--!strict
-- WorldMath: 월드 배치 계산 순수 함수 모음 (MissionWorld가 쓴다, Lune에서 그대로 테스트한다)
-- Roblox 전역(Vector3, CFrame, Instance)을 쓰지 않는다. 좌표는 X, Y, Z 필드를 가진 값이면 된다
-- (Vector3도 되고 { X = 1, Y = 2, Z = 3 } 표도 된다). 각도는 라디안.
--
-- 들어 있는 것
--   horizontalDistance, sortByDistance: 얼음 표시를 실제 수평 거리로 정렬 (Rules와 같은 동률 규칙: 이름 오름차순)
--   fitScale: 모델 경계 크기를 표시 Part 바닥 넓이(와 높이 상한)에 맞추는 균일 배율
--   slotGrid: 바닥 넓이 안 패널 슬롯 격자 (개수는 인자)
--   groundFromSamples, foundation, snapDelta: 지면 높이 샘플로 바닥 맞춤
--   riseOffset, buildFraction, visibleSegments: 건설 진행 연출
--   renderedSize, worldExtents: 표시 Part의 실제 렌더 크기(원기둥, 공)와 회전된 월드 경계 크기
--   yawToward, snapAngle, faceToward: 문과 시설 정면 방향
--   pathPoints, pointInBox, facilityDefId
--   insideBounds, spreadOffset, exitPoint: 완공 순간 구조물 안에 있는 플레이어를 바깥으로 (갇힘 방지)
--   segmentHitsBox: 수평 선분이 상자를 지나는지 (로버 길과 태양광 판 겹침 검사)

local WorldMath = {}

export type XZ = { X: number, Z: number }
export type Vec3 = { X: number, Y: number, Z: number }
export type Footprint = { X: number, Z: number, Y: number? } -- Y가 있으면 높이 상한

export type Sorted = {
    index: number, -- 정렬 뒤 순서 (1 = 가장 가까움)
    name: string,
    position: any, -- 입력 그대로 (Vector3 또는 표)
    distance: number,
}

export type Slot = {
    index: number,
    row: number,
    col: number,
    x: number, -- 바닥 중심 기준 로컬 x
    z: number, -- 바닥 중심 기준 로컬 z
    sizeX: number,
    sizeZ: number,
}

local EPSILON = 1e-9
local MIN_EXTENT = 0.01 -- 0으로 나누지 않게 하는 최소 길이

function WorldMath.clamp01(value: number): number
    if value ~= value then
        return 0
    end
    return math.clamp(value, 0, 1)
end

function WorldMath.lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

-- 수평(X, Z) 거리. 높이 차이는 무시한다
function WorldMath.horizontalDistance(a: XZ, b: XZ): number
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- 이름과 위치 목록을 from에서의 수평 거리 오름차순으로 정렬한 새 목록. 입력은 바꾸지 않는다.
-- 거리가 같으면 이름 오름차순 (Rules.newState의 얼음 정렬과 같은 규칙이라 siteIndex가 일치한다)
function WorldMath.sortByDistance(items: { { name: string, position: any } }, from: XZ): { Sorted }
    local result: { Sorted } = {}
    for _, item in items do
        table.insert(result, {
            index = 0,
            name = item.name,
            position = item.position,
            distance = WorldMath.horizontalDistance(item.position, from),
        })
    end
    table.sort(result, function(a, b)
        if math.abs(a.distance - b.distance) <= EPSILON then
            return a.name < b.name
        end
        return a.distance < b.distance
    end)
    for i, entry in result do
        entry.index = i
    end
    return result
end

-- 모델 경계 크기(size)를 바닥 넓이(box.X, box.Z)와 높이 상한(box.Y, 선택) 안에 넣는 균일 배율.
-- minScale, maxScale이 있으면 그 범위로 자른다 (예: 키우지 않으려면 maxScale = 1)
function WorldMath.fitScale(
    size: Vec3,
    box: Footprint,
    minScale: number?,
    maxScale: number?
): number
    local factor =
        math.min(box.X / math.max(size.X, MIN_EXTENT), box.Z / math.max(size.Z, MIN_EXTENT))
    if box.Y ~= nil then
        factor = math.min(factor, box.Y / math.max(size.Y, MIN_EXTENT))
    end
    if minScale ~= nil then
        factor = math.max(factor, minScale)
    end
    if maxScale ~= nil then
        factor = math.min(factor, maxScale)
    end
    return factor
end

-- 바닥 넓이 footX x footZ 안에 count개 슬롯 격자를 만든다 (바닥 중심 기준 로컬 좌표).
-- 가장자리 margin, 슬롯 사이 gap. 열 수는 "가장 큰 정사각형이 들어가는 칸"이 되게 고르고,
-- 같으면 빈 칸이 적은 쪽. 순서는 -z 줄부터, 줄 안에서는 -x부터
function WorldMath.slotGrid(
    footX: number,
    footZ: number,
    count: number,
    margin: number,
    gap: number
): { Slot }
    local result: { Slot } = {}
    if count <= 0 then
        return result
    end
    local usableX = math.max(footX - 2 * margin, MIN_EXTENT)
    local usableZ = math.max(footZ - 2 * margin, MIN_EXTENT)
    local bestCols, bestScore, bestEmpty = 1, -math.huge, math.huge
    for cols = 1, count do
        local rows = math.ceil(count / cols)
        local cellX = (usableX - (cols - 1) * gap) / cols
        local cellZ = (usableZ - (rows - 1) * gap) / rows
        local score = math.min(cellX, cellZ)
        local empty = cols * rows - count
        if
            score > bestScore + EPSILON
            or (math.abs(score - bestScore) <= EPSILON and empty < bestEmpty)
        then
            bestCols, bestScore, bestEmpty = cols, score, empty
        end
    end
    local cols = bestCols
    local rows = math.ceil(count / cols)
    local cellX = math.max((usableX - (cols - 1) * gap) / cols, MIN_EXTENT)
    local cellZ = math.max((usableZ - (rows - 1) * gap) / rows, MIN_EXTENT)
    local startX = -usableX / 2 + cellX / 2
    local startZ = -usableZ / 2 + cellZ / 2
    for i = 1, count do
        local row = math.floor((i - 1) / cols) + 1
        local col = (i - 1) % cols + 1
        table.insert(result, {
            index = i,
            row = row,
            col = col,
            x = startX + (col - 1) * (cellX + gap),
            z = startZ + (row - 1) * (cellZ + gap),
            sizeX = cellX,
            sizeZ = cellZ,
        })
    end
    return result
end

-- 지면 높이 샘플(없는 값은 nil)에서 하나를 고른다. mode: "min" | "max" | "average" | "first"
-- 샘플이 하나도 없으면 fallback
function WorldMath.groundFromSamples(samples: { number? }, mode: string, fallback: number): number
    local found: { number } = {}
    -- 일반 반복은 nil 구멍을 건너뛰고 모든 값을 본다 (#samples는 구멍에서 끊길 수 있다)
    for _, value in samples do
        if value ~= nil and value == value then
            table.insert(found, value)
        end
    end
    if #found == 0 then
        return fallback
    end
    if mode == "max" then
        return math.max(table.unpack(found))
    elseif mode == "average" then
        local sum = 0
        for _, value in found do
            sum += value
        end
        return sum / #found
    elseif mode == "first" then
        return found[1]
    end
    return math.min(table.unpack(found))
end

-- 고르지 않은 지면 위 기초 판: 윗면 = 가장 높은 샘플 + lift (지형이 바닥을 뚫고 올라오지 않게),
-- 밑면 = 가장 낮은 샘플 - sink (낮은 쪽이 떠 보이지 않게). 반환: 윗면, 밑면
function WorldMath.foundation(
    samples: { number? },
    fallback: number,
    lift: number,
    sink: number
): (number, number)
    local top = WorldMath.groundFromSamples(samples, "max", fallback) + lift
    local bottom = WorldMath.groundFromSamples(samples, "min", fallback) - sink
    return top, math.min(bottom, top - MIN_EXTENT)
end

-- 바닥 높이 bottomY인 물체를 지면 groundY에 sink만큼 묻히게 놓으려면 세로로 얼마나 옮기는지
function WorldMath.snapDelta(groundY: number, bottomY: number, sink: number?): number
    return groundY - (sink or 0) - bottomY
end

-- 건설 진행률에 따른 세로 오프셋: 0이면 완전히 묻힘(-height), 1이면 0 (v1 Construction.riseOffset과 같다)
function WorldMath.riseOffset(height: number, progress: number): number
    return -height * (1 - WorldMath.clamp01(progress))
end

-- Rules 시설의 남은 일수로 건설 진행률 (0..1). buildDays가 0 이하면 1
function WorldMath.buildFraction(daysLeft: number, buildDays: number): number
    if buildDays <= 0 then
        return 1
    end
    return WorldMath.clamp01(1 - daysLeft / buildDays)
end

-- 진행률 progress에서 보이는 구간 수 (파이프 관로가 기지에서 얼음 쪽으로 늘어난다)
function WorldMath.visibleSegments(count: number, progress: number): number
    return math.clamp(math.floor(count * WorldMath.clamp01(progress) + EPSILON), 0, count)
end

-- 표시 Part가 실제로 그려지는 로컬 크기. 원기둥은 X가 축이고 지름은 Y, Z 중 작은 값, 공은 세 값 중 작은 값
function WorldMath.renderedSize(size: Vec3, shape: string): Vec3
    if shape == "Cylinder" then
        local d = math.min(size.Y, size.Z)
        return { X = size.X, Y = d, Z = d }
    elseif shape == "Ball" then
        local d = math.min(size.X, size.Y, size.Z)
        return { X = d, Y = d, Z = d }
    end
    return { X = size.X, Y = size.Y, Z = size.Z }
end

-- 로컬 크기 size를 회전 축(right, up, back = 로컬 X, Y, Z의 월드 방향)으로 돌렸을 때의 월드 축 경계 크기
function WorldMath.worldExtents(size: Vec3, right: Vec3, up: Vec3, back: Vec3): Vec3
    return {
        X = math.abs(right.X) * size.X + math.abs(up.X) * size.Y + math.abs(back.X) * size.Z,
        Y = math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y + math.abs(back.Y) * size.Z,
        Z = math.abs(right.Z) * size.X + math.abs(up.Z) * size.Y + math.abs(back.Z) * size.Z,
    }
end

-- Roblox CFrame.Angles(0, yaw, 0)의 LookVector가 (dirX, dirZ)를 보게 하는 yaw.
-- LookVector = (-sin yaw, 0, -cos yaw) 이므로 yaw = atan2(-dirX, -dirZ). 방향이 0이면 0
function WorldMath.yawOfDirection(dirX: number, dirZ: number): number
    if math.abs(dirX) < EPSILON and math.abs(dirZ) < EPSILON then
        return 0
    end
    return math.atan2(-dirX, -dirZ)
end

-- from에서 to를 바라보는 yaw
function WorldMath.yawToward(from: XZ, to: XZ): number
    return WorldMath.yawOfDirection(to.X - from.X, to.Z - from.Z)
end

-- 각도를 step 배수로 맞춘다 (step이 0 이하면 그대로). 결과는 -pi..pi
function WorldMath.snapAngle(angle: number, step: number): number
    local value = angle
    if step > 0 then
        value = math.floor(angle / step + 0.5) * step
    end
    while value > math.pi + EPSILON do
        value -= 2 * math.pi
    end
    while value < -math.pi - EPSILON do
        value += 2 * math.pi
    end
    return value
end

-- 반폭 halfX, halfZ인 바닥 사각형(로컬)에서 방향 (dirX, dirZ)와 가장 잘 맞는 면.
-- 반환: 면 바깥 법선 (nx, nz)와 중심에서 그 면까지 거리
function WorldMath.faceToward(
    halfX: number,
    halfZ: number,
    dirX: number,
    dirZ: number
): (number, number, number)
    if math.abs(dirX) >= math.abs(dirZ) then
        local sign = if dirX >= 0 then 1 else -1
        return sign, 0, halfX
    end
    local sign = if dirZ >= 0 then 1 else -1
    return 0, sign, halfZ
end

-- a에서 b까지 수평 경로를 segmentLength 이하 간격으로 나눈 점 목록 (양 끝 포함, 최소 2점)
function WorldMath.pathPoints(a: XZ, b: XZ, segmentLength: number): { XZ }
    local distance = WorldMath.horizontalDistance(a, b)
    local count = math.max(1, math.ceil(distance / math.max(segmentLength, MIN_EXTENT)))
    local points: { XZ } = {}
    for i = 0, count do
        local t = i / count
        table.insert(points, { X = WorldMath.lerp(a.X, b.X, t), Z = WorldMath.lerp(a.Z, b.Z, t) })
    end
    return points
end

-- 로컬 좌표 점이 크기 size인 상자(중심 원점) 안인지 (경계 포함)
function WorldMath.pointInBox(localPoint: Vec3, size: Vec3): boolean
    return math.abs(localPoint.X) <= size.X / 2
        and math.abs(localPoint.Y) <= size.Y / 2
        and math.abs(localPoint.Z) <= size.Z / 2
end

-- 로컬 좌표 점이 경계 lo..hi 안인지. 수평은 margin만큼 넓히고, 세로는 lo.Y - margin부터 hi.Y + headroom까지.
-- 캐릭터 HumanoidRootPart는 발보다 약 3 높아서 낮은 구조물(패널)도 headroom으로 잡는다 (갇힘 검사)
function WorldMath.insideBounds(
    p: Vec3,
    lo: Vec3,
    hi: Vec3,
    margin: number,
    headroom: number
): boolean
    return p.X >= lo.X - margin
        and p.X <= hi.X + margin
        and p.Z >= lo.Z - margin
        and p.Z <= hi.Z + margin
        and p.Y >= lo.Y - margin
        and p.Y <= hi.Y + headroom
end

-- 여러 명을 나란히 내보낼 때 i번째(1부터) 옆 간격: 0, +s, -s, +2s, -2s ...
function WorldMath.spreadOffset(i: number, spacing: number): number
    if i <= 1 then
        return 0
    end
    local step = math.floor(i / 2)
    local sign = if i % 2 == 0 then 1 else -1
    return sign * step * spacing
end

-- 갇힌 점을 경계 lo..hi 바깥으로 내보낼 로컬 수평 위치.
-- mode "front": 정면(-Z 면) 바깥 clearance, 옆 위치는 가운데 + lateral (경계 폭 안으로 자른다)
-- mode "nearest": 가장 가까운 옆면 바깥 clearance (다른 축 위치는 그대로)
-- 반환: 위치 XZ와 바깥 방향 (dirX, dirZ)
function WorldMath.exitPoint(
    p: XZ,
    lo: XZ,
    hi: XZ,
    clearance: number,
    mode: string,
    lateral: number?
): (XZ, number, number)
    if mode == "nearest" then
        local options = {
            { d = p.X - lo.X, x = lo.X - clearance, z = p.Z, dx = -1, dz = 0 },
            { d = hi.X - p.X, x = hi.X + clearance, z = p.Z, dx = 1, dz = 0 },
            { d = p.Z - lo.Z, x = p.X, z = lo.Z - clearance, dx = 0, dz = -1 },
            { d = hi.Z - p.Z, x = p.X, z = hi.Z + clearance, dx = 0, dz = 1 },
        }
        local best = options[1]
        for _, option in options do
            if option.d < best.d then
                best = option
            end
        end
        return { X = best.x, Z = best.z }, best.dx, best.dz
    end
    local x = math.clamp((lo.X + hi.X) / 2 + (lateral or 0), lo.X, math.max(lo.X, hi.X))
    return { X = x, Z = lo.Z - clearance }, 0, -1
end

-- 수평 선분 a-b가 원점 중심, 반폭 halfX, halfZ인 상자(로컬 좌표)를 지나는지 (경로 검사, 슬랩 방식)
function WorldMath.segmentHitsBox(a: XZ, b: XZ, halfX: number, halfZ: number): boolean
    local t0, t1 = 0, 1
    local d = { X = b.X - a.X, Z = b.Z - a.Z }
    for _, axis in { "X", "Z" } do
        local half = if axis == "X" then halfX else halfZ
        local start = (a :: any)[axis]
        local delta = (d :: any)[axis]
        if math.abs(delta) < 1e-9 then
            if start < -half or start > half then
                return false
            end
        else
            local ta = (-half - start) / delta
            local tb = (half - start) / delta
            if ta > tb then
                ta, tb = tb, ta
            end
            t0 = math.max(t0, ta)
            t1 = math.min(t1, tb)
            if t0 > t1 then
                return false
            end
        end
    end
    return true
end

-- Rules 시설 인스턴스 id에서 정의 id. Rules는 첫 파이프를 "pipe", 둘째부터 "pipe2", "pipe3"로 부른다
-- ("pipe" -> "pipe", "pipe2" -> "pipe", "pipe1" -> "pipe", "led" -> "led")
function WorldMath.facilityDefId(facilityId: string): string
    local base = string.match(facilityId, "^(.-)%d+$")
    if base and base ~= "" then
        return base
    end
    return facilityId
end

-- 같은 정의의 몇 번째 인스턴스인지 ("pipe" -> 1, "pipe2" -> 2, "pipe1" -> 1). 여러 개를 나란히 놓을 때 쓴다
function WorldMath.facilityIndex(facilityId: string): number
    local digits = string.match(facilityId, "^.-(%d+)$")
    local n = if digits and digits ~= facilityId then tonumber(digits) else nil
    return math.max(1, n or 1)
end

return WorldMath
