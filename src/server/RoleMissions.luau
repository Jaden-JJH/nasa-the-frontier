--!strict
-- v2 멀티 역할 미션 (2026-11-15 리드 결정, 사용자: 넣되 점수와 메달 규칙은 바꾸지 않는다).
-- Rules와 MissionConfig는 건드리지 않고 이 서버 모듈이 따로 센다. 솔로에는 없다. 플레이어마다 미션 하나.
--   controller  guide   핀을 찍은 얼음 후보지에 관제사가 아닌 팀원이 반경 안에 들어오기 (같은 후보지는 한 번만)
--   explorer    water   (먼저 배정된 탐사대원) 본인이 물탱크에 물 내리기
--   explorer    scout   (두 번째 탐사대원) 앞으로 지을 시설 자리에 가 보기 (그린하우스, 물 파이프, 태양광 설치 자리)
--   engineer    panels  본인이 태양광 패널 설치 (남은 패널 칸이 모자라면 목표를 줄인다). 배정 때 남은 칸이 0이면
--                       panels 대신 scout (2026-11-15 QA D5: 0/1로 끝낼 수 없었다)
-- 배정: Roles가 역할을 바꿀 때마다 assign을 부른다(선택 시간이 끝난 뒤, 멀티만). 역할이 같으면 미션과 진행을 그대로 두고,
--   역할이 바뀌면 새 역할 미션을 0부터. 탐사대원은 다른 탐사대원이 water를 갖고 있지 않으면 water, 있으면 scout.
-- 진행: water, panels는 MissionFlow flow.contribute에서(onContribute), guide, scout는 주기 검사(step)에서. playing일 때만 센다.
-- 완료 순간: 본인에게 rolemission.<id>.done_self, 다른 플레이어에게 rolemission.done_team { name, role }.
-- 화면: MissionState.roleMissions = { [tostring(userId)] = { id, progress, goal, done, radius?, targets? } } (view),
--   결과: GameOver.crew[i].roleMission = { id, progress, goal, done } (resultFor). 서버는 문장을 쓰지 않는다(키만).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Msg = require(ReplicatedStorage.Shared.Msg)
local MissionWorld = require(script.Parent.MissionWorld)
local PromptKit = require(script.Parent.PromptKit)
local ServerUtil = require(script.Parent.ServerUtil)

local RoleMissions = {}

-- 역할 미션 목표 (리드 결정). 점수와 메달에는 영향이 없다
local ROLE_MISSIONS = {
    tickSeconds = 0.5, -- guide, scout 위치 검사 주기
    byRole = { controller = "guide", engineer = "panels" } :: { [string]: string },
    explorerFirst = "water",
    explorerSecond = "scout",
    water = { goal = 3 }, -- 본인 하역 횟수
    panels = { goal = 6 }, -- 본인 패널 설치 수 (남은 칸이 모자라면 줄인다, 최소 1)
    guide = { goal = 2, radius = 30 }, -- 서로 다른 핀 후보지 수, 도착 판정 수평 거리 (studs)
    scout = {
        radius = 12, -- 자리 방문 판정 수평 거리 (studs)
        -- MissionWorld 상호작용 자리 id와 화면 이름 키. 얼음 후보지는 넣지 않는다 (얼음은 지도와 핀으로 찾는다)
        targets = {
            { id = "buildSpot", key = "facility.farm.name" },
            { id = "pipeSpot", key = "facility.pipe.name" },
            { id = "installPad", key = "world.solar_field.name" },
        },
    },
}
RoleMissions.CONFIG = ROLE_MISSIONS

local ROLE_NAMES: { [string]: string } = {
    controller = "role.controller.name",
    explorer = "role.explorer.name",
    engineer = "role.engineer.name",
}

type Target = { id: string, key: string, x: number, z: number, visited: boolean }

type Record = {
    userId: number,
    role: string,
    id: string,
    progress: number,
    goal: number,
    done: boolean,
    targets: { Target }?,
    counted: { [number]: boolean }, -- guide: 이미 센 얼음 후보지 siteIndex
}

local flow: any = nil
local initialized = false
local records: { [number]: Record } = {}
local pin: { siteIndex: number?, byUserId: number? } = {}

local function round1(v: number): number
    return math.floor(v * 10 + 0.5) / 10
end

local function flat(a: Vector3, x: number, z: number): number
    return math.sqrt((a.X - x) ^ 2 + (a.Z - z) ^ 2)
end

local function playing(): boolean
    return flow ~= nil and flow.phase() == "playing" and flow.mode() == "multi"
end

-- 남은 패널 칸 (Rules 상태와 미션 정의). 상태가 없으면 nil
local function panelSlotsLeft(): number?
    local state = if flow then flow.rules() else nil
    local m = if flow then flow.mission() else nil
    if not state or not m then
        return nil
    end
    return math.max(0, m.panels.total - state.panels)
end

local function scoutTargets(): { Target }
    local out: { Target } = {}
    for _, spec in ROLE_MISSIONS.scout.targets do
        local part = MissionWorld.anchor(spec.id)
        if part then
            local p = part.CFrame.Position
            table.insert(out, {
                id = spec.id,
                key = spec.key,
                x = round1(p.X),
                z = round1(p.Z),
                visited = false,
            })
        end
    end
    return out
end

local function newRecord(player: Player, role: string, id: string): Record
    local record: Record = {
        userId = player.UserId,
        role = role,
        id = id,
        progress = 0,
        goal = 1,
        done = false,
        targets = nil,
        counted = {},
    }
    if id == "water" then
        record.goal = ROLE_MISSIONS.water.goal
    elseif id == "panels" then
        local left = panelSlotsLeft()
        local goal = ROLE_MISSIONS.panels.goal
        record.goal = math.max(1, if left then math.min(goal, left) else goal)
    elseif id == "guide" then
        record.goal = ROLE_MISSIONS.guide.goal
    elseif id == "scout" then
        record.targets = scoutTargets()
        record.goal = math.max(1, #(record.targets :: { Target }))
    end
    return record
end

local function playerById(userId: number): Player?
    for _, player in Players:GetPlayers() do
        if player.UserId == userId then
            return player
        end
    end
    return nil
end

local function complete(record: Record)
    if record.done then
        return
    end
    record.done = true
    record.progress = record.goal
    local player = playerById(record.userId)
    if flow and player then
        flow.notify(player, Msg.new("rolemission." .. record.id .. ".done_self"), "good")
        local team = Msg.new("rolemission.done_team", {
            name = player.DisplayName,
            role = Msg.new(ROLE_NAMES[record.role] or "role.explorer.name"),
        })
        for _, other in Players:GetPlayers() do
            if other ~= player then
                flow.notify(other, team, "good")
            end
        end
    end
end

local function advance(record: Record, amount: number?)
    if record.done or not playing() then
        return
    end
    record.progress = math.min(record.goal, record.progress + (amount or 1))
    if record.progress >= record.goal then
        complete(record)
    end
    if flow then
        flow.markDirty()
    end
end

-- 남은 패널 칸이 모자라면 목표를 줄인다 (진행 + 남은 칸, 최소 1). 줄여서 다 채웠으면 완료
local function shrinkPanelGoal(record: Record)
    if record.id ~= "panels" or record.done then
        return
    end
    local left = panelSlotsLeft()
    if left == nil then
        return
    end
    local goal = math.max(1, math.min(record.goal, record.progress + left))
    if goal ~= record.goal then
        record.goal = goal
        if record.progress >= goal and playing() then
            complete(record)
        end
        if flow then
            flow.markDirty()
        end
    end
end

-- 배정 -------------------------------------------------------------------------

-- Roles가 역할을 바꿀 때마다 (ordered = 들어온 순서, roles = { [Player]: role }). 선택 중이거나 솔로면 아무것도 안 한다
function RoleMissions.assign(
    mode: string,
    selecting: boolean,
    ordered: { Player },
    roles: { [Player]: string }
)
    if mode ~= "multi" or selecting then
        return
    end
    local changed = false
    local waterTaken = false
    local fresh: { Player } = {}
    for _, player in ordered do
        local role = roles[player]
        local record = records[player.UserId]
        if role and record and record.role == role then
            if record.id == ROLE_MISSIONS.explorerFirst then
                waterTaken = true
            end
        elseif role then
            table.insert(fresh, player)
        end
    end
    for _, player in fresh do
        local role = roles[player]
        local id = ROLE_MISSIONS.byRole[role]
        if role == "explorer" then
            id = if waterTaken then ROLE_MISSIONS.explorerSecond else ROLE_MISSIONS.explorerFirst
            if id == ROLE_MISSIONS.explorerFirst then
                waterTaken = true
            end
        elseif id == "panels" and panelSlotsLeft() == 0 then
            id = ROLE_MISSIONS.explorerSecond
        end
        if id then
            records[player.UserId] = newRecord(player, role, id)
            changed = true
        end
    end
    if changed and flow then
        flow.markDirty()
    end
end

-- 핀이 바뀔 때 (Roles.setPin, 새 판, 관제사 이탈)
function RoleMissions.setPin(newPin: { siteIndex: number?, byUserId: number? })
    pin = table.clone(newPin)
end

-- 새 판
function RoleMissions.reset()
    table.clear(records)
    pin = {}
end

-- 진행 ---------------------------------------------------------------------------

-- MissionFlow flow.contribute에서: 하역 1회(water 필드), 패널 1장(panels 필드)
function RoleMissions.onContribute(player: Player?, field: string, _amount: number?)
    if not player then
        return
    end
    local record = records[player.UserId]
    if not record then
        return
    end
    -- 하역은 양과 무관하게 1회, 패널은 1장씩
    if
        (field == "water" and record.id == "water") or (field == "panels" and record.id == "panels")
    then
        advance(record, 1)
    end
end

local function iceSitePosition(siteIndex: number): Vector3?
    local state = if flow then flow.rules() else nil
    local site = state and state.sites[siteIndex]
    if not site then
        return nil
    end
    for _, info in MissionWorld.iceSites() do
        if info.markerName == site.id then
            return info.position
        end
    end
    return nil
end

-- 주기 검사: guide(핀 후보지에 팀원 도착), scout(자리 방문), panels(목표 줄이기)
function RoleMissions.step()
    if not playing() then
        return
    end
    local positions: { [number]: Vector3 } = {}
    for _, player in Players:GetPlayers() do
        local p = PromptKit.rootPosition(player)
        if p then
            positions[player.UserId] = p
        end
    end
    local pinSite = pin.siteIndex
    local pinPos = if pinSite then iceSitePosition(pinSite) else nil
    for _, record in records do
        if not record.done and playerById(record.userId) then
            if record.id == "guide" and pinSite and pinPos and not record.counted[pinSite] then
                local radius = ROLE_MISSIONS.guide.radius
                for userId, p in positions do
                    local other = records[userId]
                    local teammate = userId ~= record.userId
                        and (other == nil or other.role ~= "controller")
                    if teammate and flat(p, pinPos.X, pinPos.Z) <= radius then
                        record.counted[pinSite] = true
                        advance(record, 1)
                        break
                    end
                end
            elseif record.id == "scout" and record.targets then
                local p = positions[record.userId]
                if p then
                    for _, target in record.targets do
                        if
                            not target.visited
                            and flat(p, target.x, target.z) <= ROLE_MISSIONS.scout.radius
                        then
                            target.visited = true
                            advance(record, 1)
                        end
                    end
                end
            elseif record.id == "panels" then
                shrinkPanelGoal(record)
            end
        end
    end
end

-- 보기 ----------------------------------------------------------------------------

local function entry(record: Record): { [string]: any }
    local out: { [string]: any } = {
        id = record.id,
        progress = record.progress,
        goal = record.goal,
        done = record.done,
    }
    if record.id == "guide" then
        out.radius = ROLE_MISSIONS.guide.radius
    elseif record.id == "scout" then
        out.radius = ROLE_MISSIONS.scout.radius
        local targets = {}
        for _, target in record.targets or {} do
            table.insert(targets, {
                id = target.id,
                key = target.key,
                x = target.x,
                z = target.z,
                visited = target.visited,
            })
        end
        out.targets = targets
    end
    return out
end

-- MissionState.roleMissions (멀티만, 지금 서버에 있는 플레이어만). 없으면 nil
function RoleMissions.view(): { [string]: any }?
    if not flow or flow.mode() ~= "multi" then
        return nil
    end
    local out: { [string]: any } = {}
    local any = false
    for _, player in Players:GetPlayers() do
        local record = records[player.UserId]
        if record then
            out[tostring(player.UserId)] = entry(record)
            any = true
        end
    end
    return if any then out else nil
end

-- 결과 화면 한 줄 (나간 플레이어도 남는다). 없으면 nil
function RoleMissions.resultFor(userId: number): { [string]: any }?
    local record = records[userId]
    if not record then
        return nil
    end
    return { id = record.id, progress = record.progress, goal = record.goal, done = record.done }
end

-- 테스트와 진단용
function RoleMissions.recordOf(userId: number): Record?
    return records[userId]
end

function RoleMissions.init(api: any)
    flow = api
    if initialized then
        return
    end
    initialized = true
    task.spawn(function()
        while true do
            task.wait(ROLE_MISSIONS.tickSeconds)
            ServerUtil.safeCall("RoleMissions", RoleMissions.step)
        end
    end)
end

return RoleMissions
