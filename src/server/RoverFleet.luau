--!strict
-- v2 로버 (docs/CONTRACT_V2.md 2.2 RoverFleet, V2_PLAN Q7, Q8, Q29, Q30, Q37)
-- 로버 한 대를 MissionRuntime.Rover로 만들고 두 가지로 쓴다.
--   직접 운전(멀티, 솔로도 가능): v1 RoverDrive, RoverBattery, RoverBoost, RoverDamage, RoverRecovery를 v2 숫자로 옮겼다.
--     탑승 프롬프트, 바퀴 구동(속도 배율 = 파손 x 배터리 x 부스터 x 우주 기상), 배터리(주행 중 소모, 주차판과 귀환 자리에서
--     기지 에너지로 충전, MANUAL_DRIVE.chargeKeepEnergy는 남긴다), 부스터(과열), 충돌 파손(운전 중 급정거 감지 +
--     RoverHazard 태그 파트, Rules 파손 수를 같이 쓴다), 뒤집힘과 추락 자동 복구, 탱크(얼음 채취 30, 물탱크 하역).
--   자율주행(솔로, Q8): DispatchRover가 Rules.dispatchRover에 성공하면 로버가 기지 출구까지 짧게 달려가 사라진다(Parent = nil).
--     돌아오면(Rules 상태 parked) 물탱크 옆 귀환 자리에 다시 선다. 고장(broken)이면 출구에서 얼음 후보지 쪽으로
--     brokenDistance만큼 간 자리에 멈춰 보이고, 걸어가서 R로 고치면(Rules.walkRepairRover) 자율주행을 끝내고 고친 대원이
--     운전석에 앉아 직접 몰고 돌아온다(좌석이 산소를 채운다, Q28).
--     원격 회수(Rules.remoteRecoverRover)는 콘솔에서. Rules가 일수, 에너지, 파손 확률, 물을 모두 계산한다.
-- 수동 충돌 파손은 Rules.applyRoverHit, 그 자리 R 수리는 Rules.repairRover(수동 고장 = status "broken" + 왕복 없음).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Rules = require(ReplicatedStorage.Shared.Rules)
local MissionWorld = require(script.Parent.MissionWorld)
local PromptKit = require(script.Parent.PromptKit)
local RoverRig = require(script.Parent.RoverRig)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

local RoverFleet = {}

-- 엔진 수준 값 (배터리 양, 소모, 부스터 배율과 시간, 수리비는 MissionConfig.MANUAL_DRIVE)
RoverFleet.CONFIG = {
    tickSeconds = 0.25,
    publishSeconds = 0.5, -- 배터리 값만 바뀌었을 때 StateUpdate 최소 간격
    movingSpeed = 1, -- 이보다 빠를 때만 배터리 소모 (studs/s)
    chargeRatePerSecond = 2, -- v1 Config.ROVER
    chargeRadius = 10, -- 섀시에서 주차판, 귀환 자리 중심까지 수평 거리
    baseRadius = 25, -- 이 안이면 "기지에 있음" (자율주행 출발, 원격 끌어오기 판정)
    lowBatteryRatio = 0.25,
    recoverBatteryRatio = 0.2,
    boostMinBatteryRatio = 0.2,
    -- 이 태그(또는 Attribute BoulderLayer)가 붙은 파트나 모델에 세게 부딪혀도 충돌 파손 (B 바위용, 설치한 태양광 패널.
    -- MissionWorld.CONFIG.solar.hazardTag와 같아야 한다). 패널은 고정이라 부서지지 않고 로버만 파손 1
    hazardTag = "RoverHazard",
    boardDistance = 10,
    repairDistance = 8,
    collectRadius = 20, -- 얼음 채취: 섀시에서 MinePoint까지 수평 거리
    unloadRadius = 18, -- 하역: 섀시에서 하역 자리나 귀환 자리까지 수평 거리
    -- 자율주행 출발 연출 (Q8): 출구 쪽으로 exitDistance만큼 달려 나간 뒤 사라진다. 착륙선과 에어록이 주차판과 출구 사이에
    -- 있어 출구까지 곧게 가면 건물을 뚫고 지나가므로 짧게만 달린다
    exitDistance = 40,
    exitSpeed = 20, -- studs/s
    animHz = 15,
    flipUpY = 0.3,
    flipSeconds = 3,
    fallDepth = 20, -- 가장 낮은 기지, 얼음 지면보다 이만큼 아래면 추락으로 보고 자동 복구
    recoverCooldownSeconds = 15,
    probeUp = 200, -- 고장 위치 지면 찾기 광선
    probeDepth = 600,
}
local CFG = RoverFleet.CONFIG

-- 충돌 감지 수치 (서버 소유. MissionConfig.MANUAL_DRIVE에 같은 이름이 생기면 그 값을 쓴다)
-- 새 맵은 디자이너 Terrain이라 바위 파트가 없다. 그래서 무엇에 부딪히든(Terrain, 파트) "운전 중 수평 속도가 짧은 시간에
-- 크게 떨어짐"을 충돌로 본다: impactWindowSeconds 안의 최고 속도가 impactSpeed 이상이었고 지금 속도가 그 impactDropRatio
-- 미만이면 1회. 같은 충돌의 연속 신호는 impactCooldownSeconds 안에서 한 번으로 센다
RoverFleet.MANUAL_DRIVE = {
    impactSpeed = 12, -- studs/s (v1 ROVER_DAMAGE.speedThreshold)
    impactDropRatio = 0.5,
    impactWindowSeconds = 0.25,
    impactCooldownSeconds = 1, -- v1 ROVER_DAMAGE.hitCooldown
    impactSettleSeconds = 1, -- 구동 배율이 바뀐 직후(SEP 정지, 방전, 고장)와 순간이동 직후는 이 시간 동안 보지 않는다
}

local function impact(name: string): number
    local shared = (MissionConfig.MANUAL_DRIVE :: any)[name]
    if typeof(shared) == "number" then
        return shared
    end
    return (RoverFleet.MANUAL_DRIVE :: any)[name]
end

local flow: any = nil
local initialized = false

local rover: Model? = nil
local seat: VehicleSeat? = nil
local chassis: BasePart? = nil
local rideHeight = 2
local floorY = -math.huge -- 이보다 fallDepth 아래면 추락 (기지와 얼음 후보지 중 가장 낮은 지면)
local hidden = false -- 자율주행 중 (Parent = nil)
local inField = false -- 고장으로 들판에 멈춰 보이는 중
local exiting = false
local dispatching = false
local takingOver = false -- 걸어서 수리 뒤 대원이 고장 자리에서 로버를 넘겨받는 중 (그 자리에 둔다)
local exitToken = 0

local battery = MissionConfig.MANUAL_DRIVE.batteryMax
local tank = 0
local boosting = false
local boostHeat = 0
local overheated = false
local charging = false
local chargeBlocked: Msg.Msg? = nil -- 충전판 위, 배터리가 덜 찼는데 충전이 안 되는 이유 (S6)
local weatherHold = false
local warnedLow = false
local notifiedFull = true
local emptyNotified = false
local lastPosition: Vector3? = nil
local lastPublish = -math.huge
local lastHitAt = -math.huge
local speedHistory: { { t: number, speed: number } } = {} -- 최근 impactWindowSeconds 동안 운전 중 수평 속도
local settleUntil = 0 -- 이 시각 전에는 급정거 감지를 하지 않는다
local lastMultiplier = -1
local flippedSince: number? = nil
local recoverCooldownUntil = 0
local boostLoop: Sfx.Handle? = nil
local firstBoard: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local connections: { RBXScriptConnection } = {}
local boardPrompt: ProximityPrompt? = nil
local repairPrompt: ProximityPrompt? = nil
local applyDrive: (() -> ())? = nil

local function manual(): any
    return MissionConfig.MANUAL_DRIVE
end

local function roverDef(): any
    local m = if flow then flow.mission() else nil
    return if m then m.rover else MissionConfig.MISSIONS.C.rover
end

local function tankMax(): number
    local m = if flow then flow.mission() else nil
    local ice = if m then m.ice else MissionConfig.MISSIONS.C.ice
    return ice.amountPerTrip
end

local function rulesState(): any
    return if flow then flow.rules() else nil
end

local function rulesStatus(): string
    local state = rulesState()
    return if state then state.rover.status else "parked"
end

-- 자율주행 왕복 중 고장인지 (들판에 멈춰 보이고 걸어서 수리나 원격 회수). 수동 고장은 왕복이 없다
local function fsdBroken(state: any?): boolean
    return state ~= nil and state.rover.status == "broken" and state.rover.trip ~= nil
end

local function rulesDamage(): number
    local state = rulesState()
    return if state then state.rover.damage else 0
end

local function flat(a: Vector3, b: Vector3): number
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function chassisPosition(): Vector3?
    local body = chassis
    if body and rover and rover.Parent ~= nil then
        return body.CFrame.Position
    end
    return nil
end

local function driverOf(): Player?
    local s = seat
    if not s then
        return nil
    end
    return ServerUtil.playerFromHumanoid(s.Occupant)
end

-- 섀시가 주차판이나 귀환 자리에서 radius 안인지
local function nearPads(radius: number): boolean
    local position = chassisPosition()
    if not position then
        return false
    end
    for _, id in { "roverPark", "roverDock" } do
        local pad = MissionWorld.anchor(id)
        if pad and flat(position, pad.CFrame.Position) <= radius then
            return true
        end
    end
    return false
end

function RoverFleet.isAtBase(): boolean
    return not hidden and not inField and nearPads(CFG.baseRadius)
end

-- 운전석 (보이는 로버만)
function RoverFleet.seat(): VehicleSeat?
    local s = seat
    if s and rover and rover.Parent ~= nil then
        return s
    end
    return nil
end

function RoverFleet.model(): Model?
    return rover
end

function RoverFleet.tankAmount(): number
    return tank
end

-- 속도 배율 --------------------------------------------------------------

local function speedMultiplier(): number
    local def = roverDef()
    local damage = rulesDamage()
    local damageFactor = if damage >= def.maxDamage
        then 0
        else math.max(0, 1 - def.slowdownPerDamage * damage)
    local batteryFactor = if battery > 0 then 1 else 0
    local boostFactor = if boosting then manual().v1BoostMultiplier else 1
    local weatherFactor = if weatherHold then 0 else 1
    local playing = if flow and flow.phase() == "playing" then 1 else 0
    return damageFactor * batteryFactor * boostFactor * weatherFactor * playing
end

local function refreshDrive()
    local apply = applyDrive
    if apply then
        apply()
    end
end

local function setAttr(name: string, value: any)
    local model = rover
    if model and model:GetAttribute(name) ~= value then
        model:SetAttribute(name, value)
    end
end

local function setChassisAttr(name: string, value: any)
    local body = chassis
    if body and body:GetAttribute(name) ~= value then
        body:SetAttribute(name, value)
    end
end

local function batteryPercent(): number
    local max = manual().batteryMax
    return math.clamp(math.floor(battery / math.max(max, 1e-6) * 100 + 0.5), 0, 100)
end

-- 섀시 Attribute: Charging(boolean), BatteryPercent(0 ~ 100 정수), ChargeBlocked(문구 키 또는 nil),
-- ChargeBlockedArgs(JSON 또는 nil). 클라이언트가 충전 중인지와 못 하는 이유를 그린다 (2026-11-15 시험 피드백)
local function refreshChargeAttrs()
    setChassisAttr("Charging", charging)
    setChassisAttr("BatteryPercent", batteryPercent())
    local blocked = chargeBlocked
    setChassisAttr("ChargeBlocked", if blocked then blocked.key else nil)
    setChassisAttr("ChargeBlockedArgs", if blocked then PromptKit.encode(blocked.args) else nil)
end

-- 수리 프롬프트 비용 (PromptKit.setCost): 에너지 repairEnergy, 지금 기지 에너지로 낼 수 있는지
function RoverFleet.refreshCosts()
    local repair = repairPrompt
    if not repair or repair.Parent == nil then
        return
    end
    local cost = roverDef().repairEnergy
    local state = rulesState()
    PromptKit.setCost(repair, {
        energy = cost,
        affordable = if state then state.energy + 1e-6 >= cost else nil,
    })
end

-- 프롬프트 ----------------------------------------------------------------

function RoverFleet.refresh()
    local status = rulesStatus()
    local playing = flow ~= nil and flow.phase() == "playing"
    local s = seat
    local empty = s == nil or s.Occupant == nil
    local board = boardPrompt
    if board then
        PromptKit.setEnabled(board, playing and empty and not inField and not hidden)
    end
    local repair = repairPrompt
    if repair then
        local need = if fsdBroken(rulesState()) then inField else rulesDamage() > 0
        PromptKit.setEnabled(repair, playing and empty and not hidden and need)
    end
    setAttr("Tank", tank)
    setAttr("Boosting", boosting)
    setAttr("Status", if inField then "broken" else status)
    refreshChargeAttrs()
    RoverFleet.refreshCosts()
    refreshDrive()
end

-- 부스터 ----------------------------------------------------------------

local function stopBoostLoop()
    local handle = boostLoop
    boostLoop = nil
    if handle then
        handle.stop()
    end
end

local function setBoosting(on: boolean)
    if boosting == on then
        return
    end
    boosting = on
    if on then
        boostLoop = Sfx.loop("rover_boost_loop", chassis)
    else
        stopBoostLoop()
    end
    setAttr("Boosting", on)
    refreshDrive()
    if flow then
        flow.markDirty()
    end
end

function RoverFleet.requestBoost(player: Player, on: any)
    if typeof(on) ~= "boolean" or not flow or flow.phase() ~= "playing" then
        return
    end
    if driverOf() ~= player or on == boosting then
        return
    end
    if on then
        local max = manual().batteryMax
        if overheated or weatherHold or battery < max * CFG.boostMinBatteryRatio then
            return
        end
    end
    setBoosting(on)
end

local function boostTick(dt: number, seatEmpty: boolean)
    local m = manual()
    if boosting and (seatEmpty or battery < m.batteryMax * CFG.boostMinBatteryRatio) then
        setBoosting(false)
    end
    if boosting then
        boostHeat = math.min(1, boostHeat + dt / m.v1BoostOnSeconds)
        if boostHeat >= 1 then
            overheated = true
            setBoosting(false)
        end
    else
        boostHeat = math.max(0, boostHeat - dt / m.v1BoostCooldownSeconds)
        if overheated and boostHeat <= 0 then
            overheated = false
            Sfx.play("rover_boost_ready", chassis)
        end
    end
end

-- 충돌 파손 ----------------------------------------------------------------

local function isHazard(hit: Instance): boolean
    local current: Instance? = hit
    while current and current ~= workspace do
        if current:GetAttribute("BoulderLayer") ~= nil then
            return true
        end
        local inst = current :: Instance
        local ok, tagged = pcall(function()
            return inst:HasTag(CFG.hazardTag)
        end)
        tagged = ok and tagged == true
        if tagged then
            return true
        end
        current = current.Parent
    end
    return false
end

-- 바위 충돌 한 번 (Touched와 테스트가 같은 경로). 파손을 셌으면 true
function RoverFleet.registerHit(speed: number): boolean
    if not flow or flow.phase() ~= "playing" or speed < impact("impactSpeed") then
        return false
    end
    local state = rulesState()
    if not state or state.rover.status ~= "parked" then
        return false
    end
    local now = os.clock()
    if now - lastHitAt < impact("impactCooldownSeconds") then
        return false
    end
    lastHitAt = now
    -- 파손 1, 2는 toast.rover.damaged, 3이면 수동 고장(status broken, 왕복 없음)과 toast.rover.broken_manual
    local ok = flow.act(nil, Rules.applyRoverHit, { okKind = "warn" })
    if not ok then
        return false
    end
    Sfx.play("rover_hit", chassis)
    if rulesStatus() == "broken" then
        Sfx.play("rover_broken", chassis)
    end
    RoverFleet.refresh()
    return true
end

local function resetImpact(seconds: number?)
    table.clear(speedHistory)
    settleUntil = math.max(settleUntil, os.clock() + (seconds or impact("impactSettleSeconds")))
end

-- 급정거 감지 (Heartbeat마다, 테스트도 같은 경로). 충돌로 셌으면 true
function RoverFleet.sampleImpact(now: number, velocity: Vector3): boolean
    local s = seat
    local body = chassis
    if not s or not body or s.Occupant == nil or hidden or inField or exiting or body.Anchored then
        table.clear(speedHistory)
        return false
    end
    if now < settleUntil or s.ThrottleFloat < 0 then
        -- 순간이동, 구동 배율 변화 직후와 후진(브레이크) 중에는 급정거로 보지 않는다
        table.clear(speedHistory)
        return false
    end
    local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
    local window = impact("impactWindowSeconds")
    local peak = 0
    local keep = {}
    for _, sample in speedHistory do
        if now - sample.t <= window then
            table.insert(keep, sample)
            peak = math.max(peak, sample.speed)
        end
    end
    speedHistory = keep
    table.insert(speedHistory, { t = now, speed = speed })
    if peak >= impact("impactSpeed") and speed < peak * impact("impactDropRatio") then
        table.clear(speedHistory)
        return RoverFleet.registerHit(peak)
    end
    return false
end

-- 배치와 숨김 ----------------------------------------------------------------

local function setAnchored(on: boolean)
    local model = rover
    if not model then
        return
    end
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            d.Anchored = on
            if not on then
                d.AssemblyLinearVelocity = Vector3.zero
                d.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end
end

local function runtimeParent(): Instance?
    return MissionWorld.runtimeFolder()
end

local function padCFrame(id: string): CFrame?
    if id == "roverPark" then
        return MissionWorld.roverParkCFrame()
    end
    local pad = MissionWorld.anchor(id)
    if not pad then
        return nil
    end
    return pad.CFrame * CFrame.new(0, pad.Size.Y / 2, 0)
end

local function placeAt(ground: CFrame, anchored: boolean)
    local model = rover
    local parent = runtimeParent()
    if not model or not parent then
        return
    end
    model.Parent = parent
    setAnchored(true)
    model:PivotTo(ground * CFrame.new(0, rideHeight, 0))
    setAnchored(anchored)
    hidden = false
    lastPosition = nil
    flippedSince = nil
    resetImpact()
end

local function hide()
    exitToken += 1
    exiting = false
    local model = rover
    if model then
        ServerUtil.unseat(seat and seat.Occupant)
        setAnchored(true)
        model.Parent = nil
    end
    hidden = true
    inField = false
    setBoosting(false)
end

-- 기지 출구까지 달려가 사라진다 (Q8)
local function driveOut()
    local model = rover
    local exitFrame = MissionWorld.exitCFrame()
    if not model or not exitFrame or model.Parent == nil then
        hide()
        return
    end
    exitToken += 1
    local token = exitToken
    exiting = true
    setAnchored(true)
    local start = model:GetPivot()
    local from = start.Position
    local toExit = Vector3.new(exitFrame.Position.X - from.X, 0, exitFrame.Position.Z - from.Z)
    local distance = math.min(CFG.exitDistance, toExit.Magnitude)
    local dir = if toExit.Magnitude > 1e-3 then toExit.Unit else exitFrame.LookVector
    local target = from + dir * distance
    local finish = CFrame.lookAt(target, target + dir)
    local steps = math.max(1, math.floor(distance / CFG.exitSpeed * CFG.animHz))
    task.spawn(function()
        for i = 1, steps do
            task.wait(1 / CFG.animHz)
            if token ~= exitToken then
                return
            end
            model:PivotTo(start:Lerp(finish, i / steps))
        end
        if token == exitToken then
            hide()
            RoverFleet.refresh()
            if flow then
                flow.markDirty()
            end
        end
    end)
end

-- 고장 위치: 출구에서 얼음 후보지 쪽으로 brokenDistance만큼
local function brokenGround(state: any): CFrame?
    local exitFrame = MissionWorld.exitCFrame()
    local trip = state.rover.trip
    if not exitFrame or not trip then
        return nil
    end
    local site = state.sites[trip.siteIndex]
    local target: Vector3? = nil
    for _, info in MissionWorld.iceSites() do
        if site and info.markerName == site.id then
            target = info.position
        end
    end
    local origin = exitFrame.Position
    local dir = if target
        then Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
        else exitFrame.LookVector
    if dir.Magnitude < 1e-3 then
        dir = Vector3.new(0, 0, -1)
    end
    dir = dir.Unit
    local point = origin + dir * state.rover.brokenDistance
    local y = origin.Y
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = { terrain }
        local hit = workspace:Raycast(
            Vector3.new(point.X, origin.Y + CFG.probeUp, point.Z),
            Vector3.new(0, -CFG.probeDepth, 0),
            params
        )
        if hit then
            y = hit.Position.Y
        end
    end
    local at = Vector3.new(point.X, y, point.Z)
    return CFrame.lookAt(at, at + dir)
end

local function showBroken(state: any)
    exitToken += 1
    exiting = false
    local ground = brokenGround(state)
    if ground then
        placeAt(ground, true)
        inField = true
    end
end

local function showAtDock()
    exitToken += 1
    exiting = false
    inField = false
    local ground = padCFrame("roverDock") or padCFrame("roverPark")
    if ground then
        placeAt(ground, false)
    end
end

-- Rules 상태가 바뀔 때 (MissionFlow가 commit마다 부른다)
function RoverFleet.onRulesChanged(prev: any, new: any)
    if not new then
        return
    end
    local was = if prev then prev.rover.status else "parked"
    local now = new.rover.status
    if now == "fsd" then
        if not dispatching and not exiting and not hidden then
            hide()
        end
    elseif now == "broken" then
        -- 자율주행 고장만 들판 자리에 보인다. 수동 고장은 그 자리에 그대로 (속도 0)
        if fsdBroken(new) and not inField then
            showBroken(new)
        end
    elseif now == "parked" and (was == "fsd" or fsdBroken(prev)) then
        if takingOver and inField then
            -- 고친 자리에서 직접 운전으로 넘어간다: 보이는 채로 물리를 켠다
            exitToken += 1
            inField = false
            setAnchored(false)
            lastPosition = nil
        else
            showAtDock()
        end
    end
    RoverFleet.refresh()
end

-- 우주 기상 SEP 동안 직접 운전 정지 (Q15)
function RoverFleet.setWeatherHold(on: boolean)
    weatherHold = on
    if on then
        setBoosting(false)
    end
    refreshDrive()
end

-- 복구 ------------------------------------------------------------------

local function notifyTankLost()
    if tank > 0 and flow then
        flow.notifyAll(Msg.new("toast.rover.tank_lost", { amount = tank }), "warn")
    end
    tank = 0
end

local buildRover: () -> ()

-- 주차판으로 되돌린다 (탱크의 물은 잃고 배터리는 최소 비율까지). 성공하면 true
function RoverFleet.recover(): boolean
    if hidden or inField then
        return false
    end
    if not rover or not seat or not chassis or (rover :: Model).Parent == nil then
        buildRover()
    else
        ServerUtil.unseat(seat.Occupant)
        local ground = padCFrame("roverPark")
        if not ground then
            return false
        end
        placeAt(ground, false)
    end
    notifyTankLost()
    local minimum = manual().batteryMax * CFG.recoverBatteryRatio
    if battery < minimum then
        battery = minimum
    end
    setBoosting(false)
    recoverCooldownUntil = os.clock() + CFG.recoverCooldownSeconds
    Sfx.play("rover_recover", chassis)
    if flow then
        flow.notifyAll(Msg.new("toast.rover.brought_back"), "info")
        flow.markDirty()
    end
    RoverFleet.refresh()
    return true
end

local function autoCheck(now: number)
    if hidden or inField or exiting or not flow or flow.phase() ~= "playing" then
        flippedSince = nil
        return
    end
    local cooling = now < recoverCooldownUntil
    local s = seat
    local model = rover
    if not s or not model or model.Parent == nil or not s:IsDescendantOf(workspace) then
        if not cooling then
            RoverFleet.recover()
        end
        return
    end
    if s.CFrame.Position.Y < floorY - CFG.fallDepth then
        if not cooling then
            RoverFleet.recover()
        end
        return
    end
    local flipped = s.Occupant == nil and s.CFrame.UpVector.Y < CFG.flipUpY
    if not flipped then
        flippedSince = nil
        return
    end
    if flippedSince == nil then
        flippedSince = now
    elseif now - (flippedSince :: number) >= CFG.flipSeconds and not cooling then
        RoverFleet.recover()
    end
end

-- 배터리와 충전 (주기마다) --------------------------------------------------------

function RoverFleet.step(dt: number)
    if not flow or flow.phase() ~= "playing" then
        return
    end
    autoCheck(os.clock())
    local position = chassisPosition()
    if hidden or inField or not position then
        lastPosition = nil
        if charging or chargeBlocked then
            charging = false
            chargeBlocked = nil
            refreshChargeAttrs()
            flow.markDirty()
        end
        return
    end
    local m = manual()
    local s = seat
    local seatEmpty = s == nil or s.Occupant == nil
    local previous = lastPosition
    lastPosition = position
    local speed = if previous and dt > 0 then (position - previous).Magnitude / dt else 0
    local before = battery
    local wasCharging = charging
    if speed > CFG.movingSpeed and battery > 0 then
        local drain = m.batteryDrainPerSecond
            * dt
            * (if boosting then m.boostDrainMultiplier else 1)
        battery = math.max(0, battery - drain)
    end
    boostTick(dt, seatEmpty)
    charging = false
    local wasBlocked = chargeBlocked
    chargeBlocked = nil
    local onPad = battery < m.batteryMax and nearPads(CFG.chargeRadius)
    if onPad and seatEmpty then
        local state = rulesState()
        if state then
            -- Rules.payEnergy("rover_charge")가 기지 에너지 MANUAL_DRIVE.chargeKeepEnergy를 남긴다
            local want = math.min(CFG.chargeRatePerSecond * dt, m.batteryMax - battery)
            if want > 0 then
                local ok, new, paid = Rules.payEnergy(state, MissionConfig, want, "rover_charge")
                if ok and paid > 0 then
                    battery = math.min(m.batteryMax, battery + paid)
                    charging = true
                    flow.commit(new, { publish = false })
                else
                    -- 기지 에너지가 남겨 둘 양 이하라 충전기가 멈췄다 (예전에는 아무 표시 없이 멈췄다)
                    chargeBlocked = Msg.new(
                        "hud.rover.charge_blocked_energy",
                        { keep = m.chargeKeepEnergy or 0 }
                    )
                end
            end
        end
    elseif onPad and speed <= CFG.movingSpeed then
        -- 운전석이 비어야 충전한다 (판 위를 지나가는 중에는 알리지 않는다)
        chargeBlocked = Msg.new("hud.rover.charge_blocked_seat")
    end
    local blockChanged = (wasBlocked and wasBlocked.key) ~= (chargeBlocked and chargeBlocked.key)
    -- 알림
    if battery <= 0 and before > 0 then
        if not emptyNotified then
            emptyNotified = true
            flow.notifyAll(Msg.new("toast.rover.battery_empty"), "warn")
        end
        refreshDrive()
    elseif battery > 0 and before <= 0 then
        emptyNotified = false
        refreshDrive()
    end
    local low = m.batteryMax * CFG.lowBatteryRatio
    if battery <= low and battery > 0 and not warnedLow then
        warnedLow = true
        flow.notifyAll(
            Msg.new(
                "toast.rover.battery_low",
                { percent = math.floor(battery / m.batteryMax * 100 + 0.5) }
            ),
            "warn"
        )
        Sfx.play("rover_battery_low", chassis)
    elseif battery > low then
        warnedLow = false
    end
    if charging and battery >= m.batteryMax and not notifiedFull then
        notifiedFull = true
        flow.notifyAll(Msg.new("toast.rover.charged"), "good")
        Sfx.play("rover_charge_full", chassis)
    elseif battery < m.batteryMax then
        notifiedFull = false
    end
    refreshChargeAttrs()
    local now = os.clock()
    if
        charging ~= wasCharging
        or blockChanged
        or (battery ~= before and now - lastPublish >= CFG.publishSeconds)
    then
        lastPublish = now
        flow.markDirty()
    end
end

-- 로버 만들기와 연결 --------------------------------------------------------------

local function onOccupantChanged()
    local s = seat
    if not s then
        return
    end
    local player = ServerUtil.playerFromHumanoid(s.Occupant)
    Sfx.play(if player then "rover_board" else "rover_exit", s)
    if player and not firstBoard[player] and flow then
        firstBoard[player] = true
        flow.notify(player, Msg.new("toast.rover.first_board"), "info")
    end
    if not player then
        setBoosting(false)
    end
    RoverFleet.refresh()
    if flow then
        flow.markDirty()
    end
end

local function onBoard(player: Player)
    local s = seat
    local body = chassis
    if not s or not body or s.Occupant ~= nil or hidden or inField then
        return
    end
    if not flow or flow.phase() ~= "playing" then
        return
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
        return
    end
    if not PromptKit.near(player, body, CFG.boardDistance + 6) then
        return
    end
    s:Sit(humanoid)
end

-- 그 자리 R 수리: Rules.repairRover (주차 중 파손, 수동 고장 모두. 에너지 repairEnergy, SEP 중 불가)
local function repairParked(player: Player): boolean
    return (flow.act(player, Rules.repairRover))
end

-- 들판에서 고장 난 자율주행 로버를 걸어가서 고친다 (Q30, Q37, 리드 결정 2026-11-14):
-- Rules.walkRepairRover로 고친 뒤 자율주행을 끝내고 직접 운전으로 넘긴다. 고친 대원은 운전석에 앉고(좌석이 산소를
-- 채운다, Q28) 직접 몰고 돌아온다. 이미 캔 물은 로버 탱크에 남아 물탱크에서 하역한다.
-- 자율주행 끝내기는 Rules에 함수가 없어 Rules.copy 뒤 rover.status = "parked", trip = nil로 바꾼다 (열린 질문)
local function walkRepair(player: Player)
    local carried = 0
    takingOver = true
    local ok = flow.act(player, function(state, config)
        local fixed, new, msg = Rules.walkRepairRover(state, config)
        if not fixed then
            return fixed, new, msg
        end
        local trip = new.rover.trip
        carried = if trip and trip.collected then trip.carrying else 0
        new.rover.status = "parked"
        new.rover.recovering = false
        new.rover.trip = nil
        new.rover.brokenDistance = 0
        return true, new, msg
    end)
    takingOver = false
    if not ok then
        return
    end
    tank = math.max(tank, carried)
    flow.contribute(player, "repairs", 1)
    Sfx.play("rover_repair", chassis)
    local s = seat
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if s and humanoid and humanoid.Health > 0 and s.Occupant == nil then
        s:Sit(humanoid)
    end
    flow.notify(player, Msg.new("toast.rover.repaired_drive_back"), "info")
    RoverFleet.refresh()
    flow.markDirty()
end

local function onRepair(player: Player)
    if not flow then
        return
    end
    local s = seat
    if s and s.Occupant ~= nil then
        flow.notify(player, Msg.new("toast.rover.occupied"), "warn")
        return
    end
    if fsdBroken(rulesState()) then
        walkRepair(player)
        return
    end
    if repairParked(player) then
        flow.contribute(player, "repairs", 1)
        Sfx.play("rover_repair", chassis)
        RoverFleet.refresh()
    end
end

buildRover = function()
    local old = rover
    if old then
        old:Destroy()
    end
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    applyDrive = nil
    boardPrompt = nil
    repairPrompt = nil
    local parent = runtimeParent()
    local ground = padCFrame("roverPark")
    if not parent or not ground then
        warn(
            "[RoverFleet] MissionRuntime 또는 로버 주차 자리가 없어 로버를 만들지 않습니다"
        )
        rover, seat, chassis = nil, nil, nil
        return
    end
    local model = RoverRig.build(ground, parent)
    rover = model
    local body = model.PrimaryPart :: BasePart
    chassis = body
    local s = model:FindFirstChild("DriverSeat") :: VehicleSeat
    seat = s
    rideHeight = body.CFrame.Position.Y - ground.Position.Y
    -- 추락 기준: 주차판, 출구, 얼음 후보지 중 가장 낮은 지면 (Ice4는 기지보다 약 26 낮은 크레이터 안)
    floorY = ground.Position.Y
    local exitFrame = MissionWorld.exitCFrame()
    if exitFrame then
        floorY = math.min(floorY, exitFrame.Position.Y)
    end
    for _, site in MissionWorld.iceSites() do
        floorY = math.min(floorY, site.position.Y)
    end
    hidden = false
    inField = false
    lastPosition = nil

    boardPrompt = PromptKit.make(body, {
        name = "BoardPrompt",
        actionKey = "prompt.act.board",
        objectKey = "world.rover.name",
        hold = 0,
        distance = CFG.boardDistance,
        enabled = false,
    })
    repairPrompt = PromptKit.make(body, {
        name = "RepairPrompt",
        actionKey = "prompt.act.repair_rover",
        objectKey = "world.rover.name",
        hold = manual().repairSeconds,
        distance = CFG.repairDistance,
        keyCode = Enum.KeyCode.R,
        enabled = false,
    })
    table.insert(connections, (boardPrompt :: ProximityPrompt).Triggered:Connect(onBoard))
    table.insert(connections, (repairPrompt :: ProximityPrompt).Triggered:Connect(onRepair))
    table.insert(connections, s:GetPropertyChangedSignal("Occupant"):Connect(onOccupantChanged))

    -- 바퀴 구동 (v1 RoverDrive)
    local driveHinges: { HingeConstraint } = {}
    local steerHinges: { HingeConstraint } = {}
    for _, d in model:GetDescendants() do
        if d:IsA("HingeConstraint") then
            local role = d:GetAttribute("RoverRole")
            if role == "Drive" then
                table.insert(driveHinges, d)
            elseif role == "Steer" then
                table.insert(steerHinges, d)
            end
        end
        if d:IsA("BasePart") then
            table.insert(
                connections,
                d.Touched:Connect(function(hit: BasePart)
                    if isHazard(hit) then
                        local peak = 0
                        for _, sample in speedHistory do
                            peak = math.max(peak, sample.speed)
                        end
                        RoverFleet.registerHit(
                            math.max(peak, body.AssemblyLinearVelocity.Magnitude)
                        )
                    end
                end)
            )
        end
    end
    local rig = RoverRig.CONFIG
    local function update()
        local throttle, steer = 0, 0
        if s.Occupant ~= nil then
            throttle = math.clamp(s.ThrottleFloat, -1, 1)
            steer = math.clamp(s.SteerFloat, -1, 1)
        end
        local multiplier = speedMultiplier()
        if multiplier ~= lastMultiplier then
            -- 배율이 바뀌면(SEP 정지, 방전, 고장, 부스터) 바퀴가 급히 서거나 빨라지므로 잠깐 감지를 쉰다
            if multiplier < lastMultiplier then
                resetImpact()
            end
            lastMultiplier = multiplier
        end
        for _, hinge in driveHinges do
            local radius = hinge:GetAttribute("WheelRadius")
            local wheelRadius = if typeof(radius) == "number" and radius > 0
                then radius
                else rig.wheelRadius
            hinge.MotorMaxTorque = s.Torque
            hinge.AngularVelocity = throttle * s.MaxSpeed * multiplier / wheelRadius * rig.driveSign
        end
        for _, hinge in steerHinges do
            hinge.TargetAngle = steer * rig.steerAngle * rig.steerSign
        end
    end
    table.insert(connections, s:GetPropertyChangedSignal("ThrottleFloat"):Connect(update))
    table.insert(connections, s:GetPropertyChangedSignal("SteerFloat"):Connect(update))
    table.insert(connections, s:GetPropertyChangedSignal("Occupant"):Connect(update))
    table.insert(
        connections,
        RunService.Heartbeat:Connect(function()
            RoverFleet.sampleImpact(os.clock(), body.AssemblyLinearVelocity)
        end)
    )
    applyDrive = update
    update()
    RoverFleet.refresh()
end

-- 기지가 놓인 뒤 (부팅, MissionWorld.reset 뒤)
function RoverFleet.attach()
    buildRover()
end

function RoverFleet.detach()
    exitToken += 1
    exiting = false
    dispatching = false
    stopBoostLoop()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    applyDrive = nil
    local old = rover
    if old then
        pcall(function()
            old:Destroy()
        end)
    end
    rover, seat, chassis = nil, nil, nil
    boardPrompt, repairPrompt = nil, nil
    hidden, inField = false, false
end

-- 새 판: 배터리 가득, 탱크 비움
function RoverFleet.reset()
    battery = manual().batteryMax
    tank = 0
    boosting = false
    boostHeat = 0
    overheated = false
    charging = false
    chargeBlocked = nil
    weatherHold = false
    warnedLow = false
    notifiedFull = true
    emptyNotified = false
    recoverCooldownUntil = 0
    lastHitAt = -math.huge
    table.clear(speedHistory)
    settleUntil = 0
    lastMultiplier = -1
    stopBoostLoop()
    RoverFleet.refresh()
end

-- 요청 처리 ----------------------------------------------------------------

local function validSite(siteIndex: any): boolean
    local state = rulesState()
    return typeof(siteIndex) == "number"
        and siteIndex % 1 == 0
        and state ~= nil
        and state.sites[siteIndex] ~= nil
end

-- 얼음 채취 (얼음 후보지 프롬프트, 운전석의 플레이어)
function RoverFleet.collect(player: Player, siteIndex: number, point: BasePart?)
    if not flow or flow.phase() ~= "playing" then
        return
    end
    local s = seat
    if not s or driverOf() ~= player or hidden or inField then
        flow.notify(player, Msg.new("toast.rover.need_driver"), "warn")
        return
    end
    local position = chassisPosition()
    if point and position and flat(position, point.CFrame.Position) > CFG.collectRadius then
        flow.notify(player, Msg.new("toast.rover.need_driver"), "warn")
        return
    end
    if tank > 0 then
        flow.notify(player, Msg.new("toast.rover.tank_full"), "warn")
        return
    end
    local ok = flow.act(player, function(state, config)
        return Rules.collectIce(state, config, siteIndex)
    end)
    if ok then
        tank = tankMax()
        Sfx.play("ice_collected", chassis)
        RoverFleet.refresh()
        flow.markDirty()
    end
end

-- 물 하역 (물탱크 하역 자리 프롬프트)
function RoverFleet.unload(player: Player)
    if not flow or flow.phase() ~= "playing" then
        return
    end
    if tank <= 0 then
        flow.act(player, function(state, config)
            return Rules.deliverWater(state, config, 0)
        end)
        return
    end
    local position = chassisPosition()
    local near = false
    if position and not hidden and not inField then
        for _, id in { "unloadPoint", "roverDock" } do
            local pad = MissionWorld.anchor(id)
            if pad and flat(position, pad.CFrame.Position) <= CFG.unloadRadius then
                near = true
            end
        end
    end
    if not near then
        flow.notify(player, Msg.new("toast.rover.not_here"), "warn")
        return
    end
    local amount = tank
    local ok = flow.act(player, function(state, config)
        return Rules.deliverWater(state, config, amount)
    end)
    if ok then
        tank = 0
        flow.contribute(player, "water", amount)
        Sfx.play("water_unload", chassis)
        RoverFleet.refresh()
        flow.markDirty()
    end
end

-- 자율주행 파견 (솔로만, 콘솔 근처, 로버가 기지에 비어 있을 때)
function RoverFleet.dispatch(player: Player, siteIndex: any, rush: any)
    if not flow or flow.phase() ~= "playing" then
        return
    end
    if not validSite(siteIndex) then
        return
    end
    local rushOn = rush == true
    if flow.mode() ~= "solo" then
        flow.notify(player, Msg.new("toast.rover.solo_only"), "warn")
        return
    end
    if not flow.nearConsole(player) then
        flow.notify(player, Msg.new("toast.console.too_far"), "warn")
        return
    end
    if rulesStatus() == "parked" then
        local s = seat
        if s and s.Occupant ~= nil then
            flow.notify(player, Msg.new("toast.rover.occupied"), "warn")
            return
        end
        if rover and not RoverFleet.isAtBase() then
            flow.notify(player, Msg.new("toast.rover.not_home"), "warn")
            return
        end
    end
    dispatching = true
    local ok = flow.act(player, function(state, config)
        return Rules.dispatchRover(state, config, siteIndex, rushOn)
    end)
    dispatching = false
    if ok then
        setBoosting(false)
        driveOut()
        RoverFleet.refresh()
    end
end

-- 원격 회수: 자율주행 고장이면 Rules.remoteRecoverRover, 직접 운전 로버가 기지 밖에 서 있으면 주차판으로 끌어온다
function RoverFleet.remoteRecover(player: Player)
    if not flow or flow.phase() ~= "playing" then
        return
    end
    if not flow.nearConsole(player) then
        flow.notify(player, Msg.new("toast.console.too_far"), "warn")
        return
    end
    local state = rulesState()
    local status = rulesStatus()
    if fsdBroken(state) then
        local ok = flow.act(player, Rules.remoteRecoverRover)
        if ok then
            RoverFleet.refresh()
        end
        return
    end
    -- 직접 운전 로버(주차 중이거나 수동 고장)가 기지 밖에 서 있으면 주차판으로 끌어온다. 수동 고장은 그대로 남아
    -- 기지에서 R로 고친다
    if (status == "parked" or status == "broken") and rover and not RoverFleet.isAtBase() then
        local s = seat
        if s and s.Occupant ~= nil then
            flow.notify(player, Msg.new("toast.rover.occupied"), "warn")
            return
        end
        local remaining = recoverCooldownUntil - os.clock()
        if remaining > 0 then
            flow.notify(player, Msg.count("toast.rover.recover_wait", math.ceil(remaining)), "info")
            return
        end
        RoverFleet.recover()
        return
    end
    flow.act(player, Rules.remoteRecoverRover)
end

-- MissionState.rover (CONTRACT_V2 5절 + 화면용 추가 필드)
function RoverFleet.view(state: any): { [string]: any }
    local m = manual()
    local def = roverDef()
    local status = state.rover.status
    local s = seat
    local occupied = s ~= nil and s.Occupant ~= nil and not hidden
    local shown = status
    if status == "parked" and (occupied or (rover ~= nil and not RoverFleet.isAtBase())) then
        shown = "driving"
    end
    local view: { [string]: any } = {
        state = shown,
        damage = state.rover.damage,
        maxDamage = def.maxDamage,
        battery = math.floor(battery * 10 + 0.5) / 10,
        batteryMax = m.batteryMax,
        tank = tank,
        tankMax = tankMax(),
        boosting = boosting,
        boostHeat = math.floor(boostHeat * 100 + 0.5) / 100,
        charging = charging,
        chargeBlocked = chargeBlocked, -- Msg 또는 nil (섀시 Attribute ChargeBlocked와 같은 이유)
        batteryPercent = batteryPercent(),
        atBase = RoverFleet.isAtBase(),
        fsd = Rules.roverFsdView(state, MissionConfig),
    }
    -- 보이는 로버의 지면 좌표 (StreamingEnabled로 로버 모델이 클라이언트에 없을 때 지도용). 숨김이면 없음
    local position = chassisPosition()
    if position and not hidden then
        view.x = math.floor(position.X * 10 + 0.5) / 10
        view.z = math.floor(position.Z * 10 + 0.5) / 10
    end
    if status == "broken" then
        local trip = state.rover.trip
        view.broken = {
            manual = trip == nil, -- 직접 운전 중 충돌 3회: 그 자리에서 R 수리
            siteIndex = if trip then trip.siteIndex else nil,
            position = if trip then trip.position else nil,
            distance = state.rover.brokenDistance,
            walkable = Rules.canWalkRepair(state, MissionConfig),
        }
    end
    return view
end

function RoverFleet.init(api: any)
    flow = api
    if initialized then
        return
    end
    initialized = true
    Remotes.get("RoverBoost").OnServerEvent:Connect(function(player: Player, on: any)
        ServerUtil.safeCall("RoverBoost", RoverFleet.requestBoost, player, on)
    end)
    Remotes.get("DispatchRover").OnServerEvent
        :Connect(function(player: Player, siteIndex: any, rush: any)
            ServerUtil.safeCall("DispatchRover", RoverFleet.dispatch, player, siteIndex, rush)
        end)
    Remotes.get("RemoteRecoverRover").OnServerEvent:Connect(function(player: Player)
        ServerUtil.safeCall("RemoteRecoverRover", RoverFleet.remoteRecover, player)
    end)
    task.spawn(function()
        while true do
            task.wait(CFG.tickSeconds)
            ServerUtil.safeCall("RoverFleet", RoverFleet.step, CFG.tickSeconds)
        end
    end)
end

return RoverFleet
