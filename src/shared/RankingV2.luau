--!strict
-- v2 순위 순수 로직 (docs/CONTRACT_V2.md 2.1 Ranking "정렬 기준만 v2", 7절 저장, V2_PLAN Q5, Q24).
-- Roblox API를 쓰지 않는다 (Lune 단위 테스트 tests/ranking_v2.spec.luau). 서버 RecordsV2가 DataStore 병합과 메모리 대체에 쓴다.
-- v1 Ranking(소요 일수 순)은 v1 결과 화면이 쓰므로 그대로 두고, v2는 이 모듈을 쓴다.
--
-- 미션 순위 한 줄 (FrontierRecordsV2, 키 mission_<id>): 한 판 = 한 줄
--   { medal, score, days, crew = { 이름 최대 4 }, mode = "solo" | "multi", players, at, missionId, version = 2 }
--   정렬: 메달(금 > 은 > 동) > 점수 높은 순 > 걸린 일수 적은 순 > 먼저 세운 기록
-- 전체 리더보드 한 줄 (FrontierLeaderboardV2, 키 global): 플레이어 한 명 = 한 줄
--   { userId, name, goldMissions, bestScoreSum, missions = { [missionId] = { medal, score } } }
--   goldMissions = 금메달을 딴 미션 수, bestScoreSum = 미션별 최고 점수 합 (팀 금메달은 팀원 모두에게 인정, Q5)
--   정렬: goldMissions > bestScoreSum > userId (같으면 작은 userId가 앞, 결정적)

export type MissionEntry = {
    medal: string,
    score: number,
    days: number,
    crew: { string },
    mode: string,
    players: number,
    at: number,
    missionId: string,
    version: number,
}

export type MissionBest = { medal: string, score: number }

export type GlobalEntry = {
    userId: number,
    name: string,
    goldMissions: number,
    bestScoreSum: number,
    missions: { [string]: MissionBest },
}

export type Run = {
    missionId: string,
    medal: string,
    score: number,
    members: { { userId: number, name: string } },
}

local RankingV2 = {}

RankingV2.VERSION = 2
RankingV2.MEDAL_RANK = { gold = 3, silver = 2, bronze = 1 } :: { [string]: number }
RankingV2.NAME_MAX = 20 -- 저장하는 이름 글자 수 상한 (DataStore 크기 보호)
RankingV2.CREW_MAX = 4 -- 한 줄에 저장하는 팀원 이름 수 (Q5)

local function isWhole(value: any): boolean
    return type(value) == "number" and value == value and value % 1 == 0
end

local function isNumber(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- 이름을 max 글자(UTF-8 코드 포인트)까지 자른다
function RankingV2.clip(text: string, max: number?): string
    local limit = max or RankingV2.NAME_MAX
    local length = utf8.len(text)
    if length == nil then
        return string.sub(text, 1, limit)
    end
    if length <= limit then
        return text
    end
    local cut = utf8.offset(text, limit + 1)
    return string.sub(text, 1, (cut or (#text + 1)) - 1)
end

function RankingV2.medalRank(medal: any): number
    return RankingV2.MEDAL_RANK[medal] or 0
end

-- 미션 순위 ----------------------------------------------------------------

function RankingV2.isMissionEntry(entry: any): boolean
    if type(entry) ~= "table" then
        return false
    end
    if RankingV2.medalRank(entry.medal) == 0 then
        return false
    end
    if not isNumber(entry.score) or not isWhole(entry.days) or entry.days < 0 then
        return false
    end
    if not isNumber(entry.at) or type(entry.missionId) ~= "string" then
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

function RankingV2.copyMission(entry: MissionEntry): MissionEntry
    return {
        medal = entry.medal,
        score = entry.score,
        days = entry.days,
        crew = table.clone(entry.crew),
        mode = if entry.mode == "multi" then "multi" else "solo",
        players = if isWhole(entry.players) and entry.players >= 1 then entry.players else 1,
        at = entry.at,
        missionId = entry.missionId,
        version = RankingV2.VERSION,
    }
end

-- a가 b보다 앞인지
function RankingV2.missionBefore(a: MissionEntry, b: MissionEntry): boolean
    local ma, mb = RankingV2.medalRank(a.medal), RankingV2.medalRank(b.medal)
    if ma ~= mb then
        return ma > mb
    end
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.days ~= b.days then
        return a.days < b.days
    end
    return a.at < b.at
end

function RankingV2.sameMission(a: MissionEntry, b: MissionEntry): boolean
    if
        a.medal ~= b.medal
        or a.score ~= b.score
        or a.days ~= b.days
        or a.at ~= b.at
        or a.missionId ~= b.missionId
        or #a.crew ~= #b.crew
    then
        return false
    end
    for i, name in a.crew do
        if b.crew[i] ~= name then
            return false
        end
    end
    return true
end

-- 저장된 값(형식 모름)에서 올바른 항목만 정렬해 max개까지
function RankingV2.sanitizeMission(raw: any, max: number): { MissionEntry }
    local list: { MissionEntry } = {}
    if type(raw) == "table" then
        for _, entry in raw do
            if RankingV2.isMissionEntry(entry) then
                table.insert(list, RankingV2.copyMission(entry))
            end
        end
    end
    table.sort(list, RankingV2.missionBefore)
    while #list > max do
        table.remove(list)
    end
    return list
end

function RankingV2.findMission(list: { MissionEntry }, entry: MissionEntry): number?
    for i, other in list do
        if RankingV2.sameMission(other, entry) then
            return i
        end
    end
    return nil
end

-- 새 목록에 넣는다 (같은 기록이 이미 있으면 그대로). 반환: 새 목록, 순위(max 밖이면 nil)
function RankingV2.insertMission(
    list: { MissionEntry },
    entry: MissionEntry,
    max: number
): ({ MissionEntry }, number?)
    local merged: { MissionEntry } = {}
    for _, other in list do
        table.insert(merged, RankingV2.copyMission(other))
    end
    if not RankingV2.findMission(merged, entry) then
        table.insert(merged, RankingV2.copyMission(entry))
    end
    table.sort(merged, RankingV2.missionBefore)
    while #merged > max do
        table.remove(merged)
    end
    return merged, RankingV2.findMission(merged, entry)
end

-- 한 판 기록 만들기 (이름은 NAME_MAX 글자, 팀원은 CREW_MAX명까지)
function RankingV2.makeMission(
    missionId: string,
    medal: string,
    score: number,
    days: number,
    names: { string },
    mode: string,
    players: number,
    at: number
): MissionEntry
    local crew = {}
    for i, name in names do
        if i > RankingV2.CREW_MAX then
            break
        end
        table.insert(crew, RankingV2.clip(name))
    end
    return {
        medal = medal,
        score = score,
        days = days,
        crew = crew,
        mode = if mode == "multi" then "multi" else "solo",
        players = math.max(1, math.floor(players)),
        at = at,
        missionId = missionId,
        version = RankingV2.VERSION,
    }
end

-- 전체 리더보드 ---------------------------------------------------------------

local function recount(entry: GlobalEntry)
    local gold, sum = 0, 0
    for _, best in entry.missions do
        if best.medal == "gold" then
            gold += 1
        end
        sum += best.score
    end
    entry.goldMissions = gold
    entry.bestScoreSum = sum
end

function RankingV2.copyGlobal(entry: GlobalEntry): GlobalEntry
    local missions: { [string]: MissionBest } = {}
    for id, best in entry.missions do
        missions[id] = { medal = best.medal, score = best.score }
    end
    local copy: GlobalEntry = {
        userId = entry.userId,
        name = entry.name,
        goldMissions = 0,
        bestScoreSum = 0,
        missions = missions,
    }
    recount(copy)
    return copy
end

function RankingV2.isGlobalEntry(entry: any): boolean
    if type(entry) ~= "table" or not isWhole(entry.userId) or type(entry.name) ~= "string" then
        return false
    end
    if type(entry.missions) ~= "table" then
        return false
    end
    for id, best in entry.missions do
        if
            type(id) ~= "string"
            or type(best) ~= "table"
            or RankingV2.medalRank(best.medal) == 0
            or not isNumber(best.score)
        then
            return false
        end
    end
    return true
end

function RankingV2.globalBefore(a: GlobalEntry, b: GlobalEntry): boolean
    if a.goldMissions ~= b.goldMissions then
        return a.goldMissions > b.goldMissions
    end
    if a.bestScoreSum ~= b.bestScoreSum then
        return a.bestScoreSum > b.bestScoreSum
    end
    return a.userId < b.userId
end

function RankingV2.sanitizeGlobal(raw: any, max: number): { GlobalEntry }
    local list: { GlobalEntry } = {}
    local seen: { [number]: boolean } = {}
    if type(raw) == "table" then
        for _, entry in raw do
            if RankingV2.isGlobalEntry(entry) and not seen[entry.userId] then
                seen[entry.userId] = true
                table.insert(list, RankingV2.copyGlobal(entry))
            end
        end
    end
    table.sort(list, RankingV2.globalBefore)
    while #list > max do
        table.remove(list)
    end
    return list
end

-- 한 판 결과를 팀원 모두의 줄에 반영한다. 미션별로 더 좋은 기록(메달 > 점수)만 남긴다
function RankingV2.mergeRun(list: { GlobalEntry }, run: Run, max: number): { GlobalEntry }
    local byUser: { [number]: GlobalEntry } = {}
    local merged: { GlobalEntry } = {}
    for _, entry in list do
        local copy = RankingV2.copyGlobal(entry)
        byUser[copy.userId] = copy
        table.insert(merged, copy)
    end
    if RankingV2.medalRank(run.medal) > 0 then
        for _, member in run.members do
            local entry = byUser[member.userId]
            if not entry then
                local new: GlobalEntry = {
                    userId = member.userId,
                    name = RankingV2.clip(member.name),
                    goldMissions = 0,
                    bestScoreSum = 0,
                    missions = {},
                }
                byUser[member.userId] = new
                table.insert(merged, new)
                entry = new
            end
            local current: GlobalEntry = entry :: GlobalEntry
            current.name = RankingV2.clip(member.name)
            local best = current.missions[run.missionId]
            local better = best == nil
                or RankingV2.medalRank(run.medal) > RankingV2.medalRank(best.medal)
                or (
                    RankingV2.medalRank(run.medal) == RankingV2.medalRank(best.medal)
                    and run.score > best.score
                )
            if better then
                current.missions[run.missionId] = { medal = run.medal, score = run.score }
            end
            recount(current)
        end
    end
    table.sort(merged, RankingV2.globalBefore)
    while #merged > max do
        table.remove(merged)
    end
    return merged
end

function RankingV2.findUser(list: { GlobalEntry }, userId: number): (number?, GlobalEntry?)
    for i, entry in list do
        if entry.userId == userId then
            return i, entry
        end
    end
    return nil, nil
end

-- 화면용 한 줄 (missions 상세는 빼고 보낸다)
function RankingV2.publicGlobal(entry: GlobalEntry): { [string]: any }
    return {
        userId = entry.userId,
        name = entry.name,
        goldMissions = entry.goldMissions,
        bestScoreSum = entry.bestScoreSum,
    }
end

-- 플레이어의 미션별 최고 메달 { C = "silver" } (미션 선택 화면 배지, Q24)
function RankingV2.bestMedals(list: { GlobalEntry }, userId: number): { [string]: string }
    local _, entry = RankingV2.findUser(list, userId)
    local out: { [string]: string } = {}
    if entry then
        for id, best in entry.missions do
            out[id] = best.medal
        end
    end
    return out
end

return RankingV2
