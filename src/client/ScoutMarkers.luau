--!nonstrict
-- 정찰 미션 표시 (C4, 멀티 두 번째 탐사대원). 내 역할 미션이 scout이고 아직 안 끝났으면, 아직 안 간 자리(targets)마다
-- 나에게만 보이는 표시를 놓는다: 바닥의 민트 원판과 그 위 BillboardGui(기지 아이콘, 자리 이름, "N m 거리").
-- 클라이언트가 만든 파트라 다른 플레이어에게 보이지 않는다(로컬 Folder "ScoutMarkers").
-- StreamingEnabled라 자리 근처 지형이 없을 수 있다. 서버 좌표 x, z를 쓰고, 높이는 아래로 광선을 쏴서 찾는다.
-- 지형이 아직 없으면 내 발 높이로 두고 HEIGHT_RETRY초마다 다시 찾는다.
-- 표시 판정은 ClientMath.scoutTargets(visited가 아닌 자리만), 거리는 ClientMath.toMeters(MissionConfig.metersPerStud).
-- 원판 지름은 서버 방문 판정 거리(roleMissions radius, 정찰 12 stud)의 두 배라 "이 원 안에 들어가면 된다"가 보인다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Icons = require(script.Parent.Icons)
local UI = require(script.Parent.UI)
local WorldPoints = require(script.Parent.WorldPoints)
local L = UI.Luna

local ScoutMarkers = {}

local FOLDER_NAME = "ScoutMarkers"
local RING_DIAMETER = 10 -- 서버 radius가 없을 때
local RING_THICKNESS = 0.3
local RING_TRANSPARENCY = 0.45
local SIGN_HEIGHT = 5 -- 원판 위 표지 높이 (stud)
local PROBE_UP = 200
local PROBE_DEPTH = 600
local FOOT_DROP = 3 -- 지형을 못 찾았을 때 내 HumanoidRootPart 아래로 이만큼
local HEIGHT_RETRY = 2
local DISTANCE_TICK = 0.25

local folder = nil
local markers = {} -- [mark] = { ring, anchor, gui, distanceLabel, x, z, grounded, lastProbe }
local active = false

local function ensureFolder()
    if folder and folder.Parent then
        return folder
    end
    folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME
    folder.Parent = workspace
    return folder
end

local function removeMarker(mark)
    local marker = markers[mark]
    if marker then
        marker.ring:Destroy()
        marker.anchor:Destroy()
        markers[mark] = nil
    end
end

local function clearAll()
    for mark in pairs(markers) do
        removeMarker(mark)
    end
end

-- 지면 높이. 못 찾으면 nil
local function groundY(x, z, referenceY)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = { ensureFolder() }
    local character = Players.LocalPlayer.Character
    if character then
        table.insert(exclude, character)
    end
    params.FilterDescendantsInstances = exclude
    params.IgnoreWater = true
    local top = Vector3.new(x, referenceY + PROBE_UP, z)
    local hit = workspace:Raycast(top, Vector3.new(0, -PROBE_DEPTH, 0), params)
    return hit and hit.Position.Y or nil
end

local function myPosition()
    return WorldPoints.character(Players.LocalPlayer)
end

-- 높이를 맞춘다 (지형을 찾으면 더는 찾지 않는다)
local function placeMarker(marker)
    local me = myPosition()
    local reference = if me then me.Y else 0
    local y = groundY(marker.x, marker.z, reference)
    marker.lastProbe = os.clock()
    if y then
        marker.grounded = true
    else
        y = reference - FOOT_DROP
    end
    marker.ring.CFrame = CFrame.new(marker.x, y + RING_THICKNESS / 2, marker.z)
        * CFrame.Angles(0, 0, math.rad(90))
    marker.anchor.CFrame = CFrame.new(marker.x, y + SIGN_HEIGHT, marker.z)
end

local function newPart(name, size)
    local part = Instance.new("Part")
    part.Name = name
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Size = size
    return part
end

local function addMarker(target)
    local root = ensureFolder()
    local diameter = if target.radius then target.radius * 2 else RING_DIAMETER
    local ring = newPart("Ring", Vector3.new(RING_THICKNESS, diameter, diameter))
    ring.Shape = Enum.PartType.Cylinder
    ring.Material = Enum.Material.Neon
    ring.Color = L.mint
    ring.Transparency = RING_TRANSPARENCY
    ring.Parent = root
    local anchor = newPart("Sign", Vector3.new(0.2, 0.2, 0.2))
    anchor.Transparency = 1
    anchor.Parent = root

    local nameLabel = UI.create("TextLabel", {
        Name = "Name",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 15,
        TextColor3 = L.white,
    }, { UI.worldStroke() })
    UI.msg(nameLabel, target.key or "rolemission.scout.badge")
    local icon = Icons.base(18, L.sky)
    icon.LayoutOrder = 1
    local distanceLabel = UI.create("TextLabel", {
        Name = "Distance",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 18),
        FontFace = UI.MonoBold,
        TextSize = 14,
        TextColor3 = L.mint,
    }, { UI.worldStroke() })
    local gui = UI.create("BillboardGui", {
        Name = "ScoutSign",
        Adornee = anchor,
        AlwaysOnTop = true,
        LightInfluence = 0,
        ResetOnSpawn = false,
        Size = UDim2.fromOffset(170, 48),
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
    }, {
        UI.create("Frame", {
            Name = "Panel",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = L.bgTop,
            BackgroundTransparency = 0.2,
        }, {
            UI.corner(10),
            UI.stroke(L.mint, 1.5, 0.3),
            UI.padding({ 4, 4, 8, 8 }),
            UI.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center),
            UI.create("Frame", {
                Name = "Top",
                LayoutOrder = 1,
                Size = UDim2.new(1, 0, 0, 20),
                BackgroundTransparency = 1,
            }, {
                UI.create("UIListLayout", {
                    FillDirection = Enum.FillDirection.Horizontal,
                    Padding = UDim.new(0, 6),
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    VerticalAlignment = Enum.VerticalAlignment.Center,
                    HorizontalAlignment = Enum.HorizontalAlignment.Center,
                }),
                icon,
                nameLabel,
            }),
            distanceLabel,
        }),
    })
    -- 표지는 원판과 함께 지운다
    anchor.Destroying:Connect(function()
        gui:Destroy()
    end)

    local marker = {
        ring = ring,
        anchor = anchor,
        gui = gui,
        distanceLabel = distanceLabel,
        x = target.x,
        z = target.z,
        grounded = false,
        lastProbe = -math.huge,
    }
    markers[target.mark] = marker
    placeMarker(marker)
end

local function refreshDistances()
    local me = myPosition()
    for _, marker in pairs(markers) do
        if not marker.grounded and os.clock() - marker.lastProbe >= HEIGHT_RETRY then
            placeMarker(marker)
        end
        if me then
            local studs = ClientMath.horizontalDistance(me, { X = marker.x, Z = marker.z })
            UI.msg(marker.distanceLabel, {
                key = "map.ice.distance",
                args = { n = ClientMath.toMeters(studs, MissionConfig.metersPerStud) },
            })
        end
    end
end

function ScoutMarkers.init(_ctx)
    task.spawn(function()
        while true do
            if active then
                local ok, err = pcall(refreshDistances)
                if not ok then
                    warn("[ScoutMarkers] " .. tostring(err))
                end
            end
            task.wait(DISTANCE_TICK)
        end
    end)
end

-- StateUpdate: 내 정찰 미션의 안 간 자리에 표시를 맞춘다 (플레이 중일 때만)
function ScoutMarkers.update(state)
    if type(state) ~= "table" then
        return
    end
    local raw = nil
    if
        state.phase == "playing"
        and state.mode ~= "solo"
        and type(state.roleMissions) == "table"
    then
        local userId = Players.LocalPlayer.UserId
        raw = state.roleMissions[tostring(userId)] or state.roleMissions[userId]
    end
    local targets = ClientMath.scoutTargets(raw)
    local wanted = {}
    for _, target in ipairs(targets) do
        wanted[target.mark] = true
        if not markers[target.mark] then
            addMarker(target)
        end
    end
    for mark in pairs(markers) do
        if not wanted[mark] then
            removeMarker(mark)
        end
    end
    active = next(markers) ~= nil
    if not active then
        clearAll()
    end
end

return ScoutMarkers
