-- 서버 통합 스모크 테스트. tests/run.luau가 place를 빌드해 하위 프로세스로 실행한다 (CI 포함)
-- rojo build 결과 place를 Lune로 읽고, Lune에 없는 Roblox API(PivotTo, 이벤트, task 등)를 흉내 내서
-- 부팅 -> 착륙지 선택 -> 착륙 -> 패널 -> 산소 -> 물 -> 건설 A, B, C -> 승리 -> 재시작 -> 실패까지 가상 시계로 돌린다.
-- 물리(로버 주행)와 클라이언트 UI는 검증하지 않는다.
--
-- 단독 실행: rojo build default.project.json -o build/smoke.rbxl && lune run tests/server_smoke.luau build/smoke.rbxl

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local placePath = process.args[1] or "build.rbxl"
local dm = roblox.deserializePlace(fs.readFile(placePath))

local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

local failures = 0
local warnings = {}
local function check(cond, label)
    if cond then
        print("  OK   " .. label)
    else
        failures += 1
        print("  FAIL " .. label)
    end
end

-- 패널 복제본 바닥이 슬롯 x, z를 채우는 비율 (슬롯 좌표계 기준)
local function panelFill(panel, slot)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    for _, d in panel:GetDescendants() do
        if d:IsA("BasePart") then
            local h = d.Size / 2
            for _, sx in { -1, 1 } do
                for _, sy in { -1, 1 } do
                    for _, sz in { -1, 1 } do
                        local p = slot.CFrame:PointToObjectSpace(
                            d.CFrame * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
                        )
                        lo = Vector3.new(
                            math.min(lo.X, p.X),
                            math.min(lo.Y, p.Y),
                            math.min(lo.Z, p.Z)
                        )
                        hi = Vector3.new(
                            math.max(hi.X, p.X),
                            math.max(hi.Y, p.Y),
                            math.max(hi.Z, p.Z)
                        )
                    end
                end
            end
        end
    end
    return (hi.X - lo.X) / slot.Size.X, (hi.Z - lo.Z) / slot.Size.Z
end

-- 점이 파트의 회전된 박스 안인지 (Oxygen의 판정과 같은 계산)
local function insidePart(part, point)
    local p = part.CFrame:PointToObjectSpace(point)
    local h = part.Size / 2
    return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
end

-- 걸어 들어가는 건물 출입 구조 검사: Entry 모델의 문, 프레임, 표지, 충돌 벽, 내부 빛
local function entryOk(building, expectedWalls)
    local entry = building:FindFirstChild("Entry")
    if not entry then
        return false, "Entry 없음"
    end
    local door, frame, sign =
        entry:FindFirstChild("Door"),
        entry:FindFirstChild("DoorFrame"),
        entry:FindFirstChild("DoorSign")
    if not door or not frame or not sign then
        return false, "문, 프레임, 표지 중 없음"
    end
    if not door.CanCollide or frame.CanCollide then
        return false, "닫힌 문은 충돌하고 프레임은 충돌하지 않아야 함"
    end
    if
        math.abs(door.Size.X - 4.5) > 1e-3
        or math.abs(door.Size.Y - 5.5) > 1e-3
        or math.abs(door.Size.Z - 0.4) > 1e-3
    then
        return false, "문 크기 " .. tostring(door.Size)
    end
    if frame.Color == door.Color then
        return false, "프레임 색이 문과 같음"
    end
    local gui = sign:FindFirstChildOfClass("SurfaceGui")
    local label = gui and gui:FindFirstChildOfClass("TextLabel")
    if not label or label.Text ~= "AIRLOCK" then
        return false, "AIRLOCK 표지 없음"
    end
    local walls, left, right = 0, nil, nil
    for _, child in entry:GetChildren() do
        if string.sub(child.Name, 1, 4) == "Wall" then
            walls += 1
            if
                child.Transparency ~= 1
                or not child.CanCollide
                or math.abs(child.Size.Y - 6) > 1e-6
            then
                return false, "벽 설정 " .. child.Name
            end
            if child.Name == "WallFrontLeft" then
                left = child
            elseif child.Name == "WallFrontRight" then
                right = child
            end
        end
    end
    if walls ~= expectedWalls then
        return false, "벽 " .. walls .. "개 (기대 " .. expectedWalls .. ")"
    end
    if not left or not right then
        return false, "정면 벽 조각 없음"
    end
    local gap = (left.CFrame.Position - right.CFrame.Position).Magnitude - left.Size.X
    if math.abs(gap - 5) > 1e-3 then
        return false, string.format("문 폭 비움 %.2f", gap)
    end
    local light = nil
    for _, d in entry:GetDescendants() do
        if d:IsA("PointLight") then
            light = d
        end
    end
    if not light or light.Range ~= 18 or light.Brightness ~= 1 then
        return false, "내부 빛"
    end
    return true, "ok"
end

-- 가상 시계와 task 스케줄러 ---------------------------------------------
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
local function advance(seconds)
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
    function s:Fire(...)
        for _, h in self.handlers do
            if h.connected then
                task.spawn(h.fn, ...)
            end
        end
    end
    return s
end
local signals = {}
local nextId = 0
local function signalFor(inst, name)
    local id = inst:GetAttribute("__sid")
    if not id then
        nextId += 1
        id = nextId
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
local function lastSent(name)
    for i = #sent, 1, -1 do
        if sent[i].name == name then
            return sent[i]
        end
    end
    return nil
end
local function countSent(name)
    local n = 0
    for _, s in sent do
        if s.name == name then
            n += 1
        end
    end
    return n
end

-- 가짜 플레이어 ---------------------------------------------------------
local players = {}
local function makePlayer(name, userId)
    local p = {
        Name = name,
        DisplayName = name,
        UserId = userId,
        Character = nil,
        CharacterAdded = newSignal(),
        CharacterAppearanceLoaded = newSignal(),
    }
    return p
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
roblox.implementMethod("Model", "GetBoundingBox", function(model)
    local minV, maxV = nil, nil
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            local p, h = d.CFrame.Position, d.Size / 2
            local lo, hi = p - h, p + h
            minV = if minV
                then Vector3.new(
                    math.min(minV.X, lo.X),
                    math.min(minV.Y, lo.Y),
                    math.min(minV.Z, lo.Z)
                )
                else lo
            maxV = if maxV
                then Vector3.new(
                    math.max(maxV.X, hi.X),
                    math.max(maxV.Y, hi.Y),
                    math.max(maxV.Z, hi.Z)
                )
                else hi
        end
    end
    return CFrame.new((minV + maxV) / 2), maxV - minV
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
roblox.implementProperty("VehicleSeat", "ThrottleFloat", function()
    return 0
end)
roblox.implementProperty("VehicleSeat", "SteerFloat", function()
    return 0
end)
roblox.implementMethod("VehicleSeat", "GetPropertyChangedSignal", function(inst, prop)
    return signalFor(inst, "Changed:" .. prop)
end)
-- Terrain: FillBlock, FillBall은 호출만 기록 (SetMaterialColor와 GetMaterialColor는 Lune이 구현)
local terrainCalls = {}
roblox.implementMethod("Terrain", "FillBlock", function(_, cframe, size, material)
    table.insert(
        terrainCalls,
        { kind = "block", cframe = cframe, size = size, material = material }
    )
end)
roblox.implementMethod("Terrain", "FillBall", function(_, center, radius, material)
    table.insert(
        terrainCalls,
        { kind = "ball", center = center, radius = radius, material = material }
    )
end)
-- seat:Sit(humanoid): 앉히고 Occupant 변경 신호를 보낸다
roblox.implementMethod("VehicleSeat", "Sit", function(seat, hum)
    seat.Occupant = hum
    hum.SeatPart = seat
    hum.Sit = true
    signalFor(seat, "Changed:Occupant"):Fire()
end)
roblox.implementProperty("Model", "ChildAdded", function(inst)
    return signalFor(inst, "ChildAdded")
end)
roblox.implementProperty("ProximityPrompt", "Triggered", function(inst)
    return signalFor(inst, "Triggered")
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
roblox.implementMethod("Workspace", "Raycast", function()
    return nil -- 지면 탐색은 실패한 것으로 보고 코드의 대체 높이를 쓴다
end)
-- 박스 안에 중심이 있는 파트 목록 (에어락 닫기 판정용 근사. 실제 Roblox는 파트 경계로 판정)
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
roblox.implementMethod("Workspace", "GetServerTimeNow", function()
    return 1700000000 + now
end)
roblox.implementMethod("RunService", "IsServer", function()
    return true
end)
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
local PlayersService = dm:GetService("Players")
roblox.implementProperty("Players", "PlayerAdded", function(inst)
    return signalFor(inst, "PlayerAdded")
end)
roblox.implementProperty("Players", "PlayerRemoving", function(inst)
    return signalFor(inst, "PlayerRemoving")
end)

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

-- DataModel마다 따로 모듈을 불러오는 로더 (warnSink에 warn 출력을 모은다)
-- patch(key, source)가 있으면 모듈 소스를 바꿔 불러온다 (예: DevMap 상수 뒤집기)
local function makeLoader(dataModel, warnSink, patch)
    local cache = {}
    local loadModule
    local function makeEnv(scriptInst)
        return {
            script = scriptInst,
            game = dataModel,
            workspace = dataModel:GetService("Workspace"),
            require = function(target)
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
            },
            warn = function(...)
                local text = table.concat(table.pack(...), " ")
                table.insert(warnSink, text)
                print("WARN " .. text)
            end,
            print = print,
            Instance = Instance,
            Vector3 = Vector3,
            CFrame = CFrame,
            Color3 = roblox.Color3,
            UDim2 = roblox.UDim2,
            Enum = roblox.Enum,
            PhysicalProperties = roblox.PhysicalProperties,
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
        local source = target.Source
        if patch then
            source = patch(key, source)
        end
        local fn = luau.load(
            source,
            { debugName = key, environment = makeEnv(target), injectGlobals = false }
        )
        local result = fn()
        cache[key] = result
        return result
    end
    return loadModule, makeEnv
end
local loadModule, makeEnv = makeLoader(dm, warnings)

local Server = dm:GetService("ServerScriptService"):FindFirstChild("Server")
local Shared = dm:GetService("ReplicatedStorage"):FindFirstChild("Shared")
local Workspace = dm:GetService("Workspace")
local ServerStorage = dm:GetService("ServerStorage")

-- 첫 번째 place: 실제 Roblox처럼 Terrain과 기본 Baseplate가 있다 (두 번째 place에는 없음)
local terrainInstance = Instance.new("Terrain")
terrainInstance.Parent = dm:GetService("Workspace")
local baseplate = Instance.new("Part")
baseplate.Name = "Baseplate"
baseplate.Size = Vector3.new(2048, 16, 2048)
baseplate.CFrame = CFrame.new(0, -8, 0)
baseplate.Parent = dm:GetService("Workspace")
local baseplateTexture = Instance.new("Texture")
baseplateTexture.Parent = baseplate
local atmosphere1 = Instance.new("Atmosphere")
atmosphere1.Density = 0.4
atmosphere1.Haze = 1
atmosphere1.Parent = dm:GetService("Lighting")

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

local Config = loadModule(Shared:FindFirstChild("Config"))
local ResourceState = loadModule(Server:FindFirstChild("ResourceState"))
local function state()
    return ResourceState.get()
end

check(Workspace:FindFirstChild("LandingPads") ~= nil, "DevMap: LandingPads 생성")
check(#Workspace.LandingPads:GetChildren() == 4, "DevMap: 패드 4개")
check(#Workspace.IceSites:GetChildren() == 3, "DevMap: 얼음 3곳")
local kit = ServerStorage:FindFirstChild("BaseKit")
check(
    kit ~= nil and kit.PrimaryPart ~= nil and kit.PrimaryPart.Name == "Origin",
    "BaseKit PrimaryPart = Origin"
)
check(
    kit.Lander:FindFirstChild("SpawnPoint") and kit.Lander:FindFirstChild("OxygenZone"),
    "Lander SpawnPoint, OxygenZone"
)
check(
    kit.Rover:FindFirstChild("DriverSeat") and kit.Rover.DriverSeat.ClassName == "VehicleSeat",
    "Rover.DriverSeat VehicleSeat"
)
check(#kit.SolarField.Slots:GetChildren() == 30, "Slots 30개")
check(kit.ModulePads.PadA:FindFirstChild("OxygenZone") ~= nil, "PadA OxygenZone")
for _, id in { "A", "B", "C" } do
    local pad = kit.ModulePads["Pad" .. id]
    check(
        pad:FindFirstChild("Pad") and pad:FindFirstChild("Ghost") and pad:FindFirstChild("Built"),
        "Pad" .. id .. " Pad/Ghost/Built"
    )
end
check(kit:FindFirstChild("WaterTank") ~= nil, "WaterTank")
check(ServerStorage:FindFirstChild("PanelTemplate") ~= nil, "PanelTemplate")
local hinges, unanchored, anchoredRover = 0, 0, 0
for _, d in kit:GetDescendants() do
    if d:IsA("HingeConstraint") then
        hinges += 1
    end
    if d:IsA("BasePart") then
        local inRover = d:IsDescendantOf(kit.Rover)
        if inRover and d.Anchored then
            anchoredRover += 1
        elseif not inRover and not d.Anchored then
            unanchored += 1
        end
    end
end
check(hinges == 6, "로버 힌지 6개 (구동 4 + 조향 2): " .. hinges)
check(unanchored == 0 and anchoredRover == 0, "로버만 비고정, 나머지 고정")

-- 패드별 최근접 얼음 거리
for i = 1, 4 do
    local pad = Workspace.LandingPads["Pad" .. i]
    local best = math.huge
    for _, ice in Workspace.IceSites:GetChildren() do
        local d = pad.CFrame.Position - ice.CFrame.Position
        best = math.min(best, Vector3.new(d.X, 0, d.Z).Magnitude)
    end
    check(
        math.abs(best - Config.DEV_MAP.iceDistanceBySite[i]) < 1,
        string.format(
            "Pad%d 최근접 얼음 %.0f studs (%s)",
            i,
            best,
            pad:GetAttribute("IceDistanceLabel")
        )
    )
    check(
        pad:GetAttribute("Sunlight") == Config.SITES[i].sunlight,
        "Pad" .. i .. " Sunlight attribute"
    )
end
check(
    #Workspace.DevTerrain.Boulders:GetChildren() > 50,
    "바위 수 " .. #Workspace.DevTerrain.Boulders:GetChildren()
)

-- 달 지형 (기본값 TERRAIN_ENABLED = true) ------------------------------------
print("[지형]")
local function flatDistance(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local function segmentDistance(point, a, b)
    local p = Vector3.new(point.X, 0, point.Z)
    local s0, s1 = Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z)
    local d = s1 - s0
    local t = math.clamp((p - s0):Dot(d) / d:Dot(d), 0, 1)
    return (p - (s0 + d * t)).Magnitude
end
-- 각 착륙 패드와 가장 가까운 얼음을 잇는 회랑
local function corridorsOf(ws)
    local list = {}
    for i = 1, 4 do
        local pad = ws.LandingPads["Pad" .. i].CFrame.Position
        local nearest, best = nil, math.huge
        for _, ice in ws.IceSites:GetChildren() do
            local d = flatDistance(pad, ice.CFrame.Position)
            if d < best then
                nearest, best = ice.CFrame.Position, d
            end
        end
        table.insert(list, { pad = pad, ice = nearest })
    end
    return list
end
-- 파트의 회전된 박스 꼭짓점 중 가장 낮은 y
local function partBottom(part)
    local lowest = math.huge
    local half = part.Size / 2
    for _, sx in { -1, 1 } do
        for _, sy in { -1, 1 } do
            for _, sz in { -1, 1 } do
                local corner = part.CFrame * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                lowest = math.min(lowest, corner.Y)
            end
        end
    end
    return lowest
end
-- 기지 키트(키트 좌표, 판 윗면 y -1) 높이 검사: 판과 경사로를 뺀 모든 파트 바닥이 판 윗면 - 0.1 이상,
-- 로버 복구 콘솔은 판 위에 선 기둥이고 에어락 문 중심에서 14 이상 떨어짐
local function kitHeightChecks(kitModel, label)
    local APRON_TOP = -1
    local ramps = kitModel:FindFirstChild("Ramps")
    local lowestName, lowest = "", math.huge
    for _, d in kitModel:GetDescendants() do
        if d:IsA("BasePart") and d.Name ~= "Apron" and not (ramps and d:IsDescendantOf(ramps)) then
            local bottom = partBottom(d)
            if bottom < lowest then
                lowestName, lowest = d:GetFullName(), bottom
            end
        end
    end
    check(
        lowest >= APRON_TOP - 0.1,
        string.format(
            "%s: 판과 경사로를 뺀 모든 파트 바닥이 판 윗면 - 0.1 이상 (최저 %.2f, %s)",
            label,
            lowest,
            lowestName
        )
    )
    local lander = kitModel.Lander
    local door = lander.Entry.Door
    local console = lander.RoverConsole
    local panel = lander:FindFirstChild("ConsolePanel")
    local consoleBottom = console.CFrame.Position.Y - console.Size.Y / 2
    local consoleTop = console.CFrame.Position.Y + console.Size.Y / 2
    local doorDistance = flatDistance(door.CFrame.Position, console.CFrame.Position)
    check(
        math.abs(console.Size.X - 1.4) < 1e-3
            and math.abs(console.Size.Z - 1.4) < 1e-3
            and math.abs(consoleTop - (-0.5 + 3.2)) < 1e-3
            and math.abs(consoleBottom - APRON_TOP) < 1e-3
            and console.Color == roblox.Color3.fromRGB(255, 140, 60),
        string.format(
            "%s: 복구 콘솔은 판 윗면에 선 주황 기둥 (1.4 x 3.2 x 1.4, 바닥 %.2f)",
            label,
            consoleBottom
        )
    )
    check(
        panel ~= nil
            and panel.Color == roblox.Color3.fromRGB(40, 42, 48)
            and math.abs(panel.CFrame.Position.Y - panel.Size.Y / 2 - consoleTop) < 1e-3,
        label .. ": 콘솔 윗면에 어두운 조작판"
    )
    check(
        doorDistance >= 14
            and console.CFrame.Position.X < door.CFrame.Position.X
            and console.CFrame.Position.Z < door.CFrame.Position.Z,
        string.format(
            "%s: 콘솔은 착륙선 왼쪽 앞, 문 중심에서 %.1f (14 이상)",
            label,
            doorDistance
        )
    )
end
-- 착륙지 i에 놓일 기지 판까지 xz 거리 (판 안이면 0). apron = ServerStorage.BaseKit.Apron
local function apronDistanceAt(apron, i, point, ws)
    local pad = (ws or Workspace).LandingPads["Pad" .. i]
    local apronWorld = pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + 0.5, 0) * apron.CFrame
    local p = apronWorld:PointToObjectSpace(point)
    local half = apron.Size / 2
    local dx = math.max(math.abs(p.X) - half.X, 0)
    local dz = math.max(math.abs(p.Z) - half.Z, 0)
    return math.sqrt(dx * dx + dz * dz)
end
local function runTerrainChecks()
    local TERRAIN_TOP = -1.5
    local blocks, balls = {}, {}
    for _, call in terrainCalls do
        table.insert(if call.kind == "block" then blocks else balls, call)
    end
    local block = blocks[1]
    check(
        #blocks == 1
            and math.abs(block.cframe.Position.Y + block.size.Y / 2 - TERRAIN_TOP) < 1e-6
            and block.size.Y == 24
            and block.size.X >= 1400
            and block.size.Z >= 1100,
        "FillBlock 한 번: 두께 24, 지형 윗면 y -1.5 (콘크리트 판보다 3 아래)"
    )
    check(
        terrainInstance:GetMaterialColor(roblox.Enum.Material.Sand)
            == roblox.Color3.fromRGB(128, 126, 122),
        "Sand 재질 색 = 달 표토 회색 (128, 126, 122)"
    )
    check(
        Workspace.DevTerrain:FindFirstChild("MoonGround") == nil,
        "Terrain이 있으면 지면 Part를 만들지 않음"
    )
    check(
        baseplate.Transparency == 1
            and baseplate.CanCollide == false
            and baseplateTexture.Transparency == 1,
        "기본 Baseplate는 플레이 중 숨김"
    )
    local labels = 0
    for _, container in { Workspace, ServerStorage } do
        for _, d in container:GetDescendants() do
            if d:IsA("BillboardGui") then
                labels += 1
            end
        end
    end
    check(labels == 0, "서버 월드 라벨 BillboardGui 0개 (" .. labels .. ")")

    -- 보호 구역: 기지 판 가장자리 + 25, 얼음 30, 주행 회랑 반폭 12 (지표면 원 기준)
    local apron = kit:FindFirstChild("Apron")
    local ices = {}
    for _, ice in Workspace.IceSites:GetChildren() do
        table.insert(ices, ice.CFrame.Position)
    end
    local corridors = corridorsOf(Workspace)
    local violations, corridorHits = 0, 0
    local craters, hills, smallCraters, badDepth, highRim, badHill = 0, 0, 0, 0, 0, 0
    local bigCraters = 0
    local nearPad = { 0, 0, 0, 0 }
    local craterCircles = {}
    for _, ball in balls do
        local dy = ball.center.Y - TERRAIN_TOP
        local footprint = if math.abs(dy) < ball.radius
            then math.sqrt(ball.radius ^ 2 - dy ^ 2)
            else 0
        for i = 1, 4 do
            if apronDistanceAt(apron, i, ball.center) < 25 + footprint - 1e-6 then
                violations += 1
            end
        end
        for _, ice in ices do
            if flatDistance(ball.center, ice) < 30 + footprint - 1e-6 then
                violations += 1
            end
        end
        for _, c in corridors do
            if segmentDistance(ball.center, c.pad, c.ice) < 12 + footprint - 1e-6 then
                corridorHits += 1
            end
        end
        local protrude = ball.center.Y + ball.radius - TERRAIN_TOP
        if ball.material == roblox.Enum.Material.Air then
            craters += 1
            if ball.radius < 12 then
                smallCraters += 1
            end
            if ball.radius > 50 then
                bigCraters += 1
            end
            -- 깊이 = 반지름의 20%: 중심이 지형 위 (반지름 - 깊이). Vector3는 float32라 오차 1e-4 허용
            if math.abs(dy - ball.radius * 0.8) > 1e-4 then
                badDepth += 1
            end
            table.insert(craterCircles, { center = ball.center, footprint = footprint })
            for i = 1, 4 do
                if apronDistanceAt(apron, i, ball.center) <= 120 then
                    nearPad[i] += 1
                end
            end
        elseif ball.radius >= 40 then
            hills += 1
            if protrude < 2 - 1e-6 or protrude > 4 + 1e-6 then
                badHill += 1
            end
        elseif protrude > 1.5 + 1e-6 then
            highRim += 1
        end
    end
    check(
        violations == 0,
        "모든 FillBall의 지표면 원이 기지 판 가장자리 + 25, 얼음 반지름 30 밖 (침범 "
            .. violations
            .. ")"
    )
    check(
        corridorHits == 0,
        "폭 24 주행 회랑에 크레이터와 언덕 없음 (침범 " .. corridorHits .. ")"
    )
    check(
        craters == 45 and smallCraters == 0 and bigCraters == 0,
        "크레이터 "
            .. craters
            .. "개 (약 45), 반지름 12 미만 "
            .. smallCraters
            .. "개, 50 초과 "
            .. bigCraters
            .. "개"
    )
    check(
        badDepth == 0 and highRim == 0,
        "크레이터 깊이 반지름의 20%, 테두리 둔덕 1.5 이하"
    )
    check(hills == 12 and badHill == 0, "언덕 " .. hills .. "개, 높이 2 ~ 4")
    check(
        nearPad[1] >= 8 and nearPad[2] >= 8 and nearPad[3] >= 8 and nearPad[4] >= 8,
        string.format(
            "네 착륙지 모두 기지 판 가장자리 120 안에 크레이터 중심 8개 이상 (%d, %d, %d, %d)",
            nearPad[1],
            nearPad[2],
            nearPad[3],
            nearPad[4]
        )
    )
    check(
        nearPad[4] > nearPad[1],
        string.format(
            "Pad4(지형 위험 높음) 주변 크레이터 %d개 > Pad1 주변 %d개",
            nearPad[4],
            nearPad[1]
        )
    )

    -- 착륙 패드와 얼음은 지형 위
    local padsOk, icesOk = true, true
    for i = 1, 4 do
        local pad = Workspace.LandingPads["Pad" .. i]
        local top = pad.CFrame.Position.Y + pad.Size.Y / 2
        local bottom = pad.CFrame.Position.Y - pad.Size.Y / 2
        if math.abs(top - 2) > 1e-6 or bottom > TERRAIN_TOP + 1e-6 then
            padsOk = false
        end
    end
    for _, ice in Workspace.IceSites:GetChildren() do
        if math.abs(ice.CFrame.Position.Y - ice.Size.Y / 2 - TERRAIN_TOP) > 1e-6 then
            icesOk = false
        end
    end
    check(padsOk, "착륙 패드 윗면 y 2.0, 지형까지 묻힘")
    check(icesOk, "얼음 지점 바닥이 지형 윗면(y -1.5)")

    -- 기지 콘크리트 판과 경사로 (키트 좌표: Origin 아래 0.5 = 판 윗면 -1.0)
    check(
        apron ~= nil
            and apron.Material == roblox.Enum.Material.Concrete
            and apron.Color == roblox.Color3.fromRGB(105, 105, 108)
            and math.abs(apron.CFrame.Position.Y + apron.Size.Y / 2 - -1) < 1e-6,
        "기지 키트에 콘크리트 판 (윗면 = 착륙 패드 윗면 - 0.5 = 월드 y 1.5)"
    )
    local ramps = kit:FindFirstChild("Ramps")
    local rampOk = ramps ~= nil and #ramps:GetChildren() == 4
    if ramps then
        for _, ramp in ramps:GetChildren() do
            if not ramp:IsA("WedgePart") or ramp.Size ~= Vector3.new(10, 3, 10) then
                rampOk = false
            end
        end
    end
    check(rampOk, "판 가장자리 경사로 WedgePart 4개 (폭 10, 길이 10, 높이 3)")
    -- 판 윗면(월드)이 지형보다 3 이상 높다 (어느 착륙지든 같다)
    local apronTopWorld = (Workspace.LandingPads.Pad1.CFrame * CFrame.new(
        0,
        Workspace.LandingPads.Pad1.Size.Y / 2 + 0.5,
        0
    ) * apron.CFrame * CFrame.new(0, apron.Size.Y / 2, 0)).Position.Y
    check(
        math.abs(apronTopWorld - 1.5) < 1e-6 and apronTopWorld - TERRAIN_TOP >= 3 - 1e-6,
        string.format(
            "판 윗면 y %.1f가 지형 윗면 y %.1f보다 3 이상 높음",
            apronTopWorld,
            TERRAIN_TOP
        )
    )
    kitHeightChecks(kit, "그레이박스 키트")
    -- 어느 착륙지에 놓여도 판 위에 크레이터가 없다
    local onApron = 0
    for i = 1, 4 do
        local pad = Workspace.LandingPads["Pad" .. i]
        local apronWorld = pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + 0.5, 0) * apron.CFrame
        local half = apron.Size / 2
        for _, crater in craterCircles do
            local p = apronWorld:PointToObjectSpace(crater.center)
            local dx = math.max(math.abs(p.X) - half.X, 0)
            local dz = math.max(math.abs(p.Z) - half.Z, 0)
            if math.sqrt(dx * dx + dz * dz) < crater.footprint then
                onApron += 1
            end
        end
    end
    check(onApron == 0, "네 착륙지 어디서도 콘크리트 판 위에 크레이터 없음")

    -- 바위 3층 (약 220): 기지 둘레, 회랑 옆, 산포. 회랑 안과 판 + 6 안에 없음, 크레이터 밖, 약 10%는 2배 크기
    local boulders = Workspace.DevTerrain.Boulders:GetChildren()
    local dev = Config.DEV_MAP
    local layers = { ring = 0, corridor = 0, scatter = 0 }
    local inCorridor, blocked, inCrater, big, badRing = 0, 0, 0, 0, 0
    local nearIce = {}
    for index = 1, #ices do
        nearIce[index] = 0
    end
    for _, boulder in boulders do
        local p = if boulder:IsA("BasePart")
            then boulder.CFrame.Position
            else boulder:GetPivot().Position
        local layer = boulder:GetAttribute("BoulderLayer")
        if layers[layer] then
            layers[layer] += 1
        end
        for _, c in corridors do
            if segmentDistance(p, c.pad, c.ice) < 12 then
                inCorridor += 1
            end
        end
        local nearestApron = math.huge
        for i = 1, 4 do
            nearestApron = math.min(nearestApron, apronDistanceAt(apron, i, p))
        end
        if nearestApron < 6 then
            blocked += 1
        end
        if layer == "ring" and (nearestApron < 6 or nearestApron > 45 + 1e-6) then
            badRing += 1
        end
        for index, ice in ices do
            if flatDistance(p, ice) < 15 then
                blocked += 1
            end
            if flatDistance(p, ice) < dev.iceBoulderCapRadius then
                nearIce[index] += 1
            end
        end
        for _, crater in craterCircles do
            if flatDistance(p, crater.center) < crater.footprint then
                inCrater += 1
            end
        end
        if boulder:GetAttribute("BoulderScale") == 2 then
            big += 1
        end
    end
    local function sum(list)
        local total = 0
        for _, v in list do
            total += v
        end
        return total
    end
    check(
        layers.ring == sum(dev.baseRingBouldersBySite)
            and layers.corridor >= sum(dev.boulderCountBySite) * 0.9
            and layers.scatter >= dev.scatterBoulders * 0.9
            and #boulders == layers.ring + layers.corridor + layers.scatter
            and #boulders >= 200
            and #boulders <= 230,
        string.format(
            "바위 %d개 (약 220): 기지 둘레 %d, 회랑 옆 %d, 산포 %d",
            #boulders,
            layers.ring,
            layers.corridor,
            layers.scatter
        )
    )
    check(
        inCorridor == 0 and blocked == 0,
        "바위가 회랑 안, 기지 판 + 6 안, 얼음 반지름 15 안에 없음"
    )
    check(badRing == 0, "기지 둘레 바위는 판 가장자리 + 6 ~ + 45 사이")
    local maxNearIce = 0
    for _, n in nearIce do
        maxNearIce = math.max(maxNearIce, n)
    end
    check(
        maxNearIce <= dev.iceBoulderCap,
        string.format(
            "얼음 지점 반지름 %d 안 바위 최대 %d개 (상한 %d)",
            dev.iceBoulderCapRadius,
            maxNearIce,
            dev.iceBoulderCap
        )
    )
    check(inCrater == 0, "바위가 크레이터 안에 놓이지 않음")
    check(
        big >= #boulders * 0.05 and big <= #boulders * 0.2,
        string.format("2배 크기 바위 %d개 (%.0f%%)", big, big / #boulders * 100)
    )
    check(
        boulders[1].Color == roblox.Color3.fromRGB(90, 88, 86),
        "그레이박스 바위 회색 (90, 88, 86)"
    )
    -- 얼음 지점 (그레이박스)
    local ice1 = Workspace.IceSites.Ice1
    local glow = ice1:FindFirstChild("IceGlow")
    local light = glow and glow:FindFirstChildOfClass("PointLight")
    check(
        ice1.Material == roblox.Enum.Material.Ice
            and ice1.Color == roblox.Color3.fromRGB(170, 225, 255)
            and math.abs(ice1.Transparency - 0.1) < 1e-6,
        "그레이박스 얼음: Ice 재질, 하늘색, 투명도 0.1"
    )
    check(
        light ~= nil and light.Range == 18 and math.abs(light.Brightness - 1.2) < 1e-6,
        "얼음 중심에 PointLight (Range 18, Brightness 1.2)"
    )

    -- 하늘과 행성
    local lighting = dm:GetService("Lighting")
    local sky = lighting:FindFirstChildOfClass("Sky")
    check(
        sky ~= nil
            and tostring(sky.MoonTextureId) == "rbxasset://sky/sun.jpg"
            and sky.MoonAngularSize == 14
            and sky.StarCount == 3000
            and sky.CelestialBodiesShown == true,
        "Sky 생성: 달 자리에 태양 텍스처(rbxasset://sky/sun.jpg), 크기 14, 별 3000"
    )
    check(
        atmosphere1.Density == 0 and atmosphere1.Haze == 0 and atmosphere1.Glare == 0,
        "Atmosphere 밀도, Haze, Glare 0"
    )
    check(math.abs(lighting.ClockTime - 2.5) < 1e-6, "ClockTime 2.5")
    local planet = Workspace:FindFirstChild("Decor") and Workspace.Decor:FindFirstChild("Planet")
    local sphere = planet and planet:FindFirstChild("Sphere")
    check(
        planet ~= nil
            and planet:IsA("Model")
            and planet.ModelStreamingMode == roblox.Enum.ModelStreamingMode.Persistent
            and sphere ~= nil
            and sphere.Material == roblox.Enum.Material.Neon
            and sphere.Color == roblox.Color3.fromRGB(120, 170, 230)
            and math.abs(sphere.Size.X - 260) < 1e-6,
        "메시가 없으면 Neon 구 Planet (지름 260, 항상 스트리밍)"
    )
    -- 시작 시에는 기본 착륙지(Pad2)에서 가장 가까운 얼음 쪽 하늘
    local pad2 = Workspace.LandingPads.Pad2.CFrame.Position
    local offset = sphere.CFrame.Position - pad2
    local nearestIce = Workspace.IceSites.Ice2.CFrame.Position
    local heading = Vector3.new(nearestIce.X - pad2.X, 0, nearestIce.Z - pad2.Z).Unit
    check(
        math.abs(offset.Magnitude - 900) < 0.01
            and math.abs(math.deg(math.asin(offset.Y / offset.Magnitude)) - 20) < 0.01
            and Vector3.new(offset.X, 0, offset.Z).Unit:Dot(heading) > 0.999,
        "행성: 기본 착륙지에서 거리 900, 고도 20도, 가장 가까운 얼음 방향"
    )
end
runTerrainChecks()

-- 지형 꺼짐 경로 + 디자이너 하늘 유지: DevMap의 TERRAIN_ENABLED만 false로 바꾼 사본을 별도 place에서
local function runFlatCase()
    local dm3 = roblox.deserializePlace(fs.readFile(placePath))
    local ws3 = dm3:GetService("Workspace")
    local terrain3 = Instance.new("Terrain")
    terrain3.Parent = ws3
    local plate3 = Instance.new("Part")
    plate3.Name = "Baseplate"
    plate3.Size = Vector3.new(2048, 16, 2048)
    plate3.CFrame = CFrame.new(0, -8, 0)
    plate3.Parent = ws3
    local lighting3 = dm3:GetService("Lighting")
    local designerSky = Instance.new("Sky")
    designerSky.MoonTextureId = "rbxassetid://123"
    designerSky:SetAttribute("KeepSky", true)
    designerSky.Parent = lighting3
    local designerAtmosphere = Instance.new("Atmosphere")
    designerAtmosphere.Density = 0.4
    designerAtmosphere:SetAttribute("KeepAtmosphere", true)
    designerAtmosphere.Parent = lighting3
    local patched = 0
    local loader3 = makeLoader(dm3, {}, function(key, source)
        if string.sub(key, -6) == "DevMap" then
            local out, n =
                string.gsub(source, "local TERRAIN_ENABLED = true", "local TERRAIN_ENABLED = false")
            patched += n
            return out
        end
        return source
    end)
    local callsBefore = #terrainCalls
    task.spawn(function()
        loader3(dm3:GetService("ServerScriptService").Server.DevMap).ensure()
    end)
    advance(0)
    check(patched == 1, "지형 꺼짐 경로: DevMap 플래그를 false로 바꿈")
    local ground = ws3.DevTerrain:FindFirstChild("MoonGround")
    check(
        ground ~= nil and math.abs(ground.CFrame.Position.Y + ground.Size.Y / 2 - 1.5) < 1e-6,
        "TERRAIN_ENABLED false: 평평한 지면 Part (윗면 y 1.5)"
    )
    check(#terrainCalls == callsBefore, "TERRAIN_ENABLED false: Terrain 호출 0회")
    check(
        plate3.Transparency == 0 and plate3.CanCollide == true,
        "TERRAIN_ENABLED false: Baseplate는 그대로"
    )
    local kit3 = dm3:GetService("ServerStorage").BaseKit
    check(
        kit3:FindFirstChild("Apron") == nil and kit3:FindFirstChild("Ramps") == nil,
        "TERRAIN_ENABLED false: 콘크리트 판과 경사로 없음"
    )
    local skies = 0
    for _, child in lighting3:GetChildren() do
        if child:IsA("Sky") then
            skies += 1
        end
    end
    check(
        skies == 1 and tostring(designerSky.MoonTextureId) == "rbxassetid://123",
        "Sky에 KeepSky = true면 덮어쓰지 않음"
    )
    check(
        math.abs(designerAtmosphere.Density - 0.4) < 1e-6,
        "Atmosphere에 KeepAtmosphere = true면 그대로"
    )
end
runFlatCase()

check(state().phase == "selecting", "부팅 후 selecting")

-- 플레이어 입장 ---------------------------------------------------------
print("[입장과 선택]")
local alice = makePlayer("Alice", 1)
local bob = makePlayer("Bob", 2)
-- Alice 캐릭터 (산소 테스트용)
local character = Instance.new("Model")
character.Name = "AliceCharacter"
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.CFrame = CFrame.new(0, 50, 0)
root.Parent = character
local humanoid = Instance.new("Humanoid")
humanoid.Health = 100
humanoid.Parent = character
character.PrimaryPart = root
-- R15 머리와 몸통, 평상복과 장신구 (우주복 적용 확인용)
local function dressCasual(model, rootCFrame)
    local head = Instance.new("Part")
    head.Name = "Head"
    head.Size = Vector3.new(1.2, 1.2, 1.2)
    head.CFrame = rootCFrame * CFrame.new(0, 2, 0)
    head.Parent = model
    local torso = Instance.new("Part")
    torso.Name = "UpperTorso"
    torso.Size = Vector3.new(2, 1.6, 1)
    torso.CFrame = rootCFrame * CFrame.new(0, 0.6, 0)
    torso.Parent = model
    for _, className in { "Shirt", "Pants", "ShirtGraphic" } do
        Instance.new(className).Parent = model
    end
    local hair = Instance.new("Accessory")
    hair.Name = "Hair"
    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Parent = hair
    hair.Parent = model
    Instance.new("BodyColors").Parent = model
end
dressCasual(character, root.CFrame)
character.Parent = Workspace
alice.Character = character

table.insert(players, alice)
signalFor(PlayersService, "PlayerAdded"):Fire(alice)
advance(0)
-- 우주복이 입혀졌는지
local function suitOk(model)
    for _, child in model:GetChildren() do
        if
            child:IsA("Accessory")
            or child:IsA("Shirt")
            or child:IsA("Pants")
            or child:IsA("ShirtGraphic")
        then
            return false, "평상복 남음: " .. child.ClassName
        end
    end
    local helmet = model:FindFirstChild("SuitHelmet")
    local pack = model:FindFirstChild("SuitPack")
    local panel = model:FindFirstChild("SuitPanel")
    if not helmet or not pack or not panel then
        return false, "헬멧, 배낭, 제어판 중 없음"
    end
    if
        math.abs(helmet.Transparency - Config.SUIT.helmetTransparency) > 1e-6
        or helmet.CanQuery
        or helmet.CanCollide
        or not helmet.Massless
    then
        return false, "헬멧 설정"
    end
    local weld = helmet:FindFirstChildOfClass("WeldConstraint")
    if not weld or weld.Part0 ~= model:FindFirstChild("Head") then
        return false, "헬멧이 머리에 용접되지 않음"
    end
    local colors = model:FindFirstChildOfClass("BodyColors")
    local suit = Config.SUIT
    if
        not colors
        or colors.TorsoColor3 ~= roblox.Color3.fromRGB(table.unpack(suit.suitColor))
        or colors.LeftArmColor3 ~= roblox.Color3.fromRGB(table.unpack(suit.accentColor))
    then
        return false, "BodyColors"
    end
    return true, "ok"
end
do
    local ok, why = suitOk(character)
    check(
        ok,
        "입장 직후 우주복 (평상복과 장신구 제거, 헬멧, 배낭, 제어판, 흰 수트 주황 왼팔): "
            .. why
    )
    -- 늦게 붙는 장신구도 걷어 낸다
    local late = Instance.new("Accessory")
    late.Name = "LateHat"
    late.Parent = character
    signalFor(character, "ChildAdded"):Fire(late)
    advance(0)
    check(character:FindFirstChild("LateHat") == nil, "늦게 붙은 장신구 제거")
end
local open = lastSent("SiteSelectionOpen")
check(open ~= nil and open.args[1].chooserUserId == 1, "SiteSelectionOpen 권한자 Alice")
check(
    open.args[1].deadlineUnix == 1700000000 + Config.SITE_SELECT_TIMEOUT,
    "마감 시각 = GetServerTimeNow + 30초"
)
check(
    #open.args[1].sites == 4 and open.args[1].sites[1].iceDistanceLabel == "멀다",
    "착륙지 카드 4장"
)
check(lastSent("StateUpdate") ~= nil, "입장 직후 StateUpdate")
check(lastSent("OxygenUpdate") ~= nil, "입장 직후 OxygenUpdate")

table.insert(players, bob)
signalFor(PlayersService, "PlayerAdded"):Fire(bob)
advance(0)
local selectRemote = dm:GetService("ReplicatedStorage").Remotes.SelectSite
signalFor(selectRemote, "OnServerEvent"):Fire(bob, 1)
advance(0)
check(state().phase == "selecting", "권한 없는 Bob의 선택 거부")
local n = lastSent("Notify")
check(
    n and n.target == bob and string.find(n.args[1], "Alice", 1, true),
    "Bob에게 권한 안내: " .. tostring(n and n.args[1])
)
signalFor(selectRemote, "OnServerEvent"):Fire(alice, "1")
signalFor(selectRemote, "OnServerEvent"):Fire(alice, 0 / 0)
signalFor(selectRemote, "OnServerEvent"):Fire(alice, 5)
signalFor(selectRemote, "OnServerEvent"):Fire(alice, 1.5)
advance(0)
check(state().phase == "selecting", "잘못된 siteId 무시")

signalFor(selectRemote, "OnServerEvent"):Fire(alice, 1)
advance(0)
check(state().phase == "landing", "Alice 선택 후 landing")
check(
    state().siteId == 1 and state().sunlight == 1 and state().siteName == "Shackleton Rim",
    "siteId, sunlight, siteName"
)
local base = Workspace:FindFirstChild("Base")
check(base ~= nil, "Workspace.Base 생성")
local pad1 = Workspace.LandingPads.Pad1
local origin = base.PrimaryPart
local expectedY = pad1.CFrame.Position.Y + pad1.Size.Y / 2 + origin.Size.Y / 2
check(
    (
        origin.CFrame.Position
        - Vector3.new(pad1.CFrame.Position.X, expectedY, pad1.CFrame.Position.Z)
    ).Magnitude < 0.01,
    "Origin이 Pad1 윗면에 놓임"
)
check(
    lastSent("LandingSequence") ~= nil and lastSent("LandingSequence").args[1] == 1,
    "LandingSequence(siteId=1)"
)
local spawnPoint = base.Lander.SpawnPoint
check(
    (root.CFrame.Position - spawnPoint.CFrame.Position).Magnitude < 6,
    "캐릭터가 착륙선 스폰으로 이동"
)
-- 로버 앞쪽이 얼음을 향하는지 (Pad1 -> Ice1)
local toIce = (Workspace.IceSites.Ice1.CFrame.Position - pad1.CFrame.Position)
local roverLook = base.Rover.DriverSeat.CFrame.LookVector
check(Vector3.new(toIce.X, 0, toIce.Z).Unit:Dot(roverLook) > 0.99, "로버가 얼음 방향을 봄")
local roverHome = base.Rover:GetPivot()
local seatHome = base.Rover.DriverSeat.CFrame
local landingInstall = base.SolarField.InstallPad:FindFirstChildOfClass("ProximityPrompt")
local landingTank = base.WaterTank:FindFirstChildOfClass("ProximityPrompt")
local consolePrompt = base.Lander.RoverConsole:FindFirstChildOfClass("ProximityPrompt")
check(
    landingInstall.Enabled == false
        and landingTank.Enabled == false
        and consolePrompt.Enabled == false,
    "착륙 중 설치, 하역, 복구 프롬프트 비활성"
)
local speedRemote = dm:GetService("ReplicatedStorage").Remotes.SetSpeed
signalFor(speedRemote, "OnServerEvent"):Fire(bob, 2)
advance(0)
check(state().speed == 1, "playing 전 SetSpeed 무시")
local tankDistance = (Vector3.new(
    base.WaterTank.CFrame.Position.X,
    0,
    base.WaterTank.CFrame.Position.Z
) - Vector3.new(seatHome.Position.X, 0, seatHome.Position.Z)).Magnitude
check(
    tankDistance < 12,
    string.format(
        "운전석에서 물탱크 중심까지 %.1f studs (프롬프트 12 이내)",
        tankDistance
    )
)

advance(Config.LANDING_SECONDS + 0.01)
check(state().phase == "playing" and state().day == 1, "착륙 5초 뒤 playing, day 1")
check(
    landingInstall.Enabled == true and landingTank.Enabled == true and consolePrompt.Enabled == true,
    "playing 후 설치, 하역, 복구 프롬프트 활성"
)
check(
    base.ModulePads.PadA.Pad:FindFirstChildOfClass("ProximityPrompt").Enabled == true,
    "PadA 프롬프트 활성"
)
check(
    base.ModulePads.PadB.Pad:FindFirstChildOfClass("ProximityPrompt").Enabled == false,
    "PadB 프롬프트 비활성(잠김)"
)
check(
    base.ModulePads.PadA:FindFirstChild("Built") == nil
        and base.ModulePads.PadA:FindFirstChild("Ghost") == nil,
    "Ghost, Built 숨김"
)
check(string.find(state().missionText, "패널", 1, true) ~= nil, "미션: " .. state().missionText)

-- 패널 설치 -------------------------------------------------------------
print("[패널]")
local installPrompt = base.SolarField.InstallPad:FindFirstChildOfClass("ProximityPrompt")
check(
    installPrompt.HoldDuration == Config.PANEL_INSTALL_HOLD
        and installPrompt.MaxActivationDistance == 12
        and installPrompt.RequiresLineOfSight == false,
    "InstallPad 프롬프트 설정"
)
for _ = 1, 4 do
    signalFor(installPrompt, "Triggered"):Fire(alice)
end
advance(0)
check(
    state().panelsInstalled == 3 and state().panelsInstalledToday == 3,
    "하루 3장까지만 설치"
)
check(
    lastSent("Notify").args[1] == "오늘 설치 한도에 도달했습니다",
    "4번째는 한도 경고"
)
check(
    installPrompt.ActionText == string.format(Config.PROMPT_TEXTS.installTomorrow, 3, 3),
    "한도 도달 시 프롬프트 '" .. installPrompt.ActionText .. "'"
)
check(
    installPrompt.ObjectText == "태양광 필드"
        and installPrompt.Style == roblox.Enum.ProximityPromptStyle.Custom,
    "패널 프롬프트 ObjectText '태양광 필드', Style Custom"
)
check(
    state().missionText == Config.MISSION_TEXTS.boardRover,
    "오늘 한도를 채우면 탑승 안내 미션"
)
check(#base.SolarField.Panels:GetChildren() == 3, "패널 모델 3개 배치")
local slot1 = base.SolarField.Slots.Slot1
local panel1 = base.SolarField.Panels.Panel1
check(
    math.abs(
        panel1.Frame.CFrame.Position.Y
            - panel1.Frame.Size.Y / 2
            - (slot1.CFrame.Position.Y + slot1.Size.Y / 2)
    ) < 0.01,
    "패널이 슬롯 윗면에 놓임"
)
do
    local fillX, fillZ = panelFill(panel1, slot1)
    check(
        fillX >= 0.8 and fillZ >= 0.8 and fillX <= 1 and fillZ <= 1,
        string.format(
            "그레이박스 패널 바닥이 슬롯의 %.0f%% x %.0f%% (80%% 이상)",
            fillX * 100,
            fillZ * 100
        )
    )
end

advance(Config.DAY_SECONDS)
check(
    state().day == 2
        and state().energy == Config.START.energy + 3 * Config.PANEL_OUTPUT
        and state().panelsInstalledToday == 0,
    "DayTick: day 2, 시작 에너지 + 패널 3장 발전, 오늘 설치 초기화"
)
check(
    installPrompt.ActionText == string.format(Config.PROMPT_TEXTS.installPanel, 0, 3),
    "다음 날 프롬프트 '" .. installPrompt.ActionText .. "'"
)

-- 산소: 야외에 세워 두면 고갈 ---------------------------------------------
print("[산소]")
do
    -- 그레이박스 착륙선: 걸어 들어가는 오두막. 문, 보이지 않는 충돌 벽(정면 문 폭 비움), 내부 산소 구역
    local ok, why = entryOk(base.Lander, 5)
    check(
        ok,
        "그레이박스 착륙선 출입: 문, 프레임, AIRLOCK 표지, 4면 충돌 벽(정면 5 비움), 내부 빛: "
            .. why
    )
    check(base.Lander:FindFirstChild("Airlock") == nil, "통로 튜브, 문 판, 범위 링 없음")
    local hutWallsOff = true
    for _, name in { "Roof", "BackWall", "LeftWall", "RightWall", "FrontLeft", "FrontRight" } do
        local part = base.Lander:FindFirstChild(name)
        if part and part.CanCollide then
            hutWallsOff = false
        end
    end
    check(
        hutWallsOff and base.Lander.Floor.CanCollide,
        "오두막 외형은 충돌 없음, 바닥만 충돌"
    )
    local okA, whyA = entryOk(kit.ModulePads.PadA.Built, 5)
    check(okA, "그레이박스 Habitat A 출입 구조는 Built 안: " .. whyA)
    local originCFrame = base.PrimaryPart.CFrame
    local function insideAt(position)
        root.CFrame = CFrame.new(position)
        advance(0.5)
        return lastSent("OxygenUpdate").args[3]
    end
    check(insideAt(base.Lander.OxygenZone.CFrame.Position) == true, "착륙선 내부: inside true")
    check(
        insideAt(originCFrame * Vector3.new(0, 4, 8)) == true,
        "착륙선 안쪽 깊은 곳: inside true"
    )
    check(
        insideAt(originCFrame * Vector3.new(8.5, 3, 6)) == false,
        "착륙선 옆(벽 밖): inside false"
    )
    local spawnPart = base.Lander.SpawnPoint
    local spawnRoot = spawnPart.CFrame.Position
        + Vector3.new(0, spawnPart.Size.Y / 2 + Config.SPAWN_HEIGHT_OFFSET, 0)
    check(insidePart(base.Lander.OxygenZone, spawnRoot), "스폰 지점이 착륙선 내부")
end
local function lowWarnings()
    local total = 0
    for _, s2 in sent do
        if s2.name == "Notify" and s2.target == alice and s2.args[1] == Config.TEXTS.lowOxygen then
            total += 1
        end
    end
    return total
end
local lowBefore = lowWarnings()
root.CFrame = CFrame.new(pad1.CFrame.Position + Vector3.new(0, 3, 200))
local deathsBefore = state().oxygenDeaths
advance(61)
check(
    lowWarnings() == lowBefore + 1,
    "산소 20 이하로 떨어지면 경고 한 번 (" .. (lowWarnings() - lowBefore) .. ")"
)
check(state().oxygenDeaths == deathsBefore + 1, "60초 야외에서 산소 고갈 1회")
check(
    (root.CFrame.Position - spawnPoint.CFrame.Position).Magnitude < 6,
    "고갈 후 착륙선으로 이동"
)
local oxygenSends = countSent("OxygenUpdate")
check(
    oxygenSends > 100 and oxygenSends <= 5 * 70,
    "OxygenUpdate 송신 수 " .. oxygenSends .. " (초당 5회 이하)"
)
-- 페널티 (하루 소비와 섞이므로 대략 확인)
check(state().oxygenDeaths == 1, "oxygenDeaths 1")
local o = lastSent("OxygenUpdate")
advance(1)
o = lastSent("OxygenUpdate")
check(
    o.args[1] == Config.OXYGEN.max and o.args[3] == true,
    "착륙선 안에서 산소 최대, inside=true"
)

-- 물 원정 ---------------------------------------------------------------
print("[물]")
local seat = base.Rover.DriverSeat
local ice1 = Workspace.IceSites.Ice1
local icePrompt = ice1:FindFirstChildOfClass("ProximityPrompt")
check(icePrompt.Enabled == false, "운전자 없으면 얼음 프롬프트 비활성")
seat.CFrame = ice1.CFrame * CFrame.new(0, 0, 12)
advance(1)
check(icePrompt.Enabled == false, "가까워도 운전자 없으면 비활성")
seat.Occupant = humanoid
humanoid.SeatPart = seat
advance(1)
check(icePrompt.Enabled == true, "운전 중 + 20 studs 안이면 활성")
signalFor(icePrompt, "Triggered"):Fire(bob)
advance(0)
check(state().rover.tank == 0, "운전자가 아닌 Bob의 채취 거부")
signalFor(icePrompt, "Triggered"):Fire(alice)
advance(0)
check(
    state().rover.tank == 40 and seat:GetAttribute("Tank") == 40,
    "탱크 만충 40, Attribute 반영"
)
seat.CFrame = ice1.CFrame * CFrame.new(0, 0, 60)
advance(1)
check(icePrompt.Enabled == false, "멀어지면 비활성")
-- 하차: 플레이어와 무관한 더미로 대체 (Lune은 Ref에 nil 대입 불가)
local dummyModel = Instance.new("Model")
local dummyHumanoid = Instance.new("Humanoid")
dummyHumanoid.Parent = dummyModel
seat.Occupant = dummyHumanoid
humanoid.SeatPart = Instance.new("Part")
local tankPrompt = base.WaterTank:FindFirstChildOfClass("ProximityPrompt")
local water0 = state().water
signalFor(tankPrompt, "Triggered"):Fire(bob)
advance(0)
check(
    state().water == water0 and state().rover.tank == 40,
    "로버가 멀리 있으면 하역 거부"
)
check(
    lastSent("Notify").args[1] == "로버를 물탱크 옆에 세워야 하역할 수 있습니다",
    "하역 거부 안내"
)
seat.CFrame = base.WaterTank.CFrame * CFrame.new(6, 0, 0)
signalFor(tankPrompt, "Triggered"):Fire(bob)
advance(0)
check(
    state().water == water0 + 40 and state().rover.tank == 0 and state().waterTrips == 1,
    "하역: 물 +40, 탱크 0, 원정 1회"
)
check(seat:GetAttribute("Tank") == 0, "Tank Attribute 0")
signalFor(tankPrompt, "Triggered"):Fire(bob)
advance(0)
check(
    lastSent("Notify").args[1] == "로버 탱크가 비어 있습니다",
    "빈 탱크 하역 안내"
)

-- 로버 복구 -------------------------------------------------------------
print("[로버 복구]")
seat.CFrame = seatHome
local function roverAtHome()
    local rover = base:FindFirstChild("Rover")
    return rover ~= nil and (rover:GetPivot().Position - roverHome.Position).Magnitude < 0.01
end
-- 소실: 로버를 통째로 지우면 BaseKit에서 다시 복제
base.Rover:Destroy()
advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
local newRover = base:FindFirstChild("Rover")
check(
    newRover ~= nil and newRover:FindFirstChild("DriverSeat") ~= nil,
    "시트 소실 시 로버 재복제"
)
check(roverAtHome(), "재복제 로버가 홈 위치")
check(
    newRover.DriverSeat:GetAttribute("Tank") == state().rover.tank,
    "재복제 후 Tank Attribute 반영"
)
check(lastSent("Notify").args[1] == "로버가 복구되었습니다", "복구 안내")
-- 뒤집힘: 무인 상태로 3초 이상이면 자동 복구
newRover:PivotTo(roverHome * CFrame.new(0, 2, 0) * CFrame.Angles(0, 0, math.pi))
advance(2)
check(not roverAtHome(), "뒤집힌 지 3초 전에는 그대로")
advance(3)
check(
    roverAtHome() and newRover.DriverSeat.CFrame.UpVector.Y > 0.99,
    "뒤집힘 3초 뒤 자동 복구"
)
-- 추락: Origin보다 20 studs 아래
newRover:PivotTo(roverHome * CFrame.new(0, -30, 0))
advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
check(roverAtHome(), "추락 시 자동 복구")
-- 수동: 착륙선 콘솔 프롬프트
newRover:PivotTo(roverHome * CFrame.new(40, 0, 0))
signalFor(consolePrompt, "Triggered"):Fire(alice)
advance(0)
check(roverAtHome(), "콘솔 프롬프트로 수동 복구")
check(
    consolePrompt.ActionText == "로버 복구"
        and consolePrompt.HoldDuration == Config.ROVER_RECOVERY.hold,
    "복구 프롬프트 설정"
)

-- 탑승 프롬프트 ----------------------------------------------------------
print("[탑승]")
do
    local boardPrompt = newRover.Chassis:FindFirstChildOfClass("ProximityPrompt")
    check(
        boardPrompt ~= nil
            and boardPrompt.ActionText == "탑승"
            and boardPrompt.ObjectText == "로버"
            and boardPrompt.HoldDuration == 0
            and boardPrompt.MaxActivationDistance == 10
            and boardPrompt.RequiresLineOfSight == false
            and boardPrompt.Enabled == true,
        "재생성된 로버 섀시에 탑승 프롬프트 (탑승, 로버, 홀드 0, 거리 10)"
    )
    -- 멀리서 보낸 요청은 거부
    root.CFrame = newRover.Chassis.CFrame * CFrame.new(60, 0, 0)
    signalFor(boardPrompt, "Triggered"):Fire(alice)
    advance(0)
    check(newRover.DriverSeat.Occupant == nil, "멀리서 탑승 요청은 거부")
    root.CFrame = newRover.Chassis.CFrame * CFrame.new(6, 0, 0)
    signalFor(boardPrompt, "Triggered"):Fire(alice)
    advance(0)
    check(
        newRover.DriverSeat.Occupant == humanoid and humanoid.SeatPart == newRover.DriverSeat,
        "프롬프트로 seat:Sit 호출"
    )
    check(boardPrompt.Enabled == false, "누가 앉으면 탑승 프롬프트 꺼짐")
    local note = lastSent("Notify")
    check(
        note ~= nil
            and note.target == alice
            and note.args[1] == Config.TEXTS.firstBoard
            and note.args[2] == "info",
        "첫 탑승 안내: " .. tostring(note and note.args[1])
    )
    -- 모든 프롬프트 스타일 Custom
    local count, custom = 0, 0
    for _, d in Workspace:GetDescendants() do
        if d:IsA("ProximityPrompt") then
            count += 1
            if d.Style == roblox.Enum.ProximityPromptStyle.Custom then
                custom += 1
            end
        end
    end
    check(
        count > 0 and custom == count,
        string.format("모든 프롬프트 Style Custom (%d/%d)", custom, count)
    )
    -- 패드 모델 ModuleId, 서버 패드 표지판 없음
    local idsOk, signs = true, 0
    for _, id in { "A", "B", "C" } do
        if base.ModulePads["Pad" .. id]:GetAttribute("ModuleId") ~= id then
            idsOk = false
        end
        if kit.ModulePads["Pad" .. id]:GetAttribute("ModuleId") ~= id then
            idsOk = false
        end
    end
    for _, d in base.ModulePads:GetDescendants() do
        if d:IsA("BillboardGui") then
            signs += 1
        end
    end
    check(idsOk, "PadA/B/C 모델 Attribute ModuleId (BaseKit, Base)")
    check(signs == 0, "모듈 패드에 서버 BillboardGui 표지판 없음")
end

-- 건설 -----------------------------------------------------------------
print("[건설]")
local padAPrompt = base.ModulePads.PadA.Pad:FindFirstChildOfClass("ProximityPrompt")
local padBPrompt = base.ModulePads.PadB.Pad:FindFirstChildOfClass("ProximityPrompt")
local padCPrompt = base.ModulePads.PadC.Pad:FindFirstChildOfClass("ProximityPrompt")
-- 시작 에너지가 있으므로 부족 상황을 직접 만든다
ResourceState.patch(function(s)
    s.energy = Config.MODULES.A.cost.energy - 1
end)
signalFor(padAPrompt, "Triggered"):Fire(alice)
advance(0)
check(state().modules.A.status == "available", "에너지 부족이면 착공 안 됨")
check(
    string.find(lastSent("Notify").args[1], "자원이 부족합니다", 1, true) ~= nil,
    "부족 안내: " .. lastSent("Notify").args[1]
)
ResourceState.patch(function(s)
    s.energy = 1000
    s.water = 1000
    s.food = 1000
end)
signalFor(padAPrompt, "Triggered"):Fire(alice)
advance(0)
check(
    state().modules.A.status == "building" and state().energy == 940 and state().water == 980,
    "A 착공, 비용 차감"
)
check(base.ModulePads.PadA:FindFirstChild("Ghost") ~= nil, "건설 중 Ghost 표시")
check(padAPrompt.Enabled == false, "건설 중 프롬프트 비활성")
local dayStart = state().day
advance(Config.DAY_SECONDS * Config.MODULES.A.buildDays)
check(state().day == dayStart + 5 and state().modules.A.status == "active", "5일 뒤 A 가동")
check(
    base.ModulePads.PadA:FindFirstChild("Built") ~= nil
        and base.ModulePads.PadA:FindFirstChild("Ghost") == nil,
    "Built 표시, Ghost 숨김"
)
check(
    state().modules.B.status == "available" and padBPrompt.Enabled == true,
    "B 해금, 프롬프트 활성"
)
-- Habitat A 산소 구역
root.CFrame = base.ModulePads.PadA.OxygenZone.CFrame
advance(1)
check(lastSent("OxygenUpdate").args[3] == true, "Habitat A 안은 실내")
do
    local doorA = base.ModulePads.PadA.Built.Entry.Door
    local promptA = doorA:FindFirstChildOfClass("ProximityPrompt")
    check(
        doorA.CanCollide == true
            and promptA ~= nil
            and promptA.Enabled == true
            and promptA.ActionText == "열기",
        "완공된 Habitat A 문: 닫혀 있고 열기 프롬프트"
    )
end

signalFor(padBPrompt, "Triggered"):Fire(alice)
advance(Config.DAY_SECONDS * Config.MODULES.B.buildDays)
check(
    state().modules.B.status == "active" and state().modules.C.status == "available",
    "B 가동, C 해금"
)

-- 배속 ------------------------------------------------------------------
print("[배속]")
signalFor(speedRemote, "OnServerEvent"):Fire(bob, 3)
signalFor(speedRemote, "OnServerEvent"):Fire(bob, "2")
advance(0)
check(state().speed == 1, "잘못된 배속 무시")
signalFor(speedRemote, "OnServerEvent"):Fire(bob, 2)
advance(0)
check(state().speed == 2, "2배속 적용")
signalFor(speedRemote, "OnServerEvent"):Fire(bob, 1)
advance(0)
check(state().speed == 2, "1초 쿨다운 안의 재요청 무시")
local d0 = state().day
advance(Config.DAY_SECONDS)
check(state().day == d0 + 2, "2배속에서 10초에 2일 진행 (" .. (state().day - d0) .. ")")
signalFor(speedRemote, "OnServerEvent"):Fire(bob, 1)
advance(0)

-- 승리 ------------------------------------------------------------------
print("[승리]")
signalFor(padCPrompt, "Triggered"):Fire(alice)
advance(0)
check(state().modules.C.status == "building", "C 착공")
local restartRemote = dm:GetService("ReplicatedStorage").Remotes.RequestRestart
signalFor(restartRemote, "OnServerEvent"):Fire(bob)
advance(0)
check(state().phase == "playing", "진행 중 재시작 요청 무시")
local overBefore = countSent("GameOver")
advance(Config.DAY_SECONDS * Config.MODULES.C.buildDays)
check(state().phase == "won", "C 완공 즉시 승리")
local over = lastSent("GameOver")
check(countSent("GameOver") == overBefore + 1 and over.args[1].won == true, "GameOver won")
check(
    over.args[1].siteName == "Shackleton Rim"
        and over.args[1].waterTrips == 1
        and over.args[1].oxygenDeaths == 1,
    "결과 요약 수치"
)
print("        GameOver: day " .. over.args[1].day .. ", reason " .. over.args[1].reason)
local dayAtWin = state().day
advance(Config.DAY_SECONDS * 3)
check(state().day == dayAtWin, "승리 후 시계 정지")

-- 재시작과 타임아웃 -------------------------------------------------------
print("[재시작]")
humanoid.Sit = true
signalFor(restartRemote, "OnServerEvent"):Fire(bob)
advance(0)
check(humanoid.Sit == false, "재시작 전 전원 하차")
check(
    state().phase == "selecting" and state().day == 0 and state().energy == Config.START.energy,
    "재시작: selecting, 상태 초기화"
)
check(Workspace:FindFirstChild("Base") == nil, "재시작: Base 제거")
check(
    lastSent("SiteSelectionOpen").args[1].chooserUserId == 1,
    "재시작: 권한자 다시 지정"
)
advance(Config.SITE_SELECT_TIMEOUT + 0.1)
check(
    state().phase == "landing" and state().siteId == Config.DEFAULT_SITE_ID,
    "30초 미선택 시 패드 2"
)
check(#Workspace:GetChildren() > 0 and Workspace:FindFirstChild("Base") ~= nil, "새 Base 배치")
advance(Config.LANDING_SECONDS + 0.01)
check(
    state().phase == "playing" and math.abs(state().sunlight - 0.85) < 1e-9,
    "Pad2 일조율 0.85"
)
local base2 = Workspace.Base
check(#base2.SolarField.Panels:GetChildren() == 0, "새 게임 패널 0")

-- 부족 실패 -------------------------------------------------------------
print("[실패]")
-- 산소 영향을 없애려고 캐릭터를 착륙선 안으로
root.CFrame = base2.Lander.OxygenZone.CFrame
ResourceState.patch(function(s)
    s.water = 0
end)
advance(Config.DAY_SECONDS * 3)
check(state().phase == "lost", "물 0 상태 3일이면 실패")
over = lastSent("GameOver")
check(
    over.args[1].won == false and over.args[1].reason == "물이 3일 연속 바닥났습니다",
    "실패 사유: " .. over.args[1].reason
)

-- 리스폰하면 우주복을 다시 입힌다
do
    local reborn = Instance.new("Model")
    reborn.Name = "AliceCharacter2"
    local newRoot = Instance.new("Part")
    newRoot.Name = "HumanoidRootPart"
    newRoot.CFrame = CFrame.new(0, 60, 0)
    newRoot.Parent = reborn
    local newHumanoid = Instance.new("Humanoid")
    newHumanoid.Health = 100
    newHumanoid.Parent = reborn
    reborn.PrimaryPart = newRoot
    dressCasual(reborn, newRoot.CFrame)
    reborn.Parent = Workspace
    alice.Character = reborn
    alice.CharacterAdded:Fire(reborn)
    advance(1)
    local ok, why = suitOk(reborn)
    check(ok, "리스폰 후 우주복 재적용: " .. why)
end

-- 에어락 문 (재시작 후 새 기지 base2) -------------------------------------
print("[에어락]")
local function runAirlockChecks()
    local Airlock = loadModule(Server:FindFirstChild("Airlock"))
    local aliceRoot = alice.Character.HumanoidRootPart
    root.CFrame = CFrame.new(0, 500, 0) -- 이전 캐릭터는 멀리
    aliceRoot.CFrame = base2.Lander.OxygenZone.CFrame
    local door = base2.Lander.Entry.Door
    local prompt = door:FindFirstChildOfClass("ProximityPrompt")
    check(
        prompt ~= nil
            and prompt.ObjectText == "에어락"
            and prompt.ActionText == "열기"
            and prompt.HoldDuration == 0
            and prompt.MaxActivationDistance == 8
            and prompt.RequiresLineOfSight == false
            and prompt.Style == roblox.Enum.ProximityPromptStyle.Custom
            and prompt.Enabled == true,
        "착륙선 문 프롬프트: 에어락 / 열기, 즉시, 거리 8, Custom"
    )
    check(door.CanCollide == true and door.Transparency == 0, "닫힌 문은 막혀 있음")
    local total, openCount = Airlock.counts()
    check(total == 2 and openCount == 0, "에어락 문 2개 (착륙선, Habitat A), 모두 닫힘")
    local closedColor = door.Color
    local function isOpen()
        return door.CanCollide == false
            and math.abs(door.Transparency - 0.75) < 1e-6
            and door.Color ~= closedColor
            and prompt.Enabled == false
    end
    local function isClosed()
        return door.CanCollide == true
            and door.Transparency == 0
            and door.Color == closedColor
            and prompt.Enabled == true
    end
    local function toasts()
        local count, kind = 0, nil
        for _, entry in sent do
            if
                entry.name == "Notify"
                and entry.target == alice
                and entry.args[1] == Config.TEXTS.airlockOpened
            then
                count += 1
                kind = entry.args[2]
            end
        end
        return count, kind
    end
    signalFor(prompt, "Triggered"):Fire(alice)
    local n1, kind = toasts()
    check(isOpen(), "열기: 반투명 0.75, 충돌 꺼짐, 밝은 색, 프롬프트 숨김")
    check(n1 == 1 and kind == "info", "처음 문을 열면 안내 토스트(info) 한 번")
    advance(Config.AIRLOCK.openSeconds + 0.1)
    check(isClosed(), "6초 뒤 다시 닫힘")
    -- 문 범위에 캐릭터가 있으면 닫지 않는다
    signalFor(prompt, "Triggered"):Fire(alice)
    aliceRoot.CFrame = door.CFrame
    advance(Config.AIRLOCK.openSeconds + 2)
    check(isOpen(), "문 범위에 캐릭터가 있으면 열린 채 기다림")
    aliceRoot.CFrame = base2.Lander.OxygenZone.CFrame
    advance(Config.AIRLOCK.closeRetrySeconds + 0.1)
    check(isClosed(), "캐릭터가 비키면 닫힘")
    -- 착륙선 스폰 지점(문에서 2 안쪽)에 서 있는 캐릭터는 문을 붙잡지 않는다
    local spawnPart = base2.Lander.SpawnPoint
    aliceRoot.CFrame = spawnPart.CFrame * CFrame.new(0, spawnPart.Size.Y / 2 + 3, 0)
    signalFor(prompt, "Triggered"):Fire(alice)
    advance(Config.AIRLOCK.openSeconds + 0.1)
    check(isClosed(), "스폰 지점에 서 있어도 6초 뒤 닫힘")
    check(toasts() == 1, "두 번째부터는 안내 토스트 없음")
    -- 문과 콘솔 사이 거리: 문 앞에서는 콘솔 프롬프트(거리 8)가 닿지 않는다
    local console = base2.Lander.RoverConsole
    local consolePrompt2 = console:FindFirstChildOfClass("ProximityPrompt")
    check(
        consolePrompt2 ~= nil
            and consolePrompt2.MaxActivationDistance == 8
            and (console.CFrame.Position - door.CFrame.Position).Magnitude >= 14,
        "복구 콘솔 프롬프트 거리 8, 문 중심에서 14 이상"
    )
end
runAirlockChecks()

-- 마지막 플레이어 퇴장 ---------------------------------------------------
print("[퇴장]")
local function leave(player)
    signalFor(PlayersService, "PlayerRemoving"):Fire(player)
    advance(0)
    table.remove(players, table.find(players, player))
end
leave(bob)
check(
    state().phase == "lost" and Workspace:FindFirstChild("Base") ~= nil,
    "한 명 남으면 그대로"
)
local opensBefore = countSent("SiteSelectionOpen")
leave(alice)
check(
    state().phase == "selecting" and Workspace:FindFirstChild("Base") == nil,
    "마지막 플레이어 퇴장 시 selecting으로 초기화"
)
check(
    countSent("SiteSelectionOpen") == opensBefore,
    "나간 플레이어를 권한자로 지정하지 않음"
)
-- 선택 중 마지막 플레이어가 나가면 타이머 취소
table.insert(players, alice)
signalFor(PlayersService, "PlayerAdded"):Fire(alice)
advance(0)
check(
    lastSent("SiteSelectionOpen").args[1].chooserUserId == 1,
    "다시 들어오면 권한자 지정"
)
advance(10)
leave(alice)
advance(Config.SITE_SELECT_TIMEOUT + 1)
check(
    state().phase == "selecting" and Workspace:FindFirstChild("Base") == nil,
    "선택 중 퇴장하면 타이머 취소 (자동 착륙 없음)"
)

-- KitImports 간편 경로 -----------------------------------------------------
print("[KitImports]")
local EPS = 1e-3

local function attrString(inst)
    local keys = {}
    for key, value in inst:GetAttributes() do
        if string.sub(key, 1, 2) ~= "__" then
            table.insert(keys, key .. "=" .. tostring(value))
        end
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

-- 판정과 로직이 쓰는 인스턴스만 모은 구조 서명 (외형 파트는 제외)
local LOGIC_PATHS = {
    "Origin",
    "Lander",
    "Lander.Floor",
    "Lander.SpawnPoint",
    "Lander.OxygenZone",
    "Lander.RoverConsole",
    "Rover",
    "Rover.Chassis",
    "Rover.DriverSeat",
    "Rover.WaterTankBox",
    "Rover.WheelFL",
    "Rover.WheelFR",
    "Rover.WheelRL",
    "Rover.WheelRR",
    "Rover.KnuckleFL",
    "Rover.KnuckleFR",
    "SolarField",
    "SolarField.InstallPad",
    "SolarField.Slots",
    "ModulePads",
    "ModulePads.PadA",
    "ModulePads.PadA.Pad",
    "ModulePads.PadA.Ghost",
    "ModulePads.PadA.Built",
    "ModulePads.PadA.OxygenZone",
    "ModulePads.PadB",
    "ModulePads.PadB.Pad",
    "ModulePads.PadB.Ghost",
    "ModulePads.PadB.Built",
    "ModulePads.PadC",
    "ModulePads.PadC.Pad",
    "ModulePads.PadC.Ghost",
    "ModulePads.PadC.Built",
    "WaterTank",
}
local function signature(targetKit)
    local lines = {
        "BaseKit:"
            .. targetKit.ClassName
            .. ":primary="
            .. (targetKit.PrimaryPart and targetKit.PrimaryPart.Name or "nil"),
    }
    for _, path in LOGIC_PATHS do
        local inst = targetKit
        for segment in string.gmatch(path, "[^%.]+") do
            inst = inst and inst:FindFirstChild(segment)
        end
        if not inst then
            table.insert(lines, path .. ":MISSING")
        else
            local line = path .. ":" .. inst.ClassName .. ":" .. attrString(inst)
            if inst:IsA("Model") then
                line ..= ":primary=" .. (inst.PrimaryPart and inst.PrimaryPart.Name or "nil")
            end
            if inst:IsA("BasePart") then
                line ..= ":anchored=" .. tostring(inst.Anchored)
            end
            table.insert(lines, line)
        end
    end
    local hingeLines = {}
    for _, d in targetKit.Rover:GetDescendants() do
        if d:IsA("HingeConstraint") then
            table.insert(
                hingeLines,
                string.format(
                    "%s:%s:%s:%s->%s",
                    d.Name,
                    tostring(d.ActuatorType),
                    attrString(d),
                    d.Attachment0.Parent.Name,
                    d.Attachment1.Parent.Name
                )
            )
        end
    end
    table.sort(hingeLines)
    table.insert(lines, "slots=" .. #targetKit.SolarField.Slots:GetChildren())
    return table.concat(lines, "\n") .. "\n" .. table.concat(hingeLines, "\n")
end

local function boundsOf(model)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            local h = d.Size / 2
            for _, sx in { -1, 1 } do
                for _, sy in { -1, 1 } do
                    for _, sz in { -1, 1 } do
                        local p = d.CFrame * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
                        lo = Vector3.new(
                            math.min(lo.X, p.X),
                            math.min(lo.Y, p.Y),
                            math.min(lo.Z, p.Z)
                        )
                        hi = Vector3.new(
                            math.max(hi.X, p.X),
                            math.max(hi.Y, p.Y),
                            math.max(hi.Z, p.Z)
                        )
                    end
                end
            end
        end
    end
    return lo, hi
end
local function boxContains(part, lo, hi)
    local c, h = part.CFrame.Position, part.Size / 2
    return c.X - h.X <= lo.X + EPS
        and c.Y - h.Y <= lo.Y + EPS
        and c.Z - h.Z <= lo.Z + EPS
        and c.X + h.X >= hi.X - EPS
        and c.Y + h.Y >= hi.Y - EPS
        and c.Z + h.Z >= hi.Z - EPS
end
local function allParts(model, predicate)
    local count = 0
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            count += 1
            if not predicate(d) then
                return false
            end
        end
    end
    return count > 0
end

-- 두 번째 place에 가짜 메시를 넣고 DevMap만 다시 돌린다
local dm2 = roblox.deserializePlace(fs.readFile(placePath))
local importWarnings = {}
local loadModule2, makeEnv2 = makeLoader(dm2, importWarnings)
local Workspace2 = dm2:GetService("Workspace")
local ServerStorage2 = dm2:GetService("ServerStorage")
-- 디자이너가 둔 Sky (KeepSky 없음): 덮어써야 한다
local designerSky2 = Instance.new("Sky")
designerSky2.MoonTextureId = "rbxassetid://999"
designerSky2.StarCount = 10
designerSky2.Parent = dm2:GetService("Lighting")
local importsFolder = Instance.new("Folder")
importsFolder.Name = "KitImports"
importsFolder.Parent = Workspace2
local function fakeModel(name, specs)
    local m = Instance.new("Model")
    m.Name = name
    for i, spec in specs do
        local p = Instance.new("Part")
        p.Name = name .. "Part" .. i
        p.Size = spec[1]
        p.CFrame = CFrame.new(spec[2])
        p.Anchored = false
        p.CanCollide = true
        p.Parent = m
    end
    m.Parent = importsFolder
    return m
end
-- Rover: 실제 키트 비율 4.58 x 4.88(안테나 포함 높이) x 6.56 (폭, 높이, 길이)
local roverSource = fakeModel("Rover", {
    { Vector3.new(4.58, 3.6, 6.56), Vector3.new(100, 50, 0) }, -- 차체: y 48.2 ~ 51.8
    { Vector3.new(0.3, 1.28, 0.3), Vector3.new(100, 52.44, 1) }, -- 안테나: y 51.8 ~ 53.08
})
-- Lander: House Cylinder 비율 5.6 x 4.3 x 5.6 (다리 달린 돔)
fakeModel("Lander", {
    { Vector3.new(5.6, 3.3, 5.6), Vector3.new(-50, 2.65, 0) },
    { Vector3.new(0.4, 1, 0.4), Vector3.new(-47.6, 0.5, 2.4) },
})
fakeModel("HabitatA", {
    { Vector3.new(40, 10, 30), Vector3.new(0, 5, 200) },
    { Vector3.new(10, 4, 10), Vector3.new(0, 12, 200) },
})
-- Panel: 단일 파트 (MeshPart 대용), 키트 비율 1.29 x 1.10 x 1.67 (긴 축이 Z)
local panelSource = Instance.new("Part")
panelSource.Name = "Panel"
panelSource.Size = Vector3.new(1.29, 1.10, 1.67)
panelSource.CFrame = CFrame.new(0, 30, 30)
panelSource.Parent = importsFolder
fakeModel("Rock1", { { Vector3.new(2, 1.5, 2.5), Vector3.zero } })
fakeModel("Rock2", { { Vector3.new(3, 2, 1), Vector3.zero } })
local emptyHabitat = Instance.new("Model")
emptyHabitat.Name = "HabitatB" -- 빈 모델 -> 그레이박스
emptyHabitat.Parent = importsFolder
fakeModel("Rovr", { { Vector3.one, Vector3.zero } }) -- 이름 오타
-- 장식 10종 (원본 크기는 키트 유닛 수준으로 작게)
fakeModel("Planet", { { Vector3.new(3.8, 3.8, 3.8), Vector3.new(0, 80, 0) } })
fakeModel("IceCrystal", { { Vector3.new(1.5, 2.5, 1.2), Vector3.new(0, 90, 0) } })
fakeModel("WaterTank", { { Vector3.new(4, 4, 3.8), Vector3.new(0, 100, 0) } }) -- House Single 비율
fakeModel("Connector", { { Vector3.new(3.37, 2.2, 2.2), Vector3.new(0, 110, 0) } }) -- 긴 축 X
fakeModel("ConnectorElbow", { { Vector3.new(7.8, 2.2, 7.8), Vector3.new(0, 120, 0) } })
fakeModel("Pad", { { Vector3.new(6, 0.87, 6), Vector3.new(0, 130, 0) } })
fakeModel("Antenna", { { Vector3.new(0.3, 4, 0.3), Vector3.new(0, 140, 0) } })
fakeModel("Radar", { { Vector3.new(2, 1.5, 2), Vector3.new(0, 150, 0) } })
fakeModel("Crate", { { Vector3.new(0.9, 0.9, 0.9), Vector3.new(0, 160, 0) } })
fakeModel("Crop", { { Vector3.new(0.6, 1, 0.6), Vector3.new(0, 170, 0) } })
local roverSourceSize = roverSource.RoverPart1.Size
local roverSourceCFrame = roverSource.RoverPart1.CFrame

-- 두 번째 place도 서버 전체를 부팅한다 (Remotes.init -> DevMap.ensure -> GameFlow.start)
task.spawn(function()
    local main2 = dm2:GetService("ServerScriptService").Server.Main
    luau.load(
        main2.Source,
        { debugName = "Main2", environment = makeEnv2(main2), injectGlobals = false }
    )()
end)
advance(0)

local kitGrey = ServerStorage:FindFirstChild("BaseKit")
local kitImport = ServerStorage2:FindFirstChild("BaseKit")
check(kitImport ~= nil, "KitImports로 BaseKit 생성")
do
    local skies = 0
    for _, child in dm2:GetService("Lighting"):GetChildren() do
        if child:IsA("Sky") then
            skies += 1
        end
    end
    check(
        skies == 1
            and tostring(designerSky2.MoonTextureId) == "rbxasset://sky/sun.jpg"
            and designerSky2.StarCount == 3000
            and designerSky2.MoonAngularSize == 14,
        "기존 Sky(KeepSky 없음)는 덮어씀: 태양 텍스처, 별 3000"
    )
end
check(
    Workspace2:FindFirstChild("KitImports") == nil
        and ServerStorage2:FindFirstChild("KitImports") ~= nil,
    "KitImports 폴더를 ServerStorage로 옮김"
)
check(
    roverSource.RoverPart1.Size == roverSourceSize
        and roverSource.RoverPart1.CFrame == roverSourceCFrame,
    "원본 KitImports는 바뀌지 않음"
)
local sigGrey, sigImport = signature(kitGrey), signature(kitImport)
check(sigGrey == sigImport, "판정 구조 서명이 그레이박스와 동일")
if sigGrey ~= sigImport then
    print("--- 그레이박스\n" .. sigGrey .. "\n--- KitImports\n" .. sigImport)
end
local function warned(part)
    for _, w in importWarnings do
        if string.find(w, part, 1, true) then
            return true
        end
    end
    return false
end
check(warned("'Rovr'"), "이름 오타 경고")
check(warned("'HabitatB' 안에 파트가 없어"), "빈 모델 경고")
check(#importWarnings == 2, "경고는 오타와 빈 모델 두 줄 (" .. #importWarnings .. ")")

-- 로버 외형
local rover2 = kitImport.Rover
local visual = rover2:FindFirstChild("Visual")
check(visual ~= nil and visual:IsA("Model"), "Rover.Visual 메시")
check(
    allParts(visual, function(p)
        return p.Anchored == false
            and p.Massless == true
            and p.CanCollide == false
            and p.CanQuery == false
    end),
    "로버 메시: 비고정, Massless, CanCollide/CanQuery 꺼짐"
)
local weldedToChassis = 0
for _, w in rover2.Chassis:GetChildren() do
    if w:IsA("WeldConstraint") and w.Part1 and w.Part1:IsDescendantOf(visual) then
        weldedToChassis += 1
    end
end
check(
    weldedToChassis == #visual:GetChildren(),
    "로버 메시 파트 전부 섀시에 용접 (" .. weldedToChassis .. ")"
)
do
    local vLo, vHi = boundsOf(visual)
    local vSize = vHi - vLo
    local roverScale = 11 / 6.56
    check(
        math.abs(vSize.Z - 11) < 0.01
            and math.abs(vSize.X - 4.58 * roverScale) < 0.01
            and math.abs(vSize.Y - 4.88 * roverScale) < 0.01,
        string.format(
            "로버 메시: 앞뒤 길이 11 기준 균일 스케일, 높이 제한 없음 (%.2f x %.2f x %.2f)",
            vSize.X,
            vSize.Y,
            vSize.Z
        )
    )
    local seat2 = rover2.DriverSeat
    local chassis2 = rover2.Chassis
    local seatHeight = seat2.CFrame.Position.Y - vLo.Y
    local fromFront = seat2.CFrame.Position.Z - vLo.Z -- 앞쪽 = -Z
    check(
        math.abs(seatHeight - math.min(vSize.Y * 0.35, 4.5)) < EPS
            and math.abs(fromFront - vSize.Z * 0.35) < EPS
            and math.abs(seat2.CFrame.Position.X - chassis2.CFrame.Position.X) < EPS
            and seat2.Transparency == 1,
        string.format(
            "DriverSeat 캐빈 안: 앞에서 길이의 %.0f%%, 바닥에서 높이의 %.0f%%, 투명",
            fromFront / vSize.Z * 100,
            seatHeight / vSize.Y * 100
        )
    )
    local wheelHalf = rover2.WheelFL.Size.X / 2
    local track = math.abs(rover2.WheelFL.CFrame.Position.X - chassis2.CFrame.Position.X)
    check(
        math.abs(track - (vSize.X / 2 - wheelHalf)) < EPS
            and chassis2.Size.X / 2 <= track - wheelHalf + EPS,
        string.format(
            "바퀴 간격이 메시 폭에 맞고 섀시는 바퀴 사이 (중심에서 %.2f)",
            track
        )
    )
end
check(
    rover2.Chassis.Transparency == 1 and rover2.WheelFL.Transparency == 1,
    "리그 섀시와 바퀴는 숨김"
)

-- 착륙선 외형
local lander2 = kitImport.Lander
local landerVisual = lander2:FindFirstChild("Visual")
check(landerVisual ~= nil, "Lander.Visual 메시")
check(
    allParts(landerVisual, function(p)
        return p.Anchored and not p.CanCollide
    end),
    "착륙선 메시: 고정, 충돌 없음 (안으로 걸어 들어감)"
)
local lLo, lHi = boundsOf(landerVisual)
do
    local ok, why = entryOk(lander2, 9)
    check(
        ok,
        "메시 착륙선 출입: 문, 프레임, AIRLOCK 표지, 8각형 충돌 벽(정면 5 비움), 내부 빛: "
            .. why
    )
    check(
        lander2:FindFirstChild("Airlock") == nil,
        "메시 착륙선: 통로 튜브, 문 판, 범위 링 없음"
    )
    local zone = lander2.OxygenZone
    local center = (lLo + lHi) / 2
    local inside = Vector3.new(center.X, lLo.Y + 3, center.Z)
    local besideDome = Vector3.new(lHi.X + 2, lLo.Y + 3, center.Z)
    check(boxContains(zone, inside, inside), "메시 착륙선: 돔 내부는 산소 구역")
    check(
        not boxContains(zone, besideDome, besideDome),
        "메시 착륙선: 돔 옆은 산소 구역 아님"
    )
    local door = lander2.Entry.Door
    check(
        math.abs(door.CFrame.Position.Z - (lLo.Z + 0.5)) < 1e-3
            and math.abs(door.CFrame.Position.X - center.X) < 1e-3,
        "문은 돔 정면(-Z) 가운데, 앞면에서 0.5 안쪽"
    )
    -- 꼭대기 안테나, 왼쪽 지상 레이더
    local aLo3, aHi3 = boundsOf(lander2.RoofAntenna)
    local antennaCenter = (aLo3 + aHi3) / 2
    check(
        math.abs(aLo3.Y - lHi.Y) < EPS
            and math.abs(antennaCenter.X - center.X) < 1e-3
            and math.abs(antennaCenter.Z - center.Z) < 1e-3,
        "안테나는 돔 꼭대기 중심"
    )
    local radar = lander2:FindFirstChild("GroundRadar")
    local rLo3, rHi3 = boundsOf(radar)
    check(
        lander2:FindFirstChild("RoofRadar") == nil
            and math.abs(rLo3.Y - -0.5) < EPS
            and rHi3.X < lLo.X
            and rHi3.Y - rLo3.Y <= 2.5 + EPS,
        "레이더는 착륙선 왼쪽 바닥의 지상 장비 (높이 2.5 이하)"
    )
end
do
    local size = lHi - lLo
    check(
        math.abs(size.X - 14) < 0.01 and math.abs(size.Y - 4.3 * 14 / 5.6) < 0.01,
        string.format(
            "착륙선 메시: 폭 14, 높이는 비율대로 (%.2f x %.2f x %.2f)",
            size.X,
            size.Y,
            size.Z
        )
    )
    -- 콘솔은 왼쪽 앞 바깥, 상자는 착륙선 뒤: 착륙선 충돌 벽 밖
    local wallOut = 0.5
    local function outsideLander(lo, hi)
        return lo.X > lHi.X + wallOut
            or hi.X < lLo.X - wallOut
            or lo.Z > lHi.Z + wallOut
            or hi.Z < lLo.Z - wallOut
    end
    local console = lander2.RoverConsole
    local cLo3 = console.CFrame.Position - console.Size / 2
    local cHi3 = console.CFrame.Position + console.Size / 2
    local crLo, crHi = boundsOf(kitImport.Crates)
    check(
        outsideLander(cLo3, cHi3)
            and cHi3.X < lLo.X
            and outsideLander(crLo, crHi)
            and crLo.Z > lHi.Z + wallOut,
        "복구 콘솔은 착륙선 왼쪽 바깥, 상자는 착륙선 뒤"
    )
    kitHeightChecks(kitImport, "메시 키트")
end
-- 스폰은 착륙선 내부 (문에서 2 안쪽)
local spawnPart = lander2.SpawnPoint
local spawnRoot = spawnPart.CFrame.Position
    + Vector3.new(0, spawnPart.Size.Y / 2 + Config.SPAWN_HEIGHT_OFFSET, 0)
check(
    boxContains(lander2.OxygenZone, spawnRoot, spawnRoot)
        and math.abs(spawnPart.CFrame.Position.Z - (lander2.Entry.Door.CFrame.Position.Z + 2))
            < 1e-3,
    "스폰 지점이 착륙선 내부, 문에서 2 안쪽"
)

-- Habitat A 외형 (Built 안의 출입 구조 Entry는 따로 본다)
do
    local padA2 = kitImport.ModulePads.PadA
    local builtA = padA2.Built
    local airlock = builtA:FindFirstChild("Entry")
    local function habitatOnly(fn)
        for _, d in builtA:GetDescendants() do
            if d:IsA("BasePart") and not (airlock and d:IsDescendantOf(airlock)) then
                fn(d)
            end
        end
    end
    local aLo = Vector3.new(math.huge, math.huge, math.huge)
    local aHi = -aLo
    local allStatic, count = true, 0
    habitatOnly(function(part)
        count += 1
        local h = part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local p = part.CFrame * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
                    aLo = Vector3.new(
                        math.min(aLo.X, p.X),
                        math.min(aLo.Y, p.Y),
                        math.min(aLo.Z, p.Z)
                    )
                    aHi = Vector3.new(
                        math.max(aHi.X, p.X),
                        math.max(aHi.Y, p.Y),
                        math.max(aHi.Z, p.Z)
                    )
                end
            end
        end
        if not part.Anchored or part.CanCollide then
            allStatic = false
        end
    end)
    local padPart = padA2.Pad
    local padTop = padPart.CFrame.Position.Y + padPart.Size.Y / 2
    check(math.abs(aLo.Y - padTop) < EPS, "Habitat A 바닥이 Pad 윗면")
    check(
        aHi.X - aLo.X <= padPart.Size.X + EPS and aHi.Z - aLo.Z <= padPart.Size.Z + EPS,
        string.format("Habitat A 폭이 패드 안 (%.1f x %.1f)", aHi.X - aLo.X, aHi.Z - aLo.Z)
    )
    check(
        count > 0 and allStatic,
        "Habitat A 메시: 고정, 충돌 없음 (안으로 걸어 들어감)"
    )
    check(
        allParts(padA2.Ghost, function(p)
            return math.abs(p.Transparency - Config.GHOST_TRANSPARENCY) < EPS
                and p.CanCollide == false
        end),
        "Ghost: 같은 메시, 투명도 0.7, CanCollide 꺼짐"
    )
    local ok, why = entryOk(builtA, 5)
    check(
        ok
            and padA2.Ghost:FindFirstChild("Entry") == nil
            and builtA:FindFirstChild("Airlock") == nil,
        "Habitat A 출입 구조(문, 4면 충돌 벽, 내부 빛)는 Built 안, Ghost에는 없음: "
            .. why
    )
    local center = (aLo + aHi) / 2
    local inside = Vector3.new(center.X, aLo.Y + 3, center.Z)
    local besideHabitat = Vector3.new(aHi.X + 2, aLo.Y + 3, center.Z)
    check(
        boxContains(padA2.OxygenZone, inside, inside),
        "Habitat A: 건물 내부는 산소 구역"
    )
    check(
        not boxContains(padA2.OxygenZone, besideHabitat, besideHabitat),
        "Habitat A: 건물 옆(벽 밖)은 산소 구역 아님"
    )
    -- 문은 패드 앞(-Z), Farm B는 +Z 쪽이라 A-B 연결 통로와 겹치지 않는다
    local door = builtA.Entry.Door
    local padB = kitImport.ModulePads.PadB.Pad.CFrame.Position
    check(
        door.CFrame.Position.Z < center.Z and padB.Z > aHi.Z,
        string.format(
            "Habitat A 문은 앞쪽(z %.1f), Farm B는 뒤쪽(z %.1f): A-B 통로와 겹치지 않음",
            door.CFrame.Position.Z,
            padB.Z
        )
    )
end
check(
    kitImport.ModulePads.PadB.Built:FindFirstChild("Greenhouse") ~= nil,
    "빈 HabitatB는 그레이박스"
)

-- 패널 원본
local panel2 = ServerStorage2:FindFirstChild("PanelTemplate")
local pLo, pHi = boundsOf(panel2)
check(panel2.PrimaryPart ~= nil, "PanelTemplate PrimaryPart")
check(
    pHi.X - pLo.X <= 5 + EPS and pHi.Z - pLo.Z <= 4 + EPS and pHi.X - pLo.X >= pHi.Z - pLo.Z,
    string.format(
        "패널이 슬롯 크기 안, 긴 축 X (%.2f x %.2f)",
        pHi.X - pLo.X,
        pHi.Z - pLo.Z
    )
)
check(
    allParts(panel2, function(p)
        return p.Anchored and p.CanCollide == false
    end),
    "패널 메시: 고정, CanCollide 꺼짐"
)

-- 바위
local greyRocks = Workspace.DevTerrain.Boulders:GetChildren()
local importRocks = Workspace2.DevTerrain.Boulders:GetChildren()
-- 바위 위치는 기지 판 크기(메시 키트면 달라짐)를 피해 정해지므로 개수와 규칙만 비교한다
check(
    math.abs(#greyRocks - #importRocks) <= 10 and #importRocks >= 200,
    string.format("바위 수 비슷함 (그레이박스 %d, 메시 %d)", #greyRocks, #importRocks)
)
check(importRocks[1]:IsA("Model") and importRocks[1].Name == "Boulder", "바위가 Rock 메시")
do
    local importApron = kitImport:FindFirstChild("Apron")
    local nearest = math.huge
    for _, rock in importRocks do
        local lo, hi = boundsOf(rock)
        for i = 1, 4 do
            nearest = math.min(nearest, apronDistanceAt(importApron, i, (lo + hi) / 2, Workspace2))
        end
    end
    check(
        importApron ~= nil and nearest >= 6,
        string.format("메시 바위도 메시 키트 판 + 6 밖 (최소 %.1f)", nearest)
    )
end
check(
    importRocks[1]:FindFirstChild("Rock1Part1") ~= nil
        and importRocks[2]:FindFirstChild("Rock2Part1") ~= nil,
    "Rock1, Rock2 순환 사용"
)

check(
    Workspace2.DevTerrain:FindFirstChild("MoonGround") ~= nil,
    "Terrain이 없는 환경에서는 평평한 지면 Part로 대체"
)
check(
    allParts(importRocks[1], function(p)
        return p.Color == roblox.Color3.fromRGB(90, 88, 86)
            and p.Material == roblox.Enum.Material.Basalt
    end),
    "바위 메시도 회색 Basalt로 통일"
)

-- KitImports 장식 ---------------------------------------------------------
-- 최상위 지역 변수 한도(200)를 넘지 않도록 함수 안에서 돌린다
local function runDecorScenario()
    print("[KitImports 장식]")
    -- 행성
    local decor2 = Workspace2:FindFirstChild("Decor")
    local planet = decor2 and decor2:FindFirstChild("Planet")
    check(planet ~= nil, "Planet이 Workspace.Decor 아래")
    check(
        allParts(planet, function(p)
            return p.Anchored and not p.CanCollide and not p.CanTouch and not p.CanQuery
        end),
        "Planet: 고정, CanCollide/CanTouch/CanQuery 꺼짐"
    )
    -- 시작 시에는 기본 착륙지(Pad2)에서 가장 가까운 얼음 쪽 하늘 (메시 Planet은 지름 260으로 스케일)
    local function planetFrom(origin)
        local lo, hi = boundsOf(planet)
        local offset = (lo + hi) / 2 - origin
        local nearest, best = nil, math.huge
        for _, ice in Workspace2.IceSites:GetChildren() do
            local d =
                Vector3.new(ice.CFrame.Position.X - origin.X, 0, ice.CFrame.Position.Z - origin.Z)
            if d.Magnitude < best then
                nearest, best = d.Unit, d.Magnitude
            end
        end
        return math.max(hi.X - lo.X, hi.Y - lo.Y, hi.Z - lo.Z),
            offset.Magnitude,
            math.deg(math.asin(offset.Y / offset.Magnitude)),
            Vector3.new(offset.X, 0, offset.Z).Unit:Dot(nearest)
    end
    local diameter, distance, elevation, facing =
        planetFrom(Workspace2.LandingPads.Pad2.CFrame.Position)
    check(
        math.abs(diameter - 260) < 0.5
            and math.abs(distance - 900) < 0.5
            and math.abs(elevation - 20) < 0.1
            and facing > 0.999,
        string.format(
            "Planet 메시 지름 %.0f, 기본 착륙지에서 거리 %.0f, 고도 %.1f도, 가장 가까운 얼음 방향",
            diameter,
            distance,
            elevation
        )
    )
    check(
        allParts(planet, function(p)
            return p.Material == roblox.Enum.Material.Neon
                and p.Color == roblox.Color3.fromRGB(120, 170, 230)
        end),
        "Planet: Neon 재질로 자체 발광 (색 120, 170, 230)"
    )
    check(
        planet.ModelStreamingMode == roblox.Enum.ModelStreamingMode.Persistent,
        "Planet은 항상 스트리밍"
    )
    -- 얼음 결정
    local iceB = Workspace2.IceSites.Ice1
    local crystal = iceB:FindFirstChild("Crystal")
    check(
        iceB.Transparency == 1
            and crystal ~= nil
            and iceB:FindFirstChildOfClass("ProximityPrompt") ~= nil,
        "Ice Part 투명 + 자식 결정 메시, 프롬프트는 Part에 유지"
    )
    local cLo, cHi = boundsOf(crystal)
    check(
        cHi.X - cLo.X < iceB.Size.X and cHi.Z - cLo.Z < iceB.Size.Z,
        "결정 메시 바닥 넓이가 Part보다 작음"
    )
    local iceBottom = iceB.CFrame.Position.Y - iceB.Size.Y / 2
    check(
        math.abs(cLo.Y - iceBottom) < 1e-3 and math.abs(iceBottom - -1.5) < 1e-3,
        string.format(
            "결정 메시와 Ice Part 바닥이 지형 윗면 y -1.5 (결정 %.2f, Part %.2f)",
            cLo.Y,
            iceBottom
        )
    )
    -- 얼음 프롬프트는 Part 중심(지형 위 1.5)에 그대로라 로버 운전석에서 닿는다
    check(
        iceB.CFrame.Position.Y - iceBottom <= 2,
        "얼음 프롬프트 기준점이 지면 가까이 (로버 운전석에서 도달)"
    )
    check(
        allParts(crystal, function(p)
            return p.Anchored and p.CanCollide
        end),
        "결정 메시: 고정, CanCollide"
    )
    check(
        allParts(crystal, function(p)
            return p.Material == roblox.Enum.Material.Ice
                and p.Color == roblox.Color3.fromRGB(170, 225, 255)
                and math.abs(p.Transparency - 0.1) < 1e-6
        end),
        "결정 메시: 텍스처 없는 Ice 재질, 하늘색, 투명도 0.1"
    )
    do
        local glow = iceB:FindFirstChild("IceGlow")
        local light = glow and glow:FindFirstChildOfClass("PointLight")
        local cLo2, cHi2 = boundsOf(crystal)
        check(
            light ~= nil
                and light.Range == 18
                and ((iceB.CFrame * glow.CFrame).Position - (cLo2 + cHi2) / 2).Magnitude < 1e-3,
            "결정 메시 중심에 PointLight"
        )
    end
    -- 물탱크
    local tankB = kitImport.WaterTank
    local tankVisual = tankB:FindFirstChild("Visual")
    check(tankB.Transparency == 1 and tankVisual ~= nil, "WaterTank Part 투명 + 메시 교체")
    local tLo, tHi = boundsOf(tankVisual)
    check(
        tHi.X - tLo.X <= 7 + EPS
            and tHi.Y - tLo.Y <= 7 + EPS
            and tHi.Z - tLo.Z <= 7 + EPS
            and math.max(tHi.X - tLo.X, tHi.Y - tLo.Y, tHi.Z - tLo.Z) > 7 - EPS,
        string.format(
            "물탱크 메시 크기 %.1f x %.1f x %.1f",
            tHi.X - tLo.X,
            tHi.Y - tLo.Y,
            tHi.Z - tLo.Z
        )
    )
    -- 패드 링
    local padRingA = kitImport.ModulePads.PadA.Pad:FindFirstChild("Ring")
    local installRing = kitImport.SolarField.InstallPad:FindFirstChild("Ring")
    check(padRingA ~= nil and installRing ~= nil, "PadA와 InstallPad에 링 메시")
    local rLo, rHi = boundsOf(padRingA)
    local padAPart = kitImport.ModulePads.PadA.Pad
    check(
        math.abs(rHi.Y - (padAPart.CFrame.Position.Y + padAPart.Size.Y / 2 + 0.1)) < EPS
            and rHi.X - rLo.X <= padAPart.Size.X + EPS,
        "링이 패드 크기 안, 윗면은 패드 윗면 바로 위 (Ghost와 겹치지 않게 묻음)"
    )
    -- 착륙선 안테나, 레이더, 콘솔 안테나
    local landerB = kitImport.Lander
    check(
        landerB:FindFirstChild("RoofAntenna") ~= nil
            and landerB:FindFirstChild("GroundRadar") ~= nil
            and landerB:FindFirstChild("ConsoleAntenna") ~= nil,
        "착륙선 꼭대기 안테나, 지상 레이더, 콘솔 안테나"
    )
    check(
        allParts(landerB.RoofAntenna, function(p)
            return p.Anchored and not p.CanCollide
        end),
        "안테나: 고정, CanCollide 꺼짐"
    )
    local aLo2, aHi2 = boundsOf(landerB.RoofAntenna)
    local _, landerTop = boundsOf(landerB.Visual)
    check(
        math.abs(aLo2.Y - landerTop.Y) < EPS and aHi2.Y - aLo2.Y <= 2.5 + EPS,
        "안테나가 착륙선 위, 높이 2.5 이하"
    )
    local consolePanel = landerB.ConsolePanel
    local consoleTop = consolePanel.CFrame.Position.Y + consolePanel.Size.Y / 2
    local caLo, caHi = boundsOf(landerB.ConsoleAntenna)
    check(
        math.abs(caLo.Y - consoleTop) < EPS and caHi.Y - caLo.Y <= 1.5 + EPS,
        "콘솔 안테나가 콘솔 조작판 위, 높이 1.5 이하"
    )
    local roofDecor = 0
    for _, id in { "B", "C" } do
        local built = kitImport.ModulePads["Pad" .. id].Built
        for _, d in built:GetDescendants() do
            if d.Name == "RoofAntenna" or d.Name == "RoofRadar" then
                roofDecor += 1
            end
        end
    end
    check(roofDecor == 0, "Habitat B, C 지붕에는 장식 없음")
    -- 상자
    local crates = kitImport:FindFirstChild("Crates")
    check(crates ~= nil and #crates:GetChildren() == 4, "상자 4개")
    local spawnB = landerB.SpawnPoint.CFrame.Position
    local cratesClear = true
    for _, crate in crates:GetChildren() do
        local lo, hi = boundsOf(crate)
        if hi.Y - lo.Y > 3 + EPS then
            cratesClear = false
        end
        local center = (lo + hi) / 2
        if
            (Vector3.new(center.X, 0, center.Z) - Vector3.new(spawnB.X, 0, spawnB.Z)).Magnitude < 10
        then
            cratesClear = false
        end
        if
            not allParts(crate, function(p)
                return p.Anchored and p.CanCollide
            end)
        then
            cratesClear = false
        end
    end
    check(cratesClear, "상자: 크기 3 이하, 고정, CanCollide, 스폰 지점에서 떨어짐")

    -- 게임을 진행해 A, B를 완공시키고 연결 통로와 작물을 확인
    local carol = makePlayer("Carol", 3)
    table.insert(players, carol)
    local Players2 = dm2:GetService("Players")
    signalFor(Players2, "PlayerAdded"):Fire(carol)
    advance(0)
    local remotes2 = dm2:GetService("ReplicatedStorage").Remotes
    signalFor(remotes2.SelectSite, "OnServerEvent"):Fire(carol, 1)
    advance(0)
    advance(Config.LANDING_SECONDS + 0.01)
    local Server2 = dm2:GetService("ServerScriptService").Server
    local ResourceState2 = loadModule2(Server2.ResourceState)
    check(ResourceState2.get().phase == "playing", "두 번째 place도 playing")
    do
        -- 착륙지가 정해지면 그 기지에서 가장 가까운 얼음 쪽 하늘로 다시 조준
        local baseOrigin = Workspace2.Base:GetPivot().Position
        local planetModel = Workspace2.Decor.Planet
        local lo, hi = boundsOf(planetModel)
        local offset = (lo + hi) / 2 - baseOrigin
        local ice = Workspace2.IceSites.Ice1.CFrame.Position
        local heading = Vector3.new(ice.X - baseOrigin.X, 0, ice.Z - baseOrigin.Z).Unit
        check(
            math.abs(offset.Magnitude - 900) < 0.5
                and math.abs(math.deg(math.asin(offset.Y / offset.Magnitude)) - 20) < 0.1
                and Vector3.new(offset.X, 0, offset.Z).Unit:Dot(heading) > 0.999,
            "착륙 뒤 행성: 기지에서 거리 900, 고도 20도, 가장 가까운 얼음(Ice1) 방향"
        )
    end
    do
        local field = Workspace2.Base.SolarField
        signalFor(field.InstallPad:FindFirstChildOfClass("ProximityPrompt"), "Triggered"):Fire(
            carol
        )
        advance(0)
        local placed = field.Panels:FindFirstChild("Panel1")
        check(placed ~= nil, "KitImports 패널 1장 설치")
        local fillX, fillZ = panelFill(placed, field.Slots.Slot1)
        check(
            fillX >= 0.8 and fillZ >= 0.8 and fillX <= 1 and fillZ <= 1,
            string.format(
                "KitImports 패널 바닥이 슬롯의 %.0f%% x %.0f%% (80%% 이상)",
                fillX * 100,
                fillZ * 100
            )
        )
    end
    ResourceState2.patch(function(st)
        st.energy = 1000
        st.water = 1000
        st.food = 1000
    end)
    local baseB = Workspace2.Base
    local function padPrompt(id)
        return baseB.ModulePads["Pad" .. id].Pad:FindFirstChildOfClass("ProximityPrompt")
    end
    signalFor(padPrompt("A"), "Triggered"):Fire(carol)
    advance(Config.DAY_SECONDS * Config.MODULES.A.buildDays)
    check(ResourceState2.get().modules.A.status == "active", "A 완공")
    local kitDecor = baseB:FindFirstChild("KitDecor")
    check(
        kitDecor == nil or kitDecor:FindFirstChild("ConnectorAB") == nil,
        "A만 완공이면 통로 없음"
    )
    signalFor(padPrompt("B"), "Triggered"):Fire(carol)
    advance(Config.DAY_SECONDS * Config.MODULES.B.buildDays)
    check(ResourceState2.get().modules.B.status == "active", "B 완공")
    kitDecor = baseB:FindFirstChild("KitDecor")
    local connector = kitDecor and kitDecor:FindFirstChild("ConnectorAB")
    check(
        connector ~= nil and #connector:GetChildren() >= 1,
        "A, B 완공 후 Connector 세그먼트 "
            .. (connector and #connector:GetChildren() or 0)
            .. "개"
    )
    -- 통로가 두 Built 사이에 있는지
    local builtLoA, builtHiA = boundsOf(baseB.ModulePads.PadA.Built)
    local builtLoB, builtHiB = boundsOf(baseB.ModulePads.PadB.Built)
    local segLo, segHi = boundsOf(connector)
    local between = true
    for _, segmentModel in connector:GetChildren() do
        local lo, hi = boundsOf(segmentModel)
        local width = math.min(hi.X - lo.X, hi.Z - lo.Z)
        if math.abs(width - 4) > 0.05 then
            between = false
        end
    end
    -- A에서 B로 가는 축에 투영해 통로가 두 건물 가장자리 사이 틈을 정확히 채우는지
    local centerA = (builtLoA + builtHiA) / 2
    local centerB = (builtLoB + builtHiB) / 2
    local dir = Vector3.new(centerB.X - centerA.X, 0, centerB.Z - centerA.Z).Unit
    local side = Vector3.new(-dir.Z, 0, dir.X)
    local function project(lo, hi, axis)
        local c, h = (lo + hi) / 2, (hi - lo) / 2
        local r = h.X * math.abs(axis.X) + h.Z * math.abs(axis.Z)
        local m = c.X * axis.X + c.Z * axis.Z
        return m - r, m + r
    end
    local _, edgeA = project(builtLoA, builtHiA, dir)
    local edgeB = project(builtLoB, builtHiB, dir)
    local segMin, segMax = project(segLo, segHi, dir)
    local segCenter = (segLo + segHi) / 2
    local lateral = (segCenter.X - centerA.X) * side.X + (segCenter.Z - centerA.Z) * side.Z
    check(
        between
            and math.abs(segMin - edgeA) < 0.05
            and math.abs(segMax - edgeB) < 0.05
            and math.abs(lateral) < 0.05,
        string.format(
            "통로 굵기 4, A 가장자리에서 B 가장자리까지 틈 %.1f studs를 채움",
            edgeB - edgeA
        )
    )
    check(
        allParts(connector, function(p)
            return p.Anchored and not p.CanCollide
        end),
        "통로: 고정, CanCollide 꺼짐"
    )
    local crops = kitDecor and kitDecor:FindFirstChild("CropsB")
    check(crops ~= nil and #crops:GetChildren() == 8, "B 완공 후 작물 8개")
    local cropsOk = true
    for _, crop in crops:GetChildren() do
        local lo, hi = boundsOf(crop)
        if math.max(hi.X - lo.X, hi.Y - lo.Y, hi.Z - lo.Z) > 2 + EPS then
            cropsOk = false
        end
        local center = (lo + hi) / 2
        -- 앞쪽(기지 기준 -Z) 반원: 기지 좌표로 바꿔 B 중심보다 앞인지
        local localCenter = baseB.PrimaryPart.CFrame:PointToObjectSpace(center)
        local localB = baseB.PrimaryPart.CFrame:PointToObjectSpace((builtLoB + builtHiB) / 2)
        if localCenter.Z >= localB.Z then
            cropsOk = false
        end
        if
            not allParts(crop, function(p)
                return p.Anchored and not p.CanCollide
            end)
        then
            cropsOk = false
        end
    end
    check(cropsOk, "작물: 크기 2 이하, 앞쪽 반원, 고정, CanCollide 꺼짐")
    -- C까지 완공: B-C 대각선 통로
    signalFor(padPrompt("C"), "Triggered"):Fire(carol)
    advance(Config.DAY_SECONDS * Config.MODULES.C.buildDays)
    check(ResourceState2.get().phase == "won", "C 완공으로 승리")
    local connectorBC = kitDecor:FindFirstChild("ConnectorBC")
    check(
        connectorBC ~= nil and #connectorBC:GetChildren() >= 1,
        "B, C 완공 후 대각선 통로 "
            .. (connectorBC and #connectorBC:GetChildren() or 0)
            .. "개"
    )
    local builtLoC, builtHiC = boundsOf(baseB.ModulePads.PadC.Built)
    local centerB2 = (builtLoB + builtHiB) / 2
    local centerC2 = (builtLoC + builtHiC) / 2
    local dirBC = Vector3.new(centerC2.X - centerB2.X, 0, centerC2.Z - centerB2.Z)
    local lengthBC = dirBC.Magnitude
    dirBC = dirBC.Unit
    local sideBC = Vector3.new(-dirBC.Z, 0, dirBC.X)
    local bcOk = true
    for _, segmentModel in connectorBC:GetChildren() do
        local lo, hi = boundsOf(segmentModel)
        local c = (lo + hi) / 2
        local along = (c.X - centerB2.X) * dirBC.X + (c.Z - centerB2.Z) * dirBC.Z
        local offsetBC = (c.X - centerB2.X) * sideBC.X + (c.Z - centerB2.Z) * sideBC.Z
        if math.abs(offsetBC) > 0.05 or along <= 0 or along >= lengthBC then
            bcOk = false
        end
    end
    check(
        bcOk,
        "대각선 통로 세그먼트가 B와 C 중심을 잇는 선 위, 두 건물 사이"
    )
    -- 재시작하면 Base 아래 장식은 함께 사라지고 행성은 남는다
    signalFor(remotes2.RequestRestart, "OnServerEvent"):Fire(carol)
    advance(0)
    check(
        Workspace2:FindFirstChild("Base") == nil
            and connector.Parent == nil
            and connectorBC.Parent == nil
            and crops.Parent == nil,
        "재시작 후 Base 아래 통로와 작물 제거"
    )
    check(Workspace2.Decor:FindFirstChild("Planet") ~= nil, "재시작 후에도 Planet 유지")
    check(
        #importWarnings == 2,
        "장식 추가 후에도 경고는 두 줄 (" .. #importWarnings .. ")"
    )
    table.remove(players, table.find(players, carol))
end
runDecorScenario()

print("")
print(
    string.format(
        "스모크 결과: 실패 %d, 스레드 오류 %d, 경고 %d",
        failures,
        threadErrors,
        #warnings
    )
)
for _, w in warnings do
    print("  경고: " .. w)
end
if failures > 0 or threadErrors > 0 then
    process.exit(1)
end
