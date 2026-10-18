--!strict
-- 승리 기록 저장과 랭킹 송신 (2026-10-19 16차).
-- DataStore(Config.RECORDS.datastoreName, 키 RECORDS.key)에 상위 RECORDS.maxEntries개를 둔다.
-- 모든 DataStore 호출은 task.spawn 안에서 pcall + 1회 재시도로 한다 (프롬프트 처리나 DayTick을 멈추지 않는다).
-- 서비스가 없거나(Lune, 게시 안 한 플레이스) 호출이 실패하면(Studio API 접근 꺼짐) 서버 메모리 목록으로 자동 전환하고
-- status "offline"을 보내 화면에 "저장소 연결 안 됨" 문구를 띄운다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Ranking = require(ReplicatedStorage.Shared.Ranking)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local ServerUtil = require(script.Parent.ServerUtil)

local Records = {}

local R = Config.RECORDS

local entries: { Ranking.Entry } = {}
local status: Types.RecordsStatus = "loading"
local loaded = false
local initialized = false
local store: any = nil -- GlobalDataStore. nil이면 메모리 목록만 쓴다
local listeners: { () -> () } = {}

-- 서비스와 저장소 얻기. 실패는 조용히 nil (Lune 에뮬레이터와 게시 안 한 플레이스)
local function getStore(): any
    local okService, service = pcall(function()
        return game:GetService("DataStoreService")
    end)
    if not okService or service == nil then
        return nil
    end
    local okStore, ds = pcall(function()
        return (service :: any):GetDataStore(R.datastoreName)
    end)
    if not okStore then
        return nil
    end
    return ds
end

-- pcall + 1회 재시도. 두 번 다 실패하면 출력 창에 남긴다
local function withRetry(label: string, fn: () -> any): (boolean, any)
    local ok, result = pcall(fn)
    if ok then
        return true, result
    end
    task.wait(R.retryDelay)
    ok, result = pcall(fn)
    if not ok then
        warn(
            string.format(
                "[Records] %s 실패, 이번 서버 기록만 씁니다: %s",
                label,
                tostring(result)
            )
        )
    end
    return ok, result
end

local function copyEntries(): { Ranking.Entry }
    local out = {}
    for _, entry in entries do
        table.insert(out, Ranking.copyEntry(entry))
    end
    return out
end

-- 클라이언트로 보낼 페이로드
function Records.payload(rank: number?, submitted: boolean?): Types.RecordsPayload
    return {
        entries = copyEntries(),
        rank = rank,
        status = status,
        submitted = submitted == true,
    }
end

-- 현재 목록과 상태 (기지 기록판용)
function Records.get(): ({ Ranking.Entry }, Types.RecordsStatus)
    return entries, status
end

function Records.isLoaded(): boolean
    return loaded
end

-- 목록이 바뀌면 부를 함수 (RecordBoard.refresh)
function Records.onChanged(fn: () -> ())
    table.insert(listeners, fn)
end

local function changed(rank: number?, submitted: boolean)
    Remotes.get("Records"):FireAllClients(Records.payload(rank, submitted))
    for _, fn in listeners do
        ServerUtil.safeCall("Records 갱신", fn)
    end
end

-- 입장한 플레이어에게 현재 목록. 아직 불러오는 중이면 로드가 끝날 때 전원에게 보낸다
function Records.sendTo(player: Player)
    if not loaded then
        return
    end
    Remotes.get("Records"):FireClient(player, Records.payload(nil, false))
end

local function load()
    if not R.enabled then
        store = nil
    else
        store = getStore()
    end
    if store then
        local ok, raw = withRetry("GetAsync", function()
            return store:GetAsync(R.key)
        end)
        if ok then
            entries = Ranking.sanitize(raw, R.maxEntries)
            status = "ok"
        else
            store = nil
        end
    end
    if not store then
        status = "offline"
    end
    loaded = true
    changed(nil, false)
end

-- 서버 시작 시 1회 (비동기)
function Records.init()
    if initialized then
        return
    end
    initialized = true
    task.spawn(load)
end

-- 승리 기록 제출 (비동기). 저장이 끝나면 Records(submitted = true, rank)를 전원에게 보낸다.
-- 로드가 끝나기 전이면 기다린다. 저장 실패면 메모리 목록에 넣고 offline으로 바꾼다
function Records.submit(entry: Ranking.Entry)
    task.spawn(function()
        while not loaded do
            task.wait(R.retryDelay)
        end
        local rank: number? = nil
        local saved = false
        local ds = store
        if ds then
            local ok, result = withRetry("UpdateAsync", function()
                return ds:UpdateAsync(R.key, function(old: any): any
                    local merged =
                        Ranking.insert(Ranking.sanitize(old, R.maxEntries), entry, R.maxEntries)
                    return merged
                end)
            end)
            if ok then
                entries = Ranking.sanitize(result, R.maxEntries)
                rank = Ranking.find(entries, entry)
                status = "ok"
                saved = true
            else
                store = nil
                status = "offline"
            end
        end
        if not saved then
            entries, rank = Ranking.insert(entries, entry, R.maxEntries)
        end
        changed(rank, true)
    end)
end

-- 승리 기록 항목 만들기 (이름과 착륙지는 RECORDS.nameMaxLength 글자까지)
function Records.makeEntry(days: number, site: string, crew: { string }): Ranking.Entry
    local names = {}
    for i, name in crew do
        if i > R.crewNameLimit then
            break
        end
        table.insert(names, Ranking.clip(name, R.nameMaxLength))
    end
    return {
        days = days,
        site = Ranking.clip(site, R.nameMaxLength),
        crew = names,
        at = os.time(),
        version = R.version,
    }
end

return Records
