-- v2 규칙 테스트와 밸런스 보고서 진입점: 저장소 루트에서 lune run tests/run_v2.luau
-- 리드가 나중에 tests/run.luau로 합친다. 이 파일은 v1 테스트(tests/run.luau)를 건드리지 않는다.
--   lune run tests/run_v2.luau              단위 테스트 + 보고서 (시드 40)
--   lune run tests/run_v2.luau --seeds 200  보고서 시드 수
--   lune run tests/run_v2.luau --no-report  단위 테스트만
--   lune run tests/run_v2.luau --sensitivity  민감도 표에 LED 유지비, 시작 에너지, 자율주행 에너지, 수동 배터리 소모를 더한다
-- 단위 테스트가 하나라도 실패하면 종료 코드 1. 보고서는 숫자만 출력하고 실패 처리하지 않는다.

local fs = require("@lune/fs")
local process = require("@lune/process")
local harness = require("./harness")
local Bot = require("./bot_v2")
local MissionConfig = require("../src/shared/MissionConfig")
local Rules = require("../src/shared/Rules")

local seeds = 40
local report = true
local sensitivity = false
do
    local i = 1
    while i <= #process.args do
        local arg = process.args[i]
        if arg == "--seeds" then
            seeds = tonumber(process.args[i + 1]) or seeds
            i += 1
        elseif arg == "--no-report" then
            report = false
        elseif arg == "--sensitivity" then
            sensitivity = true
        end
        i += 1
    end
end

print("[Rules v2]")
require("./rules.spec")(harness)
local _, failed = harness.report()

-- 우주 기상 구간: 리드의 SpaceWeatherData가 있으면 그것, 없으면 bot_v2의 합성 픽스처
local function weatherWindows(): ({ any }, string)
    local path = "src/shared/SpaceWeatherData.luau"
    if fs.isFile(path) then
        local ok, data = pcall(require, "../src/shared/SpaceWeatherData")
        if ok and typeof(data) == "table" then
            local list = data.windows or data.WINDOWS or data
            if typeof(list) == "table" and #list > 0 and typeof(list[1].events) == "table" then
                return list, "SpaceWeatherData.luau"
            end
        end
    end
    return Bot.weatherFixtures, "bot_v2 합성 픽스처 (실제 DONKI 아님)"
end

-- 이동 시간 표 ---------------------------------------------------------------
local function tripReport(config)
    local m = config.MISSIONS.C
    local s = Rules.newState("C", config, 1, nil)
    print("")
    print(
        string.format(
            "[자율주행] 속도 %d studs/일 = %.1f studs/s, 하루 %d초, 이동 하루당 에너지 %d",
            m.rover.fsdStudsPerDay,
            m.rover.fsdStudsPerDay / config.DAY_SECONDS,
            config.DAY_SECONDS,
            m.rover.energyPerTravelDay
        )
    )
    print(
        "  지점   거리  위험  왕복(일, 반올림 전)  에너지 | 서둘러: 일  에너지  위험     | 걸어서 수리 가능 비율"
    )
    local limit = Rules.walkRepairLimit(config)
    for index, site in s.sites do
        local plan = Rules.tripPlan(s, config, index, false) :: Rules.TripPlan
        local rush = Rules.tripPlan(s, config, index, true) :: Rules.TripPlan
        -- 고장 위치(BaseExit 기준)는 0 ~ 거리 사이 고르게 나온다 (Rules.dispatchRover의 damageAt).
        -- 걷는 거리 = 고장 위치 + 에어록 출발 보정(startOffset)
        local offset = config.WALK_REPAIR.startOffset or 0
        local walkable = math.clamp((limit - offset) / site.distance, 0, 1)
        print(
            string.format(
                "  %-5s %5d  %-4s  %d (%.2f)            %3d    | %d%s       %3d     %-8s | %3.0f%%",
                site.id,
                site.distance,
                site.risk,
                plan.days,
                plan.rawDays,
                plan.energy,
                rush.days,
                if rush.rushHelps then " " else "*",
                rush.energy,
                rush.risk,
                walkable * 100
            )
        )
    end
    print("  * 서둘러 가도 일수가 줄지 않음 (화면에서 끄는 것을 권장)")
end

-- 수동 운전 (멀티) -------------------------------------------------------------
-- 지점별 왕복 시간과 배터리 (RoverPark 출발, MissionConfig manualDriveDistances). 부스터는 과열 때문에 4초 켜고 6초 식힌다:
-- 부스터를 쓸 수 있을 때마다 쓰면 평균 속도 배율 (4 x 1.6 + 6 x 1) / 10 = 1.24, 배터리 소모 배율 (4 x 2 + 6 x 1) / 10 = 1.4
local function manualReport(config)
    local md = config.MANUAL_DRIVE
    local list = {}
    for id, distance in config.MISSIONS.C.manualDriveDistances do
        table.insert(list, { id = id, distance = distance })
    end
    table.sort(list, function(a, b)
        return a.distance < b.distance
    end)
    local cycle = md.v1BoostOnSeconds + md.v1BoostCooldownSeconds
    local boostSpeed = (md.v1BoostOnSeconds * md.v1BoostMultiplier + md.v1BoostCooldownSeconds)
        / cycle
    local boostDrain = (md.v1BoostOnSeconds * md.boostDrainMultiplier + md.v1BoostCooldownSeconds)
        / cycle
    local handling = md.fillSeconds + md.unloadSeconds
    print("")
    print(
        string.format(
            "[수동 운전] RoverPark 출발, 최고 속도 %d studs/s, 우회 배율 %.2f, 채우기 %d초 + 하역 %d초, 배터리 %d (초당 %.2f)",
            md.v1MaxSpeed,
            md.detourFactor,
            md.fillSeconds,
            md.unloadSeconds,
            md.batteryMax,
            md.batteryDrainPerSecond
        )
    )
    print(
        string.format(
            "  부스터 사용 = 과열 한도까지 계속 (속도 x%.2f, 소모 x%.2f). 배터리는 운전 중에만 닳는다 (채우기, 하역 제외)",
            boostSpeed,
            boostDrain
        )
    )
    print(
        "  지점   거리 | 부스터 없음: 왕복 초(일)  배터리 | 부스터 사용: 왕복 초(일)  배터리 | 가득 찬 배터리로 왕복 수(없음/사용)"
    )
    for _, item in list do
        local drive = 2 * item.distance * md.detourFactor / md.v1MaxSpeed
        local driveBoost = drive / boostSpeed
        local use = drive * md.batteryDrainPerSecond
        local useBoost = driveBoost * md.batteryDrainPerSecond * boostDrain
        print(
            string.format(
                "  %-5s %5d | %5.0f (%3.1f)            %4.1f   | %5.0f (%3.1f)            %4.1f   | %.1f / %.1f",
                item.id,
                item.distance,
                drive + handling,
                (drive + handling) / config.DAY_SECONDS,
                use,
                driveBoost + handling,
                (driveBoost + handling) / config.DAY_SECONDS,
                useBoost,
                md.batteryMax / use,
                md.batteryMax / useBoost
            )
        )
    end
    local walk = config.WALK_REPAIR
    local oneWay = Rules.walkRepairLimit(config)
    local both = math.floor(
        (config.OXYGEN.outdoorSeconds * walk.oxygenSafetyRatio - walk.repairHoldSeconds)
            / 2
            * walk.walkSpeed
    )
    local raw = config.OXYGEN.outdoorSeconds * walk.walkSpeed
    print(
        string.format(
            "[걸어서 수리] 산소 100 = 야외 %d초, 걷기 %d studs/s: 이론상 한 방향 %d studs, 산소 %.0f%%만 쓰고 수리 %d초를 빼면 %d studs (수리 뒤 로버를 타고 돌아옴), 걸어서 돌아오면 %d studs",
            config.OXYGEN.outdoorSeconds,
            walk.walkSpeed,
            raw,
            walk.oxygenSafetyRatio * 100,
            walk.repairHoldSeconds,
            oneWay,
            both
        )
    )
    print(
        string.format(
            "  출발은 에어록: 에어록 -> BaseExit %d studs를 더해 BaseExit 기준 고장 위치 %d studs까지 걸어서 수리",
            walk.startOffset or 0,
            oneWay - (walk.startOffset or 0)
        )
    )
end

-- 밸런스 표 (2026-11-14 새 목표, 리드 전달) -------------------------------------------
-- 목표는 실패/동/은/금 %. 3 ~ 4명은 목표 숫자 대신 "2명보다 조금 쉽게"로 본다
-- accepted: 사용자가 확정한 결과 (BALANCE_LOG 7.5.1, 2026-11-14 기지, 같은 구간 5개 x 시드 40). 값을 바꾼 뒤 비교용
local MODES = {
    {
        key = "h1",
        label = "솔로 처음",
        profile = "human",
        players = 1,
        target = { 50, 40, 9, 1 },
        accepted = { 28, 39, 34, 0 },
    },
    {
        key = "s1",
        label = "솔로 두 번째",
        profile = "semi",
        players = 1,
        target = { 30, 50, 15, 5 },
        accepted = { 20, 52, 20, 8 },
    },
    { key = "p1", label = "솔로 완벽(참고)", profile = "perfect", players = 1 },
    {
        key = "f2",
        label = "멀티 2명 처음",
        profile = "multi_first",
        players = 2,
        target = { 28, 50, 19, 3 },
        accepted = { 32, 45, 22, 0 },
    },
    {
        key = "m2",
        label = "멀티 2명 두 번째",
        profile = "multi_second",
        players = 2,
        target = { 15, 50, 27, 8 },
        accepted = { 18, 54, 22, 8 },
    },
    {
        key = "f3",
        label = "멀티 3명 처음",
        profile = "multi_first",
        players = 3,
        easierThan = "f2",
        accepted = { 12, 54, 34, 0 },
    },
    {
        key = "m3",
        label = "멀티 3명 두 번째",
        profile = "multi_second",
        players = 3,
        easierThan = "m2",
    },
    {
        key = "f4",
        label = "멀티 4명 처음",
        profile = "multi_first",
        players = 4,
        easierThan = "f2",
        accepted = { 10, 52, 38, 0 },
    },
    {
        key = "m4",
        label = "멀티 4명 두 번째",
        profile = "multi_second",
        players = 4,
        easierThan = "m2",
    },
}

type Row = {
    n: number,
    fail: number,
    bronze: number,
    silver: number,
    gold: number,
    days: number,
    stall: number,
    reasons: { [string]: number },
    windows: { { fail: number, medal2: number, n: number } },
}

local function measure(config, mode, windows: { any }, seedCount: number): Row
    local row: Row = {
        n = 0,
        fail = 0,
        bronze = 0,
        silver = 0,
        gold = 0,
        days = 0,
        stall = 0,
        reasons = {},
        windows = {},
    }
    for _, window in windows do
        local w = { fail = 0, medal2 = 0, n = 0 }
        for seed = 1, seedCount do
            local r = Bot.simulate(config, mode.profile, window, seed, mode.players)
            row.n += 1
            w.n += 1
            row.days += r.daysTaken
            row.stall += r.stallDays
            if r.outcome == "won" then
                row[r.medal] += 1
                if r.medal ~= "bronze" then
                    w.medal2 += 1
                end
            else
                row.fail += 1
                w.fail += 1
                local why = if r.reason == "shortage"
                    then ({ water = "물", food = "식량", both = "물과 식량" })[r.lossResource or "food"]
                    else "60일 메달 없음"
                row.reasons[why] = (row.reasons[why] or 0) + 1
            end
        end
        table.insert(row.windows, w)
    end
    return row
end

local function pctOf(count: number, n: number): number
    return if n > 0 then count * 100 / n else 0
end

local function rowLine(mode, row: Row, results: { [string]: Row }): string
    local f, b = pctOf(row.fail, row.n), pctOf(row.bronze, row.n)
    local sv, g = pctOf(row.silver, row.n), pctOf(row.gold, row.n)
    local reasons = {}
    for why, count in row.reasons do
        table.insert(reasons, { why = why, count = count })
    end
    table.sort(reasons, function(a, c)
        return a.count > c.count
    end)
    local reasonText = {}
    for i = 1, math.min(2, #reasons) do
        table.insert(
            reasonText,
            string.format(
                "%s %.0f%%",
                reasons[i].why,
                reasons[i].count * 100 / math.max(1, row.fail)
            )
        )
    end
    local fLo, fHi, mLo, mHi = math.huge, -math.huge, math.huge, -math.huge
    for _, w in row.windows do
        local wf, wm = pctOf(w.fail, w.n), pctOf(w.medal2, w.n)
        fLo, fHi = math.min(fLo, wf), math.max(fHi, wf)
        mLo, mHi = math.min(mLo, wm), math.max(mHi, wm)
    end
    local goal = ""
    if mode.target then
        local t = mode.target
        local gap = (
            math.abs(f - t[1])
            + math.abs(b - t[2])
            + math.abs(sv - t[3])
            + math.abs(g - t[4])
        ) / 4
        goal = string.format(
            " | 목표 %d/%d/%d/%d, 평균 차이 %.1f%%p",
            t[1],
            t[2],
            t[3],
            t[4],
            gap
        )
    elseif mode.easierThan and results[mode.easierThan] then
        local base = results[mode.easierThan]
        goal = string.format(
            " | 2명 대비 실패 %+.0f%%p, 은+금 %+.0f%%p",
            f - pctOf(base.fail, base.n),
            (sv + g) - pctOf(base.silver + base.gold, base.n)
        )
    end
    if mode.accepted then
        local a = mode.accepted
        goal ..= string.format(
            " | 7.5.1 %d/%d/%d/%d (실패 %+.0f%%p)",
            a[1],
            a[2],
            a[3],
            a[4],
            f - a[1]
        )
    end
    return string.format(
        "  %-16s 실패 %3.0f%% 동 %3.0f%% 은 %3.0f%% 금 %3.0f%% | 평균 %4.1f일 정지 %4.1f일 | 실패 사유 %s | 구간별 실패 %.0f ~ %.0f%%, 은+금 %.0f ~ %.0f%%%s",
        mode.label,
        f,
        b,
        sv,
        g,
        row.days / math.max(1, row.n),
        row.stall / math.max(1, row.n),
        if #reasonText > 0 then table.concat(reasonText, ", ") else "없음",
        fLo,
        fHi,
        mLo,
        mHi,
        goal
    )
end

local function modeReport(
    title: string,
    config,
    windows: { any },
    seedCount: number,
    keys: { string }?
)
    print("")
    print(string.format("[밸런스] %s, 구간 %d개 x 시드 %d", title, #windows, seedCount))
    local results: { [string]: Row } = {}
    for _, mode in MODES do
        if keys == nil or table.find(keys, mode.key) then
            results[mode.key] = measure(config, mode, windows, seedCount)
            print(rowLine(mode, results[mode.key], results))
        end
    end
end

-- 회의 숫자 대비 바뀐 값 (MISSIONS.C와 MANUAL_DRIVE 아래 모든 값 비교)
local function diffReport(config)
    local meeting = Bot.meetingConfig(config)
    local lines = {}
    local function walk(a, b, path: string)
        if typeof(a) == "table" and typeof(b) == "table" then
            local keys = {}
            for k in a do
                keys[k] = true
            end
            for k in b do
                keys[k] = true
            end
            for k in keys do
                walk(a[k], b[k], path .. "." .. tostring(k))
            end
        elseif a ~= b then
            table.insert(
                lines,
                string.format("  %s: 회의 %s -> %s", path, tostring(a), tostring(b))
            )
        end
    end
    walk(meeting.MISSIONS.C, config.MISSIONS.C, "C")
    walk(meeting.MANUAL_DRIVE, config.MANUAL_DRIVE, "MANUAL_DRIVE")
    table.sort(lines)
    print("")
    print("[회의 숫자(와 처음 규칙) 대비 변경] " .. #lines .. "개")
    for _, line in lines do
        print(line)
    end
end

if report then
    local windows, source = weatherWindows()
    print("")
    print("우주 기상 구간: " .. source)
    tripReport(MissionConfig)
    manualReport(MissionConfig)
    diffReport(MissionConfig)
    local core = { "h1", "s1", "f2", "m2" }
    modeReport("MissionConfig (선택한 경제)", MissionConfig, windows, seeds)
    modeReport(
        "비교: 대원 소비 인원 비례 켬 (2번째 대원부터 식량 +1, 물 +1)",
        Bot.withOverrides(MissionConfig, { ["MISSIONS.C.crewScaling"] = true }),
        windows,
        seeds,
        { "f2", "m2", "f3", "m3", "f4", "m4" }
    )
    modeReport(
        "비교: 처음 규칙 (모두 정지, 대원 에너지 먼저)",
        Bot.withOverrides(MissionConfig, {
            ["MISSIONS.C.stallMode"] = "all",
            ["MISSIONS.C.crewEnergyLast"] = false,
        }),
        windows,
        seeds,
        core
    )
    modeReport("비교: 회의 숫자", Bot.meetingConfig(MissionConfig), windows, seeds, core)
    -- 민감도: 가장 크게 움직이는 값(시작 식량)과 패널 수를 한 단계씩
    local start = MissionConfig.MISSIONS.C.start
    local panels = MissionConfig.MISSIONS.C.panels.total
    local steps = {
        { "시작 식량 " .. (start.food - 3), { ["MISSIONS.C.start.food"] = start.food - 3 } },
        { "시작 식량 " .. (start.food + 3), { ["MISSIONS.C.start.food"] = start.food + 3 } },
        { "패널 " .. (panels - 1) .. "장", { ["MISSIONS.C.panels.total"] = panels - 1 } },
        { "패널 " .. (panels + 1) .. "장", { ["MISSIONS.C.panels.total"] = panels + 1 } },
    }
    if sensitivity then
        table.insert(steps, {
            "LED 유지 전력 -1",
            {
                ["MISSIONS.C.facilities.led.upkeep.energy"] = MissionConfig.MISSIONS.C.facilities.led.upkeep.energy
                    - 1,
            },
        })
        table.insert(steps, {
            "LED 유지 전력 +1",
            {
                ["MISSIONS.C.facilities.led.upkeep.energy"] = MissionConfig.MISSIONS.C.facilities.led.upkeep.energy
                    + 1,
            },
        })
        table.insert(
            steps,
            { "시작 에너지 +10", { ["MISSIONS.C.start.energy"] = start.energy + 10 } }
        )
        table.insert(steps, {
            "자율주행 하루 에너지 -3",
            {
                ["MISSIONS.C.rover.energyPerTravelDay"] = MissionConfig.MISSIONS.C.rover.energyPerTravelDay
                    - 3,
            },
        })
        table.insert(
            steps,
            { "수동 배터리 소모 0.1", { ["MANUAL_DRIVE.batteryDrainPerSecond"] = 0.1 } }
        )
        table.insert(
            steps,
            { "수동 배터리 소모 0.2", { ["MANUAL_DRIVE.batteryDrainPerSecond"] = 0.2 } }
        )
    end
    for _, step in steps do
        modeReport(
            "민감도: " .. step[1],
            Bot.withOverrides(MissionConfig, step[2]),
            windows,
            seeds,
            core
        )
    end
end

if failed > 0 then
    process.exit(1)
end
