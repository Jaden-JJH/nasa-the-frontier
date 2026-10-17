--!strict
-- 순수 시뮬레이션 계산 (CONTRACT 3절)
-- Roblox 전역(game, script, task, Instance 등)을 쓰지 않는다. 서버와 Lune 테스트가 같은 코드를 쓴다.
-- 모든 함수는 입력 state를 바꾸지 않고 새 테이블을 돌려준다.
-- 아래 typeof(require(...))는 타입 검사 전용이며 실행 시에는 평가되지 않는다.

type Config = typeof(require("./Config"))
type ModuleDef = typeof(require("./Config").MODULES.A)

export type Phase = "selecting" | "landing" | "playing" | "won" | "lost"
export type ModuleStatus = "locked" | "available" | "building" | "active"
export type EndResult = "none" | "won" | "lost"
export type NoticeKind = "info" | "warn" | "good" -- Types.NotifyKind와 같은 값 (순환 require를 피해 여기 둔다)

-- 튜토리얼과 목표 단계 (CONTRACT missionStage). 클라이언트가 목표 대상 Highlight에 쓴다
export type MissionStage =
    "panels"
    | "board_rover"
    | "find_ice"
    | "unload"
    | "build_A"
    | "build_B"
    | "build_C"
    | "done"

export type Shortfall = { energy: number, water: number }
export type DaysLeft = { water: number, food: number }

export type ModuleState = {
    status: ModuleStatus,
    progress: number, -- 0..1, building일 때만 의미
    daysLeft: number, -- building일 때 남은 일수, 아니면 0
    unlocked: boolean, -- 선행 조건(앞 모듈 완공) 충족 여부. 비용과 무관
    shortfall: Shortfall, -- 착공 비용 대비 부족량 (충분하거나 이미 착공, 완공했으면 0)
    paused: boolean, -- 가동 중지 (2026-10-18, 현재 Farm만). true면 유지비와 생산 모두 없음. 선행 조건과 저장 상한은 그대로
    upkeepText: string, -- 표지판용 한 줄 "물 -2/일, 전력 -6/일, 식량 +2/일", 가동 중지면 "대기 중"
}

-- 키는 "A", "B", "C" (CONTRACT: { A: ModuleState, B: ModuleState, C: ModuleState })
export type Modules = { [string]: ModuleState }

-- damage 0..ROVER_DAMAGE.maxDamage, broken = damage >= maxDamage (CONTRACT 2026-10-18)
-- battery 0..batteryMax, charging = 충전 패드 위 빈 좌석에서 충전 중 (CONTRACT 2026-10-18)
-- away = 서버 추가 필드: 섀시가 충전 패드에서 ROVER.awayDistance보다 멀다 (미션 문구용)
export type RoverState = {
    tank: number,
    tankMax: number,
    damage: number,
    broken: boolean,
    battery: number,
    batteryMax: number,
    charging: boolean,
    away: boolean,
    boosting: boolean, -- 부스터 작동 중 (2026-10-18)
    boostHeat: number, -- 0..1 과열 게이지. 1에 닿으면 부스트가 꺼지고 0까지 식어야 다시 쓸 수 있다
}

export type GameState = {
    phase: Phase,
    day: number,
    totalDays: number,
    speed: number,
    energy: number,
    water: number,
    food: number,
    netEnergy: number,
    netWater: number,
    netFood: number,
    panelsInstalled: number,
    panelsInstalledToday: number,
    panelsTotal: number,
    panelsPerDay: number,
    modules: Modules,
    rover: RoverState,
    siteId: number?,
    siteName: string?,
    sunlight: number?,
    missionText: string,
    waterTrips: number,
    oxygenDeaths: number,
    shortageDays: number,
    modulesStalled: boolean, -- CONTRACT 추가 필드: 마지막 DayTick에 전력 부족으로 모듈이 멈췄는지
    missionStage: MissionStage, -- 현재 목표 단계. missionText는 이 값에서 파생
    daysLeft: DaysLeft, -- 지금 순소비율로 버틸 수 있는 일수 (내림 정수, 순소비 0 이하이면 NO_DEPLETION_DAYS)
    stallReason: string, -- 모듈 정지 사유 한 줄, 정지 아니면 ""
    energyCap: number, -- 에너지 저장 상한 = ENERGY_CAP_BASE + 가동 모듈 수 x ENERGY_CAP_PER_MODULE
    energyWasted: number, -- 서버 추가 필드: 마지막 DayTick에 상한 때문에 버려진 발전량 (없으면 0)
}

local Simulation = {}

-- 단계 순서. 단계는 이 순서로만 앞으로 간다 (unload에서 탱크를 잃은 경우만 find_ice로 되돌린다)
local STAGE_ORDER: { MissionStage } =
    { "panels", "board_rover", "find_ice", "unload", "build_A", "build_B", "build_C", "done" }
local NO_DEPLETION_DAYS = 999 -- 줄지 않는 자원의 남은 일수 표시값

-- 내부 도우미 ------------------------------------------------------------

local function roundResource(value: number, config: Config): number
    local scale = 10 ^ config.RESOURCE_DECIMALS
    return math.floor(value * scale + 0.5) / scale
end

local function clampMin0(value: number): number
    if value < 0 then
        return 0
    end
    return value
end

local function int(value: number): number
    return math.floor(value + 0.5)
end

local function newModule(status: ModuleStatus, progress: number, daysLeft: number): ModuleState
    return {
        status = status,
        progress = progress,
        daysLeft = daysLeft,
        unlocked = false,
        shortfall = { energy = 0, water = 0 },
        paused = false,
        upkeepText = "",
    }
end

local function copyModules(modules: Modules): Modules
    local out: Modules = {}
    for id, m in modules do
        out[id] = {
            status = m.status,
            progress = m.progress,
            daysLeft = m.daysLeft,
            unlocked = m.unlocked,
            shortfall = { energy = m.shortfall.energy, water = m.shortfall.water },
            paused = m.paused,
            upkeepText = m.upkeepText,
        }
    end
    return out
end

-- 가동 중이고 멈추지 않은 모듈 (유지비와 생산이 있는 모듈)
local function running(m: ModuleState?): boolean
    return m ~= nil and m.status == "active" and not m.paused
end

local function stageIndex(stage: MissionStage): number
    return table.find(STAGE_ORDER, stage) or 1
end

-- 상태 깊은 복사. 서버는 이 복사본을 고쳐서 ResourceState.set에 넘긴다.
function Simulation.copy(state: GameState): GameState
    return {
        phase = state.phase,
        day = state.day,
        totalDays = state.totalDays,
        speed = state.speed,
        energy = state.energy,
        water = state.water,
        food = state.food,
        netEnergy = state.netEnergy,
        netWater = state.netWater,
        netFood = state.netFood,
        panelsInstalled = state.panelsInstalled,
        panelsInstalledToday = state.panelsInstalledToday,
        panelsTotal = state.panelsTotal,
        panelsPerDay = state.panelsPerDay,
        modules = copyModules(state.modules),
        rover = {
            tank = state.rover.tank,
            tankMax = state.rover.tankMax,
            damage = state.rover.damage,
            broken = state.rover.broken,
            battery = state.rover.battery,
            batteryMax = state.rover.batteryMax,
            charging = state.rover.charging,
            away = state.rover.away,
            boosting = state.rover.boosting,
            boostHeat = state.rover.boostHeat,
        },
        siteId = state.siteId,
        siteName = state.siteName,
        sunlight = state.sunlight,
        missionText = state.missionText,
        waterTrips = state.waterTrips,
        oxygenDeaths = state.oxygenDeaths,
        shortageDays = state.shortageDays,
        modulesStalled = state.modulesStalled,
        missionStage = state.missionStage,
        daysLeft = { water = state.daysLeft.water, food = state.daysLeft.food },
        stallReason = state.stallReason,
        energyCap = state.energyCap,
        energyWasted = state.energyWasted,
    }
end

local function prerequisitesActive(state: GameState, config: Config, moduleId: string): boolean
    local def = config.MODULES[moduleId]
    for _, req in def.requires do
        local m = state.modules[req]
        if not m or m.status ~= "active" then
            return false
        end
    end
    return true
end

-- locked 모듈 중 선행 조건이 모두 가동 중인 것을 available로 바꾼다 (복사본을 직접 고친다)
local function refreshLocks(state: GameState, config: Config)
    for _, id in config.MODULE_ORDER do
        local m = state.modules[id]
        if m and m.status == "locked" and prerequisitesActive(state, config, id) then
            m.status = "available"
        end
    end
end

-- 가동 중 모듈의 하루 유지 소비 합계
local function activeUpkeep(state: GameState, config: Config): (number, number)
    local energy, water = 0, 0
    for _, id in config.MODULE_ORDER do
        local m = state.modules[id]
        if running(m) then
            local def = config.MODULES[id]
            energy += def.upkeep.energy
            water += def.upkeep.water
        end
    end
    return energy, water
end

local function panelEnergy(state: GameState, config: Config): number
    return state.panelsInstalled * config.PANEL_OUTPUT * (state.sunlight or 0)
end

-- 에너지 저장 상한: 기본 + 가동 모듈 수 x 모듈당
function Simulation.energyCap(state: GameState, config: Config): number
    local active = 0
    for _, id in config.MODULE_ORDER do
        local m = state.modules[id]
        if m and m.status == "active" then
            active += 1
        end
    end
    return config.ENERGY_CAP_BASE + active * config.ENERGY_CAP_PER_MODULE
end

-- 오늘 모듈 유지 에너지를 내면 0 아래로 내려가는지 (모듈 정지 규칙)
function Simulation.isStalled(state: GameState, config: Config): boolean
    local upkeepEnergy = activeUpkeep(state, config)
    return state.energy + panelEnergy(state, config) - upkeepEnergy < 0
end

-- 바닥난 자원의 한국어 이름 ("물", "식량", "물과 식량")
function Simulation.shortageName(state: GameState, config: Config): string
    local t = config.TEXTS
    if state.water <= 0 and state.food <= 0 then
        return t.waterAndFoodKo
    elseif state.water <= 0 then
        return t.waterKo
    end
    return t.foodKo
end

-- 공개 API ---------------------------------------------------------------

-- 새 게임의 초기 상태 (phase = selecting, day = 0)
function Simulation.newState(config: Config): GameState
    local modules: Modules = {}
    for _, id in config.MODULE_ORDER do
        modules[id] = newModule("locked", 0, 0)
    end
    local state: GameState = {
        phase = "selecting",
        day = 0,
        totalDays = config.TOTAL_DAYS,
        speed = config.SPEEDS[1],
        energy = config.START.energy,
        water = config.START.water,
        food = config.START.food,
        netEnergy = 0,
        netWater = 0,
        netFood = 0,
        panelsInstalled = 0,
        panelsInstalledToday = 0,
        panelsTotal = config.PANELS_TOTAL,
        panelsPerDay = config.PANELS_PER_DAY,
        modules = modules,
        rover = {
            tank = 0,
            tankMax = config.ROVER.tankMax,
            damage = 0,
            broken = false,
            battery = config.ROVER.batteryMax,
            batteryMax = config.ROVER.batteryMax,
            charging = false,
            away = false,
            boosting = false,
            boostHeat = 0,
        },
        siteId = nil,
        siteName = nil,
        sunlight = nil,
        missionText = "",
        waterTrips = 0,
        oxygenDeaths = 0,
        shortageDays = 0,
        modulesStalled = false,
        missionStage = "panels",
        daysLeft = { water = 0, food = 0 },
        stallReason = "",
        energyCap = config.ENERGY_CAP_BASE,
        energyWasted = 0,
    }
    refreshLocks(state, config)
    Simulation.refreshDerived(state, config)
    return state
end

-- 하루 생산량: 패널 발전과 Farm 식량. 물 생산은 없다 (물은 로버 원정으로만 얻는다)
-- Farm은 가동 중이고, 그날 에너지(모듈 정지 아님)와 물 수요를 채울 수 있을 때만 생산한다
function Simulation.dailyProduction(state: GameState, config: Config): (number, number, number)
    local energy = panelEnergy(state, config)
    local water = 0
    local food = 0
    if not Simulation.isStalled(state, config) then
        local _, upkeepWater = activeUpkeep(state, config)
        local waterNeedMet = state.water + water >= config.CREW.water + upkeepWater
        if waterNeedMet then
            for _, id in config.MODULE_ORDER do
                if running(state.modules[id]) then
                    food += config.MODULES[id].foodPerDay
                end
            end
        end
    end
    return energy, water, food
end

-- 하루 소비량: 크루 생명유지 + 가동 중 모듈 유지. 모듈 정지 날에는 모듈 유지 소비가 없다
function Simulation.dailyConsumption(state: GameState, config: Config): (number, number, number)
    local energy = 0
    local water = config.CREW.water
    local food = config.CREW.food
    if not Simulation.isStalled(state, config) then
        local upkeepEnergy, upkeepWater = activeUpkeep(state, config)
        energy += upkeepEnergy
        water += upkeepWater
    end
    return energy, water, food
end

-- 하루 처리 (DayTick 1회). 순서:
-- 1) 생산 계산 2) 소비 계산 (에너지가 0 아래로 가면 모듈 정지) 3) 자원 반영과 0 클램프
-- 4) 건설 중 모듈 하루 진행, 완료 시 가동 5) 잠금 해제 6) 에너지 상한(오늘 완공한 모듈 포함) 클램프
-- 7) 부족 연속 일수 8) 순증감, 다음 날
function Simulation.applyDay(state: GameState, config: Config): GameState
    local new = Simulation.copy(state)
    if state.phase ~= "playing" then
        return new
    end

    local prodEnergy, prodWater, prodFood = Simulation.dailyProduction(state, config)
    local consEnergy, consWater, consFood = Simulation.dailyConsumption(state, config)

    new.energy = clampMin0(roundResource(state.energy + prodEnergy - consEnergy, config))
    new.water = clampMin0(roundResource(state.water + prodWater - consWater, config))
    new.food = clampMin0(roundResource(state.food + prodFood - consFood, config))
    new.modulesStalled = Simulation.isStalled(state, config)

    -- 건설 진행 (건설 중에는 유지 소비 없음. 완공된 날 다음 날부터 유지 소비)
    for _, id in config.MODULE_ORDER do
        local m = new.modules[id]
        if m and m.status == "building" then
            local buildDays = config.MODULES[id].buildDays
            m.daysLeft = math.max(0, m.daysLeft - 1)
            if m.daysLeft <= 0 then
                m.status = "active"
                m.progress = 1
                m.daysLeft = 0
            else
                m.progress = (buildDays - m.daysLeft) / buildDays
            end
        end
    end
    refreshLocks(new, config)

    -- 저장 상한: 넘친 발전은 버린다 (energyWasted로 알림)
    local cap = Simulation.energyCap(new, config)
    new.energyCap = cap
    new.energyWasted = roundResource(math.max(0, new.energy - cap), config)
    new.energy = math.min(new.energy, cap)

    if new.water <= 0 or new.food <= 0 then
        new.shortageDays = math.min(state.shortageDays + 1, config.SHORTAGE_DAYS_TO_LOSE)
    else
        new.shortageDays = 0
    end

    -- 순증감: 이번 DayTick 직전 값 대비 직후 값 (하루 동안의 생산 - 소비)
    new.netEnergy = roundResource(new.energy - state.energy, config)
    new.netWater = roundResource(new.water - state.water, config)
    new.netFood = roundResource(new.food - state.food, config)

    new.panelsInstalledToday = 0
    new.day = state.day + 1
    Simulation.refreshDerived(new, config)
    return new
end

-- 착공 가능 여부와 불가 사유(한국어)
function Simulation.canBuild(state: GameState, config: Config, moduleId: string): (boolean, string)
    local t = config.TEXTS
    local def = config.MODULES[moduleId]
    local m = state.modules[moduleId]
    if not def or not m then
        return false, t.unknownModule
    end
    if state.phase ~= "playing" then
        return false, t.notPlaying
    end
    if m.status == "building" then
        return false, t.alreadyBuilding
    end
    if m.status == "active" then
        return false, t.alreadyActive
    end

    local missing: { string } = {}
    for _, req in def.requires do
        local rm = state.modules[req]
        if not rm or rm.status ~= "active" then
            table.insert(missing, config.MODULES[req].displayName)
        end
    end
    if #missing > 0 or m.status ~= "available" then
        return false, string.format(t.needPrereq, table.concat(missing, t.listSeparator))
    end

    local lacking: { string } = {}
    if state.energy < def.cost.energy then
        table.insert(
            lacking,
            string.format(t.resourceAmount, t.resourceEnergy, int(def.cost.energy))
        )
    end
    if state.water < def.cost.water then
        table.insert(lacking, string.format(t.resourceAmount, t.resourceWater, int(def.cost.water)))
    end
    if #lacking > 0 then
        return false, string.format(t.notEnoughResources, table.concat(lacking, t.listSeparator))
    end
    return true, ""
end

-- 착공: 비용 즉시 차감, building으로 전환
function Simulation.startBuild(
    state: GameState,
    config: Config,
    moduleId: string
): (boolean, GameState, string)
    local ok, reason = Simulation.canBuild(state, config, moduleId)
    if not ok then
        return false, Simulation.copy(state), reason
    end
    local def = config.MODULES[moduleId]
    local new = Simulation.copy(state)
    new.energy = clampMin0(roundResource(new.energy - def.cost.energy, config))
    new.water = clampMin0(roundResource(new.water - def.cost.water, config))
    new.modules[moduleId] = newModule("building", 0, def.buildDays)
    Simulation.refreshDerived(new, config)
    return true, new, string.format(config.TEXTS.buildStarted, def.displayName, int(def.buildDays))
end

-- 패널 1장 설치 (하루 한도와 전체 한도 확인)
function Simulation.installPanel(state: GameState, config: Config): (boolean, GameState, string)
    local t = config.TEXTS
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), t.notPlaying
    end
    if state.panelsInstalled >= config.PANELS_TOTAL then
        return false, Simulation.copy(state), t.panelsFull
    end
    if state.panelsInstalledToday >= config.PANELS_PER_DAY then
        return false, Simulation.copy(state), t.panelLimit
    end
    local new = Simulation.copy(state)
    new.panelsInstalled += 1
    new.panelsInstalledToday += 1
    Simulation.refreshDerived(new, config)
    local message = string.format(
        t.panelInstalled,
        new.panelsInstalledToday,
        config.PANELS_PER_DAY,
        new.panelsInstalled,
        config.PANELS_TOTAL
    )
    return true, new, message
end

-- 로버 탱크 만충
function Simulation.fillTank(state: GameState, config: Config): (boolean, GameState, string)
    local t = config.TEXTS
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), t.notPlaying
    end
    if state.rover.tank >= state.rover.tankMax then
        return false, Simulation.copy(state), t.tankAlreadyFull
    end
    local new = Simulation.copy(state)
    new.rover.tank = new.rover.tankMax
    Simulation.refreshDerived(new, config)
    return true, new, string.format(t.tankFilled, int(new.rover.tankMax))
end

-- 얼음 매장지에서 채취: fill = min(탱크 빈 공간, 매장량), 매장량 -= fill.
-- 반환: 성공 여부, 새 상태, 남은 매장량, 토스트 문구, 토스트 종류
function Simulation.fillFromDeposit(
    state: GameState,
    config: Config,
    deposit: number
): (boolean, GameState, number, string, NoticeKind)
    local t = config.TEXTS
    local remaining = math.max(0, deposit)
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), remaining, t.notPlaying, "info"
    end
    local space = state.rover.tankMax - state.rover.tank
    if space <= 0 then
        return false, Simulation.copy(state), remaining, t.tankAlreadyFull, "info"
    end
    if remaining <= 0 then
        return false, Simulation.copy(state), 0, t.iceDepleted, "info"
    end
    local fill = math.min(space, remaining)
    local new = Simulation.copy(state)
    new.rover.tank = roundResource(new.rover.tank + fill, config)
    remaining = roundResource(remaining - fill, config)
    Simulation.refreshDerived(new, config)
    return true, new, remaining, string.format(t.iceExtracted, int(fill), int(remaining)), "good"
end

-- 하역할 때 처리할 수 있는 물: 1 W당 WATER_PROCESS_ENERGY_PER_W 에너지
function Simulation.processableWater(state: GameState, config: Config): number
    local per = config.WATER_PROCESS_ENERGY_PER_W
    local amount = state.rover.tank
    if per > 0 then
        amount = math.min(amount, math.floor(state.energy / per + 1e-9))
    end
    return math.max(0, amount)
end

-- 로버 탱크를 기지 물에 하역. 처리 전력이 모자라면 처리 가능한 만큼만 하역하고 나머지는 탱크에 남긴다.
-- 반환: 성공 여부, 새 상태, 토스트 문구, 토스트 종류, 일부만 처리했을 때 경고 문구(아니면 nil)
function Simulation.unloadWater(
    state: GameState,
    config: Config
): (boolean, GameState, string, NoticeKind, string?)
    local t = config.TEXTS
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), t.notPlaying, "info", nil
    end
    local amount = state.rover.tank
    if amount <= 0 then
        return false, Simulation.copy(state), t.tankEmpty, "info", nil
    end
    local processed = Simulation.processableWater(state, config)
    if processed <= 0 then
        local message = string.format(t.waterNoEnergy, tostring(config.WATER_PROCESS_ENERGY_PER_W))
        return false, Simulation.copy(state), message, "warn", nil
    end
    local new = Simulation.copy(state)
    new.energy =
        clampMin0(roundResource(new.energy - processed * config.WATER_PROCESS_ENERGY_PER_W, config))
    new.water = roundResource(new.water + processed, config)
    new.rover.tank = roundResource(amount - processed, config)
    new.waterTrips += 1
    Simulation.refreshDerived(new, config)
    local warning = if processed < amount
        then string.format(t.waterPartial, int(processed))
        else nil
    return true, new, string.format(t.waterUnloaded, int(processed)), "good", warning
end

-- 로버 배터리 -------------------------------------------------------------

-- 주행 seconds초 소모. 반환: 새 상태, 이번에 0이 되었는지
function Simulation.drainBattery(
    state: GameState,
    config: Config,
    seconds: number
): (GameState, boolean)
    local new = Simulation.copy(state)
    local before = state.rover.battery
    new.rover.battery = math.max(0, before - config.ROVER.batteryDrainPerSecond * seconds)
    Simulation.refreshDerived(new, config)
    return new, before > 0 and new.rover.battery <= 0
end

-- 충전 seconds초: 기지 에너지에서 배터리로 min(속도 x 초, 빈 용량, 기지 에너지)만큼 옮긴다. 반환: 새 상태, 옮긴 양
function Simulation.chargeBattery(
    state: GameState,
    config: Config,
    seconds: number
): (GameState, number)
    local new = Simulation.copy(state)
    local amount = math.min(
        config.ROVER.chargeRatePerSecond * seconds,
        state.rover.batteryMax - state.rover.battery,
        state.energy
    )
    amount = math.max(0, amount)
    new.rover.battery += amount
    new.energy = clampMin0(new.energy - amount)
    Simulation.refreshDerived(new, config)
    return new, amount
end

-- 배터리가 낮은지 (0보다 크고 lowBatteryRatio 이하)
function Simulation.batteryLow(state: GameState, config: Config): boolean
    local r = state.rover
    return r.battery > 0 and r.battery <= r.batteryMax * config.ROVER.lowBatteryRatio
end

-- 로버 부스터 (2026-10-18) -----------------------------------------------

-- 부스트를 켤 수 있는지 (운전자 검사는 서버가 한다). overheated = 과열 뒤 아직 0까지 식지 않음
function Simulation.canBoost(state: GameState, config: Config, overheated: boolean): boolean
    local r = state.rover
    return state.phase == "playing"
        and not overheated
        and r.battery >= r.batteryMax * config.ROVER.boostMinBatteryRatio
end

-- 과열 게이지 dt초 진행: 부스트 중이면 초당 1/boostMaxSeconds 증가, 아니면 초당 1/boostCooldownSeconds 감소.
-- 1에 닿으면 부스트를 끈다. 반환: 새 상태, 이번에 과열로 꺼졌는지
function Simulation.boostTick(state: GameState, config: Config, dt: number): (GameState, boolean)
    local r = config.ROVER
    local new = Simulation.copy(state)
    local overheatedNow = false
    if state.rover.boosting then
        new.rover.boostHeat = math.min(1, state.rover.boostHeat + dt / r.boostMaxSeconds)
        if new.rover.boostHeat >= 1 - 1e-9 then
            new.rover.boostHeat = 1
            new.rover.boosting = false
            overheatedNow = true
        end
    else
        new.rover.boostHeat = math.max(0, state.rover.boostHeat - dt / r.boostCooldownSeconds)
    end
    return new, overheatedNow
end

-- 로버 파손 -------------------------------------------------------------

-- 파손 단계에 따른 최고 속도 배율 (maxDamage면 0)
function Simulation.roverSpeedMultiplier(damage: number, config: Config): number
    local d = config.ROVER_DAMAGE
    if damage >= d.maxDamage then
        return 0
    end
    return math.max(0, 1 - d.speedPenaltyPerDamage * damage)
end

-- 바위 충돌 1회: damage + 1 (최대 maxDamage). 반환: 새 상태, 실제로 늘었는지
function Simulation.applyRoverHit(state: GameState, config: Config): (GameState, boolean)
    local new = Simulation.copy(state)
    if state.rover.damage >= config.ROVER_DAMAGE.maxDamage then
        return new, false
    end
    new.rover.damage = state.rover.damage + 1
    Simulation.refreshDerived(new, config)
    return new, true
end

-- 수리: 에너지 repairEnergy를 내고 damage 0. 반환: 성공 여부, 새 상태, 토스트 문구, 토스트 종류
function Simulation.repairRover(
    state: GameState,
    config: Config
): (boolean, GameState, string, NoticeKind)
    local t = config.TEXTS
    local d = config.ROVER_DAMAGE
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), t.notPlaying, "info"
    end
    if state.rover.damage <= 0 then
        return false, Simulation.copy(state), t.repairNotNeeded, "info"
    end
    if state.energy < d.repairEnergy then
        return false,
            Simulation.copy(state),
            string.format(t.repairNeedEnergy, int(d.repairEnergy)),
            "warn"
    end
    local new = Simulation.copy(state)
    new.energy = clampMin0(roundResource(new.energy - d.repairEnergy, config))
    new.rover.damage = 0
    Simulation.refreshDerived(new, config)
    return true, new, t.repairDone, "good"
end

-- 산소 고갈 페널티: 기지 Food, Water 차감 (0 클램프), 고갈 횟수 증가
function Simulation.applyOxygenDeath(state: GameState, config: Config): GameState
    local penalty = config.OXYGEN.deathPenalty
    local new = Simulation.copy(state)
    new.food = clampMin0(roundResource(new.food - penalty.food, config))
    new.water = clampMin0(roundResource(new.water - penalty.water, config))
    new.oxygenDeaths += 1
    Simulation.refreshDerived(new, config)
    return new
end

-- 종료 판정. 같은 틱에 부족 실패와 C 완공이 함께 성립하면 실패를 먼저 본다 (물 없이 버틴 기지는 승리가 아니다).
-- 기한 초과는 승리 다음에 본다 (마지막 날 완공은 승리)
function Simulation.checkEnd(state: GameState, config: Config): (EndResult, string)
    local t = config.TEXTS
    if state.shortageDays >= config.SHORTAGE_DAYS_TO_LOSE then
        return "lost",
            string.format(
                t.endShortage,
                Simulation.shortageName(state, config),
                int(state.shortageDays)
            )
    end
    local win = state.modules[config.WIN_MODULE]
    if win and win.status == "active" then
        return "won", t.endWon
    end
    if state.day > config.TOTAL_DAYS then
        return "lost", string.format(t.endTimeout, int(config.TOTAL_DAYS))
    end
    return "none", ""
end

-- 종료 상태로 전환. applyDay가 이미 다음 날로 넘겼으므로 day를 마지막으로 끝낸 날로 되돌린다
function Simulation.finishGame(state: GameState, config: Config, result: EndResult): GameState
    local new = Simulation.copy(state)
    if result == "won" then
        new.phase = "won"
    elseif result == "lost" then
        new.phase = "lost"
    else
        return new
    end
    new.day = math.clamp(state.day - 1, 1, config.TOTAL_DAYS)
    Simulation.refreshDerived(new, config)
    return new
end

-- 상태만 보고 정할 수 있는 최소 단계 (탑승은 상태에 없으므로 markBoarded가 올린다)
local function stageFloor(state: GameState, config: Config): MissionStage
    local a, b, c = state.modules.A, state.modules.B, state.modules.C
    if c and c.status == "active" then
        return "done"
    elseif b and b.status == "active" then
        return "build_C"
    elseif a and (a.status == "building" or a.status == "active") then
        return "build_B"
    elseif state.waterTrips > 0 then
        return "build_A"
    elseif state.rover.tank > 0 then
        -- 매장량이 탱크보다 적으면 만충이 아니어도 물을 실었으면 하역 단계
        return "unload"
    elseif state.panelsInstalled >= config.PANELS_PER_DAY then
        return "board_rover"
    end
    return "panels"
end

-- 남은 일수: 보유량 / 하루 순소비(소비 - 생산), 내림 정수. 순소비가 0 이하이면 NO_DEPLETION_DAYS
local function daysOf(stock: number, netUse: number): number
    if netUse <= 0 then
        return NO_DEPLETION_DAYS
    end
    return math.min(NO_DEPLETION_DAYS, math.floor(math.max(stock, 0) / netUse))
end

-- 파생 필드를 다시 계산해 state(복사본)에 직접 쓴다:
-- missionStage(앞으로만), daysLeft, stallReason, 모듈별 unlocked와 shortfall, missionText
function Simulation.refreshDerived(state: GameState, config: Config)
    local stage: MissionStage = state.missionStage
    local floor: MissionStage = stageFloor(state, config)
    if stageIndex(floor) > stageIndex(stage) then
        stage = floor
    end
    -- 하역 전에 탱크를 잃으면(로버 복구) 다시 얼음을 찾는 단계로
    if stage == "unload" and state.rover.tank <= 0 and state.waterTrips == 0 then
        stage = "find_ice"
    end
    state.missionStage = stage

    local _, prodWater, prodFood = Simulation.dailyProduction(state, config)
    local _, useWater, useFood = Simulation.dailyConsumption(state, config)
    state.daysLeft = {
        water = daysOf(state.water, useWater - prodWater),
        food = daysOf(state.food, useFood - prodFood),
    }
    state.stallReason = if state.modulesStalled then config.TEXTS.stallReason else ""
    state.energyCap = Simulation.energyCap(state, config)
    state.rover.broken = state.rover.damage >= config.ROVER_DAMAGE.maxDamage

    for _, id in config.MODULE_ORDER do
        local m = state.modules[id]
        if m then
            local def = config.MODULES[id]
            m.unlocked = prerequisitesActive(state, config, id)
            if m.status == "building" or m.status == "active" then
                m.shortfall = { energy = 0, water = 0 }
            else
                m.shortfall = {
                    energy = roundResource(math.max(0, def.cost.energy - state.energy), config),
                    water = roundResource(math.max(0, def.cost.water - state.water), config),
                }
            end
            m.upkeepText = Simulation.upkeepText(m, def, config)
        end
    end
    state.missionText = Simulation.missionText(state, config)
end

-- 모듈 표지판 한 줄: 유지비와 생산 ("물 -2/일, 전력 -6/일, 식량 +2/일"), 가동 중지면 "대기 중"
function Simulation.upkeepText(m: ModuleState, def: ModuleDef, config: Config): string
    local t = config.TEXTS
    if m.paused then
        return t.upkeepPaused
    end
    local parts: { string } = {}
    if def.upkeep.water > 0 then
        table.insert(parts, string.format(t.upkeepWater, int(def.upkeep.water)))
    end
    if def.upkeep.energy > 0 then
        table.insert(parts, string.format(t.upkeepEnergy, int(def.upkeep.energy)))
    end
    if def.foodPerDay > 0 then
        table.insert(parts, string.format(t.upkeepFood, int(def.foodPerDay)))
    end
    return table.concat(parts, t.listSeparator)
end

-- 가동 중지 토글: canPause인 가동 중 모듈만. 반환: 성공 여부, 새 상태, 토스트 문구
function Simulation.setPaused(
    state: GameState,
    config: Config,
    moduleId: string,
    paused: boolean
): (boolean, GameState, string)
    local t = config.TEXTS
    local def = config.MODULES[moduleId]
    local m = state.modules[moduleId]
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), t.notPlaying
    end
    if not def or not m or not def.canPause or m.status ~= "active" then
        return false, Simulation.copy(state), t.cannotPause
    end
    local new = Simulation.copy(state)
    new.modules[moduleId].paused = paused
    Simulation.refreshDerived(new, config)
    local template = if paused then t.modulePaused else t.moduleResumed
    return true, new, string.format(template, def.name)
end

-- 로버에 처음 탑승: board_rover 이전 단계면 find_ice로 올린다
function Simulation.markBoarded(state: GameState, config: Config): GameState
    local new = Simulation.copy(state)
    if stageIndex(new.missionStage) < stageIndex("find_ice") then
        new.missionStage = "find_ice"
    end
    Simulation.refreshDerived(new, config)
    return new
end

-- 모듈 하나의 착공 안내 또는 건설 중 안내
local function buildText(state: GameState, config: Config, id: string): string?
    local texts = config.MISSION_TEXTS
    local m = state.modules[id]
    local def = config.MODULES[id]
    if not m or not def then
        return nil
    end
    if m.status == "building" then
        return string.format(texts.building, def.displayName, int(m.daysLeft))
    elseif m.status == "available" then
        local template = texts.build[id]
        if template then
            return string.format(template, int(def.cost.energy), int(def.cost.water))
        end
    end
    return nil
end

-- HUD 상단 미션 문구. phase 문구, 부족 경고, 그 외에는 missionStage에서 파생 (Config.MISSION_TEXTS)
function Simulation.missionText(state: GameState, config: Config): string
    local texts = config.MISSION_TEXTS
    local phase = state.phase
    if phase == "selecting" then
        return texts.selecting
    elseif phase == "landing" then
        return texts.landing
    elseif phase == "won" then
        return texts.won
    elseif phase == "lost" then
        return texts.lost
    end

    if state.water <= 0 or state.food <= 0 then
        local daysLeft = math.max(0, config.SHORTAGE_DAYS_TO_LOSE - state.shortageDays)
        return string.format(texts.shortage, Simulation.shortageName(state, config), int(daysLeft))
    end
    -- 로버 고장, 배터리 방전, 기지 밖 배터리 부족은 단계 문구보다 먼저 (부족 경고 다음)
    if state.rover.broken then
        return string.format(texts.roverBroken, int(config.ROVER_DAMAGE.repairEnergy))
    end
    if state.rover.battery <= 0 then
        return texts.batteryEmpty
    end
    if state.rover.away and Simulation.batteryLow(state, config) then
        return texts.batteryLow
    end

    local stage = state.missionStage
    if stage == "panels" then
        return string.format(
            texts.installPanels,
            int(math.max(1, config.PANELS_PER_DAY - state.panelsInstalled))
        )
    elseif stage == "board_rover" then
        return texts.boardRover
    elseif stage == "find_ice" then
        return texts.findIce
    elseif stage == "unload" then
        return texts.unloadWater
    elseif stage == "done" then
        return texts.won
    end
    -- build_X: 그 모듈 착공 안내. 아직 잠겨 있으면 건설 중인 앞 모듈의 남은 일수
    local target = string.sub(stage, 7)
    local direct = buildText(state, config, target)
    if direct then
        return direct
    end
    for _, id in config.MODULE_ORDER do
        local m = state.modules[id]
        if m and m.status == "building" then
            return buildText(state, config, id) or texts.won
        end
    end
    return texts.won
end

return Simulation
