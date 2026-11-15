-- MissionWorld 스모크 테스트. tests/run_world.luau가 place를 빌드해 하위 프로세스로 실행한다.
-- rojo build 결과 place를 Lune로 읽고, Studio MissionC 실측 좌표로 표시 픽스처와 ServerStorage.Assets(그린하우스, 키트)를
-- 만든 뒤 MissionWorld만 불러 init -> 에셋 대체 -> placeBase -> 시설 건설 연출 -> 동기화 -> reset을 가상 시계로 돌린다.
-- Lune에 없는 Roblox API(PivotTo, ScaleTo, Raycast, task)는 흉내 낸다. 지형은 실측 지면 높이를 보간한 함수다.
--
-- 단독 실행: rojo build default.project.json -o build/world_smoke.rbxl && lune run tests/world_smoke.luau build/world_smoke.rbxl

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local placePath = process.args[1] or "build/world_smoke.rbxl"
local dm = roblox.deserializePlace(fs.readFile(placePath))

local Instance, Vector3, CFrame, Color3, Enum =
    roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Color3, roblox.Enum

local failures = 0
local passes = 0
local function check(cond: any, label: string)
    if cond then
        passes += 1
        print("  OK   " .. label)
    else
        failures += 1
        print("  FAIL " .. label)
    end
end

-- 가상 시계와 task 스케줄러 (server_smoke와 같은 방식) -----------------------
local now = 0
local queue = {}
local threadErrors = 0
local function resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        threadErrors += 1
        print("THREAD ERROR: " .. tostring(err))
        print(debug.traceback(co))
    end
end
local function schedule(co, at, ...)
    table.insert(queue, { thread = co, at = at, args = table.pack(...) })
end
local task = {}
function task.spawn(f, ...)
    local co = if type(f) == "thread" then f else coroutine.create(f)
    resume(co, ...)
    return co
end
function task.defer(f, ...)
    local co = coroutine.create(f)
    schedule(co, now, ...)
    return co
end
function task.delay(t, f, ...)
    local co = coroutine.create(f)
    schedule(co, now + (t or 0), ...)
    return co
end
function task.wait(t)
    local start = now
    schedule(coroutine.running(), now + math.max(t or 0, 1 / 60))
    coroutine.yield()
    return now - start
end
function task.cancel(co)
    for i = #queue, 1, -1 do
        if queue[i].thread == co then
            table.remove(queue, i)
        end
    end
end
local function advance(seconds: number)
    local target = now + seconds
    while true do
        local bestIndex, best = nil, nil
        for i, item in queue do
            if item.at <= target and (best == nil or item.at < best.at) then
                bestIndex, best = i, item
            end
        end
        if not best then
            break
        end
        table.remove(queue, bestIndex)
        now = math.max(now, best.at)
        if coroutine.status(best.thread) == "suspended" then
            resume(best.thread, table.unpack(best.args, 1, best.args.n))
        end
    end
    now = target
end

-- Roblox API 보충 -------------------------------------------------------
local function modelPivot(model)
    if model.PrimaryPart then
        return model.PrimaryPart.CFrame
    end
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            return d.CFrame
        end
    end
    return CFrame.new()
end
roblox.implementMethod("Model", "GetPivot", function(model)
    return modelPivot(model)
end)
roblox.implementMethod("Model", "PivotTo", function(model, target)
    local delta = target * modelPivot(model):Inverse()
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            d.CFrame = delta * d.CFrame
        end
    end
end)
roblox.implementMethod("Model", "GetScale", function(model)
    return model:GetAttribute("__scale") or 1
end)
roblox.implementMethod("Model", "ScaleTo", function(model, newScale)
    local factor = newScale / (model:GetAttribute("__scale") or 1)
    local pivot = modelPivot(model)
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            local rel = pivot:ToObjectSpace(d.CFrame)
            d.Size = d.Size * factor
            d.CFrame = pivot * CFrame.new(rel.Position * factor) * (rel - rel.Position)
        end
    end
    model:SetAttribute("__scale", newScale)
end)

-- 지형: 호출하면 기록만 한다 (MissionWorld는 지형을 절대 바꾸지 않아야 한다)
local terrainCalls = {}
for _, method in
    {
        "FillBlock",
        "FillBall",
        "FillCylinder",
        "FillWedge",
        "FillRegion",
        "Clear",
        "ReplaceMaterial",
        "WriteVoxels",
    }
do
    roblox.implementMethod("Terrain", method, function()
        table.insert(terrainCalls, method)
    end)
end

-- 표시 중심 아래 지면 높이를 역거리 가중으로 보간한 지면 (기지는 추정, 얼음은 실측. 아래 표 주석)
local GROUND_SAMPLES = {
    -- 기지 표시 8개: 2026-11-15 옮긴 자리의 표시 중심 아래 지면 실측 (리드 전달, BaseExit는 다시 옮긴 자리).
    -- 얼음 5곳은 2026-11-14 실측 그대로 (얼음은 옮기지 않았다)
    { -65.69, 63.42, -24.60 }, -- Lander (실측)
    { -73.68, 37.61, -23.72 }, -- SpawnLocation (실측)
    { -174.68, 40.11, -22.61 }, -- SolarField (실측)
    { -231.13, 49.11, -23.02 }, -- FarmPad (실측)
    { -268.18, -93.89, -17.17 }, -- WaterTank (실측)
    { -131.18, 2.11, -21.24 }, -- RoverPark (실측)
    { -38.20, -43.09, -19.69 }, -- BaseExit (실측)
    { -119.2, 81.4, -23.47 }, -- Airlock (실측)
    { 576.5, -245.5, -4.3 }, -- Ice1
    { 664.0, -663.7, -4.1 }, -- Ice2
    { 759.9, -183.8, -0.4 }, -- Ice3
    { 328.0, -232.0, -28.8 }, -- Ice4
    { -296.1, -375.9, -15.4 }, -- Ice5
}
-- 얼음 후보지 둘레 ICE_SLOPE_RADIUS 안은 크레이터 경사처럼 기울인다 (S12: Studio Ice5에서 덩어리 자리마다 지면이 0.6쯤 달랐다).
-- 표시 중심에서는 0이라 실측 높이 그대로
local ICE_SLOPE = { x = 0.06, z = -0.04 }
local ICE_SLOPE_RADIUS = 30
local function groundAt(x: number, z: number): number
    local sum, weight = 0, 0
    local base: number? = nil
    for _, s in GROUND_SAMPLES do
        local d2 = (x - s[1]) ^ 2 + (z - s[2]) ^ 2
        if d2 < 1e-6 then
            base = s[3]
            break
        end
        local w = 1 / d2
        sum += w * s[3]
        weight += w
    end
    local g = base or sum / weight
    for i = 9, #GROUND_SAMPLES do -- 얼음 5곳 (표 끝)
        local s = GROUND_SAMPLES[i]
        local dx, dz = x - s[1], z - s[2]
        if dx * dx + dz * dz <= ICE_SLOPE_RADIUS * ICE_SLOPE_RADIUS then
            g += ICE_SLOPE.x * dx + ICE_SLOPE.z * dz
        end
    end
    return g
end

local terrainInstance = Instance.new("Terrain")
terrainInstance.Parent = dm:GetService("Workspace")
local raycasts = { total = 0, terrainOnly = 0 }
roblox.implementMethod("Workspace", "Raycast", function(_, origin, direction, params)
    raycasts.total += 1
    local filter = params and params.FilterDescendantsInstances
    if
        not params
        or params.FilterType ~= Enum.RaycastFilterType.Include
        or not filter
        or filter[1] ~= terrainInstance
    then
        return nil
    end
    raycasts.terrainOnly += 1
    local g = groundAt(origin.X, origin.Z)
    if origin.Y >= g and origin.Y + direction.Y <= g then
        return {
            Position = Vector3.new(origin.X, g, origin.Z),
            Instance = terrainInstance,
            Normal = Vector3.yAxis,
        }
    end
    return nil
end)

-- 픽스처 ----------------------------------------------------------------
local Workspace = dm:GetService("Workspace")
local ServerStorage = dm:GetService("ServerStorage")
local Lighting = dm:GetService("Lighting")
local ReplicatedStorage = dm:GetService("ReplicatedStorage")

Lighting.ClockTime = 3.5
Lighting.Brightness = 7
local lightingBefore = { clock = Lighting.ClockTime, brightness = Lighting.Brightness }

local fixture = {}
fixture.missionC = Instance.new("Folder")
fixture.missionC.Name = "MissionC"
fixture.missionC.Parent = Workspace

-- Studio Part.Orientation(도) -> CFrame (Roblox ToOrientation과 같은 Y, X, Z 순서)
local function orient(x: number, y: number, z: number)
    return CFrame.fromOrientation(math.rad(x), math.rad(y), math.rad(z))
end
function fixture.marker(name: string, className: string, pos, size, rot, shape)
    local part = Instance.new(className)
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(pos) * rot
    part.Anchored = false -- Studio 실측: 표시가 Anchored = false
    part.Transparency = if name == "FarmPad" then 1 else 0
    if shape then
        part.Shape = shape
    end
    part.Parent = fixture.missionC
    return part
end
-- 2026-11-15 Studio 실측 (리드 전달, 사용자 결정으로 C 기지를 옮긴 뒤). 방향은 ToOrientation(도) 그대로
fixture.marker(
    "Lander",
    "Part",
    Vector3.new(-65.69, -12.59, 63.42),
    Vector3.new(28, 118, 12),
    orient(0.1, 90.0, 92.8),
    Enum.PartType.Cylinder
)
fixture.marker(
    "Airlock",
    "Part",
    Vector3.new(-119.2, -15.0, 81.4),
    Vector3.new(43, 17, 43),
    orient(0, 0, 0)
) -- S9: 원기둥(지름 9)에서 Block으로 (원래 값은 Studio 표시 Attribute OriginalShape, OriginalSize, OriginalCFrame)
fixture.marker(
    "SpawnLocation",
    "SpawnLocation",
    Vector3.new(-73.68, -23.63, 37.61),
    Vector3.new(12, 1, 12),
    orient(0, 90, 0)
)
fixture.marker(
    "SolarField",
    "Part",
    Vector3.new(-174.68, -16.91, 40.11),
    Vector3.new(82, 5, 49),
    orient(0, 90, 0)
)
fixture.marker(
    "FarmPad",
    "Part",
    Vector3.new(-231.13, -11.53, 49.11),
    Vector3.new(31, 20, 25),
    orient(0, -90, 0)
)
fixture.marker(
    "WaterTank",
    "Part",
    Vector3.new(-268.18, -7.29, -93.89),
    Vector3.new(31, 20, 25),
    orient(0, -90, 0)
)
fixture.marker(
    "RoverPark",
    "Part",
    Vector3.new(-131.18, -19.95, 2.11),
    Vector3.new(31, 4, 25),
    orient(0, -90, 0)
)
fixture.marker(
    "BaseExit",
    "Part",
    Vector3.new(-38.20, -18.19, -43.09),
    Vector3.new(31, 4, 25),
    orient(0, -56.3, 0)
) -- 리드가 얼음 쪽으로 다시 옮김: CFrame.lookAt(pos, 얼음 무게중심 (406, y, -340))
for i, pos in
    {
        Vector3.new(576.50, -3.93, -245.50),
        Vector3.new(663.96, -2.28, -663.72),
        Vector3.new(759.92, 1.47, -183.77),
        Vector3.new(327.98, -26.90, -231.96),
        Vector3.new(-296.10, -13.58, -375.90),
    }
do
    fixture.marker("Ice" .. i, "Part", pos, Vector3.new(31, 4, 25), orient(0, -90, 0))
end
fixture.originalCFrames = {}
for _, child in fixture.missionC:GetChildren() do
    fixture.originalCFrames[child.Name] = child.CFrame
end

-- ServerStorage.Assets: 그린하우스(이름은 실제 에셋과 같다)와 키트 19종 중 쓰는 것
fixture.assets = Instance.new("Folder")
fixture.assets.Name = "Assets"
fixture.assets.Parent = ServerStorage
function fixture.mesh(parent, name: string, size, offset, props)
    local part = Instance.new("MeshPart")
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(offset)
    part.Anchored = true
    part.CanCollide = false
    for key, value in props or {} do
        part[key] = value
    end
    part.Parent = parent
    return part
end
do
    local gh = Instance.new("Model")
    gh.Name = "Greenhouse"
    gh:SetAttribute("Role", "facility.farm")
    gh:SetAttribute("SourceFile", "assets/models/Greenhouse.fbx")
    gh:SetAttribute("AssetId", 88099979185265)
    local o = Vector3.new(-30, -3121, -1086) -- 실제 에셋처럼 멀리 떨어진 원본 위치
    gh.PrimaryPart = fixture.mesh(
        gh,
        "Greenhouse_Frame_Base",
        Vector3.new(27.2, 16.8, 27.2),
        o + Vector3.new(0, 8.4, 0),
        { Material = Enum.Material.Metal }
    )
    fixture.mesh(
        gh,
        "Dome_Glass_Panels",
        Vector3.new(23, 11.1, 23.7),
        o + Vector3.new(0, 11, 0),
        { Material = Enum.Material.Glass, Transparency = 0.6 }
    )
    fixture.mesh(
        gh,
        "Central_Walkway",
        Vector3.new(2.4, 0.2, 17.8),
        o + Vector3.new(0, 0.6, 0),
        { CanCollide = true, Material = Enum.Material.DiamondPlate }
    )
    fixture.mesh(
        gh,
        "Leafy_Crops",
        Vector3.new(12.4, 1.4, 11.7),
        o + Vector3.new(0, 3.4, 0),
        { Color = Color3.fromRGB(95, 175, 80) }
    )
    local suffix = { "", ".001", ".002", ".003" }
    local spots = { { -4, -3.4 }, { 4, -3.4 }, { -4, 3.4 }, { 4, 3.4 } }
    for i = 1, 4 do
        fixture.mesh(
            gh,
            "Grow_LED_Bar" .. suffix[i],
            Vector3.new(3.5, 0.2, 0.2),
            o + Vector3.new(spots[i][1], 13, spots[i][2]),
            {
                Material = Enum.Material.Neon,
                Color = Color3.fromRGB(255, 120, 220),
            }
        )
        fixture.mesh(
            gh,
            "Hydroponic_Bed" .. suffix[i],
            Vector3.new(4.3, 1, 4.9),
            o + Vector3.new(spots[i][1], 1.5, spots[i][2]),
            {
                Color = Color3.fromRGB(235, 236, 240),
            }
        )
        fixture.mesh(
            gh,
            "Bed_Leg" .. suffix[i],
            Vector3.new(0.3, 1, 0.3),
            o + Vector3.new(spots[i][1], 0.5, spots[i][2])
        )
    end
    gh.Parent = fixture.assets
    fixture.greenhouse = gh
end
fixture.kit = Instance.new("Folder")
fixture.kit.Name = "Kit"
fixture.kit.Parent = fixture.assets
for name, size in
    {
        HabitatA = Vector3.new(3.99, 4.31, 7.79),
        HabitatB = Vector3.new(8.53, 4.97, 8.53),
        HabitatC = Vector3.new(8.53, 5.28, 8.53),
        Lander = Vector3.new(5.61, 4.32, 5.61),
        Panel = Vector3.new(1.29, 1.10, 1.67),
        WaterTank = Vector3.new(3.99, 4.0, 3.8),
        Crop = Vector3.new(2.12, 2.98, 1.44),
        Connector = Vector3.new(3.37, 2.21, 2.17),
        ConnectorElbow = Vector3.new(7.8, 4.31, 7.79),
        IceCrystal = Vector3.new(5.31, 7.43, 5.19),
        Rover = Vector3.new(4.58, 4.88, 6.56),
        Crate = Vector3.new(0.87, 0.86, 0.9),
        Antenna = Vector3.new(1.41, 3.54, 1.43),
    }
do
    -- 실제 키트처럼 Model 안에 Model, 그 안에 MeshPart
    local outer = Instance.new("Model")
    outer.Name = name
    local inner = Instance.new("Model")
    inner.Name = name
    inner.Parent = outer
    fixture.mesh(inner, name, size, Vector3.new(-3, 20, -10))
    outer.Parent = fixture.kit
end
-- 디자이너 물탱크: 긴 축 Z, 문과 경사로가 앞(-Z), 뒤쪽 설비가 뒤(+Z). 경계 X -8.35..8.35, Y -0.15..11.66, Z -18.46..12.54
-- 각 항목: 이름, 중심(원본 좌표), 크기, 충돌
function fixture.box(model, name: string, center, size, collide: boolean?, offset)
    local part = fixture.mesh(model, name, size, offset + center)
    part.CanCollide = collide == true
    return part
end
do
    local tank = Instance.new("Model")
    tank.Name = "WaterTank"
    tank:SetAttribute("AssetId", 99174776271901)
    tank:SetAttribute("Role", "world.water_tank")
    local o = Vector3.new(120, 340, 75)
    local b = fixture.box
    b(
        tank,
        "Main_Pressurized_Hull",
        Vector3.new(0, 6.085, 0),
        Vector3.new(15.05, 10.41, 19.56),
        true,
        o
    )
    b(tank, "Front_Door", Vector3.new(0, 4.975, -10.5), Vector3.new(11.31, 7.39, 0.15), false, o)
    b(
        tank,
        "Front_Blue_End_Cap",
        Vector3.new(0, 6.075, -10.03),
        Vector3.new(14.64, 10.33, 0.5),
        false,
        o
    )
    b(
        tank,
        "Entrance_Ramp_Panel_1",
        Vector3.new(0, 0.97, -11.34),
        Vector3.new(8.63, 0.5, 1.58),
        true,
        o
    )
    b(
        tank,
        "Entrance_Ramp_Panel_5",
        Vector3.new(0, 0.10, -17.66),
        Vector3.new(8.63, 0.5, 1.58),
        true,
        o
    )
    b(
        tank,
        "Rear_Utility_Housing",
        Vector3.new(0, 4.96, 11.22),
        Vector3.new(12.54, 8.4, 2.63),
        false,
        o
    )
    b(
        tank,
        "Side_Access_Panel",
        Vector3.new(7.72, 4.395, 0.38),
        Vector3.new(0.18, 4.79, 11.36),
        false,
        o
    )
    b(
        tank,
        "Side_Access_Panel.001",
        Vector3.new(-7.72, 4.395, 0.38),
        Vector3.new(0.18, 4.79, 11.36),
        false,
        o
    )
    for i, spot in { { 8.05, 5 }, { -8.05, 5 }, { 8.05, -5 }, { -8.05, -5 } } do
        b(
            tank,
            "Side_Foot" .. (if i > 1 then "." .. i else ""),
            Vector3.new(spot[1], 0.35, spot[2]),
            Vector3.new(0.6, 1, 1),
            false,
            o
        )
    end
    b(tank, "Blue_Roof_Segment_1", Vector3.new(0, 11.46, 0), Vector3.new(8, 0.4, 6), false, o)
    tank.Parent = fixture.assets
    fixture.tank = tank
end
-- 디자이너 에어록 (S9, 에셋 114535234500422): 캡슐 모듈 2개가 나란히 이어진 텍스처 메시 1개, 축척 0.0251 적용 뒤 30.6 x 17.0 x 42.4.
-- 해치는 로컬 -Z 면에 2개, 계단 해치는 로컬 X 약 -7.6 (Attribute DoorOffsetX). 가운데는 연결 통로
do
    local airlock = Instance.new("Model")
    airlock.Name = "Airlock"
    airlock:SetAttribute("SourceFile", "assets/models/Airlock.fbx")
    airlock:SetAttribute("AssetId", 114535234500422)
    airlock:SetAttribute("Role", "facility.airlock")
    airlock:SetAttribute("DoorOffsetX", -7.6)
    airlock.PrimaryPart = fixture.mesh(
        airlock,
        "Connected_Habitat",
        Vector3.new(30.6, 17.0, 42.4),
        Vector3.new(400, 60, -800)
    )
    airlock.Parent = fixture.assets
    fixture.airlock = airlock
end
-- 디자이너 파이프: 원본 경계 최소점 (-2.34, -2.81, -2.34). 고리는 +X 끝, 받침(Ground_Base) 밑면은 바닥에서 2.66 위
do
    local pipe = Instance.new("Model")
    pipe.Name = "Pipe"
    pipe:SetAttribute("AssetId", 125305563695112)
    pipe:SetAttribute("Role", "facility.pipe")
    local o = Vector3.new(-200, 280, 40) + Vector3.new(-2.34, -2.81, -2.34)
    local b = fixture.box
    b(
        pipe,
        "Buried_Sleeve.002",
        Vector3.new(2.335, 1.28, 2.335),
        Vector3.new(3.31, 2.56, 3.31),
        false,
        o
    )
    b(
        pipe,
        "Ground_Base.002",
        Vector3.new(2.335, 2.86, 2.335),
        Vector3.new(4.67, 0.4, 4.67),
        true,
        o
    )
    b(
        pipe,
        "Ground_Seal.002",
        Vector3.new(2.34, 3.21, 2.34),
        Vector3.new(3.52, 0.46, 3.52),
        false,
        o
    )
    b(
        pipe,
        "Tank_Connector_Ring.002",
        Vector3.new(9.81, 8.325, 2.34),
        Vector3.new(0.6, 3.85, 3.86),
        false,
        o
    )
    b(
        pipe,
        "Thicker_Grey_Elbow",
        Vector3.new(5.32, 4.965, 2.335),
        Vector3.new(9.08, 9.83, 3.11),
        true,
        o
    )
    pipe.Parent = fixture.assets
    fixture.pipe = pipe
end
fixture.preview = Instance.new("Folder")
fixture.preview.Name = "AssetPreview"
fixture.greenhouse:Clone().Parent = fixture.preview
fixture.preview.Parent = Workspace

-- 가짜 플레이어 (갇힘 방지 검사): 표 + 캐릭터 Model(HumanoidRootPart, Humanoid) -----------------
local fakePlayers = {}
roblox.implementMethod("Players", "GetPlayers", function()
    return table.clone(fakePlayers)
end)
local function addFakePlayer(name: string, position)
    local character = Instance.new("Model")
    character.Name = name
    local root = Instance.new("Part")
    root.Name = "HumanoidRootPart"
    root.Size = Vector3.new(2, 2, 1)
    root.Anchored = true
    root.CanCollide = false
    root.CFrame = CFrame.new(position)
    root.Parent = character
    character.PrimaryPart = root
    local humanoid = Instance.new("Humanoid")
    humanoid.Parent = character
    character.Parent = Workspace
    local p = { Name = name, UserId = #fakePlayers + 1, Character = character }
    table.insert(fakePlayers, p)
    return p
end
local function rootOf(p)
    return p.Character:FindFirstChild("HumanoidRootPart")
end
local function clearFakePlayers()
    for _, p in fakePlayers do
        p.Character:Destroy()
    end
    table.clear(fakePlayers)
end

-- 모듈 로더 -------------------------------------------------------------
local warnings = {}
local cache = {}
local loadModule
local function makeEnv(scriptInst)
    return {
        script = scriptInst,
        game = dm,
        workspace = Workspace,
        require = function(target)
            return loadModule(target)
        end,
        task = task,
        warn = function(...)
            local text = table.concat(table.pack(...), " ")
            table.insert(warnings, text)
            print("WARN " .. text)
        end,
        print = print,
        Instance = Instance,
        Vector3 = Vector3,
        CFrame = CFrame,
        Color3 = Color3,
        UDim = roblox.UDim,
        UDim2 = roblox.UDim2,
        Vector2 = roblox.Vector2,
        Enum = Enum,
        RaycastParams = {
            new = function()
                return {}
            end,
        },
        math = math,
        string = string,
        table = table,
        coroutine = coroutine,
        debug = debug,
        pcall = pcall,
        xpcall = xpcall,
        error = error,
        assert = assert,
        type = type,
        typeof = typeof,
        tostring = tostring,
        tonumber = tonumber,
        pairs = pairs,
        ipairs = ipairs,
        next = next,
        select = select,
        setmetatable = setmetatable,
        getmetatable = getmetatable,
        rawget = rawget,
        rawset = rawset,
        utf8 = utf8,
        os = {
            clock = function()
                return now
            end,
            time = os.time,
            date = os.date,
        },
    }
end
function loadModule(target)
    local key = target:GetFullName()
    if cache[key] ~= nil then
        return cache[key]
    end
    local fn = luau.load(
        target.Source,
        { debugName = key, environment = makeEnv(target), injectGlobals = false }
    )
    local result = fn()
    cache[key] = result
    return result
end

local Server = dm:GetService("ServerScriptService"):FindFirstChild("Server")
local MissionWorld = loadModule(Server:FindFirstChild("MissionWorld"))

-- 검사 도우미 ------------------------------------------------------------
local H = {}
function H.insidePart(part, point): boolean
    local p = part.CFrame:PointToObjectSpace(point)
    local h = part.Size / 2
    return math.abs(p.X) <= h.X + 1e-6
        and math.abs(p.Y) <= h.Y + 1e-6
        and math.abs(p.Z) <= h.Z + 1e-6
end
function H.bounds(root)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    local parts = {}
    if root:IsA("BasePart") then
        table.insert(parts, root)
    end
    for _, d in root:GetDescendants() do
        if d:IsA("BasePart") then
            table.insert(parts, d)
        end
    end
    for _, part in parts do
        local cf, half = part.CFrame, part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local q = cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                    lo = Vector3.new(math.min(lo.X, q.X), math.min(lo.Y, q.Y), math.min(lo.Z, q.Z))
                    hi = Vector3.new(math.max(hi.X, q.X), math.max(hi.Y, q.Y), math.max(hi.Z, q.Z))
                end
            end
        end
    end
    return lo, hi
end
-- frame 좌표계 경계 (회전된 건물을 로컬 축으로 본다)
function H.boundsIn(root, frame)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    local parts = {}
    if root:IsA("BasePart") then
        table.insert(parts, root)
    end
    for _, d in root:GetDescendants() do
        if d:IsA("BasePart") then
            table.insert(parts, d)
        end
    end
    for _, part in parts do
        local cf, half = part.CFrame, part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local q = frame:PointToObjectSpace(
                        cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                    )
                    lo = Vector3.new(math.min(lo.X, q.X), math.min(lo.Y, q.Y), math.min(lo.Z, q.Z))
                    hi = Vector3.new(math.max(hi.X, q.X), math.max(hi.Y, q.Y), math.max(hi.Z, q.Z))
                end
            end
        end
    end
    return lo, hi
end
-- 수평 방향 dir로 본 위치 (dir은 단위 벡터)
function H.along(v, dir): number
    return v.X * dir.X + v.Z * dir.Z
end
-- 축 정렬 경계 lo..hi를 수평 방향 dir로 본 최소, 최대 (네 모서리)
function H.alongRange(lo, hi, dir): (number, number)
    local a, b = math.huge, -math.huge
    for _, x in { lo.X, hi.X } do
        for _, z in { lo.Z, hi.Z } do
            local v = x * dir.X + z * dir.Z
            a = math.min(a, v)
            b = math.max(b, v)
        end
    end
    return a, b
end
function H.find(root, path: string)
    local node = root
    for name in string.gmatch(path, "[^%.]+") do
        node = node and node:FindFirstChild(name)
    end
    return node
end
function H.label(root)
    for _, d in root:GetDescendants() do
        if d:IsA("TextLabel") then
            return d
        end
    end
    return nil
end
function H.countPrefix(root, prefix: string): number
    local n = 0
    for _, d in root:GetDescendants() do
        if d:IsA("BasePart") and string.sub(d.Name, 1, #prefix) == prefix then
            n += 1
        end
    end
    return n
end
function H.allParts(parts, predicate): boolean
    if #parts == 0 then
        return false
    end
    for _, part in parts do
        if not predicate(part) then
            return false
        end
    end
    return true
end
function H.near(a: number, b: number, tolerance: number?): boolean
    return math.abs(a - b) <= (tolerance or 1e-3)
end
function H.markerBox(name: string, margin: number)
    local info = MissionWorld.getMarker(name)
    local half = info.extents / 2 + Vector3.new(margin, 0, margin)
    return info.position - half, info.position + half
end
function H.withinXZ(lo, hi, boxLo, boxHi): boolean
    return lo.X >= boxLo.X - 1e-3
        and lo.Z >= boxLo.Z - 1e-3
        and hi.X <= boxHi.X + 1e-3
        and hi.Z <= boxHi.Z + 1e-3
end

print("[월드 스모크]")

-- init --------------------------------------------------------------------
print("[init]")
local runtime
do
    local ok, missing = MissionWorld.init("C")
    check(ok == true and #missing == 0, "init: 필수 표시 모두 있음")
    runtime = Workspace:FindFirstChild("MissionRuntime")
    check(runtime ~= nil and runtime:IsA("Folder"), "init: Workspace.MissionRuntime 생성")
    check(fixture.preview.Parent == nil, "init: AssetPreview를 떼어 둔다 (Parent = nil)")
    check(
        MissionWorld.previewReference() == fixture.preview,
        "init: 떼어 둔 AssetPreview 참조 유지"
    )
    local hidden, anchored, moved = true, true, false
    for _, child in fixture.missionC:GetChildren() do
        if child.Name ~= "SpawnLocation" and (child.Transparency ~= 1 or child.CanCollide) then
            hidden = false
        end
        if not child.Anchored then
            anchored = false
        end
        if child.CFrame ~= fixture.originalCFrames[child.Name] then
            moved = true
        end
    end
    check(hidden, "init: 표시 Part는 실행 중 숨김 (투명, 충돌 없음)")
    check(anchored, "init: 표시 Part는 실행 중 고정 (Studio는 Anchored = false)")
    check(not moved, "init: 표시 위치는 바꾸지 않는다")
    check(
        fixture.missionC.SpawnLocation.Transparency == 0,
        "init: SpawnLocation은 그대로 보인다"
    )
    local lander = MissionWorld.getMarker("Lander")
    check(lander.shape == "Cylinder", "init: 착륙선 표시 모양 Cylinder")
    check(
        H.near(lander.extents.X, 12.05, 0.01)
            and H.near(lander.extents.Y, 28.57, 0.01)
            and H.near(lander.extents.Z, 13.35, 0.01),
        "init: 세운 원기둥(2.8도 기울어짐) 경계 12.05 x 28.57 x 13.35 ("
            .. tostring(lander.extents)
            .. ")"
    )
    check(
        lander.groundFound and H.near(lander.groundSamples[1], -24.60, 0.01),
        "init: 표시 아래 지면 높이 읽기"
    )
end

-- resolveAsset --------------------------------------------------------------
print("[resolveAsset]")
do
    local gh, source = MissionWorld.resolveAsset("Greenhouse")
    check(
        source == "asset" and gh:GetAttribute("AssetSource") == "asset",
        "에셋: Assets.Greenhouse 1단계"
    )
    check(
        H.countPrefix(gh, "Grow_LED_Bar") == 4 and H.countPrefix(gh, "Hydroponic_Bed") == 4,
        "에셋: LED 바 4, 수경 베드 4 복제"
    )
    check(
        fixture.greenhouse.Parent == fixture.assets and gh ~= fixture.greenhouse,
        "에셋: 원본은 그대로, 복제본을 준다"
    )
    gh:Destroy()

    local tankModel, tankSource = MissionWorld.resolveAsset("WaterTank")
    local pipeModel, pipeSource = MissionWorld.resolveAsset("Pipe")
    check(
        tankSource == "asset" and pipeSource == "asset",
        "에셋: 디자이너 WaterTank, Pipe 1단계"
    )
    tankModel:Destroy()
    pipeModel:Destroy()

    local landerModel, landerSource = MissionWorld.resolveAsset("Lander")
    check(
        landerSource == "kit" and landerModel:FindFirstChild("Main") ~= nil,
        "에셋: Lander는 Kit 2단계"
    )
    landerModel:Destroy()
    fixture.pipe.Name = "PipeOff" -- 디자이너 Pipe를 잠시 빼서 2단계 조합을 본다
    local pipe, kitPipeSource = MissionWorld.resolveAsset("Pipe")
    fixture.pipe.Name = "Pipe"
    check(
        kitPipeSource == "kit" and pipe:FindFirstChild("ConnectorElbow1") ~= nil,
        "에셋: Pipe = Connector + ConnectorElbow 조합"
    )
    local plo, phi = H.bounds(pipe:FindFirstChild("Main"))
    local elo = H.bounds(pipe:FindFirstChild("ConnectorElbow1"))
    check(
        H.near(elo.X, phi.X, 0.01) and plo.X < elo.X,
        "에셋: 엘보는 본체 +X 끝에 붙는다"
    )
    pipe:Destroy()

    fixture.greenhouse.Name = "GreenhouseOff"
    local kitGh, kitSource = MissionWorld.resolveAsset("Greenhouse")
    local crops = 0
    for _, child in kitGh:GetChildren() do
        if string.match(child.Name, "^Crop%d$") then
            crops += 1
        end
    end
    check(
        kitSource == "kit" and kitGh:FindFirstChild("Main") ~= nil and crops == 6,
        "에셋: 그린하우스가 없으면 HabitatB + Crop 6"
    )
    kitGh:Destroy()
    fixture.greenhouse.Name = "Greenhouse"

    local led, ledSource = MissionWorld.resolveAsset("LedUnit")
    local label = H.label(led)
    local gui = label and label.Parent
    check(ledSource == "placeholder", "에셋: 키트 조합이 없으면 3단계 대체 도형")
    check(
        label ~= nil
            and label:GetAttribute("TextKey") == "facility.led.name"
            and label.Text == ""
            and label.AutoLocalize == false,
        "에셋: 이름표는 TextKey만 (문장 없음, AutoLocalize false)"
    )
    check(
        gui ~= nil and gui:IsA("BillboardGui") and gui.AutoLocalize == false,
        "에셋: 이름표 BillboardGui AutoLocalize false"
    )
    led:Destroy()
    local mystery, mysterySource = MissionWorld.resolveAsset("Mystery")
    local mysteryLabel = H.label(mystery)
    check(
        mysterySource == "placeholder"
            and mysteryLabel
            and mysteryLabel:GetAttribute("TextKey") == "world.placeholder.name",
        "에셋: 모르는 역할도 대체 도형"
    )
    mystery:Destroy()

    fixture.kit.Name = "KitOff"
    local hut, hutSource = MissionWorld.resolveAsset("Lander")
    check(
        hutSource == "placeholder"
            and hut:FindFirstChild("WallFrontLeft") ~= nil
            and hut:FindFirstChild("Roof") ~= nil,
        "에셋: 키트도 없으면 걸어 들어가는 오두막 대체 도형"
    )
    local hutLabel = H.label(hut)
    check(
        hutLabel and hutLabel:GetAttribute("TextKey") == "world.lander.name",
        "에셋: 오두막 이름표 키 world.lander.name"
    )
    hut:Destroy()
    fixture.kit.Name = "Kit"
end

-- placeBase -----------------------------------------------------------------
print("[placeBase]")
MissionWorld.placeBase()
local base = runtime:FindFirstChild("Base")
do
    check(base ~= nil, "기지: MissionRuntime.Base")
    for _, name in
        {
            "LanderShelter",
            "AirlockShelter",
            "SolarField",
            "WaterTank",
            "RoverPark",
            "BaseExit",
            "FarmSite",
        }
    do
        check(base and base:FindFirstChild(name) ~= nil, "기지: " .. name)
    end
    local lander = MissionWorld.getShelter("lander")
    local airlock = MissionWorld.getShelter("airlock")
    check(lander ~= nil and airlock ~= nil, "대피처: 착륙선과 에어록")
    local entry = lander.model:FindFirstChild("Entry")
    local door = entry and entry:FindFirstChild("Door")
    check(
        door ~= nil and door.CanCollide and H.near(door.Size.X, 4.5) and H.near(door.Size.Y, 5.5),
        "대피처: 닫힌 문 4.5 x 5.5 충돌"
    )
    check(
        entry:FindFirstChild("DoorFrame") and not entry.DoorFrame.CanCollide,
        "대피처: 문 프레임은 충돌 없음"
    )
    local signLabel = H.label(entry:FindFirstChild("DoorSign"))
    check(
        signLabel
            and signLabel:GetAttribute("TextKey") == "world.sign.lander"
            and signLabel.Text == ""
            and signLabel.AutoLocalize == false,
        "대피처: 문 표지는 TextKey만"
    )
    local walls, wallsOk = 0, true
    for _, child in entry:GetChildren() do
        if string.sub(child.Name, 1, 4) == "Wall" then
            walls += 1
            if child.Transparency ~= 1 or not child.CanCollide then
                wallsOk = false
            end
        end
    end
    check(
        walls >= 8 and wallsOk,
        "대피처: 보이지 않는 충돌 벽 (팔각, " .. walls .. "개)"
    )
    local landerMarker = MissionWorld.getMarker("Lander")
    local doorPos = door.CFrame.Position
    check(
        doorPos.Z < landerMarker.position.Z - 4
            and math.abs(doorPos.X - landerMarker.position.X) < 1,
        "대피처: 착륙선 문은 스폰 쪽(-Z)"
    )
    local visualCollide = false
    for _, d in lander.model.Visual:GetDescendants() do
        if d:IsA("BasePart") and d.CanCollide then
            visualCollide = true
        end
    end
    check(not visualCollide, "대피처: 외형은 충돌 없음 (걸어 들어간다)")
    -- [2026-11-15 플레이 테스트] 안에서 보이는 방 (MissionWorld.CONFIG.interior)과 문 상태등
    for _, shelter in { lander, airlock } do
        local id = shelter.id
        local frame = shelter.frame
        local room = shelter.model:FindFirstChild("Interior")
        check(room ~= nil, "실내: " .. id .. " 보이는 방 (Interior)")
        if room then
            local visible, collide = true, true
            for _, name in { "WallBack", "WallLeft", "WallRight", "Ceiling", "Lintel" } do
                local part = room:FindFirstChild(name)
                if
                    not part
                    or part.Transparency ~= 0
                    or part.Material ~= Enum.Material.SmoothPlastic
                then
                    visible = false
                end
                if not part or not part.CanCollide or not part.CanQuery then
                    collide = false
                end
            end
            check(
                visible,
                "실내: " .. id .. " 벽 3면, 천장, 문 위가 불투명한 SmoothPlastic"
            )
            check(
                collide,
                "실내: "
                    .. id
                    .. " 벽과 천장은 충돌, CanQuery (카메라가 벽 뒤로 안 간다)"
            )
            local floorPlate = room:FindFirstChild("FloorPlate")
            check(
                floorPlate and not floorPlate.CanCollide and floorPlate.Transparency == 0,
                "실내: " .. id .. " 바닥 판 (충돌 없음, 턱 없음)"
            )
            local light = room:FindFirstChild("Ceiling")
                and room.Ceiling:FindFirstChild("RoomLight")
                and room.Ceiling.RoomLight:FindFirstChildOfClass("PointLight")
            check(
                light ~= nil and light.Range <= MissionWorld.CONFIG.interior.lightRange,
                "실내: " .. id .. " 짧은 실내 빛"
            )
            local rlo, rhi = H.boundsIn(room, frame)
            local vlo, vhi = H.boundsIn(shelter.model:FindFirstChild("Visual"), frame)
            check(
                rlo.X >= vlo.X - 1e-3
                    and rhi.X <= vhi.X + 1e-3
                    and rlo.Z >= vlo.Z - 1e-3
                    and rhi.Z <= vhi.Z + 1e-3
                    and rhi.Y <= vhi.Y + 1e-3,
                string.format(
                    "실내: %s 방은 외형 경계 안 (방 %.1f x %.1f x %.1f)",
                    id,
                    rhi.X - rlo.X,
                    rhi.Y - rlo.Y,
                    rhi.Z - rlo.Z
                )
            )
            local zlo, zhi = H.boundsIn(shelter.zone, frame)
            check(
                rlo.X >= zlo.X - 1e-3
                    and rhi.X <= zhi.X + 1e-3
                    and rlo.Z >= zlo.Z - 1e-3
                    and rhi.Z <= zhi.Z + 1e-3
                    and rhi.Y <= zhi.Y + 1e-3,
                "실내: " .. id .. " 방은 산소 구역 안"
            )
            local entryModel = shelter.model:FindFirstChild("Entry")
            local doorPart = entryModel:FindFirstChild("Door")
            local dlo, dhi = H.boundsIn(doorPart, frame)
            local doorX = (dlo.X + dhi.X) / 2
            local fl = room:FindFirstChild("WallFrontLeft")
            local fr = room:FindFirstChild("WallFrontRight")
            local leftEdge = if fl then select(2, H.boundsIn(fl, frame)).X else rlo.X
            local rightEdge = if fr then H.boundsIn(fr, frame).X else rhi.X
            local llo = H.boundsIn(room:FindFirstChild("Lintel"), frame)
            check(
                rightEdge - leftEdge >= doorPart.Size.X - 1e-3
                    and leftEdge <= dlo.X + 1e-3
                    and rightEdge >= dhi.X - 1e-3
                    and llo.Y >= dhi.Y - 1e-3,
                string.format(
                    "실내: %s 앞 벽 출입구가 문 앞 (X %.2f ~ %.2f, 문 %.2f)",
                    id,
                    leftEdge,
                    rightEdge,
                    doorX
                )
            )
            check(
                rlo.Z > dhi.Z - 1e-3,
                "실내: " .. id .. " 방은 문 뒤에서 시작 (문이 미끄러질 틈)"
            )
            local inside = frame:PointToObjectSpace(shelter.inside.Position)
            check(
                inside.X > rlo.X and inside.X < rhi.X and inside.Z > rlo.Z and inside.Z < rhi.Z,
                "실내: " .. id .. " 대피 지점은 방 안"
            )
            if shelter.console then
                local clo, chi = H.boundsIn(shelter.console, frame)
                check(
                    clo.X > rlo.X and chi.X < rhi.X and clo.Z > rlo.Z and chi.Z < rhi.Z - 0.3,
                    string.format(
                        "실내: %s 콘솔은 방 안 (뒷벽 앞) 콘솔 Z %.2f~%.2f, 방 Z %.2f~%.2f 외형 %.2f 구역 %.2f",
                        id,
                        clo.Z,
                        chi.Z,
                        rlo.Z,
                        rhi.Z,
                        vhi.Z,
                        zhi.Z
                    )
                )
            end
            local lamps = 0
            for _, holder in { entryModel, room } do
                for _, child in holder:GetChildren() do
                    if
                        child:GetAttribute("DoorLamp") == true
                        and child.Material == Enum.Material.Neon
                    then
                        lamps += 1
                    end
                end
            end
            check(
                lamps == 2,
                "문 상태등: " .. id .. " 바깥과 안쪽 Neon 2개 (" .. lamps .. ")"
            )
            check(
                doorPart:GetAttribute("SlideX") == 1 or doorPart:GetAttribute("SlideX") == -1,
                "문: " .. id .. " 미끄러질 방향 SlideX"
            )
            check(
                room:HasTag(MissionWorld.CONFIG.interior.tag),
                "실내: "
                    .. id
                    .. " 태그 ShelterInterior (카메라가 방 밖이면 화면에서 숨김)"
            )
            -- [2026-11-15 Studio] 실내 방 꼭짓점 8개가 외형 경계 안. 에어록은 계단 해치 모듈(출입구 X 가운데, 폭 10) 안
            local spec = MissionWorld.CONFIG.shelters[id].room
            local cornersIn = true
            for _, cx in { rlo.X, rhi.X } do
                for _, cy in { rlo.Y, rhi.Y } do
                    for _, cz in { rlo.Z, rhi.Z } do
                        local inVisual = cx >= vlo.X - 1e-3
                            and cx <= vhi.X + 1e-3
                            and cy >= -1e-3
                            and cy <= vhi.Y + 1e-3
                            and cz >= vlo.Z - 1e-3
                            and cz <= vhi.Z + 1e-3
                        local inModule = spec == nil
                            or math.abs(cx - doorX) <= spec.width / 2 + 1e-3
                        if not inVisual or not inModule then
                            cornersIn = false
                        end
                    end
                end
            end
            check(
                cornersIn,
                "실내: "
                    .. id
                    .. " 방 꼭짓점 8개가 외형 경계(와 해치 모듈 폭) 안"
            )
            if spec then
                local zlo2, zhi2 = H.boundsIn(shelter.zone, frame)
                check(
                    rhi.X - rlo.X <= spec.width + 1e-3
                        and H.near((rlo.X + rhi.X) / 2, doorX, 0.01)
                        and H.near(rhi.Y, spec.height, 0.01)
                        and rhi.Z - rlo.Z <= spec.length + 1e-3
                        and H.near(zlo2.X, rlo.X, 0.01)
                        and H.near(zhi2.X, rhi.X, 0.01)
                        and H.near(zhi2.Y, spec.height, 0.01)
                        and H.near(zhi2.Z, rhi.Z, 0.01),
                    string.format(
                        "실내: %s 해치 모듈 방 %.1f x %.1f x %.1f (출입구 X %.2f 가운데), 산소 구역 = 방",
                        id,
                        rhi.X - rlo.X,
                        rhi.Y,
                        rhi.Z - rlo.Z,
                        doorX
                    )
                )
                -- 참고: Airlock.fbx 실측 모듈 원통(반지름 약 5, 중심 높이 약 6)과 방 모서리 거리 (Studio 확인용)
                local scale = shelter.model:GetAttribute("AssetScale") or 1
                local half = (rhi.X - rlo.X) / 2
                print(
                    string.format(
                        "  INFO %s 방 모서리와 모듈 원통 중심 거리: 위 %.2f, 아래 %.2f (원통 반지름 %.2f)",
                        id,
                        math.sqrt(half ^ 2 + (rhi.Y - 6 * scale) ^ 2),
                        math.sqrt(half ^ 2 + (6 * scale) ^ 2),
                        5 * scale
                    )
                )
            end
        end
    end
    local floor = lander.model:FindFirstChild("Floor")
    local floorTop = floor.CFrame.Position.Y + floor.Size.Y / 2
    local highest = -math.huge
    for _, h in landerMarker.groundSamples do
        highest = math.max(highest, h)
    end
    check(
        floor.CanCollide and floorTop >= highest - 1e-3,
        "대피처: 바닥 판 윗면이 지면 위"
    )

    local zone = lander.zone
    check(
        zone:HasTag("OxygenZone")
            and zone:GetAttribute("ZoneKind") == "shelter"
            and zone:GetAttribute("ZoneId") == "lander",
        "산소: 착륙선 구역 태그와 shelter"
    )
    check(
        MissionWorld.zoneAt(lander.inside.Position) == "shelter",
        "산소: 착륙선 안은 shelter"
    )
    check(
        MissionWorld.zoneAt(lander.inside.Position + Vector3.new(60, 0, 0)) == "outside",
        "산소: 바깥은 outside"
    )
    check(
        lander.console ~= nil and H.insidePart(zone, lander.console.CFrame.Position),
        "착륙선: 콘솔이 산소 구역 안"
    )
    check(MissionWorld.anchor("console") == lander.console, "착륙선: 콘솔 자리 등록")

    check(airlock.zone:GetAttribute("ZoneKind") == "shelter", "에어록: 점검 전 shelter")
    MissionWorld.setAirlockStatus("inspecting")
    check(
        airlock.zone:GetAttribute("ZoneKind") == "shelter"
            and airlock.light:GetAttribute("Status") == "inspecting",
        "에어록: 점검 중 shelter, 표시등"
    )
    MissionWorld.setAirlockStatus("active")
    check(
        MissionWorld.zoneAt(airlock.inside.Position) == "refill",
        "에어록: 가동이면 refill"
    )
    MissionWorld.setAirlockStatus("paused")
    check(
        airlock.zone:GetAttribute("ZoneKind") == "shelter",
        "에어록: 멈춤이면 shelter (회복 정지)"
    )
    MissionWorld.setAirlockStatus("broken")
    check(MissionWorld.getAirlockStatus() == "paused", "에어록: 모르는 상태는 무시")
    MissionWorld.setAirlockStatus("idle")
    check(
        airlock.panel ~= nil and MissionWorld.controlPanel("airlock") == airlock.panel,
        "에어록: 외벽 제어반"
    )
    check(
        H.label(airlock.panel):GetAttribute("TextKey") == "facility.airlock.name",
        "에어록: 제어반 TextKey"
    )

    local alo, ahi = H.bounds(airlock.zone)
    local llo, lhi = H.bounds(lander.zone)
    local overlap = alo.X < lhi.X and llo.X < ahi.X and alo.Z < lhi.Z and llo.Z < ahi.Z
    check(not overlap, "대피처: 착륙선과 에어록 산소 구역이 겹치지 않는다")
    check(#MissionWorld.oxygenZones() == 2, "산소: 구역 2개")

    -- [2026-11-15 시험 피드백] 지붕이 열려 뛰어 나갈 수 있었다: 보이지 않는 천장이 벽 윗면에 붙고 벽 바깥까지 덮는다.
    -- 문 위 틈도 막고(DoorLintel), 문 아래 출입구는 그대로 열려 있다
    for _, shelter in { lander, airlock } do
        local entryModel = shelter.model:FindFirstChild("Entry")
        local frame = shelter.frame
        local wallLo = Vector3.new(math.huge, math.huge, math.huge)
        local wallHi = -wallLo
        for _, child in entryModel:GetChildren() do
            if string.sub(child.Name, 1, 4) == "Wall" then
                local lo, hi = H.boundsIn(child, frame)
                wallLo = Vector3.new(
                    math.min(wallLo.X, lo.X),
                    math.min(wallLo.Y, lo.Y),
                    math.min(wallLo.Z, lo.Z)
                )
                wallHi = Vector3.new(
                    math.max(wallHi.X, hi.X),
                    math.max(wallHi.Y, hi.Y),
                    math.max(wallHi.Z, hi.Z)
                )
            end
        end
        local ceiling = entryModel:FindFirstChild("Ceiling")
        local clo, chi = H.boundsIn(ceiling, frame)
        check(
            ceiling ~= nil
                and ceiling.CanCollide
                and ceiling.Transparency == 1
                and H.near(clo.Y, wallHi.Y, 1e-3),
            "지붕: " .. shelter.id .. " 보이지 않는 천장이 벽 윗면에 붙는다"
        )
        check(
            clo.X <= wallLo.X + 1e-3
                and chi.X >= wallHi.X - 1e-3
                and clo.Z <= wallLo.Z + 1e-3
                and chi.Z >= wallHi.Z - 1e-3,
            "지붕: " .. shelter.id .. " 천장이 벽 바깥 두께까지 덮는다"
        )
        local doorPart = entryModel:FindFirstChild("Door")
        local dlo, dhi = H.boundsIn(doorPart, frame)
        local lintel = entryModel:FindFirstChild("DoorLintel")
        local llo2, lhi2 = H.boundsIn(lintel, frame)
        check(
            lintel ~= nil
                and lintel.CanCollide
                and llo2.Y >= dhi.Y - 1e-3
                and H.near(lhi2.Y, wallHi.Y, 1e-3)
                and llo2.X <= dlo.X
                and lhi2.X >= dhi.X,
            "지붕: "
                .. shelter.id
                .. " 문 위 틈을 막는다 (문보다 넓고 벽 윗면까지)"
        )
        local fl = entryModel:FindFirstChild("WallFrontLeft")
        local fr = entryModel:FindFirstChild("WallFrontRight")
        local _, flHi = H.boundsIn(fl, frame)
        local frLo = H.boundsIn(fr, frame)
        local leftEdge = math.min(flHi.X, frLo.X)
        local rightEdge = math.max(flHi.X, frLo.X)
        check(
            rightEdge - leftEdge >= doorPart.Size.X - 1e-3,
            "지붕: " .. shelter.id .. " 문 아래 출입구는 열려 있다"
        )
    end

    -- 태양광
    local slots = MissionWorld.panelSlots()
    local MissionConfig =
        loadModule(ReplicatedStorage:FindFirstChild("Shared"):FindFirstChild("MissionConfig"))
    local expectedSlots = MissionConfig.MISSIONS.C.panels.total
    check(
        #slots == expectedSlots,
        "태양광: 슬롯 수 = MissionConfig panels.total (" .. expectedSlots .. ")"
    )
    local boxLo, boxHi = H.markerBox("SolarField", 0)
    local inside = H.allParts(slots, function(slot)
        local slo, shi = H.bounds(slot)
        return H.withinXZ(slo, shi, boxLo, boxHi)
    end)
    check(inside, "태양광: 슬롯은 SolarField 바닥 넓이 안")
    local notBuried = H.allParts(slots, function(slot)
        local bottom = slot.CFrame.Position.Y - slot.Size.Y / 2
        return bottom >= groundAt(slot.CFrame.Position.X, slot.CFrame.Position.Z) - 1e-3
    end)
    check(notBuried, "태양광: 슬롯마다 자기 지면 위")
    local pad = MissionWorld.anchor("installPad")
    local plo, phi = H.bounds(pad)
    check(
        pad ~= nil and not H.withinXZ(plo, phi, boxLo, boxHi),
        "태양광: 설치 자리는 판 바깥"
    )
    local function d(part)
        local a, b = part.CFrame.Position, pad.CFrame.Position
        return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
    end
    check(d(slots[1]) <= d(slots[#slots]), "태양광: 1번 슬롯이 설치 자리에 가깝다")

    -- 물탱크
    local tankLo, tankHi = H.markerBox("WaterTank", 0.01)
    local tankVisual = H.find(base, "WaterTank.Visual")
    local vlo, vhi = H.bounds(tankVisual)
    check(H.withinXZ(vlo, vhi, tankLo, tankHi), "물탱크: 외형이 표시 바닥 넓이 안")
    check(
        tankVisual:GetAttribute("AssetSource") == "asset",
        "물탱크: 디자이너 에셋 사용"
    )
    check(
        H.near(vhi.Z - vlo.Z, 31, 0.05) and H.near(vhi.X - vlo.X, 16.71, 0.05),
        string.format(
            "물탱크: 긴 축(31)이 표시의 긴 변(월드 Z)을 따른다 (%.2f x %.2f)",
            vhi.X - vlo.X,
            vhi.Z - vlo.Z
        )
    )
    check(
        H.near(H.find(base, "WaterTank"):GetAttribute("AssetScale"), 1, 0.01),
        "물탱크: 배율 약 1 (표시 크기 그대로)"
    )
    -- 뒤 끝 방향: 설비(Rear_Utility_Housing)가 선체보다 있는 쪽. 긴 축(월드 Z) 위에서 얼음 무게중심 쪽을 고른다.
    -- 2026-11-15 옮긴 기지에서는 얼음이 주로 +X(동쪽)라 Z축 위에서는 -Z(남쪽)가 얼음 쪽이다
    local function centerOf(name)
        local lo, hi = H.bounds(tankVisual:FindFirstChild(name))
        return (lo + hi) / 2
    end
    local hull = centerOf("Main_Pressurized_Hull")
    local backRaw = (centerOf("Rear_Utility_Housing") - hull) * Vector3.new(1, 0, 1)
    local back = backRaw.Unit
    fixture.tankBack = back
    local iceSum = Vector3.zero
    for i = 1, 5 do
        iceSum += MissionWorld.getMarker("Ice" .. i).position
    end
    local toIce = (iceSum / 5 - MissionWorld.getMarker("WaterTank").position) * Vector3.new(1, 0, 1)
    check(
        math.abs(back.Z) > 0.99 and back:Dot(toIce) > 0,
        string.format(
            "물탱크: 뒤 끝(설비)이 긴 축 위에서 얼음 쪽 (back %.2f, %.2f)",
            back.X,
            back.Z
        )
    )
    check(
        H.along(centerOf("Front_Door") - hull, back) < 0,
        "물탱크: 문과 경사로는 뒤 끝 반대쪽"
    )
    local unload = MissionWorld.anchor("unloadPoint").CFrame.Position
    local dockPos = MissionWorld.anchor("roverDock").CFrame.Position
    check(
        unload.X > vhi.X and dockPos.X > vhi.X,
        "물탱크: 하역 자리와 귀환 자리는 착륙선 쪽 긴 옆면"
    )
    check(
        H.along(dockPos - unload, back) < 0,
        "물탱크: 귀환 자리는 문 쪽으로 비켜 있다"
    )
    local _, tankBackEdge = H.alongRange(vlo, vhi, back)
    local pipeSpotPos = MissionWorld.anchor("pipeSpot").CFrame.Position
    check(
        H.along(pipeSpotPos, back) > tankBackEdge,
        "물탱크: 파이프 착공 자리는 뒤 끝 바깥"
    )
    for _, id in { "unloadPoint", "roverDock", "pipeSpot" } do
        check(MissionWorld.anchor(id) ~= nil, "물탱크: 자리 " .. id)
    end
    check(
        H.along(pipeSpotPos - MissionWorld.getMarker("WaterTank").position, back) > 0,
        "물탱크: 파이프 자리는 얼음 쪽 면"
    )

    -- 로버 주차, 출구
    local park = MissionWorld.roverParkCFrame()
    local exitInfo = MissionWorld.getMarker("BaseExit")
    local toExit = (exitInfo.position - park.Position) * Vector3.new(1, 0, 1)
    check(
        park ~= nil and park.LookVector:Dot(toExit.Unit) > 0.99,
        "로버 주차: 출구 쪽을 본다"
    )
    local exitCf = MissionWorld.exitCFrame()
    check(
        exitCf ~= nil and exitCf.LookVector:Dot(exitInfo.cframe.LookVector) > 0.99,
        "출구: 표시 방향을 본다"
    )
    -- 2026-11-15 리드가 출구를 얼음 쪽으로 다시 옮겼다: 얼음 무게중심을 본다 (Ice5만 옆쪽). 값만 남긴다
    for i = 1, 5 do
        local p = MissionWorld.getMarker("Ice" .. i).position
        local dir = ((p - exitInfo.position) * Vector3.new(1, 0, 1)).Unit
        print(
            string.format(
                "  INFO 출구가 보는 방향과 Ice%d 방향 내적 %.2f",
                i,
                exitCf.LookVector:Dot(dir)
            )
        )
    end

    -- 얼음
    local sites = MissionWorld.iceSites()
    local order = {}
    for _, site in sites do
        table.insert(order, site.markerName)
    end
    check(
        table.concat(order, ",") == "Ice4,Ice5,Ice1,Ice3,Ice2",
        "얼음: 출구 기준 거리 순서 " .. table.concat(order, ",")
    )
    check(
        H.near(sites[1].distanceFromExit, 412.0, 0.5)
            and H.near(sites[2].distanceFromExit, 421.0, 0.5)
            and H.near(sites[3].distanceFromExit, 647.2, 0.5)
            and H.near(sites[4].distanceFromExit, 810.4, 0.5)
            and H.near(sites[5].distanceFromExit, 937.1, 0.5),
        "얼음: 출구 거리 412.0, 421.0, 647.2, 810.4, 937.1 (리드 실측 412, 421, 647, 810, 937)"
    )
    check(
        H.near(sites[1].distanceFromRoverPark, 515.4, 0.5)
            and H.near(sites[2].distanceFromRoverPark, 412.4, 0.5)
            and H.near(sites[5].distanceFromRoverPark, 1037.1, 0.5),
        "얼음: 로버 주차 거리 (Ice4 515, Ice5 412, Ice2 1037. 주차 기준이면 Ice5가 더 가깝다)"
    )
    check(
        H.near(sites[1].distanceFromLander, 492.2, 0.5)
            and H.near(sites[2].distanceFromLander, 496.1, 0.5),
        "얼음: 착륙선 거리 (Ice4 492, Ice5 496)"
    )
    local distances = MissionWorld.iceDistances()
    check(
        H.near(distances.Ice4, 412.0, 0.5) and H.near(distances.Ice2, 937.1, 0.5),
        "얼음: Rules용 거리표"
    )
    local iceFolder = runtime:FindFirstChild("IceSites")
    local nearest = iceFolder and iceFolder:FindFirstChild("Ice4")
    check(
        nearest ~= nil
            and nearest:GetAttribute("SiteIndex") == 1
            and nearest:FindFirstChild("MinePoint") ~= nil,
        "얼음: IceSites.Ice4 SiteIndex 1 (출구에서 가장 가까움), 채취 자리"
    )
    -- [2026-11-15 시험 피드백] 얼음은 영구 음영 크레이터의 어두운 표토에 섞여 있다: 반짝이는 결정이 아니라 낮게 묻힌
    -- 표토 색 덩어리. 네온, 빛, 반짝이 효과 없음. 이름표와 반짝임은 40 studs 안에서만 보인다
    local reveal = MissionWorld.CONFIG.ice.revealDistance
    check(reveal <= 40, "얼음: 가까이서만 보이는 거리 " .. reveal .. " studs 이하 40")
    local depositOk, neonFree, colorsOk, collideFree, lowOk, buriedOk =
        true, true, true, true, true, true
    local noLights, guisNear, labelKeyOk, mineOk = true, true, true, true
    local frostCount, frostNear = 0, true
    for _, site in iceFolder:GetChildren() do
        local deposit = site:FindFirstChild("Deposit")
        local point = site:FindFirstChild("MinePoint")
        if not deposit or deposit:GetAttribute("AssetSource") ~= "placeholder" then
            depositOk = false
        end
        if
            not point
            or point:GetAttribute("SiteIndex") ~= site:GetAttribute("SiteIndex")
            or point:GetAttribute("MarkerName") ~= site.Name
        then
            mineOk = false
        end
        if deposit then
            local info = MissionWorld.getMarker(site.Name)
            -- S12: 덩어리마다 자기 자리 지면 기준으로 노출 높이 (exposure, 작은 덩어리는 높이 x (1 - minBuryRatio))
            local cfgIce = MissionWorld.CONFIG.ice
            local grounds = {}
            for _, chunk in deposit:GetChildren() do
                if chunk:IsA("BasePart") then
                    local clo, chi = H.bounds(chunk)
                    local p = chunk.CFrame.Position
                    local ground = groundAt(p.X, p.Z)
                    grounds[string.format("%.2f", ground)] = true
                    local want =
                        math.min(cfgIce.exposure, (chi.Y - clo.Y) * (1 - cfgIce.minBuryRatio))
                    if
                        math.abs(chi.Y - ground - want) > 0.02
                        or chi.Y - ground > cfgIce.exposure + 0.02
                    then
                        lowOk = false
                    end
                    if clo.Y > ground - 0.05 then
                        buriedOk = false
                    end
                end
            end
            local distinct = 0
            for _ in grounds do
                distinct += 1
            end
            if distinct < 3 then
                lowOk = false -- 경사 검사가 의미 있으려면 덩어리 자리 지면이 서로 달라야 한다
            end
            for _, item in deposit:GetDescendants() do
                if item:IsA("BasePart") then
                    if
                        item.Material == Enum.Material.Neon
                        or item.Material == Enum.Material.Glass
                        or item.Material == Enum.Material.Ice
                        or item.Material == Enum.Material.Glacier
                        or item.Reflectance > 0
                    then
                        neonFree = false
                    end
                    local c = item.Color
                    local r, g, b = c.R * 255, c.G * 255, c.B * 255
                    -- 어두운 표토: 밝기 낮고, 푸른 기는 아주 약하게 (파랑이 빨강보다 20 이하로만 높다)
                    if math.max(r, g, b) > 130 or b - r > 20 then
                        colorsOk = false
                    end
                    if item.CanCollide then
                        collideFree = false
                    end
                end
            end
            check(info ~= nil, "얼음: " .. site.Name .. " 표시 정보")
        end
        for _, item in site:GetDescendants() do
            if
                item:IsA("PointLight")
                or item:IsA("SpotLight")
                or item:IsA("SurfaceLight")
                or item:IsA("ParticleEmitter")
                or item:IsA("Sparkles")
            then
                noLights = false
            elseif item:IsA("BillboardGui") then
                if item.MaxDistance > reveal + 1e-6 or item.AlwaysOnTop then
                    guisNear = false
                end
            elseif item:IsA("SurfaceGui") then
                -- 서리 윗면: 가까이서만 (MaxDistance 0은 거리 제한 없음이라 안 된다)
                frostCount += 1
                if
                    item.MaxDistance <= 0
                    or item.MaxDistance > reveal + 1e-6
                    or item.Face ~= Enum.NormalId.Top
                then
                    frostNear = false
                end
            end
        end
        -- 이름표: map.ice.label { n }, n = 표시 번호 (Ice4 -> 4, 정렬 순서 아님)
        local label = point and point:FindFirstChild("Label")
        local text = label and H.label(label)
        local n = tonumber(string.match(site.Name, "%d+"))
        if
            not text
            or text:GetAttribute("TextKey") ~= "map.ice.label"
            or text:GetAttribute("TextArgs") ~= string.format('{"n":%d}', n)
            or text.Text ~= ""
        then
            labelKeyOk = false
        end
        if not (point and point:FindFirstChild("Glint")) then
            guisNear = false
        end
    end
    check(depositOk, "얼음: 외형은 표토 덩어리 대체 도형 (Kit IceCrystal 안 씀)")
    check(neonFree, "얼음: 네온, 유리, 얼음 재질, 반사 없음")
    check(colorsOk, "얼음: 어두운 표토 색, 아주 약한 푸른 기")
    check(collideFree, "얼음: 덩어리는 충돌 없음 (로버가 지나간다)")
    check(
        lowOk,
        "얼음: 덩어리마다 자기 자리 지면 위로 노출 높이만큼 (exposure 1.3, 작은 덩어리는 70%), 경사진 지면"
    )
    check(buriedOk, "얼음: 덩어리 밑은 모두 땅속 (떠 보이지 않는다)")
    check(noLights, "얼음: 빛, 파티클, 반짝이 효과 없음")
    check(
        guisNear,
        "얼음: 이름표와 반짝임은 40 studs 안에서만 (MaxDistance, AlwaysOnTop 끔)"
    )
    check(
        labelKeyOk,
        "얼음: 이름표는 TextKey map.ice.label + TextArgs {n = 표시 번호} (Ice4 -> 4)"
    )
    check(
        frostCount >= 5 and frostNear,
        "얼음: 서리 윗면(SurfaceGui)은 40 studs 안에서만 (" .. frostCount .. "개)"
    )
    check(mineOk, "얼음: MinePoint SiteIndex, MarkerName 유지")
end

-- 얼음 외형 규칙은 디자이너 Assets.IceDeposit에도 적용 (네온, 빛, 먼 이름표를 끈다) ---------------
print("[얼음 에셋]")
do
    local asset = Instance.new("Model")
    asset.Name = "IceDeposit"
    local shiny = fixture.mesh(asset, "Shiny", Vector3.new(6, 2, 5), Vector3.new(0, 1, 0), {
        Material = Enum.Material.Neon,
        Color = Color3.fromRGB(170, 220, 255),
    })
    local light = Instance.new("PointLight")
    light.Range = 60
    light.Parent = shiny
    local sparkles = Instance.new("Sparkles")
    sparkles.Parent = shiny
    local far = Instance.new("BillboardGui")
    far.Name = "FarLabel"
    far.MaxDistance = 500
    far.AlwaysOnTop = true
    far.Parent = shiny
    local surface = Instance.new("SurfaceGui")
    surface.Name = "FarSurface"
    surface.MaxDistance = 0 -- 거리 제한 없음
    surface.Parent = shiny
    asset.Parent = fixture.assets
    MissionWorld.placeBase()
    local deposit = H.find(runtime, "IceSites.Ice4.Deposit")
    local part = deposit and deposit:FindFirstChild("Shiny")
    check(
        deposit ~= nil and deposit:GetAttribute("AssetSource") == "asset",
        "얼음 에셋: Assets.IceDeposit 1단계"
    )
    check(
        part ~= nil and part.Material ~= Enum.Material.Neon,
        "얼음 에셋: 네온은 표토 재질로"
    )
    do
        local alo, ahi = H.bounds(deposit)
        local ground = groundAt((alo.X + ahi.X) / 2, (alo.Z + ahi.Z) / 2)
        check(
            H.near(ahi.Y - ground, MissionWorld.CONFIG.ice.exposure, 0.02),
            string.format(
                "얼음 에셋: 모델 전체를 가운데 지면 위로 노출 높이만큼 (%.2f)",
                ahi.Y - ground
            )
        )
    end
    local pl = part and part:FindFirstChildOfClass("PointLight")
    local sp = part and part:FindFirstChildOfClass("Sparkles")
    local fg = part and part:FindFirstChild("FarLabel")
    check(pl ~= nil and pl.Enabled == false, "얼음 에셋: 빛 끔")
    check(sp ~= nil and sp.Enabled == false, "얼음 에셋: 반짝이 효과 끔")
    check(
        fg ~= nil and fg.MaxDistance <= 40 and fg.AlwaysOnTop == false,
        "얼음 에셋: 글자 GUI는 가까이서만"
    )
    local farSurface = part and part:FindFirstChild("FarSurface")
    check(
        farSurface ~= nil and farSurface.MaxDistance > 0 and farSurface.MaxDistance <= 40,
        "얼음 에셋: SurfaceGui도 가까이서만 (0 = 제한 없음은 40으로)"
    )
    asset:Destroy()
    MissionWorld.placeBase()
    check(
        H.find(runtime, "IceSites.Ice4.Deposit"):GetAttribute("AssetSource") == "placeholder",
        "얼음 에셋: 빼면 대체 도형"
    )
    base = runtime:FindFirstChild("Base")
end

-- 대체 도형 오두막 대피처: 벽과 지붕이 맞닿고 충돌이 있다 (키트가 없을 때) ------------------------
print("[오두막]")
do
    fixture.kit.Name = "KitOff"
    fixture.airlock.Name = "AirlockOff" -- 디자이너 에어록도 빼서 대체 도형을 본다
    MissionWorld.placeBase()
    for _, id in { "lander", "airlock" } do
        local shelter = MissionWorld.getShelter(id)
        local visual = shelter.model:FindFirstChild("Visual")
        local frame = shelter.frame
        check(
            visual:GetAttribute("AssetSource") == "placeholder",
            "오두막: " .. id .. " 대체 도형"
        )
        local roof = visual:FindFirstChild("Roof")
        local solidOk = roof ~= nil and roof.CanCollide and roof.Transparency == 0
        local wallTop = -math.huge
        local wallLo = Vector3.new(math.huge, math.huge, math.huge)
        local wallHi = -wallLo
        for _, name in
            { "WallBack", "WallLeft", "WallRight", "WallFrontLeft", "WallFrontRight", "Lintel" }
        do
            local wall = visual:FindFirstChild(name)
            if not wall or not wall.CanCollide then
                solidOk = false
            else
                local lo, hi = H.boundsIn(wall, frame)
                wallTop = math.max(wallTop, hi.Y)
                wallLo = Vector3.new(math.min(wallLo.X, lo.X), 0, math.min(wallLo.Z, lo.Z))
                wallHi = Vector3.new(math.max(wallHi.X, hi.X), 0, math.max(wallHi.Z, hi.Z))
            end
        end
        check(
            solidOk,
            "오두막: " .. id .. " 벽과 지붕 충돌 (카메라와 점프를 막는다)"
        )
        local rlo, rhi = H.boundsIn(roof, frame)
        check(
            H.near(rlo.Y, wallTop, 1e-3),
            "오두막: " .. id .. " 지붕 밑면 = 벽 윗면 (틈 없음)"
        )
        check(
            rlo.X <= wallLo.X + 1e-3
                and rhi.X >= wallHi.X - 1e-3
                and rlo.Z <= wallLo.Z + 1e-3
                and rhi.Z >= wallHi.Z - 1e-3,
            "오두막: " .. id .. " 지붕이 벽 전체를 덮는다"
        )
        local _, flHi = H.boundsIn(visual:FindFirstChild("WallFrontLeft"), frame)
        local frLo = H.boundsIn(visual:FindFirstChild("WallFrontRight"), frame)
        local door = H.find(shelter.model, "Entry.Door")
        check(
            math.abs(frLo.X - flHi.X) >= door.Size.X - 1e-3,
            "오두막: " .. id .. " 정면 출입구는 문 폭만큼 열려 있다"
        )
        check(
            H.find(shelter.model, "Entry.Ceiling") ~= nil,
            "오두막: " .. id .. " 보이지 않는 천장도 있다"
        )
    end
    fixture.kit.Name = "Kit"
    fixture.airlock.Name = "Airlock"
    MissionWorld.placeBase()
    base = runtime:FindFirstChild("Base")
end

-- 디자이너 에어록 (S9): 맞춤 배율, 해치 방향, 출입구를 해치 쪽(DoorOffsetX)으로, 로버 길 ----------------------
print("[에어록 에셋]")
do
    local airlock = MissionWorld.getShelter("airlock")
    local frame = airlock.frame
    local visual = airlock.model:FindFirstChild("Visual")
    local scale = airlock.model:GetAttribute("AssetScale")
    check(
        visual:GetAttribute("AssetSource") == "asset",
        "에어록: Assets.Airlock 1단계 (디자이너 에셋)"
    )
    local vlo, vhi = H.boundsIn(visual, frame)
    check(
        H.near(scale, 1, 0.01) and H.near(vhi.Y - vlo.Y, 17, 0.05),
        string.format(
            "에어록: 표시 43 x 17 x 43에 맞춤 배율 약 1 (%.3f, 높이 %.2f)",
            scale,
            vhi.Y - vlo.Y
        )
    )
    local spawn = MissionWorld.getMarker("SpawnLocation").position
    local center = MissionWorld.getMarker("Airlock").position
    local toSpawn = ((spawn - center) * Vector3.new(1, 0, 1)).Unit
    local front = frame.LookVector
    print(
        string.format(
            "  INFO 에어록 정면(해치 쪽 -Z) 방향 (%.2f, %.2f), 스폰 쪽과 내적 %.2f",
            front.X,
            front.Z,
            front:Dot(toSpawn)
        )
    )
    check(
        front:Dot(toSpawn) > 0.7,
        "에어록: 해치 쪽(정면)이 스폰 쪽 (90도 단위로 맞춤)"
    )
    local entry = airlock.model:FindFirstChild("Entry")
    local expectX = -7.6 * scale
    local function localX(name)
        local lo, hi = H.boundsIn(entry:FindFirstChild(name), frame)
        return (lo.X + hi.X) / 2, lo, hi
    end
    local doorX = localX("Door")
    check(
        H.near(doorX, expectX, 0.01) and H.near(airlock.model:GetAttribute("DoorX"), expectX, 0.01),
        string.format("에어록: 문을 해치 쪽 X %.2f로 (DoorOffsetX x 배율)", doorX)
    )
    check(
        H.near(localX("DoorLintel"), expectX, 0.01)
            and H.near(localX("DoorSign"), expectX, 0.01)
            and H.near(localX("DoorFrame"), expectX, 0.01),
        "에어록: 문 위 막이, 표지, 문틀도 같은 X"
    )
    local gap = MissionWorld.CONFIG.entry.doorGap
    local _, _, leftHi = localX("WallFrontLeft")
    local _, rightLo = localX("WallFrontRight")
    check(
        H.near(leftHi.X, expectX - gap / 2, 0.01) and H.near(rightLo.X, expectX + gap / 2, 0.01),
        "에어록: 정면 벽 출입구가 해치 앞에 열린다"
    )
    local inside = frame:PointToObjectSpace(airlock.inside.Position)
    check(
        H.near(inside.X, expectX, 0.01)
            and MissionWorld.zoneAt(airlock.inside.Position) ~= "outside",
        "에어록: 대피 지점은 출입구 안쪽, 산소 구역 안"
    )
    local doorWorld = entry:FindFirstChild("Door").CFrame.Position
    local function flatDist(a, b)
        return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
    end
    check(
        flatDist(doorWorld, spawn) < flatDist(center, spawn) - 10,
        "에어록: 계단 해치 출입구가 스폰 쪽에 있다"
    )
    local panelX = frame:PointToObjectSpace(airlock.panel.CFrame.Position).X
    check(
        math.abs(panelX - expectX) < gap / 2 + 3 and math.abs(panelX - expectX) > gap / 2,
        "에어록: 제어반은 옮긴 출입구 옆"
    )
    -- 착륙선은 DoorOffsetX가 없어 가운데
    local lander = MissionWorld.getShelter("lander")
    local llo, lhi = H.boundsIn(lander.model:FindFirstChild("Visual"), lander.frame)
    local ldoorLo, ldoorHi = H.boundsIn(H.find(lander.model, "Entry.Door"), lander.frame)
    check(
        H.near((ldoorLo.X + ldoorHi.X) / 2, (llo.X + lhi.X) / 2, 0.01),
        "착륙선: DoorOffsetX가 없으면 출입구는 가운데"
    )
    -- 벽 밖으로 못 나간다: DoorOffsetX가 너무 크면 문 틈 절반만큼 안쪽으로 자른다
    fixture.airlock:SetAttribute("DoorOffsetX", 100)
    MissionWorld.placeBase()
    local clamped = MissionWorld.getShelter("airlock")
    local clo, chi = H.boundsIn(clamped.model:FindFirstChild("Visual"), clamped.frame)
    local cdoorLo, cdoorHi = H.boundsIn(H.find(clamped.model, "Entry.Door"), clamped.frame)
    local cdoorX = (cdoorLo.X + cdoorHi.X) / 2
    check(
        H.near(cdoorX, chi.X - gap / 2, 0.01)
            and cdoorX + gap / 2 <= chi.X + 1e-3
            and clo.X < cdoorX,
        string.format("에어록: 너무 큰 DoorOffsetX는 벽 안으로 자른다 (%.2f)", cdoorX)
    )
    fixture.airlock:SetAttribute("DoorOffsetX", -7.6)
    MissionWorld.placeBase()
    base = runtime:FindFirstChild("Base")
    -- 로버 길: 주차판 -> 출구 곧은 길이 에어록, 착륙선 경계를 지나는지 (지나면 warn만, 표시는 옮기지 않는다)
    local crossAirlock = MissionWorld.pathCrossesShelter("RoverPark", "BaseExit", "airlock")
    local crossLander = MissionWorld.pathCrossesShelter("RoverPark", "BaseExit", "lander")
    print(
        string.format(
            "  INFO 로버 길 RoverPark -> BaseExit: 에어록 %s, 착륙선 %s, 태양광 판 %s",
            tostring(crossAirlock),
            tostring(crossLander),
            tostring(MissionWorld.pathCrossesSolarField("RoverPark", "BaseExit"))
        )
    )
    check(
        crossAirlock == false and crossLander == false,
        "로버 길: RoverPark -> BaseExit는 에어록, 착륙선 밖"
    )
    local warned = false
    for _, text in warnings do
        if string.find(text, "건물을 지납니다", 1, true) then
            warned = true
        end
    end
    check(not warned, "로버 길: 대피처 경고 없음")
end

-- 패널 수 ---------------------------------------------------------------------
print("[패널]")
do
    MissionWorld.setPanelCount(3)
    local folder = H.find(base, "SolarField.Panels")
    check(#folder:GetChildren() == 3, "패널: 3장 배치")
    local panel1 = folder:FindFirstChild("Panel1")
    local slot1 = MissionWorld.panelSlots()[1]
    local slotTop = slot1.CFrame.Position.Y + slot1.Size.Y / 2
    local before = H.bounds(panel1)
    check(before.Y < slotTop - 1, "패널: 처음에는 슬롯 아래에서 시작")
    local function allCollide(model, want)
        for _, d in model:GetDescendants() do
            if d:IsA("BasePart") and d.CanCollide ~= want then
                return false
            end
        end
        return true
    end
    check(allCollide(panel1, false), "패널: 솟아오르는 동안 충돌 없음")
    -- 솟아오르는 패널 3 자리에 서 있는 플레이어 (다 오르면 가장 가까운 옆으로 비킨다)
    local panel3 = folder:FindFirstChild("Panel3")
    local slot3 = MissionWorld.panelSlots()[3]
    local slot3Top = slot3.CFrame * CFrame.new(0, slot3.Size.Y / 2, 0)
    local stander = addFakePlayer("PanelStander", (slot3Top * CFrame.new(0.4, 3, 0.2)).Position)
    advance(2)
    local after = H.bounds(panel1)
    check(H.near(after.Y, slotTop, 0.01), "패널: 솟아올라 슬롯 윗면에 선다")
    check(allCollide(panel1, true), "패널: 다 오르면 충돌 (로버를 막는다)")
    check(
        panel1:HasTag(MissionWorld.CONFIG.solar.hazardTag)
            and MissionWorld.CONFIG.solar.hazardTag == "RoverHazard",
        "패널: RoverHazard 태그 (로버 충돌 판정, 패널은 부서지지 않는다)"
    )
    do
        local plo3, phi3 = H.boundsIn(panel3, slot3Top)
        local q = slot3Top:PointToObjectSpace(rootOf(stander).CFrame.Position)
        local outside = q.X < plo3.X - 1 or q.X > phi3.X + 1 or q.Z < plo3.Z - 1 or q.Z > phi3.Z + 1
        check(
            outside,
            "패널: 솟아오른 패널 안에 있던 플레이어는 옆으로 비킨다"
        )
        local p3 = rootOf(stander).CFrame.Position
        check(H.near(p3.Y, groundAt(p3.X, p3.Z) + 3, 1e-3), "패널: 비킨 자리는 지면 위")
    end
    clearFakePlayers()
    -- 로버 길: 주차판에서 출구까지 곧은 길은 태양광 판을 지나지 않는다 (지나면 표시를 옮기지 않고 보고)
    check(
        MissionWorld.pathCrossesSolarField("RoverPark", "BaseExit") == false,
        "로버 길: RoverPark -> BaseExit 곧은 길은 SolarField 밖"
    )
    for _, pair in
        {
            { "RoverPark", "Ice4" },
            { "RoverPark", "Ice5" },
            { "BaseExit", "Ice5" },
            { "Lander", "RoverPark" },
        }
    do
        print(
            string.format(
                "  INFO 로버 길 %s -> %s 태양광 판 지남: %s",
                pair[1],
                pair[2],
                tostring(MissionWorld.pathCrossesSolarField(pair[1], pair[2]))
            )
        )
    end
    MissionWorld.setPanelCount(1)
    check(#folder:GetChildren() == 1, "패널: 줄이면 지운다")
    local slotTotal = #MissionWorld.panelSlots()
    MissionWorld.setPanelCount(slotTotal + 5)
    check(#folder:GetChildren() == slotTotal, "패널: 슬롯 수를 넘지 않는다")
    advance(2)
    -- 개수는 인자로도 정한다 (리드 지시: C는 20칸 기준, 지금 MissionConfig 값과 다를 수 있다)
    MissionWorld.placeBase({ panelSlots = 20 })
    base = runtime:FindFirstChild("Base")
    check(#MissionWorld.panelSlots() == 20, "패널: placeBase({ panelSlots = 20 })이면 20칸")
    check(
        #H.find(base, "SolarField.Panels"):GetChildren() == math.min(slotTotal + 5, 20),
        "패널: 기지를 다시 놓아도 요청한 설치 수 유지"
    )
    local slots20 = MissionWorld.panelSlots()
    local boxLo, boxHi = H.markerBox("SolarField", 0)
    check(
        H.allParts(slots20, function(slot)
            local slo, shi = H.bounds(slot)
            return H.withinXZ(slo, shi, boxLo, boxHi)
        end),
        "패널: 20칸도 SolarField 안"
    )
    MissionWorld.setPanelCount(0)
    MissionWorld.placeBase()
    base = runtime:FindFirstChild("Base")
end

-- 시설 ------------------------------------------------------------------------
print("[시설]")
local facilitiesFolder = runtime:FindFirstChild("Facilities")
do
    check(MissionWorld.place("farm") == true, "재배 공간: place")
    local farm = facilitiesFolder:FindFirstChild("farm")
    check(
        farm ~= nil and farm:GetAttribute("Status") == "building",
        "재배 공간: Facilities.farm building"
    )
    local info = MissionWorld.facilityInfo("farm")
    check(
        H.near(info.offsets[1], -info.heights[1], 1e-3),
        "재배 공간: 진행 0이면 완전히 땅속"
    )
    local leds = MissionWorld.upgradeParts("led")
    local beds = MissionWorld.upgradeParts("hydroponics")
    check(
        #leds == 4 and #beds == 4,
        "재배 공간: 에셋의 LED 바 4, 수경 베드 4를 찾는다"
    )
    check(
        H.allParts(leds, function(p)
            return p.Transparency == 1
        end),
        "재배 공간: LED 업그레이드 전에는 LED 바 숨김"
    )
    check(
        H.allParts(beds, function(p)
            return p.Transparency == 1
        end),
        "재배 공간: 수경 업그레이드 전에는 베드 숨김"
    )
    local walkway = H.find(farm, "Visual.Central_Walkway")
    check(
        walkway ~= nil and walkway.CanCollide == false,
        "재배 공간: 솟아오르는 동안 충돌 끔"
    )
    local panel = MissionWorld.controlPanel("farm")
    check(
        panel ~= nil and H.label(panel):GetAttribute("TextKey") == "facility.farm.name",
        "재배 공간: 외벽 제어반 TextKey"
    )
    check(
        H.find(farm, "StatusLight"):GetAttribute("Status") == "building",
        "재배 공간: 표시등 building"
    )

    MissionWorld.setBuildProgress("farm", 0.5)
    advance(2)
    info = MissionWorld.facilityInfo("farm")
    check(
        H.near(info.offsets[1], -info.heights[1] / 2, 1e-3),
        "재배 공간: 진행 0.5면 절반 솟음"
    )
    -- 건설 중 그린하우스 안에 들어간 플레이어 2명, 멀리 있는 1명, 로버에 앉은 1명 (완공 순간 갇힘 방지)
    local farmCenter = MissionWorld.getMarker("FarmPad").position
    local farmGround = groundAt(farmCenter.X, farmCenter.Z)
    local insideA =
        addFakePlayer("InsideA", Vector3.new(farmCenter.X, farmGround + 3, farmCenter.Z))
    local insideB =
        addFakePlayer("InsideB", Vector3.new(farmCenter.X + 3, farmGround + 3, farmCenter.Z - 2))
    local farPos = Vector3.new(farmCenter.X + 120, farmGround + 3, farmCenter.Z)
    local farAway = addFakePlayer("FarAway", farPos)
    local driver =
        addFakePlayer("Driver", Vector3.new(farmCenter.X - 2, farmGround + 3, farmCenter.Z + 2))
    local seatPart = Instance.new("VehicleSeat")
    seatPart.Anchored = true
    seatPart.CanCollide = false
    seatPart.Parent = driver.Character -- 참조가 DOM 안에 있어야 Lune이 SeatPart를 유지한다
    driver.Character:FindFirstChildOfClass("Humanoid").SeatPart = seatPart
    local driverPos = rootOf(driver).CFrame.Position
    MissionWorld.setActive("farm", true)
    info = MissionWorld.facilityInfo("farm")
    check(
        info.status == "active" and H.near(info.offsets[1], 0, 1e-6),
        "재배 공간: 가동이면 완공 위치"
    )
    check(walkway.CanCollide == true, "재배 공간: 완공하면 통로 충돌 되돌림")
    local lo, hi = H.bounds(farm:FindFirstChild("Visual"))
    local boxLo, boxHi = H.markerBox("FarmPad", 0.01)
    check(
        H.withinXZ(lo, hi, boxLo, boxHi),
        "재배 공간: 그린하우스가 FarmPad 바닥 넓이 안"
    )
    local fl, fr = H.find(farm, "Walls.WallFrontLeft"), H.find(farm, "Walls.WallFrontRight")
    local mid = (fl.CFrame.Position + fr.CFrame.Position) / 2
    local center = MissionWorld.getMarker("FarmPad").position
    local toLander = (MissionWorld.getMarker("Lander").position - center) * Vector3.new(1, 0, 1)
    local toDoor = (mid - center) * Vector3.new(1, 0, 1)
    check(toDoor.Unit:Dot(toLander.Unit) > 0.7, "재배 공간: 출입구가 착륙선 쪽")
    do
        -- 완공하면 안에 있던 플레이어는 출입구(정면) 바깥 지면으로, 건물 반대쪽을 본다
        local doorDir = toDoor.Unit
        local frontFrame = CFrame.lookAt(
            Vector3.new(center.X, farmGround, center.Z),
            Vector3.new(center.X, farmGround, center.Z) + doorDir
        )
        local flo, fhi = H.boundsIn(farm, frontFrame)
        local okOut, okGround, okFace = true, true, true
        for _, p in { insideA, insideB } do
            local root = rootOf(p)
            local q = frontFrame:PointToObjectSpace(root.CFrame.Position)
            if not (q.Z < flo.Z - 1.5) then
                okOut = false
            end
            local pos = root.CFrame.Position
            if not H.near(pos.Y, groundAt(pos.X, pos.Z) + 3, 1e-3) then
                okGround = false
            end
            if root.CFrame.LookVector:Dot(doorDir) < 0.99 then
                okFace = false
            end
        end
        check(
            okOut,
            "갇힘 방지: 완공 순간 그린하우스 안 플레이어를 정면 바깥으로"
        )
        check(okGround, "갇힘 방지: 옮긴 자리는 지면 (지형 광선 + 3)")
        check(okFace, "갇힘 방지: 건물 반대쪽을 본다")
        local a, b = rootOf(insideA).CFrame.Position, rootOf(insideB).CFrame.Position
        check((a - b).Magnitude >= 2.9, "갇힘 방지: 여러 명은 옆으로 나란히")
        -- Part 좌표는 float32라 같은 값도 조금 다르게 읽힌다 (예: -20.02 -> -20.020004)
        check(
            (rootOf(farAway).CFrame.Position - farPos).Magnitude < 1e-3,
            "갇힘 방지: 멀리 있는 플레이어는 그대로"
        )
        check(
            (rootOf(driver).CFrame.Position - driverPos).Magnitude < 1e-3,
            "갇힘 방지: 운전석에 앉은 플레이어는 건드리지 않는다"
        )
        check(fhi.Z > flo.Z, "갇힘 방지: 그린하우스 경계")
        clearFakePlayers()
    end
    check(
        H.find(farm, "Walls.Door") == nil and H.find(farm, "Entry") == nil,
        "재배 공간: 문 없는 출입구 (Airlock 모듈 대상 아님)"
    )

    -- LED
    check(
        MissionWorld.place("led") and facilitiesFolder:FindFirstChild("led") ~= nil,
        "LED: 장치 place"
    )
    MissionWorld.setBuildProgress("led", 0.5)
    advance(2)
    check(
        H.allParts(leds, function(p)
            return p.Transparency == 1
        end),
        "LED: 건설 중에는 LED 바 숨김"
    )
    MissionWorld.setActive("led", true)
    check(
        H.allParts(leds, function(p)
            return p.Transparency == 0 and p.Material == Enum.Material.Neon
        end),
        "LED: 가동이면 LED 바 보임 (Neon)"
    )
    MissionWorld.setPaused("led", true)
    check(
        H.allParts(leds, function(p)
            return p.Transparency == 0 and p.Material == Enum.Material.SmoothPlastic
        end),
        "LED: 멈춤이면 꺼진 모습 (CONFIG pausedUpgradeLook = dim)"
    )
    check(
        MissionWorld.controlPanel("led").Parent:FindFirstChild("StatusLight"):GetAttribute("Status")
            == "paused",
        "LED: 표시등 paused"
    )
    MissionWorld.setPaused("led", false)
    check(
        H.allParts(leds, function(p)
            return p.Material == Enum.Material.Neon and p.Color == Color3.fromRGB(255, 120, 220)
        end),
        "LED: 다시 켜면 원래 색"
    )
    MissionWorld.setPaused("farm", true)
    check(
        H.allParts(leds, function(p)
            return p.Material == Enum.Material.SmoothPlastic
        end),
        "LED: 재배 공간을 멈추면 LED도 꺼진 모습"
    )
    MissionWorld.setPaused("farm", false)
    check(leds[1].Material == Enum.Material.Neon, "LED: 재배 공간을 다시 켜면 켜짐")

    -- 수경
    MissionWorld.place("hydroponics")
    check(
        H.allParts(beds, function(p)
            return p.Transparency == 1
        end),
        "수경: 건설 시작해도 베드 숨김"
    )
    MissionWorld.setActive("hydroponics", true)
    check(
        H.allParts(beds, function(p)
            return p.Transparency == 0
        end),
        "수경: 가동이면 수경 베드 보임"
    )

    -- 영양분 (건설 중 장치 자리에 선 플레이어는 완공하면 장치 정면 바깥으로)
    MissionWorld.place("nutrient")
    local unitBuilding = facilitiesFolder:FindFirstChild("nutrient")
    local ublo, ubhi = H.bounds(unitBuilding:FindFirstChild("Visual"))
    local ucx, ucz = (ublo.X + ubhi.X) / 2, (ublo.Z + ubhi.Z) / 2
    local unitStander = addFakePlayer("UnitStander", Vector3.new(ucx, groundAt(ucx, ucz) + 3, ucz))
    check(
        H.allParts(H.find(unitBuilding, "Visual"):GetDescendants(), function(part)
            return not part:IsA("BasePart") or part.CanCollide == false
        end),
        "영양분: 건설 중 장치는 충돌 없음"
    )
    MissionWorld.setActive("nutrient", true)
    do
        local ulo2, uhi2 = H.bounds(unitBuilding:FindFirstChild("Visual"))
        local pos = rootOf(unitStander).CFrame.Position
        local outside = pos.X < ulo2.X - 1.5
            or pos.X > uhi2.X + 1.5
            or pos.Z < ulo2.Z - 1.5
            or pos.Z > uhi2.Z + 1.5
        local farmC = MissionWorld.getMarker("FarmPad").position
        local function flatDist(v)
            return math.sqrt((v.X - farmC.X) ^ 2 + (v.Z - farmC.Z) ^ 2)
        end
        check(
            outside and flatDist(pos) > flatDist(Vector3.new(ucx, 0, ucz)),
            "갇힘 방지: 장치 안 플레이어는 그린하우스 반대쪽(장치 정면)으로"
        )
        clearFakePlayers()
    end
    local unit = facilitiesFolder:FindFirstChild("nutrient")
    check(
        unit ~= nil
            and H.label(MissionWorld.controlPanel("nutrient")):GetAttribute("TextKey")
                == "facility.nutrient.name",
        "영양분: 장치와 제어반"
    )
    local ulo, uhi = H.bounds(unit:FindFirstChild("Visual"))
    local glo, ghi = H.bounds(farm:FindFirstChild("Visual"))
    local overlapUnit = ulo.X < ghi.X and glo.X < uhi.X and ulo.Z < ghi.Z and glo.Z < uhi.Z
    check(not overlapUnit, "영양분: 장치가 그린하우스와 겹치지 않는다")

    -- 파이프
    check(MissionWorld.place("pipe1", { siteIndex = 1 }), "파이프: place (얼음 지점 1)")
    info = MissionWorld.facilityInfo("pipe1")
    check(
        info.siteIndex == 1 and info.segments > 0 and info.visibleSegments == 0,
        "파이프: 관로 " .. info.segments .. "구간, 진행 0이면 안 보임"
    )
    local wellhead = H.find(facilitiesFolder, "pipe1.Wellhead")
    local site1 = MissionWorld.getMarker("Ice4").position
    local wlo, whi = H.bounds(wellhead)
    local wc = (wlo + whi) / 2
    check(
        math.abs(wc.X - site1.X) < 1 and math.abs(wc.Z - site1.Z) < 1,
        "파이프: 우물머리는 가장 가까운 얼음 지점(siteIndex 1 = Ice4)"
    )
    local tankPipe = H.find(facilitiesFolder, "pipe1.TankPipe")
    check(
        tankPipe ~= nil and tankPipe.Visual:GetAttribute("AssetSource") == "asset",
        "파이프: 디자이너 Pipe를 탱크 연결관으로"
    )
    check(
        H.near(info.offsets[1], -info.heights[1], 1e-3),
        "파이프: 진행 0이면 연결관도 땅속"
    )
    MissionWorld.setBuildProgress("pipe1", 0.5)
    advance(2)
    info = MissionWorld.facilityInfo("pipe1")
    check(
        info.visibleSegments == math.floor(info.segments * 0.5),
        "파이프: 진행 0.5면 관로 절반"
    )
    MissionWorld.setActive("pipe1", true)
    info = MissionWorld.facilityInfo("pipe1")
    check(
        info.visibleSegments == info.segments and H.near(info.offsets[2], 0, 1e-6),
        "파이프: 가동이면 관로 전부, 우물머리 완공"
    )
    do
        local tankVisual = H.find(runtime, "Base.WaterTank.Visual")
        local tlo, thi = H.bounds(tankVisual)
        local scale = H.find(runtime, "Base.WaterTank"):GetAttribute("AssetScale")
        -- 파트 이름에 점(.002)이 있어 H.find 대신 FindFirstChild
        local pipeVisual = tankPipe:FindFirstChild("Visual")
        local ring = pipeVisual:FindFirstChild("Tank_Connector_Ring.002")
        local ground = pipeVisual:FindFirstChild("Ground_Base.002")
        local sleeve = pipeVisual:FindFirstChild("Buried_Sleeve.002")
        local authoredRing = fixture.pipe:FindFirstChild("Tank_Connector_Ring.002")
        check(
            H.near(ring.Size.Y, authoredRing.Size.Y * scale, 1e-3)
                and H.near(ring.Size.Z, authoredRing.Size.Z * scale, 1e-3),
            "파이프: 탱크와 같은 배율 (따로 맞추지 않는다)"
        )
        local rlo, rhi = H.bounds(ring)
        local back = fixture.tankBack
        local side = Vector3.new(back.Z, 0, -back.X) -- 뒤 끝 방향에 수직인 수평축
        local _, tankEdge = H.alongRange(tlo, thi, back)
        local ringNear = H.alongRange(rlo, rhi, back)
        check(
            H.near(ringNear, tankEdge, 0.01),
            string.format(
                "파이프: 고리가 탱크 뒤 끝 면에 닿는다 (%.3f, %.3f)",
                ringNear,
                tankEdge
            )
        )
        check(
            H.near(H.along((rlo + rhi) / 2, side), H.along((tlo + thi) / 2, side), 0.01),
            "파이프: 고리 가운데가 탱크 축에"
        )
        check(rlo.Y >= tlo.Y and rhi.Y <= thi.Y, "파이프: 고리가 탱크 높이 범위 안")
        local pipeLo, pipeHi = H.bounds(tankPipe:FindFirstChild("Visual"))
        local pipeNear = H.alongRange(pipeLo, pipeHi, back)
        check(
            pipeNear >= tankEdge - 0.01,
            "파이프: 연결관은 탱크 바깥(얼음 쪽)으로 나간다"
        )
        local baseLo, baseHi = H.bounds(ground)
        local gc = (baseLo + baseHi) / 2
        check(H.near(baseLo.Y, groundAt(gc.X, gc.Z), 0.01), "파이프: 받침 밑면이 지면")
        local slo2 = H.bounds(sleeve)
        check(slo2.Y < baseLo.Y - 1, "파이프: 엘보 아래 슬리브는 땅속")
        local seg = H.find(facilitiesFolder, "pipe1.Pipeline.Segment1")
        local e0 = seg.CFrame * Vector3.new(-seg.Size.X / 2, 0, 0)
        local e1 = seg.CFrame * Vector3.new(seg.Size.X / 2, 0, 0)
        local function flat(a, b2)
            return math.sqrt((a.X - b2.X) ^ 2 + (a.Z - b2.Z) ^ 2)
        end
        check(
            math.min(flat(e0, gc), flat(e1, gc)) < 1,
            "파이프: 관로는 받침에서 시작한다"
        )
        check(
            H.near(
                seg.CFrame.Position.Y,
                groundAt(seg.CFrame.Position.X, seg.CFrame.Position.Z),
                0.6
            ),
            "파이프: 관로는 반쯤 묻힌다"
        )
        local panelPos = MissionWorld.controlPanel("pipe1").CFrame.Position
        local spotPos = MissionWorld.anchor("pipeSpot").CFrame.Position
        check(flat(panelPos, spotPos) < 5, "파이프: 제어반은 파이프 착공 자리 곁")
    end
    MissionWorld.setPipeSite("pipe1", 2)
    wlo, whi = H.bounds(H.find(facilitiesFolder, "pipe1.Wellhead"))
    wc = (wlo + whi) / 2
    local site2 = MissionWorld.getMarker("Ice5").position
    check(
        math.abs(wc.X - site2.X) < 1 and math.abs(wc.Z - site2.Z) < 1,
        "파이프: 지점을 바꾸면 우물머리 이동 (siteIndex 2 = Ice5)"
    )

    check(MissionWorld.place("rocket") == false, "시설: 모르는 시설은 놓지 않는다")
    -- 에어록은 시설 손잡이로 불러도 상태 표시로 바뀐다 (건물은 placeBase가 이미 놓았다)
    MissionWorld.setBuildProgress("airlock", 0.5)
    check(
        MissionWorld.getAirlockStatus() == "inspecting",
        "에어록: setBuildProgress -> inspecting"
    )
    MissionWorld.setActive("airlock", true)
    MissionWorld.setPaused("airlock", true)
    check(MissionWorld.getAirlockStatus() == "paused", "에어록: setActive + setPaused -> paused")
    MissionWorld.setPaused("airlock", false)
    check(MissionWorld.getAirlockStatus() == "active", "에어록: 멈춤 해제 -> active")
    MissionWorld.setAirlockStatus("idle")
end

-- syncFacilities ------------------------------------------------------------
print("[동기화]")
do
    -- Rules 모양 (state.facilities): nutrient는 빠졌고 led는 건설 중, airlock은 가동
    MissionWorld.syncFacilities({
        airlock = {
            id = "airlock",
            defId = "airlock",
            status = "active",
            paused = false,
            daysLeft = 0,
            buildDays = 2,
        },
        farm = {
            id = "farm",
            defId = "farm",
            status = "active",
            paused = true,
            daysLeft = 0,
            buildDays = 3,
        },
        hydroponics = {
            id = "hydroponics",
            defId = "hydroponics",
            status = "active",
            paused = false,
            daysLeft = 0,
            buildDays = 1,
        },
        pipe1 = {
            id = "pipe1",
            defId = "pipe",
            status = "building",
            paused = false,
            daysLeft = 4,
            buildDays = 5,
            siteIndex = 3,
        },
    })
    advance(2)
    check(MissionWorld.getAirlockStatus() == "active", "동기화: airlock active")
    check(
        facilitiesFolder:FindFirstChild("nutrient") == nil
            and facilitiesFolder:FindFirstChild("led") == nil,
        "동기화: 목록에 없는 시설은 지운다"
    )
    check(MissionWorld.facilityInfo("farm").paused == true, "동기화: farm 멈춤")
    local pipe = MissionWorld.facilityInfo("pipe1")
    check(
        pipe.siteIndex == 3 and pipe.status == "building" and H.near(pipe.progress, 0.2),
        "동기화: 파이프 지점 3, 진행 0.2"
    )
    check(
        #MissionWorld.upgradeParts("led") == 4
            and MissionWorld.upgradeParts("led")[1].Transparency == 1,
        "동기화: LED를 지우면 LED 바 숨김"
    )
    check(
        MissionWorld.upgradeParts("hydroponics")[1].Material == Enum.Material.SmoothPlastic,
        "동기화: 재배 공간 멈춤이면 수경 베드도 꺼진 모습"
    )
    -- MissionState 모양 (airlock 항목 없음): 에어록은 그대로
    MissionWorld.syncFacilities({
        farm = { status = "active" },
        hydroponics = { status = "paused" },
        pipe1 = { status = "active", siteIndex = 3 },
        led = { status = "available" },
    })
    check(
        MissionWorld.getAirlockStatus() == "active",
        "동기화: airlock 항목이 없으면 에어록 상태 유지"
    )
    check(
        MissionWorld.facilityInfo("farm").paused == false
            and MissionWorld.facilityInfo("hydroponics").paused == true,
        "동기화: MissionState status paused"
    )
    check(facilitiesFolder:FindFirstChild("led") == nil, "동기화: available은 놓지 않는다")
end

-- reset ---------------------------------------------------------------------
print("[reset]")
do
    MissionWorld.reset()
    advance(2)
    check(
        runtime.Parent == Workspace and runtime:FindFirstChild("Base") ~= nil,
        "reset: 기지를 다시 놓는다"
    )
    local facilities = runtime:FindFirstChild("Facilities")
    check(facilities ~= nil and #facilities:GetChildren() == 0, "reset: 시설 비움")
    check(
        MissionWorld.facilityModel("farm") == nil and MissionWorld.getAirlockStatus() == "idle",
        "reset: 시설 상태와 에어록 초기화"
    )
    check(#H.find(runtime, "Base.SolarField.Panels"):GetChildren() == 0, "reset: 패널 0")
    check(
        fixture.preview.Parent == nil and fixture.missionC.Lander.Transparency == 1,
        "reset: AssetPreview 떼기와 표시 숨김 유지"
    )
    check(
        MissionWorld.getShelter("airlock").zone:GetAttribute("ZoneKind") == "shelter",
        "reset: 에어록 구역 shelter"
    )
    check(
        MissionWorld.place("farm") and MissionWorld.upgradeParts("led")[1].Transparency == 1,
        "reset: 다시 지을 수 있다"
    )
    -- Rules 파이프 id: 첫째 "pipe"(숫자 없음), 둘째 "pipe2"
    check(
        MissionWorld.place("pipe", { siteIndex = 1 }) and facilities:FindFirstChild("pipe") ~= nil,
        "파이프 id: 숫자 없는 pipe도 파이프"
    )
    check(
        MissionWorld.place("pipe2", { siteIndex = 2 })
            and MissionWorld.facilityInfo("pipe2").siteIndex == 2,
        "파이프 id: pipe2는 둘째 파이프"
    )
    local s1lo, s1hi = H.bounds(H.find(facilities, "pipe.TankPipe.Visual"))
    local s2lo, s2hi = H.bounds(H.find(facilities, "pipe2.TankPipe.Visual"))
    local stationsOverlap = s1lo.X < s2hi.X
        and s2lo.X < s1hi.X
        and s1lo.Z < s2hi.Z
        and s2lo.Z < s1hi.Z
    check(not stationsOverlap, "파이프 id: 둘째 연결관은 옆으로 비켜 놓는다")
end

-- 표시가 없을 때 ---------------------------------------------------------------
print("[표시 검사]")
do
    fixture.missionC.WaterTank.Name = "WaterTankMoved"
    local ok, missing = MissionWorld.init("C")
    check(
        ok == false and #missing == 1 and missing[1] == "WaterTank",
        "검사: 빠진 표시 이름을 돌려준다"
    )
    MissionWorld.placeBase()
    check(
        runtime:FindFirstChild("Base"):FindFirstChild("WaterTank") == nil
            and MissionWorld.getShelter("lander") ~= nil,
        "검사: 빠진 것만 건너뛰고 나머지는 놓는다"
    )
    check(
        MissionWorld.place("pipe1", { siteIndex = 1 }) == false,
        "검사: 물탱크가 없으면 파이프를 놓지 않는다"
    )
    fixture.missionC.WaterTankMoved.Name = "WaterTank"
    local okB, missingB = MissionWorld.init("B")
    check(
        okB == false and missingB[1] == "MissionB",
        "검사: MissionB 폴더가 없으면 실패와 폴더 이름"
    )
    local okC = MissionWorld.init("C")
    MissionWorld.placeBase()
    check(
        okC and runtime:FindFirstChild("Base"):FindFirstChild("WaterTank") ~= nil,
        "검사: 되돌리면 다시 정상"
    )
end

-- 대체 에셋 (디자이너 WaterTank, Pipe가 없을 때) ---------------------------------
print("[대체 에셋]")
do
    fixture.tank.Name = "WaterTankOff"
    fixture.pipe.Name = "PipeOff"
    MissionWorld.reset()
    local tankVisual = H.find(runtime, "Base.WaterTank.Visual")
    check(
        tankVisual and tankVisual:GetAttribute("AssetSource") == "kit",
        "대체: 물탱크는 Kit WaterTank"
    )
    check(
        MissionWorld.place("pipe", { siteIndex = 1 }),
        "대체: 키트 탱크에도 파이프를 놓는다"
    )
    MissionWorld.setActive("pipe", true)
    local pipeVisual = H.find(runtime, "Facilities.pipe.TankPipe.Visual")
    check(
        pipeVisual and pipeVisual:GetAttribute("AssetSource") == "kit",
        "대체: 파이프는 Kit Connector + Elbow"
    )
    local tlo, thi = H.bounds(tankVisual)
    local plo, phi = H.bounds(pipeVisual)
    local _, tankEdge = H.alongRange(tlo, thi, fixture.tankBack)
    local pipeNear = H.alongRange(plo, phi, fixture.tankBack)
    check(
        H.near(pipeNear, tankEdge, 0.01),
        "대체: 키트 파이프도 탱크 뒤 끝에 붙는다"
    )
    fixture.tank.Name = "WaterTank"
    fixture.pipe.Name = "Pipe"
    MissionWorld.reset()
    check(
        H.find(runtime, "Base.WaterTank.Visual"):GetAttribute("AssetSource") == "asset",
        "대체: 에셋을 되돌리면 디자이너 물탱크"
    )
    check(tlo.X < thi.X, "대체: 키트 탱크 경계")
end

-- 디자이너 영역 --------------------------------------------------------------
print("[디자이너 영역]")
check(#terrainCalls == 0, "지형: Terrain 편집 호출 없음")
check(
    Lighting.ClockTime == lightingBefore.clock and Lighting.Brightness == lightingBefore.brightness,
    "조명: Lighting 값 그대로"
)
check(terrainInstance.Parent == Workspace, "지형: Terrain 그대로")
check(
    raycasts.total > 0 and raycasts.total == raycasts.terrainOnly,
    "지면: 광선은 Terrain만 맞힌다 (" .. raycasts.total .. "회)"
)
check(threadErrors == 0, "스레드 오류 없음")

print(
    string.format(
        "월드 스모크 결과: 통과 %d, 실패 %d, 경고 %d",
        passes,
        failures,
        #warnings
    )
)
if failures > 0 then
    process.exit(1)
end
