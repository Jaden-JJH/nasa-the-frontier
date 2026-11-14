--!strict
-- v2 멀티 역할 (V2_PLAN Q25, docs/CONTRACT_V2.md 4.1 RoleUpdate, PinUpdate, 4.2 ChooseRole, SetPin)
--   역할: controller(관제사 1명, 전체 지도와 목표 핀), explorer(탐사대원 1~2명), engineer(엔지니어 0~1명).
--   2명: 관제사 + 탐사대원, 3명: + 엔지니어(또는 탐사대원 2), 4명: 탐사대원 2명 + 엔지니어.
--   자리 규칙: 관제사 1자리는 늘 비워 둔다(관제사 아닌 사람 수 <= 인원 - 1), 탐사대원 <= 2, 엔지니어 <= 1(3명 이상일 때).
--   이 규칙이면 탐사대원은 늘 1명 이상이다.
--   멀티 시작 때 CONFIG(10초) 동안 고르고, 안 고른 사람은 자동 배정. 그 뒤에는 착륙선 콘솔 근처에서만 바꾼다.
--   자리가 차 있으면 그 역할을 가진 사람과 맞바꾼다(관제사 넘기기도 이 방법). 관제사가 나가면 자동 이전.
--   잠그는 것은 전체 지도와 핀뿐이다(운전, 건설, 패널은 누구나). 솔로는 모든 역할(roles = {}).
--   RoleUpdate(roles, selecting, deadline?)의 roles 키는 tostring(userId) (RemoteEvent 숫자 키 변환을 피한다).
--   핀: 관제사만(솔로는 혼자라 누구나), GST 중 거절. PinUpdate({ siteIndex?, byUserId? }).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ContributionsV2 = require(script.Parent.ContributionsV2)

local Roles = {}

-- 엔진 수준 값
Roles.CONFIG = {
    selectSeconds = 10, -- [Q25] 멀티 시작 역할 선택 시간
    maxExplorers = 2,
    maxEngineers = 1,
    engineerMinPlayers = 3,
}
local CFG = Roles.CONFIG

local ROLE_NAMES: { [string]: Msg.Msg } = {
    controller = { key = "role.controller.name" },
    explorer = { key = "role.explorer.name" },
    engineer = { key = "role.engineer.name" },
}

local roles: { [Player]: string } = {}
local order: { Player } = {} -- 들어온 순서 (자동 배정과 관제사 이전 순서)
local mode = "solo"
local selecting = false
local deadline: number? = nil
local selectToken = 0
local pin: { siteIndex: number?, byUserId: number? } = {}
local flow: any = nil

local function roleName(role: string): Msg.Msg
    return Msg.new(ROLE_NAMES[role].key)
end

local function counts(): { [string]: number }
    local c = { controller = 0, explorer = 0, engineer = 0 }
    for _, role in roles do
        c[role] += 1
    end
    return c
end

local function playerCount(): number
    return #Players:GetPlayers()
end

local function capacity(role: string, n: number): number
    if role == "controller" then
        return 1
    elseif role == "explorer" then
        return math.min(CFG.maxExplorers, math.max(1, n - 1))
    end
    return if n >= CFG.engineerMinPlayers then CFG.maxEngineers else 0
end

-- player가 role 자리에 들어갈 수 있는지 (자기 자리는 빼고 센다)
local function fits(player: Player, role: string): boolean
    local n = playerCount()
    local c = counts()
    local current = roles[player]
    if current then
        c[current] -= 1
    end
    if c[role] >= capacity(role, n) then
        return false
    end
    if role ~= "controller" then
        local others = c.explorer + c.engineer
        if others + 1 > n - 1 then
            return false
        end
    end
    return true
end

local function payload(): { [string]: string }
    local out: { [string]: string } = {}
    for player, role in roles do
        out[tostring(player.UserId)] = role
    end
    return out
end

local function broadcast()
    Remotes.get("RoleUpdate"):FireAllClients(payload(), selecting, deadline)
end

local function setRole(player: Player, role: string?)
    roles[player] = role
    ContributionsV2.setRole(player, role)
end

-- 빈자리 순서: 관제사 -> 탐사대원 -> 엔지니어 -> (넘치면) 탐사대원
local function autoRole(player: Player): string
    for _, role in { "controller", "explorer", "engineer" } do
        if fits(player, role) then
            return role
        end
    end
    return "explorer"
end

local function ensureController()
    if mode ~= "multi" then
        return
    end
    if counts().controller > 0 then
        return
    end
    -- 엔지니어, 탐사대원 순으로 먼저 들어온 사람에게 넘긴다
    local pick: Player? = nil
    for _, preferred in { "engineer", "explorer" } do
        for _, player in order do
            if roles[player] == preferred then
                pick = player
                break
            end
        end
        if pick then
            break
        end
    end
    if pick then
        setRole(pick, "controller")
        if not selecting and flow then
            flow.notifyAll(
                Msg.new(
                    "toast.role.changed",
                    { name = pick.DisplayName, role = roleName("controller") }
                ),
                "info"
            )
        end
    end
end

-- 남은 사람 자동 배정 (선택 시간이 끝났을 때, 늦은 입장)
local function fillUnassigned()
    for _, player in order do
        if roles[player] == nil and player.Parent ~= nil then
            setRole(player, autoRole(player))
        end
    end
    ensureController()
end

function Roles.init(api: any)
    flow = api
end

-- 새 판: mode는 미션 확정 때 정한 "solo" | "multi" (Q6)
function Roles.begin(newMode: string)
    mode = newMode
    table.clear(roles)
    pin = {}
    selectToken += 1
    order = Players:GetPlayers()
    if mode == "multi" then
        selecting = true
        deadline = workspace:GetServerTimeNow() + CFG.selectSeconds
        local token = selectToken
        task.delay(CFG.selectSeconds, function()
            if token == selectToken and selecting then
                Roles.finalize()
            end
        end)
    else
        selecting = false
        deadline = nil
        for _, player in order do
            ContributionsV2.setRole(player, "solo")
        end
    end
    broadcast()
    Remotes.get("PinUpdate"):FireAllClients(pin)
end

-- 선택 시간을 끝내고 남은 사람을 배정한다 (playing 시작 때도 부른다)
function Roles.finalize()
    if mode ~= "multi" then
        return
    end
    selecting = false
    deadline = nil
    fillUnassigned()
    broadcast()
end

function Roles.reset()
    selectToken += 1
    mode = "solo"
    selecting = false
    deadline = nil
    table.clear(roles)
    table.clear(order)
    pin = {}
    broadcast()
    Remotes.get("PinUpdate"):FireAllClients(pin)
end

function Roles.roleOf(player: Player): string?
    if mode ~= "multi" then
        return "solo"
    end
    return roles[player]
end

function Roles.isSelecting(): boolean
    return selecting
end

-- 전체 지도와 핀을 쓸 수 있는지 (솔로는 모두)
function Roles.canUseMap(player: Player): boolean
    return mode ~= "multi" or roles[player] == "controller"
end

-- ChooseRole 요청
function Roles.choose(player: Player, role: any)
    if mode ~= "multi" or typeof(role) ~= "string" or ROLE_NAMES[role] == nil then
        return
    end
    local phase = if flow then flow.phase() else "selecting"
    if phase ~= "landing" and phase ~= "playing" then
        return
    end
    if roles[player] == role then
        return
    end
    if not selecting and flow and not flow.nearConsole(player) then
        flow.notify(player, Msg.new("toast.role.need_console"), "warn")
        return
    end
    local before = roles[player]
    if fits(player, role) then
        setRole(player, role)
    elseif not selecting then
        -- 자리가 차 있으면 그 역할을 가진 사람과 맞바꾼다
        local other: Player? = nil
        for _, candidate in order do
            if candidate ~= player and roles[candidate] == role then
                other = candidate
                break
            end
        end
        if not other or before == nil then
            if flow then
                flow.notify(player, Msg.new("toast.role.full", { role = roleName(role) }), "warn")
            end
            return
        end
        local swapped: Player = other :: Player
        setRole(swapped, before)
        setRole(player, role)
        if flow then
            flow.notifyAll(
                Msg.new(
                    "toast.role.changed",
                    { name = swapped.DisplayName, role = roleName(before :: string) }
                ),
                "info"
            )
        end
    else
        if flow then
            flow.notify(player, Msg.new("toast.role.full", { role = roleName(role) }), "warn")
        end
        return
    end
    if not selecting and flow then
        flow.notifyAll(
            Msg.new("toast.role.changed", { name = player.DisplayName, role = roleName(role) }),
            "info"
        )
    end
    broadcast()
    if flow then
        flow.markDirty()
    end
end

-- 늦은 입장: 멀티면 빈자리 배정, 솔로 판이면 모든 역할 (Q6 판 동안 모드 고정)
function Roles.onPlayerAdded(player: Player)
    if not table.find(order, player) then
        table.insert(order, player)
    end
    local phase = if flow then flow.phase() else "selecting"
    if phase == "landing" or phase == "playing" or phase == "result" then
        if mode == "multi" then
            if not selecting and roles[player] == nil then
                setRole(player, autoRole(player))
                ensureController()
            end
        else
            ContributionsV2.setRole(player, "solo")
        end
    end
    Remotes.get("RoleUpdate"):FireClient(player, payload(), selecting, deadline)
    Remotes.get("PinUpdate"):FireClient(player, pin)
end

function Roles.onPlayerRemoving(player: Player)
    local index = table.find(order, player)
    if index then
        table.remove(order, index)
    end
    local was = roles[player]
    roles[player] = nil
    if was == "controller" then
        ensureController()
    end
    if pin.byUserId == player.UserId then
        pin.byUserId = nil
    end
    broadcast()
end

-- SetPin 요청 (siteIndex nil이면 지운다)
function Roles.setPin(player: Player, siteIndex: any)
    if not flow or flow.phase() ~= "playing" then
        return
    end
    if not Roles.canUseMap(player) then
        flow.notify(player, Msg.new("toast.map.controller_only"), "warn")
        return
    end
    local _, gst = flow.weather()
    if gst then
        flow.notify(player, Msg.new("toast.map.offline_gst"), "warn")
        return
    end
    if siteIndex ~= nil then
        local state = flow.rules()
        if
            typeof(siteIndex) ~= "number"
            or siteIndex % 1 ~= 0
            or not state
            or state.sites[siteIndex] == nil
        then
            return
        end
        pin = { siteIndex = siteIndex, byUserId = player.UserId }
    else
        pin = {}
    end
    Remotes.get("PinUpdate"):FireAllClients(pin)
end

function Roles.getPin(): { siteIndex: number?, byUserId: number? }
    return table.clone(pin)
end

-- 테스트와 진단용: 역할표 { [userId 문자열]: role }
function Roles.snapshot(): { [string]: string }
    return payload()
end

return Roles
