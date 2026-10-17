--!strict
-- 로버 배터리와 충전 (2026-10-18, CONTRACT 3절 RoverBattery)
--   소모: 섀시 속도가 ROVER.movingSpeed보다 빠를 때 초당 batteryDrainPerSecond. 속도는 주기마다 섀시 위치 변화로 잰다
--         (물리 속도 속성 대신: 네트워크 소유권과 무관하고, 복구 순간이동은 위치 기준을 다시 잡아 무시한다).
--         0이면 RoverDrive 속도 요소 0(정지) -> "복구 콘솔로 끌어오세요" 경고 1회.
--         복구(RoverRecovery)는 배터리를 recoverBatteryRatio까지 채워 돌려놓는다.
--   충전: 섀시가 Base.ChargePad 중심에서 chargeRadius 안이고 좌석이 비어 있고 기지 에너지 > 0이면
--         초당 chargeRatePerSecond만큼 기지 에너지에서 옮긴다 (빈 용량과 에너지 잔량 중 작은 값). 충전 중 rover.charging.
--         완충하면 "로버 충전 완료" 1회, 기지 에너지 0이면 충전을 멈추고 하루 한 번 경고.
--   도크 상태 (ChargePad Attribute DockState, CONTRACT 4절):
--         "empty"    로버가 반경 밖. 어두운 판 + 노란 테두리, 빛 없음
--         "docked"   반경 안이지만 충전 전(탑승 중이거나 기지 에너지 0). 하늘색 테두리 + 약한 SurfaceLight
--         "charging" 충전 중. 노란 Neon 테두리와 중앙 원판이 pulsePeriod 주기로 밝기 펄스 (서버 루프)
--         "full"     반경 안 + 배터리 가득. 초록 고정
--         탑승한 채 도크에 들어오면 운전자에게 info, 충전이 시작되는 순간 모두에게 good "충전 시작 (n / 50)".
--   경고: 배터리가 lowBatteryRatio 이하로 내려가면 1회 (그 위로 충전되면 다시 경고 가능).
--   송신: 충전 여부, 방전, 기지 밖 여부가 바뀌면 바로, 배터리 값만 바뀌면 batteryPublishSeconds 간격으로만 publish.
--   효과음: 주행 루프(섀시, 속도 비례 PlaybackSpeed, 정지하면 작게), 도크 진입, 충전 루프(패드), 완충, 배터리 부족

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local RoverDrive = require(script.Parent.RoverDrive)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type GameState = Simulation.GameState
export type DockState = "empty" | "docked" | "charging" | "full"

local RoverBattery = {}

local currentBase: Model? = nil
local padPart: BasePart? = nil
local initialized = false
local lastPublish = -math.huge -- os.clock
local warnedLow = false
local notifiedFull = false
local noEnergyNoticeDay: number? = nil
local lastPosition: Vector3? = nil -- 직전 주기의 섀시 위치 (속도 계산)
local dockState: DockState = "empty"
local dockGeneration = 0 -- 도크 상태가 바뀔 때마다 증가 (펄스 루프 정지)
local engineLoop: Sfx.Handle? = nil
local engineChassis: BasePart? = nil
local engineVolume = 0
local chargeLoop: Sfx.Handle? = nil

local function flatDistance(a: Vector3, b: Vector3): number
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function rgb(values: { number }): Color3
    return Color3.fromRGB(values[1], values[2], values[3])
end

-- 방전이면 RoverDrive 속도 요소 0
local function applyDriveFactor(state: GameState)
    RoverDrive.setSpeedFactor("battery", if state.rover.battery > 0 then 1 else 0)
end

-- 도크 상태 판정 (반경 안 여부, 좌석, 배터리, 기지 에너지)
local function evaluateDock(onPad: boolean, seatEmpty: boolean, state: GameState): DockState
    if not onPad then
        return "empty"
    elseif state.rover.battery >= state.rover.batteryMax then
        return "full"
    elseif seatEmpty and state.energy > 0 then
        return "charging"
    end
    return "docked"
end

-- 패드의 테두리(ChargePadTrim), 중앙 원판(ChargePadRing), SurfaceLight
local function padParts(pad: BasePart): ({ BasePart }, BasePart?, SurfaceLight?)
    local trims: { BasePart } = {}
    local ring: BasePart? = nil
    for _, child in pad:GetChildren() do
        if child:IsA("BasePart") and child.Name == "ChargePadTrim" then
            table.insert(trims, child)
        elseif child:IsA("BasePart") and child.Name == "ChargePadRing" then
            ring = child
        end
    end
    return trims, ring, pad:FindFirstChildOfClass("SurfaceLight")
end

local function paint(
    pad: BasePart,
    color: Color3,
    ringVisible: boolean,
    brightness: number,
    transparency: number
)
    local trims, ring, light = padParts(pad)
    for _, trim in trims do
        trim.Color = color
        trim.Transparency = transparency
    end
    if ring then
        ring.Color = color
        ring.Transparency = if ringVisible then transparency else 1
    end
    if light then
        light.Color = color
        light.Brightness = brightness
        light.Enabled = brightness > 0
    end
end

-- 도크 상태를 Attribute와 외형에 반영한다. charging이면 펄스 루프를 돌린다
local function applyDockVisual(pad: BasePart, state: DockState)
    local d = Config.CHARGE_DOCK
    dockGeneration += 1
    pad:SetAttribute("DockState", state)
    if state == "empty" then
        paint(pad, rgb(d.emptyColor), false, 0, 0)
    elseif state == "docked" then
        paint(pad, rgb(d.dockedColor), false, d.dockedLight, 0)
    elseif state == "full" then
        paint(pad, rgb(d.fullColor), true, d.fullLight, 0)
    else
        local myGeneration = dockGeneration
        local color = rgb(d.chargingColor)
        paint(pad, color, true, d.chargingLightMax, 0)
        task.spawn(function()
            local start = os.clock()
            while myGeneration == dockGeneration and pad.Parent ~= nil do
                local phase = (math.sin(2 * math.pi * (os.clock() - start) / d.pulsePeriod) + 1) / 2
                paint(pad, color, true, d.chargingLightMax * (0.3 + 0.7 * phase), 0.5 * (1 - phase))
                task.wait(1 / d.pulseHz)
            end
        end)
    end
end

local function stopChargeLoop()
    local handle = chargeLoop
    chargeLoop = nil
    if handle then
        handle.stop()
    end
end

local function stopEngine()
    local handle = engineLoop
    engineLoop = nil
    engineChassis = nil
    engineVolume = 0
    if handle then
        handle.stop()
    end
end

-- 주행 루프: 섀시에 붙이고(로버를 다시 만들면 새 섀시로 옮긴다) 속도에 비례한 PlaybackSpeed, 정지하면 작게
local function updateEngine(chassis: BasePart, speed: number, occupied: boolean)
    local s = Config.SFX
    if engineChassis ~= chassis then
        stopEngine()
        engineChassis = chassis
        engineLoop = Sfx.loop("rover_engine_loop", chassis, { volume = 0 })
    end
    local moving = speed > Config.ROVER.movingSpeed
    local target = if not occupied
        then 0
        elseif moving then Sfx.baseVolume("rover_engine_loop")
        else s.engineIdleVolume
    engineVolume += (target - engineVolume) * s.engineFade
    local ratio = math.clamp(speed / Config.ROVER.maxSpeed, 0, 1)
    Sfx.setLoopVolume(engineLoop, engineVolume)
    Sfx.setLoopSpeed(engineLoop, s.engineMinSpeed + (s.engineMaxSpeed - s.engineMinSpeed) * ratio)
end

-- 지금 도크 상태 (테스트와 진단용)
function RoverBattery.getDockState(): DockState
    return dockState
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
    local seatEmpty = seat.Occupant == nil
    updateEngine(chassis, speed, not seatEmpty)
    if speed > r.movingSpeed and new.rover.battery > 0 then
        new, emptied = Simulation.drainBattery(new, Config, dt)
    end

    local pad = padPart
    local padDistance = if pad then flatDistance(position, pad.CFrame.Position) else math.huge
    local onPad = padDistance <= r.chargeRadius
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

    -- 도크 상태: 충전 중이었으면 이번 주기에 가득 찼어도 "full"로 바로 넘어간다
    local nextDock: DockState = evaluateDock(onPad, seatEmpty, new)
    if nextDock == "charging" and not charging then
        nextDock = "docked"
    end
    if pad and nextDock ~= dockState then
        local before = dockState
        dockState = nextDock
        applyDockVisual(pad, nextDock)
        if before == "empty" then
            Sfx.play("rover_dock", pad)
            local driver = ServerUtil.playerFromHumanoid(seat.Occupant)
            if driver then
                ResourceState.notify(driver, t.dockEntered, "info")
            end
        end
        if nextDock == "charging" then
            ResourceState.notifyAll(
                string.format(
                    t.chargeStarted,
                    math.floor(new.rover.battery),
                    math.floor(new.rover.batteryMax)
                ),
                "good"
            )
            stopChargeLoop()
            chargeLoop = Sfx.loop("rover_charge_loop", pad)
        else
            stopChargeLoop()
        end
    end

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
        Sfx.play("rover_battery_low", chassis)
    elseif new.rover.battery > low then
        warnedLow = false
    end
    if charging and new.rover.battery >= new.rover.batteryMax and not notifiedFull then
        notifiedFull = true
        ResourceState.notifyAll(t.batteryFull, "good")
        Sfx.play("rover_charge_full", pad)
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

-- 새 기지에 연결: 충전 패드를 찾는다 (없으면 물탱크 자리에서 충전). 패드에 SurfaceLight가 없으면 만든다
function RoverBattery.attach(base: Model)
    RoverBattery.detach()
    currentBase = base
    local pad = ServerUtil.findPart(base, "ChargePad")
    if pad then
        if not pad:FindFirstChildOfClass("SurfaceLight") then
            local light = Instance.new("SurfaceLight")
            light.Face = Enum.NormalId.Top
            light.Range = Config.CHARGE_DOCK.lightRange
            light.Brightness = 0
            light.Enabled = false
            light.Parent = pad
        end
        dockState = "empty"
        applyDockVisual(pad, "empty")
        padPart = pad
    else
        warn("[RoverBattery] Base.ChargePad가 없어 물탱크 자리에서 충전합니다")
        padPart = ServerUtil.findPart(base, "WaterTank")
    end
    applyDriveFactor(ResourceState.get())
end

function RoverBattery.detach()
    dockGeneration += 1
    stopChargeLoop()
    stopEngine()
    currentBase = nil
    padPart = nil
    warnedLow = false
    notifiedFull = false
    noEnergyNoticeDay = nil
    lastPublish = -math.huge
    lastPosition = nil
    dockState = "empty"
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
