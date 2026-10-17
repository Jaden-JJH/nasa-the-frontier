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
        t.contains(message, "40W")
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

    -- 현실적 플레이어 봇 (GDD 4절 밸런스 검증 메모) ----------------------------
    -- 하루에 한 가지 행동만 한다. 우선순위:
    --   1) 다음 모듈을 지을 수 있고 착공 뒤에도 원정 동안 버틸 물이 남으면 착공
    --   2) 미션대로 둘째 날 첫 물 원정 (패널 설치 다음 미션)
    --   3) 물이 원정 동안 버틸 만큼만 남았으면 원정
    --   4) 에너지는 충분한데 물이 모자라거나, 깔 패널이 없는데 물이 모자라면 원정
    --   5) 패널을 하루 한도까지 설치
    --   6) 할 일이 없으면 대기
    -- 원정은 TRIP_DAYS일 동안 다른 행동을 못 하고, 마지막 날 탱크를 채워 하역한다.
    -- "원정 동안 버틸 물" = max(WATER_FLOOR, 하루 물 소비 x 원정 일수). 리드가 정한 "물 10 이하" 기준에
    -- 소비량을 더한 것으로, 이것이 없으면 B 가동 뒤(하루 4W) 6일 원정 중에 물이 바닥나 봇이 진다.
    local TRIP_DAYS = 6 -- 왕복 약 60초 (GDD 4절)
    local FIRST_TRIP_DAY = 2
    local WATER_FLOOR = 10
    -- 참고용 추정: 얼음 거리(450, 300, 180, 100 studs)를 로버 18 studs/s로 왕복하고 채우기와 하역에 약 10초
    local TRIP_DAYS_BY_DISTANCE = { 6, 5, 3, 3 }

    type BotResult = {
        result: string,
        day: number,
        aOnReturn: boolean,
        maxBlocked: number, -- 에너지 막힘 최대 연속일 (다음 모듈이 열려 있고 물도 충분한데 에너지가 모자란 기지 체류일)
        maxIdle: number, -- 완전 대기 최대 연속일 (아무 행동도 못 한 날)
        minFood: number, -- Farm 가동 전 최저 식량
        trips: number,
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

    local function waterReserve(s, tripDays: number): number
        local _, use = Simulation.dailyConsumption(s, Config)
        return math.max(WATER_FLOOR, use * tripDays)
    end

    local function fetchWater(s)
        local _, filled = Simulation.fillTank(s, Config)
        local _, unloaded = Simulation.unloadWater(filled, Config)
        return unloaded
    end

    local function simulatePlayer(sunlight: number, tripDays: number, noTrips: boolean?): BotResult
        local s = playingState(sunlight)
        local tripLeft = 0
        local tripped, checkedReturn = false, false
        local aOnReturn = false
        local blocked, maxBlocked, idle, maxIdle = 0, 0, 0, 0
        local minFood = math.huge
        for _ = 1, Config.TOTAL_DAYS + 1 do
            local busy = false -- 오늘 행동을 했는지
            local onTrip = false
            local id = nextModule(s)
            if tripLeft > 0 then
                tripLeft -= 1
                busy, onTrip = true, true
                if tripLeft == 0 then
                    s = fetchWater(s)
                end
            else
                if tripped and not checkedReturn then
                    checkedReturn = true
                    aOnReturn = (Simulation.canBuild(s, Config, "A"))
                end
                local reserve = waterReserve(s, tripDays)
                local waterCost = if id then Config.MODULES[id].cost.water else 0
                local canInstall = s.panelsInstalled < Config.PANELS_TOTAL
                local waterShort = id ~= nil and s.water < waterCost + reserve
                local energyReady = id ~= nil and s.energy >= Config.MODULES[id].cost.energy
                if
                    id
                    and (Simulation.canBuild(s, Config, id))
                    and s.water - waterCost >= reserve
                then
                    local _, built = Simulation.startBuild(s, Config, id)
                    s = built
                    busy = true
                    id = nextModule(s)
                elseif
                    not noTrips
                    and (
                        (not tripped and s.day >= FIRST_TRIP_DAY)
                        or s.water <= reserve
                        or (waterShort and (energyReady or not canInstall))
                    )
                then
                    tripped = true
                    busy, onTrip = true, true
                    tripLeft = tripDays - 1
                    if tripLeft == 0 then
                        s = fetchWater(s)
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
                and s.water >= def.cost.water + waterReserve(s, tripDays)
                and s.energy < def.cost.energy
            if isBlocked then
                blocked += 1
                maxBlocked = math.max(maxBlocked, blocked)
            else
                blocked = 0
            end
            if s.modules.B.status ~= "active" then
                minFood = math.min(minFood, s.food)
            end
            s = Simulation.applyDay(s, Config)
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
                    maxIdle = maxIdle,
                    minFood = minFood,
                    trips = s.waterTrips,
                }
            end
        end
        return {
            result = "none",
            day = s.day,
            aOnReturn = aOnReturn,
            maxBlocked = maxBlocked,
            maxIdle = maxIdle,
            minFood = minFood,
            trips = s.waterTrips,
        }
    end

    local function runAllSites(tripDaysFor: (number) -> number): { BotResult }
        local results = {}
        for index, site in Config.SITES do
            table.insert(results, simulatePlayer(site.sunlight, tripDaysFor(index)))
        end
        return results
    end

    local function summary(results: { BotResult }): string
        local parts = {}
        for index, r in results do
            table.insert(
                parts,
                string.format(
                    "%s %s %d일(원정 %d회, 에너지 막힘 최대 %d일, 완전 대기 최대 %d일, Farm 전 최저 식량 %d)",
                    Config.SITES[index].name,
                    if r.result == "won" then "승리" else r.result,
                    r.day,
                    r.trips,
                    r.maxBlocked,
                    r.maxIdle,
                    r.minFood
                )
            )
        end
        return table.concat(parts, "\n        ")
    end

    local flat = runAllSites(function()
        return TRIP_DAYS
    end)

    t.test(
        "현실적 봇: 4곳 모두 90일 안에 승리, 최적 착륙지는 35~45일",
        function()
            local best = math.huge
            for index, r in flat do
                t.eq(r.result, "won", Config.SITES[index].name)
                best = math.min(best, r.day)
            end
            t.truthy(best >= 35 and best <= 45, "최적 착륙지 승리 일수 " .. best)
            print("        원정 6일 기준:\n        " .. summary(flat))
            local estimated = runAllSites(function(index)
                return TRIP_DAYS_BY_DISTANCE[index]
            end)
            print(
                "        참고, 얼음 거리별 원정 일수(6, 5, 3, 3일):\n        "
                    .. summary(estimated)
            )
        end
    )

    t.test(
        "현실적 봇: 첫 물 원정에서 돌아오면 Habitat A를 바로 착공할 수 있다",
        function()
            for index, r in flat do
                t.truthy(r.aOnReturn, Config.SITES[index].name)
            end
        end
    )

    t.test(
        "현실적 봇: C 완공 전까지 에너지 때문에 막힌 날이 연속 3일을 넘지 않는다",
        function()
            for index, r in flat do
                t.truthy(
                    r.maxBlocked <= 3,
                    Config.SITES[index].name .. " 최대 " .. r.maxBlocked .. "일"
                )
            end
        end
    )

    -- START.food 35 (2026-10-18 사용자 결정): Farm 전 최저 식량 8 ~ 11 (원정 6일 기준).
    -- 산소 고갈이나 캐릭터 초기화(식량 -1)를 5번 겪어도 Farm 전에 바닥나지 않는 여유를 요구한다
    t.test("현실적 봇: Farm 가동 전 식량 여유 5 이상", function()
        for index, r in flat do
            t.truthy(r.minFood >= 5, Config.SITES[index].name .. " 최저 식량 " .. r.minFood)
        end
    end)

    t.test("현실적 봇: 물 원정을 안 하면 실패", function()
        for _, site in Config.SITES do
            local r = simulatePlayer(site.sunlight, TRIP_DAYS, true)
            t.eq(r.result, "lost", site.name)
        end
    end)
end
