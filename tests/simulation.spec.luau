-- Simulation 순수 로직 테스트 (GDD 4절 밸런스 검증 메모 포함)

local Config = require("../src/shared/Config")
local Simulation = require("../src/shared/Simulation")

-- 착륙을 마치고 1일차가 시작된 상태
local function playingState(sunlight: number?)
    local s = Simulation.newState(Config)
    s.phase = "playing"
    s.day = 1
    s.siteId = 1
    s.siteName = "Shackleton Rim"
    s.sunlight = sunlight or 1
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

    t.test("패널: 하루 3장 한도, 다음 날 초기화, 전체 30장 한도", function()
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
    end)

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
        -- 유지: A 3E 1W, B 5E 2W, 크루 1W
        t.eq(after.energy, 100 - 3 - 5)
        t.eq(after.water, s.water - 1 - 2 - 1)
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
            t.eq(s.daysLeft.water, 25, "물 100 / (1 + 1 + 2) = 25")
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

    t.test("얼음 매장지 8곳: easy 2, mid 3, hard 3, 합계 390 ~ 400", function()
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
        t.truthy(total >= 390 and total <= 400, "합계 " .. total)
    end)

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
    local TERRAIN_FACTOR = { easy = 1, mid = 0.85, hard = 0.7 }

    -- 착륙 패드 위치 (DevMap과 같은 식: 기준 얼음 + 방향 x 최근접 거리)
    local function padPosition(siteIndex: number): (number, number)
        local layout = Config.DEV_MAP.padLayout[siteIndex]
        local ice = Config.ICE_SITES[layout.ice]
        local distance = Config.DEV_MAP.iceDistanceBySite[siteIndex]
        return ice.x + layout.dirX * distance, ice.z + layout.dirZ * distance
    end

    local function tripDaysTo(siteIndex: number, iceIndex: number): number
        local px, pz = padPosition(siteIndex)
        local ice = Config.ICE_SITES[iceIndex]
        local distance = math.sqrt((ice.x - px) ^ 2 + (ice.z - pz) ^ 2)
        local corridor = Config.DEV_MAP.padLayout[siteIndex].ice == iceIndex
        local factor = if corridor then 1 else TERRAIN_FACTOR[ice.difficulty]
        local seconds = 2 * distance / (Config.ROVER.maxSpeed * factor) + TRIP_OVERHEAD
        return math.max(1, math.ceil(seconds / Config.DAY_SECONDS))
    end

    type BotResult = {
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
        waterNeed: number, -- 건설 물 + 크루와 모듈 유지 물 (승리까지 쓴 물 전체)
        mined: number, -- 매장지에서 캔 물 합계
        tripLog: string, -- 원정 대상 순서 (얼음 번호)
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

    local function simulatePlayer(siteIndex: number, noTrips: boolean?): BotResult
        local s = playingState(Config.SITES[siteIndex].sunlight)
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
                    local days = tripDaysTo(siteIndex, index)
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
        -- 다음 원정 대상: 다녀오는 동안 물이 버티는 매장지 중 하루당 얻는 물(min(탱크 빈 공간, 매장량) / 왕복 일수)이
        -- 가장 많은 곳. 버틸 수 있는 곳이 없으면 가장 가까운 곳
        local function nextTarget(): (number?, number)
            local best, bestDays, bestRate = nil, 0, -1
            local nearest, nearestDays = nil, math.huge
            local space = s.rover.tankMax - s.rover.tank
            for index, amount in deposits do
                if amount > 0 then
                    local days = tripDaysTo(siteIndex, index)
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
                tripLeft -= 1
                busy, onTrip = true, true
                if tripLeft == 0 then
                    arrive()
                end
            else
                unload()
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
                if afterBuild and canStart then
                    local built = afterBuild
                    waterNeed += waterCost
                    s = built
                    busy = true
                    id = nextModule(s)
                elseif
                    not noTrips
                    and target ~= nil
                    and s.rover.tank < s.rover.tankMax
                    and (
                        (not tripped and s.day >= FIRST_TRIP_DAY)
                        or s.water <= reserve
                        or (waterShort and (energyReady or not canInstall))
                    )
                then
                    tripped = true
                    busy, onTrip = true, true
                    tripTarget = target :: number
                    table.insert(log, tostring(tripTarget))
                    tripLeft = days - 1
                    if tripLeft == 0 then
                        arrive()
                    end
                elseif canInstall then
                    s = installMany(s, Config.PANELS_PER_DAY)
                    busy = true
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
            end
            local _, useWater = Simulation.dailyConsumption(s, Config)
            waterNeed += useWater
            s = Simulation.applyDay(s, Config)
            if s.energyWasted > 0 then
                wasteDays += 1
            end
            if s.modules.B.status ~= "active" then
                minFood = math.min(minFood, s.food)
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
                    waterNeed = waterNeed,
                    mined = mined,
                    tripLog = table.concat(log, ","),
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
            waterNeed = waterNeed,
            mined = mined,
            tripLog = table.concat(log, ","),
        }
    end

    local function summary(results: { BotResult }): string
        local parts = {}
        for index, r in results do
            table.insert(
                parts,
                string.format(
                    "%s %s %d일(원정 %d회 [얼음 %s], 에너지 막힘 최대 %d일 합계 %d일, 완전 대기 최대 %d일, Farm 전 최저 식량 %d, 전력 버림 %d일, 일부 처리 하역 %d회, 물 사용 %d W, 채취 %d W)",
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
                    r.waterNeed,
                    r.mined
                )
            )
        end
        return table.concat(parts, "\n        ")
    end

    local results: { BotResult } = {}
    for index in Config.SITES do
        table.insert(results, simulatePlayer(index))
    end

    t.test(
        "현실적 봇: 4곳 모두 승리, 최적 착륙지 45일 이하, 나머지 50일 이하",
        function()
            print(
                "        거리별 원정 일수와 매장량 기준:\n        " .. summary(results)
            )
            local best = math.huge
            for index, r in results do
                t.eq(r.result, "won", Config.SITES[index].name)
                best = math.min(best, r.day)
            end
            t.truthy(best <= 45, "최적 착륙지 승리 일수 " .. best)
            -- 2026-10-18 리드 승인: 나머지 착륙지는 50일(약 8분) 이하까지 허용
            for index, r in results do
                t.truthy(
                    r.day <= 50,
                    Config.SITES[index].name .. " 승리 일수 " .. r.day .. " (50 이하)"
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
    -- 매장량 합계가 가장 많이 쓴 착륙지의 1.4배 이상이어야 늦게 가는 팀도 물이 남는다
    t.test("매장량 합계 >= 승리에 필요한 물 x 1.4 (봇 실측)", function()
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
                "        매장량 합계 %d W, 최대 필요량 %d W (x 1.4 = %.0f)",
                total,
                need,
                need * 1.4
            )
        )
        t.truthy(total >= need * 1.4, string.format("합계 %d < %d x 1.4", total, need))
        t.truthy(total >= 390 and total <= 400, "매장량 합계 390 ~ 400: " .. total)
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
end
