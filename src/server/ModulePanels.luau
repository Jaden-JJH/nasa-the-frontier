--!strict
-- 모듈 제어반 (2026-10-19 19차, CONTRACT 3절 ModulePanels)
-- 사용자 보고: Farm 건물 앞에 서도 가동 중지가 되지 않았다. 프롬프트가 건물 안 패드 중심에 있어 벽 밖에서 닿지 않았다.
-- 실제 기지처럼 완공된 모듈 외벽에 제어반(ControlPanel)을 달고, 완공 뒤 조작을 모두 여기서 한다.
--   위치: 기지 Origin 축 기준 Built 경계 상자의 네 면 중 Origin 방향과 내적이 가장 큰 면, 그 면 바깥 wallGap.
--         면 중앙에서 오른쪽(밖에서 벽을 볼 때) sideOffset, 높이는 패드 윗면 + height.
--         그 면에 문(Door 파트)이 있으면 문을 피해 옆으로 민다. 실제 외벽(메시)이 경계 상자보다 안쪽이면
--         광선으로 찾아 snapDepth 안에서 벽에 붙인다.
--   표면: SurfaceGui 네 줄 (이름, 상태, 효과, 조작 안내)과 위쪽 Neon 상태 표시등
--         (가동 초록, 대기 노랑, 손상 빨강 깜빡임). 멀리서도 "여기서 조작한다"가 보이게 한다.
--   프롬프트: PausePrompt (canPause 모듈, pauseKey 홀드 toggleHold), RepairPrompt (손상일 때만, repairKey 홀드 repairHold).
--             둘 다 거리 promptDistance. 제어반이 프롬프트를 소유하고 ModuleRepair는 수리 규칙과 소리만 맡는다.
--   수명: 모듈이 active가 되어 Construction이 Built를 완공 위치에 놓은 뒤 refresh에서 만든다. 재시작(detach)이면 지운다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Construction = require(script.Parent.Construction)
local KitImports = require(script.Parent.KitImports)
local ModuleRepair = require(script.Parent.ModuleRepair)
local ResourceState = require(script.Parent.ResourceState)
local RunLog = require(script.Parent.RunLog)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type GameState = Simulation.GameState
type Mode = "running" | "paused" | "damaged"

type Panel = {
    id: string,
    part: BasePart,
    light: BasePart,
    glow: PointLight,
    status: TextLabel,
    effect: TextLabel,
    hint: TextLabel,
    pausePrompt: ProximityPrompt?,
    repairPrompt: ProximityPrompt,
    connections: { RBXScriptConnection },
    mode: Mode,
}

local CP = Config.CONTROL_PANEL
local FACES = { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis }
local FACE_TOLERANCE = 2 -- 문이 이 면에 있다고 보는 거리 (문은 경계 상자 면에서 조금 안쪽에 있다)

local ModulePanels = {}

local panels: { [string]: Panel } = {}
local currentBase: Model? = nil
local blinkToken = 0
local blinkRunning = false
local blinkOn = true

local function rgb(c: { number }): Color3
    return Color3.fromRGB(c[1], c[2], c[3])
end

local function keyCode(name: string): Enum.KeyCode
    return (Enum.KeyCode :: any)[name]
end

-- 기지 축 (Origin, 수평 회전만). 모듈 패드와 건물은 이 축에 맞춰 놓인다 (KitImports 통로, 작물과 같은 기준)
function ModulePanels.baseFrame(base: Model): CFrame
    local origin = base.PrimaryPart or ServerUtil.findPart(base, "Origin")
    local frame = if origin then origin.CFrame else base:GetPivot()
    local look = Vector3.new(frame.LookVector.X, 0, frame.LookVector.Z)
    if look.Magnitude < 1e-3 then
        return CFrame.new(frame.Position)
    end
    return CFrame.lookAt(frame.Position, frame.Position + look.Unit)
end

-- 문을 피한 옆 오프셋. 문이 그 면에 있고 패널과 겹치면 문 오른쪽으로, 자리가 없으면 왼쪽으로 민다
local function avoidDoors(
    built: Instance,
    frame: CFrame,
    center: Vector3,
    normal: Vector3,
    right: Vector3,
    halfNormal: number,
    offset: number,
    limit: number
): number
    local width = CP.size[1]
    for _, descendant in built:GetDescendants() do
        if descendant:IsA("BasePart") and descendant.Name == "Door" then
            local dlo, dhi = KitImports.boundsIn(descendant, frame)
            local rel = (dlo + dhi) / 2 - center
            if math.abs(rel:Dot(normal) - halfNormal) <= FACE_TOLERANCE then
                local size = dhi - dlo
                local doorHalf = (math.abs(right.X) * size.X + math.abs(right.Z) * size.Z) / 2
                local doorPos = rel:Dot(right)
                local reach = doorHalf + width / 2 + CP.doorMargin
                if math.abs(offset - doorPos) < reach then
                    local toRight, toLeft = doorPos + reach, doorPos - reach
                    if toRight <= limit or toLeft < -limit then
                        offset = toRight
                    else
                        offset = toLeft
                    end
                end
            end
        end
    end
    return offset
end

-- 경계 상자 면보다 안쪽에 있는 실제 외벽까지 깊이 (0 ~ snapDepth). 패널 양 끝과 가운데 세 줄 중 가장 바깥 벽 기준
local function wallDepth(
    built: Instance,
    frame: CFrame,
    faceCenter: Vector3,
    normal: Vector3,
    right: Vector3
): number
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { built }
    local half = CP.size[1] / 2
    local depth = CP.snapDepth
    local found = false
    for _, side in { -half, 0, half } do
        local start = faceCenter + normal + right * side
        local result = workspace:Raycast(
            frame * start,
            frame:VectorToWorldSpace(-normal * (1 + CP.snapDepth)),
            params
        )
        if not result then
            return 0 -- 이 줄에 벽이 없으면 경계 상자 면에 둔다 (패널이 모서리 밖으로 걸칠 수 있다)
        end
        found = true
        local hit = frame:PointToObjectSpace(result.Position)
        depth = math.min(depth, (faceCenter - hit):Dot(normal))
    end
    return if found then math.clamp(depth, 0, CP.snapDepth) else 0
end

-- 제어반 CFrame (월드). 앞면(Front, LookVector)이 건물 바깥을 본다
function ModulePanels.placement(built: Instance, pad: BasePart, frame: CFrame): CFrame
    local lo, hi = KitImports.boundsIn(built, frame)
    local center = Vector3.new((lo.X + hi.X) / 2, 0, (lo.Z + hi.Z) / 2)
    local half = (hi - lo) / 2
    -- Origin(프레임 원점) 방향과 내적이 가장 큰 면
    local toOrigin = -center
    local normal = FACES[1]
    local best = -math.huge
    for _, face in FACES do
        local score = face:Dot(toOrigin)
        if score > best then
            best, normal = score, face
        end
    end
    -- 밖에서 벽을 볼 때 오른쪽 = 보는 방향(-normal) x 위
    local right = (-normal):Cross(Vector3.yAxis)
    local halfNormal = math.abs(normal.X) * half.X + math.abs(normal.Z) * half.Z
    local halfSide = math.abs(right.X) * half.X + math.abs(right.Z) * half.Z
    local limit = math.max(0, halfSide - CP.size[1] / 2)
    local offset = math.clamp(CP.sideOffset, -limit, limit)
    offset = avoidDoors(built, frame, center, normal, right, halfNormal, offset, limit)

    local _, padHi = KitImports.boundsIn(pad, frame)
    local y = padHi.Y + CP.height
    local faceCenter = Vector3.new(center.X, y, center.Z) + normal * halfNormal + right * offset
    local inset = wallDepth(built, frame, faceCenter, normal, right)
    local spot = faceCenter + normal * (CP.wallGap + CP.size[3] / 2 - inset)
    local position = frame * spot
    return CFrame.lookAt(position, position + frame:VectorToWorldSpace(normal))
end

local function makeLabel(
    parent: Instance,
    name: string,
    order: number,
    size: number,
    bold: boolean,
    color: Color3
): TextLabel
    local label = Instance.new("TextLabel")
    label.Name = name
    label.LayoutOrder = order
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Size = UDim2.new(1, 0, 0, size)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Font = if bold then Enum.Font.GothamBold else Enum.Font.GothamMedium
    label.TextSize = size
    label.TextColor3 = color
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = ""
    label.Parent = parent
    return label
end

local function makeScreen(part: BasePart, title: string): (TextLabel, TextLabel, TextLabel)
    local colors, sizes = CP.colors, CP.textSizes
    local gui = Instance.new("SurfaceGui")
    gui.Name = "Screen"
    gui.Face = Enum.NormalId.Front
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = CP.pixelsPerStud
    gui.LightInfluence = 0
    gui.MaxDistance = CP.guiMaxDistance
    gui.Parent = part
    -- 테두리(파트 색) 안쪽의 어두운 화면
    local screen = Instance.new("Frame")
    screen.Name = "Content"
    screen.AnchorPoint = Vector2.new(0.5, 0.5)
    screen.Position = UDim2.fromScale(0.5, 0.5)
    screen.Size = UDim2.new(1, -8, 1, -8)
    screen.BackgroundColor3 = rgb(colors.body)
    screen.BorderSizePixel = 0
    screen.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = screen
    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.Parent = screen
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, 2)
    layout.Parent = screen
    local titleLabel = makeLabel(screen, "Title", 1, sizes.title, true, rgb(colors.textDim))
    titleLabel.Text = title
    local status = makeLabel(screen, "Status", 2, sizes.status, true, rgb(colors.text))
    local effect = makeLabel(screen, "Effect", 3, sizes.body, false, rgb(colors.textDim))
    local hint = makeLabel(screen, "Hint", 4, sizes.body, true, rgb(colors.text))
    return status, effect, hint
end

local function destroyPanel(panel: Panel)
    for _, connection in panel.connections do
        connection:Disconnect()
    end
    table.clear(panel.connections)
    panel.part:Destroy()
end

local function onPauseTriggered(player: Player, id: string)
    local prev = ResourceState.get()
    local m = prev.modules[id]
    if not m then
        return
    end
    local ok, newState, message = Simulation.setPaused(prev, Config, id, not m.paused)
    if not ok then
        ResourceState.notify(player, message, "info")
        return
    end
    ResourceState.set(newState)
    RunLog.event(id .. (if newState.modules[id].paused then " 가동 중지" else " 가동 재개"))
    local panel = panels[id]
    Sfx.play(CP.toggleSound, panel and panel.part)
    ModulePanels.refresh()
    ResourceState.notifyAll(message, "info")
    ResourceState.publish()
end

local function onRepairTriggered(player: Player, id: string)
    local panel = panels[id]
    if ModuleRepair.repair(player, id, panel and panel.part) then
        ModulePanels.refresh()
        ResourceState.publish()
    end
end

-- 완공 위치의 Built가 있으면 제어반을 만든다
local function createPanel(id: string, frame: CFrame): Panel?
    local built, pad = Construction.placedBuilt(id)
    if not built or not pad or not pad.Parent then
        return nil
    end
    local def = Config.MODULES[id]
    local meteor = Config.EVENTS.micrometeoroid
    local width, height, depth = CP.size[1], CP.size[2], CP.size[3]
    local cframe = ModulePanels.placement(built, pad, frame)
    local title = string.format(Config.PROMPT_TEXTS.panelObject, def.name)

    local part = Instance.new("Part")
    part.Name = "ControlPanel"
    part.Size = Vector3.new(width, height, depth)
    part.CFrame = cframe
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CastShadow = false
    part.Material = Enum.Material.Metal
    part.Color = rgb(CP.colors.bezel)
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth

    local light = Instance.new("Part")
    light.Name = "StatusLight"
    light.Size = Vector3.new(width, CP.lightHeight, depth)
    light.CFrame = cframe * CFrame.new(0, height / 2 + CP.lightHeight / 2, 0)
    light.Anchored = true
    light.CanCollide = false
    light.CanQuery = false
    light.CanTouch = false
    light.CastShadow = false
    light.Material = Enum.Material.Neon
    light.Color = rgb(CP.colors.running)
    light.TopSurface = Enum.SurfaceType.Smooth
    light.BottomSurface = Enum.SurfaceType.Smooth
    light.Parent = part
    local glow = Instance.new("PointLight")
    glow.Range = CP.lightRange
    glow.Brightness = CP.lightBrightness
    glow.Color = light.Color
    glow.Parent = light

    local status, effect, hint = makeScreen(part, title)

    local connections: { RBXScriptConnection } = {}
    local pausePrompt: ProximityPrompt? = nil
    if def.canPause then
        local prompt = ServerUtil.makePrompt(part, {
            actionText = Config.PROMPT_TEXTS.pauseModule,
            objectText = title,
            holdDuration = CP.toggleHold,
            maxDistance = CP.promptDistance,
            enabled = false,
        })
        prompt.Name = "PausePrompt"
        prompt.KeyboardKeyCode = keyCode(CP.pauseKey)
        table.insert(
            connections,
            prompt.Triggered:Connect(function(player: Player)
                onPauseTriggered(player, id)
            end)
        )
        pausePrompt = prompt
    end
    local repairPrompt = ServerUtil.makePrompt(part, {
        actionText = Config.PROMPT_TEXTS.repairModule,
        objectText = title,
        holdDuration = meteor.repairHold,
        maxDistance = CP.promptDistance,
        enabled = false,
    })
    repairPrompt.Name = "RepairPrompt"
    repairPrompt.KeyboardKeyCode = keyCode(meteor.repairKey)
    table.insert(
        connections,
        repairPrompt.Triggered:Connect(function(player: Player)
            onRepairTriggered(player, id)
        end)
    )
    table.insert(
        connections,
        repairPrompt.PromptButtonHoldBegan:Connect(function()
            ModuleRepair.beginHold(part)
        end)
    )
    table.insert(connections, repairPrompt.PromptButtonHoldEnded:Connect(ModuleRepair.endHold))

    -- PadX 모델 아래 (Base와 함께 지워진다)
    part.Parent = pad.Parent
    local panel: Panel = {
        id = id,
        part = part,
        light = light,
        glow = glow,
        status = status,
        effect = effect,
        hint = hint,
        pausePrompt = pausePrompt,
        repairPrompt = repairPrompt,
        connections = connections,
        mode = "running",
    }
    panels[id] = panel
    return panel
end

local function applyLight(panel: Panel)
    local colors = CP.colors
    local color: Color3
    local lit = true
    if panel.mode == "damaged" then
        lit = blinkOn
        color = if blinkOn then rgb(colors.damaged) else rgb(colors.off)
    elseif panel.mode == "paused" then
        color = rgb(colors.paused)
    else
        color = rgb(colors.running)
    end
    panel.light.Color = color
    panel.glow.Color = color
    panel.glow.Enabled = lit
end

local function applyPanel(panel: Panel, state: GameState)
    local m = state.modules[panel.id]
    local def = Config.MODULES[panel.id]
    if not m or not def then
        return
    end
    local t = Config.TEXTS
    local meteor = Config.EVENTS.micrometeoroid
    local playing = state.phase == "playing"
    local damaged = m.damaged == true
    local paused = m.paused == true
    panel.mode = if damaged then "damaged" elseif paused then "paused" else "running"

    panel.status.Text = if damaged
        then t.panelDamaged
        elseif paused then t.panelPaused
        else t.panelRunning
    panel.effect.Text = if damaged
        then t.panelDamagedEffect
        elseif paused then t.panelPausedEffect
        else Simulation.upkeepText(m, def, Config)
    local hints: { string } = {}
    if damaged then
        table.insert(
            hints,
            string.format(
                t.panelRepairHint,
                meteor.repairKey,
                math.floor(meteor.repairEnergy + 0.5)
            )
        )
    end
    if def.canPause then
        table.insert(
            hints,
            string.format(if paused then t.panelResumeHint else t.panelPauseHint, CP.pauseKey)
        )
    end
    panel.hint.Text = table.concat(hints, "\n")
    panel.hint.Visible = #hints > 0

    local pausePrompt = panel.pausePrompt
    if pausePrompt then
        pausePrompt.Enabled = playing
        pausePrompt.ActionText = if paused
            then Config.PROMPT_TEXTS.resumeModule
            else Config.PROMPT_TEXTS.pauseModule
    end
    panel.repairPrompt.Enabled = playing and damaged
    applyLight(panel)
end

-- 손상된 제어반이 있는 동안만 도는 깜빡임 (주기 blinkSeconds, 절반 켜짐)
local function ensureBlink()
    if blinkRunning then
        return
    end
    blinkRunning = true
    blinkToken += 1
    local token = blinkToken
    task.spawn(function()
        while token == blinkToken do
            task.wait(CP.blinkSeconds / 2)
            if token ~= blinkToken then
                return
            end
            blinkOn = not blinkOn
            local any = false
            for _, panel in panels do
                if panel.mode == "damaged" then
                    any = true
                    applyLight(panel)
                end
            end
            if not any then
                blinkOn = true
                blinkRunning = false
                return
            end
        end
    end)
end

-- 상태에 맞춰 제어반을 만들고 지우고 표면, 표시등, 프롬프트를 맞춘다
-- (DayTick, 가동 중지, 수리, phase 변화 때 GameFlow.refreshPrompts가 부른다)
function ModulePanels.refresh()
    local base = currentBase
    if not base then
        return
    end
    local state = ResourceState.get()
    local frame = ModulePanels.baseFrame(base)
    local anyDamaged = false
    for _, id in Config.MODULE_ORDER do
        local m = state.modules[id]
        local panel = panels[id]
        if m and m.status == "active" then
            if not panel then
                -- createPanel이 panels[id]에 등록한다. 자리 계산이 실패해도 DayTick은 계속 돈다
                ServerUtil.safeCall("ModulePanels", createPanel, id, frame)
            end
            local current = panels[id]
            if current then
                applyPanel(current, state)
                anyDamaged = anyDamaged or current.mode == "damaged"
            end
        elseif panel then
            destroyPanel(panel)
            panels[id] = nil
        end
    end
    if anyDamaged then
        ensureBlink()
    end
end

-- 테스트와 진단용: 모듈의 제어반 파트 (없으면 nil)
function ModulePanels.get(id: string): BasePart?
    local panel = panels[id]
    return if panel then panel.part else nil
end

-- 테스트용: 지금 있는 제어반 수
function ModulePanels.count(): number
    local n = 0
    for _ in panels do
        n += 1
    end
    return n
end

-- 새 기지에 연결 (Construction.attach 다음에 부른다)
function ModulePanels.attach(base: Model)
    ModulePanels.detach()
    currentBase = base
    ModulePanels.refresh()
end

function ModulePanels.detach()
    blinkToken += 1
    blinkRunning = false
    blinkOn = true
    ModuleRepair.endHold()
    for _, panel in panels do
        destroyPanel(panel)
    end
    table.clear(panels)
    currentBase = nil
end

return ModulePanels
