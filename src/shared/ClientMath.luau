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
--   costShortfall: 프롬프트 건설비 줄에서 빨갛게 보일 자원 (Affordable, 지금 자원)
--   roverChargeView, batteryMsg, chargeLabel: 로버 충전 표시 (HUD 칩, 로버 머리 위 표지, 안내 카드)
--   rectDistance, pickNearest, buildingInfo: 건물 안내 카드 (가장 가까운 건물, 상태 줄, 하루 유지비)
--   roleMissionOf, normalizeRoleMission, scoutTargets: 멀티 역할 미션 (HUD 카드, 정찰 표시, 결과 배지)
--   iceNumber, iceLabel, iceEntry: 얼음 후보지 표시 번호 (모든 화면 "Ice Site N", N = 표시 번호, 정렬 순서 아님)
-- 화면 문구는 Msg 모양 표({ key, args })로만 돌려준다. 키는 i18n/strings.csv에 있어야 한다(lint 검사).

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

-- 자율주행 지도 아이콘의 왕복 진행(0..1). 서버가 rover.fsd에 오늘 구간(mapFrom, mapTo, mapFromAt, mapToAt, 서버 시각)을
-- 보내면 now(workspace:GetServerTimeNow())에 맞춰 그 사이를 잇는다. 없으면 Rules 하루 단위 progress 그대로
-- (예전처럼 파견 전에 지난 하루 몫을 더하면 보내자마자 아이콘이 얼음 후보지에 가 있었다, 2026-11-15 플레이 테스트)
function ClientMath.fsdMapProgress(fsd: any, now: any): number
    if type(fsd) ~= "table" then
        return 0
    end
    local from, to, fromAt, toAt = fsd.mapFrom, fsd.mapTo, fsd.mapFromAt, fsd.mapToAt
    if
        isNumber(from)
        and isNumber(to)
        and isNumber(fromAt)
        and isNumber(toAt)
        and isNumber(now)
    then
        local span = toAt - fromAt
        local t = if span > 1e-6 then math.clamp((now - fromAt) / span, 0, 1) else 1
        return math.clamp(from + (to - from) * t, 0, 1)
    end
    return if isNumber(fsd.progress) then math.clamp(fsd.progress, 0, 1) else 0
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

-- 프롬프트 건설비 ------------------------------------------------------------------

-- 비용과 유지비 숫자 글자. 소수 둘째 자리까지 반올림하고 끝의 0을 뗀다 (60, 3.6, 0.25). 잘못된 값은 "0"
function ClientMath.formatAmount(value: any): string
    if not isNumber(value) then
        return "0"
    end
    local rounded = math.round(value * 100) / 100
    if rounded == math.floor(rounded) then
        return tostring(math.floor(rounded))
    end
    local text = string.format("%.2f", rounded)
    return (string.gsub(text, "0+$", ""))
end

export type Shortfall = { energy: boolean, water: boolean }

-- 건설비 줄에서 빨갛게 보일 자원. affordable: 서버 Attribute(true | false | nil), resources: 지금 자원(없으면 nil),
-- locked: 잠김 사유(LockMsg)가 있는지. 서버가 살 수 있다고 하면 아무것도 빨갛지 않다(비상 패널처럼 규칙 예외가 있다).
-- 살 수 없으면 모자란 자원만 빨갛게, 자원을 모르거나 모자란 것이 없으면 비용이 있는 자원 전부.
-- 단, 잠김 때문에 못 사는 것이고 자원은 충분하면 빨갛게 하지 않는다(잠김 줄이 이유를 말한다).
function ClientMath.costShortfall(
    cost: { energy: any, water: any },
    resources: any,
    affordable: any,
    locked: boolean?
): Shortfall
    local out = { energy = false, water = false }
    if affordable == true then
        return out
    end
    local e = if isNumber(cost.energy) then cost.energy else 0
    local w = if isNumber(cost.water) then cost.water else 0
    local known = type(resources) == "table"
    if known then
        out.energy = e > 0 and isNumber(resources.energy) and resources.energy + EPSILON < e
        out.water = w > 0 and isNumber(resources.water) and resources.water + EPSILON < w
    end
    if affordable == false and not out.energy and not out.water and not (locked and known) then
        out.energy = e > 0
        out.water = w > 0
    end
    return out
end

-- 로버 충전 ------------------------------------------------------------------------

export type ChargeView = {
    mode: string, -- "hidden" | "driving" | "away" | "charging" | "full" | "blocked"
    percent: number, -- 0..100 정수 (내림, 가득 찬 것만 100)
    reason: string?, -- mode "blocked"일 때 "energy" | "pad" | "seat"
}

local CHARGE_REASONS = { energy = true, pad = true, seat = true }
-- 서버가 보내는 막힌 이유 문구 키 -> 이유 (섀시 ChargeBlocked 문자열, StateUpdate rover.chargeBlocked Msg)
local BLOCKED_KEYS = {
    energy = "hud.rover.charge_blocked_energy",
    pad = "hud.rover.charge_blocked_pad",
    seat = "hud.rover.charge_blocked_seat",
}
local REASON_OF_KEY = {
    [BLOCKED_KEYS.energy] = "energy",
    [BLOCKED_KEYS.pad] = "pad",
    [BLOCKED_KEYS.seat] = "seat",
}

-- 막힌 이유 값(이유 이름, 문구 키, 또는 { key } Msg)을 이유 이름으로. 모르면 nil
function ClientMath.chargeReason(value: any): string?
    if type(value) == "table" then
        value = value.key
    end
    if type(value) ~= "string" then
        return nil
    end
    if CHARGE_REASONS[value] then
        return value
    end
    return REASON_OF_KEY[value]
end

-- 로버 충전 표시 상태. info:
--   status(rover.state), atBase, charging, battery, batteryMax: StateUpdate rover
--   percent(섀시 BatteryPercent), blocked(rover.chargeBlocked Msg 또는 섀시 ChargeBlocked 문구 키): 서버 값이 있으면 우선
--   energy(기지 에너지), keep(MANUAL_DRIVE.chargeKeepEnergy), localDriving(내가 운전석)
--   serverReasons: 서버가 충전판 위의 막힌 이유(energy, seat)를 보내는지 (rover.batteryPercent가 있으면 true)
-- 서버가 이유를 보내는데 비어 있으면 충전판 밖(pad)이다. 서버가 이유를 모르는 옛 모양이면 짐작한다:
-- 누가 타고 있으면 seat, 기지 에너지가 keep 이하면 energy, 아니면 pad
function ClientMath.roverChargeView(info: { [string]: any }): ChargeView
    local status = info.status
    if status == "fsd" or status == "broken" then
        return { mode = "hidden", percent = 0, reason = nil }
    end
    local percent
    if isNumber(info.percent) then
        percent = math.clamp(math.floor(info.percent + EPSILON), 0, 100)
    else
        percent = math.floor(ClientMath.ratio(info.battery, info.batteryMax) * 100 + EPSILON)
    end
    local full = percent >= 100
        or (
            isNumber(info.battery)
            and isNumber(info.batteryMax)
            and info.batteryMax > 0
            and info.battery >= info.batteryMax - EPSILON
        )
    if full then
        percent = 100
    end
    if info.localDriving == true then
        return { mode = "driving", percent = percent, reason = nil }
    end
    if info.charging == true then
        return { mode = "charging", percent = percent, reason = nil }
    end
    if info.atBase ~= true then
        return { mode = "away", percent = percent, reason = nil }
    end
    if full then
        return { mode = "full", percent = percent, reason = nil }
    end
    local reason = ClientMath.chargeReason(info.blocked) or "pad"
    if reason == "pad" and info.serverReasons ~= true and info.blocked == nil then
        -- 옛 모양: 서버가 이유를 보내지 않으니 짐작한다
        if status == "driving" then
            reason = "seat"
        elseif
            isNumber(info.energy)
            and isNumber(info.keep)
            and info.energy <= info.keep + EPSILON
        then
            reason = "energy"
        end
    end
    return { mode = "blocked", percent = percent, reason = reason }
end

-- "Battery 72%" (hud.battery.value에 unit.percent를 넣는다)
function ClientMath.batteryMsg(percent: number): { [string]: any }
    return {
        key = "hud.battery.value",
        args = { n = { key = "unit.percent", args = { n = ClientMath.wholeNumber(percent) } } },
    }
end

-- 충전 상태 한 줄 (없으면 nil). long이면 에너지 부족을 "기지 에너지가 keep 이하이면 멈춘다"로 풀어 쓴다
function ClientMath.chargeLabel(view: ChargeView, keep: number?, long: boolean?): { [string]: any }?
    if view.mode == "charging" then
        return { key = "hud.battery.charging" }
    elseif view.mode == "full" then
        return { key = "hud.battery.full" }
    elseif view.mode == "blocked" then
        if view.reason == "energy" and long then
            return {
                key = "hud.battery.energy_hint",
                args = { keep = ClientMath.wholeNumber(keep) },
            }
        end
        if view.reason == "energy" then
            return { key = BLOCKED_KEYS.energy, args = { keep = ClientMath.wholeNumber(keep) } }
        end
        return { key = BLOCKED_KEYS[view.reason or "pad"] or BLOCKED_KEYS.pad }
    end
    return nil
end

-- 건물 안내 카드 ----------------------------------------------------------------------

-- 화면 사각형 { x0, y0, x1, y1 } 두 개가 겹치는지 (margin만큼 넓혀서 본다)
function ClientMath.rectsOverlap(
    a: { [string]: number },
    b: { [string]: number },
    margin: number?
): boolean
    local m = margin or 0
    return a.x0 - m < b.x1 and b.x0 - m < a.x1 and a.y0 - m < b.y1 and b.y0 - m < a.y1
end

-- 가로세로 반폭 halfX, halfZ인 사각형(로컬 좌표, 중심 0)까지 수평 거리. 안이면 0
function ClientMath.rectDistance(
    localX: number,
    localZ: number,
    halfX: number,
    halfZ: number
): number
    local dx = math.max(math.abs(localX) - math.max(halfX, 0), 0)
    local dz = math.max(math.abs(localZ) - math.max(halfZ, 0), 0)
    return math.sqrt(dx * dx + dz * dz)
end

-- 가장 가까운 건물 id. distances: { [id]: 거리 }. maxDistance 안의 가장 가까운 것.
-- 지금 보이는 카드(currentId)는 maxDistance + hysteresis 안에 있고 1등보다 hysteresis 넘게 멀어지지 않으면 유지한다
-- (두 건물 사이에서 카드가 깜빡이지 않게). 같은 거리면 id 순서로 정한다
function ClientMath.pickNearest(
    distances: { [string]: number },
    maxDistance: number,
    currentId: string?,
    hysteresis: number?
): (string?, number?)
    local margin = hysteresis or 0
    local bestId, bestDistance = nil, math.huge
    for id, d in distances do
        if
            isNumber(d)
            and (d < bestDistance or (d == bestDistance and bestId ~= nil and id < bestId))
        then
            bestId, bestDistance = id, d
        end
    end
    local current = if currentId then distances[currentId] else nil
    if currentId and isNumber(current) then
        local d = current :: number
        if d <= maxDistance + margin and d <= bestDistance + margin then
            return currentId, d
        end
    end
    if bestId and bestDistance <= maxDistance then
        return bestId, bestDistance
    end
    return nil, nil
end

export type BuildingInfo = {
    status: { [string]: any }?, -- 상태 줄 Msg
    tone: string, -- 색: "neutral" | "locked" | "available" | "building" | "inspecting" | "idle" | "active" | "paused" | "stalled"
    detail: { [string]: any }?, -- 덧붙이는 줄 Msg (잠김 사유, 수확, 정지 이유, 충전)
    upkeep: { energy: number, water: number }?, -- 하루 유지비 (없거나 0이면 nil)
}

local FACILITY_STATUS_KEYS = {
    locked = "map.fac.status.locked",
    available = "map.fac.status.available",
    active = "map.fac.status.active",
    paused = "map.fac.status.paused",
    idle = "map.fac.status.idle",
}
local FACILITY_COUNT_KEYS = {
    building = "map.fac.status.building",
    inspecting = "map.fac.status.inspecting",
}
local STALL_DETAIL_KEYS = { energy = "hud.stalled.energy", water = "hud.stalled.water" }
local FACILITY_INFO_IDS = {
    farm = true,
    led = true,
    nutrient = true,
    hydroponics = true,
    pipe = true,
}
local UPGRADE_INFO_IDS = { led = true, nutrient = true, hydroponics = true }

local function isMsgTable(value: any): boolean
    return type(value) == "table" and type(value.key) == "string" and value.key ~= ""
end

-- 시설 화면 상태 (정의 id로). 첫 인스턴스 id는 정의 id와 같고 둘째부터 pipe2처럼 숫자가 붙는다
local function facilityView(state: any, defId: string): any
    local list = if type(state.facilities) == "table" then state.facilities else {}
    local direct = list[defId]
    if type(direct) == "table" then
        return direct
    end
    local bestId, best = nil, nil
    for id, f in list do
        if
            type(id) == "string"
            and type(f) == "table"
            and string.match(id, "^" .. defId .. "%d+$")
            and (bestId == nil or id < bestId)
        then
            bestId, best = id, f
        end
    end
    return best
end

local function facilityStatusMsg(status: string, daysLeft: any): { [string]: any }
    local countKey = FACILITY_COUNT_KEYS[status]
    if countKey then
        return { key = countKey, args = { count = ClientMath.wholeNumber(daysLeft) } }
    end
    return { key = FACILITY_STATUS_KEYS[status] or FACILITY_STATUS_KEYS.locked }
end

-- 하루 유지비. 멈춤이면 없다. 서버가 보낸 지금 유지비(LED 전력, 영양분 절약 반영)가 있으면 그것, 아니면 정의 값
local function upkeepOf(view: any, def: any, status: string?): { energy: number, water: number }?
    if status == "paused" then
        return nil
    end
    local e, w = 0, 0
    local live = if type(view) == "table" and type(view.upkeep) == "table" then view.upkeep else nil
    local liveE = if live and isNumber(live.energy) then live.energy else 0
    local liveW = if live and isNumber(live.water) then live.water else 0
    if liveE > 0 or liveW > 0 then
        e, w = liveE, liveW
    elseif type(def) == "table" and type(def.upkeep) == "table" then
        e = if isNumber(def.upkeep.energy) then def.upkeep.energy else 0
        w = if isNumber(def.upkeep.water) then def.upkeep.water else 0
    end
    if e <= 0 and w <= 0 then
        return nil
    end
    return { energy = e, water = w }
end

local function stallDetail(state: any): { [string]: any }
    return { key = STALL_DETAIL_KEYS[state.stallReason] or "hud.stalled" }
end

-- 건물 안내 카드의 상태. id: "lander" | "airlock" | "solar" | "farm" | "led" | "nutrient" | "hydroponics" | "tank"
-- | "pipe" | "roverpark" | "exit". state: 마지막 StateUpdate, missionDef: MissionConfig.MISSIONS[id],
-- extra: { keep = MANUAL_DRIVE.chargeKeepEnergy, localDriving = 내가 운전석, percent?, blocked? } (로버 주차장)
function ClientMath.buildingInfo(
    id: string,
    rawState: any,
    missionDef: any,
    extra: { [string]: any }?
): BuildingInfo
    local out: BuildingInfo = { status = nil, tone = "neutral", detail = nil, upkeep = nil }
    local state = if type(rawState) == "table" then rawState else {}
    local defs = if type(missionDef) == "table" and type(missionDef.facilities) == "table"
        then missionDef.facilities
        else {}
    local opts = extra or {}

    if id == "airlock" then
        local airlock = if type(state.airlock) == "table" then state.airlock else {}
        local status = if type(airlock.status) == "string" then airlock.status else "idle"
        out.status = facilityStatusMsg(status, airlock.daysLeft)
        out.tone = status
        if airlock.stalled == true then
            out.tone = "stalled"
            out.detail = stallDetail(state)
        end
        out.upkeep = upkeepOf(nil, defs.airlock, status)
    elseif FACILITY_INFO_IDS[id] then
        local view = facilityView(state, id)
        if view == nil then
            out.upkeep = upkeepOf(nil, defs[id], nil)
            return out
        end
        local status = if type(view.status) == "string" then view.status else "locked"
        out.status = facilityStatusMsg(status, view.daysLeft)
        out.tone = status
        if status == "locked" and isMsgTable(view.unlockMsg) then
            out.detail = view.unlockMsg
        elseif status == "active" then
            if id == "farm" and isNumber(view.nextHarvestIn) then
                out.detail = {
                    key = "map.fac.harvest",
                    args = { count = ClientMath.wholeNumber(view.nextHarvestIn) },
                }
            elseif id == "pipe" and isNumber(view.nextDeliveryIn) then
                out.detail = {
                    key = "info.pipe.next",
                    args = { count = ClientMath.wholeNumber(view.nextDeliveryIn) },
                }
            elseif UPGRADE_INFO_IDS[id] then
                -- 업그레이드는 그린하우스가 돌아갈 때만 효과와 유지비가 있다
                local farm = facilityView(state, "farm")
                if type(farm) ~= "table" or farm.status ~= "active" or farm.stalled == true then
                    out.tone = "paused"
                    out.detail = { key = "info.status.farm_off" }
                end
            end
        end
        if view.stalled == true then
            out.tone = "stalled"
            out.detail = stallDetail(state)
        end
        out.upkeep = upkeepOf(view, defs[id], status)
    elseif id == "solar" then
        local panels = state.panels
        if type(panels) == "table" and isNumber(panels.total) then
            local installed = ClientMath.wholeNumber(panels.installed)
            local total = ClientMath.wholeNumber(panels.total)
            out.status =
                { key = "info.solar_field.status", args = { installed = installed, total = total } }
            out.tone = if installed >= total then "active" else "available"
        end
    elseif id == "tank" then
        local pipe = facilityView(state, "pipe")
        if type(pipe) == "table" and pipe.status == "locked" and isMsgTable(pipe.unlockMsg) then
            out.detail = pipe.unlockMsg
            out.tone = "locked"
        end
    elseif id == "roverpark" then
        local rover = state.rover
        if type(rover) == "table" then
            if rover.state == "broken" then
                out.status = { key = "hud.rover.broken" }
                out.tone = "stalled"
            elseif rover.state == "fsd" then
                local fsd = if type(rover.fsd) == "table" then rover.fsd else {}
                out.status = {
                    key = if fsd.recovering
                        then "hud.rover.recovering"
                        elseif fsd.stoppedBy then "hud.rover.stopped"
                        else "hud.rover.out",
                }
                out.tone = "building"
            else
                local resources = if type(state.resources) == "table" then state.resources else {}
                local view = ClientMath.roverChargeView({
                    status = rover.state,
                    atBase = rover.atBase,
                    charging = rover.charging,
                    battery = rover.battery,
                    batteryMax = rover.batteryMax,
                    percent = if opts.percent ~= nil then opts.percent else rover.batteryPercent,
                    blocked = if opts.blocked ~= nil then opts.blocked else rover.chargeBlocked,
                    serverReasons = type(rover.batteryPercent) == "number",
                    energy = resources.energy,
                    keep = opts.keep,
                    localDriving = opts.localDriving,
                })
                out.status = ClientMath.batteryMsg(view.percent)
                out.detail = ClientMath.chargeLabel(view, opts.keep, true)
                if view.mode == "away" then
                    out.detail = { key = "map.rover.driving" }
                end
                out.tone = if view.mode == "charging"
                    then "building"
                    elseif view.mode == "full" then "active"
                    elseif view.mode == "blocked" then (if view.reason == "energy"
                        then "stalled"
                        else "paused")
                    else "neutral"
            end
        end
    end
    return out
end

-- 역할 미션 (멀티 전용, 점수와 무관) ------------------------------------------------

-- 미션 id -> 문구 키 (리터럴 키 표, I18N_PLAN 4.2)
ClientMath.ROLE_MISSION_KEYS = {
    water = { badge = "rolemission.water.badge", desc = "rolemission.water.desc" },
    panels = { badge = "rolemission.panels.badge", desc = "rolemission.panels.desc" },
    guide = { badge = "rolemission.guide.badge", desc = "rolemission.guide.desc" },
    scout = { badge = "rolemission.scout.badge", desc = "rolemission.scout.desc" },
}

export type RoleMission = {
    id: string,
    progress: number, -- 0..goal 정수
    goal: number, -- 1 이상
    done: boolean,
    ratio: number, -- 0..1
}

-- 서버 역할 미션 한 줄을 화면용으로. 모르는 id나 잘못된 값이면 nil. 끝났으면 진행을 goal로 맞춘다
function ClientMath.normalizeRoleMission(raw: any): RoleMission?
    if
        type(raw) ~= "table"
        or type(raw.id) ~= "string"
        or not ClientMath.ROLE_MISSION_KEYS[raw.id]
    then
        return nil
    end
    local goal = math.max(1, ClientMath.wholeNumber(raw.goal))
    local progress = math.min(ClientMath.wholeNumber(raw.progress), goal)
    local done = raw.done == true or progress >= goal
    if done then
        progress = goal
    end
    return { id = raw.id, progress = progress, goal = goal, done = done, ratio = progress / goal }
end

-- 그 플레이어의 역할 미션 (StateUpdate.roleMissions[tostring(userId)]). 솔로이거나 없으면 nil
function ClientMath.roleMissionOf(state: any, userId: number?): RoleMission?
    if type(state) ~= "table" or state.mode == "solo" or type(state.roleMissions) ~= "table" then
        return nil
    end
    if userId == nil then
        return nil
    end
    local list = state.roleMissions
    local raw = list[tostring(userId)]
    if raw == nil then
        raw = list[userId]
    end
    return ClientMath.normalizeRoleMission(raw)
end

export type ScoutTarget = { x: number, z: number, key: string?, mark: string, radius: number? }

-- 정찰 미션에서 아직 안 간 자리 (좌표가 있는 것만). 정찰이 아니거나 끝났으면 빈 목록.
-- mark는 표시를 다시 만들지 않게 쓰는 이름 (좌표를 정수로 반올림), radius는 서버 방문 판정 거리(stud, 없으면 nil)
function ClientMath.scoutTargets(raw: any): { ScoutTarget }
    local out: { ScoutTarget } = {}
    local mission = ClientMath.normalizeRoleMission(raw)
    if not mission or mission.id ~= "scout" or mission.done or type(raw.targets) ~= "table" then
        return out
    end
    for _, target in raw.targets do
        if
            type(target) == "table"
            and target.visited ~= true
            and isNumber(target.x)
            and isNumber(target.z)
        then
            table.insert(out, {
                x = target.x,
                z = target.z,
                key = if type(target.key) == "string" and target.key ~= "" then target.key else nil,
                mark = string.format("%d,%d", math.round(target.x), math.round(target.z)),
                radius = if isNumber(raw.radius) and raw.radius > 0 then raw.radius else nil,
            })
        end
    end
    return out
end

-- 얼음 후보지 표시 번호 -------------------------------------------------------------
-- 리드 결정(2026-11-15): 모든 화면의 "Ice Site N"은 표시 이름의 번호(Ice4 -> 4)다. siteIndex(출구에서 가까운 순)가 아니다.
-- 서버 ice[i].number를 쓰고, 없으면 markerName의 숫자, 그것도 없으면 index

function ClientMath.iceNumber(site: any): number
    if type(site) ~= "table" then
        return 0
    end
    if isNumber(site.number) then
        return ClientMath.wholeNumber(site.number)
    end
    if type(site.markerName) == "string" then
        local digits = tonumber(string.match(site.markerName, "(%d+)$"))
        if digits then
            return digits
        end
    end
    return ClientMath.wholeNumber(site.index)
end

-- "Ice Site N" Msg (map.ice.label)
function ClientMath.iceLabel(site: any): { [string]: any }
    return { key = "map.ice.label", args = { n = ClientMath.iceNumber(site) } }
end

-- 물 파이프 지점을 지금 고를 수 있는지: 파이프가 해금(available)됐고 아직 지점이 없다. 역할과 무관
-- (CONTRACT_V2 9.1 7번 SetPipeSite는 역할 제한 없음. 지도 전체 보기와 핀만 관제사 전용, Q25)
function ClientMath.pipePickOpen(state: any): boolean
    if type(state) ~= "table" or state.pipeSite ~= nil or type(state.facilities) ~= "table" then
        return false
    end
    local pipe = state.facilities.pipe
    return type(pipe) == "table" and pipe.status == "available"
end

-- 지도 없이 고르는 파이프 지점 목록 (관제사가 아닌 멀티 대원): 파이프가 아직 없는 얼음 후보지, siteIndex(가까운) 순.
-- 고를 수 없으면 빈 표
function ClientMath.pipePickSites(state: any): { any }
    local out = {}
    if not ClientMath.pipePickOpen(state) or type(state.ice) ~= "table" then
        return out
    end
    for _, site in state.ice do
        if type(site) == "table" and isNumber(site.index) and site.pipe ~= true then
            table.insert(out, site)
        end
    end
    table.sort(out, function(a, b)
        return a.index < b.index
    end)
    return out
end

-- siteIndex(정렬 순서, 핀과 파견이 쓰는 번호)로 StateUpdate ice 항목 찾기. 없으면 nil
function ClientMath.iceEntry(state: any, siteIndex: any): any
    if type(state) ~= "table" or type(state.ice) ~= "table" or siteIndex == nil then
        return nil
    end
    for _, site in state.ice do
        if type(site) == "table" and site.index == siteIndex then
            return site
        end
    end
    return nil
end

return ClientMath
