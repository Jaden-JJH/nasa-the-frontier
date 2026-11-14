-- v2 서버 통합 스모크 테스트. tests/run.luau가 place를 빌드해 하위 프로세스로 실행한다 (CI 포함).
-- rojo build 결과 place를 Lune로 읽고, world_smoke와 같은 Studio MissionC 실측 좌표 픽스처(표시 13개, 그린하우스, 키트)를
-- 놓은 뒤 v2 Main.server를 부팅한다. Lune에 없는 Roblox API(이벤트, task, PivotTo, Raycast, 좌석)는 흉내 내고
-- 가상 시계로 돌린다. 물리(실제 주행)와 클라이언트 UI는 검증하지 않는다.
--   1판(솔로): 미션 선택 -> 착륙 -> 에어록 점검, 패널 -> 자율주행 파견과 귀환 -> 재배 공간 -> GST -> 업그레이드 ->
--             파이프(콘솔 SetPipeSite + 착공) -> SEP 경보와 대피, 문 잠금 -> 산소 구조 -> 수경 재배 -> 금메달 -> 기록 -> 재시작
--   2판(멀티 2명): 역할 선택, 핀, 직접 운전 채취와 하역, 충돌 파손과 수리, 충전, 역할 맞바꾸기, 관제사 이탈 -> 부족 실패 -> 재시작
--   모든 송신 페이로드에 문장(공백이나 한글이 든 문자열)이 없는지, 보낸 Msg 키가 문구표에 있는지 검사한다.
--
-- 단독 실행: rojo build default.project.json -o build/server_smoke_v2.rbxl && lune run tests/server_smoke_v2.luau build/server_smoke_v2.rbxl

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local placePath = process.args[1] or "build/server_smoke_v2.rbxl"
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

-- 가상 시계와 task 스케줄러 -----------------------------------------------
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

-- 신호 ------------------------------------------------------------------
local function newSignal()
    local s = { handlers = {} }
    function s:Connect(fn)
        local h = { fn = fn, connected = true }
        table.insert(self.handlers, h)
        return {
            Disconnect = function()
                h.connected = false
            end,
        }
    end
    function s:Once(fn)
        local connection
        connection = self:Connect(function(...)
            connection.Disconnect()
            fn(...)
        end)
        return connection
    end
    function s:Fire(...)
        for _, h in table.clone(self.handlers) do
            if h.connected then
                task.spawn(h.fn, ...)
            end
        end
    end
    return s
end
local signals = {}
local nextSignalId = 0
local function signalFor(inst, name)
    local id = inst:GetAttribute("__sid")
    if not id then
        nextSignalId += 1
        id = nextSignalId
        inst:SetAttribute("__sid", id)
    end
    local key = id .. ":" .. name
    if not signals[key] then
        signals[key] = newSignal()
    end
    return signals[key]
end

-- 송신 기록 -------------------------------------------------------------
local sent = {}
local R = {} -- 송신 조회 도우미
function R.last(name, target)
    for i = #sent, 1, -1 do
        local s = sent[i]
        if s.name == name and (target == nil or s.target == target or s.target == "all") then
            return s
        end
    end
    return nil
end
function R.count(name)
    local n = 0
    for _, s in sent do
        if s.name == name then
            n += 1
        end
    end
    return n
end
function R.mark()
    return #sent
end
-- mark 뒤로 보낸 Notify 중 key인 것 (target이 있으면 그 플레이어 또는 전체)
function R.notified(since, key, target)
    for i = since + 1, #sent do
        local s = sent[i]
        if s.name == "Notify" and s.args[1] and s.args[1].key == key then
            if target == nil or s.target == target or s.target == "all" then
                return s
            end
        end
    end
    return nil
end
function R.since(since, name)
    for i = #sent, since + 1, -1 do
        if sent[i].name == name then
            return sent[i]
        end
    end
    return nil
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
roblox.implementMethod("Model", "WaitForChild", function(inst, name)
    return inst:FindFirstChild(name)
end)
roblox.implementProperty("Model", "ChildAdded", function(inst)
    return signalFor(inst, "ChildAdded")
end)
roblox.implementProperty("VehicleSeat", "ThrottleFloat", function()
    return 0
end)
roblox.implementProperty("VehicleSeat", "SteerFloat", function()
    return 0
end)
for _, className in { "VehicleSeat", "Humanoid" } do
    roblox.implementMethod(className, "GetPropertyChangedSignal", function(inst, prop)
        return signalFor(inst, "Changed:" .. prop)
    end)
end
-- 좌석: Sit(humanoid)으로 앉힌다 (Occupant 변경 신호). Lune은 실제 속성의 setter 흉내를 부르지 않아서
-- humanoid.Sit = false 하차는 흉내 내지 못한다. 테스트는 H.unseat로 내린다
roblox.implementMethod("VehicleSeat", "Sit", function(seat, hum)
    seat.Occupant = hum
    hum.SeatPart = seat
    signalFor(seat, "Changed:Occupant"):Fire()
end)
roblox.implementProperty("Humanoid", "Died", function(inst)
    return signalFor(inst, "Died")
end)
roblox.implementProperty("ProximityPrompt", "Triggered", function(inst)
    return signalFor(inst, "Triggered")
end)
for _, className in
    {
        "Part",
        "VehicleSeat",
        "WedgePart",
        "MeshPart",
        "UnionOperation",
        "TrussPart",
        "SpawnLocation",
        "CornerWedgePart",
    }
do
    roblox.implementProperty(className, "Touched", function(inst)
        return signalFor(inst, "Touched")
    end)
    roblox.implementProperty(className, "AssemblyLinearVelocity", function(inst)
        return inst:GetAttribute("__alv") or Vector3.zero
    end, function(inst, value)
        inst:SetAttribute("__alv", value)
    end)
    roblox.implementProperty(className, "AssemblyAngularVelocity", function(inst)
        return inst:GetAttribute("__aav") or Vector3.zero
    end, function(inst, value)
        inst:SetAttribute("__aav", value)
    end)
end
roblox.implementMethod("Sound", "Play", function() end)
roblox.implementMethod("Sound", "Stop", function() end)
roblox.implementProperty("Sound", "Ended", function(inst)
    return signalFor(inst, "Ended")
end)
roblox.implementProperty("RunService", "Heartbeat", function(inst)
    return signalFor(inst, "Heartbeat")
end)
roblox.implementMethod("RunService", "IsServer", function()
    return true
end)
roblox.implementProperty("RemoteEvent", "OnServerEvent", function(inst)
    return signalFor(inst, "OnServerEvent")
end)
roblox.implementMethod("RemoteEvent", "FireAllClients", function(inst, ...)
    table.insert(sent, { name = inst.Name, target = "all", args = table.pack(...) })
end)
roblox.implementMethod("RemoteEvent", "FireClient", function(inst, player, ...)
    table.insert(sent, { name = inst.Name, target = player, args = table.pack(...) })
end)
roblox.implementMethod("HttpService", "JSONEncode", function(_, value)
    return serde.encode("json", value)
end)
roblox.implementMethod("DataModel", "BindToClose", function() end)
roblox.implementMethod("Workspace", "GetServerTimeNow", function()
    return 1700000000 + now
end)
roblox.implementMethod("Workspace", "GetPartBoundsInBox", function(ws, cframe, size)
    local result = {}
    local half = size / 2
    for _, d in ws:GetDescendants() do
        if d:IsA("BasePart") then
            local p = cframe:PointToObjectSpace(d.CFrame.Position)
            if math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z then
                table.insert(result, d)
            end
        end
    end
    return result
end)
-- 지형: 실측 지면 높이를 역거리 가중으로 보간 (world_smoke와 같은 값). 지형을 바꾸는 호출은 기록만
local terrainCalls = {}
for _, method in { "FillBlock", "FillBall", "FillCylinder", "FillRegion", "Clear", "WriteVoxels" } do
    roblox.implementMethod("Terrain", method, function()
        table.insert(terrainCalls, method)
    end)
end
local GROUND_SAMPLES = {
    { 188.3, -516.6, -0.8 },
    { 180.3, -542.4, -0.6 },
    { 39.3, -496.9, 0.2 },
    { -14.2, -595.9, 1.0 },
    { -14.2, -673.9, -1.1 },
    { 122.8, -577.9, -2.8 },
    { 312.7, -416.0, -3.4 },
    { 174.8, -525.6, -1.2 },
    { 576.5, -245.5, -4.3 },
    { 664.0, -663.7, -4.1 },
    { 759.9, -183.8, -0.4 },
    { 328.0, -232.0, -28.8 },
    { -296.1, -375.9, -15.4 },
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
local Workspace = dm:GetService("Workspace")
local terrainInstance = Instance.new("Terrain")
terrainInstance.Parent = Workspace
roblox.implementMethod("Workspace", "Raycast", function(_, origin, direction, params)
    local filter = params and params.FilterDescendantsInstances
    if
        not params
        or params.FilterType ~= Enum.RaycastFilterType.Include
        or not filter
        or filter[1] ~= terrainInstance
    then
        return nil
    end
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
-- DataStore: Lune처럼 없다 (서버는 메모리 목록과 offline으로 바꾼다)
roblox.implementMethod("DataStoreService", "GetDataStore", function()
    error("GetDataStore is not a valid member of DataStoreService")
end)

-- 가짜 플레이어 ---------------------------------------------------------
local PlayersService = dm:GetService("Players")
local players = {}
roblox.implementMethod("Players", "GetPlayers", function()
    return table.clone(players)
end)
roblox.implementMethod("Players", "GetPlayerFromCharacter", function(_, character)
    for _, p in players do
        if p.Character ~= nil and p.Character == character then
            return p
        end
    end
    return nil
end)
roblox.implementProperty("Players", "PlayerAdded", function(inst)
    return signalFor(inst, "PlayerAdded")
end)
roblox.implementProperty("Players", "PlayerRemoving", function(inst)
    return signalFor(inst, "PlayerRemoving")
end)

local function makePlayer(name: string, userId: number)
    local attrs = {}
    local p = {
        Name = name,
        DisplayName = name,
        UserId = userId,
        Parent = PlayersService,
        Character = nil,
        CharacterAdded = newSignal(),
        CharacterAppearanceLoaded = newSignal(),
    }
    function p:SetAttribute(key, value)
        attrs[key] = value
    end
    function p:GetAttribute(key)
        return attrs[key]
    end
    local character = Instance.new("Model")
    character.Name = name
    local root = Instance.new("Part")
    root.Name = "HumanoidRootPart"
    root.Size = Vector3.new(2, 2, 1)
    root.Anchored = true
    root.Parent = character
    character.PrimaryPart = root
    local humanoid = Instance.new("Humanoid")
    humanoid.Health = 100
    humanoid.Parent = character
    character.Parent = Workspace
    p.Character = character
    return p
end
local function join(p)
    table.insert(players, p)
    signalFor(PlayersService, "PlayerAdded"):Fire(p)
    advance(0)
end
local function leave(p)
    signalFor(PlayersService, "PlayerRemoving"):Fire(p)
    local index = table.find(players, p)
    if index then
        table.remove(players, index)
    end
    p.Parent = nil
    advance(0)
end
local function moveTo(p, position)
    p.Character:PivotTo(CFrame.new(position))
end
local function humanoidOf(p)
    return p.Character:FindFirstChildOfClass("Humanoid")
end

-- 픽스처 (world_smoke와 같은 Studio 실측 좌표) -------------------------------------
local ServerStorage = dm:GetService("ServerStorage")
local ReplicatedStorage = dm:GetService("ReplicatedStorage")
local missionC = Instance.new("Folder")
missionC.Name = "MissionC"
missionC.Parent = Workspace
local YAW_LOOK_PLUS_X = CFrame.Angles(0, math.rad(-90), 0)
local UPRIGHT_CYLINDER = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 1, 0), Vector3.new(0, 0, 1))
local function marker(name, className, pos, size, rot, shape)
    local part = Instance.new(className)
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(pos) * rot
    part.Anchored = false
    if shape then
        part.Shape = shape
    end
    part.Parent = missionC
    return part
end
marker(
    "Lander",
    "Part",
    Vector3.new(188.3, 11.2, -516.6),
    Vector3.new(28, 118, 12),
    UPRIGHT_CYLINDER,
    Enum.PartType.Cylinder
)
marker(
    "Airlock",
    "Part",
    Vector3.new(174.8, 2.2, -525.6),
    Vector3.new(11, 105, 9),
    UPRIGHT_CYLINDER,
    Enum.PartType.Cylinder
)
marker(
    "SpawnLocation",
    "SpawnLocation",
    Vector3.new(180.3, -0.5, -542.4),
    Vector3.new(12, 1, 12),
    CFrame.Angles(0, math.rad(90), 0)
)
marker(
    "SolarField",
    "Part",
    Vector3.new(39.3, 3.6, -496.9),
    Vector3.new(82, 5, 49),
    CFrame.Angles(0, math.rad(180), 0)
)
marker(
    "FarmPad",
    "Part",
    Vector3.new(-14.2, 13.6, -595.9),
    Vector3.new(31, 20, 25),
    YAW_LOOK_PLUS_X
)
marker(
    "WaterTank",
    "Part",
    Vector3.new(-14.2, 8.8, -673.9),
    Vector3.new(31, 20, 25),
    YAW_LOOK_PLUS_X
)
marker(
    "RoverPark",
    "Part",
    Vector3.new(122.8, -1.5, -577.9),
    Vector3.new(31, 4, 25),
    YAW_LOOK_PLUS_X
)
marker(
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
    marker("Ice" .. i, "Part", pos, Vector3.new(31, 4, 25), YAW_LOOK_PLUS_X)
end
local assets = Instance.new("Folder")
assets.Name = "Assets"
assets.Parent = ServerStorage
local kit = Instance.new("Folder")
kit.Name = "Kit"
kit.Parent = assets
for name, size in
    {
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
    }
do
    local outer = Instance.new("Model")
    outer.Name = name
    local inner = Instance.new("Model")
    inner.Name = name
    inner.Parent = outer
    local part = Instance.new("MeshPart")
    part.Name = name
    part.Size = size
    part.CFrame = CFrame.new(-3, 20, -10)
    part.Anchored = true
    part.Parent = inner
    outer.Parent = kit
end

-- 모듈 로더 -------------------------------------------------------------
local Random = {}
function Random.new(seed)
    local state = (seed or 1) % 2147483647
    local r = {}
    function r:NextNumber(a, b)
        state = (state * 16807) % 2147483647
        local u = state / 2147483647
        return (a or 0) + u * ((b or 1) - (a or 0))
    end
    return r
end
local warnings = {}
local cache = {}
local loadModule
local function makeEnv(scriptInst)
    return {
        script = scriptInst,
        game = dm,
        workspace = Workspace,
        require = function(target)
            if type(target) == "string" then
                -- "./Name" (Rules.luau의 상대 require): 같은 폴더의 ModuleScript
                local name = string.match(target, "^%./(.+)$")
                local found = name and scriptInst.Parent:FindFirstChild(name)
                assert(found, "require 경로를 찾지 못함: " .. target)
                return loadModule(found)
            end
            return loadModule(target)
        end,
        task = task,
        os = {
            clock = function()
                return now
            end,
            time = function()
                return 1700000000 + math.floor(now)
            end,
            date = os.date,
        },
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
        NumberRange = roblox.NumberRange,
        NumberSequence = roblox.NumberSequence,
        ColorSequence = roblox.ColorSequence,
        PhysicalProperties = roblox.PhysicalProperties,
        Enum = Enum,
        RaycastParams = {
            new = function()
                return {}
            end,
        },
        Random = Random,
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
        rawequal = rawequal,
        utf8 = utf8,
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
local Shared = ReplicatedStorage:FindFirstChild("Shared")
local M = {} -- 불러온 모듈 (최상위 지역 변수 수를 줄인다)

-- 검사 도우미 ------------------------------------------------------------
local H = {}
function H.hasHangul(text: string): boolean
    if utf8.len(text) == nil then
        return false
    end
    for _, cp in utf8.codes(text) do
        if
            cp >= 0xAC00 and cp <= 0xD7A3
            or cp >= 0x1100 and cp <= 0x11FF
            or cp >= 0x3130 and cp <= 0x318F
        then
            return true
        end
    end
    return false
end
-- 페이로드 안의 문장 (공백이나 한글이 든 문자열) 목록
function H.sentences(value, path, out, depth)
    depth = depth or 0
    if depth > 12 then
        return out
    end
    if type(value) == "string" then
        if string.find(value, "%s") or H.hasHangul(value) then
            table.insert(out, path .. " = " .. value)
        end
    elseif type(value) == "table" then
        for k, v in value do
            H.sentences(v, path .. "." .. tostring(k), out, depth + 1)
        end
    end
    return out
end
-- 페이로드 안의 Msg 키를 모은다 ({ key = string, args = table? } 모양)
function H.msgKeys(value, out, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 12 then
        return out
    end
    if type(value.key) == "string" and string.find(value.key, ".", 1, true) then
        local onlyMsg = true
        for k in value do
            if k ~= "key" and k ~= "args" then
                onlyMsg = false
            end
        end
        if onlyMsg then
            out[value.key] = true
        end
    end
    for _, v in value do
        H.msgKeys(v, out, depth + 1)
    end
    return out
end
function H.unseat(p)
    -- Lune은 Ref 속성(SeatPart, Occupant)을 nil로 못 쓴다. 지운 인스턴스를 가리키는 Ref는 nil로 읽히므로
    -- Humanoid를 새로 바꿔 끼워 하차를 흉내 낸다
    local old = p.Character:FindFirstChildOfClass("Humanoid")
    local seat = old.SeatPart
    local fresh = Instance.new("Humanoid")
    fresh.Health = 100
    old:Destroy()
    fresh.Parent = p.Character
    if seat then
        signalFor(seat, "Changed:Occupant"):Fire()
    end
    advance(0)
end
function H.near(a, b, tolerance)
    return math.abs(a - b) <= (tolerance or 1e-3)
end
function H.flat(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
function H.fire(name, player, ...)
    local remote = ReplicatedStorage.Remotes:FindFirstChild(name)
    signalFor(remote, "OnServerEvent"):Fire(player, ...)
    advance(0)
end
function H.trigger(prompt, player)
    signalFor(prompt, "Triggered"):Fire(player)
    advance(0)
end
function H.state()
    local s = R.last("StateUpdate")
    return s and s.args[1]
end
function H.rules()
    return M.MissionFlow.getRules()
end
-- 다음 DayTick까지 가상 시간을 보낸다 (MissionClock 루프)
function H.day()
    local before = H.rules() and H.rules().day
    local guard = 0
    while guard < 70 do
        advance(0.5)
        guard += 1
        local r = H.rules()
        if not r or r.day ~= before or M.MissionFlow.getPhase() ~= "playing" then
            break
        end
    end
    advance(0)
end
function H.topUp(fields)
    local s = M.Rules.copy(H.rules())
    for k, v in fields do
        s[k] = v
    end
    M.MissionFlow.flow.commit(s)
    advance(0)
end
function H.landerInside()
    local shelter = M.MissionWorld.getShelter("lander")
    return shelter.zone.CFrame.Position
end
function H.outsidePoint()
    -- 솔라 필드 옆 (대피처와 로버에서 멀다)
    return Vector3.new(39.3, 4, -440)
end

-- 부팅 ------------------------------------------------------------------
print("[부팅]")
task.spawn(function()
    local main = Server:FindFirstChild("Main")
    luau.load(
        main.Source,
        { debugName = "Main", environment = makeEnv(main), injectGlobals = false }
    )()
end)
advance(0)
M.MissionConfig = loadModule(Shared:FindFirstChild("MissionConfig"))
M.Rules = loadModule(Shared:FindFirstChild("Rules"))
M.Strings = loadModule(Shared:FindFirstChild("Strings"))
M.MissionFlow = loadModule(Server:FindFirstChild("MissionFlow"))
M.MissionWorld = loadModule(Server:FindFirstChild("MissionWorld"))
M.Interactions = loadModule(Server:FindFirstChild("Interactions"))
M.RoverFleet = loadModule(Server:FindFirstChild("RoverFleet"))
M.AirlockDoors = loadModule(Server:FindFirstChild("AirlockDoors"))
M.OxygenV2 = loadModule(Server:FindFirstChild("OxygenV2"))
M.Roles = loadModule(Server:FindFirstChild("Roles"))
M.RecordsV2 = loadModule(Server:FindFirstChild("RecordsV2"))
M.SpaceWeather = loadModule(Server:FindFirstChild("SpaceWeather"))

do
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local missing = {}
    for _, name in
        {
            "StateUpdate",
            "Notify",
            "MissionSelectOpen",
            "LandingSequence",
            "SpaceWeather",
            "RoleUpdate",
            "PinUpdate",
            "OxygenUpdate",
            "GameOver",
            "Records",
            "SelectMission",
            "ChooseRole",
            "SetPin",
            "DispatchRover",
            "RemoteRecoverRover",
            "SetFacilityPaused",
            "SetPipeSite",
            "RequestRestart",
            "SetLanguage",
            "RoverBoost",
        }
    do
        if not (remotes and remotes:FindFirstChild(name)) then
            table.insert(missing, name)
        end
    end
    check(
        #missing == 0,
        "Remotes: CONTRACT_V2 4.1, 4.2 이름 모두 생성 (" .. table.concat(missing, ",") .. ")"
    )
    check(
        Workspace:FindFirstChild("LandingPads") == nil,
        "v1 부팅 없음: DevMap이 LandingPads를 만들지 않음"
    )
    check(Workspace:FindFirstChild("Base") == nil, "v1 부팅 없음: Workspace.Base 없음")
    check(#terrainCalls == 0, "지형을 바꾸는 호출 없음")
    local runtime = Workspace:FindFirstChild("MissionRuntime")
    check(
        runtime and runtime:FindFirstChild("Base") ~= nil,
        "MissionWorld: MissionRuntime.Base 배치"
    )
    local rover = runtime and runtime:FindFirstChild("Rover")
    check(
        rover ~= nil
            and rover:GetAttribute("Role") == "rover"
            and rover.PrimaryPart ~= nil
            and rover:FindFirstChild("DriverSeat") ~= nil,
        "RoverFleet: MissionRuntime.Rover (Role rover, Chassis, DriverSeat)"
    )
    local park = M.MissionWorld.anchor("roverPark")
    check(
        rover and park and H.flat(rover.PrimaryPart.CFrame.Position, park.CFrame.Position) < 1,
        "RoverFleet: 로버는 주차판 위"
    )
    local drives, steers = 0, 0
    for _, d in rover:GetDescendants() do
        if d:IsA("HingeConstraint") then
            if d:GetAttribute("RoverRole") == "Drive" then
                drives += 1
            elseif d:GetAttribute("RoverRole") == "Steer" then
                steers += 1
            end
        end
    end
    check(drives == 4 and steers == 2, "RoverRig: 구동 힌지 4, 조향 2")
    local console = M.Interactions.prompt("console")
    check(
        console and console:GetAttribute("OpenUI") == "console",
        "콘솔 프롬프트 Attribute OpenUI = console"
    )
    local doors = M.AirlockDoors.counts()
    check(
        doors == 2,
        "AirlockDoors: 착륙선과 에어록 문 2개에 프롬프트 (" .. tostring(doors) .. ")"
    )
    local state = H.state()
    check(
        state and state.phase == "selecting" and state.missionId == nil,
        "StateUpdate: selecting, missionId 없음"
    )
end

-- 1판: 솔로 --------------------------------------------------------------
print("[1판 솔로: 미션 선택]")
local ana = makePlayer("Ana", 101)
moveTo(ana, Vector3.new(180, 2, -542))
join(ana)
do
    local open = R.last("MissionSelectOpen", ana)
    local payload = open and open.args[1]
    check(
        payload and payload.chooserUserId == 101 and payload.chooserName == "Ana",
        "MissionSelectOpen: 첫 입장자가 권한자"
    )
    local states = {}
    for _, m in (payload and payload.missions) or {} do
        states[m.id] = m.state
    end
    check(
        states.A == "locked"
            and states.B == "soon"
            and states.C == "playable"
            and states.D == "locked",
        "MissionSelectOpen: A 잠김, B 곧 열림, C 플레이, D 잠김"
    )
    check(
        payload and payload.defaultMissionId == "C" and type(payload.deadline) == "number",
        "MissionSelectOpen: 기본 C, 마감 시각"
    )
    check(payload and type(payload.bestMedals) == "table", "MissionSelectOpen: bestMedals 표")
    local oxygen = R.last("OxygenUpdate", ana)
    check(
        oxygen
            and oxygen.args[1] == 100
            and oxygen.args[2] == 100
            and type(oxygen.args[3]) == "string",
        "OxygenUpdate: (oxygen, max, zone)"
    )
    check(ana:GetAttribute("Lang") == "en", "PlayerPrefs: 기본 언어 en")
    local mark = R.mark()
    H.fire("SelectMission", ana, "B")
    check(
        R.notified(mark, "toast.mission.not_ready", ana) ~= nil,
        "SelectMission B: 준비 중 알림"
    )
    check(M.MissionFlow.getPhase() == "selecting", "SelectMission B: 그대로 selecting")
    M.MissionFlow.setNextWindow("2022-08-12")
    moveTo(ana, H.landerInside())
    H.fire("SelectMission", ana, "C")
    check(M.MissionFlow.getPhase() == "landing", "SelectMission C: landing")
    local landing = R.last("LandingSequence")
    check(
        landing
            and landing.args[1] == "C"
            and typeof(landing.args[2]) == "CFrame"
            and type(landing.args[3]) == "number",
        "LandingSequence(missionId, landerCFrame, seconds)"
    )
    local r = H.rules()
    check(r and r.missionId == "C" and r.players == 1, "Rules.newState: C, 1명")
    check(
        r and r.sites[1].id == "Ice4" and r.sites[5].id == "Ice5",
        "얼음 순서: BaseExit 실측 거리 (Ice4 가장 가까움, Ice5 가장 멂)"
    )
    check(r and r.weather.id == "2022-08-12", "우주 기상 구간: setNextWindow")
    local s = H.state()
    check(s and s.mode == "solo" and s.phase == "landing", "StateUpdate: mode solo")
    advance(5.1)
    check(M.MissionFlow.getPhase() == "playing", "착륙 연출 뒤 playing")
    s = H.state()
    check(
        s and s.day == 1 and s.totalDays == 60 and s.cap == 100,
        "StateUpdate: day 1 / 60, cap 100"
    )
    check(
        s
            and s.resources.energy == M.MissionConfig.MISSIONS.C.start.energy
            and s.resources.water == M.MissionConfig.MISSIONS.C.start.water
            and s.resources.food == M.MissionConfig.MISSIONS.C.start.food,
        "StateUpdate: 시작 자원 = MissionConfig ("
            .. (s and serde.encode("json", s.resources) or "nil")
            .. ")"
    )
    check(s and type(s.dayEndsAt) == "number", "StateUpdate: dayEndsAt")
    check(s and s.mission.key == "mission.step.airlock", "미션 문구: 에어록 점검")
    check(
        s and #s.ice == 5 and s.ice[1].markerName == "Ice4" and s.ice[1].fsdDays == 1,
        "ice[1]: Ice4, 왕복 1일"
    )
    check(
        s and H.near(s.ice[1].x, 328, 0.5) and H.near(s.ice[1].z, -232, 0.5),
        "ice[i].x, z (StreamingEnabled 대비 MinePoint 좌표)"
    )
    check(
        s
            and s.mapPoints
            and H.near(s.mapPoints.Lander.x, 188.3, 0.05)
            and H.near(s.mapPoints.BaseExit.z, -416, 0.05)
            and s.mapPoints.WaterTank ~= nil
            and s.mapPoints.FarmPad ~= nil,
        "mapPoints (Lander, BaseExit, RoverPark, Airlock, SolarField, FarmPad, WaterTank)"
    )
    check(
        s and type(s.rover.x) == "number" and type(s.rover.z) == "number",
        "rover.x, z (보이는 로버)"
    )
    check(
        s
            and s.ice[1].rushDays ~= nil
            and s.ice[1].rushEnergy ~= nil
            and s.ice[5].rushRisk == "extreme",
        "ice: 서둘러 가기 미리보기 (먼 곳은 extreme)"
    )
    check(
        s and s.facilities.farm and s.facilities.farm.status == "available",
        "facilities.farm available"
    )
    check(
        s
            and s.facilities.pipe
            and s.facilities.pipe.status == "locked"
            and s.facilities.pipe.unlockMsg.key == "toast.pipe.locked",
        "facilities.pipe locked + unlockMsg"
    )
    check(
        s
            and s.facilities.hydroponics.status == "locked"
            and s.facilities.hydroponics.unlockMsg.key == "toast.build.need_prereq",
        "facilities.hydroponics locked (선행 조건)"
    )
    check(
        s and s.airlock.status == "idle" and s.rover.state == "parked",
        "airlock idle, rover parked"
    )
end

print("[1판 솔로: 에어록, 패널, 파견]")
do
    local airlockPrompt = M.Interactions.prompt("airlock")
    check(
        airlockPrompt
            and airlockPrompt.Enabled
            and airlockPrompt.ActionText == ""
            and airlockPrompt.ObjectText == ""
            and airlockPrompt:GetAttribute("ActionKey") == "prompt.act.inspect"
            and airlockPrompt:GetAttribute("ObjectKey") == "facility.airlock.name",
        "에어록 프롬프트: Attribute 키만 (문장 없음)"
    )
    local mark = R.mark()
    H.trigger(airlockPrompt, ana)
    check(
        H.rules().facilities.airlock and H.rules().facilities.airlock.status == "building",
        "에어록 점검 시작 (building)"
    )
    check(R.notified(mark, "toast.build.started") ~= nil, "알림 toast.build.started")
    check(M.MissionWorld.getAirlockStatus() == "inspecting", "MissionWorld 에어록 inspecting")
    check(H.state().airlock.status == "inspecting", "StateUpdate airlock inspecting")
    local panel = M.Interactions.prompt("installPad")
    check(
        panel
            and panel.HoldDuration == 3
            and panel:GetAttribute("ActionKey") == "prompt.act.install_panel",
        "패널 프롬프트 홀드 3초"
    )
    H.trigger(panel, ana)
    H.trigger(panel, ana)
    mark = R.mark()
    H.trigger(panel, ana)
    check(H.rules().panels == 2, "패널 2장")
    check(
        R.notified(mark, "toast.panel.limit_today", ana) ~= nil,
        "3장째: 하루 한도 알림 (그 플레이어)"
    )
    local panels = Workspace.MissionRuntime.Base.SolarField:FindFirstChild("Panels")
    check(
        panels ~= nil and #panels:GetChildren() == 2,
        "패널 월드 반영 (MissionWorld.setPanelCount 2장)"
    )
    -- 콘솔에서 멀리
    moveTo(ana, H.outsidePoint())
    mark = R.mark()
    H.fire("DispatchRover", ana, 1, false)
    check(
        R.notified(mark, "toast.console.too_far", ana) ~= nil,
        "파견: 콘솔에서 멀면 거절"
    )
    moveTo(ana, H.landerInside())
    mark = R.mark()
    H.fire("DispatchRover", ana, 1, false)
    check(H.rules().rover.status == "fsd", "파견: Rules rover fsd")
    check(R.notified(mark, "toast.rover.dispatched") ~= nil, "알림 toast.rover.dispatched")
    local rover = M.RoverFleet.model()
    check(rover and rover.Parent ~= nil, "파견 직후: 출구로 달려가는 중 (보임)")
    advance(4.5)
    check(rover and rover.Parent == nil, "출구 뒤 숨김 (Parent = nil)")
    local s = H.state()
    check(
        s.rover.state == "fsd"
            and s.rover.fsd
            and s.rover.fsd.siteIndex == 1
            and s.rover.fsd.phase == "out",
        "StateUpdate rover.fsd"
    )
    mark = R.mark()
    H.fire("DispatchRover", ana, 2, false)
    check(R.notified(mark, "toast.rover.busy", ana) ~= nil, "두 번째 파견: 로버 바쁨")
end

print("[1판 솔로: 귀환, 재배 공간]")
do
    local before = H.rules().water
    H.day()
    local r = H.rules()
    check(r.day == 2, "DayTick: day 2")
    local status = r.rover.status
    if status == "broken" then
        H.fire("RemoteRecoverRover", ana)
        H.day()
        r = H.rules()
    end
    check(
        r.rover.status == "parked" and r.deliveries >= 1,
        "자율주행 귀환: parked, 하역 1회"
    )
    check(status == "broken" or r.water > before - 10, "귀환 물 반영")
    local rover = M.RoverFleet.model()
    local dock = M.MissionWorld.anchor("roverDock")
    check(
        rover
            and rover.Parent ~= nil
            and dock
            and H.flat(rover.PrimaryPart.CFrame.Position, dock.CFrame.Position) < 1,
        "귀환: 물탱크 옆 귀환 자리에 다시 보임"
    )
    local s = H.state()
    check(
        type(s.net.energy) == "number" and s.rover.state == "parked",
        "StateUpdate net, rover parked"
    )
    local farm = M.Interactions.prompt("farm")
    check(
        farm and farm.Enabled and farm:GetAttribute("ActionKey") == "prompt.act.build",
        "재배 공간 착공 프롬프트"
    )
    local args = farm and farm:GetAttribute("ActionArgs")
    check(
        type(args) == "string" and string.find(args, "facility.farm.name", 1, true) ~= nil,
        "ActionArgs JSON: 중첩 facility Msg"
    )
    H.trigger(farm, ana)
    check(
        H.rules().facilities.farm and H.rules().facilities.farm.status == "building",
        "재배 공간 building"
    )
    check(not farm.Enabled, "착공 뒤 재배 공간 프롬프트 꺼짐")
    check(
        Workspace.MissionRuntime.Facilities:FindFirstChild("farm") ~= nil,
        "MissionWorld: 재배 공간 배치 (솟아오름)"
    )
    check(
        H.state().facilities.farm.status == "building" and H.state().facilities.farm.daysLeft == 3,
        "StateUpdate farm building 3일"
    )
    H.day()
    check(H.rules().facilities.airlock.status == "active", "에어록 가동 (2일)")
    check(
        M.MissionWorld.getAirlockStatus() == "active",
        "MissionWorld 에어록 active (refill 구역)"
    )
    local airlockPrompt = M.Interactions.prompt("airlock")
    check(
        airlockPrompt:GetAttribute("ActionKey") == "prompt.act.pause",
        "가동 뒤 에어록 제어반: 멈춤"
    )
    local mark = R.mark()
    H.trigger(airlockPrompt, ana)
    check(
        H.rules().facilities.airlock.paused == true and R.notified(mark, "toast.pause.on") ~= nil,
        "에어록 멈춤 + 모두에게 알림"
    )
    check(airlockPrompt:GetAttribute("ActionKey") == "prompt.act.resume", "멈춘 뒤: 재개")
    H.fire("SetFacilityPaused", ana, "airlock", false)
    check(H.rules().facilities.airlock.paused == false, "SetFacilityPaused(콘솔 근처): 재개")
    H.day()
    H.day()
    check(
        H.rules().day == 5 and H.rules().facilities.farm.status == "active",
        "재배 공간 가동 (day 5)"
    )
    local farmState = H.state()
    check(
        farmState.facilities.farm.status == "active"
            and type(farmState.facilities.farm.nextHarvestIn) == "number",
        "farm nextHarvestIn"
    )
    check(type(farmState.facilities.farm.upkeep.energy) == "number", "facilities upkeep 숫자")
    check(
        M.Interactions.panelPrompt("farm") ~= nil,
        "재배 공간 외벽 제어반 멈춤 프롬프트"
    )
end

print("[1판 솔로: GST, 업그레이드, 파이프]")
do
    local mark = R.mark()
    H.day()
    check(H.rules().day == 6, "day 6")
    local sw = R.since(mark, "SpaceWeather")
    check(
        sw
            and sw.args[1].kind == "GST"
            and sw.args[1].stage == "active"
            and sw.args[1].sourceDate.year == 2022,
        "SpaceWeather GST active + 실제 날짜"
    )
    check(
        H.state().weather and H.state().weather.kind == "GST" and H.state().weather.banner ~= nil,
        "StateUpdate.weather GST + banner"
    )
    mark = R.mark()
    H.fire("DispatchRover", ana, 2, false)
    check(R.notified(mark, "toast.map.offline_gst", ana) ~= nil, "GST: 파견 거절")
    mark = R.mark()
    H.fire("SetPin", ana, 2)
    check(R.notified(mark, "toast.map.offline_gst", ana) ~= nil, "GST: 핀 거절")
    H.topUp({ energy = 100, water = 100 })
    local led = M.Interactions.prompt("upgrade_led")
    local nutrient = M.Interactions.prompt("upgrade_nutrient")
    check(
        led and led.Enabled and nutrient and nutrient.Enabled,
        "업그레이드 착공 자리 켜짐"
    )
    H.trigger(led, ana)
    H.topUp({ energy = 100, water = 100 })
    H.trigger(nutrient, ana)
    check(H.rules().facilities.led and H.rules().facilities.nutrient, "LED, 영양분 착공")
    H.day()
    check(H.rules().day == 7 and H.rules().facilities.led.status == "active", "LED 가동")
    local ledParts = M.MissionWorld.upgradeParts("led")
    local ledVisible = #ledParts > 0
    for _, part in ledParts do
        if part.Transparency >= 1 then
            ledVisible = false
        end
    end
    check(
        ledVisible,
        "LED 가동: 그린하우스 LED 바 보임 (MissionWorld 업그레이드 표시)"
    )
    -- 파이프: 하역 5회 (테스트 단축) -> 콘솔 SetPipeSite -> 물탱크 옆 착공
    local pipe = M.Interactions.prompt("pipe")
    check(pipe and not pipe.Enabled, "파이프 잠김: 착공 프롬프트 꺼짐")
    H.topUp({ deliveries = 5, energy = 100, water = 100 })
    check(
        pipe.Enabled and pipe:GetAttribute("ActionKey") == "prompt.act.pick_pipe_site",
        "해금 뒤: 콘솔에서 고르기"
    )
    mark = R.mark()
    H.trigger(pipe, ana)
    check(R.notified(mark, "toast.pipe.pick_site", ana) ~= nil, "고르기 전 누르면 안내")
    local target = 2
    if H.rules().sites[target].cooldownLeft > 0 then
        target = 3
    end
    mark = R.mark()
    H.fire("SetPipeSite", ana, target)
    local siteSet = R.notified(mark, "toast.pipe.site_set")
    check(
        siteSet
            and siteSet.args[1].args.site.key == "map.ice.label"
            and siteSet.args[1].args.site.args.n == target,
        "toast.pipe.site_set: site = 중첩 map.ice.label { n }"
    )
    check(H.state().pipeSite == target, "SetPipeSite: MissionState.pipeSite")
    check(pipe:GetAttribute("ActionKey") == "prompt.act.build", "파이프 착공 프롬프트")
    H.trigger(pipe, ana)
    local p = H.rules().facilities.pipe
    check(
        p and p.status == "building" and p.siteIndex == target,
        "파이프 building, 얼음 후보지 연결"
    )
    check(H.state().facilities.pipe.siteIndex == target, "facilities.pipe.siteIndex")
    check(
        Workspace.MissionRuntime.Facilities:FindFirstChild("pipe") ~= nil,
        "MissionWorld: 파이프 배치"
    )
    for _ = 1, 5 do
        H.day()
    end
    check(H.rules().facilities.pipe.status == "active", "파이프 가동 (5일)")
    local icePrompt = M.Interactions.icePrompt(target)
    check(
        icePrompt and icePrompt:GetAttribute("ActionKey") == "prompt.act.ice_piped",
        "파이프 연결 얼음 후보지 프롬프트"
    )
end

print("[1판 솔로: 자율주행 고장, 걸어서 수리, 원격 회수]")
do
    -- 확률 파손은 시드에 따라 나오지 않으므로 Rules 상태를 고장으로 바꿔 서버 반응을 본다
    local function breakRover(distance)
        local s = M.Rules.copy(H.rules())
        s.rover.status = "broken"
        s.rover.damage = 3
        s.rover.brokenDistance = distance
        s.rover.trip = {
            siteIndex = 1,
            totalDays = 2,
            elapsed = 1,
            rush = false,
            risk = "low",
            collected = true,
            carrying = 30,
            damageAt = nil,
            position = 0.6,
        }
        s.energy = 90
        M.MissionFlow.flow.commit(s)
        advance(0)
    end
    breakRover(100)
    local rover = M.RoverFleet.model()
    local exitFrame = M.MissionWorld.exitCFrame()
    check(
        rover.Parent ~= nil
            and H.near(H.flat(rover.PrimaryPart.CFrame.Position, exitFrame.Position), 100, 1),
        "고장: 출구에서 얼음 후보지 쪽 100 stud에 멈춰 보임"
    )
    local s = H.state()
    check(
        s.rover.state == "broken"
            and s.rover.broken.siteIndex == 1
            and s.rover.broken.walkable == true,
        "StateUpdate rover.broken { siteIndex, walkable }"
    )
    local repair = rover.PrimaryPart:FindFirstChild("RepairPrompt")
    check(repair and repair.Enabled, "고장 로버: 수리 프롬프트")
    check(
        not rover.PrimaryPart:FindFirstChild("BoardPrompt").Enabled,
        "고장 로버: 탑승 꺼짐"
    )
    moveTo(ana, rover.PrimaryPart.CFrame.Position + Vector3.new(4, 0, 0))
    local fieldSpot = rover.PrimaryPart.CFrame.Position
    local mark = R.mark()
    H.trigger(repair, ana)
    local r = H.rules()
    check(
        r.rover.status == "parked" and r.rover.trip == nil and r.rover.damage == 0,
        "걸어서 수리: 자율주행 끝, 직접 운전으로"
    )
    check(
        rover.Parent ~= nil and H.flat(rover.PrimaryPart.CFrame.Position, fieldSpot) < 1,
        "고친 자리에 로버가 남는다"
    )
    check(not rover.PrimaryPart.Anchored, "직접 운전: 물리 켜짐")
    check(
        M.RoverFleet.seat().Occupant == humanoidOf(ana),
        "고친 대원은 운전석에 (좌석 산소 회복)"
    )
    check(
        R.notified(mark, "toast.rover.repaired_drive_back", ana) ~= nil,
        "알림 toast.rover.repaired_drive_back"
    )
    check(M.RoverFleet.tankAmount() == 30, "이미 캔 물은 로버 탱크에")
    advance(0.5)
    check(
        M.OxygenV2.zoneOf(ana) == "refill" and H.state().rover.state == "driving",
        "좌석 refill, rover.state driving"
    )
    local unloadPoint = M.MissionWorld.anchor("unloadPoint")
    rover:PivotTo(CFrame.new(unloadPoint.CFrame.Position + Vector3.new(0, 3, 0)))
    advance(0.3)
    local deliveries = H.rules().deliveries
    H.trigger(M.Interactions.prompt("unload"), ana)
    check(
        H.rules().deliveries == deliveries + 1 and M.RoverFleet.tankAmount() == 0,
        "몰고 와서 하역"
    )
    H.unseat(ana)
    moveTo(ana, H.landerInside())
    breakRover(700)
    check(H.state().rover.broken.walkable == false, "멀리 고장: 걸어서 수리 불가 표시")
    H.fire("RemoteRecoverRover", ana)
    check(
        H.rules().rover.status == "fsd" and H.rules().rover.recovering == true,
        "원격 회수 시작"
    )
    check(
        rover.Parent == nil and H.state().rover.fsd.recovering == true,
        "회수 중: 숨김, rover.fsd.recovering"
    )
    H.day()
    check(H.rules().rover.status == "parked", "원격 회수 1일 뒤 귀환")
    check(H.rules().rover.damage == 3, "원격 회수는 파손을 고치지 않는다")
    local repairAtBase = rover.PrimaryPart:FindFirstChild("RepairPrompt")
    moveTo(ana, rover.PrimaryPart.CFrame.Position + Vector3.new(4, 0, 0))
    H.trigger(repairAtBase, ana)
    check(H.rules().rover.damage == 0, "기지에서 R 수리")
    moveTo(ana, H.landerInside())
end

print("[1판 솔로: SEP 경보, 대피, 문 잠금]")
do
    while H.rules().day < 15 do
        H.topUp({ water = 90, food = 90, energy = 90 })
        H.day()
    end
    check(H.rules().day == 15, "day 15 (내일 SEP)")
    check(
        H.state().weather == nil or H.state().weather.stage ~= "warning",
        "경보 전: StateUpdate에 warning 없음"
    )
    -- 로버 옆 야외에 선다
    local rover = M.RoverFleet.model()
    moveTo(ana, rover.PrimaryPart.CFrame.Position + Vector3.new(6, 0, 0))
    local mark = R.mark()
    advance(15.5)
    local sw = R.since(mark, "SpaceWeather")
    check(
        sw and sw.args[1].kind == "SEP" and sw.args[1].stage == "warning" and sw.args[1].day == 16,
        "SEP 15초 전 경보"
    )
    check(
        H.state().weather and H.state().weather.stage == "warning",
        "경보 뒤: StateUpdate weather warning"
    )
    check(
        R.notified(mark, "banner.sep.warning") == nil,
        "경보는 토스트로 겹쳐 보내지 않는다"
    )
    mark = R.mark()
    H.day()
    check(H.rules().day == 16, "day 16 SEP")
    sw = R.since(mark, "SpaceWeather")
    check(
        sw and sw.args[1].stage == "active" and sw.args[1].kind == "SEP",
        "SpaceWeather SEP active"
    )
    local seat = M.RoverFleet.seat()
    check(
        seat and seat.Occupant == humanoidOf(ana),
        "SEP: 로버 옆 대원은 운전석에 자동 탑승"
    )
    check(R.notified(mark, "toast.sep.shelter_rover", ana) ~= nil, "알림 toast.sep.shelter_rover")
    check(M.AirlockDoors.isLocked(), "SEP: 문 잠금")
    local door = Workspace.MissionRuntime.Base.LanderShelter.Entry.Door:FindFirstChild("DoorPrompt")
    check(
        door and door:GetAttribute("ActionKey") == "prompt.act.door_locked",
        "문 프롬프트: 잠김 키"
    )
    mark = R.mark()
    H.trigger(door, ana)
    check(
        R.notified(mark, "toast.outdoor.locked_sep", ana) ~= nil,
        "잠긴 문: 밖에 못 나감 알림"
    )
    mark = R.mark()
    H.trigger(M.Interactions.prompt("installPad"), ana)
    check(
        R.notified(mark, "toast.outdoor.locked_sep", ana) ~= nil,
        "SEP: 패널 설치 거절 (Rules)"
    )
    check(
        H.state().weather.kind == "SEP" and H.state().weather.stage == "active",
        "StateUpdate weather SEP active"
    )
    mark = R.mark()
    H.day()
    sw = R.since(mark, "SpaceWeather")
    check(sw and sw.args[1].stage == "ended", "SEP ended")
    check(not M.AirlockDoors.isLocked(), "SEP 끝: 문 열림")
    H.unseat(ana)
    check(seat.Occupant == nil, "하차")
end

print("[1판 솔로: 산소 구조]")
do
    moveTo(ana, H.outsidePoint())
    advance(0.5)
    local _, zone = M.OxygenV2.get(ana)
    check(zone == "outside", "야외 구역 outside")
    M.OxygenV2.set(ana, 0.3)
    local mark = R.mark()
    advance(0.6)
    check(H.rules().oxygenRescues == 1, "산소 0: Rules.recordOxygenRescue")
    check(R.notified(mark, "toast.oxygen.rescued", ana) ~= nil, "구조 알림 (그 플레이어)")
    local oxygen, zone2 = M.OxygenV2.get(ana)
    check(
        oxygen and oxygen > 90 and zone2 ~= "outside",
        "구조: 에어록 안, 산소 다시 채움"
    )
    local update = R.last("OxygenUpdate", ana)
    check(
        update and (update.args[3] == "refill" or update.args[3] == "shelter"),
        "OxygenUpdate zone refill/shelter"
    )
end

print("[1판 솔로: 수경 재배 -> 금메달]")
do
    moveTo(ana, H.landerInside())
    H.topUp({ energy = 100, water = 100, food = 90 })
    local hydro = M.Interactions.prompt("upgrade_hydroponics")
    check(hydro and hydro.Enabled, "수경 재배 착공 자리")
    H.trigger(hydro, ana)
    check(
        H.rules().facilities.hydroponics and H.rules().facilities.hydroponics.status == "building",
        "수경 재배 building"
    )
    local mark = R.mark()
    H.day()
    check(M.MissionFlow.getPhase() == "result", "금메달 조건 -> 즉시 result")
    local over = R.since(mark, "GameOver")
    local result = over and over.args[1]
    check(result and result.won == true and result.medal == "gold", "GameOver: won, gold")
    check(
        result
            and result.reason.key == "result.medal.earned"
            and result.reason.args.medal.key == "medal.gold.name",
        "reason Msg"
    )
    check(result and result.missionId == "C" and result.mode == "solo", "GameOver missionId, mode")
    check(result and type(result.score) == "number" and result.score <= 1000, "GameOver score")
    local dedOk = result and type(result.deductions) == "table"
    for _, d in (result and result.deductions) or {} do
        if
            type(d.reason) ~= "string"
            or type(d.count) ~= "number"
            or type(d.points) ~= "number"
            or type(d.msg) ~= "table"
        then
            dedOk = false
        end
    end
    check(dedOk, "deductions: { reason, count, points, msg }")
    local rescue = false
    for _, d in (result and result.deductions) or {} do
        if d.reason == "oxygen_rescue" and d.points == 100 then
            rescue = true
        end
    end
    check(rescue, "산소 구조 감점 100")
    check(
        result
            and result.weather.windowId == "2022-08-12"
            and result.weather.sep == 3
            and result.weather.gst == 3
            and result.weather.startDate.year == 2022,
        "GameOver weather 요약 (SEP 3, GST 3)"
    )
    local row = result and result.crew[1]
    check(
        row
            and row.name == "Ana"
            and row.role == "solo"
            and row.panels == 2
            and row.builds >= 6
            and row.rescues == 1,
        "crew: 역할 solo, 기여"
    )
    check(
        result and result.chooserUserId == 101 and type(result.restartAvailableAt) == "number",
        "restartAvailableAt, chooserUserId"
    )
    advance(2)
    local records = R.last("Records", ana)
    local payload = records and records.args[1]
    check(
        payload
            and payload.submitted == true
            and payload.status == "offline"
            and payload.mission.rank == 1,
        "Records: 메모리 저장(offline), 이번 판 1위"
    )
    check(
        payload
            and payload.mission.entries[1].medal == "gold"
            and payload.mission.entries[1].crew[1] == "Ana"
            and payload.mission.entries[1].mode == "solo",
        "Records mission.entries"
    )
    check(
        payload and payload.global.rank == 1 and payload.global.mine.goldMissions == 1,
        "Records global.rank, mine"
    )
    check(H.state().phase == "result", "StateUpdate phase result")
end

print("[1판 솔로: 재시작]")
do
    local mark = R.mark()
    H.fire("RequestRestart", ana)
    check(R.notified(mark, "toast.restart.too_soon", ana) ~= nil, "재시작: 너무 이름")
    advance(10)
    H.fire("RequestRestart", ana)
    check(M.MissionFlow.getPhase() == "selecting", "재시작 -> selecting")
    local open = R.last("MissionSelectOpen", ana)
    check(open and open.args[1].bestMedals.C == "gold", "MissionSelectOpen bestMedals C = gold")
    local rover = M.RoverFleet.model()
    check(rover and rover.Parent == Workspace.MissionRuntime, "재시작: 로버 다시 만듦")
    check(
        M.Interactions.prompt("airlock") ~= nil and M.MissionWorld.getAirlockStatus() == "idle",
        "재시작: 프롬프트 다시 붙음, 에어록 idle"
    )
    check(
        Workspace.MissionRuntime.Facilities:FindFirstChild("farm") == nil,
        "재시작: 시설 지움"
    )
end

-- 2판: 멀티 --------------------------------------------------------------
print("[2판 멀티: 역할, 핀]")
local ben = makePlayer("Ben", 202)
moveTo(ben, H.landerInside())
join(ben)
do
    local mark = R.mark()
    H.fire("SelectMission", ben, "C")
    check(
        R.notified(mark, "mission_select.chooser", ben) ~= nil,
        "권한자 아닌 사람의 선택: 안내"
    )
    M.MissionFlow.setNextWindow("2022-08-12")
    H.fire("SelectMission", ana, "C")
    local s = H.state()
    check(s.mode == "multi" and s.players == 2, "2명 확정: multi")
    local roleUpdate = R.last("RoleUpdate")
    check(
        roleUpdate and roleUpdate.args[2] == true and type(roleUpdate.args[3]) == "number",
        "RoleUpdate(roles, selecting, deadline)"
    )
    H.fire("ChooseRole", ben, "controller")
    mark = R.mark()
    H.fire("ChooseRole", ana, "controller")
    check(R.notified(mark, "toast.role.full", ana) ~= nil, "관제사 자리 참: 거절")
    advance(10.2)
    check(M.MissionFlow.getPhase() == "playing", "역할 선택 10초 뒤 playing")
    local roles = R.last("RoleUpdate").args[1]
    check(
        roles["202"] == "controller" and roles["101"] == "explorer",
        "역할: Ben 관제사, Ana 자동 탐사대원 (문자열 userId 키)"
    )
    check(R.last("RoleUpdate").args[2] == false, "선택 끝: selecting false")
    mark = R.mark()
    H.fire("SetPin", ana, 2)
    check(R.notified(mark, "toast.map.controller_only", ana) ~= nil, "탐사대원 핀: 거절")
    H.fire("SetPin", ben, 2)
    local pin = R.last("PinUpdate")
    check(
        pin and pin.args[1].siteIndex == 2 and pin.args[1].byUserId == 202,
        "PinUpdate { siteIndex, byUserId }"
    )
    mark = R.mark()
    H.fire("DispatchRover", ana, 1, false)
    check(
        R.notified(mark, "toast.rover.solo_only", ana) ~= nil,
        "멀티 파견: 직접 운전 안내"
    )
end

print("[2판 멀티: 직접 운전 채취와 하역]")
do
    local rover = M.RoverFleet.model()
    moveTo(ana, rover.PrimaryPart.CFrame.Position + Vector3.new(4, 0, 0))
    local board = rover.PrimaryPart:FindFirstChild("BoardPrompt")
    check(
        board and board.Enabled and board:GetAttribute("ActionKey") == "prompt.act.board",
        "탑승 프롬프트"
    )
    local mark = R.mark()
    H.trigger(board, ana)
    local seat = M.RoverFleet.seat()
    check(seat and seat.Occupant == humanoidOf(ana), "탑승")
    check(
        R.notified(0, "toast.rover.first_board", ana) ~= nil,
        "첫 탑승 안내 (이 서버에서 한 번)"
    )
    advance(0.3)
    check(H.state().rover.state == "driving", "rover.state driving")
    -- 급정거 충돌: Terrain처럼 태그 없는 것에 세게 부딪혀 수평 속도가 0.25초 안에 절반 아래로 떨어지면 1회
    do
        local chassis = rover.PrimaryPart
        local heartbeat = signalFor(dm:GetService("RunService"), "Heartbeat")
        local function setVelocity(v)
            pcall(function()
                chassis.AssemblyLinearVelocity = v
            end)
            chassis:SetAttribute("__alv", v)
        end
        local function sample(v)
            setVelocity(v)
            heartbeat:Fire(1 / 60)
            advance(0.05)
        end
        advance(1.2)
        local damage0 = H.rules().rover.damage
        local hitMark = R.mark()
        sample(Vector3.new(15, 0, 0))
        sample(Vector3.new(16, 0, 2))
        signalFor(chassis, "Touched"):Fire(terrainInstance)
        advance(0)
        check(
            H.rules().rover.damage == damage0,
            "Terrain Touched만으로는 세지 않는다 (태그 없음)"
        )
        sample(Vector3.new(3, 0, 0))
        sample(Vector3.new(0.5, 0, 0))
        sample(Vector3.new(0, 0, 0))
        local hits = 0
        for i = hitMark + 1, #sent do
            if sent[i].name == "Notify" and sent[i].args[1].key == "toast.rover.damaged" then
                hits += 1
            end
        end
        check(
            H.rules().rover.damage == damage0 + 1 and hits == 1,
            "급정거(16 -> 3, 0.05초): 파손 1회, 알림 1회"
        )
        local rock = Instance.new("Part")
        rock.Name = "Rock"
        rock:AddTag("RoverHazard")
        rock.Parent = Workspace
        setVelocity(Vector3.new(14, 0, 0))
        signalFor(chassis, "Touched"):Fire(rock)
        advance(0)
        check(
            H.rules().rover.damage == damage0 + 1,
            "같은 충돌의 태그 바위 신호는 1초 안이면 한 번으로"
        )
        advance(1.2)
        sample(Vector3.new(8, 0, 0))
        sample(Vector3.new(1, 0, 0))
        check(H.rules().rover.damage == damage0 + 1, "느리게(8) 서면 충돌 아님")
        sample(Vector3.new(14, 0, 0))
        sample(Vector3.new(10, 0, 0))
        check(H.rules().rover.damage == damage0 + 1, "절반 위로 줄면(14 -> 10) 충돌 아님")
        setVelocity(Vector3.new(14, 0, 0))
        signalFor(chassis, "Touched"):Fire(rock)
        advance(0)
        check(
            H.rules().rover.damage == damage0 + 2,
            "RoverHazard 태그 파트에 세게 부딪히면 따로 센다"
        )
        rock:Destroy()
        setVelocity(Vector3.zero)
        local fixed = M.Rules.copy(H.rules())
        fixed.rover.damage = 0
        M.MissionFlow.flow.commit(fixed)
        advance(1.2)
    end
    local point = Workspace.MissionRuntime.IceSites:FindFirstChild("Ice4").MinePoint
    rover:PivotTo(CFrame.new(point.CFrame.Position + Vector3.new(3, 2, 0)))
    advance(0.3)
    local icePrompt = M.Interactions.icePrompt(1)
    check(
        icePrompt
            and icePrompt:GetAttribute("ActionKey") == "prompt.act.collect_ice"
            and icePrompt.Enabled,
        "얼음 채취 프롬프트"
    )
    mark = R.mark()
    H.trigger(icePrompt, ben)
    check(
        R.notified(mark, "toast.rover.need_driver", ben) ~= nil,
        "운전석이 아니면 채취 거절"
    )
    mark = R.mark()
    H.trigger(icePrompt, ana)
    check(
        M.RoverFleet.tankAmount() == 30 and H.rules().sites[1].cooldownLeft == 3,
        "채취: 탱크 30, 쿨타임 3일"
    )
    check(
        icePrompt:GetAttribute("ActionKey") == "prompt.act.ice_wait",
        "쿨타임 중 프롬프트 키"
    )
    local args = icePrompt:GetAttribute("ActionArgs")
    check(
        type(args) == "string" and string.find(args, '"count":3', 1, true) ~= nil,
        "쿨타임 ActionArgs count 3"
    )
    mark = R.mark()
    H.trigger(icePrompt, ana)
    check(R.notified(mark, "toast.rover.tank_full", ana) ~= nil, "탱크 가득: 거절")
    local unloadPrompt = M.Interactions.prompt("unload")
    check(unloadPrompt.Enabled, "탱크에 물: 하역 프롬프트 켜짐")
    mark = R.mark()
    H.trigger(unloadPrompt, ben)
    check(
        R.notified(mark, "toast.rover.not_here", ben) ~= nil,
        "로버가 물탱크 옆이 아니면 거절"
    )
    local unloadPoint = M.MissionWorld.anchor("unloadPoint")
    rover:PivotTo(CFrame.new(unloadPoint.CFrame.Position + Vector3.new(0, 3, 0)))
    advance(0.3)
    local deliveries = H.rules().deliveries
    H.trigger(unloadPrompt, ana)
    check(
        H.rules().deliveries == deliveries + 1 and M.RoverFleet.tankAmount() == 0,
        "하역: 하역 횟수 +1, 탱크 0"
    )
    check(H.state().deliveries == deliveries + 1, "StateUpdate deliveries")
    -- 충돌 파손과 수리
    mark = R.mark()
    check(M.RoverFleet.registerHit(20), "바위 충돌: 파손 +1")
    check(
        H.rules().rover.damage == 1 and R.notified(mark, "toast.rover.damaged") ~= nil,
        "Rules 파손 1, 알림"
    )
    H.unseat(ana)
    advance(1.2)
    local repair = rover.PrimaryPart:FindFirstChild("RepairPrompt")
    check(
        repair and repair.Enabled and repair.KeyboardKeyCode == Enum.KeyCode.R,
        "수리 프롬프트 (R)"
    )
    local energy = H.rules().energy
    H.trigger(repair, ana)
    check(
        H.rules().rover.damage == 0 and H.rules().energy < energy,
        "수리: 파손 0, 에너지 사용"
    )
    -- 충돌 3회: 수동 고장 (Rules.applyRoverHit, 왕복 없는 broken). 그 자리에서 R 수리 (Rules.repairRover)
    local spot = rover.PrimaryPart.CFrame.Position
    mark = R.mark()
    for _ = 1, 3 do
        advance(1.1)
        M.RoverFleet.registerHit(20)
    end
    local broken = H.rules().rover
    check(
        broken.status == "broken" and broken.trip == nil and broken.damage == 3,
        "충돌 3회: 수동 고장"
    )
    check(R.notified(mark, "toast.rover.broken_manual") ~= nil, "알림 toast.rover.broken_manual")
    check(
        rover.Parent ~= nil and H.flat(rover.PrimaryPart.CFrame.Position, spot) < 1,
        "수동 고장: 그 자리에 그대로"
    )
    advance(0.3)
    check(
        H.state().rover.state == "broken" and H.state().rover.broken.manual == true,
        "StateUpdate rover.broken.manual"
    )
    check(not M.RoverFleet.registerHit(20), "고장 뒤 충돌은 더 세지 않는다")
    H.trigger(repair, ana)
    check(
        H.rules().rover.status == "parked"
            and H.rules().rover.damage == 0
            and rover.Parent ~= nil
            and H.flat(rover.PrimaryPart.CFrame.Position, spot) < 1,
        "수동 고장 R 수리: 그 자리에서 parked"
    )
    -- 충전: 주차판에 빈 로버
    local park = M.MissionWorld.anchor("roverPark")
    rover:PivotTo(CFrame.new(park.CFrame.Position + Vector3.new(0, 3, 0)))
    H.topUp({ energy = 90 })
    local battery = H.state().rover.battery
    advance(3)
    local s = H.state()
    check(
        s.rover.battery >= battery and s.rover.batteryMax == 50 and s.rover.atBase == true,
        "주차판: 충전 (배터리 <= 50)"
    )
end

print("[2판 멀티: 역할 맞바꾸기, 관제사 이탈, 실패]")
do
    moveTo(ana, H.landerInside())
    local mark = R.mark()
    H.fire("ChooseRole", ana, "controller")
    local roles = R.last("RoleUpdate").args[1]
    check(
        roles["101"] == "controller" and roles["202"] == "explorer",
        "콘솔에서 관제사 맞바꾸기"
    )
    check(R.notified(mark, "toast.role.changed") ~= nil, "역할 변경 알림")
    moveTo(ben, H.outsidePoint())
    mark = R.mark()
    H.fire("ChooseRole", ben, "engineer")
    check(
        R.notified(mark, "toast.role.need_console", ben) ~= nil,
        "콘솔 밖: 역할 변경 거절"
    )
    moveTo(ben, H.landerInside())
    mark = R.mark()
    leave(ana)
    roles = R.last("RoleUpdate").args[1]
    check(roles["202"] == "controller", "관제사 이탈: 자동 이전")
    check(R.notified(mark, "toast.role.changed") ~= nil, "이전 알림")
    check(H.state().chooserUserId == 202, "권한자 이전")
    H.topUp({ water = 0, food = 0 })
    local failMark = R.mark()
    for _ = 1, 6 do
        if M.MissionFlow.getPhase() ~= "playing" then
            break
        end
        H.day()
    end
    check(M.MissionFlow.getPhase() == "result", "물과 식량 0 4일: 실패")
    local result = R.last("GameOver").args[1]
    check(
        result.won == false and result.medal == nil and result.reason.key == "end.lost.both",
        "GameOver lost (end.lost.both)"
    )
    check(
        result.mode == "multi" and result.chooserUserId == 202 and result.players == 2,
        "GameOver multi, 권한자 Ben"
    )
    local roleNames = {}
    for _, row in result.crew do
        roleNames[row.name] = row.role
    end
    check(
        roleNames.Ben == "controller" and roleNames.Ana == "controller",
        "crew 역할 (나간 사람은 마지막 역할)"
    )
    advance(10.5)
    local submittedAgain = false
    for i = failMark + 1, #sent do
        if sent[i].name == "Records" and sent[i].args[1].submitted == true then
            submittedAgain = true
        end
    end
    check(not submittedAgain, "메달 없음: 기록 제출 없음")
    H.fire("RequestRestart", ben)
    check(M.MissionFlow.getPhase() == "selecting", "재시작 -> selecting")
    leave(ben)
    check(
        M.MissionFlow.getPhase() == "selecting" and H.state().chooserUserId == 0,
        "모두 나감: selecting, 권한자 없음"
    )
end

-- 페이로드 검사 ----------------------------------------------------------------
print("[페이로드]")
do
    local bad = {}
    for _, s in sent do
        H.sentences(s.args, s.name, bad)
    end
    check(#bad == 0, "송신 페이로드에 문장 없음 (" .. #bad .. ")")
    for i = 1, math.min(#bad, 10) do
        print("    " .. bad[i])
    end
    local keys = {}
    for _, s in sent do
        H.msgKeys(s.args, keys)
    end
    local unknown = {}
    for key in keys do
        local strings = M.Strings.strings
        if not strings[key] and not strings[key .. ".one"] and not strings[key .. ".other"] then
            table.insert(unknown, key)
        end
    end
    table.sort(unknown)
    check(
        #unknown == 0,
        "보낸 Msg 키가 모두 문구표에 있음 (" .. table.concat(unknown, ", ") .. ")"
    )
    local promptBad = {}
    for _, d in Workspace:GetDescendants() do
        if d:IsA("ProximityPrompt") then
            if
                d.ActionText ~= ""
                or d.ObjectText ~= ""
                or type(d:GetAttribute("ActionKey")) ~= "string"
            then
                table.insert(promptBad, d:GetFullName())
            end
        end
    end
    check(#promptBad == 0, "모든 프롬프트: ActionText, ObjectText 비움, ActionKey 있음")
    local state = nil
    for i = #sent, 1, -1 do
        if sent[i].name == "StateUpdate" and sent[i].args[1].phase == "playing" then
            state = sent[i].args[1]
            break
        end
    end
    local fields = {
        "phase",
        "missionId",
        "mode",
        "day",
        "totalDays",
        "resources",
        "cap",
        "net",
        "daysLeft",
        "lowWarn",
        "panels",
        "airlock",
        "facilities",
        "ice",
        "rover",
        "deliveries",
        "mission",
        "stalled",
        "facilitiesShed",
    }
    local missing = {}
    for _, field in fields do
        if state == nil or state[field] == nil then
            table.insert(missing, field)
        end
    end
    check(
        #missing == 0,
        "MissionState 필드 (CONTRACT_V2 5절) (" .. table.concat(missing, ",") .. ")"
    )
    check(R.count("StateUpdate") > 50, "StateUpdate 여러 번 (" .. R.count("StateUpdate") .. ")")
end

check(threadErrors == 0, "스레드 오류 없음 (" .. threadErrors .. ")")
local seriousWarnings = {}
for _, text in warnings do
    if not string.find(text, "Entry.Door", 1, true) then
        table.insert(seriousWarnings, text)
    end
end
check(#seriousWarnings == 0, "경고 없음 (" .. #seriousWarnings .. ")")

print("")
print(string.format("v2 서버 스모크 결과: 통과 %d, 실패 %d", passes, failures))
if failures > 0 then
    process.exit(1)
end
