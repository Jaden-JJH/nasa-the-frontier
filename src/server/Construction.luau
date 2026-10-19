--!strict
-- 모듈 건설: PadA/B/C 프롬프트, 비용 검증, 건설 진행, 고스트/완성 모델 전환, 선행 조건 (CONTRACT 3절)
-- Ghost와 Built는 해당 상태가 아닐 때 Parent를 nil로 빼 둔다 (CONTRACT 4절 "Parent를 빼두거나 투명")
-- 건설 연출 (2026-10-18): Ghost는 착공 가능(available)일 때 미리보기로만 보이고 착공하면 숨긴다.
-- building 동안 Built가 지면 아래(바닥 = 지면 - 높이)에서 진행률만큼 올라온다. DayTick마다 BUILD_RISE_SECONDS
-- 동안 ANIMATION_HZ로 부드럽게 옮긴다. 올라오는 동안 충돌은 끄고, 완공하면 최종 위치에 붙이고 충돌을 되돌린다.
-- 완공 뒤 조작(가동 중지, 외벽 수리)은 외벽 제어반이 맡는다 (ModulePanels, 2026-10-19 19차). 여기는 건설 프롬프트만.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Contributions = require(script.Parent.Contributions)
local KitImports = require(script.Parent.KitImports)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type GameState = Simulation.GameState

type PadEntry = {
    id: string,
    model: Model,
    pad: BasePart,
    ghost: Instance?,
    built: Instance?,
    prompt: ProximityPrompt,
    builtPivot: CFrame, -- 완공 위치
    builtHeight: number, -- Built 경계 상자 높이 (완전히 묻힌 깊이)
    collide: { [BasePart]: boolean }, -- 올라오는 동안 끈 충돌의 원래 값
    offset: number, -- 지금 Built의 세로 오프셋 (0이면 완공 위치)
    moveToken: number, -- 진행 중인 부드러운 이동을 끊을 때 증가
    buildLoop: Sfx.Handle?, -- 건설 중 공사 소리 (완공하면 멈춘다)
}

local function stopBuildLoop(entry: PadEntry)
    local handle = entry.buildLoop
    entry.buildLoop = nil
    if handle then
        handle.stop()
    end
end

local Construction = {}

local entries: { [string]: PadEntry } = {}
local connections: { RBXScriptConnection } = {}
local currentBase: Model? = nil

-- 건설 진행률에 따른 Built 세로 오프셋: 0이면 완전히 묻힘(-높이), 1이면 0
function Construction.riseOffset(height: number, progress: number): number
    return -height * (1 - math.clamp(progress, 0, 1))
end

local function forEachPart(root: Instance, fn: (BasePart) -> ())
    if root:IsA("BasePart") then
        fn(root)
    end
    for _, descendant in root:GetDescendants() do
        if descendant:IsA("BasePart") then
            fn(descendant)
        end
    end
end

local function placeBuilt(entry: PadEntry, offset: number)
    local built = entry.built
    if not built then
        return
    end
    entry.offset = offset
    local target = entry.builtPivot + Vector3.new(0, offset, 0)
    if built:IsA("Model") then
        built:PivotTo(target)
    elseif built:IsA("BasePart") then
        built.CFrame = target
    end
end

-- 올라오는 동안 충돌을 끈다 (원래 값을 한 번만 저장)
local function disableCollision(entry: PadEntry)
    local built = entry.built
    if not built or next(entry.collide) ~= nil then
        return
    end
    forEachPart(built, function(part)
        entry.collide[part] = part.CanCollide
        part.CanCollide = false
    end)
end

local function restoreCollision(entry: PadEntry)
    for part, value in entry.collide do
        part.CanCollide = value
    end
    table.clear(entry.collide)
end

-- 지금 오프셋에서 목표 오프셋까지 BUILD_RISE_SECONDS 동안 부드럽게
local function moveBuilt(entry: PadEntry, target: number)
    entry.moveToken += 1
    local token = entry.moveToken
    local from = entry.offset
    if math.abs(from - target) < 1e-6 then
        placeBuilt(entry, target)
        return
    end
    task.spawn(function()
        local steps = math.max(1, math.ceil(Config.BUILD_RISE_SECONDS * Config.ANIMATION_HZ))
        for step = 1, steps do
            task.wait(Config.BUILD_RISE_SECONDS / steps)
            if entry.moveToken ~= token then
                return
            end
            placeBuilt(entry, from + (target - from) * (step / steps))
        end
    end)
end

-- 상태에 맞춰 고스트, 완성 모델, 프롬프트를 맞춘다 (패드 상태 표지판은 클라이언트가 state.modules로 그린다)
local function applyVisuals(entry: PadEntry, state: GameState)
    local m = state.modules[entry.id]
    if not m then
        return
    end
    if entry.ghost then
        entry.ghost.Parent = if m.status == "available" then entry.model else nil
    end
    local built = entry.built
    if built then
        if m.status == "building" then
            if not entry.buildLoop then
                entry.buildLoop = Sfx.loop("build_loop", entry.pad)
            end
            local wasHidden = built.Parent == nil
            disableCollision(entry)
            built.Parent = entry.model
            local target = Construction.riseOffset(entry.builtHeight, m.progress)
            if wasHidden then
                -- 착공 직후: 완전히 묻힌 자리에서 시작
                placeBuilt(entry, Construction.riseOffset(entry.builtHeight, 0))
            end
            moveBuilt(entry, target)
        elseif m.status == "active" then
            stopBuildLoop(entry)
            entry.moveToken += 1
            placeBuilt(entry, 0)
            restoreCollision(entry)
            built.Parent = entry.model
        else
            stopBuildLoop(entry)
            entry.moveToken += 1
            placeBuilt(entry, 0)
            restoreCollision(entry)
            built.Parent = nil
        end
    end
    entry.prompt.Enabled = m.status == "available" and state.phase == "playing"
end

-- 테스트용: 모듈 Built의 지금 세로 오프셋 (없으면 nil)
function Construction.builtOffset(id: string): number?
    local entry = entries[id]
    return if entry then entry.offset else nil
end

-- 완공 위치에 놓인 Built와 그 Pad 파트 (ModulePanels가 제어반 자리를 잡을 때). 아직 안 지어졌거나 올라오는 중이면 nil
function Construction.placedBuilt(id: string): (Instance?, BasePart?)
    local entry = entries[id]
    local built = entry and entry.built
    if not entry or not built or built.Parent == nil or entry.offset ~= 0 then
        return nil, nil
    end
    return built, entry.pad
end

-- prev와 new를 비교해 화면을 맞추고 상태 전환 알림을 보낸다. prev가 nil이면 알림 없이 맞추기만 한다
function Construction.sync(prev: GameState?, new: GameState)
    for _, id in Config.MODULE_ORDER do
        local entry = entries[id]
        if entry then
            applyVisuals(entry, new)
        end
        if prev then
            local before = prev.modules[id]
            local after = new.modules[id]
            local def = Config.MODULES[id]
            if before and after and before.status ~= after.status then
                if after.status == "active" then
                    Sfx.play("build_complete", entry and entry.pad)
                    ResourceState.notifyAll(Construction.doneText(id), "good")
                    -- KitImports 장식 (연결 통로, 작물). 메시가 없으면 아무 것도 하지 않는다
                    local base = currentBase
                    if base then
                        ServerUtil.safeCall(
                            "KitImports",
                            KitImports.onModuleActivated,
                            id,
                            base,
                            function(moduleId: string): boolean
                                local m = new.modules[moduleId]
                                return m ~= nil and m.status == "active"
                            end
                        )
                    end
                elseif after.status == "available" and before.status == "locked" then
                    ResourceState.notifyAll(
                        string.format(Config.TEXTS.moduleUnlocked, def.displayName),
                        "info"
                    )
                end
            end
        end
    end
end

-- 완공 알림: 모듈별 문구(유지비와 생산 포함)가 있으면 그것, 없으면 "%s 완공"
function Construction.doneText(id: string): string
    local def = Config.MODULES[id]
    local template = Config.TEXTS.buildDoneBy[id]
    if id == "A" and template then
        return string.format(template, def.upkeep.water, def.upkeep.energy)
    elseif id == "B" and template then
        return string.format(template, def.foodPerDay, def.upkeep.water, def.upkeep.energy)
    end
    return string.format(Config.TEXTS.buildDone, def.displayName)
end

local function onTriggered(player: Player, id: string)
    local prev = ResourceState.get()
    local ok, newState, message = Simulation.startBuild(prev, Config, id)
    if not ok then
        ResourceState.notify(player, message, "warn")
        return
    end
    ResourceState.set(newState)
    Contributions.add(player, "builds", 1)
    local entry = entries[id]
    Sfx.play("build_start", entry and entry.pad)
    Construction.sync(prev, newState)
    ResourceState.notifyAll(message, "info")
    ResourceState.publish()
end

-- 새 기지에 연결
function Construction.attach(base: Model)
    Construction.detach()
    currentBase = base
    local pads = base:FindFirstChild("ModulePads")
    for _, id in Config.MODULE_ORDER do
        local model = ServerUtil.findModel(pads, "Pad" .. id)
        local padPart = ServerUtil.findPart(model, "Pad")
        if model and padPart then
            local def = Config.MODULES[id]
            -- 클라이언트가 패드 모델을 찾을 수 있게 (디자이너 BaseKit에도 붙인다)
            model:SetAttribute("ModuleId", id)
            local ghost = model:FindFirstChild("Ghost")
            local built = model:FindFirstChild("Built")
            local builtPivot, builtHeight = CFrame.identity, 0
            if built and built:IsA("Model") then
                builtPivot = built:GetPivot()
                local _, size = built:GetBoundingBox()
                builtHeight = size.Y
            elseif built and built:IsA("BasePart") then
                builtPivot = built.CFrame
                builtHeight = built.Size.Y
            end
            if ghost then
                ghost.Parent = nil
            end
            if built then
                built.Parent = nil
            end
            local prompt = ServerUtil.makePrompt(padPart, {
                actionText = Config.PROMPT_TEXTS.build,
                objectText = string.format(Config.PROMPT_TEXTS.buildObject, def.displayName),
                holdDuration = Config.PROMPT.buildHold,
                enabled = false,
            })
            entries[id] = {
                id = id,
                model = model,
                pad = padPart,
                ghost = ghost,
                built = built,
                prompt = prompt,
                builtPivot = builtPivot,
                builtHeight = builtHeight,
                collide = {},
                offset = 0,
                moveToken = 0,
                buildLoop = nil,
            }
            table.insert(
                connections,
                prompt.Triggered:Connect(function(player: Player)
                    onTriggered(player, id)
                end)
            )
        else
            warn("[Construction] Base.ModulePads.Pad" .. id .. ".Pad를 찾지 못했습니다")
        end
    end
    Construction.sync(nil, ResourceState.get())
end

function Construction.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, entry in entries do
        entry.moveToken += 1
        stopBuildLoop(entry)
        restoreCollision(entry)
        entry.prompt:Destroy()
        -- 빼 두었던 모델은 Base와 함께 사라지지 않으므로 직접 정리한다
        if entry.ghost and entry.ghost.Parent == nil then
            entry.ghost:Destroy()
        end
        if entry.built and entry.built.Parent == nil then
            entry.built:Destroy()
        end
    end
    table.clear(entries)
    currentBase = nil
end

return Construction
