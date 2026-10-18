-- Simulation 순수 로직 테스트 (GDD 4절 밸런스 검증 메모 포함)

local Bot = require("./bot")
local Config = require("../src/shared/Config")
local Simulation = require("../src/shared/Simulation")

type BotResult = Bot.BotResult

-- 착륙을 마치고 1일차가 시작된 상태
local function playingState(sunlight: number?)
    local s = Simulation.newState(Config)
    s.phase = "playing"
    s.day = 1
    s.siteId = 1
    s.siteName = "Shackleton Rim"
    s.sunlight = sunlight or 1
    s.eventSchedule = {} -- 랜덤 이벤트는 이벤트 테스트가 직접 넣는다 (기존 테스트는 이벤트 없이)
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

local function moduleState(status, progress: number, daysLeft: number)
    return {
        status = status,
        progress = progress,
        daysLeft = daysLeft,
        unlocked = true,
        shortfall = { energy = 0, water = 0 },
    }
end

local function setActive(state, id: string)
    state.modules[id] = moduleState("active", 1, 0)
end

return function(t)
    t.test("초기 상태: selecting, 시작 자원, A만 착공 가능", function()
        local s = Simulation.newState(Config)
        t.eq(s.phase, "selecting")
        t.eq(s.day, 0)
        t.eq(s.energy, Config.START.energy)
        t.eq(s.water, Config.START.water)
        t.eq(s.food, Config.START.food)
        t.eq(s.modules.A.status, "available")
        t.eq(s.modules.B.status, "locked")
        t.eq(s.modules.C.status, "locked")
        t.eq(s.rover.tankMax, Config.ROVER.tankMax)
        t.eq(s.totalDays, Config.TOTAL_DAYS)
        t.eq(s.missionText, Config.MISSION_TEXTS.selecting)
    end)

    -- 기대값은 Config에서 계산한다. 현재 값(시작 50, 하루 3장, 장당 1)이면 53, 59, 68, 80, 95, 113
    t.test(
        "100% 일조 워크스루: 매일 패널을 한도까지 설치하면 에너지가 삼각수로 늘어난다",
        function()
            local perPanel = Config.PANEL_OUTPUT
            local perDay = Config.PANELS_PER_DAY
            local s = playingState(1)
            for day = 1, 6 do
                s = installMany(s, perDay)
                s = Simulation.applyDay(s, Config)
                local expected = Config.START.energy + perPanel * perDay * day * (day + 1) / 2
                t.near(s.energy, expected, "day " .. day .. " energy")
            end
            do
                t.eq(s.day, 7)
                t.near(s.netEnergy, perPanel * perDay * 6, "6일차 순증감")
                t.near(s.water, 19, "물 25 - 6")
                t.near(s.food, Config.START.food - 6, "시작 식량 - 6")
                t.near(s.netWater, -1)
                t.near(s.netFood, -1)
                t.eq(s.panelsInstalled, perDay * 6)
            end
        end
    )

    t.test("6일차: 에너지는 충분하지만 물 19 < 20이라 A 착공 불가", function()
        local s = playingState(1)
        for _ = 1, 6 do
            s = installMany(s, Config.PANELS_PER_DAY)
            s = Simulation.applyDay(s, Config)
        end
        local ok, reason = Simulation.canBuild(s, Config, "A")
        t.falsy(ok)
        t.contains(reason, "자원이 부족합니다")
        t.contains(reason, "Water 20")
        t.falsy(string.find(reason, "Energy", 1, true), "에너지는 부족하지 않음")
    end)

    t.test("일조율 0.85: 패널 3장 하루 발전 2.55, 부동소수 오차 없음", function()
        local s = installMany(playingState(0.85), 3)
        s.energy = 0
        s = Simulation.applyDay(s, Config)
        t.eq(s.energy, 2.55)
        t.eq(s.netEnergy, 2.55)
    end)

    t.test(
        "패널: 하루 한도, 다음 날 초기화, 전체 한도 (Config.PANELS_TOTAL)",
        function()
            local s = installMany(playingState(1), 3)
            local ok, _, reason = Simulation.installPanel(s, Config)
            t.falsy(ok)
            t.eq(reason, Config.TEXTS.panelLimit)
            s = Simulation.applyDay(s, Config)
            t.eq(s.panelsInstalledToday, 0)
            local ok2 = Simulation.installPanel(s, Config)
            t.truthy(ok2)
            s.panelsInstalled = Config.PANELS_TOTAL
            local ok3, _, reason3 = Simulation.installPanel(s, Config)
            t.falsy(ok3)
            t.eq(reason3, Config.TEXTS.panelsFull)
        end
    )

    t.test("Farm은 에너지가 0이면 생산하지 않는다", function()
        local s = playingState(1)
        setActive(s, "A")
        setActive(s, "B")
        s.energy = 0
        s.panelsInstalled = 0
        local _, _, food = Simulation.dailyProduction(s, Config)
        t.eq(food, 0)
        local after = Simulation.applyDay(s, Config)
        t.eq(after.food, s.food - Config.CREW.food)
        t.truthy(after.modulesStalled)
    end)

    t.test("Farm은 에너지와 물이 있으면 하루 +2 (순증 +1)", function()
        local s = playingState(1)
        setActive(s, "A")
        setActive(s, "B")
        s.energy = 100
        local after = Simulation.applyDay(s, Config)
        t.eq(after.food, s.food + Config.MODULES.B.foodPerDay - Config.CREW.food)
        t.eq(after.netFood, 1)
        t.falsy(after.modulesStalled)
        -- 유지: A, B 에너지와 물, 크루 물 (수치는 Config)
        local A, B = Config.MODULES.A.upkeep, Config.MODULES.B.upkeep
        t.eq(after.energy, 100 - A.energy - B.energy)
        t.eq(after.water, s.water - A.water - B.water - Config.CREW.water)
    end)

    t.test("Farm은 그날 물 수요를 못 채우면 생산하지 않는다", function()
        local s = playingState(1)
        setActive(s, "A")
        setActive(s, "B")
        s.energy = 100
        s.water = 2 -- 필요 4 (크루 1 + A 1 + B 2)
        local _, _, food = Simulation.dailyProduction(s, Config)
        t.eq(food, 0)
        local after = Simulation.applyDay(s, Config)
        t.eq(after.water, 0)
        t.eq(after.shortageDays, 1)
    end)

    t.test(
        "모듈 정지 규칙: 에너지가 0 아래로 가면 모듈 유지 소비 없음",
        function()
            local s = playingState(1)
            setActive(s, "A")
            s.energy = 1
            s.panelsInstalled = 1 -- 생산 1, 유지 3 -> 1 + 1 - 3 < 0
            t.truthy(Simulation.isStalled(s, Config))
            local e, w, f = Simulation.dailyConsumption(s, Config)
            t.eq(e, 0)
            t.eq(w, Config.CREW.water)
            t.eq(f, Config.CREW.food)
            local after = Simulation.applyDay(s, Config)
            t.eq(after.energy, 2, "정지 날에는 생산만 쌓인다")
            t.eq(after.water, s.water - Config.CREW.water)
            t.truthy(after.modulesStalled)
            -- 다음 날은 2 + 1 - 3 = 0 이므로 정지 아님
            local next = Simulation.applyDay(after, Config)
            t.falsy(next.modulesStalled)
            t.eq(next.energy, 0)
        end
    )

    t.test("자원은 0 아래로 내려가지 않는다", function()
        local s = playingState(1)
        s.water = 0.5
        s.food = 0
        local after = Simulation.applyDay(s, Config)
        t.eq(after.water, 0)
        t.eq(after.food, 0)
    end)

    t.test(
        "건설: 비용 즉시 차감, buildDays 틱 뒤 가동, 다음 모듈 해금",
        function()
            local s = playingState(1)
            s.energy = 100
            s.water = 50
            local ok, built, message = Simulation.startBuild(s, Config, "A")
            t.truthy(ok)
            t.contains(message, "Habitat A")
            t.eq(built.energy, 40)
            t.eq(built.water, 30)
            t.eq(built.modules.A.status, "building")
            t.eq(built.modules.A.daysLeft, Config.MODULES.A.buildDays)
            local cur = built
            for i = 1, Config.MODULES.A.buildDays - 1 do
                cur = Simulation.applyDay(cur, Config)
                t.eq(cur.modules.A.status, "building", "tick " .. i)
                t.near(cur.modules.A.progress, i / Config.MODULES.A.buildDays)
            end
            t.eq(cur.modules.A.daysLeft, 1)
            t.eq(cur.modules.B.status, "locked")
            cur = Simulation.applyDay(cur, Config)
            t.eq(cur.modules.A.status, "active")
            t.eq(cur.modules.A.daysLeft, 0)
            t.eq(cur.modules.B.status, "available")
            t.eq(cur.modules.C.status, "locked")
        end
    )

    t.test("건설 중에는 유지 소비가 없다", function()
        local s = playingState(1)
        s.energy = 100
        s.water = 50
        local _, built = Simulation.startBuild(s, Config, "A")
        local after = Simulation.applyDay(built, Config)
        t.eq(after.energy, built.energy)
        t.eq(after.water, built.water - Config.CREW.water)
    end)

    t.test("canBuild: A 전에 B 착공 불가 (한국어 사유)", function()
        local s = playingState(1)
        s.energy = 1000
        s.water = 1000
        local ok, reason = Simulation.canBuild(s, Config, "B")
        t.falsy(ok)
        t.contains(reason, "Habitat A")
        t.contains(reason, "완공이 필요합니다")
        local okC, reasonC = Simulation.canBuild(s, Config, "C")
        t.falsy(okC)
        t.contains(reasonC, "Habitat A")
        t.contains(reasonC, "Farm B")
    end)

    t.test("canBuild: 자원 부족 시 한국어 사유와 필요량", function()
        local s = playingState(1)
        s.energy = 10
        s.water = 5
        local ok, reason = Simulation.canBuild(s, Config, "A")
        t.falsy(ok)
        t.eq(reason, "자원이 부족합니다: Energy 60, Water 20 필요")
    end)

    t.test("canBuild: 건설 중, 완공, 비진행 단계, 잘못된 id 거부", function()
        local s = playingState(1)
        s.energy = 1000
        s.water = 1000
        local _, built = Simulation.startBuild(s, Config, "A")
        local ok1, r1 = Simulation.canBuild(built, Config, "A")
        t.falsy(ok1)
        t.eq(r1, Config.TEXTS.alreadyBuilding)
        setActive(s, "A")
        local ok2, r2 = Simulation.canBuild(s, Config, "A")
        t.falsy(ok2)
        t.eq(r2, Config.TEXTS.alreadyActive)
        local sel = Simulation.newState(Config)
        local ok3, r3 = Simulation.canBuild(sel, Config, "A")
        t.falsy(ok3)
        t.eq(r3, Config.TEXTS.notPlaying)
        local ok4, r4 = Simulation.canBuild(s, Config, "Z")
        t.falsy(ok4)
        t.eq(r4, Config.TEXTS.unknownModule)
    end)

    t.test("부족 3일 연속이면 실패, 중간에 회복하면 초기화", function()
        local s = playingState(1)
        s.water = 0
        for day = 1, 2 do
            s = Simulation.applyDay(s, Config)
            t.eq(s.shortageDays, day)
            local result = Simulation.checkEnd(s, Config)
            t.eq(result, "none")
        end
        local recovered = Simulation.copy(s)
        recovered.water = 10
        recovered = Simulation.applyDay(recovered, Config)
        t.eq(recovered.shortageDays, 0)

        s = Simulation.applyDay(s, Config)
        t.eq(s.shortageDays, Config.SHORTAGE_DAYS_TO_LOSE)
        local result, reason = Simulation.checkEnd(s, Config)
        t.eq(result, "lost")
        t.eq(reason, "물이 3일 연속 바닥났습니다")
    end)

    t.test("식량 부족 실패 사유", function()
        local s = playingState(1)
        s.food = 0
        s.shortageDays = 2
        s = Simulation.applyDay(s, Config)
        local result, reason = Simulation.checkEnd(s, Config)
        t.eq(result, "lost")
        t.contains(reason, "식량이")
    end)

    t.test("C 완공 즉시 승리", function()
        local s = playingState(1)
        setActive(s, "A")
        setActive(s, "B")
        s.energy = 500
        s.water = 100
        s.modules.C = moduleState("building", 6 / 7, 1)
        t.eq((Simulation.checkEnd(s, Config)), "none")
        s = Simulation.applyDay(s, Config)
        t.eq(s.modules.C.status, "active")
        local result, reason = Simulation.checkEnd(s, Config)
        t.eq(result, "won")
        t.eq(reason, Config.TEXTS.endWon)
        local finished = Simulation.finishGame(s, Config, result)
        t.eq(finished.phase, "won")
        t.eq(finished.day, 1, "1일차를 끝내고 승리")
        t.eq(finished.missionText, Config.MISSION_TEXTS.won)
    end)

    t.test("90일 안에 C 미완공이면 실패", function()
        local s = playingState(1)
        s.water = 1000
        s.food = 1000
        s.day = Config.TOTAL_DAYS
        t.eq((Simulation.checkEnd(s, Config)), "none")
        s = Simulation.applyDay(s, Config)
        local result, reason = Simulation.checkEnd(s, Config)
        t.eq(result, "lost")
        t.eq(reason, "90일 안에 완공하지 못했습니다")
        local finished = Simulation.finishGame(s, Config, result)
        t.eq(finished.day, Config.TOTAL_DAYS)
    end)

    t.test("applyDay는 입력 상태를 바꾸지 않는다", function()
        local s = installMany(playingState(1), 3)
        s.energy = 50
        setActive(s, "A")
        local before = Simulation.copy(s)
        local after = Simulation.applyDay(s, Config)
        t.eq(s.energy, before.energy)
        t.eq(s.day, before.day)
        t.eq(s.modules.A.status, "active")
        t.eq(s.panelsInstalledToday, before.panelsInstalledToday)
        t.truthy(after ~= s)
        t.truthy(after.modules ~= s.modules)
        t.truthy(after.rover ~= s.rover)
    end)

    t.test("playing이 아니면 applyDay는 아무 것도 하지 않는다", function()
        local s = Simulation.newState(Config)
        local after = Simulation.applyDay(s, Config)
        t.eq(after.day, 0)
        t.eq(after.water, s.water)
    end)

    t.test("로버: 만충, 하역 시 물과 원정 횟수 증가, 빈 탱크 거부", function()
        local s = playingState(1)
        local okEmpty, _, reasonEmpty = Simulation.unloadWater(s, Config)
        t.falsy(okEmpty)
        t.eq(reasonEmpty, Config.TEXTS.tankEmpty)
        local okFill, filled = Simulation.fillTank(s, Config)
        t.truthy(okFill)
        t.eq(filled.rover.tank, Config.ROVER.tankMax)
        local okFull, _, reasonFull = Simulation.fillTank(filled, Config)
        t.falsy(okFull)
        t.eq(reasonFull, Config.TEXTS.tankAlreadyFull)
        local okUnload, unloaded, message = Simulation.unloadWater(filled, Config)
        t.truthy(okUnload)
        t.eq(unloaded.water, s.water + Config.ROVER.tankMax)
        t.eq(unloaded.rover.tank, 0)
        t.eq(unloaded.waterTrips, 1)
        t.contains(message, Config.ROVER.tankMax .. "W")
        t.near(
            unloaded.energy,
            s.energy - Config.ROVER.tankMax * Config.WATER_PROCESS_ENERGY_PER_W,
            "하역한 물 1 W당 전력 0.5"
        )
    end)

    t.test("산소 고갈 페널티: Food -1, Water -2, 0 클램프", function()
        local s = playingState(1)
        local after = Simulation.applyOxygenDeath(s, Config)
        t.eq(after.food, s.food - 1)
        t.eq(after.water, s.water - 2)
        t.eq(after.oxygenDeaths, 1)
        s.water = 1
        s.food = 0
        local clamped = Simulation.applyOxygenDeath(s, Config)
        t.eq(clamped.water, 0)
        t.eq(clamped.food, 0)
    end)

    t.test(
        "같은 틱에 부족 실패와 C 완공이 겹치면 실패가 먼저 (리뷰 I06)",
        function()
            local s = playingState(1)
            setActive(s, "A")
            setActive(s, "B")
            s.energy = 500
            s.water = 0
            s.food = 100
            s.shortageDays = Config.SHORTAGE_DAYS_TO_LOSE - 1
            s.modules.C = moduleState("building", 6 / 7, 1)
            s = Simulation.applyDay(s, Config)
            t.eq(s.modules.C.status, "active", "C는 이 틱에 완공")
            t.eq(s.shortageDays, Config.SHORTAGE_DAYS_TO_LOSE, "물 부족 3일째")
            local result, reason = Simulation.checkEnd(s, Config)
            t.eq(result, "lost")
            t.contains(reason, "물이")
        end
    )

    t.test("미션 단계: 날짜가 지나도 패널 3장 전에는 panels 유지", function()
        local s = installMany(playingState(1), 1)
        t.eq(s.missionStage, "panels")
        t.contains(s.missionText, "패널 2장")
        s = Simulation.applyDay(s, Config)
        s = Simulation.applyDay(s, Config)
        t.eq(s.missionStage, "panels", "날짜 기준 전이 없음")
        t.contains(s.missionText, "패널 2장")
    end)

    t.test(
        "미션 단계가 행동 완료로 넘어가고 문구는 단계에서 파생된다",
        function()
            local s = playingState(1)
            t.eq(s.missionStage, "panels")
            t.eq(s.missionText, "솔라 필드에서 패널 3장을 설치하세요")
            s = installMany(s, 3)
            t.eq(s.missionStage, "board_rover", "패널 3장이면 탑승")
            t.eq(s.missionText, Config.MISSION_TEXTS.boardRover)
            s = Simulation.markBoarded(s, Config)
            t.eq(s.missionStage, "find_ice", "탑승하면 얼음 찾기")
            t.eq(s.missionText, Config.MISSION_TEXTS.findIce)
            local again = Simulation.markBoarded(s, Config)
            t.eq(again.missionStage, "find_ice", "다시 타도 그대로")
            local _, filled = Simulation.fillTank(s, Config)
            t.eq(filled.missionStage, "unload", "만충이면 하역")
            t.eq(filled.missionText, Config.MISSION_TEXTS.unloadWater)
            -- 하역 전에 탱크를 잃으면(로버 복구) 다시 얼음 찾기
            local lost = Simulation.copy(filled)
            lost.rover.tank = 0
            Simulation.refreshDerived(lost, Config)
            t.eq(lost.missionStage, "find_ice", "탱크를 잃으면 얼음 찾기로")
            local _, unloaded = Simulation.unloadWater(filled, Config)
            t.eq(unloaded.missionStage, "build_A", "하역하면 A 착공")
            t.eq(unloaded.missionText, "Habitat A를 착공하세요 (Energy 60, Water 20 필요)")
            unloaded.energy = 100
            local _, building = Simulation.startBuild(unloaded, Config, "A")
            t.eq(building.missionStage, "build_B", "A 착공하면 build_B")
            t.contains(building.missionText, "Habitat A 건설 중: 5일 남음")
            local withA = Simulation.copy(building)
            setActive(withA, "A")
            withA.modules.B.status = "available"
            Simulation.refreshDerived(withA, Config)
            t.eq(withA.missionStage, "build_B")
            t.eq(withA.missionText, "Farm B를 착공하세요 (Energy 80, Water 30 필요)")
            setActive(withA, "B")
            withA.modules.C.status = "available"
            Simulation.refreshDerived(withA, Config)
            t.eq(withA.missionStage, "build_C", "B 완공하면 build_C")
            setActive(withA, "C")
            Simulation.refreshDerived(withA, Config)
            t.eq(withA.missionStage, "done", "C 완공하면 done")
            local dry = Simulation.copy(building)
            dry.water = 0
            Simulation.refreshDerived(dry, Config)
            t.contains(dry.missionText, "물이 바닥났습니다")
            t.eq(dry.missionStage, "build_B", "부족 경고 중에도 단계는 그대로")
        end
    )

    t.test("미션 단계: 순서를 건너뛴 행동은 앞으로만 반영", function()
        local s = installMany(playingState(1), 1)
        s = Simulation.markBoarded(s, Config)
        t.eq(s.missionStage, "find_ice", "패널 전에 탑승해도 얼음 찾기로")
        local fresh = playingState(1)
        local _, filled = Simulation.fillTank(fresh, Config)
        t.eq(filled.missionStage, "unload", "바로 만충하면 하역")
        local back = installMany(filled, 3)
        t.eq(back.missionStage, "unload", "되돌아가지 않음")
    end)

    t.test(
        "daysLeft: 보유량 / 하루 순소비, 내림 정수, 순소비 0 이하면 999",
        function()
            local s = playingState(1)
            t.eq(s.daysLeft.water, 25, "물 25, 크루 1/일")
            t.eq(s.daysLeft.food, Config.START.food, "시작 식량, 크루 1/일")
            setActive(s, "A")
            s.water = 25
            Simulation.refreshDerived(s, Config)
            t.eq(s.daysLeft.water, 12, "물 25 / (크루 1 + A 1) = 12.5 -> 12")
            setActive(s, "B")
            s.energy = 500
            s.water = 100
            Simulation.refreshDerived(s, Config)
            t.eq(s.daysLeft.food, 999, "Farm이 식량 +2, 크루 -1이면 줄지 않음")
            local farmUse = Config.CREW.water
                + Config.MODULES.A.upkeep.water
                + Config.MODULES.B.upkeep.water
            t.eq(s.daysLeft.water, math.floor(100 / farmUse), "물 100 / (크루 + A + B 유지)")
            s.water = 0
            Simulation.refreshDerived(s, Config)
            t.eq(s.daysLeft.water, 0)
        end
    )

    t.test("stallReason: 전력 부족 정지면 사유 문구, 아니면 빈 문자열", function()
        local s = playingState(1)
        t.eq(s.stallReason, "")
        setActive(s, "A")
        s.energy = 0
        s = Simulation.applyDay(s, Config)
        t.truthy(s.modulesStalled)
        t.eq(s.stallReason, Config.TEXTS.stallReason)
        t.eq(
            s.stallReason,
            "전력 부족으로 시설이 멈췄습니다. 패널을 더 설치하세요"
        )
    end)

    t.test("모듈 unlocked와 shortfall", function()
        local s = playingState(1)
        t.truthy(s.modules.A.unlocked, "A는 선행 조건 없음")
        t.falsy(s.modules.B.unlocked, "B는 A 완공 전 잠김")
        t.eq(s.modules.A.shortfall.energy, 10, "A 에너지 60 - 보유 50")
        t.eq(s.modules.A.shortfall.water, 0, "A 물 20 <= 보유 25")
        t.eq(s.modules.B.shortfall.energy, 30, "잠긴 모듈도 부족량은 계산")
        t.eq(s.modules.B.shortfall.water, 5)
        s.energy = 100
        local _, building = Simulation.startBuild(s, Config, "A")
        t.eq(building.modules.A.shortfall.energy, 0, "착공한 모듈은 0")
        t.eq(building.modules.A.status, "building", "status 의미 유지")
        local withA = Simulation.copy(building)
        setActive(withA, "A")
        Simulation.refreshDerived(withA, Config)
        t.truthy(withA.modules.B.unlocked, "A 완공 뒤 B 해금")
    end)

    -- 얼음 매장량, 물 처리 전력, 저장 상한, 로버 파손 (2026-10-18) -------------------------------

    t.test(
        "fillFromDeposit: 탱크 빈 공간과 매장량 중 작은 만큼 채우고 매장량을 줄인다",
        function()
            local s = playingState(1)
            local ok, filled, remaining, message, kind = Simulation.fillFromDeposit(s, Config, 15)
            t.truthy(ok)
            t.eq(filled.rover.tank, 15, "매장량 15 < 빈 공간 40")
            t.eq(remaining, 0)
            t.eq(message, string.format(Config.TEXTS.iceExtracted, 15, 0))
            t.eq(kind, "good")
            t.eq(
                filled.missionStage,
                "unload",
                "물을 실으면 예전 만충과 같이 하역 단계"
            )
            local max = Config.ROVER.tankMax
            local ok2, topped, left2 = Simulation.fillFromDeposit(filled, Config, 100)
            t.truthy(ok2)
            t.eq(topped.rover.tank, max, "빈 공간만 채움")
            t.eq(left2, 100 - (max - 15), "매장량 100 - 빈 공간")
            local ok3, _, left3, message3, kind3 = Simulation.fillFromDeposit(topped, Config, 25)
            t.falsy(ok3)
            t.eq(left3, 25, "가득 차 있으면 매장량 그대로")
            t.eq(message3, Config.TEXTS.tankAlreadyFull)
            t.eq(kind3, "info")
            local ok4, _, left4, message4 = Simulation.fillFromDeposit(s, Config, 0)
            t.falsy(ok4)
            t.eq(left4, 0)
            t.eq(message4, Config.TEXTS.iceDepleted)
            local selecting = Simulation.newState(Config)
            t.falsy(
                (Simulation.fillFromDeposit(selecting, Config, 30)),
                "playing이 아니면 거부"
            )
        end
    )

    t.test("물을 조금이라도 실으면 단계 unload (만충이 아니어도)", function()
        local s = installMany(playingState(1), 3)
        s = Simulation.markBoarded(s, Config)
        local _, filled = Simulation.fillFromDeposit(s, Config, 15)
        t.eq(filled.missionStage, "unload")
    end)

    t.test("하역: 물 1 W당 전력 0.5, 모자라면 처리 가능한 만큼만", function()
        local s = playingState(1)
        s.rover.tank = 30
        s.energy = 50
        local ok, full, message, kind, warning = Simulation.unloadWater(s, Config)
        t.truthy(ok)
        t.eq(full.water, s.water + 30)
        t.near(full.energy, 50 - 30 * Config.WATER_PROCESS_ENERGY_PER_W)
        t.eq(full.rover.tank, 0)
        t.eq(full.waterTrips, 1)
        t.eq(message, string.format(Config.TEXTS.waterUnloaded, 30))
        t.eq(kind, "good")
        t.eq(warning, nil, "전부 처리하면 경고 없음")
        s.energy = 7.9 -- floor(7.9 / 0.5) = 15
        local okP, partial, _, _, warningP = Simulation.unloadWater(s, Config)
        t.truthy(okP)
        t.eq(partial.water, s.water + 15)
        t.eq(partial.rover.tank, 15, "나머지는 탱크에 남는다")
        t.near(partial.energy, 0.4)
        t.eq(warningP, string.format(Config.TEXTS.waterPartial, 15))
        s.energy = 0.4
        local okZ, zero, messageZ, kindZ = Simulation.unloadWater(s, Config)
        t.falsy(okZ, "0.5 미만이면 1 W도 처리 못 함")
        t.eq(zero.rover.tank, 30)
        t.eq(kindZ, "warn")
        t.contains(messageZ, "전력이 부족해")
    end)

    t.test(
        "에너지 저장 상한: 150 + 가동 모듈 x 100, 넘친 발전은 버린다",
        function()
            local s = playingState(1)
            t.eq(s.energyCap, Config.ENERGY_CAP_BASE)
            s = installMany(s, 3)
            s.energy = Config.ENERGY_CAP_BASE - 1
            local next1 = Simulation.applyDay(s, Config)
            t.eq(next1.energy, Config.ENERGY_CAP_BASE, "상한에서 멈춤")
            t.near(next1.energyWasted, 2, "149 + 3 - 150")
            t.eq(next1.netEnergy, 1)
            local next2 = Simulation.applyDay(next1, Config)
            t.near(next2.energyWasted, 3)
            local withA = Simulation.copy(s)
            setActive(withA, "A")
            Simulation.refreshDerived(withA, Config)
            t.eq(withA.energyCap, Config.ENERGY_CAP_BASE + Config.ENERGY_CAP_PER_MODULE)
            withA.energy = 10
            local next3 = Simulation.applyDay(withA, Config)
            t.eq(next3.energyWasted, 0, "상한 아래면 0")
        end
    )

    t.test("완공한 날부터 늘어난 상한을 쓴다", function()
        local s = installMany(playingState(1), 3)
        s.modules.A = moduleState("building", 0.8, 1)
        s.energy = Config.ENERGY_CAP_BASE
        local done = Simulation.applyDay(s, Config)
        t.eq(done.modules.A.status, "active")
        t.eq(done.energyCap, Config.ENERGY_CAP_BASE + Config.ENERGY_CAP_PER_MODULE)
        t.eq(done.energy, Config.ENERGY_CAP_BASE + 3, "완공 당일 발전은 버려지지 않음")
        t.eq(done.energyWasted, 0)
    end)

    t.test(
        "로버 파손: 1당 속도 10% 감소, 3이면 고장(0), 수리는 전력 10",
        function()
            local d = Config.ROVER_DAMAGE
            t.eq(Simulation.roverSpeedMultiplier(0, Config), 1)
            t.near(Simulation.roverSpeedMultiplier(1, Config), 0.9)
            t.near(Simulation.roverSpeedMultiplier(2, Config), 0.8)
            -- 파손 2의 최고 속도도 임계값 이상이라 평지에서 세 번째 파손이 가능하다
            t.truthy(
                Config.ROVER.maxSpeed * Simulation.roverSpeedMultiplier(2, Config)
                    >= Config.ROVER_DAMAGE.speedThreshold,
                "파손 2 최고 속도 >= 임계값"
            )
            t.eq(Simulation.roverSpeedMultiplier(3, Config), 0)
            local s = playingState(1)
            local hit1, changed1 = Simulation.applyRoverHit(s, Config)
            t.truthy(changed1)
            t.eq(hit1.rover.damage, 1)
            t.falsy(hit1.rover.broken)
            local hit3 = Simulation.applyRoverHit(Simulation.applyRoverHit(hit1, Config), Config)
            t.eq(hit3.rover.damage, d.maxDamage)
            t.truthy(hit3.rover.broken)
            t.eq(hit3.missionText, string.format(Config.MISSION_TEXTS.roverBroken, d.repairEnergy))
            local _, changed4 = Simulation.applyRoverHit(hit3, Config)
            t.falsy(changed4, "3을 넘지 않음")
            hit3.energy = d.repairEnergy - 1
            local okLow, _, messageLow, kindLow = Simulation.repairRover(hit3, Config)
            t.falsy(okLow)
            t.eq(messageLow, string.format(Config.TEXTS.repairNeedEnergy, d.repairEnergy))
            t.eq(kindLow, "warn")
            hit3.energy = 30
            local ok, fixed, message, kind = Simulation.repairRover(hit3, Config)
            t.truthy(ok)
            t.eq(fixed.rover.damage, 0)
            t.falsy(fixed.rover.broken)
            t.eq(fixed.energy, 30 - d.repairEnergy)
            t.eq(message, Config.TEXTS.repairDone)
            t.eq(kind, "good")
            t.truthy(
                fixed.missionText ~= hit3.missionText,
                "수리하면 고장 문구가 사라짐"
            )
            t.falsy((Simulation.repairRover(fixed, Config)), "멀쩡하면 수리 거부")
        end
    )

    t.test("얼음 매장지 8곳: easy 2, mid 3, hard 3, 합계 510 ~ 520", function()
        local counts = { easy = 0, mid = 0, hard = 0 }
        local total = 0
        for _, site in Config.ICE_SITES do
            counts[site.difficulty] += 1
            total += site.deposit
        end
        t.eq(#Config.ICE_SITES, 8)
        t.eq(counts.easy, 2)
        t.eq(counts.mid, 3)
        t.eq(counts.hard, 3)
        t.truthy(total >= 510 and total <= 520, "합계 " .. total)
    end)

    t.test(
        "로버 배터리: 주행 소모, 충전은 빈 용량과 기지 에너지 중 작은 만큼",
        function()
            local rv = Config.ROVER
            local s = playingState(1)
            t.eq(s.rover.battery, rv.batteryMax, "시작 만충")
            t.eq(s.rover.batteryMax, rv.batteryMax)
            t.falsy(s.rover.charging)
            local drained, emptied = Simulation.drainBattery(s, Config, 10)
            t.near(drained.rover.battery, rv.batteryMax - rv.batteryDrainPerSecond * 10)
            t.falsy(emptied)
            local dead, emptied2 = Simulation.drainBattery(drained, Config, 1000)
            t.eq(dead.rover.battery, 0)
            t.truthy(emptied2, "이번에 0이 되면 true")
            local _, again = Simulation.drainBattery(dead, Config, 1)
            t.falsy(again, "이미 0이면 다시 true가 아님")
            t.eq(dead.missionText, Config.MISSION_TEXTS.batteryEmpty, "방전 미션 문구")
            dead.energy = 100
            local charged, amount = Simulation.chargeBattery(dead, Config, 1)
            t.near(amount, rv.chargeRatePerSecond)
            t.near(charged.rover.battery, rv.chargeRatePerSecond)
            t.near(charged.energy, 100 - rv.chargeRatePerSecond, "기지 에너지에서 1:1")
            dead.energy = 1.5
            local poor, amount2 = Simulation.chargeBattery(dead, Config, 10)
            t.near(amount2, 1.5, "기지 에너지 잔량까지만")
            t.eq(poor.energy, 0)
            local nearFull = Simulation.copy(s)
            nearFull.rover.battery = rv.batteryMax - 0.5
            nearFull.energy = 100
            local full, amount3 = Simulation.chargeBattery(nearFull, Config, 10)
            t.near(amount3, 0.5, "빈 용량까지만")
            t.eq(full.rover.battery, rv.batteryMax)
        end
    )

    t.test(
        "배터리 부족 미션: 기지 밖에서 25% 이하일 때만, 방전은 어디서나",
        function()
            local rv = Config.ROVER
            local s = playingState(1)
            s.rover.battery = rv.batteryMax * rv.lowBatteryRatio
            Simulation.refreshDerived(s, Config)
            t.truthy(Simulation.batteryLow(s, Config))
            t.truthy(
                s.missionText ~= Config.MISSION_TEXTS.batteryLow,
                "기지 안이면 단계 문구"
            )
            s.rover.away = true
            Simulation.refreshDerived(s, Config)
            t.eq(s.missionText, Config.MISSION_TEXTS.batteryLow)
            s.rover.battery = rv.batteryMax * rv.lowBatteryRatio + 1
            Simulation.refreshDerived(s, Config)
            t.truthy(
                s.missionText ~= Config.MISSION_TEXTS.batteryLow,
                "25%보다 많으면 단계 문구"
            )
        end
    )

    t.test(
        "Farm 가동 중지: 유지비와 생산 모두 0, daysLeft 반영, C 해금과 저장 상한은 그대로",
        function()
            local s = installMany(playingState(1), 3)
            setActive(s, "A")
            setActive(s, "B")
            s.energy = 100
            s.water = 60
            local okPause, paused, message = Simulation.setPaused(s, Config, "B", true)
            t.truthy(okPause)
            t.truthy(paused.modules.B.paused)
            t.eq(message, string.format(Config.TEXTS.modulePaused, "Farm"))
            t.eq(paused.modules.B.upkeepText, Config.TEXTS.upkeepPaused, "대기 중")
            local A = Config.MODULES.A
            local after = Simulation.applyDay(paused, Config)
            t.near(after.energy, 100 + 3 - A.upkeep.energy, "Farm 전력 유지 없음")
            t.eq(after.water, 60 - Config.CREW.water - A.upkeep.water, "Farm 물 유지 없음")
            t.eq(after.food, paused.food - Config.CREW.food, "Farm 식량 생산 없음")
            t.eq(
                paused.daysLeft.water,
                math.floor(60 / (Config.CREW.water + A.upkeep.water)),
                "daysLeft는 Farm 물 유지를 빼고 계산"
            )
            t.truthy(paused.modules.C.unlocked, "B가 멈춰도 C 선행 조건 충족")
            t.eq(
                after.modules.C.status,
                "available",
                "멈춘 Farm으로도 하루가 지나면 C 착공 가능"
            )
            t.eq(
                paused.energyCap,
                Config.ENERGY_CAP_BASE + 2 * Config.ENERGY_CAP_PER_MODULE,
                "저장 상한은 완공 수 기준"
            )
            local okResume, resumed, message2 = Simulation.setPaused(paused, Config, "B", false)
            t.truthy(okResume)
            t.falsy(resumed.modules.B.paused)
            t.eq(message2, string.format(Config.TEXTS.moduleResumed, "Farm"))
            local B = Config.MODULES.B
            t.eq(
                resumed.modules.B.upkeepText,
                string.format(
                    "물 -%d/일, 전력 -%d/일, 식량 +%d/일",
                    B.upkeep.water,
                    B.upkeep.energy,
                    B.foodPerDay
                )
            )
            t.falsy((Simulation.setPaused(s, Config, "A", true)), "Habitat A는 멈출 수 없음")
            local building = Simulation.copy(s)
            building.modules.B = moduleState("building", 0.2, 4)
            t.falsy(
                (Simulation.setPaused(building, Config, "B", true)),
                "건설 중에는 멈출 수 없음"
            )
        end
    )

    t.test(
        "로버 부스터: 배터리 20% 이상, 과열 4초에 꺼지고 6초 동안 식는다",
        function()
            local rv = Config.ROVER
            local s = playingState(1)
            t.truthy(Simulation.canBoost(s, Config, false))
            t.falsy(Simulation.canBoost(s, Config, true), "과열 중 거부")
            local low = Simulation.copy(s)
            low.rover.battery = rv.batteryMax * rv.boostMinBatteryRatio - 0.01
            t.falsy(Simulation.canBoost(low, Config, false), "배터리 부족 거부")
            s.rover.boosting = true
            local heated, over = Simulation.boostTick(s, Config, rv.boostMaxSeconds / 2)
            t.near(heated.rover.boostHeat, 0.5)
            t.falsy(over)
            t.truthy(heated.rover.boosting)
            local hot, over2 = Simulation.boostTick(heated, Config, rv.boostMaxSeconds / 2)
            t.eq(hot.rover.boostHeat, 1)
            t.truthy(over2, "1에 닿으면 과열")
            t.falsy(hot.rover.boosting, "과열이면 꺼짐")
            local cooled = Simulation.boostTick(hot, Config, rv.boostCooldownSeconds / 2)
            t.near(cooled.rover.boostHeat, 0.5)
            local cold = Simulation.boostTick(cooled, Config, rv.boostCooldownSeconds)
            t.eq(cold.rover.boostHeat, 0, "0 아래로 내려가지 않음")
        end
    )

    t.test(
        "finishGame: 하루 도중 실패(산소 고갈)는 지금 날짜로 끝낸다",
        function()
            local s = playingState(1)
            s.day = 12
            t.eq(Simulation.finishGame(s, Config, "lost").day, 11, "DayTick 실패는 끝낸 날")
            local mid = Simulation.finishGame(s, Config, "lost", true)
            t.eq(mid.day, 12, "하루 도중이면 그날")
            t.eq(mid.phase, "lost")
            t.eq(
                mid.oxygenDeaths,
                s.oxygenDeaths,
                "산소 고갈 실패는 통계를 바꾸지 않음"
            )
        end
    )

    -- 랜덤 이벤트 (2026-10-18 15차) ---------------------------------------
    local EV = Config.EVENTS
    local function stormEntry(day: number)
        return {
            kind = "solarStorm",
            day = day,
            duration = EV.solarStorm.durationDays,
            warningDays = EV.solarStorm.warningDays,
            roll = 0,
            resolved = false,
            target = "",
        }
    end
    local function meteorEntry(day: number, roll: number)
        return {
            kind = "micrometeoroid",
            day = day,
            duration = EV.micrometeoroid.bannerDays,
            warningDays = 0,
            roll = roll,
            resolved = false,
            target = "",
        }
    end
    local function withSchedule(state, schedule)
        state.eventSchedule = schedule
        Simulation.refreshDerived(state, Config)
        return state
    end
    local function stepTo(state, day: number)
        local s = state
        while s.day < day do
            s = Simulation.applyDay(s, Config)
        end
        return s
    end

    t.test(
        "이벤트 일정: 같은 시드면 같은 일정, 시드가 다르면 달라진다",
        function()
            local a = Simulation.makeEventSchedule(Config, 12345)
            local b = Simulation.makeEventSchedule(Config, 12345)
            t.eq(#a, #b)
            for i, entry in a do
                t.eq(entry.kind, b[i].kind)
                t.eq(entry.day, b[i].day)
                t.eq(entry.roll, b[i].roll)
            end
            local stormDays = {}
            for seed = 1, 50 do
                for _, entry in Simulation.makeEventSchedule(Config, seed * 7919) do
                    if entry.kind == "solarStorm" then
                        stormDays[entry.day] = true
                    end
                end
            end
            local distinct = 0
            for _ in stormDays do
                distinct += 1
            end
            t.truthy(distinct >= 10, "시드 50개의 폭풍 날짜 종류 " .. distinct)
            -- newState(seed)도 같은 일정
            local s1 = Simulation.newState(Config, 777)
            local s2 = Simulation.newState(Config, 777)
            t.eq(#s1.eventSchedule, #s2.eventSchedule)
            t.eq(s1.eventSchedule[1].day, s2.eventSchedule[1].day)
        end
    )

    t.test(
        "이벤트 일정 제약: 폭풍 1회 [30, 50], 운석 1~2회 [15, 80], 10일 간격, 폭풍과 겹치지 않음",
        function()
            local counts = { [1] = 0, [2] = 0 }
            for seed = 1, 400 do
                local schedule = Simulation.makeEventSchedule(Config, seed)
                local storms, meteors = {}, {}
                for _, entry in schedule do
                    if entry.kind == "solarStorm" then
                        table.insert(storms, entry)
                    else
                        table.insert(meteors, entry)
                    end
                end
                t.eq(#storms, 1, "폭풍 수 (시드 " .. seed .. ")")
                local storm = storms[1]
                t.truthy(
                    storm.day >= EV.solarStorm.startDayMin
                        and storm.day <= EV.solarStorm.startDayMax,
                    "폭풍 날짜 " .. storm.day
                )
                t.truthy(
                    #meteors >= EV.micrometeoroid.countMin
                        and #meteors <= EV.micrometeoroid.countMax,
                    "운석 수 " .. #meteors
                )
                counts[#meteors] = (counts[#meteors] or 0) + 1
                local stormFrom = storm.day - storm.warningDays
                local stormTo = storm.day + storm.duration - 1
                for i, m in meteors do
                    t.truthy(
                        m.day >= EV.micrometeoroid.dayMin and m.day <= EV.micrometeoroid.dayMax,
                        "운석 날짜 " .. m.day
                    )
                    t.truthy(m.roll >= 0 and m.roll < 1, "roll 범위")
                    local bannerTo = m.day + m.duration - 1
                    t.truthy(
                        bannerTo < stormFrom or m.day > stormTo,
                        string.format(
                            "운석 %d와 폭풍 %d 겹침 (시드 %d)",
                            m.day,
                            storm.day,
                            seed
                        )
                    )
                    for j, other in meteors do
                        if i ~= j then
                            t.truthy(
                                math.abs(m.day - other.day) >= EV.micrometeoroid.minGapDays,
                                "운석 간격"
                            )
                        end
                    end
                end
                for i = 2, #schedule do
                    t.truthy(schedule[i - 1].day <= schedule[i].day, "날짜 순 정렬")
                end
            end
            t.truthy(counts[1] > 0 and counts[2] > 0, "1회와 2회가 모두 나온다")
        end
    )

    t.test("EVENTS.enabled = false면 일정도 효과도 배너도 없다", function()
        EV.enabled = false
        local ok, err = pcall(function()
            t.eq(#Simulation.makeEventSchedule(Config, 99), 0, "빈 일정")
            t.eq(#Simulation.newState(Config, 99).eventSchedule, 0, "newState 빈 일정")
            -- 일정이 들어 있어도 꺼져 있으면 무시
            local s = installMany(playingState(1), 3)
            setActive(s, "A")
            s = withSchedule(s, { stormEntry(3), meteorEntry(2, 0.5) })
            s = stepTo(s, 3)
            t.falsy(s.modules.A.damaged, "운석 없음")
            t.eq(s.event, nil, "배너 없음")
            t.falsy(Simulation.stormActive(s, Config), "폭풍 없음")
            local energy = Simulation.dailyProduction(s, Config)
            t.near(energy, 3, "발전 그대로")
            t.eq(Simulation.outdoorOxygenMultiplier(s, Config), 1)
        end)
        EV.enabled = true
        if not ok then
            error(err, 0)
        end
    end)

    t.test(
        "태양 입자 폭풍: 예고 D-2, 진행 2일 동안 발전 절반과 실외 산소 1.5배, 끝나면 원래대로",
        function()
            local S = 10
            local s = withSchedule(installMany(playingState(1), 3), { stormEntry(S) })
            s.panelsInstalled = 10
            s = stepTo(s, S - 3)
            t.eq(s.event, nil, "예고 전")
            s = stepTo(s, S - 2)
            t.eq(s.event.kind, "solarStorm")
            t.eq(s.event.stage, "warning")
            t.eq(s.event.daysLeft, 2)
            t.eq(s.event.text, string.format(Config.TEXTS.stormBannerWarning, 2))
            t.eq(s.event.eduText, Config.TEXTS.stormEdu)
            t.near(Simulation.dailyProduction(s, Config), 10, "예고 중 발전 그대로")
            s = stepTo(s, S)
            t.eq(s.event.stage, "active")
            t.eq(s.event.text, string.format(Config.TEXTS.stormBannerActive, 2))
            t.near(
                Simulation.dailyProduction(s, Config),
                10 * EV.solarStorm.panelMultiplier,
                "발전 절반"
            )
            t.eq(
                Simulation.outdoorOxygenMultiplier(s, Config),
                EV.solarStorm.outdoorOxygenMultiplier
            )
            local before = s.energy
            s = Simulation.applyDay(s, Config)
            t.near(s.energy - before, 5, "폭풍 날 순증 +5")
            t.eq(s.event.daysLeft, 1, "남은 1일")
            s = stepTo(s, S + EV.solarStorm.durationDays)
            t.eq(s.event, nil, "폭풍 끝")
            t.near(Simulation.dailyProduction(s, Config), 10, "발전 회복")
            t.eq(Simulation.outdoorOxygenMultiplier(s, Config), 1)
        end
    )

    t.test(
        "미세운석: 가동 모듈 외벽 손상, 생산 정지, 유지비 계속, 수리하면 재개",
        function()
            local s = installMany(playingState(1), 3)
            setActive(s, "A")
            setActive(s, "B")
            s.energy, s.water, s.food = 100, 100, 20
            s = withSchedule(s, { meteorEntry(2, 0.99) })
            s = stepTo(s, 2)
            t.truthy(s.modules.B.damaged, "roll 0.99면 뒤쪽 후보 Farm B")
            t.falsy(s.modules.A.damaged)
            t.eq(s.eventSchedule[1].target, "B")
            t.eq(s.event.kind, "micrometeoroid")
            t.eq(s.event.text, string.format(Config.TEXTS.meteorBannerModule, "Farm B"))
            t.eq(s.event.eduText, Config.TEXTS.meteorEdu)
            local meteor = EV.micrometeoroid
            t.eq(
                s.modules.B.upkeepText,
                string.format(Config.TEXTS.upkeepDamaged, meteor.repairKey, meteor.repairEnergy)
            )
            local _, _, food = Simulation.dailyProduction(s, Config)
            t.eq(food, 0, "손상된 Farm은 식량 0")
            local useEnergy, useWater = Simulation.dailyConsumption(s, Config)
            t.eq(
                useEnergy,
                Config.MODULES.A.upkeep.energy + Config.MODULES.B.upkeep.energy,
                "유지 전력 계속"
            )
            t.eq(
                useWater,
                Config.CREW.water + Config.MODULES.A.upkeep.water + Config.MODULES.B.upkeep.water
            )
            -- 가동 중지와 달리 손상은 다음 날에도 그대로
            s = Simulation.applyDay(s, Config)
            t.truthy(s.modules.B.damaged, "수리 전까지 유지")
            -- 수리: 전력 부족이면 거절
            local poor = Simulation.copy(s)
            poor.energy = meteor.repairEnergy - 1
            local okPoor, _, msgPoor, kindPoor = Simulation.repairModule(poor, Config, "B")
            t.falsy(okPoor)
            t.eq(msgPoor, string.format(Config.TEXTS.repairNeedEnergy, meteor.repairEnergy))
            t.eq(kindPoor, "warn")
            local okNo, _, msgNo = Simulation.repairModule(s, Config, "A")
            t.falsy(okNo, "멀쩡한 모듈은 수리 안 함")
            t.eq(msgNo, Config.TEXTS.moduleRepairNotNeeded)
            local okFix, fixed, msgFix, kindFix = Simulation.repairModule(s, Config, "B")
            t.truthy(okFix)
            t.eq(kindFix, "good")
            t.eq(msgFix, string.format(Config.TEXTS.moduleRepaired, "Farm B"))
            t.falsy(fixed.modules.B.damaged)
            t.near(fixed.energy, s.energy - meteor.repairEnergy, "전력 10")
            local _, _, foodAfter = Simulation.dailyProduction(fixed, Config)
            t.eq(foodAfter, Config.MODULES.B.foodPerDay, "생산 재개")
        end
    )

    t.test(
        "미세운석 대상: 손상 모듈과 승리 모듈은 빼고, 없으면 패널, 패널도 0이면 빗나감",
        function()
            -- A 손상, B 가동 -> 두 번째 운석은 B
            local s = installMany(playingState(1), 3)
            setActive(s, "A")
            setActive(s, "B")
            s.modules.A.damaged = true
            s.energy, s.water, s.food = 100, 100, 50
            s = withSchedule(s, { meteorEntry(2, 0.0) })
            s = stepTo(s, 2)
            t.truthy(s.modules.B.damaged, "남은 후보 B")
            -- 가동 모듈 없음 -> 패널 1장
            local p = withSchedule(
                installMany(playingState(1), 2),
                { meteorEntry(2, 0.5), meteorEntry(3, 0.5), meteorEntry(4, 0.5) }
            )
            p = stepTo(p, 2)
            t.eq(p.panelsInstalled, 1, "패널 2 -> 1")
            t.eq(p.eventSchedule[1].target, "panel")
            t.eq(p.event.text, Config.TEXTS.meteorBannerPanel)
            p = stepTo(p, 3)
            t.eq(p.panelsInstalled, 0, "1 -> 0")
            p = stepTo(p, 4)
            t.eq(p.panelsInstalled, 0, "0 아래로 내려가지 않음")
            t.eq(p.eventSchedule[3].target, "none")
            t.eq(p.event.text, Config.TEXTS.meteorBannerMiss)
            -- 부서진 슬롯은 다시 설치할 수 있다
            local ok = Simulation.installPanel(p, Config)
            t.truthy(ok, "다시 설치")
        end
    )

    t.test(
        "이벤트 알림: 폭풍 예고, 시작, 끝, 운석 충돌 토스트를 한 번씩",
        function()
            local S = 8
            local s = installMany(playingState(1), 3)
            setActive(s, "A")
            s.energy, s.water, s.food = 100, 100, 50
            s = withSchedule(s, { meteorEntry(3, 0.5), stormEntry(S) })
            local seen = {}
            while s.day < S + EV.solarStorm.durationDays + 1 do
                local new = Simulation.applyDay(s, Config)
                for _, notice in Simulation.eventNotices(s, new, Config) do
                    table.insert(seen, { day = new.day, text = notice.text, kind = notice.kind })
                end
                s = new
            end
            local meteor = EV.micrometeoroid
            local expected = {
                {
                    3,
                    string.format(
                        Config.TEXTS.meteorModule,
                        "Habitat A",
                        meteor.repairKey,
                        meteor.repairEnergy
                    ),
                    "warn",
                },
                { S - 2, string.format(Config.TEXTS.stormWarning, 2), "warn" },
                { S, string.format(Config.TEXTS.stormStart, EV.solarStorm.durationDays), "warn" },
                { S + 2, Config.TEXTS.stormEnd, "good" },
            }
            t.eq(#seen, #expected, "알림 수")
            for i, e in expected do
                t.eq(seen[i].day, e[1], "알림 날 " .. i)
                t.eq(seen[i].text, e[2])
                t.eq(seen[i].kind, e[3])
            end
        end
    )

    -- 현실적 플레이어 봇: tests/bot.luau (2026-10-18 15차에 옮김. 규칙 설명도 그 파일 머리에)
    local simulatePlayer = Bot.simulatePlayer
    local summary = Bot.summary

    local results: { BotResult } = {}
    for index in Config.SITES do
        table.insert(results, simulatePlayer(index))
    end

    t.test(
        "현실적 봇: 4곳 모두 승리, 최적 착륙지 55 ~ 75일, 나머지 85일 이하",
        function()
            print(
                "        거리별 원정 일수와 매장량 기준:\n        " .. summary(results)
            )
            local best = math.huge
            for index, r in results do
                t.eq(r.result, "won", Config.SITES[index].name)
                best = math.min(best, r.day)
            end
            t.truthy(
                best >= 55 and best <= 75,
                "최적 착륙지 승리 일수 " .. best .. " (55 ~ 75)"
            )
            -- 2026-10-18 사용자 피드백(너무 쉽다) 반영 목표: 나머지 85일 이하, 최악도 90일 안
            for index, r in results do
                t.truthy(
                    r.day <= 85,
                    Config.SITES[index].name .. " 승리 일수 " .. r.day .. " (85 이하)"
                )
            end
        end
    )

    t.test(
        "현실적 봇: C 완공 전까지 에너지 때문에 막힌 날이 연속 5일을 넘지 않는다",
        function()
            for index, r in results do
                t.truthy(
                    r.maxBlocked <= 5,
                    Config.SITES[index].name .. " 최대 " .. r.maxBlocked .. "일"
                )
            end
        end
    )

    -- START.food 35 (2026-10-18 사용자 결정): 산소 고갈이나 캐릭터 초기화(식량 -1)를 5번 겪어도
    -- Farm 전에 바닥나지 않는 여유를 요구한다
    t.test("현실적 봇: Farm 가동 전 식량 여유 5 이상", function()
        for index, r in results do
            t.truthy(r.minFood >= 5, Config.SITES[index].name .. " 최저 식량 " .. r.minFood)
        end
    end)

    t.test("현실적 봇: 물 원정을 안 하면 실패", function()
        for index, site in Config.SITES do
            local r = simulatePlayer(index, true)
            t.eq(r.result, "lost", site.name)
        end
    end)

    -- 승리에 필요한 물 = 건설 물 + 크루와 모듈 유지 물 (봇이 승리까지 실제로 쓴 양).
    -- 매장량 합계가 가장 많이 쓴 착륙지의 1.3배 이상이어야 늦게 가는 팀도 물이 남는다
    t.test("매장량 합계 >= 승리에 필요한 물 x 1.3 (봇 실측)", function()
        local total = 0
        for _, site in Config.ICE_SITES do
            total += site.deposit
        end
        local need = 0
        for _, r in results do
            need = math.max(need, r.waterNeed)
        end
        print(
            string.format(
                "        매장량 합계 %d W, 최대 필요량 %d W (x 1.3 = %.0f)",
                total,
                need,
                need * 1.3
            )
        )
        t.truthy(total >= need * 1.3, string.format("합계 %d < %d x 1.3", total, need))
        t.truthy(total >= 510 and total <= 520, "매장량 합계 510 ~ 520: " .. total)
    end)

    t.test(
        "현실적 봇: 첫 매장지만으로는 이길 수 없어 mid나 hard로 간다",
        function()
            for index, r in results do
                local farther = false
                for _, token in string.split(r.tripLog, ",") do
                    local ice = Config.ICE_SITES[tonumber(token) :: number]
                    if
                        ice
                        and ice.difficulty ~= "easy"
                        and tonumber(token) ~= Config.DEV_MAP.padLayout[index].ice
                    then
                        farther = true
                    end
                end
                t.truthy(farther, Config.SITES[index].name .. " 원정 " .. r.tripLog)
            end
        end
    )

    -- 랜덤 이벤트 밸런스 (2026-10-18 15차): 같은 봇에 이벤트 일정을 넣는다.
    -- 봇의 폭풍 대응: 진행 중에는 착공과 패널 설치를 하지 않고(로버 원정과 건물 앞 4초 수리는 한다), 손상은 다음 기회에 수리
    local function farmFirst(siteIndex: number, schedule)
        return simulatePlayer(siteIndex, false, { schedule = schedule })
    end

    t.test(
        "이벤트 봇: 시드 일정 25개씩, 4곳 모두 90일 안에 승리, Farm 전 식량 5 이상",
        function()
            local lines = {}
            for index, site in Config.SITES do
                local worst, total = 0, 0
                for seed = 1, 25 do
                    local r =
                        farmFirst(index, Simulation.makeEventSchedule(Config, seed * 104729 + 17))
                    t.eq(r.result, "won", site.name .. " 시드 " .. seed)
                    t.truthy(r.minFood >= 5, site.name .. " 최저 식량 " .. r.minFood)
                    worst = math.max(worst, r.day)
                    total += r.day
                end
                table.insert(
                    lines,
                    string.format("%s 평균 %.1f일, 최악 %d일", site.name, total / 25, worst)
                )
            end
            print("        " .. table.concat(lines, "\n        "))
        end
    )

    t.test("이벤트 봇: 폭풍이 30 ~ 50일 어느 날에 와도 4곳 모두 승리", function()
        for index, site in Config.SITES do
            local worst, worstDay = 0, 0
            for day = EV.solarStorm.startDayMin, EV.solarStorm.startDayMax do
                local r = farmFirst(index, { stormEntry(day) })
                t.eq(r.result, "won", site.name .. " 폭풍 " .. day .. "일")
                if r.day > worst then
                    worst, worstDay = r.day, day
                end
            end
            print(
                string.format(
                    "        %s 폭풍 최악 %d일 (폭풍 %d일 시작)",
                    site.name,
                    worst,
                    worstDay
                )
            )
        end
    end)

    t.test(
        "이벤트 봇 최악: 폭풍이 Farm 완공 직후, 운석 두 번이 모두 Farm(10일 간격), 이른 운석이 패널 파괴",
        function()
            for index, site in Config.SITES do
                local farmDay = simulatePlayer(index).farmDay
                t.truthy(farmDay > 0, site.name .. " Farm 완공일")
                local stormDay =
                    math.clamp(farmDay + 1, EV.solarStorm.startDayMin, EV.solarStorm.startDayMax)
                local afterFarm = farmFirst(index, { stormEntry(stormDay) })
                t.eq(afterFarm.result, "won", site.name .. " Farm 직후 폭풍 " .. stormDay)
                -- 운석 두 번: Farm 완공 다음 날과 10일 뒤, roll 0.99(뒤쪽 후보 = Farm), 폭풍은 가장 늦은 날
                local m1 = farmDay + 1
                local m2 = m1 + EV.micrometeoroid.minGapDays
                local twice = farmFirst(index, {
                    meteorEntry(m1, 0.99),
                    meteorEntry(m2, 0.99),
                    stormEntry(EV.solarStorm.startDayMax),
                })
                t.eq(twice.result, "won", site.name .. " 운석 두 번 Farm")
                t.eq(twice.repairs, 2, site.name .. " 수리 두 번")
                -- 생성기 범위(15일~)보다 이른 10일 운석: 모듈이 없어 패널 1장 파괴, 다시 깔아야 한다
                local panel = farmFirst(index, { meteorEntry(10, 0.5) })
                t.eq(panel.result, "won", site.name .. " 패널 파괴")
                t.eq(panel.panelsLost, 1, site.name .. " 부서진 패널")
                print(
                    string.format(
                        "        %s Farm %d일: 직후 폭풍 %d일 승리, 운석 2회 Farm %d일 승리, 패널 파괴 %d일 승리",
                        site.name,
                        farmDay,
                        afterFarm.day,
                        twice.day,
                        panel.day
                    )
                )
            end
        end
    )

    t.test(
        "이벤트 봇: 15차 최악 격자에서 지던 운석 시점도 공정성 규칙으로 버틴다",
        function()
            -- 규칙 전 패배: de Gerlache 운석 32, 42일 / Nobile 35, 45일 (둘 다 Farm, roll 0.99)
            local cases = { { 2, 32, 42 }, { 4, 35, 45 }, { 4, 35, 47 }, { 4, 36, 46 } }
            local outcomes = {}
            for _, c in cases do
                local r = farmFirst(c[1], { meteorEntry(c[2], 0.99), meteorEntry(c[3], 0.99) })
                local name = Config.SITES[c[1]].name
                t.eq(r.result, "won", string.format("%s 운석 %d, %d일", name, c[2], c[3]))
                table.insert(outcomes, string.format("%s %d,%d -> %d일", name, c[2], c[3], r.day))
            end
            print("        " .. table.concat(outcomes, ", "))
        end
    )

    t.test(
        "운석 공정성: 가동 첫날부터 유예 기간 안 모듈은 맞지 않는다",
        function()
            local grace = EV.micrometeoroid.graceDaysAfterActivation
            local s = installMany(playingState(1), 3)
            s.energy, s.water, s.food = 500, 500, 50
            setActive(s, "A")
            s.modules.A.activatedDay = 1
            s.modules.B = moduleState("building", 0.8, 1)
            s.modules.B.damaged = false
            -- B는 2일에 가동 시작. 유예 마지막 날(2 + grace - 1)과 그다음 날에 운석
            local lastGraceDay = 2 + grace - 1
            s = withSchedule(s, { meteorEntry(lastGraceDay, 0.99) })
            s = stepTo(s, 2)
            t.eq(s.modules.B.status, "active")
            t.eq(s.modules.B.activatedDay, 2, "가동 첫날 기록")
            t.eq(Simulation.copy(s).modules.B.activatedDay, 2, "copy가 activatedDay를 유지")
            s = stepTo(s, lastGraceDay)
            t.falsy(s.modules.B.damaged, "유예 기간 안 Farm은 후보에서 빠짐")
            t.truthy(s.modules.A.damaged, "남은 후보 A가 맞음")
            -- 유예가 끝난 다음 날이면 B도 후보
            local later = installMany(playingState(1), 3)
            later.energy, later.water, later.food = 500, 500, 50
            setActive(later, "A")
            setActive(later, "B")
            later.modules.A.activatedDay = 1
            later.modules.B.activatedDay = 2
            later = withSchedule(later, { meteorEntry(2 + grace, 0.99) })
            later = stepTo(later, 2 + grace)
            t.truthy(later.modules.B.damaged, "유예가 끝나면 Farm도 맞을 수 있다")
        end
    )

    t.test(
        "운석 공정성: 직전 운석이 때린 모듈은 다음 운석에서 빠지고, 후보가 없으면 패널",
        function()
            local s = installMany(playingState(1), 3)
            s.energy, s.water, s.food = 500, 500, 50
            setActive(s, "A")
            setActive(s, "B")
            s = withSchedule(
                s,
                { meteorEntry(2, 0.99), meteorEntry(4, 0.99), meteorEntry(6, 0.99) }
            )
            s = stepTo(s, 2)
            t.truthy(s.modules.B.damaged, "첫 운석 B")
            local fixed = select(2, Simulation.repairModule(s, Config, "B"))
            fixed = stepTo(fixed, 4)
            t.falsy(
                fixed.modules.B.damaged,
                "수리했어도 직전 대상 B는 연속으로 맞지 않음"
            )
            t.truthy(fixed.modules.A.damaged, "두 번째 운석은 A")
            t.eq(fixed.eventSchedule[2].target, "A")
            -- 세 번째: A는 손상 중이고 직전 대상, B만 남는다
            fixed = stepTo(fixed, 6)
            t.truthy(fixed.modules.B.damaged, "세 번째 운석은 다시 B (직전 대상은 A)")

            -- 가동 모듈이 B 하나뿐이고 직전 대상이 B면 패널 1장
            local only = installMany(playingState(1), 3)
            only.energy, only.water, only.food = 500, 500, 50
            setActive(only, "B")
            only = withSchedule(only, { meteorEntry(2, 0.5), meteorEntry(3, 0.5) })
            only = stepTo(only, 2)
            only = select(2, Simulation.repairModule(only, Config, "B"))
            local panels = only.panelsInstalled
            only = stepTo(only, 3)
            t.falsy(only.modules.B.damaged, "직전 대상이라 B 제외")
            t.eq(only.panelsInstalled, panels - 1, "후보가 없으면 패널 파괴")
            t.eq(only.eventSchedule[2].target, "panel")
        end
    )
end
