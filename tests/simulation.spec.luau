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

local function setActive(state, id: string)
    state.modules[id] = { status = "active", progress = 1, daysLeft = 0 }
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

    t.test(
        "100% 일조 워크스루: 하루 3장 설치 시 1..6일 에너지 3, 9, 18, 30, 45, 63",
        function()
            local expected = { 3, 9, 18, 30, 45, 63 }
            local s = playingState(1)
            for day = 1, 6 do
                s = installMany(s, Config.PANELS_PER_DAY)
                s = Simulation.applyDay(s, Config)
                t.near(s.energy, expected[day], "day " .. day .. " energy")
            end
            t.eq(s.day, 7)
            t.near(s.netEnergy, 18, "6일차 순증감")
            t.near(s.water, 19, "물 25 - 6")
            t.near(s.food, 24, "식량 30 - 6")
            t.near(s.netWater, -1)
            t.near(s.netFood, -1)
            t.eq(s.panelsInstalled, 18)
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
        s.modules.C = { status = "building", progress = 6 / 7, daysLeft = 1 }
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

    t.test("미션 문구가 단계에 따라 바뀐다", function()
        local s = playingState(1)
        t.eq(
            Simulation.missionText(s, Config),
            "솔라 필드에서 패널 3장을 설치하세요"
        )
        local one = installMany(s, 1)
        t.eq(one.missionText, "솔라 필드에서 패널 2장을 설치하세요")
        s = installMany(s, 3)
        t.eq(s.missionText, Config.MISSION_TEXTS.firstWaterTrip)
        local _, filled = Simulation.fillTank(s, Config)
        local _, unloaded = Simulation.unloadWater(filled, Config)
        t.eq(unloaded.missionText, "Habitat A를 착공하세요 (Energy 60, Water 20 필요)")
        unloaded.energy = 100
        local _, building = Simulation.startBuild(unloaded, Config, "A")
        t.contains(building.missionText, "Habitat A 건설 중: 5일 남음")
        local dry = Simulation.copy(building)
        dry.water = 0
        t.contains(Simulation.missionText(dry, Config), "물이 바닥났습니다")
    end)

    -- 밸런스 스모크: 단순 봇 (매일 패널 3장, 일정 간격 물 원정, 가능하면 즉시 착공)
    local function simulateBot(sunlight: number, tripEveryDays: number): (string, number)
        local s = playingState(sunlight)
        for _ = 1, Config.TOTAL_DAYS + 1 do
            s = installMany(s, Config.PANELS_PER_DAY)
            if s.day % tripEveryDays == 0 then
                local _, filled = Simulation.fillTank(s, Config)
                local _, unloaded = Simulation.unloadWater(filled, Config)
                s = unloaded
            end
            for _, id in Config.MODULE_ORDER do
                local ok, new = Simulation.startBuild(s, Config, id)
                if ok then
                    s = new
                end
            end
            s = Simulation.applyDay(s, Config)
            local result = Simulation.checkEnd(s, Config)
            if result ~= "none" then
                return result, Simulation.finishGame(s, Config, result).day
            end
        end
        return "none", s.day
    end

    t.test(
        "밸런스 스모크: 6일마다 물 원정이면 4곳 모두 90일 안에 승리",
        function()
            local days = {}
            for _, site in Config.SITES do
                local result, day = simulateBot(site.sunlight, 6)
                t.eq(result, "won", site.name)
                table.insert(days, string.format("%s %d일", site.name, day))
            end
            print("        승리 일수: " .. table.concat(days, ", "))
        end
    )

    t.test("밸런스 스모크: 물 원정을 안 하면 실패", function()
        local result = simulateBot(1, 1000)
        t.eq(result, "lost")
    end)
end
