--!strict
-- 플레이어별 언어 설정 (v2 다국어, docs/I18N_PLAN.md 4.5).
-- - DataStore "FrontierPrefs", 키 "u_<UserId>", 값 { lang = "ko", v = 1 }.
-- - 들어오면 바로 player:SetAttribute("Lang", "en")(기본)을 쓰고, 저장된 값을 읽으면 그 값으로 바꾼다.
--   읽기가 끝나기 전에 플레이어가 직접 고르면 그 선택이 이긴다.
-- - 클라이언트는 SetLanguage(code) Remote로 바꾼다. 화이트리스트 en, ko(Loc.normalize), 플레이어당 1초에 1번.
-- - 저장은 마지막 변경 SAVE_DELAY초 뒤 한 번(디바운스). 나갈 때(PlayerRemoving)와 서버 종료(BindToClose)에 바로 저장.
-- - DataStore 호출은 Records와 같이 task.spawn 안에서 pcall + 1회 재시도. 서비스가 없거나(Lune, 게시 안 한 플레이스)
--   두 번 다 실패하면 이 서버의 메모리 표로 바꾼다 (같은 서버에 다시 들어오면 기억, 서버가 닫히면 사라짐).
-- init()만 제공한다. Main.server.luau 연결은 v2 통합 때 리드가 한다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loc = require(ReplicatedStorage.Shared.Loc)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local PlayerPrefs = {}

PlayerPrefs.DATASTORE_NAME = "FrontierPrefs"
PlayerPrefs.ATTRIBUTE = "Lang"
PlayerPrefs.FORMAT_VERSION = 1
PlayerPrefs.RATE_LIMIT = 1 -- 초. 이보다 빨리 온 SetLanguage는 버린다
PlayerPrefs.SAVE_DELAY = 6 -- 초. 마지막 변경 뒤 이만큼 조용하면 저장
PlayerPrefs.RETRY_DELAY = 2 -- 초. DataStore 재시도 간격
PlayerPrefs.CLOSE_TIMEOUT = 20 -- 초. BindToClose에서 저장을 기다리는 최대 시간

export type Status = "loading" | "ok" | "offline"

type State = {
    lang: string,
    chosen: boolean, -- 플레이어가 이번 접속에서 직접 골랐음 (읽은 값으로 덮지 않음)
    dirty: boolean, -- 저장할 변경이 있음
    lastRequest: number, -- 마지막 SetLanguage 처리 시각 (os.clock)
    saveToken: number, -- 디바운스 예약 번호
}

local states: { [Player]: State } = {}
local memory: { [number]: string } = {} -- UserId -> 언어 (DataStore 대체, 이 서버 동안만)
local store: any = nil -- GlobalDataStore. nil이면 메모리만 쓴다
local status: Status = "loading"
local pendingSaves = 0
local initialized = false

-- 서비스와 저장소 얻기. 실패는 조용히 nil
local function getStore(): any
    local okService, service = pcall(function()
        return game:GetService("DataStoreService")
    end)
    if not okService or service == nil then
        return nil
    end
    local okStore, ds = pcall(function()
        return (service :: any):GetDataStore(PlayerPrefs.DATASTORE_NAME)
    end)
    if not okStore then
        return nil
    end
    return ds
end

-- pcall + 1회 재시도 (yield함, task.spawn 안에서만 부른다)
local function withRetry(label: string, fn: () -> any): (boolean, any)
    local ok, result = pcall(fn)
    if ok then
        return true, result
    end
    task.wait(PlayerPrefs.RETRY_DELAY)
    ok, result = pcall(fn)
    if not ok then
        warn(
            string.format(
                "[PlayerPrefs] %s 실패, 이 서버 메모리로 언어 설정을 기억합니다: %s",
                label,
                tostring(result)
            )
        )
    end
    return ok, result
end

local function keyFor(userId: number): string
    return "u_" .. tostring(userId)
end

-- 저장된 값 해석 ({ lang = "ko" } 또는 예전 형식 문자열)
local function decode(raw: any): string?
    if type(raw) == "table" then
        return Loc.normalize(raw.lang)
    end
    return Loc.normalize(raw)
end

local function apply(player: Player, state: State, lang: string)
    state.lang = lang
    player:SetAttribute(PlayerPrefs.ATTRIBUTE, lang)
end

local function goOffline()
    store = nil
    status = "offline"
end

-- 저장 (yield함). 메모리에는 항상 남기고 저장소가 있으면 DataStore에도 쓴다
local function save(userId: number, lang: string)
    memory[userId] = lang
    local ds = store
    if not ds then
        return
    end
    pendingSaves += 1
    local ok = withRetry("SetAsync", function()
        return ds:SetAsync(
            keyFor(userId),
            { lang = lang, v = PlayerPrefs.FORMAT_VERSION },
            { userId }
        )
    end)
    pendingSaves -= 1
    if not ok then
        goOffline()
    end
end

local function flushState(player: Player, state: State)
    if not state.dirty then
        return
    end
    state.dirty = false
    save(player.UserId, state.lang)
end

local function scheduleSave(player: Player, state: State)
    state.dirty = true
    state.saveToken += 1
    local token = state.saveToken
    task.delay(PlayerPrefs.SAVE_DELAY, function()
        if states[player] == state and state.saveToken == token then
            flushState(player, state)
        end
    end)
end

local function load(player: Player, state: State)
    local ds = store
    if not ds then
        return
    end
    local ok, raw = withRetry("GetAsync", function()
        return ds:GetAsync(keyFor(player.UserId))
    end)
    if not ok then
        goOffline()
        return
    end
    local saved = decode(raw)
    if saved and states[player] == state and not state.chosen and saved ~= state.lang then
        apply(player, state, saved)
    end
end

local function onPlayerAdded(player: Player)
    if states[player] then
        return
    end
    local state: State = {
        lang = Loc.DEFAULT,
        chosen = false,
        dirty = false,
        lastRequest = -math.huge,
        saveToken = 0,
    }
    states[player] = state
    apply(player, state, memory[player.UserId] or Loc.DEFAULT)
    task.spawn(load, player, state)
end

local function onPlayerRemoving(player: Player)
    local state = states[player]
    states[player] = nil
    if state and state.dirty then
        state.dirty = false
        task.spawn(save, player.UserId, state.lang)
    end
end

-- 클라이언트 요청. 1초 제한을 먼저 보고, 화이트리스트 밖이면 무시
local function onSetLanguage(player: Player, code: any)
    local state = states[player]
    if not state then
        return
    end
    local now = os.clock()
    if now - state.lastRequest < PlayerPrefs.RATE_LIMIT then
        return
    end
    state.lastRequest = now
    local lang = Loc.normalize(code)
    if not lang then
        return
    end
    state.chosen = true
    if lang == state.lang then
        return
    end
    apply(player, state, lang)
    scheduleSave(player, state)
end

-- 서버 종료: 남은 변경을 모두 저장하고 끝날 때까지(최대 CLOSE_TIMEOUT초) 기다린다
function PlayerPrefs.flushAll()
    for player, state in states do
        if state.dirty then
            state.dirty = false
            task.spawn(save, player.UserId, state.lang)
        end
    end
    local waited = 0
    while pendingSaves > 0 and waited < PlayerPrefs.CLOSE_TIMEOUT do
        waited += task.wait(0.1)
    end
end

-- 현재 언어 (없으면 기본 en)
function PlayerPrefs.getLanguage(player: Player): string
    local state = states[player]
    return if state then state.lang else Loc.DEFAULT
end

-- 서버 쪽에서 언어 바꾸기 (요청 제한 없음). 지원하지 않는 코드면 false
function PlayerPrefs.setLanguage(player: Player, code: string): boolean
    local state = states[player]
    local lang = Loc.normalize(code)
    if not state or not lang then
        return false
    end
    state.chosen = true
    if lang ~= state.lang then
        apply(player, state, lang)
        scheduleSave(player, state)
    end
    return true
end

function PlayerPrefs.status(): Status
    return status
end

-- 서버 시작 시 1회. 여러 번 불러도 안전하다
function PlayerPrefs.init()
    if initialized then
        return
    end
    initialized = true
    store = getStore()
    status = if store then "ok" else "offline"

    Remotes.get("SetLanguage").OnServerEvent:Connect(onSetLanguage)
    Players.PlayerAdded:Connect(onPlayerAdded)
    Players.PlayerRemoving:Connect(onPlayerRemoving)
    for _, player in Players:GetPlayers() do
        onPlayerAdded(player)
    end
    game:BindToClose(PlayerPrefs.flushAll)
end

return PlayerPrefs
