--!strict
-- ClientMath: v2 클라이언트 화면 계산 순수 함수 모음 (Roblox 전역을 쓰지 않는다, Lune에서 그대로 테스트한다)
-- 좌표는 X, Z 필드를 가진 값이면 된다 (Vector3도 되고 { X = 1, Z = 2 } 표도 된다).
--
-- 들어 있는 것
--   wholeNumber, ratio, resourceLevel: 자원 숫자 표시 (상한 100, 20 미만 경고)
--   secondsLeft: 서버 시각 마감까지 남은 초 (미션 선택 30초, 역할 10초, 재시작, 프롬프트 쿨타임)
--   bounds, fitMap, project: 월드 XZ를 콘솔 지도 픽셀로 (위가 -Z, 오른쪽이 +X)
--   horizontalDistance, roundTripFraction, tripPoint: 자율주행 아이콘 위치
--   toMeters: stud 거리를 화면용 정수 미터로 (MissionConfig.metersPerStud, Rules.meters와 같은 반올림)
--   edgeArrow: 핀 화살표 A안 (화면 안이면 그 자리, 밖이면 가장자리 위치와 각도)
--   medalValue, bestMedal: 메달 비교
--   nextRisk, rushPreview: 서둘러 가기 미리보기 근사 (서버 값이 없을 때만)
--   rankRows: 순위표 상위 N과 "내 순위" 한 줄
--   normalizeRoles, roleCounts, roleCapacity: RoleUpdate 정리와 역할 자리 수 (서버 Roles와 같은 규칙)

local ClientMath = {}

export type XZ = { X: number, Z: number }
export type Bounds = { minX: number, minZ: number, maxX: number, maxZ: number }
export type MapFit = {
    bounds: Bounds,
    scale: number, -- 픽셀 / stud
    offsetX: number,
    offsetY: number,
    width: number,
    height: number,
}
export type Arrow = {
    onScreen: boolean,
    x: number,
    y: number,
    angle: number, -- 도. 0 = 화면 위쪽, 시계 방향 + (Roblox Rotation과 같은 방향)
}
export type RankRow = { rank: number, entry: any, mine: boolean }

local EPSILON = 1e-6
local MEDAL_VALUES = { gold = 3, silver = 2, bronze = 1 }

local function isNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- 화면에 쓰는 정수. 소수는 내림(20 미만 경고와 숫자가 어긋나지 않게), 음수와 잘못된 값은 0
function ClientMath.wholeNumber(value: any): number
    if not isNumber(value) then
        return 0
    end
    return math.max(0, math.floor(value + EPSILON))
end

-- 0..1 비율. max가 0 이하이거나 잘못되면 0
function ClientMath.ratio(value: any, max: any): number
    if not isNumber(value) or not isNumber(max) or max <= 0 then
        return 0
    end
    return math.clamp(value / max, 0, 1)
end

-- "zero" | "low" | "ok". low는 threshold 미만(감점선과 같은 기준, Q4)
function ClientMath.resourceLevel(value: any, threshold: number): string
    local n = if isNumber(value) then value else 0
    if n <= EPSILON then
        return "zero"
    elseif n < threshold then
        return "low"
    end
    return "ok"
end

-- 마감(서버 시각)까지 남은 초를 올림. 마감이 없거나 지났으면 0
function ClientMath.secondsLeft(deadline: any, now: number): number
    if not isNumber(deadline) or not isNumber(now) then
        return 0
    end
    return math.max(0, math.ceil(deadline - now - EPSILON))
end

-- 점들을 감싸는 경계. padding은 사방 여백(stud), minSpan은 한 변의 최소 길이(점이 하나일 때 대비)
function ClientMath.bounds(points: { XZ }, padding: number?, minSpan: number?): Bounds
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, p in points do
        if isNumber(p.X) and isNumber(p.Z) then
            minX = math.min(minX, p.X)
            minZ = math.min(minZ, p.Z)
            maxX = math.max(maxX, p.X)
            maxZ = math.max(maxZ, p.Z)
        end
    end
    if minX == math.huge then
        minX, minZ, maxX, maxZ = 0, 0, 0, 0
    end
    local pad = padding or 0
    minX -= pad
    minZ -= pad
    maxX += pad
    maxZ += pad
    local span = minSpan or 1
    if maxX - minX < span then
        local mid = (minX + maxX) / 2
        minX, maxX = mid - span / 2, mid + span / 2
    end
    if maxZ - minZ < span then
        local mid = (minZ + maxZ) / 2
        minZ, maxZ = mid - span / 2, mid + span / 2
    end
    return { minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ }
end

-- 경계를 width x height 픽셀 안에 비율을 지켜 가운데 맞춤
function ClientMath.fitMap(bounds: Bounds, width: number, height: number): MapFit
    local spanX = math.max(bounds.maxX - bounds.minX, EPSILON)
    local spanZ = math.max(bounds.maxZ - bounds.minZ, EPSILON)
    local w = math.max(width, 1)
    local h = math.max(height, 1)
    local scale = math.min(w / spanX, h / spanZ)
    return {
        bounds = bounds,
        scale = scale,
        offsetX = (w - spanX * scale) / 2,
        offsetY = (h - spanZ * scale) / 2,
        width = w,
        height = h,
    }
end

-- 월드 X, Z -> 지도 픽셀 x, y (좌상단 0, 0). 경계 밖이면 지도 밖 값이 나온다
function ClientMath.project(fit: MapFit, x: number, z: number): (number, number)
    local px = fit.offsetX + (x - fit.bounds.minX) * fit.scale
    local py = fit.offsetY + (z - fit.bounds.minZ) * fit.scale
    return px, py
end

-- 지도 픽셀을 지도 안으로 (아이콘이 가장자리 밖으로 나가지 않게)
function ClientMath.clampToMap(
    fit: MapFit,
    px: number,
    py: number,
    inset: number?
): (number, number)
    local pad = inset or 0
    return math.clamp(px, pad, fit.width - pad), math.clamp(py, pad, fit.height - pad)
end

function ClientMath.horizontalDistance(a: XZ, b: XZ): number
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- stud 거리 -> 정수 미터 (잘못된 값은 0). 배율이 없으면 1 stud = 1 m
function ClientMath.toMeters(studs: any, metersPerStud: number?): number
    if not isNumber(studs) then
        return 0
    end
    local factor = if isNumber(metersPerStud) then metersPerStud :: number else 1
    return math.max(0, math.round(studs * factor))
end

-- 왕복 진행 비율(0..1) -> 출발점에서 목표까지의 거리 비율. 0.5에서 목표(1), 0과 1에서 출발점(0)
-- (Rules의 고장 거리 계산 1 - |1 - 2p|와 같은 식)
function ClientMath.roundTripFraction(progress: any): number
    local p = if isNumber(progress) then math.clamp(progress, 0, 1) else 0
    return 1 - math.abs(1 - 2 * p)
end

-- from에서 to로 fraction(0..1)만큼 간 점
function ClientMath.tripPoint(from: XZ, to: XZ, fraction: number): XZ
    local f = math.clamp(if isNumber(fraction) then fraction else 0, 0, 1)
    return {
        X = from.X + (to.X - from.X) * f,
        Z = from.Z + (to.Z - from.Z) * f,
    }
end

-- 핀 화살표 A안. (x, y)는 WorldToViewportPoint 결과, inFront는 카메라 앞인지(Z > 0).
-- 화면 안(가장자리 margin 안쪽)이고 앞이면 onScreen = true, 그 자리를 돌려준다.
-- 아니면 화면 중심에서 그 방향으로 뻗은 선이 margin만큼 들어간 사각형과 만나는 점과 각도를 돌려준다.
-- 카메라 뒤의 점은 투영 좌표가 뒤집혀 나오므로 방향을 반대로 한다. 정확히 뒤면 아래를 가리킨다.
function ClientMath.edgeArrow(
    x: number,
    y: number,
    inFront: boolean,
    width: number,
    height: number,
    margin: number
): Arrow
    local cx, cy = width / 2, height / 2
    local halfW = math.max(cx - margin, 1)
    local halfH = math.max(cy - margin, 1)
    if inFront and x >= cx - halfW and x <= cx + halfW and y >= cy - halfH and y <= cy + halfH then
        return { onScreen = true, x = x, y = y, angle = 0 }
    end
    local dx, dy = x - cx, y - cy
    if not inFront then
        dx, dy = -dx, -dy
        if math.abs(dx) < EPSILON and math.abs(dy) < EPSILON then
            dx, dy = 0, 1
        end
    elseif math.abs(dx) < EPSILON and math.abs(dy) < EPSILON then
        dx, dy = 0, -1
    end
    local tx = if math.abs(dx) > EPSILON then halfW / math.abs(dx) else math.huge
    local ty = if math.abs(dy) > EPSILON then halfH / math.abs(dy) else math.huge
    local t = math.min(tx, ty)
    local angle = math.deg(math.atan2(dx, -dy))
    return { onScreen = false, x = cx + dx * t, y = cy + dy * t, angle = angle }
end

function ClientMath.medalValue(medal: any): number
    return MEDAL_VALUES[medal] or 0
end

-- 둘 중 더 좋은 메달 (없으면 nil)
function ClientMath.bestMedal(a: string?, b: string?): string?
    if ClientMath.medalValue(b) > ClientMath.medalValue(a) then
        return b
    end
    if ClientMath.medalValue(a) > 0 then
        return a
    end
    return nil
end

-- 위험 등급 한 단계 위 (order 끝이면 그대로)
function ClientMath.nextRisk(order: { string }, level: string): string
    local index = table.find(order, level) or 1
    return order[math.min(index + 1, #order)]
end

-- 서둘러 가기 미리보기 근사. 서버가 rushDays, rushEnergy, rushRisk를 보내지 않을 때만 쓴다.
-- days: 일반 왕복 일수, energy: 일반 비용, roverDef: MissionConfig 미션의 rover 표
function ClientMath.rushPreview(
    days: number,
    energy: number,
    risk: string,
    roverDef: any
): (number, number, string)
    local timeFactor = if roverDef and isNumber(roverDef.rushTimeFactor)
        then roverDef.rushTimeFactor
        else 1
    local energyFactor = if roverDef and isNumber(roverDef.rushEnergyFactor)
        then roverDef.rushEnergyFactor
        else 1
    local order = if roverDef and type(roverDef.riskOrder) == "table"
        then roverDef.riskOrder
        else { "low", "mid", "high", "extreme" }
    local rushDays = math.max(1, math.floor(days * timeFactor + 0.5))
    local rushEnergy = math.ceil(energy * energyFactor - EPSILON)
    return rushDays, rushEnergy, ClientMath.nextRisk(order, risk)
end

-- 순위표: 상위 limit개 행, 그리고 내 순위가 limit 밖이면 그 순위(아니면 nil)
function ClientMath.rankRows(
    entries: { any }?,
    limit: number,
    myRank: number?
): ({ RankRow }, number?)
    local rows: { RankRow } = {}
    local list = entries or {}
    for i = 1, math.min(limit, #list) do
        table.insert(rows, { rank = i, entry = list[i], mine = myRank == i })
    end
    local extra = if isNumber(myRank) and (myRank :: number) > limit then myRank else nil
    return rows, extra
end

-- RoleUpdate의 역할 표를 { [userId 숫자]: 역할 }로. 문자열 userId 키도 받는다
function ClientMath.normalizeRoles(raw: any): { [number]: string }
    local out: { [number]: string } = {}
    if type(raw) ~= "table" then
        return out
    end
    for key, role in raw do
        local id = tonumber(key)
        if id and type(role) == "string" then
            out[id] = role
        end
    end
    return out
end

-- 역할별 인원
function ClientMath.roleCounts(roles: { [number]: string }): { [string]: number }
    local counts: { [string]: number } = {}
    for _, role in roles do
        counts[role] = (counts[role] or 0) + 1
    end
    return counts
end

-- 인원 n명일 때 역할 자리 수 (V2_PLAN 15.3 Q25, 서버 Roles.capacity와 같은 규칙)
-- 관제사 1, 탐사대원 min(2, max(1, n - 1)), 엔지니어는 3명 이상일 때 1
function ClientMath.roleCapacity(role: string, n: number): number
    if role == "controller" then
        return 1
    elseif role == "explorer" then
        return math.min(2, math.max(1, n - 1))
    elseif role == "engineer" then
        return if n >= 3 then 1 else 0
    end
    return 0
end

return ClientMath
