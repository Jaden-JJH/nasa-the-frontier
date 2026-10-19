--!strict
-- 승리 기록 랭킹 순수 로직 (2026-10-19 16차). Roblox API를 쓰지 않는다 (Lune 단위 테스트 대상)
-- 정렬: 소요 일수 오름차순, 같으면 먼저 세운 기록(at 오름차순)이 앞.
-- 서버 Records(DataStore 병합과 메모리 대체)와 클라이언트 ResultUI가 같이 쓴다 (17차부터 결과 화면에만 표시).

-- 아래 typeof(require(...))는 타입 검사 전용이며 실행 시에는 평가되지 않는다.
type Config = typeof(require("./Config"))

export type Entry = {
    days: number, -- 승리까지 걸린 일수 (GameOverInfo.day)
    site: string, -- 착륙지 이름
    crew: { string }, -- 승무원 이름 (기여 순, 최대 RECORDS.crewNameLimit)
    at: number, -- 기록 시각 os.time()
    version: number, -- 항목 형식 버전 (RECORDS.version)
}

local Ranking = {}

local function isWholeNumber(value: any): boolean
    return type(value) == "number" and value == value and value % 1 == 0
end

-- 저장소에서 읽은 값이나 새 항목이 올바른 형식인지. 잘못된 항목은 목록에서 빠진다
function Ranking.isValid(entry: any): boolean
    if type(entry) ~= "table" then
        return false
    end
    if not isWholeNumber(entry.days) or entry.days < 1 then
        return false
    end
    if type(entry.site) ~= "string" then
        return false
    end
    if type(entry.at) ~= "number" or entry.at ~= entry.at then
        return false
    end
    if type(entry.crew) ~= "table" then
        return false
    end
    for _, name in entry.crew do
        if type(name) ~= "string" then
            return false
        end
    end
    return true
end

-- a가 b보다 앞 순위인지 (같은 기록이면 false)
function Ranking.before(a: Entry, b: Entry): boolean
    if a.days ~= b.days then
        return a.days < b.days
    end
    return a.at < b.at
end

-- 같은 기록인지 (UpdateAsync 재시도로 두 번 들어가지 않게)
function Ranking.same(a: Entry, b: Entry): boolean
    if a.days ~= b.days or a.at ~= b.at or a.site ~= b.site or #a.crew ~= #b.crew then
        return false
    end
    for i, name in a.crew do
        if b.crew[i] ~= name then
            return false
        end
    end
    return true
end

-- 항목 복사 (crew도 새 표)
function Ranking.copyEntry(entry: Entry): Entry
    return {
        days = entry.days,
        site = entry.site,
        crew = table.clone(entry.crew),
        at = entry.at,
        version = if type(entry.version) == "number" then entry.version else 1,
    }
end

-- 저장된 값(형식을 모름)을 올바른 항목만 정렬해 maxEntries개까지 새 목록으로
function Ranking.sanitize(raw: any, maxEntries: number): { Entry }
    local out: { Entry } = {}
    if type(raw) ~= "table" then
        return out
    end
    for _, entry in raw do
        if Ranking.isValid(entry) then
            local copy = Ranking.copyEntry(entry)
            local duplicate = false
            for _, existing in out do
                if Ranking.same(existing, copy) then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                table.insert(out, copy)
            end
        end
    end
    table.sort(out, Ranking.before)
    while #out > maxEntries do
        table.remove(out)
    end
    return out
end

-- 목록에서 entry의 순위 (없으면 nil)
function Ranking.find(list: { Entry }, entry: Entry): number?
    for i, existing in list do
        if Ranking.same(existing, entry) then
            return i
        end
    end
    return nil
end

-- 새 기록을 넣은 새 목록과 그 순위. 상위 maxEntries 밖이면 순위 nil, 잘못된 항목이면 목록만 정리해 돌려준다.
-- 같은 일수면 먼저 세운 기록이 앞이므로, 새 항목은 자기보다 확실히 늦은 기록 앞에만 들어간다
function Ranking.insert(list: { Entry }, entry: any, maxEntries: number): ({ Entry }, number?)
    local out = Ranking.sanitize(list, maxEntries)
    if not Ranking.isValid(entry) then
        return out, nil
    end
    local new = Ranking.copyEntry(entry)
    local existing = Ranking.find(out, new)
    if existing then
        return out, existing
    end
    local index = #out + 1
    for i, other in out do
        if Ranking.before(new, other) then
            index = i
            break
        end
    end
    if index > maxEntries then
        return out, nil
    end
    table.insert(out, index, new)
    while #out > maxEntries do
        table.remove(out)
    end
    return out, index
end

-- 기록 날짜 "월/일" (RECORDS.utcOffsetHours 기준)
function Ranking.dateText(at: number, config: Config): string
    local d = os.date("!*t", math.floor(at + config.RECORDS.utcOffsetHours * 3600))
    return string.format(config.TEXTS.recordDate, d.month, d.day)
end

-- 승무원 이름 요약: 앞 RECORDS.crewShowNames명 + "외 n명"
function Ranking.crewText(crew: { string }, config: Config): string
    local shown = math.min(#crew, config.RECORDS.crewShowNames)
    local names = {}
    for i = 1, shown do
        table.insert(names, crew[i])
    end
    local joined = table.concat(names, config.TEXTS.listSeparator)
    if #crew > shown then
        return string.format(config.TEXTS.recordCrewMore, joined, #crew - shown)
    end
    return joined
end

-- 목록 한 줄: "1위  32일  Shackleton Rim  Alice, Bob 외 1명  10/19"
function Ranking.formatLine(entry: Entry, rank: number, config: Config): string
    return string.format(
        config.TEXTS.recordLine,
        rank,
        entry.days,
        entry.site,
        Ranking.crewText(entry.crew, config),
        Ranking.dateText(entry.at, config)
    )
end

-- 이름과 착륙지 글자 수 제한 (utf8 글자 단위, 깨진 문자열은 바이트 단위로 자른다)
function Ranking.clip(text: string, maxLength: number): string
    local ok, length = pcall(utf8.len, text)
    if not ok or type(length) ~= "number" then
        return string.sub(text, 1, maxLength)
    end
    if length <= maxLength then
        return text
    end
    local cut = utf8.offset(text, maxLength + 1)
    if cut == nil then
        return text
    end
    return string.sub(text, 1, cut - 1)
end

return Ranking
