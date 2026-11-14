--!strict
-- v2 플레이어별 기여도 (docs/CONTRACT_V2.md 2.2 Contributions "v1 재사용 + 역할", 6절 MissionResult.crew).
-- v1 Contributions와 같은 방식(서버 메모리, 판마다 초기화, 나간 플레이어도 남는다)에 역할과 산소 구조 횟수를 더했다.
-- v1 모듈은 v1 Config와 Types에 묶여 있어 v2용으로 따로 둔다.

export type Field = "panels" | "water" | "builds" | "repairs" | "rescues"

export type CrewRow = {
    userId: number, -- 결과 화면에서 내 줄 찾기 (개인 정보 아님, Roblox 공개 id)
    name: string,
    role: string?, -- "controller" | "explorer" | "engineer" | "solo"
    panels: number,
    water: number,
    builds: number,
    repairs: number,
    rescues: number,
}

type Row = CrewRow & { order: number }

local ContributionsV2 = {}

-- 표 정렬용 기여 합에서 물 1의 무게 (v1 RECORDS.crewWaterWeight: 물 10 = 패널 1장)
ContributionsV2.CONFIG = { waterWeight = 0.1 }

local rows: { [number]: Row } = {}
local nextOrder = 0

local function rowFor(player: Player): Row
    local row = rows[player.UserId]
    if row then
        row.name = player.DisplayName
        return row
    end
    nextOrder += 1
    local new: Row = {
        name = player.DisplayName,
        role = nil,
        panels = 0,
        water = 0,
        builds = 0,
        repairs = 0,
        rescues = 0,
        order = nextOrder,
        userId = player.UserId,
    }
    rows[player.UserId] = new
    return new
end

function ContributionsV2.reset()
    rows = {}
    nextOrder = 0
end

-- 아무것도 안 한 플레이어도 표에 나오게
function ContributionsV2.ensure(player: Player)
    rowFor(player)
end

function ContributionsV2.add(player: Player?, field: Field, amount: number?)
    if not player then
        return
    end
    local value = amount or 1
    if value <= 0 then
        return
    end
    local row = rowFor(player)
    row[field] += value
end

-- 지금 역할 (나간 뒤에도 마지막 역할이 남는다)
function ContributionsV2.setRole(player: Player, role: string?)
    rowFor(player).role = role
end

local function score(row: CrewRow): number
    return row.panels + row.builds + row.repairs + row.water * ContributionsV2.CONFIG.waterWeight
end

local function sorted(): { Row }
    local list: { Row } = {}
    for _, row in rows do
        table.insert(list, row)
    end
    table.sort(list, function(a: Row, b: Row): boolean
        local sa, sb = score(a), score(b)
        if sa ~= sb then
            return sa > sb
        end
        return a.order < b.order
    end)
    return list
end

-- 기여 합이 큰 순(같으면 먼저 들어온 순) 표. limit을 넘는 행은 뺀다
function ContributionsV2.crew(limit: number?): { CrewRow }
    local out: { CrewRow } = {}
    for i, row in sorted() do
        if limit and i > limit then
            break
        end
        table.insert(out, {
            userId = row.userId,
            name = row.name,
            role = row.role,
            panels = row.panels,
            water = math.floor(row.water + 0.5),
            builds = row.builds,
            repairs = row.repairs,
            rescues = row.rescues,
        })
    end
    return out
end

-- 기여 순 { userId, name } (기록 저장용)
function ContributionsV2.members(limit: number?): { { userId: number, name: string } }
    local out = {}
    for i, row in sorted() do
        if limit and i > limit then
            break
        end
        table.insert(out, { userId = row.userId, name = row.name })
    end
    return out
end

return ContributionsV2
