-- 현실적 플레이어 봇 (GDD 4절 밸런스 검증 메모). simulation.spec.luau와 이벤트 밸런스 스윕이 같이 쓴다.
-- 2026-10-18 15차: spec에서 이 파일로 옮기고 랜덤 이벤트 시나리오(Scenario.schedule)를 받게 했다.
-- 이벤트가 없으면(기본) 예전 기록과 같은 결과가 나온다.

local Config = require("../src/shared/Config")
local Simulation = require("../src/shared/Simulation")

-- 착륙을 마치고 1일차가 시작된 상태 (이벤트 일정은 비운다. 시나리오가 따로 넣는다)
local function playingState(sunlight: number?)
    local s = Simulation.newState(Config)
    s.phase = "playing"
    s.day = 1
    s.siteId = 1
    s.siteName = "Shackleton Rim"
    s.sunlight = sunlight or 1
    s.eventSchedule = {}
    Simulation.refreshDerived(s, Config)
    return s
end

local function installMany(state, count: number)
    local s = state
    for _ = 1, count do
        local ok, new = Simulation.installPanel(s, Config)
        if ok then
            s = new
        end
    end
    return s
end

-- 현실적 플레이어 봇 (GDD 4절 밸런스 검증 메모, 2026-10-18 매장량과 전력 제약 반영) -----------
-- 하루에 한 가지 행동만 한다. 우선순위:
--   0) 기지에 있고 탱크에 물이 남아 있으면 하역 (행동 소모 없음, 전력이 모자라면 처리 가능한 만큼)
--   1) 다음 모듈을 지을 수 있고 착공 뒤에도 원정 동안 버틸 물이 남으면 착공
--   2) 미션대로 둘째 날 첫 물 원정 (패널 설치 다음 미션)
--   3) 물이 원정 동안 버틸 만큼만 남았으면 원정
--   4) 에너지는 충분한데 물이 모자라거나, 깔 패널이 없는데 물이 모자라면 원정
--   5) 패널을 하루 한도까지 설치
--   6) 할 일이 없으면 대기
-- 원정은 남은 매장지 중 왕복 일수가 가장 짧은 곳(같으면 매장량이 많은 곳)으로 간다. 원정 일수 동안 다른
-- 행동을 못 하고, 마지막 날 채취(fillFromDeposit)와 하역(unloadWater)을 한다.
-- 왕복 일수 = ceil((2 x 거리 / (로버 최고 속도 x 지형 배율) + 채우기와 하역 TRIP_OVERHEAD초) / DAY_SECONDS).
-- 지형 배율: 패드의 주행 회랑(최근접 얼음)은 1, 회랑이 없는 easy 1, mid 0.85, hard 0.7 (크레이터와 바위를 돌아간다).
-- 예전 추정(450, 300, 180, 100 studs -> 6, 5, 3, 3일)과 같은 식이다.
-- "원정 동안 버틸 물" = max(WATER_FLOOR, 하루 물 소비 x 다음 원정 일수)
local FIRST_TRIP_DAY = 2
local WATER_FLOOR = 10
local TRIP_OVERHEAD = 10
local USEFUL_TRIP_W = 15 -- 착공 판단 때 이보다 적게 남은 매장지는 "다녀올 곳"으로 치지 않는다
local FOOD_URGENT_MARGIN = 8 -- 식량이 Farm 건설 기간 + 이 일수 이하로 남으면 물 여유 없이도 Farm을 착공
-- 승리 모듈 전력이 조금 모자라면 원정과 로버 충전 대신 이 일수까지 기다려 착공한다 (2026-10-18 15차, 아래 충전 패드 주석)
local WIN_WAIT_MAX_DAYS = 5
local TERRAIN_FACTOR = { easy = 1, mid = 0.85, hard = 0.7 }

-- 사람 프로필 (2026-10-19 20차): 처음 하는 사람의 15분 플레이를 가정한 값. 관찰 가정이라 Config가 아니라 여기 둔다.
-- human은 perfect와 같은 원정 판단(물이 원정 동안 버틸 만큼만 남으면 떠남)을 하되, 착공은 물 예비분을 따지지 않고
-- 자원이 모이면 하루 뒤에 하며, 아래 만큼 느리고 덜 안다.
-- 로버 충전은 패드에 세우면 자동이라 Lab을 위해 충전을 미루는 요령(perfect의 waitForWin)은 쓰지 않는다
local HUMAN = {
    idleStartDays = 2, -- 시작 2일은 Tip과 화면을 익히느라 아무것도 안 한다
    earlyPanelDays = 10, -- 이 날까지는 하루 earlyPanelsPerDay장만 설치
    earlyPanelsPerDay = 2,
    panelSkipChance = 0.2, -- 설치할 날 중 이 확률로 하루 건너뛴다
    tripTimeFactor = 1.6, -- 원정 시간과 배터리 x1.6 (길 찾기, 바위, 뒤집힘)
    firstTripWaterDays = 10, -- 물 남은 일수가 이 이하가 되어야 첫 원정을 떠난다 (위기 전엔 안 움직임)
    tripDelayChance = 0.2, -- 원정마다 이 확률로 하루 더 걸린다
    buildDelayDays = 1, -- 착공할 자원이 모인 뒤 이만큼 늦게 착공 (토스트를 보고 패드까지 간다)
    pauseKnowChance = 0.5, -- Farm 가동 중지를 아는 사람의 비율 (게임마다 한 번 정한다)
    pauseWaterDays = 3, -- 물 남은 일수가 이 이하이면 Farm을 끈다 (아는 사람만)
    resumeWaterDays = 6, -- Farm을 켜도 물이 이 일수 이상 버티면 다시 켠다
    repairDelayDays = 2, -- 손상 알림 뒤 이만큼 지나서 수리
    targetRule = "nearest", -- 원정 대상: 가장 가까운 곳 (hard는 다른 곳이 다 고갈된 뒤)
    buildRule = "naive", -- 착공: 자원이 모이면 (물 예비분을 따지지 않음)
    tripMemoryMarginDays = nil :: number?, -- nil이면 두 번째 원정부터 perfect의 원정 판단
}

-- semi 프로필 (2026-10-19 20차 3단계, 리드 지정): 게임을 한 번 해 본 사람. 사용자 체감("딱딱 맞게 해도 부족")에 가장
-- 가깝다고 보는 모델. 리드가 정하지 않은 항목(폭풍 중 정지, 수리 2일 뒤)은 human과 같고, 착공은 아래 buildRule
local SEMI = {
    idleStartDays = 1,
    earlyPanelDays = 5,
    earlyPanelsPerDay = 2,
    panelSkipChance = 0,
    tripTimeFactor = 1.3,
    firstTripWaterDays = 14,
    tripDelayChance = 0.1,
    buildDelayDays = 0,
    pauseKnowChance = 0.8,
    pauseWaterDays = 3,
    resumeWaterDays = 6,
    repairDelayDays = 2,
    targetRule = "nearTwoLargest", -- 가까운 두 곳 중 남은 매장량이 큰 쪽
    -- 착공은 perfect처럼 원정 동안 버틸 물을 남길 때만 (한 번 해 본 사람은 A를 짓고 물 1로 원정을 떠나지 않는다.
    -- naive면 5일에 A를 짓고 물 1이 남아 첫 원정 중에 진다)
    buildRule = "reserve",
    tripMemoryMarginDays = 3 :: number?, -- 두 번째 원정부터 "지난 원정 일수 + 3일분" (착공 물이 모자랄 때도 떠난다)
}

-- 결정적 난수 (시드별 재현). 0..1 미만
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

-- 착륙 패드 위치 (DevMap과 같은 식: 기준 얼음 + 방향 x 최근접 거리)
local function padPosition(siteIndex: number): (number, number)
    local layout = Config.DEV_MAP.padLayout[siteIndex]
    local ice = Config.ICE_SITES[layout.ice]
    local distance = Config.DEV_MAP.iceDistanceBySite[siteIndex]
    return ice.x + layout.dirX * distance, ice.z + layout.dirZ * distance
end

-- 왕복 주행 초 (채우기와 하역은 빼고)
local function driveSecondsTo(siteIndex: number, iceIndex: number): number
    local px, pz = padPosition(siteIndex)
    local ice = Config.ICE_SITES[iceIndex]
    local distance = math.sqrt((ice.x - px) ^ 2 + (ice.z - pz) ^ 2)
    local corridor = Config.DEV_MAP.padLayout[siteIndex].ice == iceIndex
    local factor = if corridor then 1 else TERRAIN_FACTOR[ice.difficulty]
    return 2 * distance / (Config.ROVER.maxSpeed * factor)
end

-- timeFactor: 사람 프로필의 주행 시간 배율 (perfect는 1)
local function tripDaysTo(siteIndex: number, iceIndex: number, timeFactor: number?): number
    local seconds = driveSecondsTo(siteIndex, iceIndex) * (timeFactor or 1) + TRIP_OVERHEAD
    return math.max(1, math.ceil(seconds / Config.DAY_SECONDS))
end

-- 원정 한 번의 로버 배터리 소모 = 주행 초 x batteryDrainPerSecond (2026-10-18)
local function tripBatteryTo(siteIndex: number, iceIndex: number, timeFactor: number?): number
    return driveSecondsTo(siteIndex, iceIndex)
        * (timeFactor or 1)
        * Config.ROVER.batteryDrainPerSecond
end

export type BotResult = {
    result: string,
    day: number,
    aOnReturn: boolean,
    maxBlocked: number, -- 에너지 막힘 최대 연속일 (다음 모듈이 열려 있고 물도 충분한데 에너지가 모자란 기지 체류일)
    blockedDays: number, -- 에너지 막힘 일수 합계
    maxIdle: number, -- 완전 대기 최대 연속일 (아무 행동도 못 한 날)
    minFood: number, -- Farm 가동 전 최저 식량
    trips: number,
    wasteDays: number, -- 저장 상한 때문에 발전이 버려진 날
    partialUnloads: number, -- 전력이 모자라 일부만 처리한 하역
    chargeDays: number, -- 기지에서 로버를 충전한 날
    waterNeed: number, -- 건설 물 + 크루와 모듈 유지 물 (승리까지 쓴 물 전체)
    mined: number, -- 매장지에서 캔 물 합계
    tripLog: string, -- 원정 대상 순서 (얼음 번호)
    farmDay: number, -- Farm B가 가동된 날 (못 지었으면 0)
    repairs: number, -- 미세운석 손상 모듈 수리 횟수 (2026-10-18 15차)
    damagedDays: number, -- 손상 모듈이 하나라도 있던 날 수
    panelsLost: number, -- 미세운석으로 부서진 패널 수
    stormIdleDays: number, -- 폭풍 때문에 기지 안에서 아무 일도 못 한 날
    aborts: number, -- Farm 손상 알림으로 원정을 되돌린 횟수
    minWater: number, -- Farm 가동 전 최저 물 (20차)
    firstTripDay: number, -- 첫 원정 출발일 (못 떠났으면 0)
    lossReason: string, -- 실패 사유 "water" | "food" | "both" | "timeout" (승리면 "")
    pauses: number, -- Farm 가동 중지 횟수 (human)
}

-- 이벤트 시나리오 (2026-10-18 15차). schedule이 없으면 이벤트 없음 (기존 기록과 같은 조건)
export type Scenario = {
    schedule: { Simulation.EventEntry }?,
    trace: ((day: number, state: Simulation.GameState, action: string) -> ())?, -- 디버그용 하루 기록
    stormStayHome: boolean?, -- 엄격 모델(비교용): 폭풍 중 원정 출발과 수리도 하지 않고 기지 안에만 있는다
    abortOnFarmDamage: boolean?, -- 원정 중 Farm 손상 알림을 받으면 되돌아온다 (기본 꺼짐, 비교용)
    profile: string?, -- "perfect"(기본) | "human" | "semi" (20차)
    seed: number?, -- human 프로필 난수 시드
}

local function nextModule(s): string?
    for _, id in Config.MODULE_ORDER do
        local status = s.modules[id].status
        if status == "available" or status == "locked" then
            return id
        end
    end
    return nil
end

local function simulatePlayer(siteIndex: number, noTrips: boolean?, scenario: Scenario?): BotResult
    local s = playingState(Config.SITES[siteIndex].sunlight)
    if scenario and scenario.schedule then
        local schedule = {}
        for _, entry in scenario.schedule do
            table.insert(schedule, table.clone(entry))
        end
        s.eventSchedule = schedule
        Simulation.refreshDerived(s, Config)
    end
    local farmDay, repairs, damagedDays, panelsLost, stormIdleDays = 0, 0, 0, 0, 0
    -- 사람 프로필 (20차)
    local profileName = if scenario then scenario.profile else nil
    local P = if profileName == "human" then HUMAN elseif profileName == "semi" then SEMI else nil
    local human = P ~= nil -- 사람 계열 프로필 (human, semi)
    local HP = P or HUMAN -- 사람 계열 값 (perfect에서는 읽지 않는다)
    local lastTripDays = 0
    local timeFactor = if human then HP.tripTimeFactor else 1
    local rng = makeRng(if scenario and scenario.seed then scenario.seed else 1)
    local knowsPause = human and rng() < HP.pauseKnowChance
    local damageSeen: { [string]: number } = {}
    local readySince: number? = nil
    local minWater, firstTripDay, pauses = math.huge, 0, 0
    local function daysTo(iceIndex: number): number
        return tripDaysTo(siteIndex, iceIndex, timeFactor)
    end
    local function batteryTo(iceIndex: number): number
        return tripBatteryTo(siteIndex, iceIndex, timeFactor)
    end
    -- 로버 배터리: 원정을 떠날 때 왕복 소모를 빼고, 기지에 있는 날마다 기지 에너지에서 충전한다
    local battery = Config.ROVER.batteryMax
    local chargeDays = 0 -- 기지에서 충전한 날 수
    local deposits: { number } = {}
    for index, site in Config.ICE_SITES do
        deposits[index] = site.deposit
    end
    -- days일 동안 아무 행동 없이 보낼 때 쓰는 물 (건설 중 모듈이 그 사이 완공되면 유지 소비도 더한다)
    local function waterUse(state, days: number): number
        local projected = state
        local total = 0
        for _ = 1, days do
            local _, use = Simulation.dailyConsumption(projected, Config)
            total += use
            projected = Simulation.applyDay(projected, Config)
        end
        return total
    end
    local function reserveFor(state, days: number): number
        return math.max(WATER_FLOOR, waterUse(state, days))
    end
    -- 가장 짧은 "갈 만한" 원정 (USEFUL_TRIP_W 이상 남은 곳. 없으면 남은 곳 아무 데나)
    local function shortestTrip(): number
        local best, anyBest = math.huge, math.huge
        for index, amount in deposits do
            if amount > 0 then
                local days = daysTo(index)
                anyBest = math.min(anyBest, days)
                if amount >= USEFUL_TRIP_W then
                    best = math.min(best, days)
                end
            end
        end
        if best == math.huge then
            best = anyBest
        end
        return if best == math.huge then 0 else best
    end
    -- 갈 만한 매장지를 왕복 일수 순으로 둘 골라, 첫 원정을 버티고 그 물로 둘째 원정까지 버티는지
    local function survivesTwoTrips(state): boolean
        local list = {}
        for index, amount in deposits do
            if amount >= USEFUL_TRIP_W then
                table.insert(list, { days = daysTo(index), amount = amount })
            end
        end
        table.sort(list, function(a, b)
            return a.days < b.days
        end)
        local first, second = list[1], list[2]
        if not first then
            return true
        end
        local projected = state
        for _ = 1, first.days do
            projected = Simulation.applyDay(projected, Config)
        end
        if Simulation.checkEnd(projected, Config) == "lost" then
            return false
        end
        if not second then
            return true
        end
        local afterFirst = Simulation.copy(projected)
        afterFirst.water += math.min(state.rover.tankMax, first.amount)
        return afterFirst.water >= waterUse(afterFirst, second.days)
    end
    -- 다음 원정 대상: 다녀오는 동안 물이 버티는 매장지 중 하루당 얻는 물(min(탱크 빈 공간, 매장량) / 왕복 일수)이
    -- 가장 많은 곳. 버틸 수 있는 곳이 없으면 가장 가까운 곳
    local function nextTarget(): (number?, number)
        if human and HP.targetRule == "nearTwoLargest" then
            -- semi: 가까운 두 곳 중 남은 매장량이 큰 쪽
            local list = {}
            for index, amount in deposits do
                if amount > 0 and batteryTo(index) <= battery then
                    table.insert(list, { index = index, days = daysTo(index), amount = amount })
                end
            end
            table.sort(list, function(a, b)
                return a.days < b.days
            end)
            local pick = list[1]
            if list[2] and list[2].amount > pick.amount then
                pick = list[2]
            end
            if pick then
                return pick.index, pick.days
            end
            return nil, 0
        end
        if human then
            -- 사람: 레이더에서 가장 가까운 매장지만 (바위밭 hard는 다른 곳이 다 고갈된 뒤에야 간다)
            local pick, pickDays, pickHard = nil, math.huge, true
            for index, amount in deposits do
                if amount > 0 and batteryTo(index) <= battery then
                    local hard = Config.ICE_SITES[index].difficulty == "hard"
                    local days = daysTo(index)
                    if (pickHard and not hard) or (hard == pickHard and days < pickDays) then
                        pick, pickDays, pickHard = index, days, hard
                    end
                end
            end
            return pick, if pick then pickDays else 0
        end
        local best, bestDays, bestRate = nil, 0, -1
        local nearest, nearestDays = nil, math.huge
        local space = s.rover.tankMax - s.rover.tank
        for index, amount in deposits do
            -- 지금 배터리로 왕복할 수 없는 매장지는 고르지 않는다
            if amount > 0 and batteryTo(index) <= battery then
                local days = daysTo(index)
                if days < nearestDays then
                    nearest, nearestDays = index, days
                end
                local rate = math.min(space, amount) / days
                local survivable = waterUse(s, days) < s.water
                if
                    survivable
                    and (
                        rate > bestRate + 1e-9
                        or (math.abs(rate - bestRate) <= 1e-9 and days < bestDays)
                    )
                then
                    best, bestDays, bestRate = index, days, rate
                end
            end
        end
        if best then
            return best, bestDays
        end
        return nearest, if nearest then nearestDays else 0
    end
    -- 착공 판단과 막힘 지표용: 가장 짧은 원정 동안 버틸 물
    local function waterReserve(state): number
        return reserveFor(state, shortestTrip())
    end

    local tripLeft, tripTarget = 0, 0
    local tripTotal, tripAborted = 0, false -- 이번 원정 전체 일수, 되돌아오는 중인지 (15차)
    local aborts = 0
    local tripped, checkedReturn = false, false
    local aOnReturn = false
    local blocked, maxBlocked, blockedDays, idle, maxIdle = 0, 0, 0, 0, 0
    local minFood = math.huge
    local wasteDays, partialUnloads, waterNeed, mined = 0, 0, 0, 0
    local log: { string } = {}

    local function unload()
        if s.rover.tank <= 0 then
            return
        end
        local ok, new, _, _, warning = Simulation.unloadWater(s, Config)
        if ok then
            s = new
            if warning then
                partialUnloads += 1
            end
        end
    end
    local function arrive()
        local ok, new, remaining = Simulation.fillFromDeposit(s, Config, deposits[tripTarget])
        if ok then
            mined += deposits[tripTarget] - remaining
            deposits[tripTarget] = remaining
            s = new
        end
        unload()
    end

    for _ = 1, Config.TOTAL_DAYS + 1 do
        local busy = false -- 오늘 행동을 했는지
        local onTrip = false
        local id = nextModule(s)
        if tripLeft > 0 then
            -- 랜덤 이벤트 (2026-10-18 15차): 원정 전반부에 Farm 손상 알림을 받았고 남은 식량이 원정 끝까지 못 가면
            -- 사람처럼 되돌아온다 (온 만큼 돌아가고 물은 못 얻는다). 되돌아오는 편이 이틀 이상 빠르고 빈손으로도
            -- 물이 버틸 때만. 이벤트가 없으면 일어나지 않는다
            local elapsed = tripTotal - tripLeft
            local farm = s.modules.B
            if
                scenario ~= nil
                and scenario.abortOnFarmDamage == true
                and not tripAborted
                and farm.damaged
                and elapsed * 2 < tripTotal
                and s.food <= tripLeft + 1
                and elapsed + 1 < tripLeft -- 되돌아오는 편이 이틀 이상 빨라야 한다
                and s.water > waterUse(s, elapsed + shortestTrip()) -- 빈손으로 와도 다음 원정까지 물이 버틴다
            then
                tripAborted = true
                aborts += 1
                tripLeft = math.max(1, elapsed)
                log[#log] = log[#log] .. "x"
            end
            tripLeft -= 1
            busy, onTrip = true, true
            if tripLeft == 0 then
                if tripAborted then
                    tripAborted = false
                else
                    arrive()
                end
            end
        else
            unload()
            -- 충전 패드: 하루(DAY_SECONDS초) 동안 chargeRatePerSecond씩, 기지 에너지 잔량까지.
            -- 단, 승리 모듈을 오늘 또는 WIN_WAIT_MAX_DAYS일 안에(원정 없이 기다려) 착공해 완공까지 버틸 수 있으면
            -- 로버 충전을 미루고 기다렸다 짓는다 (2026-10-18 15차: 원정에서 돌아온 날 충전이 Lab 전력을 먹고,
            -- 몇 E 모자라면 10일 원정을 떠나 90일을 넘기던 봇 결함. 사람은 로버를 세워 두고 Lab부터 짓는다)
            local waitForWin = false
            if
                not noTrips
                and not human
                and id == Config.WIN_MODULE
                and s.modules[id].status == "available"
                and not Simulation.stormActive(s, Config)
            then
                local projected = s
                for wait = 0, WIN_WAIT_MAX_DAYS do
                    if wait > 0 then
                        projected = Simulation.applyDay(projected, Config)
                        if Simulation.checkEnd(projected, Config) ~= "none" then
                            break
                        end
                    end
                    local okWait, started = Simulation.startBuild(projected, Config, id)
                    if okWait then
                        for _ = 1, Config.MODULES[id].buildDays do
                            started = Simulation.applyDay(started, Config)
                            local result = Simulation.checkEnd(started, Config)
                            if result ~= "none" then
                                waitForWin = result == "won"
                                break
                            end
                        end
                        break
                    end
                end
            end
            local holdCharge = waitForWin
            local charge = if holdCharge
                then 0
                else math.min(
                    Config.ROVER.chargeRatePerSecond * Config.DAY_SECONDS,
                    Config.ROVER.batteryMax - battery,
                    s.energy
                )
            if charge > 0 then
                s = Simulation.copy(s)
                s.energy -= charge
                battery += charge
                chargeDays += 1
                Simulation.refreshDerived(s, Config)
            end
            -- 랜덤 이벤트 (2026-10-18 15차): 폭풍이 진행 중이면 오래 걸리는 바깥 일(착공, 패널 설치)을 하지 않는다.
            -- 로버 좌석은 산소 규칙상 실내라 원정은 나갈 수 있고, 손상 모듈 수리는 건물 앞 4초라 한다.
            -- (Scenario.stormStayHome이면 원정 출발과 수리도 막는 엄격 모델.) 손상 모듈은 다음 기회에 먼저 수리한다
            -- (전력 repairEnergy, 행동을 쓰지 않는 4초 작업으로 본다)
            local storming = Simulation.stormActive(s, Config)
            -- 사람(20차): 처음 idleStartDays일은 Tip과 화면을 익히느라, 폭풍 중에는 무서워서 아무것도 하지 않는다
            local learning = human and s.day <= HP.idleStartDays
            local stayHome = learning
                or (storming and (human or (scenario ~= nil and scenario.stormStayHome == true)))
            if not stayHome then
                for _, moduleId in Config.MODULE_ORDER do
                    local seen = damageSeen[moduleId]
                    local noticed = not human
                        or (seen ~= nil and s.day >= seen + HP.repairDelayDays)
                    if s.modules[moduleId].damaged and noticed then
                        local repaired, after = Simulation.repairModule(s, Config, moduleId)
                        if repaired then
                            s = after
                            repairs += 1
                            damageSeen[moduleId] = nil
                        end
                    end
                end
                -- 사람: Farm 가동 중지는 아는 사람(게임마다 50%)만, 물이 pauseWaterDays일분 이하일 때
                local farm = s.modules.B
                if human and knowsPause and farm.status == "active" then
                    if not farm.paused and s.daysLeft.water <= HP.pauseWaterDays then
                        local paused, after = Simulation.setPaused(s, Config, "B", true)
                        if paused then
                            s = after
                            pauses += 1
                        end
                    elseif farm.paused then
                        local probe = Simulation.copy(s)
                        probe.modules.B.paused = false
                        Simulation.refreshDerived(probe, Config)
                        if probe.daysLeft.water >= HP.resumeWaterDays then
                            local resumed, after = Simulation.setPaused(s, Config, "B", false)
                            if resumed then
                                s = after
                            end
                        end
                    end
                end
            end
            if tripped and not checkedReturn then
                checkedReturn = true
                aOnReturn = (Simulation.canBuild(s, Config, "A"))
            end
            local waterCost = if id then Config.MODULES[id].cost.water else 0
            local canInstall = s.panelsInstalled < Config.PANELS_TOTAL
            local energyReady = id ~= nil and s.energy >= Config.MODULES[id].cost.energy
            local target, days = nextTarget()
            local reserve = reserveFor(s, days)
            local waterShort = id ~= nil and s.water < waterCost + reserve
            local afterBuild = if id and (Simulation.canBuild(s, Config, id))
                then select(2, Simulation.startBuild(s, Config, id))
                else nil
            -- 착공 판단: 보통은 착공 뒤에도 가장 짧은 원정 동안 버틸 물이 남을 때.
            -- 승리 모듈은 완공 즉시 승리라, 기지에서 기다리기만 해도 실패보다 승리가 먼저 오면 착공한다
            -- (물이 바닥나도 SHORTAGE_DAYS_TO_LOSE일 전에 완공하면 승리. 사람도 이렇게 마지막 물을 건다)
            local canStart = false
            if afterBuild and id == Config.WIN_MODULE then
                local projected = afterBuild
                for _ = 1, Config.MODULES[id].buildDays do
                    projected = Simulation.applyDay(projected, Config)
                    local result = Simulation.checkEnd(projected, Config)
                    if result ~= "none" then
                        canStart = result == "won"
                        break
                    end
                end
            elseif afterBuild then
                canStart = afterBuild.water >= reserveFor(afterBuild, shortestTrip())
                -- 물 유지비가 큰 모듈(Farm)은 두 원정 앞까지 본다: 가까운 순으로 첫 원정을 버티고,
                -- 그 물을 더한 뒤 다음 원정도 완공 뒤 소비로 버틸 만큼 모였을 때 착공 (사람도 Farm 전에 물을 쌓는다)
                if canStart and Config.MODULES[id :: string].upkeep.water > 1 then
                    canStart = survivesTwoTrips(afterBuild)
                end
                -- 식량이 급하면(Farm 건설 기간 + FOOD_URGENT_MARGIN일 안에 바닥) 물 여유가 없어도 Farm부터
                local foodDef = Config.MODULES[id :: string]
                if
                    not canStart
                    and foodDef.foodPerDay > 0
                    and s.food <= foodDef.buildDays + FOOD_URGENT_MARGIN
                then
                    canStart = true
                end
            end
            -- 사람: 물 예비분을 따지지 않고 자원이 모이면(canBuild) buildDelayDays일 뒤 착공한다
            -- (리드 지정: "자원이 모였다는 토스트 뒤 1일 지연". 토스트를 보고 패드까지 간다)
            if human then
                if HP.buildRule == "naive" then
                    canStart = afterBuild ~= nil
                end
                if afterBuild and canStart then
                    readySince = readySince or s.day
                    if s.day < (readySince :: number) + HP.buildDelayDays then
                        canStart = false
                    end
                else
                    readySince = nil
                end
            end
            if afterBuild and canStart and not storming and not stayHome then
                readySince = nil
                local built = afterBuild
                waterNeed += waterCost
                s = built
                busy = true
                id = nextModule(s)
            elseif
                not noTrips
                and not stayHome
                and not waitForWin
                and target ~= nil
                and s.rover.tank < s.rover.tankMax
                and (
                    if human and not tripped
                        -- 사람의 첫 원정은 물이 firstTripWaterDays일분 이하가 되어서야 (위기 전엔 안 움직임)
                        then s.daysLeft.water <= HP.firstTripWaterDays
                        elseif
                            human
                            and HP.tripMemoryMarginDays ~= nil -- semi: 지난 원정 일수 + 여유일분 이하이거나, 착공할 물이 모자랄 때

                        then s.daysLeft.water
                                <= lastTripDays + (HP.tripMemoryMarginDays :: number)
                            or (waterShort and (energyReady or not canInstall))
                        else (not tripped and s.day >= FIRST_TRIP_DAY)
                            or s.water <= reserve
                            or (waterShort and (energyReady or not canInstall))
                )
            then
                if human and rng() < HP.tripDelayChance then
                    days += 1
                end
                if firstTripDay == 0 then
                    firstTripDay = s.day
                end
                lastTripDays = days
                tripped = true
                busy, onTrip = true, true
                tripTarget = target :: number
                battery = math.max(0, battery - batteryTo(tripTarget))
                table.insert(log, tostring(tripTarget))
                tripLeft = days - 1
                tripTotal = days
                if tripLeft == 0 then
                    arrive()
                end
            elseif canInstall and not storming and not stayHome then
                -- 사람: 처음 earlyPanelDays일은 하루 earlyPanelsPerDay장, 설치할 날의 panelSkipChance는 건너뜀
                if not human or rng() >= HP.panelSkipChance then
                    local perDay = if human and s.day <= HP.earlyPanelDays
                        then HP.earlyPanelsPerDay
                        else Config.PANELS_PER_DAY
                    s = installMany(s, perDay)
                    busy = true
                end
            elseif storming then
                stormIdleDays += 1
            end
        end
        -- 대기 지표
        if busy then
            idle = 0
        else
            idle += 1
            maxIdle = math.max(maxIdle, idle)
        end
        local def = id and Config.MODULES[id]
        local isBlocked = not onTrip
            and def ~= nil
            and s.modules[id :: string].status == "available"
            and s.water >= def.cost.water + waterReserve(s)
            and s.energy < def.cost.energy
        if isBlocked then
            blocked += 1
            blockedDays += 1
            maxBlocked = math.max(maxBlocked, blocked)
        else
            blocked = 0
        end
        if s.modules.B.status ~= "active" then
            minFood = math.min(minFood, s.food)
            minWater = math.min(minWater, s.water)
        end
        local _, useWater = Simulation.dailyConsumption(s, Config)
        waterNeed += useWater
        if scenario and scenario.trace then
            local action = if onTrip then "trip" elseif busy then "act" else "idle"
            scenario.trace(s.day, s, action)
        end
        local panelsBefore, farmBefore = s.panelsInstalled, s.modules.B.status
        s = Simulation.applyDay(s, Config)
        if s.panelsInstalled < panelsBefore then
            panelsLost += panelsBefore - s.panelsInstalled
        end
        if farmBefore ~= "active" and s.modules.B.status == "active" then
            farmDay = s.day
        end
        for _, moduleId in Config.MODULE_ORDER do
            if s.modules[moduleId].damaged then
                damagedDays += 1
                break
            end
        end
        if s.energyWasted > 0 then
            wasteDays += 1
        end
        if s.modules.B.status ~= "active" then
            minFood = math.min(minFood, s.food)
            minWater = math.min(minWater, s.water)
        end
        -- 사람이 손상 알림을 받은 날 (수리는 HP.repairDelayDays 뒤)
        for _, moduleId in Config.MODULE_ORDER do
            if s.modules[moduleId].damaged and damageSeen[moduleId] == nil then
                damageSeen[moduleId] = s.day
            end
        end
        local result = Simulation.checkEnd(s, Config)
        if result ~= "none" then
            return {
                result = result,
                day = Simulation.finishGame(s, Config, result).day,
                aOnReturn = aOnReturn,
                maxBlocked = maxBlocked,
                blockedDays = blockedDays,
                maxIdle = maxIdle,
                minFood = minFood,
                trips = s.waterTrips,
                wasteDays = wasteDays,
                partialUnloads = partialUnloads,
                chargeDays = chargeDays,
                waterNeed = waterNeed,
                mined = mined,
                tripLog = table.concat(log, ","),
                farmDay = farmDay,
                repairs = repairs,
                damagedDays = damagedDays,
                panelsLost = panelsLost,
                stormIdleDays = stormIdleDays,
                aborts = aborts,
                minWater = minWater,
                firstTripDay = firstTripDay,
                lossReason = if result == "won"
                    then ""
                    elseif s.day > Config.TOTAL_DAYS then "timeout"
                    elseif s.water <= 0 and s.food <= 0 then "both"
                    elseif s.water <= 0 then "water"
                    else "food",
                pauses = pauses,
            }
        end
    end
    return {
        result = "none",
        day = s.day,
        aOnReturn = aOnReturn,
        maxBlocked = maxBlocked,
        blockedDays = blockedDays,
        maxIdle = maxIdle,
        minFood = minFood,
        trips = s.waterTrips,
        wasteDays = wasteDays,
        partialUnloads = partialUnloads,
        chargeDays = chargeDays,
        waterNeed = waterNeed,
        mined = mined,
        tripLog = table.concat(log, ","),
        farmDay = farmDay,
        repairs = repairs,
        damagedDays = damagedDays,
        panelsLost = panelsLost,
        stormIdleDays = stormIdleDays,
        aborts = aborts,
        minWater = minWater,
        firstTripDay = firstTripDay,
        lossReason = "timeout",
        pauses = pauses,
    }
end

local function summary(results: { BotResult }): string
    local parts = {}
    for index, r in results do
        table.insert(
            parts,
            string.format(
                "%s %s %d일(원정 %d회 [얼음 %s], 에너지 막힘 최대 %d일 합계 %d일, 완전 대기 최대 %d일, Farm 전 최저 식량 %d, 전력 버림 %d일, 일부 처리 하역 %d회, 충전 %d일, 물 사용 %d W, 채취 %d W)",
                Config.SITES[index].name,
                if r.result == "won" then "승리" else r.result,
                r.day,
                r.trips,
                r.tripLog,
                r.maxBlocked,
                r.blockedDays,
                r.maxIdle,
                r.minFood,
                r.wasteDays,
                r.partialUnloads,
                r.chargeDays,
                r.waterNeed,
                r.mined
            )
        )
    end
    return table.concat(parts, "\n        ")
end

return {
    simulatePlayer = simulatePlayer,
    human = HUMAN, -- 사람 프로필 가정 (민감도 실험이 바꿔 보고 되돌린다)
    semi = SEMI,
    summary = summary,
    tripDaysTo = tripDaysTo,
}
