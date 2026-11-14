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

-- 실측 지면 높이 (2026-11-14 Studio, 표시 중심 아래 지형) 를 역거리 가중으로 보간한 지면
local GROUND_SAMPLES = {
    { 188.3, -516.6, -0.8 }, -- Lander
    { 180.3, -542.4, -0.6 }, -- SpawnLocation
    { 39.3, -496.9, 0.2 }, -- SolarField
    { -14.2, -595.9, 1.0 }, -- FarmPad
    { -14.2, -673.9, -1.1 }, -- WaterTank
    { 122.8, -577.9, -2.8 }, -- RoverPark
    { 312.7, -416.0, -3.4 }, -- BaseExit
    { 174.8, -525.6, -1.2 }, -- Airlock
    { 576.5, -245.5, -4.3 }, -- Ice1
    { 664.0, -663.7, -4.1 }, -- Ice2
    { 759.9, -183.8, -0.4 }, -- Ice3
    { 328.0, -232.0, -28.8 }, -- Ice4
    { -296.1, -375.9, -15.4 }, -- Ice5
}
local function groundAt(x: number, z: number): number
    local sum, weight = 0, 0
    for _, s in GROUND_SAMPLES do
        local d2 = (x - s[1]) ^ 2 + (z - s[2]) ^ 2
        if d2 < 1e-6 then
            return s[3]
        end
        local w = 1 / d2
        sum += w * s[3]
        weight += w
    end
    return sum / weight
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

local YAW_LOOK_PLUS_X = CFrame.Angles(0, math.rad(-90), 0) -- LookVector (1, 0, 0)
local UPRIGHT_CYLINDER = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 1, 0), Vector3.new(0, 0, 1)) -- 원기둥 축 X가 위
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
fixture.marker(
    "Lander",
    "Part",
    Vector3.new(188.3, 11.2, -516.6),
    Vector3.new(28, 118, 12),
    UPRIGHT_CYLINDER,
    Enum.PartType.Cylinder
)
fixture.marker(
    "Airlock",
    "Part",
    Vector3.new(174.8, 2.2, -525.6),
    Vector3.new(11, 105, 9),
    UPRIGHT_CYLINDER,
    Enum.PartType.Cylinder
)
fixture.marker(
    "SpawnLocation",
    "SpawnLocation",
    Vector3.new(180.3, -0.5, -542.4),
    Vector3.new(12, 1, 12),
    CFrame.Angles(0, math.rad(90), 0)
)
fixture.marker(
    "SolarField",
    "Part",
    Vector3.new(39.3, 3.6, -496.9),
    Vector3.new(82, 5, 49),
    CFrame.Angles(0, math.rad(180), 0)
)
fixture.marker(
    "FarmPad",
    "Part",
    Vector3.new(-14.2, 13.6, -595.9),
    Vector3.new(31, 20, 25),
    YAW_LOOK_PLUS_X
)
fixture.marker(
    "WaterTank",
    "Part",
    Vector3.new(-14.2, 8.8, -673.9),
    Vector3.new(31, 20, 25),
    YAW_LOOK_PLUS_X
)
fixture.marker(
    "RoverPark",
    "Part",
    Vector3.new(122.8, -1.5, -577.9),
    Vector3.new(31, 4, 25),
    YAW_LOOK_PLUS_X
)
fixture.marker(
    "BaseExit",
    "Part",
    Vector3.new(312.7, -1.5, -416.0),
    Vector3.new(31, 4, 25),
    CFrame.Angles(0, math.atan2(-0.7776, -0.6288), 0)
)
for i, pos in
    {
        Vector3.new(576.5, -3.9, -245.5),
        Vector3.new(664.0, -2.3, -663.7),
        Vector3.new(759.9, 1.5, -183.8),
        Vector3.new(328.0, -26.9, -232.0),
        Vector3.new(-296.1, -13.6, -375.9),
    }
do
    fixture.marker("Ice" .. i, "Part", pos, Vector3.new(31, 4, 25), YAW_LOOK_PLUS_X)
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
        H.near(lander.extents.X, 12, 0.01)
            and H.near(lander.extents.Y, 28, 0.01)
            and H.near(lander.extents.Z, 12, 0.01),
        "init: 세운 원기둥 렌더 크기 12 x 28 x 12 (" .. tostring(lander.extents) .. ")"
    )
    check(
        lander.groundFound and H.near(lander.groundSamples[1], -0.8, 0.01),
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
    local function centerZ(name)
        local lo, hi = H.bounds(tankVisual:FindFirstChild(name))
        return (lo.Z + hi.Z) / 2
    end
    check(
        centerZ("Rear_Utility_Housing") > centerZ("Main_Pressurized_Hull")
            and centerZ("Front_Door") < centerZ("Main_Pressurized_Hull"),
        "물탱크: 뒤 끝(설비)이 얼음 쪽(+Z), 문이 반대쪽"
    )
    local unload = MissionWorld.anchor("unloadPoint").CFrame.Position
    local dockPos = MissionWorld.anchor("roverDock").CFrame.Position
    check(
        unload.X > vhi.X and dockPos.X > vhi.X,
        "물탱크: 하역 자리와 귀환 자리는 착륙선 쪽 긴 옆면"
    )
    check(dockPos.Z < unload.Z, "물탱크: 귀환 자리는 문 쪽으로 비켜 있다")
    check(
        MissionWorld.anchor("pipeSpot").CFrame.Position.Z > vhi.Z,
        "물탱크: 파이프 착공 자리는 뒤 끝 바깥"
    )
    for _, id in { "unloadPoint", "roverDock", "pipeSpot" } do
        check(MissionWorld.anchor(id) ~= nil, "물탱크: 자리 " .. id)
    end
    check(
        MissionWorld.anchor("pipeSpot").CFrame.Position.Z
            > MissionWorld.getMarker("WaterTank").position.Z,
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
        "출구: 표시 방향(얼음 쪽)을 본다"
    )

    -- 얼음
    local sites = MissionWorld.iceSites()
    local order = {}
    for _, site in sites do
        table.insert(order, site.markerName)
    end
    check(
        table.concat(order, ",") == "Ice4,Ice1,Ice2,Ice3,Ice5",
        "얼음: 출구 기준 거리 순서 " .. table.concat(order, ",")
    )
    check(
        H.near(sites[1].distanceFromExit, 184.6, 0.5)
            and H.near(sites[5].distanceFromExit, 610.1, 0.5),
        "얼음: 출구 거리 184.6 ~ 610.1"
    )
    check(
        H.near(sites[1].distanceFromRoverPark, 402.2, 0.5),
        "얼음: 로버 주차 거리 (Ice4 약 402)"
    )
    check(
        H.near(sites[1].distanceFromLander, 317.0, 0.5),
        "얼음: 착륙선 거리 (Ice4 약 317)"
    )
    local distances = MissionWorld.iceDistances()
    check(
        H.near(distances.Ice5, 610.1, 0.5) and H.near(distances.Ice4, 184.6, 0.5),
        "얼음: Rules용 거리표"
    )
    local iceFolder = runtime:FindFirstChild("IceSites")
    local ice4 = iceFolder and iceFolder:FindFirstChild("Ice4")
    check(
        ice4 ~= nil
            and ice4:GetAttribute("SiteIndex") == 1
            and ice4:FindFirstChild("MinePoint") ~= nil,
        "얼음: IceSites.Ice4 SiteIndex 1, 채취 자리"
    )
    check(
        ice4
            and ice4:FindFirstChild("Crystal")
            and ice4.Crystal:GetAttribute("AssetSource") == "kit",
        "얼음: 결정 외형은 Kit IceCrystal"
    )
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
    advance(2)
    local after = H.bounds(panel1)
    check(H.near(after.Y, slotTop, 0.01), "패널: 솟아올라 슬롯 윗면에 선다")
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

    -- 영양분
    MissionWorld.place("nutrient")
    MissionWorld.setActive("nutrient", true)
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
    local ice4 = MissionWorld.getMarker("Ice4").position
    local wlo, whi = H.bounds(wellhead)
    local wc = (wlo + whi) / 2
    check(
        math.abs(wc.X - ice4.X) < 1 and math.abs(wc.Z - ice4.Z) < 1,
        "파이프: 우물머리는 가장 가까운 얼음 지점(Ice4)"
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
        check(
            H.near(rlo.Z, thi.Z, 0.01),
            string.format(
                "파이프: 고리가 탱크 뒤 끝 면에 닿는다 (%.3f, %.3f)",
                rlo.Z,
                thi.Z
            )
        )
        check(
            H.near((rlo.X + rhi.X) / 2, (tlo.X + thi.X) / 2, 0.01),
            "파이프: 고리 가운데가 탱크 축에"
        )
        check(rlo.Y >= tlo.Y and rhi.Y <= thi.Y, "파이프: 고리가 탱크 높이 범위 안")
        local pipeLo = H.bounds(tankPipe:FindFirstChild("Visual"))
        check(
            pipeLo.Z >= thi.Z - 0.01,
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
    local ice1 = MissionWorld.getMarker("Ice1").position
    check(
        math.abs(wc.X - ice1.X) < 1 and math.abs(wc.Z - ice1.Z) < 1,
        "파이프: 지점을 바꾸면 우물머리 이동 (Ice1)"
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
    local plo = H.bounds(pipeVisual)
    check(H.near(plo.Z, thi.Z, 0.01), "대체: 키트 파이프도 탱크 뒤 끝에 붙는다")
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
