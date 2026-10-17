--!strict
-- 순수 시뮬레이션 계산 (CONTRACT 3절)
-- Roblox 전역(game, script, task, Instance 등)을 쓰지 않는다. 서버와 Lune 테스트가 같은 코드를 쓴다.
-- 모든 함수는 입력 state를 바꾸지 않고 새 테이블을 돌려준다.
-- 아래 typeof(require(...))는 타입 검사 전용이며 실행 시에는 평가되지 않는다.

type Config = typeof(require("./Config"))

export type Phase = "selecting" | "landing" | "playing" | "won" | "lost"
export type ModuleStatus = "locked" | "available" | "building" | "active"
export type EndResult = "none" | "won" | "lost"

export type ModuleState = {
    status: ModuleStatus,
    progress: number, -- 0..1, building일 때만 의미
    daysLeft: number, -- building일 때 남은 일수, 아니면 0
}

-- 키는 "A", "B", "C" (CONTRACT: { A: ModuleState, B: ModuleState, C: ModuleState })
export type Modules = { [string]: ModuleState }

export type RoverState = { tank: number, tankMax: number }

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
}

local Simulation = {}

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

local function copyModules(modules: Modules): Modules
    local out: Modules = {}
    for id, m in modules do
        out[id] = { status = m.status, progress = m.progress, daysLeft = m.daysLeft }
    end
    return out
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
        rover = { tank = state.rover.tank, tankMax = state.rover.tankMax },
        siteId = state.siteId,
        siteName = state.siteName,
        sunlight = state.sunlight,
        missionText = state.missionText,
        waterTrips = state.waterTrips,
        oxygenDeaths = state.oxygenDeaths,
        shortageDays = state.shortageDays,
        modulesStalled = state.modulesStalled,
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
        if m and m.status == "active" then
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
        modules[id] = { status = "locked", progress = 0, daysLeft = 0 }
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
        rover = { tank = 0, tankMax = config.ROVER.tankMax },
        siteId = nil,
        siteName = nil,
        sunlight = nil,
        missionText = "",
        waterTrips = 0,
        oxygenDeaths = 0,
        shortageDays = 0,
        modulesStalled = false,
    }
    refreshLocks(state, config)
    state.missionText = Simulation.missionText(state, config)
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
                local m = state.modules[id]
                if m and m.status == "active" then
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
-- 4) 건설 중 모듈 하루 진행, 완료 시 가동 5) 잠금 해제 6) 부족 연속 일수 7) 순증감, 다음 날
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
    new.missionText = Simulation.missionText(new, config)
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
    new.modules[moduleId] = { status = "building", progress = 0, daysLeft = def.buildDays }
    new.missionText = Simulation.missionText(new, config)
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
    new.missionText = Simulation.missionText(new, config)
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
    return true, new, string.format(t.tankFilled, int(new.rover.tankMax))
end

-- 로버 탱크를 기지 물에 하역
function Simulation.unloadWater(state: GameState, config: Config): (boolean, GameState, string)
    local t = config.TEXTS
    if state.phase ~= "playing" then
        return false, Simulation.copy(state), t.notPlaying
    end
    local amount = state.rover.tank
    if amount <= 0 then
        return false, Simulation.copy(state), t.tankEmpty
    end
    local new = Simulation.copy(state)
    new.water = roundResource(new.water + amount, config)
    new.rover.tank = 0
    new.waterTrips += 1
    new.missionText = Simulation.missionText(new, config)
    return true, new, string.format(t.waterUnloaded, int(amount))
end

-- 산소 고갈 페널티: 기지 Food, Water 차감 (0 클램프), 고갈 횟수 증가
function Simulation.applyOxygenDeath(state: GameState, config: Config): GameState
    local penalty = config.OXYGEN.deathPenalty
    local new = Simulation.copy(state)
    new.food = clampMin0(roundResource(new.food - penalty.food, config))
    new.water = clampMin0(roundResource(new.water - penalty.water, config))
    new.oxygenDeaths += 1
    new.missionText = Simulation.missionText(new, config)
    return new
end

-- 종료 판정. 승리를 먼저 본다
function Simulation.checkEnd(state: GameState, config: Config): (EndResult, string)
    local t = config.TEXTS
    local win = state.modules[config.WIN_MODULE]
    if win and win.status == "active" then
        return "won", t.endWon
    end
    if state.shortageDays >= config.SHORTAGE_DAYS_TO_LOSE then
        return "lost",
            string.format(
                t.endShortage,
                Simulation.shortageName(state, config),
                int(state.shortageDays)
            )
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
    new.missionText = Simulation.missionText(new, config)
    return new
end

-- HUD 상단 미션 문구 (단계별, Config.MISSION_TEXTS)
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

    local first = state.modules[config.MODULE_ORDER[1]]
    local notStarted = first ~= nil and first.status == "available"
    if notStarted and state.panelsInstalled < config.PANELS_PER_DAY then
        return string.format(
            texts.installPanels,
            int(config.PANELS_PER_DAY - state.panelsInstalled)
        )
    end
    if notStarted and state.waterTrips == 0 then
        return texts.firstWaterTrip
    end

    for _, id in config.MODULE_ORDER do
        local m = state.modules[id]
        local def = config.MODULES[id]
        if m and m.status == "available" then
            local template = texts.build[id]
            if template then
                return string.format(template, int(def.cost.energy), int(def.cost.water))
            end
        elseif m and m.status == "building" then
            return string.format(texts.building, def.displayName, int(m.daysLeft))
        elseif m and m.status == "locked" then
            break
        end
    end
    return texts.won
end

return Simulation
