--!strict
-- 플레이어별 기여도 (2026-10-19 16차). 서버 메모리, 게임마다 초기화한다.
-- 각 시스템의 성공 지점에서 add를 부르고, GameFlow가 결과 화면(GameOverInfo.crew)과 승리 기록 이름에 쓴다.
-- 나간 플레이어도 표에 남는다 (UserId로 기억, 이름은 마지막 DisplayName)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

export type Field = "panels" | "water" | "builds" | "repairs" | "deaths"

type Row = Types.CrewRow & { order: number }

local Contributions = {}

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
        panels = 0,
        water = 0,
        builds = 0,
        repairs = 0,
        deaths = 0,
        order = nextOrder,
    }
    rows[player.UserId] = new
    return new
end

-- 새 게임 (beginNewGame)
function Contributions.reset()
    rows = {}
    nextOrder = 0
end

-- 아무것도 안 한 플레이어도 표에 나오게 행을 만든다 (플레이 시작, 게임 종료 때 현재 플레이어 전원)
function Contributions.ensure(player: Player)
    rowFor(player)
end

-- 성공 지점에서 가산. amount를 생략하면 1
function Contributions.add(player: Player?, field: Field, amount: number?)
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

-- 표 정렬용 기여 합 (물은 RECORDS.crewWaterWeight를 곱한다. 산소 고갈은 넣지 않는다)
function Contributions.score(row: Types.CrewRow): number
    return row.panels + row.builds + row.repairs + row.water * Config.RECORDS.crewWaterWeight
end

-- 기여 합이 큰 순(같으면 먼저 들어온 순) 표. limit을 넘는 행은 뺀다
function Contributions.crew(limit: number?): { Types.CrewRow }
    local list: { Row } = {}
    for _, row in rows do
        table.insert(list, row)
    end
    table.sort(list, function(a: Row, b: Row): boolean
        local sa, sb = Contributions.score(a), Contributions.score(b)
        if sa ~= sb then
            return sa > sb
        end
        return a.order < b.order
    end)
    local out: { Types.CrewRow } = {}
    local max = limit or #list
    for i, row in list do
        if i > max then
            break
        end
        table.insert(out, {
            name = row.name,
            panels = row.panels,
            water = math.floor(row.water + 0.5),
            builds = row.builds,
            repairs = row.repairs,
            deaths = row.deaths,
        })
    end
    return out
end

-- 기여 순 이름 목록 (승리 기록용)
function Contributions.names(limit: number): { string }
    local names = {}
    for _, row in Contributions.crew(limit) do
        table.insert(names, row.name)
    end
    return names
end

return Contributions
