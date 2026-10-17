--!strict
-- 로버 부스터 (2026-10-18, CONTRACT RoverBoost Remote)
--   요청: RoverBoost(on: boolean). 보낸 플레이어가 DriverSeat 탑승자이고, 플레이 중이고, 배터리가
--         ROVER.boostMinBatteryRatio 이상이고, 과열(쿨다운) 중이 아니어야 켠다. 조건이 안 맞으면 조용히 무시한다.
--   효과: RoverDrive 속도 요소 "boost" = boostSpeedMultiplier, RoverBattery 소모 x boostDrainMultiplier,
--         섀시에 rover_boost_loop.
--   과열: 부스트 중 초당 1/boostMaxSeconds 증가, 1이면 꺼지고 과열. 아닐 때 초당 1/boostCooldownSeconds 감소,
--         과열 뒤 0까지 식으면 다시 쓸 수 있고 rover_boost_ready 1회.
--   자동 해제: 하차(좌석 빔), 배터리 부족(비율 미만), 과열. 계산은 RoverBattery 주기(tick)에서 같이 한다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local RoverDrive = require(script.Parent.RoverDrive)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type GameState = Simulation.GameState

local RoverBoost = {}

local overheated = false -- 과열로 꺼진 뒤 아직 0까지 식지 않음
local boostLoop: Sfx.Handle? = nil
local initialized = false

local function stopLoop()
    local handle = boostLoop
    boostLoop = nil
    if handle then
        handle.stop()
    end
end

-- 상태의 boosting을 속도 요소와 부스트 루프에 반영한다
function RoverBoost.apply(state: GameState)
    local boosting = state.rover.boosting
    RoverDrive.setSpeedFactor("boost", if boosting then Config.ROVER.boostSpeedMultiplier else 1)
    if boosting and not boostLoop then
        local rover = ServerUtil.findModel(ServerUtil.getBase(), "Rover")
        boostLoop = Sfx.loop("rover_boost_loop", rover and rover.PrimaryPart)
    elseif not boosting then
        stopLoop()
    end
end

function RoverBoost.isOverheated(): boolean
    return overheated
end

-- 원격 요청 처리 (테스트도 같은 경로를 쓴다)
function RoverBoost.request(player: Player, on: any)
    if typeof(on) ~= "boolean" then
        return
    end
    local seat = ServerUtil.getRoverSeat()
    if not seat or ServerUtil.playerFromHumanoid(seat.Occupant) ~= player then
        return
    end
    local state = ResourceState.get()
    if on == state.rover.boosting then
        return
    end
    if on and not Simulation.canBoost(state, Config, overheated) then
        return
    end
    ResourceState.patch(function(s)
        s.rover.boosting = on
        Simulation.refreshDerived(s, Config)
    end)
    RoverBoost.apply(ResourceState.get())
    ResourceState.publish()
end

-- RoverBattery 주기마다: 자동 해제와 과열 게이지. 반환: 새 상태, boosting이 바뀌었는지
function RoverBoost.tick(
    state: GameState,
    dt: number,
    seatEmpty: boolean,
    chassis: BasePart?
): (GameState, boolean)
    local new = state
    local r = state.rover
    if
        r.boosting and (seatEmpty or r.battery < r.batteryMax * Config.ROVER.boostMinBatteryRatio)
    then
        new = Simulation.copy(state)
        new.rover.boosting = false
    end
    local overheatNow
    new, overheatNow = Simulation.boostTick(new, Config, dt)
    if overheatNow then
        overheated = true
    elseif overheated and new.rover.boostHeat <= 0 then
        overheated = false
        Sfx.play("rover_boost_ready", chassis)
    end
    return new, new.rover.boosting ~= state.rover.boosting
end

function RoverBoost.reset()
    overheated = false
    stopLoop()
    RoverDrive.setSpeedFactor("boost", 1)
end

function RoverBoost.init()
    if initialized then
        return
    end
    initialized = true
    Remotes.get("RoverBoost").OnServerEvent:Connect(function(player: Player, on: any)
        ServerUtil.safeCall("RoverBoost", RoverBoost.request, player, on)
    end)
end

return RoverBoost
