--!strict
-- 규칙 수치 내보내기 (V2_PLAN 15.12 Q22). 저장소 루트에서 실행한다.
--   lune run tools/rules/export.luau          src/shared/MissionConfig.luau -> data/rules_v2.json
--   lune run tools/rules/export.luau --check  다시 만든 결과가 파일과 같은지만 확인 (CI용, 파일을 쓰지 않음)
-- --check에서 다르거나 파일이 없으면 종료 코드 1.
--
-- 웹판(PlayCanvas, Mahi)이 Roblox판과 같은 숫자를 쓰도록 MissionConfig를 그대로 JSON으로 옮긴다.
-- - 키 이름과 구조는 MissionConfig와 같다 (웹판 코드와 1:1). 맨 위에 schemaVersion, generatedFrom, generatedBy.
-- - 함수와 Roblox 전용 값(숫자, 문자열, 불, 표가 아닌 값)은 빼고, 뺀 경로를 출력한다.
-- - 결정적 출력: 객체 키는 바이트 순서로 정렬, 숫자는 되읽으면 같은 값이 되는 가장 짧은 표기, 시각 같은 값은 넣지 않는다.
-- - 빈 표는 배열 [] 로 쓴다 (MissionConfig의 빈 표는 requires, iceSites 같은 목록뿐이다).
-- - derived: Rules.luau로 계산한 값(걸어서 수리 한도, 지점별 왕복 계획). 웹판 구현 검산용이며 MissionConfig에는 없는 키다.
-- 필드 설명은 data/README_rules.md.

local fs = require("@lune/fs")
local process = require("@lune/process")

local MissionConfig = require("../../src/shared/MissionConfig")
local Rules = require("../../src/shared/Rules")

local OUTPUT_PATH = "data/rules_v2.json"
local SCHEMA_VERSION = 1
local META_ORDER = { "schemaVersion", "generatedFrom", "generatedBy" }

local checkOnly = table.find(process.args, "--check") ~= nil
local skipped: { string } = {}

local function isPlain(value: any): boolean
    local kind = type(value)
    return kind == "number" or kind == "string" or kind == "boolean" or kind == "table"
end

-- 배열이면 길이, 아니면 nil (1..n 정수 키만 있을 때 배열)
local function arrayLength(t: { [any]: any }): number?
    local count = 0
    for key in t do
        if type(key) ~= "number" then
            return nil
        end
        count += 1
    end
    for i = 1, count do
        if t[i] == nil then
            return nil
        end
    end
    return count
end

local function encodeString(text: string): string
    local out = string.gsub(text, '[%c"\\]', function(c: string): string
        if c == '"' then
            return '\\"'
        elseif c == "\\" then
            return "\\\\"
        elseif c == "\n" then
            return "\\n"
        elseif c == "\r" then
            return "\\r"
        elseif c == "\t" then
            return "\\t"
        end
        return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. out .. '"'
end

local function encodeNumber(n: number, path: string): string
    if n ~= n or n == math.huge or n == -math.huge then
        error("JSON에 쓸 수 없는 숫자: " .. path)
    end
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
        return string.format("%d", n)
    end
    local text = string.format("%.15g", n)
    if tonumber(text) ~= n then
        text = string.format("%.17g", n)
    end
    return text
end

local encode: (value: any, path: string, indent: string, keyOrder: { string }?) -> string

local function scalarArray(t: { any }, length: number): boolean
    for i = 1, length do
        if type(t[i]) == "table" then
            return false
        end
    end
    return true
end

local function sortedKeys(t: { [any]: any }, path: string, first: { string }?): { string }
    local keys = {}
    for key, value in t do
        if type(key) ~= "string" then
            error("문자열이 아닌 키가 섞인 표: " .. path)
        end
        if isPlain(value) then
            if not (first and table.find(first, key)) then
                table.insert(keys, key)
            end
        else
            table.insert(skipped, path .. "." .. key .. " (" .. typeof(value) .. ")")
        end
    end
    table.sort(keys)
    if first then
        for i = #first, 1, -1 do
            if t[first[i]] ~= nil then
                table.insert(keys, 1, first[i])
            end
        end
    end
    return keys
end

encode = function(value: any, path: string, indent: string, keyOrder: { string }?): string
    local kind = type(value)
    if kind == "number" then
        return encodeNumber(value, path)
    elseif kind == "string" then
        return encodeString(value)
    elseif kind == "boolean" then
        return if value then "true" else "false"
    elseif kind ~= "table" then
        error("JSON에 쓸 수 없는 값: " .. path)
    end
    local inner = indent .. "  "
    local length = arrayLength(value)
    if length then
        if length == 0 then
            return "[]"
        end
        local parts = {}
        if scalarArray(value, length) then
            for i = 1, length do
                table.insert(parts, encode(value[i], path .. "[" .. i .. "]", inner))
            end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        for i = 1, length do
            table.insert(parts, inner .. encode(value[i], path .. "[" .. i .. "]", inner))
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end
    local parts = {}
    for _, key in sortedKeys(value, path, keyOrder) do
        table.insert(
            parts,
            inner .. encodeString(key) .. ": " .. encode(value[key], path .. "." .. key, inner)
        )
    end
    if #parts == 0 then
        return "{}"
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

-- 웹판 검산용 계산값 (Rules.luau와 같은 결과가 나와야 한다)
local function derived(): { [string]: any }
    local missions = {}
    for id, def in MissionConfig.MISSIONS :: { [string]: any } do
        if def.playable then
            local state = Rules.newState(id, MissionConfig, 1, nil)
            local sites = {}
            for index, site in state.sites do
                local trip = Rules.tripPlan(state, MissionConfig, index, false) :: Rules.TripPlan
                local rush = Rules.tripPlan(state, MissionConfig, index, true) :: Rules.TripPlan
                local function plan(p: Rules.TripPlan)
                    return {
                        days = p.days,
                        rawDays = p.rawDays,
                        energy = p.energy,
                        risk = p.risk,
                        damageChance = p.damageChance,
                        rushHelps = p.rushHelps,
                    }
                end
                table.insert(sites, {
                    siteIndex = index,
                    id = site.id,
                    distance = site.distance,
                    risk = site.risk,
                    trip = plan(trip),
                    rushTrip = plan(rush),
                })
            end
            missions[id] = { sites = sites }
        end
    end
    return {
        walkRepairLimit = Rules.walkRepairLimit(MissionConfig),
        missions = missions,
    }
end

local root: { [string]: any } = table.clone(MissionConfig :: { [string]: any })
root.schemaVersion = SCHEMA_VERSION
root.generatedFrom = "src/shared/MissionConfig.luau"
root.generatedBy = "tools/rules/export.luau"
root.derived = derived()

local content = encode(root, "MissionConfig", "", META_ORDER) .. "\n"

for _, path in skipped do
    print("[rules] 뺀 값: " .. path)
end

if checkOnly then
    if not fs.isFile(OUTPUT_PATH) or fs.readFile(OUTPUT_PATH) ~= content then
        print(
            "[rules] "
                .. OUTPUT_PATH
                .. " 이 MissionConfig와 다릅니다. lune run tools/rules/export.luau 로 다시 만드세요."
        )
        process.exit(1)
    end
    print("[rules] --check 통과: " .. OUTPUT_PATH .. " 이 MissionConfig와 같습니다.")
    process.exit(0)
end

local same = fs.isFile(OUTPUT_PATH) and fs.readFile(OUTPUT_PATH) == content
if not same then
    fs.writeFile(OUTPUT_PATH, content)
end
print(string.format("[rules] %s %s", OUTPUT_PATH, if same then "(변경 없음)" else "생성"))
