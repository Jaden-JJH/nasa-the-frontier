--!nonstrict
-- 월드 위치 읽기 (CONTRACT_V2 1절, 7.5절). 콘솔 지도와 핀 화살표가 같이 쓴다. 읽기만 한다.
-- 이 플레이스는 StreamingEnabled가 켜져 있어(리드 확인, 반경 1024) 먼 파트는 클라이언트에 없을 수 있다.
-- 그래서 서버가 StateUpdate에 실어 보내는 좌표를 먼저 쓴다(setStatePoints):
-- - 얼음 후보지: state.ice[i].x, z (MinePoint 지면 좌표)
-- - 기지 표시: state.mapPoints[이름] = { x, z } (Lander, BaseExit, RoverPark, Airlock, SolarField, FarmPad, WaterTank)
-- - 보이는 로버: state.rover.x, z (자율주행 숨김 중에는 없음 -> 지도는 rover.fsd를 쓴다)
-- 서버 좌표에는 높이가 없으므로, 그 파트가 스트리밍되어 있으면 높이만 월드에서 가져온다.
-- 서버 좌표가 없을 때만 월드(Workspace.Mission<id>, MissionRuntime.IceSites, MissionRuntime.Rover)를 읽는다.

local WorldPoints = {}

-- 지도 경계에 넣는 기지 표시 (CONTRACT_V2 1절)
WorldPoints.BASE_MARKERS =
    { "Lander", "Airlock", "SolarField", "FarmPad", "WaterTank", "RoverPark", "BaseExit" }

local ROVER_SCAN_SECONDS = 2 -- 로버 모델을 MissionRuntime 전체에서 다시 찾는 최소 간격

local roverCache = nil
local lastRoverScan = -math.huge
local stateIce = {} -- [siteIndex] = Vector3 (서버 좌표, Y = 0)
local statePoints = {} -- [표시 이름] = Vector3 (서버 좌표, Y = 0)
local stateRover = nil -- Vector3 (서버 좌표, Y = 0)

local function vectorFrom(entry)
    if type(entry) == "table" and type(entry.x) == "number" and type(entry.z) == "number" then
        return Vector3.new(entry.x, if type(entry.y) == "number" then entry.y else 0, entry.z)
    end
    return nil
end

-- StateUpdate마다 서버 좌표를 기억한다 (없으면 비운다)
function WorldPoints.setStatePoints(state)
    stateIce = {}
    statePoints = {}
    stateRover = nil
    if type(state) ~= "table" then
        return
    end
    for _, site in ipairs(type(state.ice) == "table" and state.ice or {}) do
        local v = vectorFrom(site)
        if v and type(site.index) == "number" then
            stateIce[site.index] = v
        end
    end
    if type(state.mapPoints) == "table" then
        for name, entry in pairs(state.mapPoints) do
            statePoints[name] = vectorFrom(entry)
        end
    end
    stateRover = vectorFrom(state.rover)
end

local function positionOf(inst)
    if not inst then
        return nil
    end
    if inst:IsA("BasePart") then
        return inst.Position
    elseif inst:IsA("Model") then
        return inst:GetPivot().Position
    elseif inst:IsA("Attachment") then
        return inst.WorldPosition
    end
    return nil
end
WorldPoints.positionOf = positionOf

function WorldPoints.missionFolder(missionId)
    return workspace:FindFirstChild("Mission" .. tostring(missionId or "C"))
end

function WorldPoints.runtime()
    return workspace:FindFirstChild("MissionRuntime")
end

-- 서버 좌표(X, Z)에 월드 높이를 붙인다. 반환: 위치, 높이를 믿을 수 있는지
local function merge(fromState, fromWorld)
    if fromState then
        if fromWorld then
            return Vector3.new(fromState.X, fromWorld.Y, fromState.Z), true
        end
        return fromState, false
    end
    return fromWorld, fromWorld ~= nil
end

local function worldMarker(name, missionId)
    local folder = WorldPoints.missionFolder(missionId)
    return positionOf(folder and folder:FindFirstChild(name))
end

-- 기지 표시 위치 (없으면 nil). 두 번째 값: 높이(Y)를 믿을 수 있는지
function WorldPoints.marker(name, missionId)
    return merge(statePoints[name], worldMarker(name, missionId))
end

local function worldIceSite(siteIndex, markerName, missionId)
    local runtime = WorldPoints.runtime()
    local folder = runtime and runtime:FindFirstChild("IceSites")
    if folder then
        for _, model in ipairs(folder:GetChildren()) do
            if model:GetAttribute("SiteIndex") == siteIndex then
                return positionOf(model:FindFirstChild("MinePoint") or model)
            end
        end
        local model = markerName and folder:FindFirstChild(markerName)
        if model then
            return positionOf(model:FindFirstChild("MinePoint") or model)
        end
    end
    return markerName and worldMarker(markerName, missionId) or nil
end

-- 얼음 후보지 위치 (siteIndex = 출구에서 가까운 순, state.ice[i].index). 두 번째 값: 높이를 믿을 수 있는지
function WorldPoints.iceSite(siteIndex, markerName, missionId)
    return merge(stateIce[siteIndex], worldIceSite(siteIndex, markerName, missionId))
end

local function isRoverModel(inst)
    return inst:IsA("Model")
        and (inst:GetAttribute("Role") == "rover" or inst:GetAttribute("AssetRole") == "Rover")
end

-- 직접 운전 로버 Model (MissionRuntime.Rover, 없으면 드물게 전체에서 찾는다). 자율주행 중에는 숨겨져 없다
function WorldPoints.roverModel()
    if roverCache and roverCache.Parent then
        return roverCache
    end
    roverCache = nil
    local runtime = WorldPoints.runtime()
    if not runtime then
        return nil
    end
    local direct = runtime:FindFirstChild("Rover")
    if direct and direct:IsA("Model") then
        roverCache = direct
        return direct
    end
    if os.clock() - lastRoverScan < ROVER_SCAN_SECONDS then
        return nil
    end
    lastRoverScan = os.clock()
    for _, inst in ipairs(runtime:GetDescendants()) do
        if isRoverModel(inst) then
            roverCache = inst
            return inst
        end
    end
    return nil
end

-- 보이는 로버 위치. 가까이 있어 스트리밍된 모델이 있으면 그 위치(실시간), 없으면 서버 좌표
function WorldPoints.rover()
    local model = WorldPoints.roverModel()
    if model then
        return model:GetPivot().Position
    end
    return stateRover
end

-- 플레이어 캐릭터의 HumanoidRootPart 위치
function WorldPoints.character(player)
    local character = player and player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return root and root.Position or nil
end

return WorldPoints
