--!strict
-- 로버 배터리와 충전 (2026-10-18, CONTRACT 3절 RoverBattery)
--   소모: 섀시 속도가 ROVER.movingSpeed보다 빠를 때 초당 batteryDrainPerSecond. 속도는 주기마다 섀시 위치 변화로 잰다
--         (물리 속도 속성 대신: 네트워크 소유권과 무관하고, 복구 순간이동은 위치 기준을 다시 잡아 무시한다). 0이면 RoverDrive 속도 요소 0(정지)
--         -> "복구 콘솔로 끌어오세요" 경고 1회. 복구(RoverRecovery)는 배터리를 recoverBatteryRatio까지 채워 돌려놓는다.
--   충전: 섀시가 Base.ChargePad 중심에서 chargeRadius 안이고 좌석이 비어 있고 기지 에너지 > 0이면
--         초당 chargeRatePerSecond만큼 기지 에너지에서 옮긴다 (빈 용량과 에너지 잔량 중 작은 값). 충전 중 rover.charging.
--         완충하면 "로버 충전 완료" 1회, 기지 에너지 0이면 충전을 멈추고 하루 한 번 경고.
--   경고: 배터리가 lowBatteryRatio 이하로 내려가면 1회 (그 위로 충전되면 다시 경고 가능).
--   송신: 충전 여부, 방전, 기지 밖 여부가 바뀌면 바로, 배터리 값만 바뀌면 batteryPublishSeconds 간격으로만 publish.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local RoverDrive = require(script.Parent.RoverDrive)
local ServerUtil = require(script.Parent.ServerUtil)

type GameState = Simulation.GameState

local RoverBattery = {}

local currentBase: Model? = nil
local padPart: BasePart? = nil
local initialized = false
local lastPublish = -math.huge -- os.clock
local warnedLow = false
local notifiedFull = false
local noEnergyNoticeDay: number? = nil
local lastPosition: Vector3? = nil -- 직전 주기의 섀시 위치 (속도 계산)

local function flatDistance(a: Vector3, b: Vector3): number
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- 방전이면 RoverDrive 속도 요소 0
local function applyDriveFactor(state: GameState)
    RoverDrive.setSpeedFactor("battery", if state.rover.battery > 0 then 1 else 0)
end

-- 한 주기(dt초) 계산. 서버 루프와 테스트가 같은 경로를 쓴다
function RoverBattery.step(dt: number)
    local state = ResourceState.get()
    if state.phase ~= "playing" then
        return
    end
    local seat = ServerUtil.getRoverSeat()
    local rover = ServerUtil.findModel(ServerUtil.getBase(), "Rover")
    if not seat or not rover then
        return
    end
    local chassis: BasePart = rover.PrimaryPart or seat
    local r = Config.ROVER
    local t = Config.TEXTS
    local new = state
    local emptied = false
    local position = chassis.CFrame.Position
    local previous = lastPosition
    lastPosition = position
    local speed = if previous and dt > 0 then (position - previous).Magnitude / dt else 0
    if speed > r.movingSpeed and new.rover.battery > 0 then
        new, emptied = Simulation.drainBattery(new, Config, dt)
    end

    local pad = padPart
    local padDistance = if pad then flatDistance(position, pad.CFrame.Position) else math.huge
    local onPad = padDistance <= r.chargeRadius
    local seatEmpty = seat.Occupant == nil
    local charging = false
    if onPad and seatEmpty and new.rover.battery < new.rover.batteryMax then
        if new.energy > 0 then
            local amount
            new, amount = Simulation.chargeBattery(new, Config, dt)
            charging = amount > 0
        elseif noEnergyNoticeDay ~= new.day then
            noEnergyNoticeDay = new.day
            ResourceState.notifyAll(t.chargeNoEnergy, "warn")
        end
    end
    local away = padDistance > r.awayDistance

    local flagsChanged = charging ~= state.rover.charging or away ~= state.rover.away
    local batteryChanged = new.rover.battery ~= state.rover.battery
    if not flagsChanged and not batteryChanged then
        return
    end
    if new == state then
        new = Simulation.copy(state)
    end
    new.rover.charging = charging
    new.rover.away = away
    Simulation.refreshDerived(new, Config)
    ResourceState.set(new)

    -- 알림
    if emptied then
        ResourceState.notifyAll(t.batteryEmpty, "warn")
    end
    local low = new.rover.batteryMax * r.lowBatteryRatio
    if new.rover.battery <= low and new.rover.battery > 0 and not warnedLow then
        warnedLow = true
        local percent = math.floor(new.rover.battery / new.rover.batteryMax * 100 + 0.5)
        ResourceState.notifyAll(string.format(t.batteryLow, percent), "warn")
    elseif new.rover.battery > low then
        warnedLow = false
    end
    if charging and new.rover.battery >= new.rover.batteryMax and not notifiedFull then
        notifiedFull = true
        ResourceState.notifyAll(t.batteryFull, "good")
    elseif new.rover.battery < new.rover.batteryMax and charging then
        notifiedFull = false
    end
    if (state.rover.battery > 0) ~= (new.rover.battery > 0) then
        applyDriveFactor(new)
    end

    local now = os.clock()
    local emptyChanged = (state.rover.battery > 0) ~= (new.rover.battery > 0)
    if flagsChanged or emptyChanged or now - lastPublish >= r.batteryPublishSeconds then
        lastPublish = now
        ResourceState.publish()
    end
end

-- 복구 뒤: 배터리를 최소 recoverBatteryRatio까지 채운다 (RoverRecovery가 부른다)
function RoverBattery.onRecovered()
    lastPosition = nil -- 순간이동은 주행이 아니다
    ResourceState.patch(function(s)
        local minimum = s.rover.batteryMax * Config.ROVER.recoverBatteryRatio
        if s.rover.battery < minimum then
            s.rover.battery = minimum
        end
        Simulation.refreshDerived(s, Config)
    end)
    applyDriveFactor(ResourceState.get())
end

-- 새 기지에 연결: 충전 패드를 찾는다 (없으면 물탱크 자리에서 충전)
function RoverBattery.attach(base: Model)
    RoverBattery.detach()
    currentBase = base
    padPart = ServerUtil.findPart(base, "ChargePad") or ServerUtil.findPart(base, "WaterTank")
    if not ServerUtil.findPart(base, "ChargePad") then
        warn("[RoverBattery] Base.ChargePad가 없어 물탱크 자리에서 충전합니다")
    end
    applyDriveFactor(ResourceState.get())
end

function RoverBattery.detach()
    currentBase = nil
    padPart = nil
    warnedLow = false
    notifiedFull = false
    noEnergyNoticeDay = nil
    lastPublish = -math.huge
    lastPosition = nil
    RoverDrive.setSpeedFactor("battery", 1)
end

-- 서버 시작 시 한 번: 계산 루프
function RoverBattery.init()
    if initialized then
        return
    end
    initialized = true
    task.spawn(function()
        local tick = Config.ROVER.batteryTickSeconds
        while true do
            task.wait(tick)
            if currentBase then
                ServerUtil.safeCall("RoverBattery", RoverBattery.step, tick)
            end
        end
    end)
end

return RoverBattery
