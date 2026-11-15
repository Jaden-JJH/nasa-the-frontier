-- v2 클라이언트 순수 계산 테스트 (src/shared/ClientMath.luau)

local ClientMath = require("../src/shared/ClientMath")
local MissionConfig = require("../src/shared/MissionConfig")

return function(t)
    t.test("ClientMath: 자원 숫자는 내림, 잘못된 값은 0", function()
        t.eq(ClientMath.wholeNumber(19.6), 19, "20 미만 경고와 같은 쪽으로 내림")
        t.eq(ClientMath.wholeNumber(70), 70)
        t.eq(ClientMath.wholeNumber(19.9999999), 20, "부동소수 오차는 정수로")
        t.eq(ClientMath.wholeNumber(-3), 0, "음수는 0")
        t.eq(ClientMath.wholeNumber(nil), 0, "nil은 0")
        t.eq(ClientMath.wholeNumber(0 / 0), 0, "NaN은 0")
        t.eq(ClientMath.wholeNumber(math.huge), 0, "무한대는 0")
    end)

    t.test("ClientMath: 비율과 자원 단계", function()
        t.near(ClientMath.ratio(70, 100), 0.7)
        t.eq(ClientMath.ratio(150, 100), 1, "상한을 넘으면 1")
        t.eq(ClientMath.ratio(5, 0), 0, "max 0")
        t.eq(ClientMath.ratio(nil, 100), 0, "값 없음")
        local threshold = MissionConfig.SCORE.lowThreshold
        t.eq(ClientMath.resourceLevel(0, threshold), "zero")
        t.eq(ClientMath.resourceLevel(19.9, threshold), "low")
        t.eq(ClientMath.resourceLevel(20, threshold), "ok", "20은 경고가 아니다 (20 미만)")
        t.eq(ClientMath.resourceLevel(nil, threshold), "zero")
    end)

    t.test("ClientMath: 남은 초는 올림, 지나면 0", function()
        t.eq(ClientMath.secondsLeft(130, 100), 30)
        t.eq(ClientMath.secondsLeft(130, 100.2), 30, "29.8초는 30으로")
        t.eq(ClientMath.secondsLeft(100, 130), 0, "지난 마감")
        t.eq(ClientMath.secondsLeft(nil, 100), 0, "마감 없음")
        t.eq(ClientMath.secondsLeft(130, 130), 0, "딱 마감")
    end)

    t.test("ClientMath: 경계에 여백과 최소 길이", function()
        local b = ClientMath.bounds({ { X = 0, Z = 0 }, { X = 100, Z = 50 } }, 10)
        t.eq(b.minX, -10)
        t.eq(b.maxX, 110)
        t.eq(b.minZ, -10)
        t.eq(b.maxZ, 60)
        local one = ClientMath.bounds({ { X = 5, Z = 5 } }, 0, 40)
        t.eq(one.maxX - one.minX, 40, "점 하나면 minSpan")
        t.eq(one.minX, -15)
        local empty = ClientMath.bounds({}, 0, 2)
        t.eq(empty.maxX - empty.minX, 2, "빈 목록도 크기가 있다")
    end)

    t.test("ClientMath: 지도 투영은 비율을 지키고 가운데", function()
        local b = { minX = 0, minZ = 0, maxX = 200, maxZ = 100 }
        local fit = ClientMath.fitMap(b, 400, 400)
        t.near(fit.scale, 2, "가로가 기준")
        t.near(fit.offsetX, 0)
        t.near(fit.offsetY, 100, "세로는 가운데")
        local x, y = ClientMath.project(fit, 0, 0)
        t.near(x, 0)
        t.near(y, 100)
        x, y = ClientMath.project(fit, 200, 100)
        t.near(x, 400)
        t.near(y, 300)
        x, y = ClientMath.project(fit, 100, 50)
        t.near(x, 200, "중심")
        t.near(y, 200)
        -- +Z는 아래쪽
        local _, yTop = ClientMath.project(fit, 50, 10)
        local _, yBottom = ClientMath.project(fit, 50, 90)
        t.truthy(yTop < yBottom, "+Z가 아래")
        local cx, cy = ClientMath.clampToMap(fit, -50, 999, 8)
        t.eq(cx, 8)
        t.eq(cy, 392)
    end)

    t.test("ClientMath: 왕복 비율과 아이콘 위치", function()
        t.near(ClientMath.roundTripFraction(0), 0)
        t.near(ClientMath.roundTripFraction(0.25), 0.5)
        t.near(ClientMath.roundTripFraction(0.5), 1, "가운데에서 목표")
        t.near(ClientMath.roundTripFraction(0.75), 0.5)
        t.near(ClientMath.roundTripFraction(1), 0)
        t.near(ClientMath.roundTripFraction(7), 0, "범위 밖은 자른다")
        local fsd = { progress = 0, mapFrom = 0.2, mapTo = 0.5, mapFromAt = 100, mapToAt = 130 }
        t.near(ClientMath.fsdMapProgress(fsd, 100), 0.2, "구간 시작")
        t.near(ClientMath.fsdMapProgress(fsd, 115), 0.35, "구간 가운데")
        t.near(ClientMath.fsdMapProgress(fsd, 200), 0.5, "마감 뒤는 마감 값")
        t.near(ClientMath.fsdMapProgress(fsd, 50), 0.2, "시작 전은 시작 값")
        t.near(
            ClientMath.fsdMapProgress({ progress = 0.5 }, 115),
            0.5,
            "구간 없으면 Rules progress 그대로 (파견 전 하루 몫을 더하지 않는다)"
        )
        t.near(ClientMath.fsdMapProgress(nil, 115), 0)
        local p = ClientMath.tripPoint({ X = 0, Z = 0 }, { X = 100, Z = -40 }, 0.5)
        t.near(p.X, 50)
        t.near(p.Z, -20)
        t.near(ClientMath.horizontalDistance({ X = 0, Z = 0 }, { X = 3, Z = 4 }), 5)
    end)

    t.test("ClientMath: 핀 화살표, 화면 안이면 그 자리", function()
        local a = ClientMath.edgeArrow(500, 300, true, 1000, 600, 40)
        t.truthy(a.onScreen)
        t.eq(a.x, 500)
        t.eq(a.y, 300)
        local edge = ClientMath.edgeArrow(970, 300, true, 1000, 600, 40)
        t.falsy(edge.onScreen, "가장자리 여백 안은 화면 밖으로 본다")
    end)

    t.test("ClientMath: 핀 화살표, 화면 밖이면 가장자리와 각도", function()
        local right = ClientMath.edgeArrow(2000, 300, true, 1000, 600, 40)
        t.falsy(right.onScreen)
        t.near(right.x, 960, "오른쪽 가장자리")
        t.near(right.y, 300)
        t.near(right.angle, 90, "오른쪽을 가리킨다")
        local up = ClientMath.edgeArrow(500, -900, true, 1000, 600, 40)
        t.near(up.y, 40, "위 가장자리")
        t.near(up.angle, 0, "위를 가리킨다")
        local left = ClientMath.edgeArrow(-500, 300, true, 1000, 600, 40)
        t.near(left.x, 40)
        t.near(math.abs(left.angle), 90)
        t.truthy(left.angle < 0, "왼쪽은 음수 각도")
        local corner = ClientMath.edgeArrow(5000, 5000, true, 1000, 600, 40)
        t.truthy(
            corner.x <= 960 + 1e-6 and corner.y <= 560 + 1e-6,
            "모서리 쪽도 사각형 안"
        )
    end)

    t.test("ClientMath: 카메라 뒤의 점은 방향을 뒤집는다", function()
        -- 뒤에 있는 점이 화면 오른쪽에 투영되어도 실제로는 왼쪽 뒤
        local back = ClientMath.edgeArrow(700, 300, false, 1000, 600, 40)
        t.falsy(back.onScreen, "뒤는 화면 안 좌표여도 화면 밖")
        t.near(back.x, 40, "왼쪽 가장자리")
        t.truthy(back.angle < 0)
        local behind = ClientMath.edgeArrow(500, 300, false, 1000, 600, 40)
        t.near(behind.angle, 180, "정확히 뒤면 아래")
        t.near(behind.y, 560)
    end)

    t.test("ClientMath: 메달 비교", function()
        t.eq(ClientMath.medalValue("gold"), 3)
        t.eq(ClientMath.medalValue(nil), 0)
        t.eq(ClientMath.bestMedal("bronze", "silver"), "silver")
        t.eq(ClientMath.bestMedal("gold", "silver"), "gold")
        t.eq(ClientMath.bestMedal(nil, nil), nil)
        t.eq(ClientMath.bestMedal("bronze", nil), "bronze")
    end)

    t.test("ClientMath: 서둘러 가기 근사는 MissionConfig 배율", function()
        local roverDef = MissionConfig.MISSIONS.C.rover
        local days, energy, risk = ClientMath.rushPreview(3, 27, "high", roverDef)
        t.eq(days, 2, "3일 x 0.65 = 1.95 -> 2")
        t.eq(energy, 41, "27 x 1.5 = 40.5 -> 41")
        t.eq(risk, "extreme", "high 다음은 extreme")
        local d1 = ClientMath.rushPreview(1, 9, "low", roverDef)
        t.eq(d1, 1, "최소 1일")
        t.eq(ClientMath.nextRisk(roverDef.riskOrder, "extreme"), "extreme", "끝은 그대로")
    end)

    t.test("ClientMath: 순위표 상위 5와 내 순위 한 줄", function()
        local entries = { "a", "b", "c", "d", "e", "f", "g" }
        local rows, extra = ClientMath.rankRows(entries, 5, 7)
        t.eq(#rows, 5)
        t.eq(rows[1].entry, "a")
        t.eq(extra, 7, "5위 밖이면 아래 한 줄")
        local rows2, extra2 = ClientMath.rankRows(entries, 5, 2)
        t.truthy(rows2[2].mine, "안이면 그 줄을 표시")
        t.eq(extra2, nil)
        local rows3 = ClientMath.rankRows(nil, 5, nil)
        t.eq(#rows3, 0, "목록 없음")
    end)

    t.test("ClientMath: 역할 표 정리와 인원", function()
        local roles = ClientMath.normalizeRoles({
            ["101"] = "controller",
            [202] = "explorer",
            ["303"] = "explorer",
            bad = "engineer",
            [404] = 5,
        })
        t.eq(roles[101], "controller", "문자열 키")
        t.eq(roles[202], "explorer", "숫자 키")
        t.eq(roles[404], nil, "역할이 문자열이 아니면 뺀다")
        local counts = ClientMath.roleCounts(roles)
        t.eq(counts.explorer, 2)
        t.eq(counts.controller, 1)
        t.eq(counts.engineer, nil)
        t.eq(next(ClientMath.normalizeRoles(nil)), nil, "nil은 빈 표")
    end)

    t.test(
        "ClientMath: 역할 자리 수 (Q25: 2명 관제사+탐사, 3명 +엔지니어, 4명 탐사 2)",
        function()
            t.eq(ClientMath.roleCapacity("controller", 2), 1)
            t.eq(ClientMath.roleCapacity("explorer", 2), 1)
            t.eq(ClientMath.roleCapacity("engineer", 2), 0)
            t.eq(ClientMath.roleCapacity("explorer", 3), 2)
            t.eq(ClientMath.roleCapacity("engineer", 3), 1)
            t.eq(ClientMath.roleCapacity("explorer", 4), 2)
            t.eq(ClientMath.roleCapacity("engineer", 4), 1)
            t.eq(ClientMath.roleCapacity("solo", 4), 0, "모르는 역할")
        end
    )

    t.test("ClientMath: 비용 숫자 글자", function()
        t.eq(ClientMath.formatAmount(60), "60")
        t.eq(ClientMath.formatAmount(3.6), "3.6")
        t.eq(ClientMath.formatAmount(1.2 * 3), "3.6", "부동소수 오차")
        t.eq(ClientMath.formatAmount(0.25), "0.25")
        t.eq(ClientMath.formatAmount(2.004), "2")
        t.eq(ClientMath.formatAmount(nil), "0")
    end)

    t.test("ClientMath: 건설비 줄에서 빨간 자원", function()
        local cost = { energy = 60, water = 40 }
        local none = ClientMath.costShortfall(cost, { energy = 10, water = 10 }, true)
        t.falsy(
            none.energy or none.water,
            "서버가 살 수 있다고 하면 빨간 것 없음 (비상 패널 등)"
        )
        local short = ClientMath.costShortfall(cost, { energy = 70, water = 30 }, false)
        t.falsy(short.energy, "에너지는 충분")
        t.truthy(short.water, "물만 모자람")
        local unknown = ClientMath.costShortfall(cost, nil, false)
        t.truthy(unknown.energy and unknown.water, "자원을 모르면 비용 있는 것 전부")
        local zero = ClientMath.costShortfall({ energy = 4 }, nil, false)
        t.truthy(zero.energy)
        t.falsy(zero.water, "비용 없는 자원은 빨갛지 않다")
        local locked = ClientMath.costShortfall(cost, { energy = 90, water = 90 }, false, true)
        t.falsy(locked.energy or locked.water, "잠김 때문이면 자원은 빨갛지 않다")
        local guess = ClientMath.costShortfall(cost, { energy = 59.5, water = 40 }, nil)
        t.truthy(guess.energy, "Affordable이 없으면 자원으로 판단")
        t.falsy(guess.water, "딱 맞으면 충분")
    end)

    t.test("ClientMath: 로버 충전 표시 상태", function()
        local keep = MissionConfig.MANUAL_DRIVE.chargeKeepEnergy
        local base = {
            status = "parked",
            atBase = true,
            charging = false,
            battery = 30,
            batteryMax = 50,
            energy = 60,
            keep = keep,
        }
        local function with(changes)
            local info = table.clone(base)
            for k, v in changes do
                info[k] = v
            end
            return ClientMath.roverChargeView(info)
        end
        local charging = with({ charging = true })
        t.eq(charging.mode, "charging")
        t.eq(charging.percent, 60)
        t.eq(with({ battery = 50 }).mode, "full")
        t.eq(
            with({ battery = 49.9 }).percent,
            99,
            "가득 차기 전에는 100을 보이지 않는다"
        )
        t.eq(with({ battery = 49.9 }).mode, "blocked")
        local energy = with({ energy = keep })
        t.eq(energy.mode, "blocked")
        t.eq(energy.reason, "energy", "기지 에너지가 keep 이하면 에너지 때문")
        t.eq(with({ energy = keep + 5 }).reason, "pad", "에너지가 있으면 주차판 밖")
        t.eq(with({ status = "driving" }).reason, "seat", "기지에서 누가 타고 있음")
        t.eq(with({ blocked = "energy", energy = 80 }).reason, "energy", "서버 이유가 우선")
        t.eq(
            with({ blocked = "hud.rover.charge_blocked_seat" }).reason,
            "seat",
            "섀시 ChargeBlocked 문구 키"
        )
        t.eq(
            with({
                blocked = { key = "hud.rover.charge_blocked_energy", args = { keep = 20 } },
                energy = 80,
            }).reason,
            "energy",
            "StateUpdate chargeBlocked Msg"
        )
        t.eq(with({ blocked = "weird" }).reason, "pad", "모르는 이유는 짐작")
        t.eq(
            with({ serverReasons = true, energy = keep }).reason,
            "pad",
            "서버가 이유를 보내는데 비었으면 충전판 밖"
        )
        t.eq(
            with({ serverReasons = true, blocked = "hud.rover.charge_blocked_energy" }).reason,
            "energy"
        )
        t.eq(
            with({ serverReasons = true, blocked = "hud.rover.charge_blocked_pad", energy = keep }).reason,
            "pad",
            "서버가 보낸 충전판 밖 이유가 짐작보다 우선"
        )
        t.eq(with({ atBase = false }).mode, "away")
        t.eq(with({ localDriving = true, charging = true }).mode, "driving", "내가 운전 중")
        t.eq(with({ status = "fsd" }).mode, "hidden")
        t.eq(with({ status = "broken" }).mode, "hidden")
        t.eq(with({ percent = 73.6 }).percent, 73, "섀시 BatteryPercent 우선")
        local msg = ClientMath.batteryMsg(73)
        t.eq(msg.key, "hud.battery.value")
        t.eq(msg.args.n.key, "unit.percent")
        t.eq(msg.args.n.args.n, 73)
        t.eq(ClientMath.chargeLabel(charging, keep).key, "hud.battery.charging")
        local short = ClientMath.chargeLabel(energy, keep)
        t.eq(short.key, "hud.rover.charge_blocked_energy")
        t.eq(short.args.keep, keep)
        t.eq(
            ClientMath.chargeLabel(with({ status = "driving" }), keep).key,
            "hud.rover.charge_blocked_seat"
        )
        t.eq(
            ClientMath.chargeLabel(with({ energy = 90 }), keep).key,
            "hud.rover.charge_blocked_pad"
        )
        local hint = ClientMath.chargeLabel(energy, keep, true)
        t.eq(hint.key, "hud.battery.energy_hint", "긴 설명")
        t.eq(hint.args.keep, keep)
        t.eq(
            ClientMath.chargeLabel(with({ atBase = false }), keep),
            nil,
            "기지 밖은 줄 없음"
        )
    end)

    t.test("ClientMath: 사각형까지 거리와 가장 가까운 건물", function()
        t.eq(ClientMath.rectDistance(1, -2, 5, 5), 0, "안이면 0")
        t.near(ClientMath.rectDistance(8, 0, 5, 5), 3)
        t.near(ClientMath.rectDistance(-8, 9, 5, 5), 5, "모서리 바깥은 대각선 (3, 4)")
        local id, d = ClientMath.pickNearest({ lander = 6, airlock = 3, tank = 30 }, 14, nil, 2)
        t.eq(id, "airlock")
        t.eq(d, 3)
        t.eq(ClientMath.pickNearest({ tank = 20 }, 14, nil, 2), nil, "멀면 없음")
        t.eq(
            ClientMath.pickNearest({ lander = 4, airlock = 3 }, 14, "lander", 2),
            "lander",
            "조금 더 가까운 건물로 바로 바꾸지 않는다"
        )
        t.eq(
            ClientMath.pickNearest({ lander = 6, airlock = 3 }, 14, "lander", 2),
            "airlock",
            "충분히 가까우면 바꾼다"
        )
        t.eq(
            ClientMath.pickNearest({ lander = 15 }, 14, "lander", 2),
            "lander",
            "보이던 카드는 조금 넘어도 유지"
        )
        t.eq(ClientMath.pickNearest({ lander = 17 }, 14, "lander", 2), nil)
        t.eq(
            ClientMath.pickNearest({ b = 3, a = 3 }, 14, nil, 0),
            "a",
            "같은 거리면 id 순서"
        )
        local card = { x0 = 16, y0 = 500, x1 = 306, y1 = 700 }
        t.truthy(ClientMath.rectsOverlap(card, { x0 = 200, y0 = 600, x1 = 460, y1 = 690 }))
        t.falsy(ClientMath.rectsOverlap(card, { x0 = 400, y0 = 600, x1 = 660, y1 = 690 }))
        t.truthy(
            ClientMath.rectsOverlap(card, { x0 = 310, y0 = 600, x1 = 570, y1 = 690 }, 8),
            "여백 안이면 겹침"
        )
    end)

    t.test("ClientMath: 건물 안내 카드 상태 (시설)", function()
        local def = MissionConfig.MISSIONS.C
        local state = {
            stallReason = "energy",
            airlock = { status = "inspecting", daysLeft = 2 },
            facilities = {
                farm = {
                    status = "active",
                    daysLeft = 0,
                    nextHarvestIn = 3,
                    upkeep = { energy = 3.6, water = 1 },
                },
                led = { status = "active", upkeep = { energy = 5, water = 1 } },
                nutrient = { status = "building", daysLeft = 1 },
                hydroponics = {
                    status = "locked",
                    unlockMsg = { key = "toast.build.need_prereq", args = {} },
                },
                pipe = {
                    status = "locked",
                    unlockMsg = { key = "toast.pipe.locked", args = { done = 2, need = 5 } },
                },
            },
        }
        local airlock = ClientMath.buildingInfo("airlock", state, def)
        t.eq(airlock.status.key, "map.fac.status.inspecting")
        t.eq(airlock.status.args.count, 2)
        t.eq(
            airlock.upkeep.energy,
            def.facilities.airlock.upkeep.energy,
            "에어록은 정의 유지비"
        )
        local farm = ClientMath.buildingInfo("farm", state, def)
        t.eq(farm.status.key, "map.fac.status.active")
        t.eq(farm.tone, "active")
        t.eq(farm.detail.key, "map.fac.harvest")
        t.eq(farm.detail.args.count, 3)
        t.eq(farm.upkeep.energy, 3.6, "서버의 지금 유지비 (LED x1.2)")
        local nutrient = ClientMath.buildingInfo("nutrient", state, def)
        t.eq(nutrient.status.key, "map.fac.status.building")
        t.eq(nutrient.status.args.count, 1)
        t.eq(
            nutrient.upkeep.energy,
            def.facilities.nutrient.upkeep.energy,
            "짓는 중은 정의 값"
        )
        local hydro = ClientMath.buildingInfo("hydroponics", state, def)
        t.eq(hydro.tone, "locked")
        t.eq(hydro.detail.key, "toast.build.need_prereq", "잠김 사유")
        local tank = ClientMath.buildingInfo("tank", state, def)
        t.eq(tank.status, nil)
        t.eq(tank.detail.key, "toast.pipe.locked", "물탱크는 파이프 해금 진행")
        t.eq(tank.detail.args.done, 2)

        -- 그린하우스가 멈추면 업그레이드는 효과가 없다
        state.facilities.farm.status = "paused"
        local led = ClientMath.buildingInfo("led", state, def)
        t.eq(led.tone, "paused")
        t.eq(led.detail.key, "info.status.farm_off")
        t.eq(
            ClientMath.buildingInfo("farm", state, def).upkeep,
            nil,
            "멈춘 시설은 유지비 없음"
        )

        -- 자원 부족으로 정지
        state.facilities.led.stalled = true
        local stalled = ClientMath.buildingInfo("led", state, def)
        t.eq(stalled.tone, "stalled")
        t.eq(stalled.detail.key, "hud.stalled.energy")

        -- 둘째 파이프 인스턴스(pipe2)만 있어도 찾는다
        local piped = ClientMath.buildingInfo("pipe", {
            facilities = { pipe2 = { status = "active", nextDeliveryIn = 2, upkeep = {} } },
        }, def)
        t.eq(piped.status.key, "map.fac.status.active")
        t.eq(piped.detail.key, "info.pipe.next")
        t.eq(piped.upkeep.water, def.facilities.pipe.upkeep.water, "유지비 0이면 정의 값")
    end)

    t.test("ClientMath: 건물 안내 카드 상태 (기지 건물, 로버 주차장)", function()
        local def = MissionConfig.MISSIONS.C
        local keep = MissionConfig.MANUAL_DRIVE.chargeKeepEnergy
        local solar =
            ClientMath.buildingInfo("solar", { panels = { installed = 5, total = 13 } }, def)
        t.eq(solar.status.key, "info.solar_field.status")
        t.eq(solar.status.args.installed, 5)
        t.eq(solar.tone, "available")
        local lander = ClientMath.buildingInfo("lander", {}, def)
        t.eq(lander.status, nil, "착륙선은 상태 줄 없음")
        t.eq(lander.upkeep, nil)
        t.eq(ClientMath.buildingInfo("exit", nil, nil).status, nil, "잘못된 상태도 안전")
        local state = {
            resources = { energy = keep, water = 50, food = 30 },
            rover = {
                state = "parked",
                atBase = true,
                charging = false,
                battery = 20,
                batteryMax = 50,
            },
        }
        local park = ClientMath.buildingInfo("roverpark", state, def, { keep = keep })
        t.eq(park.status.key, "hud.battery.value")
        t.eq(park.detail.key, "hud.battery.energy_hint", "충전이 조용히 멈춘 이유")
        t.eq(park.tone, "stalled")
        state.rover.charging = true
        t.eq(
            ClientMath.buildingInfo("roverpark", state, def, { keep = keep }).detail.key,
            "hud.battery.charging"
        )
        state.rover.state = "fsd"
        state.rover.fsd = { recovering = true }
        t.eq(
            ClientMath.buildingInfo("roverpark", state, def, { keep = keep }).status.key,
            "hud.rover.recovering"
        )
        local noFacilities = ClientMath.buildingInfo("farm", {}, def)
        t.eq(noFacilities.status, nil, "상태가 아직 없으면 설명만")
        t.eq(noFacilities.upkeep.energy, def.facilities.farm.upkeep.energy)
    end)

    t.test("ClientMath: 역할 미션 정리 (멀티만, 끝나면 goal)", function()
        local state = {
            mode = "multi",
            roleMissions = {
                ["101"] = { id = "water", progress = 2, goal = 3, done = false },
                [202] = { id = "panels", progress = 7, goal = 6, done = false },
                ["303"] = { id = "mystery", progress = 1, goal = 2 },
            },
        }
        local water = ClientMath.roleMissionOf(state, 101)
        t.eq(water.id, "water")
        t.eq(water.progress, 2)
        t.eq(water.goal, 3)
        t.falsy(water.done)
        t.near(water.ratio, 2 / 3)
        local panels = ClientMath.roleMissionOf(state, 202)
        t.truthy(panels.done, "goal을 넘으면 끝 (숫자 키도 받는다)")
        t.eq(panels.progress, 6, "진행은 goal까지만")
        t.eq(ClientMath.roleMissionOf(state, 303), nil, "모르는 id")
        t.eq(ClientMath.roleMissionOf(state, 404), nil, "없는 플레이어")
        state.mode = "solo"
        t.eq(ClientMath.roleMissionOf(state, 101), nil, "솔로는 없음")
        t.eq(ClientMath.roleMissionOf(nil, 101), nil)
        local finished =
            ClientMath.normalizeRoleMission({ id = "guide", progress = 0, goal = 2, done = true })
        t.eq(finished.progress, 2, "서버가 끝났다고 하면 goal")
        t.eq(
            ClientMath.normalizeRoleMission({ id = "scout", progress = 1 }).goal,
            1,
            "goal 없으면 1"
        )
        for id, keys in ClientMath.ROLE_MISSION_KEYS do
            t.eq(keys.badge, "rolemission." .. id .. ".badge")
        end
    end)

    t.test("ClientMath: 정찰 미션 표시는 안 간 자리만", function()
        local raw = {
            id = "scout",
            progress = 1,
            goal = 3,
            done = false,
            targets = {
                { x = 10.4, z = -20.6, visited = true, key = "facility.led.name" },
                { x = 30, z = 40, visited = false, key = "facility.pipe.name" },
                { x = 50.5, z = 60, key = "" },
                { z = 1 },
            },
        }
        local targets = ClientMath.scoutTargets(raw)
        t.eq(#targets, 2, "방문한 곳과 좌표 없는 곳은 뺀다")
        t.eq(targets[1].key, "facility.pipe.name")
        t.eq(targets[1].mark, "30,40")
        t.eq(targets[2].key, nil, "빈 키는 nil")
        t.eq(targets[1].radius, nil, "radius 없으면 nil")
        raw.radius = 12
        t.eq(ClientMath.scoutTargets(raw)[1].radius, 12, "서버 방문 판정 거리")
        raw.done = true
        t.eq(#ClientMath.scoutTargets(raw), 0, "끝났으면 없음")
        t.eq(
            #ClientMath.scoutTargets({ id = "water", progress = 0, goal = 3, targets = raw.targets }),
            0
        )
        t.eq(#ClientMath.scoutTargets(nil), 0)
    end)

    t.test("ClientMath: 얼음 후보지 표시 번호 (정렬 순서 아님)", function()
        local state = {
            ice = {
                { index = 1, markerName = "Ice4", number = 4 },
                { index = 2, markerName = "Ice1" },
                { index = 3 },
            },
        }
        local first = ClientMath.iceEntry(state, 1)
        t.eq(ClientMath.iceNumber(first), 4, "서버 number")
        t.eq(ClientMath.iceLabel(first).key, "map.ice.label")
        t.eq(ClientMath.iceLabel(first).args.n, 4, "지도 첫 줄(Ice4)은 Ice Site 4")
        t.eq(
            ClientMath.iceNumber(ClientMath.iceEntry(state, 2)),
            1,
            "number가 없으면 표시 이름 숫자"
        )
        t.eq(ClientMath.iceNumber(ClientMath.iceEntry(state, 3)), 3, "그것도 없으면 index")
        t.eq(ClientMath.iceEntry(state, 9), nil)
        t.eq(ClientMath.iceEntry(nil, 1), nil)
        t.eq(ClientMath.iceNumber({ index = 2 }), 2, "핀만 알 때 대체")
    end)

    t.test("ClientMath: 미터 환산은 MissionConfig 배율과 반올림", function()
        t.eq(ClientMath.toMeters(2044, MissionConfig.metersPerStud), 2560, "지형 한 변")
        t.eq(ClientMath.toMeters(100, nil), 100, "배율 없음")
        t.eq(ClientMath.toMeters(nil, 1.25), 0, "잘못된 값")
        t.eq(ClientMath.toMeters(185, MissionConfig.metersPerStud), 232, "Ice4 185 stud")
    end)
end
