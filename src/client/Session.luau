--!nonstrict
-- v2 클라이언트 공용 상태 (Main.client가 원격 이벤트를 받아 채우고, 화면 모듈이 읽는다).
-- - state: 마지막 StateUpdate (CONTRACT_V2 5절 MissionState)
-- - roles: RoleUpdate 역할 표 { [userId]: "controller" | "explorer" | "engineer" }, selecting, deadline
-- - pin: PinUpdate { siteIndex?, byUserId? }
-- Session.changed:Connect(function(what) ... end)  what: "state" | "roles" | "pin"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Session = {}

-- 역할 순서 (V2_PLAN 15.3 Q25)
Session.ROLE_ORDER = { "controller", "explorer", "engineer" }
-- 역할 이름 키 (리터럴 키 표)
Session.ROLE_NAMES = {
    controller = "role.controller.name",
    explorer = "role.explorer.name",
    engineer = "role.engineer.name",
    solo = "role.solo.name",
}
Session.ROLE_DUTIES = {
    controller = "role.controller.duty",
    explorer = "role.explorer.duty",
    engineer = "role.engineer.duty",
    solo = "role.solo.duty",
}

Session.state = nil
Session.roles = {}
Session.rolesSelecting = false
Session.roleDeadline = nil
Session.pinSite = nil
Session.pinBy = nil

local changedEvent = Instance.new("BindableEvent")
Session.changed = changedEvent.Event

function Session.setState(state)
    Session.state = state
    changedEvent:Fire("state")
end

-- RoleUpdate: (roles, selecting, deadline) 3인자 또는 { roles, selecting, deadline } 표 하나
function Session.setRoles(a, b, c)
    local roles, selecting, deadline = a, b, c
    if type(a) == "table" and type(a.roles) == "table" then
        roles, selecting, deadline = a.roles, a.selecting, a.deadline
    end
    Session.roles = ClientMath.normalizeRoles(roles)
    Session.rolesSelecting = selecting == true
    Session.roleDeadline = if type(deadline) == "number" then deadline else nil
    changedEvent:Fire("roles")
end

function Session.setPin(payload)
    if type(payload) == "table" then
        Session.pinSite = if type(payload.siteIndex) == "number" then payload.siteIndex else nil
        Session.pinBy = payload.byUserId
    else
        Session.pinSite = if type(payload) == "number" then payload else nil
        Session.pinBy = nil
    end
    changedEvent:Fire("pin")
end

-- 지금 인원으로 역할 자리 수 (서버 Roles와 같은 규칙, ClientMath.roleCapacity)
function Session.roleCapacity(role)
    return ClientMath.roleCapacity(role, #Players:GetPlayers())
end

function Session.phase()
    return Session.state and Session.state.phase or nil
end

function Session.mode()
    return Session.state and Session.state.mode or "solo"
end

function Session.isMulti()
    return Session.mode() == "multi"
end

function Session.missionId()
    return Session.state and Session.state.missionId or "C"
end

function Session.missionDef()
    return MissionConfig.MISSIONS[Session.missionId()] or MissionConfig.MISSIONS.C
end

-- 내 역할. 솔로면 "solo"(모든 역할), 멀티에서 아직 없으면 nil
function Session.myRole()
    if not Session.isMulti() then
        return "solo"
    end
    return Session.roles[Players.LocalPlayer.UserId]
end

function Session.roleOf(userId)
    if not Session.isMulti() then
        return "solo"
    end
    return Session.roles[userId]
end

-- 전체 지도와 핀을 쓸 수 있는지 (솔로 또는 관제사, Q25)
function Session.canUseMap()
    local role = Session.myRole()
    return role == "solo" or role == "controller"
end

local function weather()
    local w = Session.state and Session.state.weather
    return if type(w) == "table" then w else nil
end

-- 지자기 폭풍 진행 중 (지도와 핀 화살표 끊김)
function Session.isGst()
    local w = weather()
    -- SEP와 같은 날이면 kind는 SEP이고 gst = true (서버 MissionState.weather.gst)
    return w ~= nil and w.stage == "active" and (w.gst == true or w.kind == "GST")
end

-- 태양 고에너지 입자 폭풍 진행 중 (외출 금지, 로버 정지)
function Session.isSep()
    local w = weather()
    return w ~= nil and w.kind == "SEP" and w.stage == "active"
end

return Session
