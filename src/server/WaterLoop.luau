--!strict
-- 물 루프: 얼음 매장지 프롬프트(채취, 고갈), 기지 물탱크 프롬프트(하역, 처리 전력), 로버 탱크 Attribute (CONTRACT 3절)
-- 탱크 값의 기준은 서버 GameState.rover.tank이고, Base.Rover.DriverSeat의 Attribute "Tank"에 그대로 비춘다.
-- 매장량의 기준은 각 Ice 파트의 Attribute "Deposit"(남은 양)과 "DepositMax"(처음 양)이다 (2026-10-18).
--   채취하면 Deposit이 줄고 결정 크기가 남은 / 처음 비율(하한 Config.ICE_VISUAL.minScale)로 줄어든다.
--   0이 되면 결정과 빛을 치우고 프롬프트를 끄고 어두운 패치를 깐다. 재시작하면 처음 상태로 되돌린다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Contributions = require(script.Parent.Contributions)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

-- 얼음 하나의 외형 원본 (고갈 표시와 재시작 복원용)
type IceEntry = {
    part: BasePart,
    prompt: ProximityPrompt,
    depositMax: number,
    partSize: Vector3, -- 그레이박스 파트 원래 크기 (결정 메시가 없을 때 이 파트가 결정 역할)
    partCFrame: CFrame,
    partTransparency: number,
    partCanCollide: boolean,
    crystal: Model?, -- KitImports 결정 메시 (없으면 nil)
    crystalScale: number,
    crystalPivot: CFrame,
    crystalBottom: number,
    lights: { PointLight },
    patch: BasePart?,
    mineLoop: Sfx.Handle?, -- 채취 홀드 동안 드릴 소리
}

local WaterLoop = {}

local iceEntries: { IceEntry } = {}
local tankPrompt: ProximityPrompt? = nil
local tankPart: BasePart? = nil
local baseConnections: { RBXScriptConnection } = {}
local initialized = false

-- 서버 탱크 값을 로버 DriverSeat의 Attribute "Tank"에 비춘다 (로버를 다시 만들었을 때도 호출)
function WaterLoop.mirrorTank()
    local seat = ServerUtil.getRoverSeat()
    if seat then
        seat:SetAttribute("Tank", ResourceState.get().rover.tank)
    end
end

-- 물탱크 프롬프트 문구와 활성 상태 (playing일 때만 활성)
function WaterLoop.refresh()
    local current = tankPrompt
    if current then
        local state = ResourceState.get()
        current.Enabled = state.phase == "playing"
        current.ObjectText = Config.PROMPT_TEXTS.tankObject
    end
end

-- 플레이어가 로버 운전석에 앉아 있는지
local function isDriver(player: Player, seat: VehicleSeat?): boolean
    if not seat then
        return false
    end
    return ServerUtil.playerFromHumanoid(seat.Occupant) == player
end

-- 로버가 얼음 파트에서 기준 거리 안에 있는지
local function roverNear(seat: VehicleSeat?, ice: BasePart): boolean
    if not seat then
        return false
    end
    return ServerUtil.distanceToPart(ice, seat.CFrame.Position) <= Config.ICE_PROMPT_DISTANCE
end

local function depositOf(entry: IceEntry): number
    local value = entry.part:GetAttribute("Deposit")
    return if typeof(value) == "number" then value else 0
end

-- 결정 모델 바닥 높이
local function modelBottom(model: Model): number
    local cframe, size = model:GetBoundingBox()
    return cframe.Position.Y - size.Y / 2
end

-- 남은 매장량에 맞춰 결정 크기, 빛, 고갈 패치, 프롬프트 문구를 맞춘다
local function applyDepositVisual(entry: IceEntry)
    local remaining = depositOf(entry)
    local visual = Config.ICE_VISUAL
    local depleted = remaining <= 0
    local ratio = if entry.depositMax > 0 then remaining / entry.depositMax else 0
    local scale = math.max(visual.minScale, math.min(1, ratio))
    local part = entry.part
    local crystal = entry.crystal
    if crystal then
        if depleted then
            crystal.Parent = nil
        else
            crystal.Parent = part
            crystal:ScaleTo(entry.crystalScale * scale)
            crystal:PivotTo(entry.crystalPivot)
            -- 바닥을 지면에 붙인 채로 줄인다
            local lift = entry.crystalBottom - modelBottom(crystal)
            crystal:PivotTo(entry.crystalPivot + Vector3.new(0, lift, 0))
        end
    else
        -- 그레이박스: 파트 자체가 얼음 덩어리. 바닥을 고정하고 크기를 줄인다. 고갈되면 숨긴다
        local size = entry.partSize * scale
        local bottom = entry.partCFrame.Position.Y - entry.partSize.Y / 2
        part.Size = size
        part.CFrame = entry.partCFrame
            + Vector3.new(0, bottom + size.Y / 2 - entry.partCFrame.Position.Y, 0)
        part.Transparency = if depleted then 1 else entry.partTransparency
        part.CanCollide = if depleted then false else entry.partCanCollide
    end
    for _, light in entry.lights do
        light.Enabled = not depleted
    end
    if depleted and not entry.patch then
        local size = visual.patchSize
        local color = visual.patchColor
        local patch = Instance.new("Part")
        patch.Name = "MinedPatch"
        patch.Size = Vector3.new(size[1], size[2], size[3])
        local bottom = entry.partCFrame.Position.Y - entry.partSize.Y / 2
        patch.CFrame = CFrame.new(
            entry.partCFrame.Position.X,
            bottom + size[2] / 2,
            entry.partCFrame.Position.Z
        )
        patch.Color = Color3.fromRGB(color[1], color[2], color[3])
        patch.Material = Enum.Material.Slate
        patch.Anchored = true
        patch.CanCollide = false
        patch.CanQuery = false
        patch.Parent = part
        entry.patch = patch
    elseif not depleted and entry.patch then
        entry.patch:Destroy()
        entry.patch = nil
    end
    entry.prompt.ObjectText = if depleted
        then Config.PROMPT_TEXTS.iceObject
        else string.format(Config.PROMPT_TEXTS.iceObjectAmount, math.floor(remaining + 0.5))
end

-- 모든 매장지를 처음 매장량으로 되돌린다 (서버 시작, 재시작)
function WaterLoop.resetDeposits()
    for _, entry in iceEntries do
        entry.part:SetAttribute("Deposit", entry.depositMax)
        applyDepositVisual(entry)
    end
end

-- 남은 매장량 (테스트와 디버그용). 없는 이름이면 nil
function WaterLoop.depositOf(name: string): number?
    for _, entry in iceEntries do
        if entry.part.Name == name then
            return depositOf(entry)
        end
    end
    return nil
end

local function stopMineLoop(entry: IceEntry)
    local handle = entry.mineLoop
    entry.mineLoop = nil
    if handle then
        handle.stop()
    end
end

local function onIceTriggered(player: Player, entry: IceEntry)
    stopMineLoop(entry)
    local seat = ServerUtil.getRoverSeat()
    if not isDriver(player, seat) then
        ResourceState.notify(player, Config.TEXTS.needDriver, "warn")
        return
    end
    if not roverNear(seat, entry.part) then
        return
    end
    local ok, newState, remaining, message, kind =
        Simulation.fillFromDeposit(ResourceState.get(), Config, depositOf(entry))
    if not ok then
        ResourceState.notify(player, message, ResourceState.kind(kind))
        return
    end
    entry.part:SetAttribute("Deposit", remaining)
    applyDepositVisual(entry)
    Sfx.play("ice_collected", entry.part)
    if remaining <= 0 then
        Sfx.play("ice_depleted", entry.part)
    end
    ResourceState.set(newState)
    WaterLoop.mirrorTank()
    WaterLoop.refresh()
    ResourceState.notify(player, message, ResourceState.kind(kind))
    ResourceState.publish()
end

-- 로버가 물탱크 옆에 서 있는지 (DriverSeat에서 WaterTank 파트 표면까지 거리)
local function roverAtTank(): boolean
    local seat = ServerUtil.getRoverSeat()
    local tank = tankPart
    if not seat or not tank then
        return false
    end
    return ServerUtil.distanceToPart(tank, seat.CFrame.Position) <= Config.TANK_UNLOAD_DISTANCE
end

local function onTankTriggered(player: Player)
    local state = ResourceState.get()
    -- 빈 탱크와 비진행 단계 안내는 Simulation.unloadWater가 맡고, 실제 하역 직전에만 거리를 본다
    if state.phase == "playing" and state.rover.tank > 0 and not roverAtTank() then
        ResourceState.notify(player, Config.TEXTS.needRoverAtTank, "warn")
        return
    end
    local ok, newState, message, kind, warning = Simulation.unloadWater(state, Config)
    if not ok then
        ResourceState.notify(player, message, ResourceState.kind(kind))
        return
    end
    ResourceState.set(newState)
    -- 하역량 = 탱크에서 빠진 양 (전력이 모자라 일부만 처리하면 처리한 만큼)
    Contributions.add(player, "water", state.rover.tank - newState.rover.tank)
    Sfx.play("water_unload", tankPart)
    Sfx.play("water_processing", tankPart)
    WaterLoop.mirrorTank()
    WaterLoop.refresh()
    ResourceState.notifyAll(message, ResourceState.kind(kind))
    if warning then
        ResourceState.notifyAll(warning, "warn")
    end
    ResourceState.publish()
end

-- 얼음 프롬프트 Enabled 갱신: 플레이 중 + 매장량 남음 + 운전석에 누가 앉음 + 로버가 가까움
local function pollIcePrompts()
    local playing = ResourceState.get().phase == "playing"
    local seat = ServerUtil.getRoverSeat()
    local occupied = seat ~= nil and seat.Occupant ~= nil
    for _, entry in iceEntries do
        local enabled = playing
            and occupied
            and depositOf(entry) > 0
            and roverNear(seat, entry.part)
        if entry.prompt.Enabled ~= enabled then
            entry.prompt.Enabled = enabled
        end
    end
end

-- 얼음 파트 하나의 처음 매장량: Attribute DepositMax -> Deposit -> Config.ICE_SITES[번호] -> 기본값
local function initialDeposit(part: BasePart): (number, string)
    local index = tonumber(string.match(part.Name, "^Ice(%d+)$"))
    local site = if index then Config.ICE_SITES[index] else nil
    local difficulty = part:GetAttribute("Difficulty")
    local label = if typeof(difficulty) == "string"
        then difficulty
        elseif site then site.difficulty
        else "mid"
    for _, key in { "DepositMax", "Deposit" } do
        local value = part:GetAttribute(key)
        if typeof(value) == "number" and value > 0 then
            return value, label
        end
    end
    if site then
        return site.deposit, label
    end
    return Config.ICE_DEFAULT_DEPOSIT, label
end

local function makeEntry(part: BasePart, prompt: ProximityPrompt): IceEntry
    local depositMax, difficulty = initialDeposit(part)
    part:SetAttribute("DepositMax", depositMax)
    part:SetAttribute("Deposit", depositMax)
    part:SetAttribute("Difficulty", difficulty)
    local crystal: Model? = nil
    for _, child in part:GetChildren() do
        if child:IsA("Model") then
            crystal = child
            break
        end
    end
    local lights: { PointLight } = {}
    for _, descendant in part:GetDescendants() do
        if descendant:IsA("PointLight") then
            table.insert(lights, descendant)
        end
    end
    local entry: IceEntry = {
        part = part,
        prompt = prompt,
        depositMax = depositMax,
        partSize = part.Size,
        partCFrame = part.CFrame,
        partTransparency = part.Transparency,
        partCanCollide = part.CanCollide,
        crystal = crystal,
        crystalScale = if crystal then crystal:GetScale() else 1,
        crystalPivot = if crystal then crystal:GetPivot() else CFrame.identity,
        crystalBottom = if crystal then modelBottom(crystal) else 0,
        lights = lights,
        patch = nil,
        mineLoop = nil,
    }
    return entry
end

-- 서버 시작 시 한 번: Workspace.IceSites의 각 파트에 프롬프트를 붙이고 감시 루프를 돈다
function WaterLoop.init()
    if initialized then
        return
    end
    initialized = true
    local folder = workspace:FindFirstChild("IceSites")
    if not folder then
        warn("[WaterLoop] Workspace.IceSites를 찾지 못했습니다")
        return
    end
    for _, child in folder:GetChildren() do
        if child:IsA("BasePart") then
            -- 얼음 프롬프트는 로버 거리 기준과 맞추려고 활성 거리를 ICE_PROMPT_DISTANCE로 둔다
            local prompt = ServerUtil.makePrompt(child, {
                actionText = Config.PROMPT_TEXTS.fillIce,
                objectText = Config.PROMPT_TEXTS.iceObject,
                holdDuration = Config.ROVER.fillHold,
                maxDistance = Config.ICE_PROMPT_DISTANCE,
                enabled = false,
            })
            local entry = makeEntry(child, prompt)
            prompt.Triggered:Connect(function(player: Player)
                onIceTriggered(player, entry)
            end)
            -- 홀드하는 동안 채취 소리 (홀드를 놓거나 끝나면 멈춘다)
            prompt.PromptButtonHoldBegan:Connect(function()
                stopMineLoop(entry)
                entry.mineLoop = Sfx.loop("ice_mine_loop", entry.part)
            end)
            prompt.PromptButtonHoldEnded:Connect(function()
                stopMineLoop(entry)
            end)
            table.insert(iceEntries, entry)
        end
    end
    WaterLoop.resetDeposits()
    task.spawn(function()
        while true do
            ServerUtil.safeCall("WaterLoop", pollIcePrompts)
            task.wait(Config.ICE_PROMPT_POLL_SECONDS)
        end
    end)
end

-- 새 기지에 연결: 물탱크 프롬프트, 탱크 Attribute
function WaterLoop.attach(base: Model)
    WaterLoop.detach()
    WaterLoop.mirrorTank()
    local tank = ServerUtil.findPart(base, "WaterTank")
    if not tank then
        warn("[WaterLoop] Base.WaterTank를 찾지 못했습니다")
        return
    end
    tankPart = tank
    local prompt = ServerUtil.makePrompt(tank, {
        actionText = Config.PROMPT_TEXTS.unload,
        objectText = Config.PROMPT_TEXTS.tankObject,
        holdDuration = Config.PROMPT.unloadHold,
        enabled = false,
    })
    tankPrompt = prompt
    table.insert(baseConnections, prompt.Triggered:Connect(onTankTriggered))
    WaterLoop.refresh()
end

function WaterLoop.detach()
    for _, connection in baseConnections do
        connection:Disconnect()
    end
    table.clear(baseConnections)
    if tankPrompt then
        tankPrompt:Destroy()
        tankPrompt = nil
    end
    tankPart = nil
    for _, entry in iceEntries do
        entry.prompt.Enabled = false
        stopMineLoop(entry)
    end
end

return WaterLoop
