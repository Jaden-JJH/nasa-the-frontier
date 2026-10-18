--!strict
-- RemoteEvent 이름 목록과 생성, 조회 (CONTRACT 2절)
-- 서버: Remotes.init()으로 ReplicatedStorage.Remotes 아래에 전부 생성한다.
-- 클라이언트: Remotes.get(name)이 WaitForChild로 생성될 때까지 기다린 뒤 반환한다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local Remotes = {}

-- 서버 -> 클라이언트, 클라이언트 -> 서버 이벤트 전체 목록
Remotes.NAMES = {
    -- 서버 -> 클라이언트
    "StateUpdate",
    "OxygenUpdate",
    "Notify",
    "SiteSelectionOpen",
    "LandingSequence",
    "GameOver",
    "Records", -- (payload: RecordsPayload) 승리 기록 상위 목록과 이번 순위 (2026-10-19 16차)
    -- 클라이언트 -> 서버
    "SelectSite",
    "SetSpeed",
    "RequestRestart",
    "RoverBoost", -- (on: boolean) 운전자 부스터 켜기/끄기 (2026-10-18)
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
