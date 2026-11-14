-- v2 Rules 순수 규칙 테스트 (docs/V2_PLAN.md 15절). tests/harness.luau 형식: function(harness)
-- 숫자는 MissionConfig에서 읽어 비교한다. 특정 숫자에 묶인 테스트는 설정을 복사해 값을 고정한다(Bot.withOverrides).

local Bot = require("./bot_v2")
local MissionConfig = require("../src/shared/MissionConfig")
local Rules = require("../src/shared/Rules")

local C = MissionConfig.MISSIONS.C

-- 리드가 정한 우주 기상 입력 형식의 픽스처 (실제 데이터는 src/shared/SpaceWeatherData.luau)
local WINDOW = {
    id = "2024-06-21",
    startDate = { year = 2024, month = 6, day = 21 },
    events = {
        {
            kind = "SEP",
            day = 12,
            durationDays = 2,
            sourceDate = { year = 2024, month = 7, day = 2 },
        },
        {
            kind = "GST",
            day = 30,
            durationDays = 1,
            kp = 7,
            sourceDate = { year = 2024, month = 7, day = 20 },
        },
        {
            kind = "GST",
            day = 40,
            durationDays = 1,
            kp = 5, -- Kp 6 미만은 규칙이 버린다 [Q14]
            sourceDate = { year = 2024, month = 7, day = 30 },
        },
    },
}

local KEY_PATTERN = "^[a-z][a-z0-9_]*%.[a-z0-9_%.]+$"

local function fresh(seed: number?, window: any?)
    return Rules.newState("C", MissionConfig, seed or 1, window)
end

-- n일 마감, 이벤트 키 목록을 모은다
local function advance(s, n: number, config: any?)
    local keys = {}
    local all = {}
    for _ = 1, n do
        local events
        s, events = Rules.applyDay(s, config or MissionConfig)
        for _, e in events do
            table.insert(keys, e.key)
            table.insert(all, e)
        end
    end
    return s, keys, all
end

local function hasKey(keys: { string }, key: string): boolean
    return table.find(keys, key) ~= nil
end

local function build(s, defId: string, config: any?, siteIndex: number?)
    local ok, new, reason = Rules.startBuild(s, config or MissionConfig, defId, siteIndex)
    assert(ok, "build " .. defId .. " failed: " .. (reason and reason.key or "?"))
    return new
end

-- 시설을 바로 완공 상태로 (테스트 준비용)
local function finishAll(s)
    for _, f in s.facilities do
        if f.status == "building" then
            f.status = "active"
            f.daysLeft = 0
            f.completedDay = s.day
        end
    end
    return s
end

-- Msg가 키 형식만 쓰고 문장이 없는지 (중첩 Msg 포함). 문자열 값은 id나 열거형(공백 없음)만 허용
local function checkMsg(t, m, where: string)
    t.truthy(typeof(m) == "table" and typeof(m.key) == "string", where .. " Msg 형식")
    t.truthy(string.match(m.key, KEY_PATTERN) ~= nil, where .. " 키 형식 " .. tostring(m.key))
    if m.args then
        for name, value in m.args do
            if typeof(value) == "table" then
                checkMsg(t, value, where .. "." .. name)
            elseif typeof(value) == "string" then
                t.falsy(string.find(value, " ", 1, true), where .. " 문장 값 " .. value)
            else
                t.truthy(
                    typeof(value) == "number" or typeof(value) == "boolean",
                    where .. " 값 종류 " .. name
                )
            end
        end
    end
end

return function(t)
    t.test("newState: 시작 자원(MissionConfig), 상한 100, 1일차, 60일", function()
        local s = fresh()
        t.eq(s.phase, "playing")
        t.eq(s.day, 1)
        t.eq(s.totalDays, 60)
        t.eq(s.energy, C.start.energy)
        t.eq(s.water, C.start.water)
        t.eq(s.food, C.start.food)
        t.eq(s.cap, 100)
        t.eq(s.panels, 0)
        t.eq(s.rover.status, "parked")
    end)

    t.test("newState: 얼음 후보지는 거리순, 거리로 위험 등급 [Q37, Q30]", function()
        local s = fresh()
        local ids, risks = {}, {}
        for _, site in s.sites do
            table.insert(ids, site.id)
            table.insert(risks, site.risk)
        end
        t.eq(table.concat(ids, ","), "Ice4,Ice1,Ice2,Ice3,Ice5")
        t.eq(table.concat(risks, ","), "low,low,mid,mid,high")
        t.eq(s.sites[1].distance, 185)
        t.eq(s.sites[5].distance, 610)
    end)

    t.test("newState: 서버 실측 거리로 덮어쓰면 순서를 다시 정한다", function()
        local s = Rules.newState("C", MissionConfig, 1, nil, { iceDistances = { Ice5 = 100 } })
        t.eq(s.sites[1].id, "Ice5")
        t.eq(s.sites[1].risk, "low")
    end)

    t.test("newState: B는 아직 자리 표시라 받지 않는다", function()
        local ok = pcall(Rules.newState, "B", MissionConfig, 1, nil)
        t.falsy(ok)
    end)

    t.test("하루 마감: 대원 소비 E12 W3 F3, 다음 날", function()
        local s = advance(fresh(), 1)
        t.eq(s.day, 2)
        t.eq(s.energy, C.start.energy - C.crew.energy)
        t.eq(s.water, C.start.water - C.crew.water)
        t.eq(s.food, C.start.food - C.crew.food)
    end)

    t.test(
        "하루 마감: 소비를 먼저 빼고 패널 발전을 더한다 (패널 함정 방지)",
        function()
            local s = fresh()
            s.energy = 5
            s.panels = 3
            s = advance(s, 1)
            t.eq(s.energy, 3 * C.panels.output, "max(0, 5 - 12) + 9")
        end
    )

    t.test("상한 100: 넘친 양은 버리고 기록", function()
        local s = fresh()
        s.energy = 95
        s.panels = 10
        s = advance(s, 1)
        t.eq(s.energy, 100)
        t.eq(s.stats.wastedEnergy, 95 - 12 + 10 * C.panels.output - 100)
    end)

    t.test("패널: 비용, 하루 한도, 전체 한도", function()
        local s = fresh()
        local ok, new, m = Rules.installPanel(s, MissionConfig)
        t.truthy(ok)
        t.eq(m.key, "toast.panel.installed")
        t.eq(new.energy, C.start.energy - C.panels.cost)
        t.eq(s.panels, 0, "입력 상태는 그대로")
        for _ = 2, C.panels.perDay do
            ok, new = Rules.installPanel(new, MissionConfig)
            t.truthy(ok)
        end
        local ok2, _, m2 = Rules.installPanel(new, MissionConfig)
        t.falsy(ok2)
        t.eq(m2.key, "toast.panel.limit_today")
        local full = fresh()
        full.panels = C.panels.total
        local ok3, _, m3 = Rules.installPanel(full, MissionConfig)
        t.falsy(ok3)
        t.eq(m3.key, "toast.panel.full")
    end)

    t.test(
        "패널 구조 장치: 에너지가 모자라도 발전이 대원 소비보다 작으면 남은 에너지로 설치",
        function()
            local s = fresh()
            s.energy = 2
            s.panels = 1
            local ok, new, m = Rules.installPanel(s, MissionConfig)
            t.truthy(ok)
            t.eq(m.key, "toast.panel.installed_emergency")
            t.eq(new.energy, 0)
            t.eq(new.panels, 2)
            local rich = fresh()
            rich.energy = 2
            rich.panels = math.ceil(C.crew.energy / C.panels.output) -- 발전이 대원 소비 이상, 구조 장치 없음
            local ok2, _, m2 = Rules.installPanel(rich, MissionConfig)
            t.falsy(ok2)
            t.eq(m2.key, "toast.panel.need_energy")
        end
    )

    t.test("에어록 점검: 비용 없음, 2일 뒤 가동, 그다음부터 유지비", function()
        local s = fresh()
        local ok, new, m = Rules.inspectAirlock(s, MissionConfig)
        t.truthy(ok)
        t.eq(m.key, "toast.build.started")
        t.eq(new.energy, C.start.energy)
        local keys
        new, keys = advance(new, C.facilities.airlock.buildDays)
        t.truthy(hasKey(keys, "toast.build.done"))
        t.eq(new.facilities.airlock.status, "active")
        local before = new.energy
        new = advance(new, 1)
        t.eq(new.energy, before - C.crew.energy - C.facilities.airlock.upkeep.energy)
        local again = Rules.inspectAirlock(new, MissionConfig)
        t.falsy(again, "이미 점검함")
    end)

    t.test("재배 공간: 비용, 건설 일수, 주기마다 자동 수확 [Q12]", function()
        local s = fresh()
        s.energy, s.water = 100, 100
        s = build(s, "farm")
        t.eq(s.energy, 100 - C.facilities.farm.cost.energy)
        t.eq(s.water, 100 - C.facilities.farm.cost.water)
        s = advance(s, C.facilities.farm.buildDays)
        t.eq(s.facilities.farm.status, "active")
        s.energy, s.water, s.food = 100, 100, 50
        local keys, all
        s, keys = advance(s, C.facilities.farm.harvestEveryDays - 1)
        t.falsy(hasKey(keys, "toast.harvest"))
        s.energy, s.water = 100, 100
        s, keys, all = advance(s, 1)
        t.truthy(hasKey(keys, "toast.harvest"))
        for _, e in all do
            if e.key == "toast.harvest" then
                t.eq(e.args.amount, C.facilities.farm.harvestAmount)
            end
        end
    end)

    t.test(
        "업그레이드: LED 주기 단축과 전력 +20%, 영양분 물 절반, 수경 수확량 [Q12, Q13]",
        function()
            local s = fresh()
            s.facilities.farm = {
                id = "farm",
                defId = "farm",
                status = "active",
                daysLeft = 0,
                buildDays = 3,
                paused = false,
                progress = 0,
                startedDay = 1,
                completedDay = 1,
            }
            local _, e0, w0 = Rules.upkeepBreakdown(s, MissionConfig)
            t.eq(e0, C.facilities.farm.upkeep.energy)
            t.eq(w0, C.facilities.farm.upkeep.water)
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "led"))
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "nutrient"))
            local list, e1, w1 = Rules.upkeepBreakdown(s, MissionConfig)
            local farmLine
            for _, line in list do
                if line.defId == "farm" then
                    farmLine = line
                end
            end
            t.near(
                farmLine.energy,
                C.facilities.farm.upkeep.energy * C.facilities.led.farmEnergyUpkeepMultiplier
            )
            t.near(
                farmLine.water,
                C.facilities.farm.upkeep.water * C.facilities.nutrient.farmWaterUpkeepMultiplier
            )
            t.near(
                e1,
                farmLine.energy
                    + C.facilities.led.upkeep.energy
                    + C.facilities.nutrient.upkeep.energy
            )
            t.near(
                w1,
                farmLine.water + C.facilities.led.upkeep.water + C.facilities.nutrient.upkeep.water
            )
            -- LED 주기
            local keys
            for _ = 1, C.facilities.led.harvestEveryDays - 1 do
                s.energy, s.water = 100, 100
                s, keys = advance(s, 1)
                t.falsy(hasKey(keys, "toast.harvest"))
            end
            s.energy, s.water = 100, 100
            s, keys = advance(s, 1)
            t.truthy(hasKey(keys, "toast.harvest"), "LED면 4일째 수확")
            t.eq(Rules.medal(s, MissionConfig), "silver")
        end
    )

    t.test("수경 재배: 파이프가 있어야 짓고, 수확량이 34", function()
        local s = fresh()
        s.energy, s.water = 100, 100
        s = finishAll(build(s, "farm"))
        s.energy, s.water = 100, 100
        local ok, reason = Rules.canBuild(s, MissionConfig, "hydroponics")
        t.falsy(ok)
        t.eq(reason and reason.key, "toast.build.need_prereq")
        t.eq(reason and reason.args and reason.args.facility.key, "facility.pipe.name")
        s.deliveries = C.facilities.pipe.unlockDeliveries
        s = finishAll(build(s, "pipe", nil, 5))
        s.energy, s.water = 100, 100
        s = finishAll(build(s, "hydroponics"))
        s.facilities.farm.progress = C.facilities.farm.harvestEveryDays - 1
        s.energy, s.water = 100, 100
        local _, _, all = advance(s, 1)
        local amount = 0
        for _, e in all do
            if e.key == "toast.harvest" then
                amount = e.args.amount
            end
        end
        t.eq(amount, C.facilities.hydroponics.harvestAmount)
    end)

    t.test(
        "멈춤: 유지비 0, 수확 타이머 정지, 재배 공간이 멈추면 업그레이드 유지비도 0 [Q33]",
        function()
            local s = fresh()
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "farm"))
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "led"))
            local ok, paused, m = Rules.setPaused(s, MissionConfig, "farm", true)
            t.truthy(ok)
            t.eq(m.key, "toast.pause.on")
            local _, e, w = Rules.upkeepBreakdown(paused, MissionConfig)
            t.eq(e, 0)
            t.eq(w, 0)
            local progress = paused.facilities.farm.progress
            paused = advance(paused, 3)
            t.eq(paused.facilities.farm.progress, progress)
            local again = Rules.setPaused(paused, MissionConfig, "farm", true)
            t.falsy(again, "이미 멈춤")
            local building = fresh()
            building.energy, building.water = 100, 100
            building = build(building, "farm")
            local ok2, _, m2 = Rules.setPaused(building, MissionConfig, "farm", true)
            t.falsy(ok2)
            t.eq(m2.key, "toast.pause.not_active")
        end
    )

    t.test(
        "정지(처음 규칙 all + 대원 에너지 먼저): 유지비를 못 내면 모든 시설 정지 [Q3]",
        function()
            local cfg = Bot.withOverrides(MissionConfig, {
                ["MISSIONS.C.stallMode"] = "all",
                ["MISSIONS.C.crewEnergyLast"] = false,
            })
            local s = Rules.newState("C", cfg, 1, nil)
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "farm", cfg))
            s.energy = C.crew.energy -- 대원 몫을 내면 유지비를 낼 에너지가 없다
            s.water = 80
            local flows = Rules.flows(s, cfg)
            t.truthy(flows.stalled)
            t.eq(flows.stallReason, "energy")
            local new, keys = advance(s, 1, cfg)
            t.truthy(new.stalled)
            t.truthy(hasKey(keys, "toast.stall.stopped_energy"), "멈춘 시설 이름 알림")
            t.eq(new.water, 80 - C.crew.water, "유지 물도 내지 않는다")
            t.eq(new.facilities.farm.progress, 0, "수확 타이머 정지")
            t.eq(new.phase, "playing", "에너지 0은 실패가 아니다")
        end
    )

    t.test(
        "정지 priority: 덜 중요한 시설부터 멈추고 재배 공간은 마지막까지 [stallMode]",
        function()
            local cfg = Bot.withOverrides(MissionConfig, {
                ["MISSIONS.C.stallMode"] = "priority",
                ["MISSIONS.C.crewEnergyLast"] = false,
            })
            local s = Rules.newState("C", cfg, 1, nil)
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "farm", cfg))
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "airlock", cfg))
            -- 대원 + 재배 공간 유지비만 낼 수 있는 에너지 (에어록 몫은 없다)
            s.energy = C.crew.energy + C.facilities.farm.upkeep.energy
            s.water = 80
            local flows = Rules.flows(s, cfg)
            t.truthy(flows.stalled)
            t.eq(flows.stallReason, "energy")
            t.truthy(flows.running.farm, "재배 공간은 돈다")
            t.falsy(flows.running.airlock, "에어록이 먼저 멈춘다")
            t.eq(table.concat(flows.shed, ","), "airlock")
            local new, _, all = advance(s, 1, cfg)
            t.eq(new.facilities.farm.progress, 1, "수확 타이머가 간다")
            local named = nil
            for _, e in all do
                if e.key == "toast.stall.stopped_energy" then
                    named = e.args and e.args.facilities
                end
            end
            t.eq(
                named and named.key,
                "facility.airlock.name",
                "멈춘 시설 이름이 알림에 들어간다"
            )
            t.eq(table.concat(new.shed, ","), "airlock")
            -- 다음 날 에너지가 넉넉하면 다시 돈다 (멈춘 시설이 없으면 cleared)
            new.energy = 100
            local _, keys2 = advance(new, 1, cfg)
            t.truthy(hasKey(keys2, "toast.stall.cleared"))
            -- 같은 날 계속 멈춰 있으면 다시 알리지 않는다
            new.energy = C.crew.energy + C.facilities.farm.upkeep.energy
            local _, keys3 = advance(new, 1, cfg)
            t.falsy(
                hasKey(keys3, "toast.stall.stopped_energy"),
                "이미 멈춘 시설은 다시 알리지 않는다"
            )
            local allCfg = Bot.withOverrides(cfg, { ["MISSIONS.C.stallMode"] = "all" })
            local same = Rules.flows(s, allCfg)
            t.falsy(same.running.farm, "all 모드는 모두 멈춘다")
        end
    )

    t.test(
        "crewEnergyLast: 시설 에너지 유지비를 대원 에너지보다 먼저 낸다",
        function()
            local cfg = Bot.withOverrides(MissionConfig, {
                ["MISSIONS.C.stallMode"] = "priority",
                ["MISSIONS.C.crewEnergyLast"] = true,
            })
            local s = Rules.newState("C", cfg, 1, nil)
            s.energy, s.water = 100, 100
            s = finishAll(build(s, "farm", cfg))
            s.energy = C.facilities.farm.upkeep.energy -- 재배 공간 몫뿐, 대원 몫은 없다
            s.water = 80
            local flows = Rules.flows(s, cfg)
            t.falsy(flows.stalled, "재배 공간은 돈다")
            local new = advance(s, 1, cfg)
            t.eq(new.facilities.farm.progress, 1)
            t.eq(
                new.energy,
                s.panels * C.panels.output,
                "대원 에너지는 못 내고 0에서 발전만 더한다"
            )
            t.eq(new.phase, "playing", "대원 에너지 부족은 실패가 아니다 (감점만)")
        end
    )

    t.test(
        "대원 에너지를 못 낸 날: 에너지 바닥 감점과 경고 (발전이 들어와도)",
        function()
            local cfg = Bot.withOverrides(MissionConfig, {
                ["MISSIONS.C.stallMode"] = "priority",
                ["MISSIONS.C.crewEnergyLast"] = true,
            })
            local s = Rules.newState("C", cfg, 1, nil)
            s.panels = C.panels.total -- 하루 끝 발전이 20을 넘어도
            s.energy = 5
            local new, _, all = advance(s, 1, cfg)
            t.truthy(
                new.energy >= MissionConfig.SCORE.lowThreshold,
                "하루 끝 에너지는 발전으로 높다"
            )
            t.eq(new.score.energy.zero, 1, "그래도 바닥난 날로 감점")
            t.eq(new.crewEnergyShort, C.crew.energy - 5)
            local warned = nil
            for _, e in all do
                if e.key == "banner.energy.crew_unpaid" then
                    warned = e.args and e.args.amount
                end
            end
            t.eq(warned, C.crew.energy - 5, "못 낸 양을 경고")
        end
    )

    t.test("화면 거리는 정수 미터 (metersPerStud = 2560 / 2044)", function()
        local s = fresh()
        s.rover.status = "broken"
        s.rover.brokenDistance = 600
        s.energy = 100
        local ok, _, m = Rules.walkRepairRover(s, MissionConfig)
        t.falsy(ok)
        t.eq(m.key, "toast.rover.too_far_walk")
        local walk = 600 + MissionConfig.WALK_REPAIR.startOffset
        t.eq(m.args and m.args.distance, math.round(walk * 2560 / 2044))
        t.eq(
            m.args and m.args.limit,
            math.round(Rules.walkRepairLimit(MissionConfig) * 2560 / 2044)
        )
    end)

    t.test("정지: 물이 유지비를 못 내도 정지", function()
        local s = fresh()
        s.energy, s.water = 100, 100
        s = finishAll(build(s, "farm"))
        s.water = C.crew.water + C.facilities.farm.upkeep.water - 1
        local flows = Rules.flows(s, MissionConfig)
        t.truthy(flows.stalled)
        t.eq(flows.stallReason, "water")
    end)

    t.test(
        "로버 계획: 왕복 일수 1,2,2,2,3(가장 가까운 곳 1일, 가장 먼 곳 3일)과 거리 비례 에너지 [Q7, Q37]",
        function()
            local s = fresh()
            local days, energy = {}, {}
            for index = 1, #s.sites do
                local plan = Rules.tripPlan(s, MissionConfig, index, false)
                table.insert(days, tostring(plan.days))
                table.insert(energy, plan.energy)
            end
            t.eq(table.concat(days, ","), "1,2,2,2,3")
            for i = 2, #energy do
                t.truthy(energy[i] > energy[i - 1], "먼 곳일수록 에너지가 크다")
            end
        end
    )

    t.test(
        "로버 계획: 서둘러 가기는 위험 한 단계 위, 에너지 x1.5, 줄 때만 rushHelps",
        function()
            local s = fresh()
            local near = Rules.tripPlan(s, MissionConfig, 1, true)
            t.eq(near.risk, "mid")
            t.falsy(near.rushHelps, "가장 가까운 곳은 이미 1일")
            local far = Rules.tripPlan(s, MissionConfig, 5, true)
            local farPlain = Rules.tripPlan(s, MissionConfig, 5, false)
            t.eq(far.risk, "extreme")
            t.truthy(far.rushHelps)
            t.truthy(far.days < farPlain.days)
            t.truthy(far.energy > farPlain.energy)
            t.near(far.damageChance, C.rover.risk.extreme.damageChance)
        end
    )

    t.test(
        "로버 파견: 에너지 차감, 귀환하면 물 30과 하역 1회, 지점 쿨타임 3일 [Q9]",
        function()
            local s = fresh()
            s.water = 40
            local ok, new, m = Rules.dispatchRover(s, MissionConfig, 1, false)
            t.truthy(ok)
            t.eq(m.key, "toast.rover.dispatched")
            local plan = Rules.tripPlan(s, MissionConfig, 1, false)
            t.eq(new.energy, C.start.energy - plan.energy)
            local busy, _, m2 = Rules.dispatchRover(new, MissionConfig, 2, false)
            t.falsy(busy)
            t.eq(m2.key, "toast.rover.busy")
            local keys
            new, keys = advance(new, 1)
            t.truthy(hasKey(keys, "toast.rover.returned"))
            t.eq(new.water, 40 - C.crew.water + C.ice.amountPerTrip)
            t.eq(new.deliveries, 1)
            t.eq(new.rover.status, "parked")
            t.eq(new.sites[1].cooldownLeft, C.ice.cooldownDays)
            local cool, _, m3 = Rules.dispatchRover(new, MissionConfig, 1, false)
            t.falsy(cool)
            t.eq(m3.key, "toast.rover.site_cooldown")
            new = advance(new, C.ice.cooldownDays)
            t.eq(new.sites[1].cooldownLeft, 0)
            new.energy = 100 -- 쿨타임만 보려고 에너지를 채운다
            t.truthy((Rules.dispatchRover(new, MissionConfig, 1, false)))
        end
    )

    t.test(
        "로버: 3일 왕복은 중간에 채취하고 3일째 마감에 돌아온다",
        function()
            local s = fresh()
            local _, new = Rules.dispatchRover(s, MissionConfig, 5, false)
            new = advance(new, 1)
            t.eq(new.rover.status, "fsd")
            t.falsy(new.rover.trip.collected)
            new = advance(new, 1)
            t.truthy(new.rover.trip.collected)
            local keys
            new, keys = advance(new, 1)
            t.truthy(hasKey(keys, "toast.rover.returned"))
            t.eq(new.rover.status, "parked")
        end
    )

    t.test(
        "SEP: 패널, 현장 건설, 파견 금지, 로버 정지, 발전과 건설은 계속, 알림과 출처 날짜 [Q15, Q36]",
        function()
            local s = fresh(1, WINDOW)
            s.day = 10
            s.panels = 4
            local _, onTrip = Rules.dispatchRover(s, MissionConfig, 5, false) -- 3일 왕복
            onTrip.energy, onTrip.water = 100, 100
            onTrip = build(onTrip, "farm")
            local keys, all
            onTrip, keys = advance(onTrip, 1) -- 10일 마감 -> 11일
            t.truthy(hasKey(keys, "banner.sep.warning"), "내일 SEP: 15초 전 경보용")
            local warn = Rules.weatherStatus(onTrip)
            t.eq(warn and warn.stage, "warning")
            onTrip, keys, all = advance(onTrip, 1) -- 11일 마감 -> 12일 (SEP 시작)
            t.truthy(hasKey(keys, "banner.sep.active"))
            local sourceSeen = false
            for _, e in all do
                if e.key == "event.source" then
                    sourceSeen = true
                    t.eq(e.args.date.key, "fmt.date.long")
                    t.eq(e.args.date.args.month, 7)
                    t.eq(e.args.date.args.year, 2024)
                    t.eq(e.args.date.args.month_name.key, "date.month.7")
                end
            end
            t.truthy(sourceSeen, "출처 한 줄 (Q36)")
            local sep = Rules.weatherOn(onTrip)
            t.truthy(sep ~= nil)
            local status = Rules.weatherStatus(onTrip)
            t.eq(status and status.stage, "active")
            t.eq(status and status.daysLeft, 2)
            t.eq(status and status.banner.key, "banner.sep.days_left")
            t.eq(status and status.banner.args and status.banner.args.count, 2)
            local view = Rules.roverFsdView(onTrip, MissionConfig)
            t.eq(view and view.stoppedBy, "SEP")
            local p, _, pm = Rules.installPanel(onTrip, MissionConfig)
            t.falsy(p)
            t.eq(pm.key, "toast.outdoor.locked_sep")
            local b, bm = Rules.canBuild(onTrip, MissionConfig, "led")
            t.falsy(b)
            t.truthy(bm ~= nil)
            local elapsed = onTrip.rover.trip.elapsed
            local farmDaysLeft = onTrip.facilities.farm.daysLeft
            local energyBefore = onTrip.energy
            local after
            after, keys = advance(onTrip, 1)
            t.eq(after.rover.trip.elapsed, elapsed, "SEP 날 로버 정지")
            t.eq(after.facilities.farm.daysLeft, math.max(0, farmDaysLeft - 1), "건설은 계속")
            t.eq(after.energy, math.min(100, energyBefore - C.crew.energy + 4 * C.panels.output))
            after, keys = advance(after, 1) -- SEP 2일째 마감
            t.truthy(hasKey(keys, "banner.sep.end"))
            t.eq(Rules.weatherOn(after), nil)
        end
    )

    t.test("GST: Kp 6 이상만, 파견과 지도 파이프 금지, 로버 정지 [Q14]", function()
        local s = fresh(1, WINDOW)
        local count = 0
        for _, e in s.weather.events do
            if e.kind == "GST" then
                count += 1
            end
        end
        t.eq(count, 1, "Kp 5 사건은 버린다")
        s.day = 29
        local _, onTrip = Rules.dispatchRover(s, MissionConfig, 4, false) -- 2일 왕복
        local keys
        onTrip, keys = advance(onTrip, 1) -- 29일 마감 -> 30일 GST
        t.truthy(hasKey(keys, "banner.gst.active"))
        t.truthy(hasKey(keys, "banner.gst.rover_stopped"), "자율주행 중이면 정지 알림")
        t.truthy(hasKey(keys, "event.source"))
        local elapsed = onTrip.rover.trip.elapsed
        local home = fresh(1, WINDOW)
        home.day = 30
        local ok, _, m = Rules.dispatchRover(home, MissionConfig, 1, false)
        t.falsy(ok)
        t.eq(m.key, "toast.map.offline_gst")
        home.deliveries = C.facilities.pipe.unlockDeliveries
        home.energy, home.water = 100, 100
        local okPipe, reason = Rules.canBuild(home, MissionConfig, "pipe", 5)
        t.falsy(okPipe)
        t.eq(reason and reason.key, "toast.map.offline_gst")
        onTrip, keys = advance(onTrip, 1)
        t.eq(onTrip.rover.trip.elapsed, elapsed, "GST 날 로버 정지")
        t.truthy(hasKey(keys, "banner.gst.end"))
    end)

    t.test(
        "파이프: 하역 5회 해금, 지점 선택, 그 지점은 로버 불가, 3일마다 30 [Q10]",
        function()
            local s = fresh()
            s.energy, s.water = 100, 50
            local ok, reason = Rules.canBuild(s, MissionConfig, "pipe", 5)
            t.falsy(ok)
            t.eq(reason and reason.key, "toast.pipe.locked")
            s.deliveries = C.facilities.pipe.unlockDeliveries - 1
            local okd, afterDelivery, _, events = Rules.deliverWater(s, MissionConfig, 20)
            t.truthy(okd)
            t.eq(afterDelivery.deliveries, C.facilities.pipe.unlockDeliveries)
            t.eq(events[1] and events[1].key, "toast.pipe.unlocked")
            local noSite, why = Rules.canBuild(afterDelivery, MissionConfig, "pipe")
            t.falsy(noSite)
            t.eq(why and why.key, "toast.pipe.pick_site")
            afterDelivery.energy, afterDelivery.water = 100, 100
            local piped = build(afterDelivery, "pipe", nil, 5)
            t.eq(piped.sites[5].pipeId, "pipe", "첫 파이프 id는 계약 id 그대로")
            local blocked, _, m = Rules.dispatchRover(piped, MissionConfig, 5, false)
            t.falsy(blocked)
            t.eq(m.key, "toast.rover.site_piped")
            local maxed, maxWhy = Rules.canBuild(piped, MissionConfig, "pipe", 4)
            t.falsy(maxed)
            t.eq(maxWhy and maxWhy.key, "toast.build.max_count")
            piped = advance(piped, C.facilities.pipe.buildDays)
            t.truthy(Rules.isBuilt(piped, "pipe"))
            piped.water = 50
            piped.energy = 100
            local keys
            piped, keys = advance(piped, C.facilities.pipe.deliverEveryDays)
            t.truthy(hasKey(keys, "toast.pipe.delivered"))
            t.eq(piped.stats.pipeWater, C.facilities.pipe.deliverAmount)
        end
    )

    t.test(
        "파이프는 SEP 중에도 지도에서 지을 수 있다 (현장 건설과 다름)",
        function()
            local s = fresh(1, WINDOW)
            s.day = 12
            s.deliveries = C.facilities.pipe.unlockDeliveries
            s.energy, s.water = 100, 100
            t.truthy((Rules.canBuild(s, MissionConfig, "pipe", 5)))
            t.falsy((Rules.canBuild(s, MissionConfig, "farm")))
        end
    )

    t.test(
        "파손: 1~2회는 물을 싣고 돌아오고 느려진다, 주차 자리 수리 [Q30]",
        function()
            local cfg = Bot.withOverrides(MissionConfig, {
                ["MISSIONS.C.rover.risk.low.damageChance"] = 1,
            })
            local s = Rules.newState("C", cfg, 3, nil)
            local _, trip = Rules.dispatchRover(s, cfg, 1, false)
            t.truthy(trip.rover.trip.damageAt ~= nil)
            local keys
            trip, keys = advance(trip, 1, cfg)
            t.truthy(hasKey(keys, "toast.rover.damaged"))
            t.truthy(hasKey(keys, "toast.rover.returned"))
            t.eq(trip.rover.damage, 1)
            local plain = Rules.tripPlan(s, cfg, 4, false)
            local slow = Rules.tripPlan(trip, cfg, 4, false)
            t.truthy(slow.rawDays > plain.rawDays, "파손 1이면 느려진다")
            local ok, fixed, m = Rules.repairRover(trip, cfg)
            t.truthy(ok)
            t.eq(m.key, "toast.rover.repaired")
            t.eq(fixed.rover.damage, 0)
            t.eq(fixed.energy, trip.energy - C.rover.repairEnergy)
        end
    )

    t.test(
        "고장(3회): 지도 위에서 멈추고, 걸어서 수리(물 지킴) 또는 원격 회수(1일, 물 잃음)",
        function()
            local cfg = Bot.withOverrides(MissionConfig, {
                ["MISSIONS.C.rover.risk.high.damageChance"] = 1,
            })
            local s = Rules.newState("C", cfg, 5, nil)
            s.rover.damage = 2
            s.energy = 100
            local _, trip = Rules.dispatchRover(s, cfg, 5, false)
            local at = trip.rover.trip.damageAt :: number
            local keys = {}
            for _ = 1, trip.rover.trip.totalDays do -- 파손 2면 느려져 왕복이 길다
                local k
                trip, k = advance(trip, 1, cfg)
                for _, key in k do
                    table.insert(keys, key)
                end
                if trip.rover.status == "broken" then
                    break
                end
            end
            -- 걷는 거리 = 고장 위치(BaseExit 기준) + 에어록에서 BaseExit까지 176. 한도 704 안이면 broken_walkable
            local offset = MissionConfig.WALK_REPAIR.startOffset
            local walkKey = if trip.rover.brokenDistance + offset <= Rules.walkRepairLimit(cfg)
                then "toast.rover.broken_walkable"
                else "toast.rover.broken_far"
            t.truthy(hasKey(keys, walkKey), walkKey)
            t.eq(trip.rover.status, "broken")
            local expected = s.sites[5].distance * (1 - math.abs(1 - 2 * at))
            t.truthy(
                math.abs(trip.rover.brokenDistance - expected) < 0.01,
                "고장 위치 (소수 둘째 자리 반올림)"
            )
            local blocked = Rules.dispatchRover(trip, cfg, 1, false)
            t.falsy(blocked)
            -- 원격 회수
            local okR, rec, mR = Rules.remoteRecoverRover(trip, cfg)
            t.truthy(okR)
            t.eq(mR.key, "toast.rover.recovering")
            t.eq(rec.rover.status, "fsd")
            t.truthy(rec.rover.recovering)
            local recView = Rules.roverFsdView(rec, cfg)
            t.eq(recView and recView.phase, "return")
            local recKeys
            rec, recKeys = advance(rec, C.rover.remoteRecoverDays, cfg)
            t.truthy(hasKey(recKeys, "toast.rover.recovered"))
            t.eq(rec.rover.status, "parked")
            t.falsy(rec.rover.recovering)
            t.eq(rec.rover.damage, C.rover.maxDamage, "돌아와도 수리는 따로")
            t.eq(rec.deliveries, 0, "물을 잃어 하역 없음")
            local needRepair, _, mN = Rules.dispatchRover(rec, cfg, 1, false)
            t.falsy(needRepair)
            t.eq(mN.key, "toast.rover.need_repair")
            -- 걸어서 수리
            local walkable = Rules.copy(trip)
            walkable.rover.brokenDistance = Rules.walkRepairLimit(cfg) - offset - 1
            t.truthy(Rules.canWalkRepair(walkable, cfg))
            local okW, walked = Rules.walkRepairRover(walkable, cfg)
            t.truthy(okW)
            t.eq(walked.rover.status, "fsd", "남은 왕복을 이어 간다")
            t.eq(walked.rover.damage, 0)
            local far = Rules.copy(trip)
            far.rover.brokenDistance = Rules.walkRepairLimit(cfg) - offset + 1
            local okF, _, mF = Rules.walkRepairRover(far, cfg)
            t.falsy(okF)
            t.eq(mF.key, "toast.rover.too_far_walk")
        end
    )

    t.test(
        "수동 운전 충돌: 파손 +1, maxDamage면 고장, 그 자리 R 수리 [applyRoverHit]",
        function()
            local s = fresh()
            s.energy = 100
            local ok, hit, m = Rules.applyRoverHit(s, MissionConfig)
            t.truthy(ok)
            t.eq(m.key, "toast.rover.damaged")
            t.eq(m.args and m.args.damage, 1)
            t.eq(hit.rover.damage, 1)
            t.eq(hit.stats.damages, 1)
            t.eq(s.rover.damage, 0, "입력 상태는 그대로")
            local ok2, broken, m2 = Rules.applyRoverHit(hit, MissionConfig, { amount = 5 })
            t.truthy(ok2)
            t.eq(m2.key, "toast.rover.broken_manual")
            t.eq(broken.rover.damage, C.rover.maxDamage, "상한에서 멈춘다")
            t.eq(broken.rover.status, "broken")
            t.eq(broken.stats.breakdowns, 1)
            local again, _, m3 = Rules.applyRoverHit(broken, MissionConfig)
            t.falsy(again)
            t.eq(m3.key, "toast.rover.need_repair")
            local fixedOk, fixed = Rules.repairRover(broken, MissionConfig)
            t.truthy(fixedOk, "수동 고장은 그 자리에서 고친다")
            t.eq(fixed.rover.status, "parked")
            t.eq(fixed.rover.damage, 0)
            local _, onTrip = Rules.dispatchRover(fresh(), MissionConfig, 1, false)
            local tripHit, _, m4 = Rules.applyRoverHit(onTrip, MissionConfig)
            t.falsy(tripHit, "자율주행 중에는 받지 않는다")
            t.eq(m4.key, "toast.rover.busy")
        end
    )

    t.test("얼음 후보지 값은 중첩 Msg map.ice.label { n }", function()
        local s = fresh()
        local _, _, m = Rules.dispatchRover(s, MissionConfig, 1, false)
        t.eq(m.key, "toast.rover.dispatched")
        local site = m.args and m.args.site
        t.eq(site and site.key, "map.ice.label")
        t.eq(site and site.args and site.args.n, tonumber(string.match(s.sites[1].id, "%d+")))
    end)

    t.test("걸어서 수리 한도: (60초 x 0.8 - 4초) x 16 = 704 studs [Q37]", function()
        t.eq(Rules.walkRepairLimit(MissionConfig), 704)
    end)

    t.test("실패: 물 0이 4일 연속 [Q3]", function()
        local s = fresh()
        s.water = 0
        local result
        for day = 1, MissionConfig.SHORTAGE_DAYS_TO_LOSE do
            s = advance(s, 1)
            result = Rules.checkEnd(s, MissionConfig)
            if day < MissionConfig.SHORTAGE_DAYS_TO_LOSE then
                t.eq(result.outcome, "none")
            end
        end
        t.eq(result.outcome, "lost")
        t.eq(result.reason, "shortage")
        t.eq(result.resource, "water")
        t.eq(result.msg.key, "end.lost.water")
    end)

    t.test("부족 연속 일수는 회복하면 0으로", function()
        local s = fresh()
        s.water = 0
        s = advance(s, 2)
        t.eq(s.shortageDays, 2)
        s.water = 50
        s = advance(s, 1)
        t.eq(s.shortageDays, 0)
    end)

    t.test("종료: 금메달 조건이면 즉시 완료, 걸린 일수 기록 [Q2]", function()
        local s = fresh()
        for _, id in { "farm", "led", "nutrient", "hydroponics" } do
            s.facilities[id] = {
                id = id,
                defId = id,
                status = "active",
                daysLeft = 0,
                buildDays = 1,
                paused = false,
                progress = 0,
                startedDay = 1,
                completedDay = 1,
            }
        end
        s.day = 21
        local r = Rules.checkEnd(s, MissionConfig)
        t.eq(r.outcome, "won")
        t.eq(r.medal, "gold")
        t.eq(r.daysTaken, 20)
        local done = Rules.finish(s, MissionConfig, r)
        t.eq(done.phase, "won")
        local after = advance(done, 1)
        t.eq(after.day, done.day, "끝난 뒤에는 하루가 흐르지 않는다")
    end)

    t.test("종료: 60일을 마치면 지은 만큼 메달, 없으면 실패", function()
        local s = fresh()
        s.facilities.farm = {
            id = "farm",
            defId = "farm",
            status = "active",
            daysLeft = 0,
            buildDays = 3,
            paused = true, -- 멈춰 있어도 지은 것은 지은 것
            progress = 0,
            startedDay = 1,
            completedDay = 4,
        }
        s.day = 61
        local r = Rules.checkEnd(s, MissionConfig)
        t.eq(r.outcome, "won")
        t.eq(r.medal, "bronze")
        t.eq(r.reason, "timeout")
        t.eq(r.daysTaken, 60)
        local none = fresh()
        none.day = 61
        local r2 = Rules.checkEnd(none, MissionConfig)
        t.eq(r2.outcome, "lost")
        t.eq(r2.reason, "noMedal")
        t.eq(Rules.checkEnd(fresh(), MissionConfig).outcome, "none")
    end)

    t.test(
        "점수: 20 미만 -10, 0이면 -30, 산소 구조 -100, 0점 아래 없음, 사유별 목록 [Q4]",
        function()
            local s = fresh()
            s.energy = 25 -- 하루 끝 13 -> 낮음
            s.food = 2 -- 하루 끝 0 -> 0
            local _, rescued = Rules.recordOxygenRescue(s, MissionConfig)
            rescued = advance(rescued, 1)
            local report = Rules.finalScore(rescued, MissionConfig)
            t.eq(report.start, 1000)
            t.eq(report.score, 1000 - 10 - 30 - 100)
            local reasons = {}
            for _, d in report.deductions do
                table.insert(reasons, d.reason .. ":" .. (d.resource or "-") .. ":" .. d.points)
                t.eq(d.msg.key, "score.deduct." .. d.reason, "자원별 키 (CSV)")
                t.eq(
                    d.msg.args and d.msg.args.points,
                    d.points,
                    "양수 점수, 부호는 템플릿"
                )
                t.eq(d.msg.args and d.msg.args.count, d.count, "복수형 count")
            end
            table.sort(reasons)
            t.eq(
                table.concat(reasons, ","),
                "energy_low:energy:10,food_zero:food:30,oxygen_rescue:-:100"
            )
            local broke = fresh()
            broke.oxygenRescues = 20
            t.eq(Rules.finalScore(broke, MissionConfig).score, 0)
        end
    )

    t.test("결정성: 같은 시드와 같은 행동이면 같은 결과", function()
        local function play(seed: number)
            local r = Bot.simulate(MissionConfig, "human", Bot.weatherFixtures[1], seed)
            return string.format(
                "%s %s %d %d %d",
                r.outcome,
                tostring(r.medal),
                r.daysTaken,
                r.score,
                r.trips
            )
        end
        t.eq(play(11), play(11))
        local cfg = Bot.withOverrides(MissionConfig, {
            ["MISSIONS.C.rover.risk.low.damageChance"] = 0.5,
        })
        local a = Rules.newState("C", cfg, 42, nil)
        local b = Rules.newState("C", cfg, 42, nil)
        local _, ta = Rules.dispatchRover(a, cfg, 1, false)
        local _, tb = Rules.dispatchRover(b, cfg, 1, false)
        t.eq(ta.rover.trip.damageAt, tb.rover.trip.damageAt)
        t.eq(ta.rngState, tb.rngState)
    end)

    t.test("행동은 입력 상태를 바꾸지 않는다", function()
        local s = fresh(1, WINDOW)
        local before = s.energy .. "/" .. s.water .. "/" .. s.panels .. "/" .. s.rover.status
        Rules.installPanel(s, MissionConfig)
        Rules.dispatchRover(s, MissionConfig, 1, false)
        Rules.inspectAirlock(s, MissionConfig)
        Rules.applyDay(s, MissionConfig)
        t.eq(s.energy .. "/" .. s.water .. "/" .. s.panels .. "/" .. s.rover.status, before)
        t.eq(s.day, 1)
    end)

    t.test("출력은 키와 값뿐 (문장 없음, i18n 4.1)", function()
        local seen = 0
        local function scan(s, events)
            for _, e in events do
                checkMsg(t, e, e.key)
                seen += 1
            end
            return s
        end
        local s = fresh(9, WINDOW)
        for day = 1, MissionConfig.TOTAL_DAYS do
            local _, _, m1 = Rules.installPanel(s, MissionConfig)
            checkMsg(t, m1, "installPanel")
            local ok, new, m2 = Rules.inspectAirlock(s, MissionConfig)
            checkMsg(t, m2, "inspectAirlock")
            if ok then
                s = new
            end
            local okF, newF, m3 = Rules.startBuild(s, MissionConfig, "farm")
            checkMsg(t, m3, "startBuild")
            if okF then
                s = newF
            end
            local okD, newD, m4 = Rules.dispatchRover(s, MissionConfig, 1 + day % 5, day % 3 == 0)
            checkMsg(t, m4, "dispatch")
            if okD then
                s = newD
            end
            local events
            s, events = Rules.applyDay(s, MissionConfig)
            scan(s, events)
            local r = Rules.checkEnd(s, MissionConfig)
            if r.msg then
                checkMsg(t, r.msg, "end")
            end
            if r.outcome ~= "none" then
                break
            end
        end
        for _, d in Rules.finalScore(s, MissionConfig).deductions do
            checkMsg(t, d.msg, "deduction")
        end
        t.truthy(seen > 10, "이벤트가 나왔다")
    end)

    t.test("우주 날씨 요약: 구간 id와 사건 수 [Q36]", function()
        local summary = Rules.weatherSummary(fresh(1, WINDOW))
        t.eq(summary.id, "2024-06-21")
        t.eq(summary.sep, 1)
        t.eq(summary.gst, 1)
        local e = summary.endDate
        t.eq(
            e and string.format("%d-%d-%d", e.year, e.month, e.day),
            "2024-8-19",
            "60일째 날짜"
        )
        local leap = Rules.newState("C", MissionConfig, 1, {
            id = "leap",
            startDate = { year = 2024, month = 1, day = 15 },
            events = {},
        })
        local le = Rules.weatherSummary(leap).endDate
        t.eq(
            le and string.format("%d-%d-%d", le.year, le.month, le.day),
            "2024-3-14",
            "윤년 2월 29일"
        )
        local none = Rules.weatherSummary(fresh())
        t.eq(none.id, "none")
        t.eq(none.sep + none.gst, 0)
    end)

    t.test("봇: 완벽 봇은 픽스처 구간 모두에서 금메달", function()
        for _, window in Bot.weatherFixtures do
            for seed = 1, 3 do
                local r = Bot.simulate(MissionConfig, "perfect", window, seed)
                t.eq(r.medal, "gold", window.id .. " seed " .. seed)
            end
        end
    end)

    t.test(
        "봇: 처음 하는 사람의 실패는 60일 무메달이 아니라 물이나 식량 부족 (새 목표)",
        function()
            local medals, lost, shortage = 0, 0, 0
            for seed = 1, 20 do
                local r =
                    Bot.simulate(MissionConfig, "human", Bot.weatherFixtures[1 + seed % 5], seed)
                if r.outcome == "won" then
                    medals += 1
                else
                    lost += 1
                    if r.reason == "shortage" then
                        shortage += 1
                    end
                end
            end
            t.eq(shortage, lost, "실패 사유")
            t.truthy(
                medals >= 4 and lost >= 4,
                "메달과 실패가 모두 나온다: 메달 " .. medals .. "/20"
            )
        end
    )

    t.test(
        "봇: 멀티 2명 팀도 끝까지 돈다 (수동 운전 하역, 파이프 해금)",
        function()
            local delivered = false
            for seed = 1, 6 do
                local r = Bot.simulate(
                    MissionConfig,
                    "multi_second",
                    Bot.weatherFixtures[1 + seed % 5],
                    seed,
                    2
                )
                t.eq(r.players, 2)
                if r.manualTrips >= 5 and r.stats.manualWater > 0 then
                    delivered = true
                end
            end
            t.truthy(delivered, "수동 왕복과 하역")
        end
    )
end
