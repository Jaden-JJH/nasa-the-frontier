--!nonstrict
-- v2 클라이언트 원격 이벤트 창구. ReplicatedStorage.Remotes 폴더에서 이름으로 찾는다.
-- Shared.Remotes.get은 목록에 없는 이름이면 에러, 아직 안 만들어진 이름이면 무한 대기라서
-- v2 이름이 서버에 등록되기 전에도 클라이언트가 멈추지 않게 이 모듈을 거친다.
-- - Net.on(name, fn): 이벤트가 생기면(지금 또는 나중에) OnClientEvent에 연결한다.
-- - Net.fire(name, ...): 있으면 FireServer, 없으면 한 번만 경고하고 버린다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

local FOLDER_NAME = "Remotes"
local FOLDER_WAIT_SECONDS = 60

local folder = nil
local pending = {} -- { [name] = { fn, ... } } 아직 없는 이벤트에 걸어 둔 연결
local warned = {}

local function connect(remote, fn)
    remote.OnClientEvent:Connect(fn)
end

local function flush(child)
    if not child:IsA("RemoteEvent") then
        return
    end
    local list = pending[child.Name]
    if not list then
        return
    end
    pending[child.Name] = nil
    for _, fn in ipairs(list) do
        connect(child, fn)
    end
end

local function ensureFolder()
    if folder then
        return folder
    end
    folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
    if folder then
        folder.ChildAdded:Connect(flush)
    end
    return folder
end

task.spawn(function()
    if ensureFolder() then
        return
    end
    local found = ReplicatedStorage:WaitForChild(FOLDER_NAME, FOLDER_WAIT_SECONDS)
    if found and not folder then
        folder = found
        folder.ChildAdded:Connect(flush)
        for _, child in ipairs(folder:GetChildren()) do
            flush(child)
        end
    end
end)

-- 지금 있는 RemoteEvent (없으면 nil)
function Net.find(name)
    local f = ensureFolder()
    local remote = f and f:FindFirstChild(name)
    if remote and remote:IsA("RemoteEvent") then
        return remote
    end
    return nil
end

function Net.on(name, fn)
    local remote = Net.find(name)
    if remote then
        connect(remote, fn)
        return
    end
    pending[name] = pending[name] or {}
    table.insert(pending[name], fn)
end

function Net.fire(name, ...)
    local remote = Net.find(name)
    if remote then
        remote:FireServer(...)
        return true
    end
    if not warned[name] then
        warned[name] = true
        warn("[Net] RemoteEvent가 아직 없습니다: " .. tostring(name))
    end
    return false
end

return Net
