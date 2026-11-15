--!strict
-- RemoteEvent 이름 목록과 생성, 조회 (docs/CONTRACT_V2.md 4절)
-- 서버: Remotes.init()으로 ReplicatedStorage.Remotes 아래에 전부 생성한다.
-- 클라이언트: Remotes.get(name)이 WaitForChild로 생성될 때까지 기다린 뒤 반환한다.
-- v1 이름(SiteSelectionOpen, SelectSite, SetSpeed)은 v1 클라이언트 파일을 지울 때까지 남겨 둔다(v2 서버는 쓰지 않는다).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local Remotes = {}

-- 서버 -> 클라이언트, 클라이언트 -> 서버 이벤트 전체 목록
Remotes.NAMES = {
    -- 서버 -> 클라이언트 (CONTRACT_V2 4.1)
    "StateUpdate", -- (state: MissionState)
    "Notify", -- (msg: Msg, kind: "info" | "warn" | "good")
    "MissionSelectOpen", -- (payload) 미션 선택 진입, 늦은 입장자
    "LandingSequence", -- (missionId, landerCFrame) landing 진입 1회
    "SpaceWeather", -- (payload) 경보 15초 전, 시작, 끝
    "RoleUpdate", -- (roles, selecting, deadline?) 멀티 역할
    "PinUpdate", -- ({ siteIndex?, byUserId? }) 관제사 핀
    "OxygenUpdate", -- (oxygen, max, zone: "outside" | "shelter" | "refill")
    "GameOver", -- (result: MissionResult)
    "Records", -- (payload) 미션 순위와 전체 리더보드
    -- 클라이언트 -> 서버 (CONTRACT_V2 4.2)
    "SelectMission", -- (missionId)
    "MissionSelectSeen", -- () 타이틀에서 시작을 눌러 미션 선택 화면이 보임 (첫 신호부터 30초 자동 선택 타이머)
    "ChooseRole", -- (role)
    "SetPin", -- (siteIndex?)
    "DispatchRover", -- (siteIndex, rush)
    "RemoteRecoverRover", -- ()
    "SetFacilityPaused", -- (facilityId, paused)
    "SetPipeSite", -- (siteIndex)
    "RequestRestart", -- ()
    "SetLanguage", -- (code: string) 플레이어 언어 변경 en/ko, 서버 PlayerPrefs가 처리
    "RoverBoost", -- (on: boolean) 운전자 부스터
    -- v1 (v2 서버는 쓰지 않는다. v1 클라이언트를 지울 때 함께 지운다)
    "SiteSelectionOpen",
    "SelectSite",
    "SetSpeed",
}

local known: { [string]: boolean } = {}
for _, name in Remotes.NAMES do
    known[name] = true
end

local cache: { [string]: RemoteEvent } = {}

local function getFolder(create: boolean): Folder
    local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
    if existing and existing:IsA("Folder") then
        return existing
    end
    if create then
        local folder = Instance.new("Folder")
        folder.Name = FOLDER_NAME
        folder.Parent = ReplicatedStorage
        return folder
    end
    return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

-- 서버 전용. 모든 RemoteEvent를 만든다. 여러 번 불러도 안전하다.
function Remotes.init()
    assert(RunService:IsServer(), "Remotes.init()은 서버에서만 호출한다")
    local folder = getFolder(true)
    for _, name in Remotes.NAMES do
        local existing = folder:FindFirstChild(name)
        if existing and existing:IsA("RemoteEvent") then
            cache[name] = existing
        else
            local remote = Instance.new("RemoteEvent")
            remote.Name = name
            remote.Parent = folder
            cache[name] = remote
        end
    end
end

-- 이름으로 RemoteEvent를 얻는다. 목록에 없는 이름이면 에러.
function Remotes.get(name: string): RemoteEvent
    if not known[name] then
        error(string.format("알 수 없는 Remote 이름: %s", tostring(name)), 2)
    end
    local cached = cache[name]
    if cached and cached.Parent then
        return cached
    end
    local remote: RemoteEvent
    if RunService:IsServer() then
        local folder = getFolder(true)
        local found = folder:FindFirstChild(name)
        if found and found:IsA("RemoteEvent") then
            remote = found
        else
            Remotes.init()
            remote = cache[name]
        end
    else
        remote = getFolder(false):WaitForChild(name) :: RemoteEvent
    end
    cache[name] = remote
    return remote
end

return Remotes
