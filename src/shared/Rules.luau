--!strict
-- The Frontier v2 순수 규칙 (docs/V2_PLAN.md 15절 grill 결정이 기준, 숫자는 MissionConfig)
-- Roblox API를 쓰지 않는다. 서버, Lune 테스트, 봇 시뮬레이션이 같은 코드를 쓴다.
-- 모든 함수는 입력 state를 바꾸지 않고 새 테이블을 돌려준다.
-- 같은 seed, 같은 우주 기상 구간, 같은 행동이면 항상 같은 결과가 나온다 (난수 상태는 state.rngState).
-- 출력에는 문장을 넣지 않는다. 화면 문구는 Msg { key, args }와 열거형 문자열로만 내보낸다
-- (docs/I18N_PLAN.md 4.1, 4.5). 번역이 필요한 값(시설 이름, 자원 이름, 날짜)은 중첩 Msg로 넘긴다.
--
-- 하루 흐름: 플레이어 행동(이 모듈의 행동 함수들) -> applyDay(하루 마감) -> checkEnd -> 끝났으면 finish
-- state.day는 지금 진행 중인 날(1부터). applyDay는 그날을 마감하고 day를 1 올린다.

-- Msg 모듈(v2-i18n)로 키를 만든다. tools/i18n/lint.luau가 Msg.new("..."), Msg.count("..."), { key = "..." }의
-- 리터럴 키를 CSV와 대조하므로 키는 모두 리터럴로 쓰고, 동적 키는 리터럴 키 표 조회로만 고른다 (I18N_PLAN 4.2)
local Msg = require("./Msg")

type Config = typeof(require("./MissionConfig"))

export type Msg = { key: string, args: { [string]: any }? }
export type Outcome = "none" | "won" | "lost"
export type Medal = "gold" | "silver" | "bronze"

export type Facility = {
    id: string, -- 시설 인스턴스 id. 하나만 짓는 시설은 정의 id와 같고, 여러 개(파이프)는 "pipe1", "pipe2"
    defId: string,
    status: string, -- "building" | "active"
    daysLeft: number, -- 건설 중 남은 일수
    buildDays: number,
    paused: boolean, -- [Q33] 멈춤: 유지비 0, 효과도 멈춤
    progress: number, -- 생산 주기 진행 일수 (재배 수확, 파이프 공급)
    siteIndex: number?, -- 파이프가 연결된 얼음 지점
    startedDay: number,
    completedDay: number?,
}

export type Site = {
    id: string, -- 맵 표시 Part 이름 (Workspace.MissionC.Ice1 ~ Ice5)
    distance: number, -- 착륙선에서 수평 거리(studs)
    risk: string, -- 거리로 정한 경로 위험 "low" | "mid" | "high"
    cooldownLeft: number, -- 0이면 채취 가능
    pipeId: string?, -- 파이프가 연결(또는 건설 중)이면 그 시설 id. 로버로 못 캔다
}

export type Trip = {
    siteIndex: number,
    totalDays: number,
    elapsed: number,
    rush: boolean,
    risk: string, -- 실제로 굴린 위험 등급 (서둘러 가기면 한 단계 위)
    collected: boolean,
    carrying: number,
    damageAt: number?, -- 이번 왕복에서 파손이 나는 위치(왕복 진행 비율 0..1). nil이면 파손 없음
    position: number?, -- 고장으로 멈춘 위치(왕복 진행 비율)
}

export type Rover = {
    status: string, -- CONTRACT_V2 5절 로버 상태 중 규칙이 쓰는 것: "parked" | "fsd" | "broken" ("driving"은 서버의 수동 운전)
    recovering: boolean, -- status = "fsd"이면서 원격 회수로 기지에 돌아오는 중
    damage: number,
    trip: Trip?,
    recoverLeft: number,
    brokenDistance: number, -- 고장 위치의 착륙선 거리 (걸어서 수리 판정)
}

export type WeatherEvent = {
    kind: string, -- "SEP" | "GST"
    day: number,
    durationDays: number,
    kp: number?,
    sourceDate: { year: number, month: number, day: number }?,
}

export type WeatherWindow = {
    id: string,
    startDate: { year: number, month: number, day: number }?,
    events: { WeatherEvent },
}

export type ScoreCounts = { low: number, zero: number }

export type EndResult = {
    outcome: Outcome,
    medal: Medal?,
    reason: string?, -- "gold" | "timeout" | "shortage" | "noMedal"
    resource: string?, -- 부족 실패면 "water" | "food" | "both"
    daysTaken: number,
    msg: Msg?,
}

export type Deduction = {
    reason: string, -- "water_low" | "water_zero" | "food_low" | ... | "oxygen_rescue" (CSV score.deduct.* 끝)
    resource: string?,
    count: number,
    points: number, -- 깎인 점수 (양수, 화면의 "-"는 템플릿에 있다)
    msg: Msg,
}

export type ScoreReport = { start: number, score: number, deductions: { Deduction } }

export type State = {
    missionId: string,
    players: number, -- 판의 최대 인원 [Q6]. 대원 소비 인원 비례(MissionConfig crewScaling)에 쓴다
    phase: string, -- "playing" | "won" | "lost"
    day: number,
    totalDays: number,
    energy: number,
    water: number,
    food: number,
    cap: number,
    panels: number,
    panelsToday: number,
    facilities: { [string]: Facility },
    sites: { Site },
    rover: Rover,
    deliveries: number, -- 기지 하역 횟수 (자율주행 귀환 + 수동 하역). 파이프 해금 [Q10]
    shortageDays: number,
    stalled: boolean, -- 마지막 하루 마감에서 시설이 멈췄는지
    stallReason: string?, -- "energy" | "water"
    shed: { string }, -- 마지막 하루 마감에서 자원이 모자라 멈춘 시설 id (다음 날 새로 멈춘 것과 다시 돈 것을 가린다)
    crewEnergyShort: number, -- 마지막 하루 마감에서 못 낸 대원 에너지 (0이면 다 냄)
    oxygenRescues: number,
    score: { [string]: ScoreCounts }, -- 자원별 감점 일수
    stats: { [string]: number },
    weather: WeatherWindow, -- 바꾸지 않는다 (복사본끼리 공유)
    rngState: number,
    result: EndResult?,
}

local Rules = {}

-- 내부 도우미 ------------------------------------------------------------

local EPSILON = 1e-9
local LCG_MODULUS = 2147483647
local LCG_MULTIPLIER = 48271
local LCG_WARMUP = 3

-- 시설 이름 (리터럴 키 표, CONTRACT_V2 시설 id)
local FACILITY_NAMES: { [string]: Msg } = {
    airlock = { key = "facility.airlock.name" },
    farm = { key = "facility.farm.name" },
    led = { key = "facility.led.name" },
    nutrient = { key = "facility.nutrient.name" },
    pipe = { key = "facility.pipe.name" },
    hydroponics = { key = "facility.hydroponics.name" },
    tower = { key = "facility.tower.name" },
    powerline = { key = "facility.powerline.name" },
}

local MEDAL_NAMES: { [string]: Msg } = {
    gold = { key = "medal.gold.name" },
    silver = { key = "medal.silver.name" },
    bronze = { key = "medal.bronze.name" },
}

-- 표의 Msg는 공유하지 않고 새로 만들어 넘긴다 (받는 쪽이 고쳐도 표가 바뀌지 않게)
local function facilityName(defId: string): Msg
    local name = FACILITY_NAMES[defId]
    assert(name ~= nil, "no name key for facility " .. tostring(defId))
    return Msg.new(name.key)
end

local function medalName(medal: string): Msg
    return Msg.new(MEDAL_NAMES[medal].key)
end

-- 얼음 후보지 이름 "Ice Site 2" / "얼음 후보지 2" (표시 Part 이름 Ice2의 번호)
local function siteLabel(site: { id: string }): Msg
    return Msg.new("map.ice.label", { n = tonumber(string.match(site.id, "%d+")) or 0 })
end

local function round(value: number, config: Config): number
    local scale = 10 ^ config.RESOURCE_DECIMALS
    return math.floor(value * scale + 0.5) / scale
end

local function roundInt(value: number): number
    return math.floor(value + 0.5)
end

local function mission(config: Config, missionId: string): any
    local def = (config.MISSIONS :: any)[missionId]
    assert(def ~= nil, "unknown mission " .. tostring(missionId))
    return def
end

local function missionOf(state: State, config: Config): any
    return mission(config, state.missionId)
end

local function seedValue(seed: number): number
    local value = math.floor(math.abs(seed)) % LCG_MODULUS
    if value == 0 then
        value = 1
    end
    for _ = 1, LCG_WARMUP do
        value = (value * LCG_MULTIPLIER) % LCG_MODULUS
    end
    return value
end

-- 0..1 미만 난수. state를 직접 고친다 (복사본에만 쓴다)
local function nextRandom(state: State): number
    state.rngState = (state.rngState * LCG_MULTIPLIER) % LCG_MODULUS
    return state.rngState / LCG_MODULUS
end

local function copyFacility(f: Facility): Facility
    return table.clone(f)
end

-- 상태 복사. weather는 바꾸지 않는 값이라 공유한다
function Rules.copy(state: State): State
    local new = table.clone(state)
    local facilities: { [string]: Facility } = {}
    for id, f in state.facilities do
        facilities[id] = copyFacility(f)
    end
    new.facilities = facilities
    local sites: { Site } = {}
    for index, site in state.sites do
        sites[index] = table.clone(site)
    end
    new.sites = sites
    local rover = table.clone(state.rover)
    if state.rover.trip then
        rover.trip = table.clone(state.rover.trip :: Trip)
    end
    new.rover = rover
    local score: { [string]: ScoreCounts } = {}
    for resource, counts in state.score do
        score[resource] = table.clone(counts)
    end
    new.score = score
    new.stats = table.clone(state.stats)
    new.shed = table.clone(state.shed or {})
    if state.result then
        new.result = table.clone(state.result :: EndResult)
    end
    return new
end

local function normalizeWeather(window: any, config: Config): WeatherWindow
    local events: { WeatherEvent } = {}
    if window == nil then
        return { id = "none", startDate = nil, events = events }
    end
    for _, e in window.events or {} do
        local keep = e.kind == "SEP" or e.kind == "GST"
        if keep and e.kind == "GST" and e.kp ~= nil and e.kp < config.WEATHER.GST.minKp then
            keep = false
        end
        if keep and typeof(e.day) == "number" then
            table.insert(events, {
                kind = e.kind,
                day = e.day,
                durationDays = math.max(1, e.durationDays or 1),
                kp = e.kp,
                sourceDate = if e.sourceDate then table.clone(e.sourceDate) else nil,
            })
        end
    end
    table.sort(events, function(a, b)
        if a.day == b.day then
            return a.kind < b.kind
        end
        return a.day < b.day
    end)
    return {
        id = window.id or "unknown",
        startDate = if window.startDate then table.clone(window.startDate) else nil,
        events = events,
    }
end

local function eventActive(e: WeatherEvent, day: number): boolean
    return day >= e.day and day < e.day + e.durationDays
end

-- 그날의 우주 기상. 진행 중인 SEP, GST 사건(없으면 nil)
function Rules.weatherOn(state: State, day: number?): (WeatherEvent?, WeatherEvent?)
    local target = day or state.day
    local sep, gst = nil, nil
    for _, e in state.weather.events do
        if eventActive(e, target) then
            if e.kind == "SEP" and sep == nil then
                sep = e
            elseif e.kind == "GST" and gst == nil then
                gst = e
            end
        end
    end
    return sep, gst
end

local function sepToday(state: State): boolean
    local sep = Rules.weatherOn(state)
    return sep ~= nil
end

local function gstToday(state: State): boolean
    local _, gst = Rules.weatherOn(state)
    return gst ~= nil
end

-- 출처 한 줄 "NASA DONKI record, {date}" (Q36). 날짜는 Msg.date의 fmt.date.long (month_name 중첩 포함)
local function sourceMsg(e: WeatherEvent): Msg?
    local d = e.sourceDate
    if not d then
        return nil
    end
    return Msg.new("event.source", { date = Msg.date(d, "long") })
end

local function riskForDistance(roverDef: any, distance: number): string
    for _, level in roverDef.riskOrder do
        local def = roverDef.risk[level]
        if level ~= "extreme" and (def.maxDistance == nil or distance < def.maxDistance) then
            return level
        end
    end
    return "high"
end

local function nextRisk(roverDef: any, level: string): string
    local index = table.find(roverDef.riskOrder, level) or 1
    return roverDef.riskOrder[math.min(index + 1, #roverDef.riskOrder)]
end

-- 시설 조회 -------------------------------------------------------------

local function instancesOf(state: State, defId: string): { Facility }
    local list: { Facility } = {}
    for _, f in state.facilities do
        if f.defId == defId then
            table.insert(list, f)
        end
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

-- 완공한 인스턴스가 하나라도 있는지 (멈춤 여부와 무관). 선행 조건과 메달 판정에 쓴다
function Rules.isBuilt(state: State, defId: string): boolean
    for _, f in state.facilities do
        if f.defId == defId and f.status == "active" then
            return true
        end
    end
    return false
end

function Rules.builtCount(state: State, defId: string): number
    local count = 0
    for _, f in state.facilities do
        if f.defId == defId and f.status == "active" then
            count += 1
        end
    end
    return count
end

local function farmRunning(state: State): boolean
    local farm = state.facilities.farm
    return farm ~= nil and farm.status == "active" and not farm.paused
end

-- 오늘 유지비와 효과가 있는 시설인지. 업그레이드는 재배 공간이 돌아갈 때만 (재배 공간의 일부로 본다).
-- keep이 있으면 그 안의 시설만 돌아간다 (자원이 모자라 멈춘 시설을 뺀 집합, Rules.flows)
local function running(
    state: State,
    f: Facility,
    config: Config,
    keep: { [string]: boolean }?
): boolean
    if f.status ~= "active" or f.paused then
        return false
    end
    if keep and not keep[f.id] then
        return false
    end
    local def = missionOf(state, config).facilities[f.defId]
    if def.kind == "upgrade" then
        return farmRunning(state) and (keep == nil or keep.farm == true)
    end
    return true
end

local function upgradeRunning(
    state: State,
    defId: string,
    config: Config,
    keep: { [string]: boolean }?
): boolean
    local f = state.facilities[defId]
    return f ~= nil and running(state, f, config, keep)
end

-- 시설별 오늘 유지비 (멈춤, 정지 판정 전). HUD의 "시설별 숫자 유지비"와 하루 마감이 같이 쓴다
function Rules.upkeepBreakdown(
    state: State,
    config: Config,
    keep: { [string]: boolean }?
): (
    { { id: string, defId: string, energy: number, water: number } },
    number,
    number
)
    local m = missionOf(state, config)
    local list = {}
    local totalEnergy, totalWater = 0, 0
    local ids: { string } = {}
    for id in state.facilities do
        table.insert(ids, id)
    end
    table.sort(ids)
    for _, id in ids do
        local f = state.facilities[id]
        if running(state, f, config, keep) then
            local def = m.facilities[f.defId]
            local energy, water = def.upkeep.energy, def.upkeep.water
            if f.defId == "farm" then
                if upgradeRunning(state, "led", config, keep) then
                    energy *= m.facilities.led.farmEnergyUpkeepMultiplier or 1
                end
                if upgradeRunning(state, "nutrient", config, keep) then
                    water *= m.facilities.nutrient.farmWaterUpkeepMultiplier or 1
                end
            end
            energy, water = round(energy, config), round(water, config)
            table.insert(list, { id = id, defId = f.defId, energy = energy, water = water })
            totalEnergy += energy
            totalWater += water
        end
    end
    return list, round(totalEnergy, config), round(totalWater, config)
end

-- 오늘 하루의 예상 흐름 (행동 없이 마감하면). HUD와 봇이 쓴다
export type Flows = {
    panelEnergy: number,
    crew: { energy: number, water: number, food: number },
    upkeepEnergy: number,
    upkeepWater: number,
    stalled: boolean, -- 자원이 모자라 멈춘 시설이 하나라도 있는지
    stallReason: string?, -- "energy" | "water"
    running: { [string]: boolean }, -- 오늘 유지비와 효과가 있는 시설 id
    shed: { string }, -- 자원이 모자라 오늘 멈춘 시설 id (stallMode "priority"면 덜 중요한 것부터)
}

-- 하루 대원 소비. crewScaling이 켜져 있으면 2번째 대원부터 crewPerExtraPlayer씩 더한다 (끄면 인원과 무관)
function Rules.crewUse(
    state: State,
    config: Config
): { energy: number, water: number, food: number }
    local m = missionOf(state, config)
    local extra = if m.crewScaling then math.max(0, (state.players or 1) - 1) else 0
    local per = m.crewPerExtraPlayer or { energy = 0, water = 0, food = 0 }
    return {
        energy = m.crew.energy + extra * per.energy,
        water = m.crew.water + extra * per.water,
        food = m.crew.food + extra * per.food,
    }
end

-- 정지 판정은 지금 가진 양으로만 한다. 오늘 패널 발전은 소비를 뺀 뒤 들어와 다음 날 아침부터 쓴다 (applyDay 5단계).
-- 대원 소비를 먼저 떼고 남은 에너지와 물로 시설 유지비를 낸다. stallMode
--   "all": 다 못 내면 모든 시설이 멈춘다 (처음 구현)
--   "priority": shedOrder 앞쪽(덜 중요한 시설)부터 멈추고 나머지는 돌아간다. 재배 공간은 마지막까지 버틴다
function Rules.flows(state: State, config: Config): Flows
    local m = missionOf(state, config)
    local panelEnergy = state.panels * m.panels.output
    local crew = Rules.crewUse(state, config)
    -- crewEnergyLast: 시설 에너지 유지비를 대원 에너지보다 먼저 낸다 (대원 에너지 부족은 감점뿐이고 실패가 아니다, Q3)
    local energyLeft = if m.crewEnergyLast then state.energy else state.energy - crew.energy
    local waterLeft = state.water - crew.water
    local all: { [string]: boolean } = {}
    local ids: { string } = {}
    for id, f in state.facilities do
        if running(state, f, config) then
            all[id] = true
            table.insert(ids, id)
        end
    end
    local function fits(keep: { [string]: boolean }): (boolean, string?)
        local _, e, w = Rules.upkeepBreakdown(state, config, keep)
        if energyLeft < e - EPSILON then
            return false, "energy"
        elseif waterLeft < w - EPSILON then
            return false, "water"
        end
        return true, nil
    end
    local keep: { [string]: boolean } = {}
    local shed: { string } = {}
    local reason: string? = nil
    local ok, why = fits(all)
    if ok then
        keep = all
    elseif m.stallMode == "priority" then
        -- 중요한 시설부터 하나씩 넣어 보고 들어가면 남긴다 (shedOrder를 거꾸로)
        local order = m.shedOrder or {}
        local function rank(id: string): number
            local defId = state.facilities[id].defId
            return table.find(order, defId) or 0
        end
        table.sort(ids, function(a, b)
            local ra, rb = rank(a), rank(b)
            if ra == rb then
                return a < b
            end
            return ra > rb
        end)
        for _, id in ids do
            keep[id] = true
            local fit, failWhy = fits(keep)
            if not fit then
                keep[id] = nil
                table.insert(shed, id)
                reason = reason or failWhy
            end
        end
    else
        reason = why
        for _, id in ids do
            table.insert(shed, id)
        end
    end
    table.sort(shed)
    local _, upkeepEnergy, upkeepWater = Rules.upkeepBreakdown(state, config, keep)
    return {
        panelEnergy = panelEnergy,
        crew = crew,
        upkeepEnergy = upkeepEnergy,
        upkeepWater = upkeepWater,
        stalled = #shed > 0,
        stallReason = reason,
        running = keep,
        shed = shed,
    }
end

-- 새 게임 ----------------------------------------------------------------

export type NewStateOptions = {
    iceDistances: { [string]: number }?, -- 서버 실측 거리로 덮어쓰기 (키는 Ice1 ~ Ice5)
    players: number?, -- 판의 최대 인원 (기본 1). 미션 확정 때 정한다 [Q6]
}

-- 새 게임 상태 (1일차 시작, 플레이 중). weatherWindow는 SpaceWeatherData의 구간 하나 (없으면 우주 기상 없음)
function Rules.newState(
    missionId: string,
    config: Config,
    seed: number,
    weatherWindow: any,
    options: NewStateOptions?
): State
    local m = mission(config, missionId)
    assert(m.playable, "mission " .. missionId .. " is not playable yet")
    local overrides = if options and options.iceDistances then options.iceDistances else {}
    local sites: { Site } = {}
    for _, def in m.iceSites do
        local distance = overrides[def.id] or def.distance
        table.insert(sites, {
            id = def.id,
            distance = distance,
            risk = riskForDistance(m.rover, distance),
            cooldownLeft = 0,
            pipeId = nil,
        })
    end
    -- [Q37] 번호가 아니라 거리로 순서를 정한다. siteIndex 1 = 가장 가까운 곳
    table.sort(sites, function(a, b)
        if a.distance == b.distance then
            return a.id < b.id
        end
        return a.distance < b.distance
    end)
    local score: { [string]: ScoreCounts } = {}
    for _, resource in config.RESOURCES do
        score[resource] = { low = 0, zero = 0 }
    end
    return {
        missionId = missionId,
        players = math.max(
            1,
            math.floor(if options and options.players then options.players else 1)
        ),
        phase = "playing",
        day = 1,
        totalDays = config.TOTAL_DAYS,
        energy = m.start.energy,
        water = m.start.water,
        food = m.start.food,
        cap = m.cap,
        panels = 0,
        panelsToday = 0,
        facilities = {},
        sites = sites,
        rover = {
            status = "parked",
            recovering = false,
            damage = 0,
            trip = nil,
            recoverLeft = 0,
            brokenDistance = 0,
        },
        deliveries = 0,
        shortageDays = 0,
        stalled = false,
        stallReason = nil,
        shed = {},
        crewEnergyShort = 0,
        oxygenRescues = 0,
        score = score,
        stats = {
            trips = 0,
            rushTrips = 0,
            damages = 0,
            breakdowns = 0,
            walkRepairs = 0,
            remoteRecoveries = 0,
            roverRepairs = 0,
            harvests = 0,
            foodHarvested = 0,
            pipeWater = 0,
            roverWater = 0,
            manualWater = 0,
            wastedEnergy = 0,
            wastedWater = 0,
            wastedFood = 0,
            stallDays = 0,
            roverEnergy = 0,
            lostWater = 0,
            chargeEnergy = 0,
            manualRepairEnergy = 0,
            crewEnergyUnpaidDays = 0,
        },
        weather = normalizeWeather(weatherWindow, config),
        rngState = seedValue(seed),
        result = nil,
    }
end

-- 공용 검사 -------------------------------------------------------------

local function notPlaying(state: State): Msg?
    if state.phase ~= "playing" then
        return Msg.new("toast.game.not_playing")
    end
    return nil
end

-- 행동이 실패하면 상태는 그대로(복사본), 사유 Msg
local function fail(state: State, reason: Msg): (boolean, State, Msg)
    return false, Rules.copy(state), reason
end

local function pipeUnlockCheck(state: State, before: number, config: Config, events: { Msg })
    local pipe = missionOf(state, config).facilities.pipe
    if pipe == nil then
        return
    end
    local need = pipe.unlockDeliveries or 0
    if before < need and state.deliveries >= need then
        table.insert(events, Msg.new("toast.pipe.unlocked"))
    end
end

-- 자원 더하기 (상한 넘친 양은 버리고 기록). 반환: 버려진 양
local function addResource(state: State, resource: string, amount: number, config: Config): number
    local raw = (state :: any)[resource] + amount
    local wasted = math.max(0, raw - state.cap);
    (state :: any)[resource] = round(math.clamp(raw, 0, state.cap), config)
    if wasted > 0 then
        local key = "wasted" .. string.upper(string.sub(resource, 1, 1)) .. string.sub(resource, 2)
        state.stats[key] = round((state.stats[key] or 0) + wasted, config)
    end
    return round(wasted, config)
end

-- 패널 -----------------------------------------------------------------

function Rules.installPanel(state: State, config: Config): (boolean, State, Msg)
    local m = missionOf(state, config)
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    if sepToday(state) then
        return fail(state, Msg.new("toast.outdoor.locked_sep"))
    end
    if state.panels >= m.panels.total then
        return fail(state, Msg.new("toast.panel.full", { total = m.panels.total }))
    end
    if state.panelsToday >= m.panels.perDay then
        return fail(state, Msg.new("toast.panel.limit_today", { perDay = m.panels.perDay }))
    end
    local cost = m.panels.cost
    local emergency = false
    if state.energy < cost then
        -- 구조 장치: 패널 발전이 대원 에너지 소비보다 작아 에너지가 다시 차오를 수 없을 때만, 남은 에너지를 다 내고 설치
        if
            m.panels.emergencyInstall
            and state.panels * m.panels.output < Rules.crewUse(state, config).energy
        then
            cost = state.energy
            emergency = true
        else
            return fail(state, Msg.new("toast.panel.need_energy", { energy = m.panels.cost }))
        end
    end
    local new = Rules.copy(state)
    new.energy = round(new.energy - cost, config)
    new.panels += 1
    new.panelsToday += 1
    if emergency then
        new.stats.emergencyPanels = (new.stats.emergencyPanels or 0) + 1
    end
    return true,
        new,
        if emergency
            then Msg.new(
                "toast.panel.installed_emergency",
                { installed = new.panels, total = m.panels.total }
            )
            else Msg.new(
                "toast.panel.installed",
                { installed = new.panels, total = m.panels.total }
            )
end

-- 건설 -----------------------------------------------------------------

-- 지을 수 있는지와 못 짓는 사유. siteIndex는 파이프만 쓴다
function Rules.canBuild(
    state: State,
    config: Config,
    defId: string,
    siteIndex: number?
): (boolean, Msg?)
    local m = missionOf(state, config)
    local bad = notPlaying(state)
    if bad then
        return false, bad
    end
    local def = m.facilities[defId]
    if def == nil then
        return false, Msg.new("toast.build.unknown")
    end
    if def.buildFrom == "map" then
        if gstToday(state) then
            return false, Msg.new("toast.map.offline_gst")
        end
    elseif sepToday(state) then
        return false, Msg.new("toast.outdoor.locked_sep")
    end
    local instances = instancesOf(state, defId)
    if def.multi then
        if #instances >= (def.maxCount or 1) then
            return false,
                Msg.new("toast.build.max_count", {
                    facility = facilityName(defId),
                    max = def.maxCount or 1,
                })
        end
    elseif #instances > 0 then
        if instances[1].status == "active" then
            return false, Msg.new("toast.build.already_built", { facility = facilityName(defId) })
        end
        return false, Msg.new("toast.build.already_building", { facility = facilityName(defId) })
    end
    if def.unlockDeliveries and state.deliveries < def.unlockDeliveries then
        return false,
            Msg.new("toast.pipe.locked", { done = state.deliveries, need = def.unlockDeliveries })
    end
    if def.kind == "pipe" then
        local site = if siteIndex then state.sites[siteIndex] else nil
        if site == nil then
            return false, Msg.new("toast.pipe.pick_site")
        end
        if site.pipeId ~= nil then
            return false, Msg.new("toast.pipe.site_taken", { site = siteLabel(site) })
        end
    end
    for _, req in def.requires do
        if not Rules.isBuilt(state, req) then
            return false, Msg.new("toast.build.need_prereq", { facility = facilityName(req) })
        end
    end
    local needEnergy = math.max(0, def.cost.energy - state.energy)
    local needWater = math.max(0, def.cost.water - state.water)
    if needEnergy > 0 or needWater > 0 then
        return false,
            Msg.new("toast.build.need_resources", {
                energy = math.ceil(needEnergy - EPSILON),
                water = math.ceil(needWater - EPSILON),
            })
    end
    return true, nil
end

-- 착공: 비용 즉시 차감, building. 반환 Msg는 성공이면 toast.build.started
function Rules.startBuild(
    state: State,
    config: Config,
    defId: string,
    siteIndex: number?
): (boolean, State, Msg)
    local ok, reason = Rules.canBuild(state, config, defId, siteIndex)
    if not ok then
        return fail(state, reason :: Msg)
    end
    local m = missionOf(state, config)
    local def = m.facilities[defId]
    local new = Rules.copy(state)
    new.energy = round(new.energy - def.cost.energy, config)
    new.water = round(new.water - def.cost.water, config)
    -- 첫 인스턴스 id는 정의 id 그대로("pipe", CONTRACT_V2 시설 id), 둘째부터 "pipe2", "pipe3"
    local id = defId
    if def.multi then
        local n = 1
        while new.facilities[id] ~= nil do
            n += 1
            id = defId .. tostring(n)
        end
    end
    new.facilities[id] = {
        id = id,
        defId = defId,
        status = "building",
        daysLeft = def.buildDays,
        buildDays = def.buildDays,
        paused = false,
        progress = 0,
        siteIndex = if def.kind == "pipe" then siteIndex else nil,
        startedDay = new.day,
        completedDay = nil,
    }
    if def.kind == "pipe" and siteIndex then
        new.sites[siteIndex].pipeId = id
    end
    return true,
        new,
        Msg.count("toast.build.started", def.buildDays, {
            facility = facilityName(defId),
            id = id,
        })
end

-- 에어록 점검 [Q28]: 비용 없는 2일 건설과 같다
function Rules.inspectAirlock(state: State, config: Config): (boolean, State, Msg)
    return Rules.startBuild(state, config, "airlock")
end

-- 시설 멈춤과 재개 [Q33]. 외벽 제어반과 착륙선 콘솔 둘 다 (우주 기상과 무관)
function Rules.setPaused(
    state: State,
    config: Config,
    facilityId: string,
    paused: boolean
): (boolean, State, Msg)
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    local f = state.facilities[facilityId]
    if f == nil then
        return fail(state, Msg.new("toast.pause.no_facility"))
    end
    local def = missionOf(state, config).facilities[f.defId]
    if not def.canPause then
        return fail(state, Msg.new("toast.pause.not_allowed", { facility = facilityName(f.defId) }))
    end
    if f.status ~= "active" then
        return fail(state, Msg.new("toast.pause.not_active", { facility = facilityName(f.defId) }))
    end
    if f.paused == paused then
        return fail(
            state,
            if paused
                then Msg.new("toast.pause.already_paused", { facility = facilityName(f.defId) })
                else Msg.new(
                    "toast.pause.already_running",
                    { facility = facilityName(f.defId) }
                )
        )
    end
    local new = Rules.copy(state)
    new.facilities[facilityId].paused = paused
    return true,
        new,
        if paused
            then Msg.new("toast.pause.on", { facility = facilityName(f.defId), id = facilityId })
            else Msg.new(
                "toast.pause.off",
                { facility = facilityName(f.defId), id = facilityId }
            )
end

-- 로버 ------------------------------------------------------------------

export type TripPlan = {
    siteIndex: number,
    days: number, -- 왕복 일수 (화면 "왕복 약 N일")
    rawDays: number, -- 반올림 전 일수
    energy: number, -- 출발 때 내는 에너지
    risk: string, -- 굴릴 위험 등급
    baseRisk: string, -- 거리로 정한 등급
    damageChance: number,
    rushHelps: boolean, -- 서둘러 가기로 일수가 줄어드는지
}

-- 왕복 계획 (화면 미리보기와 파견이 같은 값을 쓴다) [Q7, Q30]
function Rules.tripPlan(state: State, config: Config, siteIndex: number, rush: boolean?): TripPlan?
    local site = state.sites[siteIndex]
    if site == nil then
        return nil
    end
    local roverDef = missionOf(state, config).rover
    local baseLevel = roverDef.risk[site.risk]
    local damageFactor = math.max(0.1, 1 - roverDef.slowdownPerDamage * state.rover.damage)
    local baseDays = 2 * site.distance / (roverDef.fsdStudsPerDay * baseLevel.speedFactor)
    local plainRaw = baseDays / damageFactor
    local raw = if rush then plainRaw * roverDef.rushTimeFactor else plainRaw
    local days = math.max(1, roundInt(raw))
    local plainDays = math.max(1, roundInt(plainRaw))
    local rushDays = math.max(1, roundInt(plainRaw * roverDef.rushTimeFactor))
    local risk = if rush then nextRisk(roverDef, site.risk) else site.risk
    local energy = math.ceil(
        baseDays * roverDef.energyPerTravelDay * (if rush then roverDef.rushEnergyFactor else 1)
            - EPSILON
    )
    return {
        siteIndex = siteIndex,
        days = days,
        rawDays = round(raw, config),
        energy = energy,
        risk = risk,
        baseRisk = site.risk,
        damageChance = roverDef.risk[risk].damageChance * roverDef.damageChanceMultiplier,
        rushHelps = rushDays < plainDays,
    }
end

-- 자율주행 파견 [Q7, Q8, Q30]
function Rules.dispatchRover(
    state: State,
    config: Config,
    siteIndex: number,
    rush: boolean?
): (boolean, State, Msg)
    local roverDef = missionOf(state, config).rover
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    if state.rover.status ~= "parked" then
        return fail(state, Msg.new("toast.rover.busy"))
    end
    if state.rover.damage >= roverDef.maxDamage then
        return fail(state, Msg.new("toast.rover.need_repair"))
    end
    if sepToday(state) then
        return fail(state, Msg.new("toast.rover.sep_hold"))
    end
    if gstToday(state) then
        return fail(state, Msg.new("toast.map.offline_gst"))
    end
    local site = state.sites[siteIndex]
    if site == nil then
        return fail(state, Msg.new("toast.rover.pick_site"))
    end
    if site.pipeId ~= nil then
        return fail(state, Msg.new("toast.rover.site_piped", { site = siteLabel(site) }))
    end
    if site.cooldownLeft > 0 then
        return fail(
            state,
            Msg.count("toast.rover.site_cooldown", site.cooldownLeft, { site = siteLabel(site) })
        )
    end
    local plan = Rules.tripPlan(state, config, siteIndex, rush) :: TripPlan
    if state.energy < plan.energy then
        return fail(state, Msg.new("toast.rover.need_energy", { energy = plan.energy }))
    end
    local new = Rules.copy(state)
    new.energy = round(new.energy - plan.energy, config)
    local damageAt: number? = nil
    if nextRandom(new) < plan.damageChance then
        -- 파손 위치는 왕복 진행 비율. 0과 1 끝은 피한다 (기지 안에서 파손 없음)
        damageAt = 0.02 + nextRandom(new) * 0.96
    end
    new.rover.status = "fsd"
    new.rover.recovering = false
    new.rover.trip = {
        siteIndex = siteIndex,
        totalDays = plan.days,
        elapsed = 0,
        rush = rush == true,
        risk = plan.risk,
        collected = false,
        carrying = 0,
        damageAt = damageAt,
        position = nil,
    }
    new.stats.trips += 1
    new.stats.roverEnergy += plan.energy
    if rush then
        new.stats.rushTrips += 1
    end
    return true,
        new,
        Msg.count(
            "toast.rover.dispatched",
            plan.days,
            { site = siteLabel(site), energy = plan.energy }
        )
end

-- 주차 자리 R 수리 [Q30]: 기지에 있을 때, 파손을 모두 없앤다
function Rules.repairRover(state: State, config: Config): (boolean, State, Msg)
    local roverDef = missionOf(state, config).rover
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    -- 주차 중이거나, 수동 운전 중 고장(자율주행 왕복이 없음)이면 그 자리에서 R 수리
    local manualBroken = state.rover.status == "broken" and state.rover.trip == nil
    if state.rover.status ~= "parked" and not manualBroken then
        return fail(state, Msg.new("toast.rover.not_home"))
    end
    if state.rover.damage <= 0 then
        return fail(state, Msg.new("toast.rover.no_damage"))
    end
    if sepToday(state) then
        return fail(state, Msg.new("toast.outdoor.locked_sep"))
    end
    if state.energy < roverDef.repairEnergy then
        return fail(state, Msg.new("toast.rover.need_energy", { energy = roverDef.repairEnergy }))
    end
    local new = Rules.copy(state)
    new.energy = round(new.energy - roverDef.repairEnergy, config)
    new.rover.damage = 0
    if manualBroken then
        new.rover.status = "parked"
    end
    new.stats.roverRepairs += 1
    return true, new, Msg.new("toast.rover.repaired")
end

export type RoverHitOptions = {
    amount: number?, -- 파손 증가량 (기본 1)
}

-- 수동 운전(멀티) 충돌 파손 [Q29, Q30]. 서버 RoverFleet이 바위 충돌을 감지하면 부른다.
-- 파손 +amount(기본 1), stats.damages도 센다. maxDamage에 닿으면 고장(status "broken", 자율주행 왕복 없음)이고
-- 그 자리에서 repairRover(R 수리)로 고친다. 자율주행 중에는 받지 않는다(자율주행 파손은 하루 마감의 굴림).
-- 반환 Msg: toast.rover.damaged { damage } 또는 고장이면 toast.rover.broken_manual (키 안내 {key_repair}는 클라이언트)
function Rules.applyRoverHit(
    state: State,
    config: Config,
    opts: RoverHitOptions?
): (boolean, State, Msg)
    local roverDef = missionOf(state, config).rover
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    if state.rover.status == "fsd" then
        return fail(state, Msg.new("toast.rover.busy"))
    end
    if state.rover.status == "broken" then
        return fail(state, Msg.new("toast.rover.need_repair"))
    end
    local amount = math.max(1, math.floor(if opts and opts.amount then opts.amount else 1))
    local new = Rules.copy(state)
    new.rover.damage = math.min(roverDef.maxDamage, new.rover.damage + amount)
    new.stats.damages += amount
    if new.rover.damage >= roverDef.maxDamage then
        new.rover.status = "broken"
        new.rover.trip = nil
        new.rover.brokenDistance = 0
        new.stats.breakdowns += 1
        return true, new, Msg.new("toast.rover.broken_manual")
    end
    return true, new, Msg.new("toast.rover.damaged", { damage = new.rover.damage })
end

-- 걸어서 수리할 수 있는 최대 거리 [Q37]: 산소로 갈 수 있는 한 방향 거리 (수리 뒤 로버를 타고 돌아온다)
function Rules.walkRepairLimit(config: Config): number
    local walk = config.WALK_REPAIR
    local seconds = config.OXYGEN.outdoorSeconds * walk.oxygenSafetyRatio - walk.repairHoldSeconds
    return math.max(0, math.floor(seconds * walk.walkSpeed))
end

-- 고장 난 로버까지 걷는 거리: 에어록에서 출발하므로 BaseExit 기준 고장 위치 + 에어록에서 BaseExit까지 (리드 측정 176)
local function walkDistance(brokenDistance: number, config: Config): number
    return brokenDistance + (config.WALK_REPAIR.startOffset or 0)
end

-- 화면에 보이는 거리는 정수 미터 (내부는 studs). 디자이너 높이맵 2.56 km = 2044 studs
local function meters(studs: number, config: Config): number
    return math.round(studs * (config.metersPerStud or 1))
end

function Rules.canWalkRepair(state: State, config: Config): boolean
    return state.rover.status == "broken"
        and walkDistance(state.rover.brokenDistance, config) <= Rules.walkRepairLimit(config)
end

-- 고장 난 로버까지 걸어가서 수리 (물을 지킨다): 파손을 없애고 남은 왕복을 이어 간다
function Rules.walkRepairRover(state: State, config: Config): (boolean, State, Msg)
    local roverDef = missionOf(state, config).rover
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    if state.rover.status ~= "broken" then
        return fail(state, Msg.new("toast.rover.not_broken"))
    end
    if sepToday(state) then
        return fail(state, Msg.new("toast.outdoor.locked_sep"))
    end
    local limit = Rules.walkRepairLimit(config)
    local walk = walkDistance(state.rover.brokenDistance, config)
    if walk > limit then
        return fail(
            state,
            Msg.new("toast.rover.too_far_walk", {
                distance = meters(walk, config),
                limit = meters(limit, config),
            })
        )
    end
    if state.energy < roverDef.repairEnergy then
        return fail(state, Msg.new("toast.rover.need_energy", { energy = roverDef.repairEnergy }))
    end
    local new = Rules.copy(state)
    new.energy = round(new.energy - roverDef.repairEnergy, config)
    new.rover.damage = 0
    new.rover.status = "fsd"
    new.rover.brokenDistance = 0
    new.stats.walkRepairs += 1
    new.stats.roverRepairs += 1
    return true, new, Msg.new("toast.rover.repaired")
end

-- 착륙선 콘솔 원격 회수 [Q30]: remoteRecoverDays 뒤 기지에 돌아오고 싣고 있던 물은 잃는다. 파손은 그대로(수리 따로)
function Rules.remoteRecoverRover(state: State, config: Config): (boolean, State, Msg)
    local roverDef = missionOf(state, config).rover
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    if state.rover.status ~= "broken" then
        return fail(state, Msg.new("toast.rover.not_broken"))
    end
    if gstToday(state) then
        return fail(state, Msg.new("toast.map.offline_gst"))
    end
    if state.energy < roverDef.remoteRecoverEnergy then
        return fail(
            state,
            Msg.new("toast.rover.need_energy", { energy = roverDef.remoteRecoverEnergy })
        )
    end
    local new = Rules.copy(state)
    new.energy = round(new.energy - roverDef.remoteRecoverEnergy, config)
    local trip = new.rover.trip
    local lost = if trip then trip.carrying else 0
    new.stats.lostWater += lost
    new.rover.status = "fsd"
    new.rover.recovering = true
    new.rover.recoverLeft = roverDef.remoteRecoverDays
    -- 어느 지점에서 돌아오는지 화면에 보이도록 trip은 남기고 싣던 물과 남은 파손만 지운다
    if trip then
        trip.carrying = 0
        trip.damageAt = nil
    end
    new.rover.brokenDistance = 0
    new.stats.remoteRecoveries += 1
    return true,
        new,
        Msg.count("toast.rover.recovering", roverDef.remoteRecoverDays, { lost = lost })
end

-- 수동 운전(멀티): 얼음 지점에서 탱크 채우기. 쿨타임만 기록하고 채운 양을 돌려준다 (탱크는 서버가 든다)
function Rules.collectIce(state: State, config: Config, siteIndex: number): (boolean, State, Msg)
    local m = missionOf(state, config)
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    if sepToday(state) then
        return fail(state, Msg.new("toast.outdoor.locked_sep"))
    end
    local site = state.sites[siteIndex]
    if site == nil then
        return fail(state, Msg.new("toast.rover.pick_site"))
    end
    if site.pipeId ~= nil then
        return fail(state, Msg.new("toast.rover.site_piped", { site = siteLabel(site) }))
    end
    if site.cooldownLeft > 0 then
        return fail(
            state,
            Msg.count("toast.rover.site_cooldown", site.cooldownLeft, { site = siteLabel(site) })
        )
    end
    local new = Rules.copy(state)
    new.sites[siteIndex].cooldownLeft = m.ice.cooldownDays
    return true,
        new,
        Msg.new("toast.ice.collected", { site = siteLabel(site), amount = m.ice.amountPerTrip })
end

-- 수동 운전(멀티): 물탱크에 하역. 하역 횟수는 파이프 해금에 센다 [Q10]
function Rules.deliverWater(
    state: State,
    config: Config,
    amount: number
): (boolean, State, Msg, { Msg })
    local bad = notPlaying(state)
    if bad then
        local ok, same, reason = fail(state, bad)
        return ok, same, reason, {}
    end
    if amount <= 0 then
        local ok, same, reason = fail(state, Msg.new("toast.water.nothing"))
        return ok, same, reason, {}
    end
    local new = Rules.copy(state)
    local before = new.deliveries
    local wasted = addResource(new, "water", amount, config)
    new.deliveries += 1
    new.stats.manualWater += amount - wasted
    local events: { Msg } = {}
    -- 넘친 양은 따로 알린다 (넘친 것이 없으면 알림 없음, "0 넘침"을 보이지 않게)
    if wasted > 0 then
        table.insert(events, Msg.new("toast.water.overflow", { amount = wasted }))
    end
    pipeUnlockCheck(new, before, config, events)
    return true, new, Msg.new("toast.water.delivered", { amount = amount }), events
end

-- 멀티 수동 운전의 에너지 지출 (서버 RoverFleet): purpose "rover_charge"(충전 패드, v1처럼 기지 에너지 1:1),
-- "rover_repair"(현장 R 수리). 있는 만큼만 낸다. 반환: 성공 여부, 새 상태, 실제로 낸 양
function Rules.payEnergy(
    state: State,
    config: Config,
    amount: number,
    purpose: string
): (boolean, State, number)
    if state.phase ~= "playing" or amount <= 0 then
        return false, Rules.copy(state), 0
    end
    local new = Rules.copy(state)
    -- 충전은 기지 에너지를 chargeKeepEnergy만큼 남긴다 (수리는 남김 없이)
    local keep = if purpose == "rover_repair"
        then 0
        else (config.MANUAL_DRIVE.chargeKeepEnergy or 0)
    local paid = round(math.max(0, math.min(amount, new.energy - keep)), config)
    new.energy = round(new.energy - paid, config)
    if purpose == "rover_repair" then
        new.stats.manualRepairEnergy += paid
    else
        new.stats.chargeEnergy += paid
    end
    return paid > 0, new, paid
end

-- 산소 0 구조 [Q3, Q4]: 즉시 실패가 아니라 에어록으로 구조되고 감점
function Rules.recordOxygenRescue(state: State, config: Config): (boolean, State, Msg)
    local bad = notPlaying(state)
    if bad then
        return fail(state, bad)
    end
    local new = Rules.copy(state)
    new.oxygenRescues += 1
    return true, new, Msg.new("toast.oxygen.rescued", { points = config.SCORE.oxygenRescuePenalty })
end

-- 하루 마감 --------------------------------------------------------------

-- 로버 하루 진행. 우주 기상으로 멈춘 날은 부르지 않는다. 반환: 기지에 들어온 물
local function advanceRover(new: State, config: Config, events: { Msg }): number
    local m = missionOf(new, config)
    local rover = new.rover
    if rover.status == "fsd" and rover.recovering then
        rover.recoverLeft -= 1
        if rover.recoverLeft <= 0 then
            rover.status = "parked"
            rover.recovering = false
            rover.recoverLeft = 0
            rover.trip = nil
            table.insert(events, Msg.new("toast.rover.recovered", { damage = rover.damage }))
        end
        return 0
    end
    if rover.status ~= "fsd" or rover.trip == nil then
        return 0
    end
    local trip = rover.trip :: Trip
    trip.elapsed += 1
    local reach = trip.elapsed / trip.totalDays
    local site = new.sites[trip.siteIndex]
    -- 왕복 진행 비율 순으로 사건 처리: 0.5 채취, damageAt 파손, 1.0 귀환
    local steps = {}
    if not trip.collected then
        table.insert(steps, { at = 0.5, kind = "collect" })
    end
    if trip.damageAt then
        table.insert(steps, { at = trip.damageAt :: number, kind = "damage" })
    end
    table.insert(steps, { at = 1, kind = "return" })
    table.sort(steps, function(a, b)
        return a.at < b.at
    end)
    for _, step in steps do
        if step.at > reach + EPSILON then
            break
        end
        if step.kind == "collect" then
            trip.collected = true
            trip.carrying = m.ice.amountPerTrip
            site.cooldownLeft = m.ice.cooldownDays
        elseif step.kind == "damage" then
            trip.damageAt = nil
            rover.damage += 1
            new.stats.damages += 1
            if rover.damage >= m.rover.maxDamage then
                rover.status = "broken"
                trip.position = step.at
                rover.brokenDistance =
                    round(site.distance * (1 - math.abs(1 - 2 * step.at)), config)
                new.stats.breakdowns += 1
                local args = {
                    site = siteLabel(site),
                    distance = meters(walkDistance(rover.brokenDistance, config), config),
                }
                if walkDistance(rover.brokenDistance, config) <= Rules.walkRepairLimit(config) then
                    table.insert(events, Msg.new("toast.rover.broken_walkable", args))
                else
                    table.insert(events, Msg.new("toast.rover.broken_far", args))
                end
                return 0
            end
            table.insert(events, Msg.new("toast.rover.damaged", { damage = rover.damage }))
        else
            local amount = trip.carrying
            rover.status = "parked"
            rover.trip = nil
            table.insert(
                events,
                Msg.new("toast.rover.returned", { site = siteLabel(site), amount = amount })
            )
            return amount
        end
    end
    return 0
end

-- 하루 마감 (DayTick 1회). 순서:
-- 1) 얼음 지점 쿨타임 감소 2) 대원 소비, 시설 유지비와 정지 판정(지금 가진 에너지나 물로 유지비를 못 내면 모든 시설 정지)
-- 3) 시설 효과(수확, 파이프 공급) 4) 로버 진행(SEP, GST 날은 멈춤)
-- 5) 자원 반영: 소비를 먼저 빼고(0 아래는 0) 들어온 양(패널 발전, 수확, 물)을 더한다. 상한 100, 넘친 양 기록
-- 6) 건설 진행(우주 기상, 정지와 무관하게 계속) 7) 부족 연속 일수 8) 감점 일수 9) 다음 날, 우주 기상 알림
-- 반환: 새 상태, 이벤트 Msg 목록
function Rules.applyDay(state: State, config: Config): (State, { Msg })
    local events: { Msg } = {}
    local new = Rules.copy(state)
    if state.phase ~= "playing" then
        return new, events
    end
    local m = missionOf(state, config)
    local sep, gst = Rules.weatherOn(state)

    -- 1) 쿨타임
    for _, site in new.sites do
        if site.cooldownLeft > 0 then
            site.cooldownLeft -= 1
        end
    end

    -- 2) 흐름과 정지. 어제와 비교해 새로 멈춘 시설과 다시 돈 시설을 이름으로 알린다
    local flows = Rules.flows(state, config)
    new.stalled = flows.stalled
    new.stallReason = flows.stallReason
    new.shed = table.clone(flows.shed)
    if flows.stalled then
        new.stats.stallDays += 1
    end
    local wasShed: { [string]: boolean } = {}
    for _, id in state.shed or {} do
        wasShed[id] = true
    end
    local isShed: { [string]: boolean } = {}
    local stopped: { any } = {}
    for _, id in flows.shed do
        isShed[id] = true
        if not wasShed[id] then
            table.insert(stopped, facilityName(state.facilities[id].defId))
        end
    end
    local resumed: { any } = {}
    for _, id in state.shed or {} do
        local f = state.facilities[id]
        if f and not isShed[id] and flows.running[id] then
            table.insert(resumed, facilityName(f.defId))
        end
    end
    if #stopped > 0 then
        local list = Msg.list(stopped)
        if flows.stallReason == "water" then
            table.insert(events, Msg.new("toast.stall.stopped_water", { facilities = list }))
        else
            table.insert(events, Msg.new("toast.stall.stopped_energy", { facilities = list }))
        end
    end
    if #resumed > 0 then
        if #flows.shed == 0 then
            table.insert(events, Msg.new("toast.stall.cleared"))
        else
            table.insert(events, Msg.new("toast.stall.resumed", { facilities = Msg.list(resumed) }))
        end
    end
    local inflowWater, inflowFood = 0, 0

    -- 3) 시설 효과 (오늘 돌아가는 시설만, flows.running)
    local keep = flows.running
    if new.facilities.farm and new.facilities.farm.status == "active" and not keep.farm then
        new.stats.farmStallDays = (new.stats.farmStallDays or 0)
            + (if new.facilities.farm.paused then 0 else 1)
    end
    do
        local farm = new.facilities.farm
        if farm and running(new, farm, config, keep) then
            farm.progress += 1
            local every = m.facilities.farm.harvestEveryDays
            if upgradeRunning(new, "led", config, keep) then
                every = m.facilities.led.harvestEveryDays or every
            end
            if farm.progress >= every then
                local amount = m.facilities.farm.harvestAmount
                if upgradeRunning(new, "hydroponics", config, keep) then
                    amount = m.facilities.hydroponics.harvestAmount or amount
                end
                farm.progress = 0
                inflowFood += amount
                new.stats.harvests += 1
                new.stats.foodHarvested += amount
                table.insert(events, Msg.new("toast.harvest", { amount = amount }))
            end
        end
        for _, f in instancesOf(new, "pipe") do
            if running(new, f, config, keep) then
                local def = m.facilities.pipe
                f.progress += 1
                if f.progress >= def.deliverEveryDays then
                    f.progress = 0
                    inflowWater += def.deliverAmount
                    new.stats.pipeWater += def.deliverAmount
                    table.insert(
                        events,
                        Msg.new("toast.pipe.delivered", { amount = def.deliverAmount })
                    )
                end
            end
        end
    end

    -- 4) 로버 (SEP와 GST 날은 멈춤) [Q14, Q15]
    local roverPaused = (sep ~= nil and config.WEATHER.SEP.pausesRover)
        or (gst ~= nil and config.WEATHER.GST.pausesRover)
    if not roverPaused then
        local before = new.deliveries
        local arrived = advanceRover(new, config, events)
        if arrived > 0 then
            inflowWater += arrived
            new.stats.roverWater += arrived
            new.deliveries += 1
            pipeUnlockCheck(new, before, config, events)
        end
    end

    -- 5) 자원 반영: 먼저 소비를 빼고(0 아래는 0), 그다음 들어온 양을 더한다(상한 넘친 양은 버림).
    -- 패널 발전도 이때 더해져 다음 날 아침부터 쓸 수 있다. 소비와 생산을 한꺼번에 계산하면 패널이 1 ~ 3장일 때
    -- 대원 소비 12가 발전을 다 먹어 에너지가 매일 0에 묶이고 패널(에너지 4)을 다시 살 수 없는 함정이 생긴다
    -- (처음 하는 사람 봇이 회의 숫자로 매판 빠졌다). 이 순서면 패널 2장부터 다시 올라올 수 있다
    -- 대원 에너지를 다 못 낸 날: 실패는 아니지만(Q3) 에너지가 바닥난 날로 감점하고 경고를 보낸다 (8단계)
    local energyAfter = state.energy - flows.crew.energy - flows.upkeepEnergy
    local crewUnpaid = round(math.max(0, -energyAfter), config)
    new.crewEnergyShort = crewUnpaid
    if crewUnpaid > 0 then
        new.stats.crewEnergyUnpaidDays = (new.stats.crewEnergyUnpaidDays or 0) + 1
        table.insert(
            events,
            Msg.new("banner.energy.crew_unpaid", { amount = math.ceil(crewUnpaid) })
        )
    end
    new.energy = round(math.max(0, energyAfter), config)
    new.water = round(math.max(0, state.water - flows.crew.water - flows.upkeepWater), config)
    new.food = round(math.max(0, state.food - flows.crew.food), config)
    addResource(new, "energy", flows.panelEnergy, config)
    local wastedWater = addResource(new, "water", inflowWater, config)
    local wastedFood = addResource(new, "food", inflowFood, config)
    if wastedWater > 0 and inflowWater > 0 then
        table.insert(events, Msg.new("toast.water.overflow", { amount = wastedWater }))
    end
    if wastedFood > 0 and inflowFood > 0 then
        table.insert(events, Msg.new("toast.food.overflow", { amount = wastedFood }))
    end

    -- 6) 건설 진행
    local building: { Facility } = {}
    for _, f in new.facilities do
        if f.status == "building" then
            table.insert(building, f)
        end
    end
    table.sort(building, function(a, b)
        return a.id < b.id
    end)
    for _, f in building do
        f.daysLeft -= 1
        if f.daysLeft <= 0 then
            f.daysLeft = 0
            f.status = "active"
            f.progress = 0
            f.completedDay = state.day
            table.insert(
                events,
                Msg.new("toast.build.done", { facility = facilityName(f.defId), id = f.id })
            )
        end
    end

    -- 7) 부족 연속 일수 [Q3]
    if new.water <= 0 or new.food <= 0 then
        new.shortageDays = math.min(state.shortageDays + 1, config.SHORTAGE_DAYS_TO_LOSE)
        local resource = if new.water <= 0 and new.food <= 0
            then "both"
            elseif new.water <= 0 then "water"
            else "food"
        -- 자원 이름을 값으로 넣으면 한국어 조사가 깨지므로 자원별 키 (리드 결정 3과 같은 이유)
        local daysLeft = config.SHORTAGE_DAYS_TO_LOSE - new.shortageDays
        if resource == "both" then
            table.insert(events, Msg.count("banner.shortage.both", daysLeft))
        elseif resource == "water" then
            table.insert(events, Msg.count("banner.shortage.water", daysLeft))
        else
            table.insert(events, Msg.count("banner.shortage.food", daysLeft))
        end
    else
        new.shortageDays = 0
    end

    -- 8) 감점 일수 [Q4]: 자원마다 하루 한 번, 하루 끝 값으로. 대원 에너지를 못 낸 날은 패널 발전이 들어와도
    -- 에너지가 바닥난 날(0)로 센다 (아이들이 대가를 보게)
    for _, resource in config.RESOURCES do
        local value = if resource == "energy" and crewUnpaid > 0 then 0 else (new :: any)[resource]
        if value <= 0 then
            new.score[resource].zero += 1
        elseif value < config.SCORE.lowThreshold then
            new.score[resource].low += 1
        end
    end

    -- 9) 다음 날과 우주 기상 알림 [Q15, Q36]
    new.day = state.day + 1
    new.panelsToday = 0
    -- 시작 알림 뒤에는 출처 한 줄(event.source)이 따른다. 사건 이름과 교육 문구(event.sep.name/edu,
    -- event.gst.name/edu)와 남은 일수 배너(banner.*.days_left)는 Rules.weatherStatus로 클라이언트가 그린다
    local nextSep, nextGst = Rules.weatherOn(new)
    if nextSep and nextSep ~= sep then
        table.insert(events, Msg.new("banner.sep.active"))
        local source = sourceMsg(nextSep)
        if source then
            table.insert(events, source)
        end
    elseif sep and nextSep == nil then
        table.insert(events, Msg.new("banner.sep.end"))
    end
    if nextGst and nextGst ~= gst then
        table.insert(events, Msg.new("banner.gst.active"))
        local source = sourceMsg(nextGst)
        if source then
            table.insert(events, source)
        end
        if new.rover.status == "fsd" then
            table.insert(events, Msg.new("banner.gst.rover_stopped"))
        end
    elseif gst and nextGst == nil then
        table.insert(events, Msg.new("banner.gst.end"))
    end
    local soonSep = Rules.weatherOn(new, new.day + 1)
    if soonSep and soonSep ~= nextSep and soonSep.day == new.day + 1 then
        -- 내일 SEP가 시작한다. 서버는 이 알림을 오늘 끝 15초(반나절) 전에 붉은 배너와 테두리로 띄운다 [Q15]
        table.insert(events, Msg.new("banner.sep.warning"))
    end
    return new, events
end

-- 메달, 종료, 점수 -------------------------------------------------------------

-- 지금 지은 시설로 받을 메달 (없으면 nil) [V2_PLAN 15.6]
function Rules.medal(state: State, config: Config): Medal?
    local m = missionOf(state, config)
    for _, medal in m.medalOrder do
        local all = true
        for _, defId in m.medals[medal] do
            if not Rules.isBuilt(state, defId) then
                all = false
                break
            end
        end
        if all then
            return medal :: Medal
        end
    end
    return nil
end

-- 종료 판정 [Q2, Q3]. 이미 끝났으면 저장한 결과
--   금메달 조건 = 그 순간 임무 완료. 물이나 식량 0이 SHORTAGE_DAYS_TO_LOSE일 연속 = 실패.
--   60일을 마치면 지은 만큼 메달, 동메달도 없으면 실패
function Rules.checkEnd(state: State, config: Config): EndResult
    if state.result then
        return table.clone(state.result :: EndResult)
    end
    local daysTaken = state.day - 1
    local medal = Rules.medal(state, config)
    if medal == "gold" then
        return {
            outcome = "won",
            medal = medal,
            reason = "gold",
            daysTaken = daysTaken,
            msg = Msg.new("result.medal.earned", { medal = medalName("gold") }),
        }
    end
    if state.shortageDays >= config.SHORTAGE_DAYS_TO_LOSE then
        local resource = if state.water <= 0 and state.food <= 0
            then "both"
            elseif state.water <= 0 then "water"
            else "food"
        return {
            outcome = "lost",
            medal = nil,
            reason = "shortage",
            resource = resource,
            daysTaken = daysTaken,
            msg = if resource == "both"
                then Msg.new("end.lost.both")
                elseif resource == "water" then Msg.new("end.lost.water")
                else Msg.new("end.lost.food"),
        }
    end
    if state.day > state.totalDays then
        if medal then
            return {
                outcome = "won",
                medal = medal,
                reason = "timeout",
                daysTaken = daysTaken,
                msg = Msg.new("result.medal.earned", { medal = medalName(medal) }),
            }
        end
        return {
            outcome = "lost",
            medal = nil,
            reason = "noMedal",
            daysTaken = daysTaken,
            msg = Msg.new("end.lost.no_medal"),
        }
    end
    return { outcome = "none", medal = medal, daysTaken = daysTaken }
end

-- 감점 한 줄 Msg. 자원 이름을 값으로 넣지 않고 사유마다 리터럴 키 (리드 결정 3). points는 양수, "-"는 템플릿
local function deductionMsg(reason: string, count: number, points: number): Msg
    local args = { points = points }
    if reason == "water_low" then
        return Msg.count("score.deduct.water_low", count, args)
    elseif reason == "water_zero" then
        return Msg.count("score.deduct.water_zero", count, args)
    elseif reason == "food_low" then
        return Msg.count("score.deduct.food_low", count, args)
    elseif reason == "food_zero" then
        return Msg.count("score.deduct.food_zero", count, args)
    elseif reason == "energy_low" then
        return Msg.count("score.deduct.energy_low", count, args)
    elseif reason == "energy_zero" then
        return Msg.count("score.deduct.energy_zero", count, args)
    end
    return Msg.count("score.deduct.oxygen_rescue", count, args)
end

-- 최종 점수와 사유별 감점 [Q4]. 목록 순서: 자원(RESOURCES 순)마다 0, 20 미만, 마지막에 산소 구조
-- Deduction.reason은 CSV 키 끝과 같다: "water_low" | "water_zero" | ... | "oxygen_rescue"
function Rules.finalScore(state: State, config: Config): ScoreReport
    local s = config.SCORE
    local deductions: { Deduction } = {}
    local total = 0
    local function add(reason: string, resource: string?, count: number, each: number)
        if count <= 0 then
            return
        end
        local points = each * count
        total += points
        table.insert(deductions, {
            reason = reason,
            resource = resource,
            count = count,
            points = points,
            msg = deductionMsg(reason, count, points),
        })
    end
    for _, resource in config.RESOURCES do
        local counts = state.score[resource]
        add(resource .. "_zero", resource, counts.zero, s.zeroPenalty)
        add(resource .. "_low", resource, counts.low, s.lowPenalty)
    end
    add("oxygen_rescue", nil, state.oxygenRescues, s.oxygenRescuePenalty)
    return {
        start = s.start,
        score = math.max(s.minScore, s.start - total),
        deductions = deductions,
    }
end

-- 게임 종료 처리: phase와 결과를 저장한 복사본 (result.outcome이 none이면 그대로 복사)
function Rules.finish(state: State, config: Config, result: EndResult?): State
    local r = result or Rules.checkEnd(state, config)
    local new = Rules.copy(state)
    if r.outcome == "none" then
        return new
    end
    new.phase = r.outcome
    new.result = table.clone(r)
    return new
end

-- 결과 화면의 우주 날씨 요약 [Q36]: 이번 구간 id, 시작 날짜, SEP와 GST 사건 수
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- 날짜 + n일 (n >= 0, 그레고리력). os.time의 시간대 차이를 피하려고 직접 센다
local function addDays(date: { year: number, month: number, day: number }, n: number)
    local year, month, day = date.year, date.month, date.day + n
    while true do
        local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
        local length = DAYS_IN_MONTH[month] + (if month == 2 and leap then 1 else 0)
        if day <= length then
            break
        end
        day -= length
        month += 1
        if month > 12 then
            month = 1
            year += 1
        end
    end
    return { year = year, month = month, day = day }
end

-- endDate = 시작 날짜 + (totalDays - 1)일 (CONTRACT_V2 6절 weather.endDate, result.weather.range)
function Rules.weatherSummary(
    state: State
): { id: string, sep: number, gst: number, startDate: any, endDate: any }
    local sep, gst = 0, 0
    for _, e in state.weather.events do
        if e.day <= state.totalDays then
            if e.kind == "SEP" then
                sep += 1
            else
                gst += 1
            end
        end
    end
    local start = state.weather.startDate
    return {
        id = state.weather.id,
        sep = sep,
        gst = gst,
        startDate = if start then table.clone(start) else nil,
        endDate = if start then addDays(start, state.totalDays - 1) else nil,
    }
end

-- 화면용 보기 (CONTRACT_V2 5절 모양) ---------------------------------------------

export type WeatherStatus = {
    kind: string, -- "SEP" | "GST"
    stage: string, -- "warning"(내일 SEP 시작) | "active"
    daysLeft: number, -- active: 오늘 포함 남은 일수, warning: SEP가 이어질 일수
    sourceDate: { year: number, month: number, day: number }?,
    banner: Msg, -- banner.sep.days_left / banner.gst.days_left / banner.sep.warning
}

-- 지금 보여 줄 우주 기상. 둘 다 진행 중이면 SEP(야외 금지)가 먼저. 없으면 nil
function Rules.weatherStatus(state: State): WeatherStatus?
    local sep, gst = Rules.weatherOn(state)
    local active = sep or gst
    if active then
        local daysLeft = active.day + active.durationDays - state.day
        return {
            kind = active.kind,
            stage = "active",
            daysLeft = daysLeft,
            sourceDate = if active.sourceDate then table.clone(active.sourceDate) else nil,
            banner = if active.kind == "SEP"
                then Msg.count("banner.sep.days_left", daysLeft)
                else Msg.count("banner.gst.days_left", daysLeft),
        }
    end
    local soon = Rules.weatherOn(state, state.day + 1)
    if soon and soon.day == state.day + 1 then
        return {
            kind = "SEP",
            stage = "warning",
            daysLeft = soon.durationDays,
            sourceDate = if soon.sourceDate then table.clone(soon.sourceDate) else nil,
            banner = Msg.new("banner.sep.warning"),
        }
    end
    return nil
end

export type FsdView = {
    siteIndex: number,
    phase: string, -- "out" | "return"
    progress: number, -- 0..1 (왕복 전체 비율, 원격 회수면 회수 진행)
    rush: boolean,
    recovering: boolean,
    stoppedBy: string?, -- "SEP" | "GST" | nil (오늘 멈춤, 지도 아이콘 정지와 "통신 끊김")
}

-- 자율주행 로버 위치 (CONTRACT_V2 rover.fsd). 자율주행 중이 아니면 nil
function Rules.roverFsdView(state: State, config: Config): FsdView?
    local rover = state.rover
    local trip = rover.trip
    if rover.status ~= "fsd" or trip == nil then
        return nil
    end
    local sep, gst = Rules.weatherOn(state)
    local stoppedBy = if gst then "GST" elseif sep then "SEP" else nil
    if rover.recovering then
        local days = missionOf(state, config).rover.remoteRecoverDays
        return {
            siteIndex = trip.siteIndex,
            phase = "return",
            progress = math.clamp(1 - rover.recoverLeft / math.max(1, days), 0, 1),
            rush = false,
            recovering = true,
            stoppedBy = stoppedBy,
        }
    end
    local progress = math.clamp(trip.elapsed / trip.totalDays, 0, 1)
    return {
        siteIndex = trip.siteIndex,
        phase = if trip.collected then "return" else "out",
        progress = progress,
        rush = trip.rush,
        recovering = false,
        stoppedBy = stoppedBy,
    }
end

return Rules
