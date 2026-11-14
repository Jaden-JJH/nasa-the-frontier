-- v2 C 식량 기지 플레이어 봇 (Q31: 완벽, 한 번 해 본 사람, 처음 하는 사람). 솔로 + 자율주행(FSD) 기준.
-- tests/bot.luau(v1)의 프로필 방식을 따른다: 사람 프로필 값은 관찰 가정이라 MissionConfig가 아니라 여기 둔다.
-- 규칙은 src/shared/Rules.luau만 부른다. 봇 자신의 난수(늦장, 깜빡함, 산소 실수)는 규칙 난수와 따로 시드로 만든다.
--
-- 하루에 하는 일 (순서는 프로필 priority):
--   로버 돌보기(고장이면 걸어서 수리 또는 원격 회수, 파손이면 주차 자리 수리) -> 에어록 점검
--   -> "panels" 패널 설치, "build" 다음 시설 착공, "rover" 자율주행 파견 -> 멈춤 조작 -> 산소 실수 굴림
-- 완벽 봇은 계획을 세운다: 아래 PERFECT_VARIANTS 조합을 모두 같은 시드로 해 보고 가장 좋은 판을 고른다
-- (메달 > 금이면 빠른 날 > 점수). 사람 봇은 한 가지 방식으로 한 번만 한다.

local Rules = require("../src/shared/Rules")

-- 우주 기상 테스트 구간 (리드가 만드는 src/shared/SpaceWeatherData.luau가 없을 때 쓰는 합성 픽스처).
-- Q14 규칙(SEP 2~4건, 사건마다 1~2일, GST 2~4건, Kp 6 이상, 1일)에 맞춰 날짜만 지어낸 값이다. 실제 DONKI 기록이 아니다.
-- 시작 날짜는 V2_PLAN 6.2의 후보 구간을 빌렸다 (표시용)
local WEATHER_FIXTURES = {
    {
        id = "fx1-2024-07-26",
        startDate = { year = 2024, month = 7, day = 26 },
        events = {
            { kind = "SEP", day = 8, durationDays = 2 },
            { kind = "GST", day = 15, durationDays = 1, kp = 7 },
            { kind = "SEP", day = 27, durationDays = 1 },
            { kind = "GST", day = 33, durationDays = 1, kp = 6 },
            { kind = "SEP", day = 44, durationDays = 2 },
            { kind = "GST", day = 51, durationDays = 1, kp = 8 },
        },
    },
    {
        id = "fx2-2024-03-15",
        startDate = { year = 2024, month = 3, day = 15 },
        events = {
            { kind = "GST", day = 6, durationDays = 1, kp = 6 },
            { kind = "SEP", day = 12, durationDays = 2 },
            { kind = "GST", day = 20, durationDays = 1, kp = 7 },
            { kind = "GST", day = 29, durationDays = 1, kp = 6 },
            { kind = "SEP", day = 38, durationDays = 2 },
            { kind = "GST", day = 47, durationDays = 1, kp = 7 },
        },
    },
    {
        id = "fx3-2025-10-17",
        startDate = { year = 2025, month = 10, day = 17 },
        events = {
            { kind = "SEP", day = 5, durationDays = 1 },
            { kind = "SEP", day = 18, durationDays = 2 },
            { kind = "GST", day = 24, durationDays = 1, kp = 8 },
            { kind = "SEP", day = 31, durationDays = 1 },
            { kind = "GST", day = 40, durationDays = 1, kp = 6 },
            { kind = "SEP", day = 52, durationDays = 2 },
        },
    },
    {
        id = "fx4-2023-07-14",
        startDate = { year = 2023, month = 7, day = 14 },
        events = {
            { kind = "GST", day = 3, durationDays = 1, kp = 6 },
            { kind = "SEP", day = 10, durationDays = 1 },
            { kind = "SEP", day = 25, durationDays = 2 },
            { kind = "SEP", day = 41, durationDays = 2 },
            { kind = "GST", day = 57, durationDays = 1, kp = 7 },
        },
    },
    {
        id = "fx5-2022-08-12",
        startDate = { year = 2022, month = 8, day = 12 },
        events = {
            { kind = "GST", day = 9, durationDays = 1, kp = 7 },
            { kind = "SEP", day = 16, durationDays = 2 },
            { kind = "GST", day = 35, durationDays = 1, kp = 6 },
            { kind = "GST", day = 36, durationDays = 1, kp = 6 },
            { kind = "SEP", day = 49, durationDays = 1 },
        },
    },
}

local function merge(...: any): any
    local out = {}
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if t then
            for k, v in t do
                out[k] = v
            end
        end
    end
    return out
end

-- 공통 기본값 (프로필이 덮어쓴다) -------------------------------------------------
local BASE = {
    idleStartDays = 0, -- 시작 n일은 화면을 익히느라 아무것도 하지 않는다
    airlockDay = 1, -- 이날부터 에어록 점검
    priority = { "panels", "build", "rover" },
    panelEarlyDays = 0, -- 이 날까지는 panelEarlyPerDay장만
    panelEarlyPerDay = 2,
    panelSkipChance = 0, -- 설치할 날 중 이 확률로 건너뜀
    panelEnergyFloor = 0, -- 설치 뒤 에너지가 이 값 이상일 때만
    firstTripDay = 1, -- 첫 파견 가장 이른 날
    firstTripWaterDays = nil :: number?, -- 있으면 물 남은 일수가 이 이하일 때 첫 파견 (위기 전엔 안 움직임)
    dispatchChance = 1, -- 로버가 기지에 있을 때 그날 보내는 확률 (나머지는 깜빡함)
    targetRule = "best", -- "best"(하루당 물 최대, 같으면 에너지 적은 곳) | "nearest"(거리)
    rushChance = 0, -- 서둘러 가기가 시간을 줄일 때 고르는 확률
    rushWhenShort = false, -- 물이 왕복 동안 못 버티면 서둘러 간다 (완벽)
    avoidOverflow = false, -- 돌아왔을 때 물이 상한을 넘으면 보내지 않는다
    overflowSlack = 0,
    tripEnergyFloor = 0, -- 파견 뒤 에너지가 이 값 이상일 때만
    buildOrder = { "farm", "led", "nutrient", "pipe", "hydroponics" },
    strictOrder = false, -- 다음 시설을 못 지으면 뒤 시설을 보지 않고 모은다
    buildEnergyFloor = 0, -- 착공 뒤 에너지 하한
    buildWaterFloorDays = 0, -- 착공 뒤 물이 (하루 물 사용 x 이 일수) 이상
    buildWaterFloor = 0, -- 착공 뒤 물 하한 (위 값과 큰 쪽)
    buildDelayDays = 0, -- 지을 수 있게 된 뒤 이만큼 늦게 착공 (알림을 보고 패드까지 간다)
    upgradeDelayDays = 0, -- 재배 공간 완공 뒤 업그레이드를 알아채기까지
    pipeDelayDays = 0, -- 파이프 해금 뒤 알아채기까지
    pipeAfterSilver = false, -- 은메달 시설을 다 지은 뒤에야 파이프를 생각한다
    pipeSite = "farthest", -- "farthest" | "nearest" | "random"
    oneBuildPerDay = true,
    knowsPauseChance = 0, -- 멈춤 기능을 아는 사람 비율 (게임마다 한 번 굴림)
    pausePolicy = "stall", -- "stall"(정지를 막으려고 덜 중요한 시설부터 멈춤) | "farmWater"(물이 적으면 재배 공간 멈춤)
    pauseOrder = { "led", "airlock", "nutrient", "hydroponics", "pipe", "farm" },
    pauseWaterDays = 3,
    resumeWaterDays = 6,
    farmPauseFood = 85, -- "save": 식량이 이 이상이면 재배 공간 멈춤
    farmResumeFood = 45, -- "save": 이 이하이면 다시 켬
    ledResumeFood = 30, -- "save": 식량이 이 미만이면 LED를 켜서 수확을 당긴다
    pipePauseWater = 95, -- "save": 물이 이 이상이면 파이프 멈춤
    repairDamageAt = 1, -- 기지에서 파손이 이 값 이상이면 수리
    repairEnergyFloor = 0,
    repairDelayDays = 0, -- 파손, 고장 알림 뒤 이만큼 지나서 손댄다
    walkRepairChance = 1, -- 걸어서 수리할 수 있을 때 고르는 확률
    oxygenChance = 0, -- 야외 일을 한 날 산소 실수로 구조될 확률 (에어록 가동 중)
    oxygenNoAirlockMultiplier = 3, -- 에어록이 안 돌면 위 확률 x이 값 (회복할 곳이 로버 좌석뿐)
    -- 위기 반응: 물이 이 일수분 아래거나 부족 경고(0)가 뜨면 늦장 없이 로버를 고치고 보낸다 (붉은 경고 배너)
    urgentWaterDays = 2,
    -- 하루 행동 예산 (하루 30초). 착륙선 콘솔 파견, 솔라 필드(150 studs)에서 패널 2장(3초 x 2),
    -- 재배 공간 자리(217 studs)에서 착공은 각각 10초 안팎이 걸린다 (걷기 16 studs/s, Q19 실측 위치)
    actionsPerDay = 3,
    extraActionChance = 0,
    chooser = "priority", -- "priority"(priority 순서) | "weighted"(weights 가중치로 무작위)
    weights = { panels = 1, rover = 1, build = 1 },
    lowWaterLevel = 30,
    urgentRoverWeight = 3,
    fullWaterLevel = 101, -- 물이 이 값 이상이면 로버를 보내지 않는다 (탱크가 가득 찬 것을 본다). 101이면 안 봄
    -- 식량 위기: 재배 공간이 없고 식량이 이 값 미만이면 재배 공간을 늦장 없이 가장 먼저 (HUD 경고와 미션 안내)
    foodUrgentLevel = 40,
    urgentBuildWeight = 3,
    trace = nil :: ((day: number, state: any) -> ())?, -- 디버그: 하루 마감 직전 상태
    -- 멀티 (players 2 이상). 수동 운전 값은 v1 로버(18 studs/s, 부스터 x1.6, 4초 켜고 6초 식힘)와 RoverPark 거리
    players = 1,
    departChance = 1, -- 운전할 수 있을 때 바로 떠나는 확률
    manualDetour = 1.25, -- 실제 경로 / 직선 (관제사 안내 있음)
    gstDetourExtra = 0.15, -- GST: 지도와 핀이 끊겨 더 돌아간다 [Q14]
    boostShare = 0.3, -- 부스터를 쓰는 시간 비율 (과열 한도 0.4)
    lostSecondsMax = 0, -- 왕복마다 길을 헤매는 시간 0 ~ 이 값(초)
    manualDamageChance = 0.1, -- 왕복마다 바위 충돌 파손 확률
    manualRepairAt = 2, -- 파손이 이만큼 쌓이면 현장 R 수리 (에너지 10)
    controllerOutdoorShare = 0.3, -- 관제사가 그날 밖에 나가 일 하나를 하는 확률
    secondsPerAction = 12, -- 운전하지 않은 시간에서 일 하나에 드는 초 (걷기 + 홀드)
    coordinationLoss = 0, -- 팀 행동 중 손발이 안 맞아 잃는 비율
    skillRange = nil :: { number }?, -- 있으면 판마다 실력을 뽑아 SKILL_SPAN 값을 덮어쓴다 (완벽은 없음)
    farmFirst = false,
    airlockWhenEnergy = false,
}

-- 사람 계열 프로필 (2026-11-14 새 목표). 판단 구조는 모두 같고(가중치 무작위 선택, 위기 반응, 실력 값) 실력 범위만 다르다.
-- 고정 값은 실력과 무관한 관찰 가정이다
local SKILL_PLAYER = {
    idleStartDays = 1, -- 첫날은 화면을 익힌다
    airlockDay = 2, -- 첫 미션 "에어록 점검" [Q28]
    actionsPerDay = 1, -- 하루 30초에 걸어서 하는 일 1개 (+ extraActionChance)
    chooser = "weighted",
    panelEarlyDays = 10,
    firstTripDay = 3,
    fullWaterLevel = 92, -- 물탱크가 거의 가득이면 로버를 안 보낸다
    repairDamageAt = 2,
    repairDelayDays = 1,
    walkRepairChance = 0.7,
    oxygenChance = 0.02,
    boostShare = 0.35,
    manualRepairAt = 2,
}

local HUMAN = merge(SKILL_PLAYER, { skillRange = { 0, 0.65 } })
local SEMI = merge(SKILL_PLAYER, { skillRange = { 0.1, 0.8 } })
local MULTI_FIRST = merge(SKILL_PLAYER, { skillRange = { 0, 0.65 } })
local MULTI_SECOND = merge(SKILL_PLAYER, { skillRange = { 0.1, 0.8 } })

-- 완벽: 사람 실수 없음. 아래 변형 중 가장 좋은 판을 고른다 (계획)
local PERFECT = {
    idleStartDays = 0,
    airlockDay = 1,
    dispatchChance = 1,
    targetRule = "best",
    rushWhenShort = true,
    avoidOverflow = true,
    overflowSlack = 5,
    strictOrder = true,
    knowsPauseChance = 1,
    pausePolicy = "stall",
    repairDamageAt = 2,
    walkRepairChance = 1,
    oxygenChance = 0,
}

local PERFECT_VARIANTS_BASE = {
    {
        priority = { "panels", "rover", "build" },
        buildOrder = { "farm", "pipe", "led", "nutrient", "hydroponics" },
        buildEnergyFloor = 20,
        buildWaterFloor = 20,
        panelEnergyFloor = 12,
        tripEnergyFloor = 12,
    },
    {
        priority = { "panels", "rover", "build" },
        buildOrder = { "farm", "led", "nutrient", "pipe", "hydroponics" },
        buildEnergyFloor = 20,
        buildWaterFloor = 20,
        panelEnergyFloor = 12,
        tripEnergyFloor = 12,
    },
    {
        priority = { "rover", "build", "panels" },
        buildOrder = { "farm", "pipe", "led", "nutrient", "hydroponics" },
        buildEnergyFloor = 20,
        buildWaterFloor = 20,
        panelEnergyFloor = 20,
        tripEnergyFloor = 12,
    },
    {
        priority = { "panels", "rover", "build" },
        buildOrder = { "pipe", "farm", "led", "nutrient", "hydroponics" },
        buildEnergyFloor = 20,
        buildWaterFloor = 20,
        panelEnergyFloor = 12,
        tripEnergyFloor = 12,
    },
    {
        priority = { "panels", "rover", "build" },
        buildOrder = { "farm", "pipe", "led", "nutrient", "hydroponics" },
        buildEnergyFloor = 0,
        buildWaterFloor = 10,
        panelEnergyFloor = 0,
        tripEnergyFloor = 0,
        strictOrder = false,
    },
    {
        priority = { "rover", "panels", "build" },
        buildOrder = { "farm", "pipe", "led", "nutrient", "hydroponics" },
        buildEnergyFloor = 10,
        buildWaterFloor = 15,
        panelEnergyFloor = 8,
        tripEnergyFloor = 8,
        pipeSite = "nearest",
    },
}

-- 각 변형을 멈춤 방식 두 가지("stall" 정지만 막기, "save" 아껴 모으기)로 모두 해 본다
local PERFECT_VARIANTS = {}
for _, policy in { "stall", "save" } do
    for _, variant in PERFECT_VARIANTS_BASE do
        local v = table.clone(variant)
        v.pausePolicy = policy
        table.insert(PERFECT_VARIANTS, v)
    end
end

local function makeRng(seed: number): () -> number
    local value = math.floor(math.abs(seed)) % 2147483647
    if value == 0 then
        value = 1
    end
    local function nextValue(): number
        value = (value * 48271) % 2147483647
        return value / 2147483647
    end
    for _ = 1, 3 do
        nextValue()
    end
    return nextValue
end

local MEDAL_RANK = { gold = 3, silver = 2, bronze = 1 }

export type GameResult = {
    profile: string,
    window: string,
    seed: number,
    outcome: string,
    medal: string?,
    reason: string?,
    daysTaken: number,
    score: number,
    deductions: { any },
    bronzeDay: number,
    silverDay: number,
    goldDay: number,
    pipeDay: number,
    trips: number,
    breakdowns: number,
    rescues: number,
    stallDays: number,
    wastedWater: number,
    minFood: number,
    minWater: number,
    stats: { [string]: number },
    players: number,
    manualTrips: number,
    skill: number?,
    lossResource: string?,
    variant: number?,
}

local function exists(s, defId: string): boolean
    for _, f in s.facilities do
        if f.defId == defId then
            return true
        end
    end
    return false
end

local function dailyWater(s, config): number
    local f = Rules.flows(s, config)
    return f.crew.water + f.upkeepWater
end

-- 한 판 (프로필 값 P로). config는 MissionConfig 또는 덮어쓴 복사본
-- 실력 (2026-11-14 새 목표: 처음 실패 50%, 두 번째 실패 30% 등). 사람 계열 프로필은 모두 같은 판단 구조를 쓰고
-- 판마다 실력 u(0 ~ 1)를 프로필의 skillRange에서 고르게 뽑아 아래 값을 약함(u = 0)과 강함(u = 1) 사이로 정한다.
-- 실패, 동, 은, 금의 분포는 이 퍼짐에서 나온다. 범위(가정): 처음 하는 사람과 처음 하는 팀 0 ~ 0.65,
-- 두 번째부터 0.1 ~ 0.8 (두 번째에도 30%가 실패한다는 목표는 실력이 낮은 두 번째 플레이어가 꽤 있다는 뜻)
local SKILL_SPAN = {
    extraActionChance = { 0, 0.8 }, -- 하루 일 1개 + 이 확률로 하나 더
    dispatchChance = { 0.35, 1 }, -- 로버가 기지에 있을 때 그날 보내는 확률
    departChance = { 0.4, 1 }, -- 멀티: 운전할 수 있을 때 떠나는 확률
    buildDelayDays = { 3, 0 },
    upgradeDelayDays = { 6, 0 },
    pipeDelayDays = { 6, 1 },
    knowsPauseChance = { 0.1, 0.9 },
    foodUrgentLevel = { 10, 50 }, -- 약하면 식량이 거의 바닥나서야 재배 공간을 짓는다
    urgentWaterDays = { 0.5, 3 }, -- 약하면 물이 거의 바닥나서야 로버를 보낸다
    lowWaterLevel = { 10, 35 },
    buildEnergyFloor = { 0, 15 }, -- 강하면 착공 뒤에도 에너지를 남긴다
    buildWaterFloor = { 0, 20 },
    rushChance = { 0.4, 0.05 },
    coordinationLoss = { 0.35, 0 }, -- 멀티: 손발이 안 맞아 잃는 행동 비율
    manualDetour = { 1.45, 1.15 },
    lostSecondsMax = { 20, 0 },
    manualDamageChance = { 0.2, 0.05 },
    controllerOutdoorShare = { 0.4, 0.8 },
}
local SKILL_INTEGER = { buildDelayDays = true, upgradeDelayDays = true, pipeDelayDays = true }
-- 계획(지은 업그레이드 멈춰 아끼기, 파이프를 먼 곳에)을 세울 확률: 실력 PLANNER_FROM에서 0, PLANNER_FULL에서 1로 오른다
local PLANNER_FROM = 0.6
local PLANNER_FULL = 1.0
local FARM_FIRST_SKILL = 0.4 -- 이 이상이면 재배 공간을 첫 건설로
local AIRLOCK_ENERGY_SKILL = 0.6 -- 이 이상이면 패널 발전이 대원 소비 + 5를 넘을 때 에어록 점검

local function applySkill(P, u: number, planRoll: number)
    for key, span in SKILL_SPAN do
        local value = span[1] + (span[2] - span[1]) * u
        if SKILL_INTEGER[key] then
            value = math.floor(value + 0.5)
        end
        P[key] = value
    end
    P.panelEarlyPerDay = if u < 0.5 then 1 else 2
    P.weights = {
        panels = 1,
        rover = if P.players and P.players > 1 then 0 else 1 + 0.5 * u,
        build = 1.2 + 1.3 * u,
    }
    -- 시작 운영: 실력이 있으면 재배 공간부터 짓고(식량이 버틸 시간), 더 있으면 패널 발전이 대원 소비를 덮을 때까지
    -- 에어록 점검(유지 E2 W1)을 미룬다. 약하면 튜토리얼 순서(에어록 -> 패널 -> 로버 -> 재배 공간)
    P.farmFirst = u >= FARM_FIRST_SKILL
    P.airlockWhenEnergy = u >= AIRLOCK_ENERGY_SKILL
    local planChance = math.clamp((u - PLANNER_FROM) / (PLANNER_FULL - PLANNER_FROM), 0, 1)
    if planRoll < planChance then
        P.pausePolicy = "save"
        P.knowsPauseChance = 1
        P.pipeSite = "farthest"
    else
        P.pausePolicy = "farmWater"
        P.pipeSite = "random"
    end
    P.skill = u
end

local function playGame(config, P, window, seed: number, profileName: string): GameResult
    local m = config.MISSIONS.C
    -- 시드를 비선형으로 섞는다. LCG에 seed x 상수를 바로 넣으면 이웃 시드의 첫 값들이 주기 3으로 되풀이되어
    -- 실력이 세 가지 값으로만 뽑혔다 (2026-11-14 발견)
    local mixed = math.sin(seed * 12.9898 + 78.233) * 43758.5453
    local rng = makeRng(math.floor((mixed - math.floor(mixed)) * 2147483645) + 1)
    if P.skillRange then
        -- 실력은 황금비 수열로 시드마다 고르게 퍼뜨린다 (시드 40개면 범위를 촘촘히 덮는다)
        local spread = (seed * 0.6180339887498949) % 1
        applySkill(P, P.skillRange[1] + spread * (P.skillRange[2] - P.skillRange[1]), rng())
    end
    local players = P.players or 1
    local multi = players > 1
    local s = Rules.newState("C", config, seed, window, { players = players })
    local knowsPause = rng() < P.knowsPauseChance
    local readySince: { [string]: number } = {}
    local brokenSince: number? = nil
    local damagedSince: number? = nil
    local tripped = false
    local farmDoneDay: number? = nil
    local pipeUnlockDay: number? = nil
    local bronzeDay, silverDay, goldDay, pipeDay = 0, 0, 0, 0
    local minFood, minWater = math.huge, math.huge
    local maxDamage = m.rover.maxDamage

    local function try(fn, ...): boolean
        local ok, new = fn(s, config, ...)
        if ok then
            s = new
        end
        return ok
    end

    local function availableSites(): { number }
        local list = {}
        for index, site in s.sites do
            if site.cooldownLeft <= 0 and site.pipeId == nil then
                table.insert(list, index)
            end
        end
        return list
    end

    local function pickTarget(): number?
        local list = availableSites()
        if #list == 0 then
            return nil
        end
        if P.targetRule == "nearest" then
            return list[1] -- sites는 가까운 순
        end
        local best, bestRate, bestEnergy = nil, -1, math.huge
        for _, index in list do
            local plan = Rules.tripPlan(s, config, index, false)
            if plan then
                local rate = m.ice.amountPerTrip / plan.days
                if
                    rate > bestRate + 1e-9
                    or (math.abs(rate - bestRate) <= 1e-9 and plan.energy < bestEnergy)
                then
                    best, bestRate, bestEnergy = index, rate, plan.energy
                end
            end
        end
        return best
    end

    local function pickPipeSite(): number?
        local list = {}
        for index, site in s.sites do
            if site.pipeId == nil then
                table.insert(list, index)
            end
        end
        if #list == 0 then
            return nil
        end
        if P.pipeSite == "nearest" then
            return list[1]
        elseif P.pipeSite == "random" then
            return list[math.min(#list, 1 + math.floor(rng() * #list))]
        end
        return list[#list]
    end

    local outdoorToday = false
    local urgent = false

    local function stepPanels(day: number): boolean
        if s.panels >= m.panels.total then
            return false
        end
        if P.panelSkipChance > 0 and rng() < P.panelSkipChance then
            return false
        end
        local acted = false
        local perDay = if day <= P.panelEarlyDays then P.panelEarlyPerDay else m.panels.perDay
        for _ = 1, perDay do
            -- 에너지가 비용보다 적으면 규칙의 구조 장치(emergencyInstall)에 맡기고 시도한다
            if s.energy >= m.panels.cost and s.energy - m.panels.cost < P.panelEnergyFloor then
                break
            end
            if try(Rules.installPanel) then
                outdoorToday = true
                acted = true
            else
                break
            end
        end
        return acted
    end

    local function foodUrgent(): boolean
        return not exists(s, "farm") and (P.farmFirst or s.food < P.foodUrgentLevel)
    end

    local function stepBuild(day: number): boolean
        local acted = false
        if foodUrgent() then
            if try(Rules.startBuild, "farm") then
                outdoorToday = true
                return true
            end
            return false
        end
        for _, defId in P.buildOrder do
            if not exists(s, defId) then
                local def = m.facilities[defId]
                local noticed = true
                if def.kind == "upgrade" then
                    noticed = farmDoneDay ~= nil
                        and day >= (farmDoneDay :: number) + P.upgradeDelayDays
                end
                if defId == "pipe" then
                    noticed = pipeUnlockDay ~= nil
                        and day >= (pipeUnlockDay :: number) + P.pipeDelayDays
                    if P.pipeAfterSilver and silverDay == 0 then
                        noticed = false
                    end
                end
                if defId == "hydroponics" and not Rules.isBuilt(s, "pipe") then
                    noticed = false
                end
                if noticed then
                    local site = if defId == "pipe" then pickPipeSite() else nil
                    local ok = Rules.canBuild(s, config, defId, site)
                    local afford = ok
                    if ok then
                        local floorWater = math.max(
                            P.buildWaterFloor,
                            dailyWater(s, config) * P.buildWaterFloorDays
                        )
                        afford = s.energy - def.cost.energy >= P.buildEnergyFloor
                            and s.water - def.cost.water >= floorWater
                    end
                    if afford then
                        readySince[defId] = readySince[defId] or day
                        if day - readySince[defId] >= P.buildDelayDays then
                            if try(Rules.startBuild, defId, site) then
                                readySince[defId] = nil
                                acted = true
                                if def.buildFrom == "outdoor" then
                                    outdoorToday = true
                                end
                                if P.oneBuildPerDay then
                                    return true
                                end
                            end
                        elseif P.strictOrder then
                            return acted
                        end
                    else
                        readySince[defId] = nil
                        if P.strictOrder then
                            return acted
                        end
                    end
                elseif P.strictOrder and def.kind ~= "upgrade" and defId ~= "pipe" then
                    return acted
                end
            end
        end
        return acted
    end

    local function stepRover(day: number): boolean
        if s.rover.status ~= "parked" or s.rover.damage >= maxDamage then
            return false
        end
        if not tripped then
            if day < P.firstTripDay then
                return false
            end
            if P.firstTripWaterDays then
                local use = math.max(1, dailyWater(s, config))
                if s.water / use > P.firstTripWaterDays then
                    return false
                end
            end
        end
        if s.water >= P.fullWaterLevel then
            return false
        end
        if not urgent and P.dispatchChance < 1 and rng() >= P.dispatchChance then
            return false
        end
        local target = pickTarget()
        if target == nil then
            return false
        end
        local plan = Rules.tripPlan(s, config, target, false)
        if plan == nil then
            return false
        end
        local use = dailyWater(s, config)
        if P.avoidOverflow then
            local onReturn = s.water - use * plan.days + m.ice.amountPerTrip
            if onReturn > s.cap + P.overflowSlack then
                return false
            end
        end
        local rush = false
        if plan.rushHelps then
            local short = P.rushWhenShort and s.water - use * plan.days <= 0
            rush = short or (P.rushChance > 0 and rng() < P.rushChance)
        end
        local final = Rules.tripPlan(s, config, target, rush)
        if final == nil or s.energy - final.energy < P.tripEnergyFloor then
            return false
        end
        if try(Rules.dispatchRover, target, rush) then
            tripped = true
            return true
        end
        return false
    end

    local function stepRoverCare(day: number): boolean
        if s.rover.status == "broken" then
            brokenSince = brokenSince or day
            if urgent or day >= (brokenSince :: number) + P.repairDelayDays then
                if Rules.canWalkRepair(s, config) and rng() < P.walkRepairChance then
                    if try(Rules.walkRepairRover) then
                        outdoorToday = true
                        brokenSince = nil
                        return true
                    end
                end
                if try(Rules.remoteRecoverRover) then
                    brokenSince = nil
                    return true
                end
            end
            return false
        end
        brokenSince = nil
        if s.rover.status == "parked" and s.rover.damage > 0 then
            damagedSince = damagedSince or day
            local must = s.rover.damage >= maxDamage
            local want = s.rover.damage >= P.repairDamageAt
                and s.energy - m.rover.repairEnergy >= P.repairEnergyFloor
            local waited = day >= (damagedSince :: number) + P.repairDelayDays
            if (must or want) and (waited or (urgent and must)) then
                if try(Rules.repairRover) then
                    outdoorToday = true
                    damagedSince = nil
                    return true
                end
            end
        else
            damagedSince = nil
        end
        return false
    end

    local function stepPause()
        if not knowsPause then
            return
        end
        if P.pausePolicy == "farmWater" then
            local farm = s.facilities.farm
            if farm and farm.status == "active" then
                local use = math.max(1, dailyWater(s, config))
                if not farm.paused and s.water / use <= P.pauseWaterDays then
                    try(Rules.setPaused, "farm", true)
                elseif farm.paused and s.water / use >= P.resumeWaterDays then
                    try(Rules.setPaused, "farm", false)
                end
            end
            return
        end
        if P.pausePolicy == "save" then
            -- 계획(완벽): 메달은 "지은 것"으로 세므로 다 지은 업그레이드는 멈춰 유지비를 아끼고 다음 건설에 모은다.
            -- 식량이 넉넉하면 재배 공간도 멈추고(업그레이드 유지비도 같이 0), 모자라면 다시 켠다. 물이 가득이면 파이프를 멈춘다
            local farm = s.facilities.farm
            if farm and farm.status == "active" then
                if not farm.paused and s.food >= P.farmPauseFood then
                    try(Rules.setPaused, "farm", true)
                elseif farm.paused and s.food <= P.farmResumeFood then
                    try(Rules.setPaused, "farm", false)
                end
            end
            for _, id in { "led", "nutrient" } do
                local f = s.facilities[id]
                if f and f.status == "active" then
                    local wantRun = id == "led" and s.food < P.ledResumeFood
                    if f.paused and wantRun then
                        try(Rules.setPaused, id, false)
                    elseif not f.paused and not wantRun then
                        try(Rules.setPaused, id, true)
                    end
                end
            end
            for _, f in s.facilities do
                if f.defId == "pipe" and f.status == "active" then
                    if not f.paused and s.water >= P.pipePauseWater then
                        try(Rules.setPaused, f.id, true)
                    elseif f.paused and s.water < P.pipePauseWater - 20 then
                        try(Rules.setPaused, f.id, false)
                    end
                end
            end
        end
        -- "stall"과 "save": 내일 정지가 예상되면 덜 중요한 시설부터 멈추고, 여유가 생기면 거꾸로 켠다
        if P.pausePolicy == "save" and not Rules.flows(s, config).stalled then
            return
        end
        local flows = Rules.flows(s, config)
        if flows.stalled then
            for _, id in P.pauseOrder do
                local f = s.facilities[id]
                if f and f.status == "active" and not f.paused then
                    try(Rules.setPaused, id, true)
                    if not Rules.flows(s, config).stalled then
                        break
                    end
                end
            end
        else
            for i = #P.pauseOrder, 1, -1 do
                local id = P.pauseOrder[i]
                local f = s.facilities[id]
                if f and f.paused then
                    local probe = Rules.copy(s)
                    probe.facilities[id].paused = false
                    local after = Rules.flows(probe, config)
                    if
                        not after.stalled
                        and probe.energy
                                + after.panelEnergy
                                - after.crew.energy
                                - after.upkeepEnergy
                            >= 10
                    then
                        try(Rules.setPaused, id, false)
                    end
                end
            end
        end
    end

    -- 멀티 수동 운전 (탐사대원 1명이 로버 1대를 몬다). 시간은 초 단위로 따라가고 하루 경계(30초)를 넘을 수 있다.
    -- 지점 거리는 RoverPark 기준 지점별 실측 (MissionConfig manualDriveDistances)
    local md = config.MANUAL_DRIVE
    local manualDist = m.manualDriveDistances
    local battery = md.batteryMax
    local manualTrip: any = nil
    local driverFreeAt = 0
    local manualDamage = 0
    local manualTrips = 0

    local function chargeRover()
        local need = md.batteryMax - battery
        if need > 0 then
            local ok, new, paid = Rules.payEnergy(s, config, need, "rover_charge")
            if ok then
                s = new
                battery += paid
            end
        end
    end

    -- 오늘 탐사대원의 운전. 반환: 운전하지 않고 남은 초 (다른 일을 할 시간)
    local function stepDriver(day: number): number
        local daySeconds = config.DAY_SECONDS
        local dayStart, dayEnd = (day - 1) * daySeconds, day * daySeconds
        local sep, gst = Rules.weatherOn(s)
        if sep then
            -- SEP: 로버가 멈추고 밖에 못 나간다 [Q15]. 운전 중이면 남은 일정이 하루 밀린다
            if manualTrip then
                manualTrip.collectAt += daySeconds
                manualTrip.arriveAt += daySeconds
            end
            driverFreeAt = math.max(driverFreeAt, dayEnd)
            return 0
        end
        if day <= P.idleStartDays then
            return daySeconds
        end
        local t = math.max(driverFreeAt, dayStart)
        local idle = 0
        for _ = 1, 8 do
            if t >= dayEnd then
                break
            end
            if manualTrip then
                if not manualTrip.collected and manualTrip.collectAt < dayEnd then
                    manualTrip.collected = true
                    manualTrip.amount = if try(Rules.collectIce, manualTrip.siteIndex)
                        then m.ice.amountPerTrip
                        else 0
                end
                if manualTrip.arriveAt >= dayEnd then
                    return idle
                end
                t = manualTrip.arriveAt
                if manualTrip.amount > 0 then
                    try(Rules.deliverWater, manualTrip.amount)
                end
                manualTrip = nil
                if rng() < P.manualDamageChance then
                    manualDamage += 1
                end
                if manualDamage >= P.manualRepairAt then
                    local ok, new = Rules.payEnergy(s, config, md.repairEnergy, "rover_repair")
                    if ok then
                        s = new
                    end
                    manualDamage = 0
                    t += md.repairSeconds + 6
                end
                chargeRover()
                driverFreeAt = t
            else
                -- 출발 판단 (첫 출발일, 물이 가득이면 안 감, 처음 하는 팀은 딴 일을 하다 놓친다)
                local go = day >= P.firstTripDay and s.water < P.fullWaterLevel
                -- 식량 위기인데 재배 공간이 없으면 오늘은 운전 대신 짓는다 (물도 위기면 운전)
                if go and foodUrgent() and not urgent and t <= dayStart then
                    go = false
                end
                if go and not urgent and P.departChance < 1 and rng() >= P.departChance then
                    go = false
                end
                -- 수동 운전은 RoverPark에서 가장 가까운 채취 가능 지점으로
                local target: number? = nil
                local targetDistance = math.huge
                if go then
                    for index, site in s.sites do
                        local d = manualDist[site.id] or site.distance
                        if site.cooldownLeft <= 0 and site.pipeId == nil and d < targetDistance then
                            target, targetDistance = index, d
                        end
                    end
                end
                local plan: any = nil
                if target then
                    local distance = targetDistance
                    local detour = P.manualDetour + (if gst then P.gstDetourExtra else 0)
                    local boost = math.min(
                        P.boostShare,
                        md.v1BoostOnSeconds / (md.v1BoostOnSeconds + md.v1BoostCooldownSeconds)
                    )
                    local speed = md.v1MaxSpeed * (1 + boost * (md.v1BoostMultiplier - 1))
                    local drive = 2 * distance * detour / speed
                    local lost = rng() * P.lostSecondsMax
                    local drain = (drive + lost)
                        * md.batteryDrainPerSecond
                        * (1 + boost * (md.boostDrainMultiplier - 1))
                    if battery < drain then
                        chargeRover()
                    end
                    if battery >= drain then
                        plan = {
                            siteIndex = target,
                            collectAt = t + (drive + lost) / 2 + md.fillSeconds,
                            arriveAt = t + drive + lost + md.fillSeconds + md.unloadSeconds,
                            collected = false,
                            amount = 0,
                        }
                        battery -= drain
                    end
                end
                if plan then
                    manualTrip = plan
                    manualTrips += 1
                    tripped = true
                else
                    idle += dayEnd - t
                    t = dayEnd
                end
            end
        end
        return idle
    end

    for _ = 1, config.TOTAL_DAYS do
        local day = s.day
        outdoorToday = false
        urgent = s.shortageDays > 0
            or s.water < math.max(1, dailyWater(s, config)) * P.urgentWaterDays
        if day > P.idleStartDays then
            -- 하루 행동 예산: 걸어서 하는 일(패널, 착공, 수리)과 콘솔 파견이 각각 1. 멈춤 조작은 무료
            local budget = P.actionsPerDay
            if P.extraActionChance > 0 and rng() < P.extraActionChance then
                budget += 1
            end
            if multi then
                -- 팀 행동 예산 (V2_PLAN 15.3 역할): 관제사는 지도와 핀을 보느라 가끔만 나가고, 엔지니어와 둘째 탐사대원은
                -- 한 사람 몫, 운전하는 탐사대원은 운전하지 않은 시간만큼. 처음 하는 팀은 손발이 안 맞아 일부를 잃는다
                local idle = stepDriver(day)
                budget = 0
                for _ = 3, players do
                    local slots = P.actionsPerDay
                    if P.extraActionChance > 0 and rng() < P.extraActionChance then
                        slots += 1
                    end
                    budget += slots
                end
                -- 관제사: 탐사대원이 운전하는 동안 안내하고 남는 시간에 일한다
                local controllerSlots = P.actionsPerDay
                if P.extraActionChance > 0 and rng() < P.extraActionChance then
                    controllerSlots += 1
                end
                for _ = 1, controllerSlots do
                    if rng() < P.controllerOutdoorShare then
                        budget += 1
                    end
                end
                budget += math.floor(idle / P.secondsPerAction)
                local kept = 0
                for _ = 1, budget do
                    if rng() >= P.coordinationLoss then
                        kept += 1
                    end
                end
                budget = kept
            end
            if stepRoverCare(day) then
                budget -= 1
            end
            local airlockReady = not P.airlockWhenEnergy
                or s.panels * m.panels.output >= Rules.crewUse(s, config).energy + 5
            if budget > 0 and not exists(s, "airlock") and day >= P.airlockDay and airlockReady then
                if try(Rules.inspectAirlock) then
                    outdoorToday = true
                    budget -= 1
                end
            end
            local function run(step: string): boolean
                if step == "panels" then
                    return stepPanels(day)
                elseif step == "build" then
                    return stepBuild(day)
                end
                return stepRover(day)
            end
            if P.chooser == "weighted" then
                -- 처음 하는 사람: 그날 눈에 띄는 일을 가중치로 하나씩 고른다 (물이 적으면 로버 가중치 x urgentRoverWeight)
                local remaining = {}
                for name, weight in P.weights do
                    local w = if multi and name == "rover" then 0 else weight
                    if name == "rover" and (urgent or s.water < P.lowWaterLevel) then
                        w *= P.urgentRoverWeight
                    end
                    if name == "build" and foodUrgent() then
                        w *= P.urgentBuildWeight
                    end
                    if w > 0 then
                        table.insert(remaining, { name = name, w = w })
                    end
                end
                table.sort(remaining, function(a, b)
                    return a.name < b.name
                end)
                while budget > 0 and #remaining > 0 do
                    local total = 0
                    for _, item in remaining do
                        total += item.w
                    end
                    local roll = rng() * total
                    local pick = #remaining
                    for index, item in remaining do
                        roll -= item.w
                        if roll <= 0 then
                            pick = index
                            break
                        end
                    end
                    local name = remaining[pick].name
                    table.remove(remaining, pick)
                    if run(name) then
                        budget -= 1
                    end
                end
            else
                for _, step in P.priority do
                    if budget <= 0 then
                        break
                    end
                    if not (multi and step == "rover") and run(step) then
                        budget -= 1
                    end
                end
            end
            if multi and budget > 0 then
                -- 손이 남으면 한 번 더 (패널은 하루 한도, 건설은 하루 1건이 규칙과 봇 한도)
                for _, step in { "build", "panels" } do
                    if budget > 0 and run(step) then
                        budget -= 1
                    end
                end
            end
            stepPause()
            if outdoorToday and P.oxygenChance > 0 then
                local chance = P.oxygenChance
                if not Rules.isBuilt(s, "airlock") or s.facilities.airlock.paused then
                    chance *= P.oxygenNoAirlockMultiplier
                end
                if rng() < chance then
                    try(Rules.recordOxygenRescue)
                end
            end
        end
        if P.trace then
            P.trace(day, s)
        end
        s = Rules.applyDay(s, config)
        local unlockAt = m.facilities.pipe.unlockDeliveries
        -- 수동 하역(멀티)은 하루 중에 일어나므로 하루 마감 전후 비교가 아니라 하역 수로 알아챈다
        if pipeUnlockDay == nil and s.deliveries >= unlockAt then
            pipeUnlockDay = s.day
        end
        if farmDoneDay == nil and Rules.isBuilt(s, "farm") then
            farmDoneDay = s.day
        end
        if pipeDay == 0 and Rules.isBuilt(s, "pipe") then
            pipeDay = s.day - 1
        end
        local medal = Rules.medal(s, config)
        if medal and bronzeDay == 0 then
            bronzeDay = s.day - 1
        end
        if (medal == "silver" or medal == "gold") and silverDay == 0 then
            silverDay = s.day - 1
        end
        if medal == "gold" and goldDay == 0 then
            goldDay = s.day - 1
        end
        minFood = math.min(minFood, s.food)
        minWater = math.min(minWater, s.water)
        local result = Rules.checkEnd(s, config)
        if result.outcome ~= "none" then
            s = Rules.finish(s, config, result)
            break
        end
    end
    local result = Rules.checkEnd(s, config)
    local score = Rules.finalScore(s, config)
    return {
        profile = profileName,
        window = if window then window.id else "none",
        seed = seed,
        outcome = result.outcome,
        medal = result.medal,
        reason = result.reason,
        daysTaken = result.daysTaken,
        score = score.score,
        deductions = score.deductions,
        bronzeDay = bronzeDay,
        silverDay = silverDay,
        goldDay = goldDay,
        pipeDay = pipeDay,
        trips = s.stats.trips,
        breakdowns = s.stats.breakdowns,
        rescues = s.oxygenRescues,
        stallDays = s.stats.stallDays,
        wastedWater = s.stats.wastedWater,
        minFood = minFood,
        minWater = minWater,
        stats = table.clone(s.stats),
        players = players,
        manualTrips = manualTrips,
        skill = P.skill,
        lossResource = result.resource,
    }
end

-- 결과 비교 (완벽 봇이 변형 중 고를 때)
local function better(a: GameResult, b: GameResult): boolean
    local ra = if a.outcome == "won" then MEDAL_RANK[a.medal :: string] or 0 else 0
    local rb = if b.outcome == "won" then MEDAL_RANK[b.medal :: string] or 0 else 0
    if ra ~= rb then
        return ra > rb
    end
    -- [Q5] 미션 순위와 같은 기준: 메달 > 점수 > 걸린 일수
    if a.score ~= b.score then
        return a.score > b.score
    end
    return a.daysTaken < b.daysTaken
end

local PROFILE_VALUES = {
    human = HUMAN,
    semi = SEMI,
    perfect = PERFECT,
    multi_first = MULTI_FIRST,
    multi_second = MULTI_SECOND,
}

-- 프로필 이름으로 한 판. perfect는 변형을 모두 해 보고 가장 좋은 판
-- players: 멀티 프로필(multi_first, multi_second)의 인원 (기본 2). 솔로 프로필은 1
local function simulate(
    config,
    profileName: string,
    window,
    seed: number,
    players: number?
): GameResult
    local values = PROFILE_VALUES[profileName]
    assert(values ~= nil, "unknown profile " .. profileName)
    local isMulti = profileName == "multi_first" or profileName == "multi_second"
    local count = if isMulti then math.max(2, players or 2) else 1
    if profileName ~= "perfect" then
        return playGame(config, merge(BASE, values, { players = count }), window, seed, profileName)
    end
    local best: GameResult? = nil
    for index, variant in PERFECT_VARIANTS do
        local r = playGame(config, merge(BASE, values, variant), window, seed, profileName)
        r.variant = index
        if best == nil or better(r, best :: GameResult) then
            best = r
        end
    end
    return best :: GameResult
end

-- 회의 숫자(식량 비용 제외, Q11) 그대로의 설정. 밸런스 보고서가 조정 전후를 비교할 때 쓴다
local function deepCopy(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in value do
        out[k] = deepCopy(v)
    end
    return out
end

-- MissionConfig를 깊은 복사하고 path("MISSIONS.C.facilities.led.cost.energy" 형식)마다 값을 바꾼다
local function withOverrides(config, overrides: { [string]: any }): any
    local copy = deepCopy(config)
    for path, value in overrides do
        local node = copy
        local parts = string.split(path, ".")
        for i = 1, #parts - 1 do
            node = node[parts[i]]
            assert(node ~= nil, "bad path " .. path)
        end
        node[parts[#parts]] = value
    end
    return copy
end

-- 회의와 카드 숫자 (Q10 ~ Q13 반영, 식량 비용 제외). MissionConfig가 [sim]으로 바꾼 값만 되돌린다
local MEETING_VALUES = {
    ["MISSIONS.C.facilities.farm.cost"] = { energy = 10, water = 5 },
    ["MISSIONS.C.facilities.farm.upkeep"] = { energy = 3, water = 2 },
    ["MISSIONS.C.facilities.led.cost"] = { energy = 8, water = 4 },
    ["MISSIONS.C.facilities.led.upkeep"] = { energy = 3, water = 1 },
    ["MISSIONS.C.facilities.nutrient.cost"] = { energy = 8, water = 4 },
    ["MISSIONS.C.facilities.nutrient.upkeep"] = { energy = 2, water = 0 },
    ["MISSIONS.C.facilities.pipe.cost"] = { energy = 15, water = 4 },
    ["MISSIONS.C.facilities.pipe.upkeep"] = { energy = 2, water = 1 },
    ["MISSIONS.C.facilities.hydroponics.cost"] = { energy = 6, water = 3 },
    ["MISSIONS.C.facilities.hydroponics.upkeep"] = { energy = 2, water = 2 },
    ["MISSIONS.C.panels.total"] = 20,
    ["MISSIONS.C.panels.output"] = 3,
    ["MISSIONS.C.panels.cost"] = 4,
    ["MISSIONS.C.facilities.airlock.upkeep"] = { energy = 2, water = 1 },
    ["MISSIONS.C.start"] = { energy = 70, water = 70, food = 70 },
    -- 처음 구현한 규칙과 v1 로버 배터리 (회의 숫자는 아니지만 비교 기준)
    ["MISSIONS.C.stallMode"] = "all",
    ["MISSIONS.C.crewEnergyLast"] = false,
    ["MANUAL_DRIVE.batteryDrainPerSecond"] = 0.3,
    ["MANUAL_DRIVE.boostDrainMultiplier"] = 3,
}

local function meetingConfig(config): any
    return withOverrides(config, MEETING_VALUES)
end

return {
    simulate = simulate,
    playGame = playGame,
    profiles = PROFILE_VALUES,
    base = BASE,
    perfectVariants = PERFECT_VARIANTS,
    weatherFixtures = WEATHER_FIXTURES,
    withOverrides = withOverrides,
    meetingConfig = meetingConfig,
    meetingValues = MEETING_VALUES,
    medalRank = MEDAL_RANK,
    better = better,
}
