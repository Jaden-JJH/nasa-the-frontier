--!strict
-- v2 기록 저장과 순위 송신 (docs/CONTRACT_V2.md 7절, 4.1 Records, V2_PLAN Q5, Q24).
--   FrontierRecordsV2      키 mission_<id>  상위 CONFIG.missionMax개 미션 순위 (RankingV2.MissionEntry)
--   FrontierLeaderboardV2  키 global        상위 CONFIG.globalMax명 전체 리더보드 (RankingV2.GlobalEntry)
-- v1 FrontierRecords는 읽지도 쓰지도 않는다.
-- 모든 DataStore 호출은 task.spawn 안에서 pcall + 1회 재시도 (v1 Records 방식). 서비스가 없거나(Lune, 게시 안 한 플레이스)
-- 호출이 실패하면(Studio API 접근 꺼짐) 서버 메모리 목록으로 바꾸고 status "offline"을 보낸다.
-- Records 페이로드는 플레이어마다 다르다(전체 순위의 "내 순위"): FireClient로 한 명씩 보낸다.
--   { missionId, mission = { entries, rank?, entry? }, global = { entries, rank?, mine? }, status, submitted }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RankingV2 = require(ReplicatedStorage.Shared.RankingV2)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local RecordsV2 = {}

-- 저장 설정 (엔진 수준 값, MissionConfig 밖)
RecordsV2.CONFIG = {
    enabled = true,
    recordsStore = "FrontierRecordsV2",
    leaderboardStore = "FrontierLeaderboardV2",
    globalKey = "global",
    missionMax = 10, -- 미션별 저장 줄 수 (계약 7절)
    globalMax = 50, -- 전체 리더보드 저장 줄 수 (계약 7절)
    sendMission = 10, -- 화면에 보내는 줄 수 (결과 화면은 5줄만 그린다, Q24)
    sendGlobal = 10,
    retryDelay = 1,
}

local CFG = RecordsV2.CONFIG

export type Status = "loading" | "ok" | "offline"

local missionLists: { [string]: { RankingV2.MissionEntry } } = {}
local globalList: { RankingV2.GlobalEntry } = {}
local status: Status = "loading"
local loaded = false
local initialized = false
local recordsStore: any = nil
local leaderboardStore: any = nil
local currentMission = "C"
-- 마지막 제출 (결과 화면에서 이번 판 순위를 다시 보낼 때)
local lastSubmitted: { missionId: string, entry: RankingV2.MissionEntry, rank: number? }? = nil

local function missionKey(missionId: string): string
    return "mission_" .. missionId
end

local function getStore(name: string): any
    local okService, service = pcall(function()
        return game:GetService("DataStoreService")
    end)
    if not okService or service == nil then
        return nil
    end
    local okStore, ds = pcall(function()
        return (service :: any):GetDataStore(name)
    end)
    if not okStore then
        return nil
    end
    return ds
end

local function withRetry(label: string, fn: () -> any): (boolean, any)
    local ok, result = pcall(fn)
    if ok then
        return true, result
    end
    task.wait(CFG.retryDelay)
    ok, result = pcall(fn)
    if not ok then
        warn(
            string.format(
                "[RecordsV2] %s 실패, 이번 서버 기록만 씁니다: %s",
                label,
                tostring(result)
            )
        )
    end
    return ok, result
end

local function goOffline()
    recordsStore = nil
    leaderboardStore = nil
    status = "offline"
end

local function listFor(missionId: string): { RankingV2.MissionEntry }
    local list = missionLists[missionId]
    if not list then
        list = {}
        missionLists[missionId] = list
    end
    return list
end

local function loadMission(missionId: string)
    local ds = recordsStore
    if not ds then
        return
    end
    local ok, raw = withRetry("GetAsync " .. missionKey(missionId), function()
        return ds:GetAsync(missionKey(missionId))
    end)
    if ok then
        missionLists[missionId] = RankingV2.sanitizeMission(raw, CFG.missionMax)
    else
        goOffline()
    end
end

-- 한 플레이어에게 보낼 페이로드
function RecordsV2.payload(
    player: Player?,
    missionId: string?,
    submitted: boolean?
): { [string]: any }
    local id = missionId or currentMission
    local entries = {}
    for i, entry in listFor(id) do
        if i > CFG.sendMission then
            break
        end
        table.insert(entries, RankingV2.copyMission(entry))
    end
    local mission: { [string]: any } = { entries = entries }
    local last = lastSubmitted
    if submitted and last and last.missionId == id then
        mission.rank = last.rank
        mission.entry = RankingV2.copyMission(last.entry)
    end
    local globalEntries = {}
    for i, entry in globalList do
        if i > CFG.sendGlobal then
            break
        end
        table.insert(globalEntries, RankingV2.publicGlobal(entry))
    end
    local global: { [string]: any } = { entries = globalEntries }
    if player then
        local rank, mine = RankingV2.findUser(globalList, player.UserId)
        global.rank = rank
        if mine then
            global.mine = { goldMissions = mine.goldMissions, bestScoreSum = mine.bestScoreSum }
        end
    end
    return {
        missionId = id,
        mission = mission,
        global = global,
        status = status,
        submitted = submitted == true,
    }
end

function RecordsV2.sendTo(player: Player, submitted: boolean?)
    if not loaded then
        return
    end
    Remotes.get("Records"):FireClient(player, RecordsV2.payload(player, nil, submitted))
end

local function sendAll(submitted: boolean)
    for _, player in Players:GetPlayers() do
        Remotes.get("Records"):FireClient(player, RecordsV2.payload(player, nil, submitted))
    end
end

function RecordsV2.isLoaded(): boolean
    return loaded
end

function RecordsV2.status(): Status
    return status
end

-- 플레이어 본인의 미션별 최고 메달 (기록을 불러오기 전이면 빈 표)
function RecordsV2.bestMedals(player: Player): { [string]: string }
    return RankingV2.bestMedals(globalList, player.UserId)
end

-- 지금 보여 줄 미션 (결과 화면과 입장 송신 기준)
function RecordsV2.setMission(missionId: string)
    currentMission = missionId
end

function RecordsV2.clearSubmitted()
    lastSubmitted = nil
end

local function load()
    if CFG.enabled then
        recordsStore = getStore(CFG.recordsStore)
        leaderboardStore = getStore(CFG.leaderboardStore)
    end
    if recordsStore and leaderboardStore then
        status = "ok"
        local ds = leaderboardStore
        local ok, raw = withRetry("GetAsync global", function()
            return ds:GetAsync(CFG.globalKey)
        end)
        if ok then
            globalList = RankingV2.sanitizeGlobal(raw, CFG.globalMax)
            loadMission(currentMission)
        else
            goOffline()
        end
    else
        goOffline()
    end
    loaded = true
    sendAll(false)
end

function RecordsV2.init()
    if initialized then
        return
    end
    initialized = true
    task.spawn(load)
end

export type Submission = {
    missionId: string,
    medal: string,
    score: number,
    days: number,
    mode: string,
    players: number,
    members: { { userId: number, name: string } },
}

-- 메달을 딴 판 제출 (비동기). 저장이 끝나면 모두에게 Records(submitted = true)
function RecordsV2.submit(run: Submission)
    task.spawn(function()
        while not loaded do
            task.wait(CFG.retryDelay)
        end
        local names = {}
        for _, member in run.members do
            table.insert(names, member.name)
        end
        local entry = RankingV2.makeMission(
            run.missionId,
            run.medal,
            run.score,
            run.days,
            names,
            run.mode,
            run.players,
            os.time()
        )
        local globalRun: RankingV2.Run = {
            missionId = run.missionId,
            medal = run.medal,
            score = run.score,
            members = run.members,
        }
        local rank: number? = nil
        local savedMission, savedGlobal = false, false
        local ds = recordsStore
        if ds then
            local ok, result = withRetry("UpdateAsync " .. missionKey(run.missionId), function()
                return ds:UpdateAsync(missionKey(run.missionId), function(old: any): any
                    local merged = RankingV2.insertMission(
                        RankingV2.sanitizeMission(old, CFG.missionMax),
                        entry,
                        CFG.missionMax
                    )
                    return merged
                end)
            end)
            if ok then
                local list = RankingV2.sanitizeMission(result, CFG.missionMax)
                missionLists[run.missionId] = list
                rank = RankingV2.findMission(list, entry)
                savedMission = true
            else
                goOffline()
            end
        end
        local lb = leaderboardStore
        if lb then
            local ok, result = withRetry("UpdateAsync global", function()
                return lb:UpdateAsync(CFG.globalKey, function(old: any): any
                    return RankingV2.mergeRun(
                        RankingV2.sanitizeGlobal(old, CFG.globalMax),
                        globalRun,
                        CFG.globalMax
                    )
                end)
            end)
            if ok then
                globalList = RankingV2.sanitizeGlobal(result, CFG.globalMax)
                savedGlobal = true
            else
                goOffline()
            end
        end
        if not savedMission then
            local list
            list, rank = RankingV2.insertMission(listFor(run.missionId), entry, CFG.missionMax)
            missionLists[run.missionId] = list
        end
        if not savedGlobal then
            globalList = RankingV2.mergeRun(globalList, globalRun, CFG.globalMax)
        end
        lastSubmitted = { missionId = run.missionId, entry = entry, rank = rank }
        currentMission = run.missionId
        sendAll(true)
    end)
end

return RecordsV2
