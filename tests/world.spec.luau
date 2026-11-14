-- WorldMath 순수 함수 테스트 (v2 월드 배치). 좌표는 2026-11-14 Studio MissionC 실측값

local WorldMath = require("../src/shared/WorldMath")

local function p(x: number, z: number, y: number?): any
    return { X = x, Y = y or 0, Z = z }
end

-- Studio 실측 표시 중심 (X, Z). 얼음은 2026-11-14, 기지는 2026-11-15 옮긴 자리 (리드 전달)
local ICE = {
    { name = "Ice1", position = p(576.50, -245.50) },
    { name = "Ice2", position = p(663.96, -663.72) },
    { name = "Ice3", position = p(759.92, -183.77) },
    { name = "Ice4", position = p(327.98, -231.96) },
    { name = "Ice5", position = p(-296.10, -375.90) },
}
local BASE_EXIT = p(-38.20, -43.09) -- 리드가 얼음 쪽으로 다시 옮긴 자리
local LANDER = p(-65.69, 63.42)
local ROVER_PARK = p(-131.18, 2.11)

local function names(list): string
    local out = {}
    for _, entry in list do
        table.insert(out, entry.name)
    end
    return table.concat(out, ",")
end

return function(t)
    t.test("WorldMath: 수평 거리는 높이를 무시한다", function()
        t.near(WorldMath.horizontalDistance(p(0, 0, 100), p(3, 4, -50)), 5)
        t.near(WorldMath.horizontalDistance(p(1, 1), p(1, 1)), 0)
    end)

    t.test(
        "WorldMath: 얼음 표시를 기지 출구에서 실제 거리로 정렬한다",
        function()
            local sorted = WorldMath.sortByDistance(ICE, BASE_EXIT)
            t.eq(
                names(sorted),
                "Ice4,Ice5,Ice1,Ice3,Ice2",
                "출구 기준 순서 (2026-11-15 옮긴 기지, 리드 실측 412, 421, 647, 810, 937)"
            )
            local expected = { 412.0, 421.0, 647.2, 810.4, 937.1 }
            for i, entry in sorted do
                t.eq(entry.index, i, "index " .. i)
                t.truthy(
                    math.abs(entry.distance - expected[i]) < 0.5,
                    entry.name .. " 거리 " .. entry.distance
                )
            end
        end
    )

    t.test(
        "WorldMath: 기준점에 따라 순서가 달라진다 (착륙선, 로버 주차)",
        function()
            t.eq(
                names(WorldMath.sortByDistance(ICE, LANDER)),
                "Ice4,Ice5,Ice1,Ice3,Ice2",
                "착륙선 기준 (Ice4 492, Ice5 496으로 출구 기준과 1, 2위가 바뀐다)"
            )
            local park = WorldMath.sortByDistance(ICE, ROVER_PARK)
            t.eq(names(park), "Ice5,Ice4,Ice1,Ice3,Ice2", "로버 주차 기준")
            t.truthy(math.abs(park[1].distance - 412.4) < 0.5, "가장 가까운 곳 약 412")
            t.truthy(math.abs(park[5].distance - 1037.1) < 0.5, "가장 먼 곳 약 1037")
        end
    )

    t.test(
        "WorldMath: 정렬은 입력을 바꾸지 않고 같은 거리는 이름 순서 (Rules와 같은 규칙)",
        function()
            local items = {
                { name = "IceB", position = p(10, 0) },
                { name = "IceA", position = p(-10, 0) },
                { name = "IceC", position = p(0, 5) },
            }
            local sorted = WorldMath.sortByDistance(items, p(0, 0))
            t.eq(names(sorted), "IceC,IceA,IceB")
            t.eq(items[1].name, "IceB", "입력 순서 유지")
            t.eq(#WorldMath.sortByDistance({}, p(0, 0)), 0, "빈 목록")
        end
    )

    t.test("WorldMath: 그린하우스를 FarmPad 바닥 넓이에 맞추는 배율", function()
        -- 에셋 31 x 24.6 x 27.5를 표시 31 x 25 바닥에 넣으면 깊이(27.5 -> 25)가 결정한다
        local size = p(31, 27.5, 24.6)
        t.near(WorldMath.fitScale(size, { X = 31, Z = 25 }), 25 / 27.5)
        -- 높이 상한이 더 작으면 높이가 결정한다
        t.near(WorldMath.fitScale(size, { X = 31, Z = 25, Y = 12.3 }), 0.5)
        -- 작은 키트 메시는 키운다 (착륙선 5.61 -> 12)
        t.near(WorldMath.fitScale(p(5.61, 5.61, 4.32), { X = 12, Z = 12, Y = 28 }), 12 / 5.61)
        -- 범위 자르기
        t.near(WorldMath.fitScale(p(1, 1, 1), { X = 10, Z = 10 }, nil, 2), 2, "최대")
        t.near(WorldMath.fitScale(p(100, 1, 100), { X = 10, Z = 10 }, 0.5), 0.5, "최소")
    end)

    t.test("WorldMath: 크기가 0인 모델도 무한대가 되지 않는다", function()
        local factor = WorldMath.fitScale(p(0, 0, 0), { X = 10, Z = 10, Y = 10 })
        t.truthy(factor > 0 and factor < math.huge, "유한 배율 " .. factor)
    end)

    t.test("WorldMath: SolarField 82 x 49에 슬롯 20개 (5 x 4)", function()
        local slots = WorldMath.slotGrid(82, 49, 20, 2, 1)
        t.eq(#slots, 20)
        local maxRow, maxCol = 0, 0
        for i, s in slots do
            t.eq(s.index, i)
            maxRow, maxCol = math.max(maxRow, s.row), math.max(maxCol, s.col)
            -- 바닥 넓이 안 (가장자리 여백 포함)
            t.truthy(math.abs(s.x) + s.sizeX / 2 <= 82 / 2 - 2 + 1e-6, "x 안쪽 " .. i)
            t.truthy(math.abs(s.z) + s.sizeZ / 2 <= 49 / 2 - 2 + 1e-6, "z 안쪽 " .. i)
        end
        t.eq(maxCol, 5, "열")
        t.eq(maxRow, 4, "행")
        t.near(slots[1].sizeX, 14.8)
        t.near(slots[1].sizeZ, 10.5)
        -- 겹치지 않는다
        for i = 1, #slots do
            for j = i + 1, #slots do
                local a, b = slots[i], slots[j]
                local overlapX = math.abs(a.x - b.x) < (a.sizeX + b.sizeX) / 2 - 1e-6
                local overlapZ = math.abs(a.z - b.z) < (a.sizeZ + b.sizeZ) / 2 - 1e-6
                t.falsy(overlapX and overlapZ, "겹침 " .. i .. "," .. j)
            end
        end
    end)

    t.test("WorldMath: 슬롯 개수는 인자로 정한다", function()
        t.eq(#WorldMath.slotGrid(82, 49, 5, 2, 1), 5)
        t.eq(#WorldMath.slotGrid(82, 49, 1, 2, 1), 1)
        t.eq(#WorldMath.slotGrid(82, 49, 0, 2, 1), 0, "0개")
        local one = WorldMath.slotGrid(10, 10, 1, 1, 1)[1]
        t.near(one.x, 0)
        t.near(one.z, 0)
        t.near(one.sizeX, 8)
    end)

    t.test("WorldMath: 지면 샘플 고르기와 없는 값 건너뛰기", function()
        local samples: { number? } = { -0.8, nil, -1.1, -0.4, nil }
        t.near(WorldMath.groundFromSamples(samples, "min", 99), -1.1)
        t.near(WorldMath.groundFromSamples(samples, "max", 99), -0.4)
        t.near(WorldMath.groundFromSamples(samples, "average", 99), (-0.8 - 1.1 - 0.4) / 3)
        t.near(WorldMath.groundFromSamples({}, "min", 7), 7, "샘플 없음 -> 대체 높이")
        t.near(WorldMath.groundFromSamples({ nil, nil }, "max", -3), -3)
    end)

    t.test(
        "WorldMath: 기초 판은 가장 높은 지면 위, 가장 낮은 지면 아래까지",
        function()
            local top, bottom = WorldMath.foundation({ -1.6, 2.5, 0.2 }, 0, 0.05, 1)
            t.near(top, 2.55)
            t.near(bottom, -2.6)
            local top2, bottom2 = WorldMath.foundation({}, 4, 0.05, 1)
            t.near(top2, 4.05, "샘플 없음 윗면")
            t.near(bottom2, 3, "샘플 없음 밑면")
        end
    )

    t.test("WorldMath: 바닥 맞춤 이동량", function()
        t.near(WorldMath.snapDelta(2, 5, 0.5), -3.5, "떠 있으면 내린다")
        t.near(WorldMath.snapDelta(-1, -4), 3, "묻혀 있으면 올린다")
    end)

    t.test(
        "WorldMath: 건설 진행률에 따른 솟아오름 (v1 riseOffset과 같다)",
        function()
            t.near(WorldMath.riseOffset(10, 0), -10)
            t.near(WorldMath.riseOffset(10, 0.5), -5)
            t.near(WorldMath.riseOffset(10, 1), 0)
            t.near(WorldMath.riseOffset(10, 2), 0, "1 넘으면 자른다")
            t.near(WorldMath.riseOffset(10, -1), -10, "0 아래 자른다")
            t.near(WorldMath.riseOffset(10, 0 / 0), -10, "NaN은 0")
        end
    )

    t.test("WorldMath: Rules 남은 일수로 진행률, 관로 보이는 구간", function()
        t.near(WorldMath.buildFraction(2, 5), 0.6)
        t.near(WorldMath.buildFraction(0, 3), 1)
        t.near(WorldMath.buildFraction(3, 3), 0)
        t.near(WorldMath.buildFraction(1, 0), 1, "건설 0일")
        t.eq(WorldMath.visibleSegments(10, 0), 0)
        t.eq(WorldMath.visibleSegments(10, 0.55), 5)
        t.eq(WorldMath.visibleSegments(10, 1), 10)
        t.eq(WorldMath.visibleSegments(3, 2 / 3), 2, "부동소수 경계")
    end)

    t.test("WorldMath: 원기둥, 공 표시의 실제 렌더 크기", function()
        local cyl = WorldMath.renderedSize(p(28, 12, 118), "Cylinder") -- X 28, Y 118, Z 12
        t.near(cyl.X, 28)
        t.near(cyl.Y, 12)
        t.near(cyl.Z, 12)
        local ball = WorldMath.renderedSize({ X = 3, Y = 4, Z = 5 }, "Ball")
        t.near(ball.X, 3)
        t.near(ball.Z, 3)
        local block = WorldMath.renderedSize({ X = 31, Y = 4, Z = 25 }, "Block")
        t.near(block.Z, 25)
    end)

    t.test(
        "WorldMath: 세워 둔 착륙선 원기둥의 월드 경계 크기 (Studio 실측 회전)",
        function()
            local right = { X = 0.000975, Y = 0.99881, Z = 0.04877 }
            local up = { X = 0, Y = -0.04877, Z = 0.99881 }
            local back = { X = 1, Y = -0.000974, Z = -0.0000476 }
            local e = WorldMath.worldExtents({ X = 28, Y = 12, Z = 12 }, right, up, back)
            t.truthy(math.abs(e.X - 12.03) < 0.05, "X " .. e.X)
            t.truthy(math.abs(e.Y - 28.56) < 0.05, "Y " .. e.Y)
            t.truthy(math.abs(e.Z - 13.35) < 0.05, "Z " .. e.Z)
            -- 회전 없는 상자
            local plain = WorldMath.worldExtents(
                { X = 2, Y = 3, Z = 4 },
                { X = 1, Y = 0, Z = 0 },
                { X = 0, Y = 1, Z = 0 },
                { X = 0, Y = 0, Z = 1 }
            )
            t.near(plain.X, 2)
            t.near(plain.Y, 3)
            t.near(plain.Z, 4)
        end
    )

    t.test("WorldMath: 방향 yaw와 각도 맞춤", function()
        t.near(WorldMath.yawToward(p(0, 0), p(0, -10)), 0, "-Z를 보면 0")
        t.near(WorldMath.yawToward(p(0, 0), p(-10, 0)), math.pi / 2, "-X를 보면 90도")
        t.near(WorldMath.yawToward(p(0, 0), p(10, 0)), -math.pi / 2, "+X를 보면 -90도")
        t.near(math.abs(WorldMath.yawToward(p(0, 0), p(0, 10))), math.pi, "+Z를 보면 180도")
        t.near(WorldMath.yawOfDirection(0, 0), 0, "방향 없음")
        t.near(WorldMath.snapAngle(math.rad(80), math.rad(90)), math.rad(90))
        t.near(WorldMath.snapAngle(math.rad(-100), math.rad(90)), math.rad(-90))
        t.near(WorldMath.snapAngle(math.rad(17), 0), math.rad(17), "step 0이면 그대로")
        t.near(WorldMath.snapAngle(math.rad(350), math.rad(90)), 0, "범위 정리")
    end)

    t.test(
        "WorldMath: 문을 스폰 쪽으로 (착륙선 -> SpawnLocation이면 남쪽 -Z)",
        function()
            local lander, spawn = p(188.3, -516.6), p(180.3, -542.4)
            local raw = WorldMath.yawToward(lander, spawn)
            local markerYaw = math.pi / 2 -- 표시 LookVector (-1, 0, 0)
            local yaw = markerYaw + WorldMath.snapAngle(raw - markerYaw, math.pi / 2)
            t.near(math.sin(yaw), 0, "look X")
            t.near(math.cos(yaw), 1, "look -Z")
        end
    )

    t.test("WorldMath: 방향에 맞는 바닥 면", function()
        local nx, nz, half = WorldMath.faceToward(10, 5, 0.2, -1)
        t.eq(nx, 0)
        t.eq(nz, -1)
        t.near(half, 5)
        nx, nz, half = WorldMath.faceToward(10, 5, 3, 1)
        t.eq(nx, 1)
        t.eq(nz, 0)
        t.near(half, 10)
    end)

    t.test("WorldMath: 관로 경로 점과 상자 안 판정", function()
        local points = WorldMath.pathPoints(p(0, 0), p(100, 0), 24)
        t.eq(#points, 6, "100 / 24 -> 5구간 6점")
        t.near(points[1].X, 0)
        t.near(points[6].X, 100)
        t.near(points[2].X, 20)
        t.eq(#WorldMath.pathPoints(p(5, 5), p(5, 5), 24), 2, "같은 점도 2점")
        t.truthy(WorldMath.pointInBox({ X = 1, Y = 2, Z = -3 }, { X = 4, Y = 4, Z = 6 }))
        t.falsy(WorldMath.pointInBox({ X = 2.1, Y = 0, Z = 0 }, { X = 4, Y = 4, Z = 6 }))
    end)

    t.test("WorldMath: Rules 시설 인스턴스 id에서 정의 id", function()
        t.eq(WorldMath.facilityDefId("pipe"), "pipe", "Rules 첫 파이프는 숫자 없음")
        t.eq(WorldMath.facilityDefId("pipe2"), "pipe")
        t.eq(WorldMath.facilityIndex("pipe"), 1)
        t.eq(WorldMath.facilityIndex("pipe2"), 2)
        t.eq(WorldMath.facilityIndex("pipe1"), 1)
        t.eq(WorldMath.facilityIndex("farm"), 1)
        t.eq(WorldMath.facilityDefId("pipe1"), "pipe")
        t.eq(WorldMath.facilityDefId("pipe12"), "pipe")
        t.eq(WorldMath.facilityDefId("led"), "led")
        t.eq(WorldMath.facilityDefId("hydroponics"), "hydroponics")
        t.eq(WorldMath.facilityDefId("42"), "42", "숫자만이면 그대로")
    end)

    t.test("WorldMath: 갇힘 검사 경계 (수평 margin, 세로 headroom)", function()
        local lo, hi = p(-5, -5, 0), p(5, 5, 4)
        t.truthy(WorldMath.insideBounds(p(0, 0, 3), lo, hi, 1, 3), "가운데")
        t.truthy(WorldMath.insideBounds(p(5.8, 0, 3), lo, hi, 1, 3), "옆으로 margin 안")
        t.falsy(WorldMath.insideBounds(p(6.2, 0, 3), lo, hi, 1, 3), "margin 밖")
        t.truthy(WorldMath.insideBounds(p(0, 0, 6.5), lo, hi, 1, 3), "지붕 위 headroom 안")
        t.falsy(WorldMath.insideBounds(p(0, 0, 7.5), lo, hi, 1, 3), "지붕 위 멀리")
        t.falsy(WorldMath.insideBounds(p(0, 0, -1.5), lo, hi, 1, 3), "밑")
    end)

    t.test("WorldMath: 내보내기 자리 (정면, 가장 가까운 면, 나란히)", function()
        local lo, hi = { X = -4, Z = -6 }, { X = 4, Z = 6 }
        local out, dx, dz = WorldMath.exitPoint({ X = 3, Z = 5 }, lo, hi, 3, "front")
        t.near(out.X, 0, "정면은 가운데로")
        t.near(out.Z, -9, "정면(-Z) 바깥 clearance")
        t.eq(dx, 0)
        t.eq(dz, -1)
        local side = WorldMath.exitPoint({ X = 0, Z = 0 }, lo, hi, 3, "front", 20)
        t.near(side.X, 4, "옆 간격은 경계 폭 안으로 자른다")
        local near, ndx, ndz = WorldMath.exitPoint({ X = 3.5, Z = 1 }, lo, hi, 1, "nearest")
        t.near(near.X, 5, "가장 가까운 +X 면 바깥")
        t.near(near.Z, 1, "다른 축은 그대로")
        t.eq(ndx, 1)
        t.eq(ndz, 0)
        local back = WorldMath.exitPoint({ X = 0, Z = 5.5 }, lo, hi, 1, "nearest")
        t.near(back.Z, 7, "가장 가까운 +Z 면")
        t.eq(WorldMath.spreadOffset(1, 3), 0)
        t.eq(WorldMath.spreadOffset(2, 3), 3)
        t.eq(WorldMath.spreadOffset(3, 3), -3)
        t.eq(WorldMath.spreadOffset(4, 3), 6)
    end)

    t.test("WorldMath: 선분이 상자를 지나는지", function()
        t.truthy(
            WorldMath.segmentHitsBox({ X = -10, Z = 0 }, { X = 10, Z = 0 }, 2, 2),
            "가로지름"
        )
        t.falsy(
            WorldMath.segmentHitsBox({ X = -10, Z = 3 }, { X = 10, Z = 3 }, 2, 2),
            "위로 비켜감"
        )
        t.falsy(
            WorldMath.segmentHitsBox({ X = -10, Z = 0 }, { X = -3, Z = 0 }, 2, 2),
            "닿기 전에 끝"
        )
        t.truthy(
            WorldMath.segmentHitsBox({ X = 0, Z = 0 }, { X = 1, Z = 1 }, 2, 2),
            "안에서 시작"
        )
        t.truthy(
            WorldMath.segmentHitsBox({ X = -3, Z = -1 }, { X = -1, Z = 3 }, 2, 2),
            "모서리 대각선"
        )
        t.falsy(
            WorldMath.segmentHitsBox({ X = -4, Z = 0 }, { X = 0, Z = 4 }, 1.9, 1.9),
            "모서리 비켜감"
        )
    end)

    t.test("WorldMath: clamp01, lerp", function()
        t.near(WorldMath.clamp01(1.5), 1)
        t.near(WorldMath.clamp01(-0.2), 0)
        t.near(WorldMath.lerp(2, 6, 0.25), 3)
    end)
end
