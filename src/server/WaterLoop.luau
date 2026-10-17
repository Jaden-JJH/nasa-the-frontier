--!strict
-- 물 루프: 얼음 지점 프롬프트(만충), 기지 물탱크 프롬프트(하역), 로버 탱크 Attribute (CONTRACT 3절)
-- 탱크 값의 기준은 서버 GameState.rover.tank이고, Base.Rover.DriverSeat의 Attribute "Tank"에 그대로 비춘다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)

type IceEntry = { part: BasePart, prompt: ProximityPrompt }

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

local function onIceTriggered(player: Player, ice: BasePart)
    local seat = ServerUtil.getRoverSeat()
    if not isDriver(player, seat) then
        ResourceState.notify(player, Config.TEXTS.needDriver, "warn")
        return
    end
    if not roverNear(seat, ice) then
        return
    end
    local ok, newState, message = Simulation.fillTank(ResourceState.get(), Config)
    if not ok then
        ResourceState.notify(player, message, "info")
        return
    end
    ResourceState.set(newState)
    WaterLoop.mirrorTank()
    WaterLoop.refresh()
    ResourceState.notify(player, message, "good")
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
    local ok, newState, message = Simulation.unloadWater(state, Config)
    if not ok then
        ResourceState.notify(player, message, "info")
        return
    end
    ResourceState.set(newState)
    WaterLoop.mirrorTank()
    WaterLoop.refresh()
    ResourceState.notifyAll(message, "good")
    ResourceState.publish()
end

-- 얼음 프롬프트 Enabled 갱신: 플레이 중 + 운전석에 누가 앉음 + 로버가 가까움
local function pollIcePrompts()
    local playing = ResourceState.get().phase == "playing"
    local seat = ServerUtil.getRoverSeat()
    local occupied = seat ~= nil and seat.Occupant ~= nil
    for _, entry in iceEntries do
        local enabled = playing and occupied and roverNear(seat, entry.part)
        if entry.prompt.Enabled ~= enabled then
            entry.prompt.Enabled = enabled
        end
    end
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
            prompt.Triggered:Connect(function(player: Player)
                onIceTriggered(player, child)
            end)
            table.insert(iceEntries, { part = child, prompt = prompt })
        end
    end
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
    end
end

return WaterLoop
