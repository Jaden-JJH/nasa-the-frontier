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
    function s:Once(fn)
        local connection
        connection = self:Connect(function(...)
            connection.Disconnect()
            fn(...)
        end)
        return connection
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
roblox.implementProperty("Humanoid", "Died", function(inst)
    return signalFor(inst, "Died")
end)
roblox.implementProperty("ProximityPrompt", "Triggered", function(inst)
    return signalFor(inst, "Triggered")
end)
roblox.implementProperty("ProximityPrompt", "PromptButtonHoldBegan", function(inst)
    return signalFor(inst, "PromptButtonHoldBegan")
end)
roblox.implementProperty("ProximityPrompt", "PromptButtonHoldEnded", function(inst)
    return signalFor(inst, "PromptButtonHoldEnded")
end)
-- 효과음 (Sfx): Play와 Stop은 기록만 한다. soundLog = { { name, parent, looped } }
local soundLog = {}
roblox.implementMethod("Sound", "Play", function(inst)
    table.insert(
        soundLog,
        { name = inst.Name, parent = inst.Parent, looped = inst.Looped, sound = inst }
    )
end)
roblox.implementMethod("Sound", "Stop", function() end)
roblox.implementProperty("Sound", "Ended", function(inst)
    return signalFor(inst, "Ended")
end)
-- 로버 파손 감지 (RoverDamage): 파트 Touched, RunService.Heartbeat (스모크에서는 직접 Fire한다)
for _, className in { "Part", "VehicleSeat", "WedgePart", "MeshPart", "UnionOperation" } do
    roblox.implementProperty(className, "Touched", function(inst)
        return signalFor(inst, "Touched")
    end)
end
roblox.implementProperty("RunService", "Heartbeat", function(inst)
    return signalFor(inst, "Heartbeat")
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
-- 효과음 카탈로그: 아직 id가 0인 키는 테스트 id로 채워 연결 지점을 확인한다 (0이면 건너뜀은 [충전 도크]에서 따로 확인)
for _, spec in loadModule(Shared:FindFirstChild("SoundIds")) do
    if spec.id == 0 then
        spec.id = 1
    end
end
local function playedSound(key)
    for _, entry in soundLog do
        if entry.name == "Sfx_" .. key then
            return true
        end
    end
    return false
end
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
check(
    #Workspace.IceSites:GetChildren() == #Config.ICE_SITES and #Config.ICE_SITES == 8,
    "DevMap: 얼음 매장지 8곳"
)
do
    local attrsOk, total = true, 0
    for index, def in Config.ICE_SITES do
        local ice = Workspace.IceSites:FindFirstChild("Ice" .. index)
        total += def.deposit
        if
            not ice
            or ice:GetAttribute("Deposit") ~= def.deposit
            or ice:GetAttribute("DepositMax") ~= def.deposit
            or ice:GetAttribute("Difficulty") ~= def.difficulty
            or math.abs(ice.CFrame.Position.X - def.x) > 1e-3
            or math.abs(ice.CFrame.Position.Z - def.z) > 1e-3
        then
            attrsOk = false
        end
    end
    check(
        attrsOk,
        "Ice1..Ice8 위치와 Attribute Deposit, DepositMax, Difficulty = Config.ICE_SITES"
    )
    check(total >= 510 and total <= 520, "매장량 합계 " .. total .. " W (510 ~ 520)")
    -- mid는 어느 착륙 패드에서도 350 이상, hard는 500 이상 (패드 최근접 얼음은 예외: 첫 원정 설계)
    local distOk = true
    for index, def in Config.ICE_SITES do
        local p = Vector3.new(def.x, 0, def.z)
        for i = 1, 4 do
            local pad = Workspace.LandingPads["Pad" .. i].CFrame.Position
            local d = Vector3.new(pad.X - p.X, 0, pad.Z - p.Z).Magnitude
            local isCorridor = Config.DEV_MAP.padLayout[i].ice == index
            local minimum = if def.difficulty == "hard"
                then 500
                elseif def.difficulty == "mid" then 350
                else 0
            if not isCorridor and d < minimum - 1e-3 then
                distOk = false
            end
        end
    end
    check(distOk, "mid 매장지는 모든 패드에서 350 이상, hard는 500 이상")
end
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
check(
    #kit.SolarField.Slots:GetChildren() == Config.PANELS_TOTAL and Config.PANELS_TOTAL == 25,
    "Slots = PANELS_TOTAL 25개 (5 x 5)"
)
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
            and block.size.X >= 2600
            and block.size.Z >= 2200,
        "FillBlock 한 번: 2600 x 2200, 두께 24, 지형 윗면 y -1.5 (콘크리트 판보다 3 아래)"
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
    local bigCraters, outerCraters = 0, 0
    local mountainBalls, mountainIceHits = 0, 0 -- 산(Rock) 공: 얼음 반경 40 침범
    local edgePeakCenters = {} -- 가장자리 200 띠 안의 봉우리 축 (x, z 키)
    local bigNearPad = { 0, 0, 0, 0 }
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
        if ball.material == roblox.Enum.Material.Rock then
            -- 산 (2026-10-18): 원뿔에 내접하는 공을 축 위로 쌓은 봉우리. 크레이터, 언덕 판정에서 뺀다
            mountainBalls += 1
            for _, ice in ices do
                if flatDistance(ball.center, ice) < 40 + footprint - 1e-6 then
                    mountainIceHits += 1
                end
            end
            local fromEdge =
                math.min(1300 - math.abs(ball.center.X), 1100 - math.abs(ball.center.Z))
            if fromEdge <= 200 then
                edgePeakCenters[string.format("%.1f,%.1f", ball.center.X, ball.center.Z)] = true
            end
            continue
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
                    if ball.radius >= 30 then
                        bigNearPad[i] += 1
                    end
                end
            end
            if math.abs(ball.center.X) > 700 or math.abs(ball.center.Z) > 550 then
                outerCraters += 1
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
    -- 위험 경로 (2026-10-18): 각 패드에서 mid(650 안), hard(850 안) 매장지로 가는 직선 40 안의 크레이터
    local routeCraters = 0
    for _, crater in craterCircles do
        local onRoute = false
        for i = 1, 4 do
            local pad = Workspace.LandingPads["Pad" .. i].CFrame.Position
            for index, def in Config.ICE_SITES do
                local reach = if def.difficulty == "mid"
                    then Config.DEV_MAP.routeMidReach
                    elseif def.difficulty == "hard" then Config.DEV_MAP.routeHardReach
                    else 0
                local to = Vector3.new(def.x, 0, def.z)
                if
                    reach > 0
                    and Config.DEV_MAP.padLayout[i].ice ~= index
                    and flatDistance(pad, to) <= reach
                    and segmentDistance(crater.center, pad, to) <= 40
                then
                    onRoute = true
                end
            end
        end
        if onRoute then
            routeCraters += 1
        end
    end
    check(
        craters >= 75 and routeCraters >= 20,
        string.format(
            "크레이터 %d개 (75 이상), mid/hard 경로 직선 40 안 %d개 (20 이상)",
            craters,
            routeCraters
        )
    )
    check(
        craters >= 45 and smallCraters == 0 and bigCraters == 0,
        "크레이터 "
            .. craters
            .. "개 (45 이상), 반지름 12 미만 "
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
    -- 산 (2026-10-18): 가장자리 산맥과 내부 능선
    local DevMap = loadModule(Server:FindFirstChild("DevMap"))
    local mountains = DevMap.getMountains()
    local edgePeaks = 0
    for _ in edgePeakCenters do
        edgePeaks += 1
    end
    check(
        mountains ~= nil
            and mountains.edgePeaks >= 40
            and edgePeaks == mountains.edgePeaks
            and #mountains.ridges >= 4
            and #mountains.ridges <= 6,
        string.format(
            "산: 가장자리 200 띠 봉우리 %d개, 내부 능선 %d개 (4 ~ 6), Rock 공 %d개",
            edgePeaks,
            mountains and #mountains.ridges or 0,
            mountainBalls
        )
    )
    check(
        mountainIceHits == 0,
        "산 바닥이 얼음 반경 40 밖 (침범 " .. mountainIceHits .. ")"
    )
    do
        -- 능선 길이 120 ~ 250, 폭 40 ~ 70, 그리고 하나 이상이 패드 -> mid/hard 직선 경로를 가로지른다
        local function crosses(a, b, c, d)
            local function cross(o, p, q)
                return (p.X - o.X) * (q.Z - o.Z) - (p.Z - o.Z) * (q.X - o.X)
            end
            return cross(a, b, c) * cross(a, b, d) < 0 and cross(c, d, a) * cross(c, d, b) < 0
        end
        local shapeOk, crossing = true, 0
        for _, ridge in mountains.ridges do
            local length = flatDistance(ridge.a, ridge.b)
            if
                length < 120 - 1e-3
                or length > 250 + 1e-3
                or ridge.width < 40
                or ridge.width > 70
            then
                shapeOk = false
            end
            local hit = false
            for i = 1, 4 do
                local pad = Workspace.LandingPads["Pad" .. i].CFrame.Position
                for index, def in Config.ICE_SITES do
                    if def.difficulty ~= "easy" and Config.DEV_MAP.padLayout[i].ice ~= index then
                        if crosses(ridge.a, ridge.b, pad, Vector3.new(def.x, 0, def.z)) then
                            hit = true
                        end
                    end
                end
            end
            if hit then
                crossing += 1
            end
        end
        check(shapeOk, "능선 길이 120 ~ 250, 바닥 폭 40 ~ 70")
        check(
            crossing >= 1,
            "패드 -> mid/hard 직선 경로를 가로지르는 능선 " .. crossing .. "개"
        )
    end
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
        bigNearPad[1] >= 2 and bigNearPad[2] >= 2 and bigNearPad[3] >= 2 and bigNearPad[4] >= 2,
        string.format(
            "네 착륙지 모두 판 120 안 크레이터 중 반지름 30 이상 2개 이상 (%d, %d, %d, %d)",
            bigNearPad[1],
            bigNearPad[2],
            bigNearPad[3],
            bigNearPad[4]
        )
    )
    check(
        outerCraters > 0,
        "넓힌 지형(중심 1400 x 1100 밖)에도 크레이터 " .. outerCraters .. "개"
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
    local layers = { ring = 0, corridor = 0, scatter = 0, near = 0, hardRing = 0 }
    local hardRingCount = {} -- hard 매장지별 고리 바위 (얼음 중심 25 ~ 45 + 여유)
    local ringBand = { 0, 0, 0, 0 } -- 착륙지별 판 + 6 ~ + 45 띠 안 바위 (층 무관)
    local nearBandRocks, coreFarRocks, outerRocks, outOfMap = 0, 0, 0, 0
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
            local d = apronDistanceAt(apron, i, p)
            nearestApron = math.min(nearestApron, d)
            if d >= 6 and d <= 45 then
                ringBand[i] += 1
            end
        end
        local scattered = layer == "scatter" or layer == "near"
        local inCore = math.abs(p.X) <= 700 and math.abs(p.Z) <= 550
        if scattered and nearestApron >= 45 and nearestApron <= 200 then
            nearBandRocks += 1
        elseif layer == "scatter" and inCore and nearestApron > 200 then
            coreFarRocks += 1
        end
        if not inCore then
            outerRocks += 1
        end
        if math.abs(p.X) > 1300 or math.abs(p.Z) > 1100 then
            outOfMap += 1
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
            -- hard 고리 바위는 얼음 주변 상한에 세지 않는다 (DevMap 5층)
            if layer ~= "hardRing" and flatDistance(p, ice) < dev.iceBoulderCapRadius then
                nearIce[index] += 1
            end
        end
        if layer == "hardRing" then
            for index, def in Config.ICE_SITES do
                local d = flatDistance(p, Vector3.new(def.x, 0, def.z))
                if def.difficulty == "hard" and d >= 25 - 1e-3 and d <= 45 + 1e-3 then
                    hardRingCount[index] = (hardRingCount[index] or 0) + 1
                end
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
            and layers.near > 0
            and #boulders
                == layers.ring + layers.corridor + layers.scatter + layers.near + layers.hardRing,
        string.format(
            "바위 %d개: 기지 둘레 %d, 회랑 옆 %d, 산포 %d, 기지 근처 산포 %d, hard 고리 %d",
            #boulders,
            layers.ring,
            layers.corridor,
            layers.scatter,
            layers.near,
            layers.hardRing
        )
    )
    do
        local ringsOk, parts = true, {}
        for index, def in Config.ICE_SITES do
            if def.difficulty == "hard" then
                local n = hardRingCount[index] or 0
                table.insert(parts, "Ice" .. index .. " " .. n)
                if n < dev.hardRingRocks[1] or n > dev.hardRingRocks[2] then
                    ringsOk = false
                end
            end
        end
        check(
            ringsOk,
            "hard 매장지마다 반지름 25 ~ 45 바위 고리 12 ~ 20개 ("
                .. table.concat(parts, ", ")
                .. ")"
        )
    end
    local ringOk = true
    for i = 1, 4 do
        if ringBand[i] < dev.baseRingBouldersBySite[i] or ringBand[i] < 35 then
            ringOk = false
        end
    end
    check(
        ringOk,
        string.format(
            "어느 기지든 판 + 6 ~ + 45 띠에 바위 35개 이상 (%d, %d, %d, %d)",
            ringBand[1],
            ringBand[2],
            ringBand[3],
            ringBand[4]
        )
    )
    -- 산포 밀도: 판 + 45 ~ + 200 띠는 중심 구역의 다른 곳보다 약 1.5배 (격자 10 studs로 넓이 추정)
    local bandCells, farCells = 0, 0
    for gx = -695, 695, 10 do
        for gz = -545, 545, 10 do
            local nearest = math.huge
            for i = 1, 4 do
                nearest = math.min(nearest, apronDistanceAt(apron, i, Vector3.new(gx, 0, gz)))
            end
            if nearest >= 45 and nearest <= 200 then
                bandCells += 1
            elseif nearest > 200 then
                farCells += 1
            end
        end
    end
    local ratio = (nearBandRocks / bandCells) / (coreFarRocks / farCells)
    check(
        ratio >= 1.25 and ratio <= 2.2,
        string.format(
            "판 + 45 ~ + 200 산포 밀도가 중심 구역 다른 곳의 %.2f배 (목표 1.5, 띠 %d개, 그 밖 %d개)",
            ratio,
            nearBandRocks,
            coreFarRocks
        )
    )
    check(
        outerRocks > 0 and outOfMap == 0,
        string.format(
            "넓힌 지형(중심 밖)에도 바위 %d개, 지형 밖 바위 %d개",
            outerRocks,
            outOfMap
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
    do
        local onMountain = 0
        for _, boulder in boulders do
            local p = if boulder:IsA("BasePart")
                then boulder.CFrame.Position
                else boulder:GetPivot().Position
            for _, m in loadModule(Server:FindFirstChild("DevMap")).getMountains().footprints do
                if Vector3.new(p.X - m.x, 0, p.Z - m.z).Magnitude < m.r then
                    onMountain += 1
                end
            end
        end
        check(onMountain == 0, "산 바닥 위에 바위 없음 (" .. onMountain .. ")")
    end
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
    local tiles, area, tilesOk = 0, 0, true
    for _, child in ws3.DevTerrain:GetChildren() do
        if child.Name == "MoonGround" then
            tiles += 1
            area += child.Size.X * child.Size.Z
            if
                math.abs(child.CFrame.Position.Y + child.Size.Y / 2 - 1.5) > 1e-4
                or child.Size.X > 2048
                or child.Size.Z > 2048
            then
                tilesOk = false
            end
        end
    end
    check(
        tiles >= 2 and tilesOk and math.abs(area - 2600 * 2200) < 1,
        string.format(
            "TERRAIN_ENABLED false: 평평한 지면 타일 %d개 (윗면 y 1.5, 한 변 2048 이하, 합계 2600 x 2200)",
            tiles
        )
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
        and base.ModulePads.PadA:FindFirstChild("Ghost") ~= nil
        and base.ModulePads.PadB:FindFirstChild("Ghost") == nil,
    "착공 가능한 A만 Ghost 미리보기, Built 숨김"
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
-- 설치 연출 (2026-10-18): 홀드가 끝나면 패널이 슬롯 아래에서 접힌 채 올라와 PANEL_UNFOLD_SECONDS 동안 펼쳐진다
local unfoldSpent = 0 -- 이 구간에서 쓴 시간 (아래 첫 DayTick 시점을 예전과 맞춘다)
local function slotTopY(slot)
    return slot.CFrame.Position.Y + slot.Size.Y / 2
end
signalFor(installPrompt, "Triggered"):Fire(alice)
advance(0)
check(state().panelsInstalled == 1, "홀드가 끝나면 바로 1장 반영")
check(
    installPrompt.Enabled == false and installPrompt.ActionText == Config.PROMPT_TEXTS.installing,
    "펼치는 동안 설치 프롬프트 꺼짐, ActionText '설치 중'"
)
do
    local slot = base.SolarField.Slots.Slot1
    local frame = base.SolarField.Panels.Panel1.Frame
    check(
        frame.CFrame.Position.Y < slotTopY(slot) - 0.5,
        string.format(
            "펼치기 시작: 패널이 슬롯 윗면 아래에서 시작 (%.2f < %.2f)",
            frame.CFrame.Position.Y,
            slotTopY(slot)
        )
    )
end
signalFor(installPrompt, "Triggered"):Fire(alice)
advance(0)
check(state().panelsInstalled == 1, "펼치는 중 설치 요청은 무시")
advance(Config.PANEL_UNFOLD_SECONDS / 2)
unfoldSpent += Config.PANEL_UNFOLD_SECONDS / 2
check(installPrompt.Enabled == false, "펼치는 중간에도 프롬프트 꺼짐")
advance(Config.PANEL_UNFOLD_SECONDS / 2 + 0.1)
unfoldSpent += Config.PANEL_UNFOLD_SECONDS / 2 + 0.1
check(
    installPrompt.Enabled == true
        and installPrompt.ActionText == string.format(Config.PROMPT_TEXTS.installPanel, 1, 3),
    "펼침이 끝나면 프롬프트 다시 켜짐 '" .. installPrompt.ActionText .. "'"
)
for _ = 1, 2 do
    signalFor(installPrompt, "Triggered"):Fire(alice)
    advance(Config.PANEL_UNFOLD_SECONDS + 0.1)
    unfoldSpent += Config.PANEL_UNFOLD_SECONDS + 0.1
end
signalFor(installPrompt, "Triggered"):Fire(alice)
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
    "펼침이 끝난 패널이 슬롯 윗면에 놓임 (최종 자세)"
)
do
    -- 최종 자세는 슬롯과 같은 방향 (펼침 각도 0)
    local look = panel1.Frame.CFrame.UpVector:Dot(slot1.CFrame.UpVector)
    check(math.abs(look - 1) < 1e-4, "펼침이 끝난 패널이 슬롯과 평행")
end
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

advance(Config.DAY_SECONDS - unfoldSpent)
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
-- 미션 단계: 패널 3장 -> board_rover (날짜가 아니라 행동으로)
check(state().missionStage == "board_rover", "패널 3장 설치 뒤 단계 board_rover")
local ice1 = Workspace.IceSites.Ice1
local icePrompt = ice1:FindFirstChildOfClass("ProximityPrompt")
check(icePrompt.Enabled == false, "운전자 없으면 얼음 프롬프트 비활성")
seat.CFrame = ice1.CFrame * CFrame.new(0, 0, 12)
advance(1)
check(icePrompt.Enabled == false, "가까워도 운전자 없으면 비활성")
seat:Sit(humanoid)
advance(1)
check(icePrompt.Enabled == true, "운전 중 + 20 studs 안이면 활성")
check(
    state().missionStage == "find_ice"
        and lastSent("StateUpdate").args[1].missionStage == "find_ice"
        and state().missionText == Config.MISSION_TEXTS.findIce,
    "로버에 타면 단계 find_ice, 문구 파생"
)
signalFor(icePrompt, "Triggered"):Fire(bob)
advance(0)
check(state().rover.tank == 0, "운전자가 아닌 Bob의 채취 거부")
-- 매장량 (2026-10-18): Ice1은 mid 30 W. 탱크 빈 공간(40)보다 적으므로 30만 채우고 매장지가 고갈된다
local ice1Deposit = Config.ICE_SITES[1].deposit
check(
    icePrompt.ObjectText == string.format(Config.PROMPT_TEXTS.iceObjectAmount, ice1Deposit),
    "얼음 프롬프트 ObjectText에 남은 매장량 '" .. icePrompt.ObjectText .. "'"
)
signalFor(icePrompt, "Triggered"):Fire(alice)
advance(0)
check(
    state().rover.tank == ice1Deposit and seat:GetAttribute("Tank") == ice1Deposit,
    "채취량 = min(탱크 빈 공간, 매장량) = " .. ice1Deposit .. ", Attribute 반영"
)
check(
    lastSent("Notify").args[1] == string.format(Config.TEXTS.iceExtracted, ice1Deposit, 0)
        and lastSent("Notify").args[2] == "good",
    "채취 알림 '" .. tostring(lastSent("Notify").args[1]) .. "'"
)
check(
    ice1:GetAttribute("Deposit") == 0 and ice1:GetAttribute("DepositMax") == ice1Deposit,
    "Ice1 Deposit 0, DepositMax 유지"
)
do
    local glow = ice1:FindFirstChild("IceGlow")
    local light = glow and glow:FindFirstChildOfClass("PointLight")
    local patch = ice1:FindFirstChild("MinedPatch")
    check(
        light ~= nil
            and light.Enabled == false
            and patch ~= nil
            and math.abs(patch.Size.X - 10) < 1e-3
            and math.abs(patch.Size.Y - 0.2) < 1e-3
            and ice1.Transparency == 1,
        "고갈: 빛 끔, 결정 숨김, 어두운 10 x 0.2 x 10 패치"
    )
end
advance(1)
check(
    icePrompt.Enabled == false,
    "고갈된 매장지는 운전 중 가까워도 프롬프트 꺼짐"
)
signalFor(icePrompt, "Triggered"):Fire(alice)
advance(0)
check(
    state().rover.tank == ice1Deposit and lastSent("Notify").args[1] == Config.TEXTS.iceDepleted,
    "고갈된 매장지 채취 요청 거부와 안내"
)
-- 결정 크기: 절반 남은 매장지는 원래 크기의 0.5배 (하한 0.35), 바닥은 그대로
do
    local ice2 = Workspace.IceSites.Ice2
    local WaterLoop = loadModule(Server:FindFirstChild("WaterLoop"))
    local size0, bottom0 = ice2.Size, ice2.CFrame.Position.Y - ice2.Size.Y / 2
    seat.CFrame = ice2.CFrame * CFrame.new(0, 0, 12)
    advance(1)
    local prompt2 = ice2:FindFirstChildOfClass("ProximityPrompt")
    -- 탱크를 비워 두고 반만 캔다: 매장량을 직접 맞춘 뒤 다시 채취
    ResourceState.patch(function(st)
        st.rover.tank = st.rover.tankMax - Config.ICE_SITES[2].deposit / 2
    end)
    signalFor(prompt2, "Triggered"):Fire(alice)
    advance(0)
    local half = ice2:GetAttribute("Deposit")
    check(
        half == Config.ICE_SITES[2].deposit / 2 and state().rover.tank == state().rover.tankMax,
        "탱크 빈 공간만큼만 채취, 매장량 " .. tostring(half) .. " 남음"
    )
    check(
        math.abs(ice2.Size.X - size0.X * 0.5) < 1e-3
            and math.abs((ice2.CFrame.Position.Y - ice2.Size.Y / 2) - bottom0) < 1e-3,
        string.format(
            "남은 비율 0.5만큼 결정 크기 축소, 바닥 고정 (%.2f)",
            ice2.Size.X / size0.X
        )
    )
    -- 탱크가 가득 차면 채취 거부 (info)
    signalFor(prompt2, "Triggered"):Fire(alice)
    advance(0)
    check(
        lastSent("Notify").args[1] == Config.TEXTS.tankAlreadyFull
            and lastSent("Notify").args[2] == "info",
        "탱크가 가득 차 있으면 info 안내"
    )
    -- 원래대로 (아래 하역 검사는 Ice1의 30 W 기준)
    ResourceState.patch(function(st)
        st.rover.tank = ice1Deposit
    end)
    WaterLoop.mirrorTank()
    ice2:SetAttribute("Deposit", Config.ICE_SITES[2].deposit)
end
check(state().missionStage == "unload", "물을 실으면(만충이 아니어도) 단계 unload")
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
    state().water == water0 and state().rover.tank == ice1Deposit,
    "로버가 멀리 있으면 하역 거부"
)
check(
    lastSent("Notify").args[1] == "로버를 물탱크 옆에 세워야 하역할 수 있습니다",
    "하역 거부 안내"
)
seat.CFrame = base.WaterTank.CFrame * CFrame.new(6, 0, 0)
-- 처리 전력 부족: 에너지 5면 1 W당 0.5라 10 W만 처리하고 나머지는 탱크에 남긴다
local energyBeforeUnload = state().energy
ResourceState.patch(function(st)
    st.energy = 5
end)
signalFor(tankPrompt, "Triggered"):Fire(bob)
advance(0)
check(
    state().water == water0 + 10
        and state().rover.tank == ice1Deposit - 10
        and state().energy == 0
        and state().waterTrips == 1,
    string.format(
        "전력 5로 물 10 W만 처리, 탱크 %d 남음, 에너지 0",
        state().rover.tank
    )
)
do
    local warned = false
    for i = #sent, math.max(1, #sent - 4), -1 do
        local s = sent[i]
        if
            s.name == "Notify"
            and s.args[1] == string.format(Config.TEXTS.waterPartial, 10)
            and s.args[2] == "warn"
        then
            warned = true
        end
    end
    check(warned, "일부만 처리하면 warn 알림")
end
-- 에너지 0이면 처리할 수 없다
signalFor(tankPrompt, "Triggered"):Fire(bob)
advance(0)
check(
    state().rover.tank == ice1Deposit - 10
        and lastSent("Notify").args[2] == "warn"
        and string.find(lastSent("Notify").args[1], "전력이 부족해", 1, true) ~= nil,
    "에너지 0이면 하역 거부 (warn)"
)
ResourceState.patch(function(st)
    st.energy = energyBeforeUnload
end)
signalFor(tankPrompt, "Triggered"):Fire(bob)
advance(0)
check(
    state().water == water0 + ice1Deposit
        and state().rover.tank == 0
        and state().waterTrips == 2
        and math.abs(
                state().energy
                    - (energyBeforeUnload - (ice1Deposit - 10) * Config.WATER_PROCESS_ENERGY_PER_W)
            )
            < 1e-6,
    string.format(
        "나머지 하역: 물 합계 +%d, 탱크 0, 하역 2회, 1 W당 전력 %.1f",
        ice1Deposit,
        Config.WATER_PROCESS_ENERGY_PER_W
    )
)
check(seat:GetAttribute("Tank") == 0, "Tank Attribute 0")
check(state().missionStage == "build_A", "하역하면 단계 build_A")
do
    local sentState = lastSent("StateUpdate").args[1]
    local a = sentState.modules.A
    check(
        a.unlocked == true
            and sentState.modules.B.unlocked == false
            and a.shortfall.energy == math.max(0, Config.MODULES.A.cost.energy - sentState.energy)
            and a.shortfall.water == math.max(0, Config.MODULES.A.cost.water - sentState.water),
        string.format(
            "StateUpdate 모듈 unlocked와 shortfall (A 부족 E %s, W %s)",
            tostring(a.shortfall.energy),
            tostring(a.shortfall.water)
        )
    )
    check(
        sentState.daysLeft.water == math.floor(sentState.water / Config.CREW.water)
            and sentState.daysLeft.food == math.floor(sentState.food / Config.CREW.food)
            and sentState.stallReason == "",
        string.format(
            "StateUpdate daysLeft (물 %d일, 식량 %d일), stallReason 빈 문자열",
            sentState.daysLeft.water,
            sentState.daysLeft.food
        )
    )
end
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
check(
    string.find(consolePrompt.ActionText, "초 뒤", 1, true) ~= nil,
    "복구 직후 콘솔 프롬프트에 쿨다운 남은 초 (" .. consolePrompt.ActionText .. ")"
)
-- 뒤집힘: 무인 상태로 3초 이상이면 자동 복구 (쿨다운이 끝난 뒤)
advance(Config.ROVER_RECOVERY.cooldownSeconds)
check(
    consolePrompt.ActionText == "로버 복구",
    "쿨다운이 끝나면 프롬프트 문구 복귀"
)
newRover:PivotTo(roverHome * CFrame.new(0, 2, 0) * CFrame.Angles(0, 0, math.pi))
advance(2)
check(not roverAtHome(), "뒤집힌 지 3초 전에는 그대로")
advance(3)
check(
    roverAtHome() and newRover.DriverSeat.CFrame.UpVector.Y > 0.99,
    "뒤집힘 3초 뒤 자동 복구"
)
-- 추락: Origin보다 20 studs 아래. 방금 복구해서 쿨다운 중이면 기다렸다가 복구
newRover:PivotTo(roverHome * CFrame.new(0, -30, 0))
advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
check(not roverAtHome(), "쿨다운 중에는 자동 복구도 기다림")
advance(Config.ROVER_RECOVERY.cooldownSeconds)
check(roverAtHome(), "추락 시 쿨다운 뒤 자동 복구")
advance(Config.ROVER_RECOVERY.cooldownSeconds)
-- 반례 (리뷰 I01): 만충 로버를 복구해도 물은 기지로 오지 않고 탱크의 물을 잃는다
do
    ResourceState.patch(function(st)
        st.rover.tank = st.rover.tankMax
    end)
    newRover.DriverSeat:SetAttribute("Tank", 40)
    local waterBefore = state().water
    newRover:PivotTo(roverHome * CFrame.new(300, 0, 0)) -- 얼음 근처라고 가정한 먼 곳
    signalFor(consolePrompt, "Triggered"):Fire(alice)
    advance(0)
    check(roverAtHome(), "콘솔 프롬프트로 수동 복구 (운전석 비어 있음)")
    check(
        state().rover.tank == 0
            and newRover.DriverSeat:GetAttribute("Tank") == 0
            and state().water == waterBefore,
        string.format(
            "만충 로버 복구: 탱크 0, 기지 물 그대로 (%d -> %d), 물 순간 운송 불가",
            waterBefore,
            state().water
        )
    )
    local lostWarn = false
    for _, entry in sent do
        if
            entry.name == "Notify"
            and entry.args[1] == "복구 중 탱크의 물을 잃었습니다"
        then
            lostWarn = entry.args[2] == "warn"
        end
    end
    check(lostWarn, "물 유실 안내 (warn)")
    -- 쿨다운 중 재요청 거부
    newRover:PivotTo(roverHome * CFrame.new(40, 0, 0))
    signalFor(consolePrompt, "Triggered"):Fire(alice)
    advance(0)
    check(
        not roverAtHome()
            and string.find(
                    lastSent("Notify").args[1],
                    "초 뒤에 할 수 있습니다",
                    1,
                    true
                )
                ~= nil,
        "쿨다운 중 수동 복구 거부 (" .. lastSent("Notify").args[1] .. ")"
    )
    -- 탑승 중 복구 거부 (쿨다운이 끝난 뒤)
    advance(Config.ROVER_RECOVERY.cooldownSeconds + Config.ROVER_RECOVERY.checkSeconds + 0.1)
    newRover.DriverSeat.Occupant = humanoid
    signalFor(consolePrompt, "Triggered"):Fire(alice)
    advance(0)
    check(
        not roverAtHome()
            and lastSent("Notify").args[1] == "탑승 중에는 복구할 수 없습니다"
            and lastSent("Notify").args[2] == "warn",
        "탑승 중에는 수동 복구 거부"
    )
    check(
        consolePrompt.ActionText == "로버 복구"
            and consolePrompt.HoldDuration == Config.ROVER_RECOVERY.hold,
        "복구 프롬프트 설정"
    )
    -- 다음 단계를 위해 빈 로버로 바꿔 둔다 (Lune은 Occupant에 nil을 넣을 수 없어 로버를 지워 재복제)
    newRover:Destroy()
    advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
    newRover = base:FindFirstChild("Rover")
    advance(Config.ROVER_RECOVERY.cooldownSeconds)
end

-- 캐릭터 초기화 (리뷰 I17): Reset Character로 죽으면 산소 구조와 같은 페널티 -------
print("[초기화]")
do
    local before = state()
    local foodBefore, waterBefore, deaths = before.food, before.water, before.oxygenDeaths
    signalFor(humanoid, "Died"):Fire()
    advance(0)
    check(
        state().food == math.max(0, foodBefore - Config.OXYGEN.deathPenalty.food)
            and state().water == math.max(0, waterBefore - Config.OXYGEN.deathPenalty.water)
            and state().oxygenDeaths == deaths + 1,
        "초기화 사망: Food -1, Water -2, oxygenDeaths +1"
    )
    local selfWarn, otherWarn = false, false
    for _, entry in sent do
        if entry.name == "Notify" and entry.args[2] == "warn" then
            if entry.target == alice and string.find(entry.args[1], "쓰러져서", 1, true) then
                selfWarn = true
            elseif
                entry.target == bob
                and string.find(entry.args[1], "Alice 대원이 쓰러져", 1, true)
            then
                otherWarn = true
            end
        end
    end
    check(selfWarn and otherWarn, "초기화 페널티 안내 (본인, 다른 대원 warn)")
end

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
    -- 첫 탑승 안내는 물 원정에서 처음 앉았을 때 한 번만 (로버를 다시 만들어도 반복하지 않음)
    local firstBoards, kind = 0, nil
    for _, entry in sent do
        if
            entry.name == "Notify"
            and entry.target == alice
            and entry.args[1]
                == string.format(Config.TEXTS.firstBoard, Config.ROVER.boostDrainMultiplier)
        then
            firstBoards += 1
            kind = entry.args[2]
        end
    end
    check(
        firstBoards == 1 and kind == "info",
        "첫 탑승 안내는 한 번 (" .. firstBoards .. "회)"
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

-- 로버 파손과 수리 (2026-10-18) --------------------------------------------
print("[로버 파손]")
do
    local RoverDamage = loadModule(Server:FindFirstChild("RoverDamage"))
    local RoverDrive = loadModule(Server:FindFirstChild("RoverDrive"))
    local d = Config.ROVER_DAMAGE
    local rock = nil
    for _, b in Workspace.DevTerrain.Boulders:GetChildren() do
        if b:IsA("BasePart") then
            rock = b
            break
        end
    end
    check(rock ~= nil and rock:GetAttribute("BoulderLayer") ~= nil, "바위 파트에 BoulderLayer")
    local function repairPromptOf(rover)
        for _, p in rover.Chassis:GetChildren() do
            if p:IsA("ProximityPrompt") and p.ActionText == Config.PROMPT_TEXTS.repairRover then
                return p
            end
        end
        return nil
    end
    local rover = newRover
    local repair = repairPromptOf(rover)
    check(
        repair ~= nil
            and repair.ObjectText == "로버"
            and repair.HoldDuration == d.repairHold
            and repair.MaxActivationDistance == d.promptDistance
            and repair.KeyboardKeyCode == roblox.Enum.KeyCode.R
            and repair.Style == roblox.Enum.ProximityPromptStyle.Custom
            and repair.Enabled == false,
        "섀시에 수리 프롬프트 (로버, 수리, R, 홀드 4, 거리 8, Custom), 파손 0이면 꺼짐"
    )
    local function hitWith(part, speed)
        rover.Chassis.AssemblyLinearVelocity = Vector3.new(speed, 0, 0)
        signalFor(part, "Touched"):Fire(rock)
        advance(0)
        rover.Chassis.AssemblyLinearVelocity = Vector3.zero
    end
    -- 최고 속도 = ROVER.maxSpeed x 파손 배율 (파손 0: 18, 1: 16.2, 2: 14.4). 임계값 12는 셋 모두보다 낮다
    local function topSpeed(damage)
        return Config.ROVER.maxSpeed * (1 - d.speedPenaltyPerDamage * damage)
    end
    hitWith(rover.Chassis, d.speedThreshold - 0.1)
    check(state().rover.damage == 0, "임계값 12 바로 아래(11.9) 충돌은 파손 없음")
    hitWith(rover.Chassis, d.speedThreshold)
    check(state().rover.damage == 1, "임계값 12 충돌은 파손 1")
    do
        local toDriver, toOthers = false, false
        for i = #sent, math.max(1, #sent - 6), -1 do
            local s = sent[i]
            if s.name == "Notify" and s.target == alice and s.args[1] == "로버 파손 1/3" then
                toDriver = s.args[2] == "warn"
            end
            if
                s.name == "Notify"
                and s.target == bob
                and s.args[1] == "로버가 바위에 부딪혔습니다 (파손 1/3)"
            then
                toOthers = s.args[2] == "warn"
            end
        end
        check(
            toDriver and toOthers,
            "운전자에게 '로버 파손 1/3', 다른 대원에게 충돌 알림 (warn)"
        )
    end
    check(
        math.abs(RoverDrive.getSpeedMultiplier() - 0.9) < 1e-9 and topSpeed(1) >= d.speedThreshold,
        "파손 1이면 최고 속도 0.9배 (16.2, 임계값 이상)"
    )
    hitWith(rover.Chassis, 16)
    check(state().rover.damage == 1, "1초 안의 두 번째 충돌은 한 번으로 셈")
    advance(d.hitCooldown + 0.1)
    -- 바위가 아닌 파트와의 접촉은 무시
    rover.Chassis.AssemblyLinearVelocity = Vector3.new(30, 0, 0)
    signalFor(rover.Chassis, "Touched"):Fire(Workspace.LandingPads.Pad1)
    advance(0)
    check(state().rover.damage == 1, "바위가 아닌 파트와 충돌은 무시")
    -- 바퀴로 부딪혀도 센다
    local wheel = nil
    for _, part in rover:GetChildren() do
        if part:IsA("BasePart") and string.sub(part.Name, 1, 5) == "Wheel" then
            wheel = part
            break
        end
    end
    -- 파손 1의 평지 최고 속도(16.2)로 바퀴가 부딪혀도 센다
    hitWith(wheel, topSpeed(1))
    check(
        state().rover.damage == 2 and math.abs(RoverDrive.getSpeedMultiplier() - 0.8) < 1e-9,
        "바퀴 충돌(16.2)도 파손 2, 최고 속도 0.8배 (14.4)"
    )
    advance(d.hitCooldown + 0.1)
    -- 파손 2의 평지 최고 속도(14.4)도 임계값 12 이상이라 세 번째 파손이 난다
    hitWith(rover.Chassis, topSpeed(2))
    check(
        state().rover.damage == 3
            and state().rover.broken == true
            and RoverDrive.getSpeedMultiplier() == 0
            and lastSent("StateUpdate").args[1].rover.broken == true
            and lastSent("StateUpdate").args[1].rover.damage == 3,
        "세 번째 충돌: 파손 3, broken, 속도 배율 0, StateUpdate 반영"
    )
    check(
        state().missionText == string.format(Config.MISSION_TEXTS.roverBroken, d.repairEnergy),
        "고장이면 미션 '" .. state().missionText .. "'"
    )
    do
        local brokenNotice = false
        for i = #sent, math.max(1, #sent - 6), -1 do
            if sent[i].name == "Notify" and sent[i].args[1] == Config.TEXTS.roverBroken then
                brokenNotice = true
            end
        end
        check(brokenNotice, "고장 알림 '로버 고장. 수리가 필요합니다'")
    end
    advance(d.hitCooldown + 0.1)
    hitWith(rover.Chassis, 25)
    check(state().rover.damage == 3, "파손은 3을 넘지 않음")
    check(repair.Enabled == false, "탑승 중에는 수리 프롬프트 꺼짐")
    signalFor(repair, "Triggered"):Fire(alice)
    advance(0)
    check(
        state().rover.damage == 3 and lastSent("Notify").args[1] == Config.TEXTS.repairOccupied,
        "탑승 중 수리 요청 거부"
    )
    -- 복구하면 파손 0 (Lune은 Occupant에 nil을 넣을 수 없어 로버를 지워 재복제 경로로 복구)
    rover:Destroy()
    advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
    rover = base:FindFirstChild("Rover")
    check(
        rover ~= nil
            and state().rover.damage == 0
            and state().rover.broken == false
            and RoverDrive.getSpeedMultiplier() == 1,
        "로버 복구는 파손을 0으로 되돌림"
    )
    repair = repairPromptOf(rover)
    check(
        repair ~= nil and repair.Enabled == false,
        "재복제한 로버에도 수리 프롬프트 (파손 0이면 꺼짐)"
    )
    -- 빈 로버: 운전자가 없으면 모두에게 충돌 알림
    hitWith(rover.Chassis, 18)
    check(
        state().rover.damage == 1
            and lastSent("Notify").target == "all"
            and lastSent("Notify").args[1]
                == "로버가 바위에 부딪혔습니다 (파손 1/3)",
        "운전자 없는 충돌은 전원에게 알림"
    )
    check(repair.Enabled == true, "파손 > 0, 좌석 비어 있으면 수리 프롬프트 켜짐")
    local energyBefore = state().energy
    ResourceState.patch(function(st)
        st.energy = d.repairEnergy - 1
    end)
    signalFor(repair, "Triggered"):Fire(bob)
    advance(0)
    check(
        state().rover.damage == 1
            and lastSent("Notify").args[1] == string.format(
                Config.TEXTS.repairNeedEnergy,
                d.repairEnergy
            )
            and lastSent("Notify").args[2] == "warn",
        "전력 부족이면 수리 거부 '" .. lastSent("Notify").args[1] .. "'"
    )
    ResourceState.patch(function(st)
        st.energy = 50
    end)
    signalFor(repair, "Triggered"):Fire(bob)
    advance(0)
    check(
        state().rover.damage == 0
            and state().energy == 50 - d.repairEnergy
            and lastSent("Notify").args[1] == Config.TEXTS.repairDone
            and lastSent("Notify").args[2] == "good"
            and repair.Enabled == false
            and RoverDrive.getSpeedMultiplier() == 1,
        "수리 성공: 전력 -10, 파손 0, 알림, 프롬프트 꺼짐"
    )
    ResourceState.patch(function(st)
        st.energy = energyBefore
    end)
    -- 끄기: Config.ROVER_DAMAGE.enabled = false면 감지, 프롬프트, 속도 감소가 모두 없다
    d.enabled = false
    RoverDamage.attach(base)
    check(repairPromptOf(rover) == nil, "끄면 수리 프롬프트 없음")
    advance(d.hitCooldown + 0.1)
    hitWith(rover.Chassis, 30)
    check(
        state().rover.damage == 0
            and RoverDamage.registerHit(30) == false
            and RoverDrive.getSpeedMultiplier() == 1,
        "끄면 충돌해도 파손 없음, 속도 배율 1"
    )
    d.enabled = true
    RoverDamage.attach(base)
    check(repairPromptOf(rover) ~= nil, "다시 켜면 수리 프롬프트")
    -- 다음 단계는 Alice가 로버에 탄 상태를 이어 쓴다
    rover.DriverSeat:Sit(humanoid)
    advance(0)
    newRover = rover
end

-- 로버 배터리와 충전 (2026-10-18) -------------------------------------------
print("[로버 배터리]")
do
    local RoverBattery = loadModule(Server:FindFirstChild("RoverBattery"))
    local RoverDrive = loadModule(Server:FindFirstChild("RoverDrive"))
    local rv = Config.ROVER
    local rover = base.Rover
    local chassis = rover.Chassis
    local pad = base:FindFirstChild("ChargePad")
    check(
        pad ~= nil
            and math.abs(pad.Size.X - 12) < 1e-3
            and math.abs(pad.Size.Z - 12) < 1e-3
            and #pad:GetChildren() >= 4,
        "BaseKit ChargePad 12 x 12, 노란 테두리"
    )
    local kitPad = kit:FindFirstChild("ChargePad")
    local kitChassis = kit.Rover.Chassis
    check(
        kitPad ~= nil
            and Vector3.new(
                    kitChassis.CFrame.Position.X - kitPad.CFrame.Position.X,
                    0,
                    kitChassis.CFrame.Position.Z - kitPad.CFrame.Position.Z
                ).Magnitude
                <= rv.chargeRadius,
        "시작 시 로버가 충전 패드 위에 주차"
    )
    check(
        state().rover.battery == rv.batteryMax
            and state().rover.batteryMax == rv.batteryMax
            and lastSent("StateUpdate").args[1].rover.batteryMax == rv.batteryMax
            and lastSent("StateUpdate").args[1].rover.charging ~= nil,
        "시작 배터리 만충, StateUpdate에 battery, batteryMax, charging"
    )
    local function notices(text)
        local count = 0
        for _, entry in sent do
            if entry.name == "Notify" and entry.args[1] == text then
                count += 1
            end
        end
        return count
    end
    -- 기준 위치를 잡은 뒤 한 주기 동안 5 studs 이동 = 주행
    local function driveStep(distance)
        RoverBattery.step(0.25)
        chassis.CFrame = chassis.CFrame + Vector3.new(distance, 0, 0)
        RoverBattery.step(0.25)
        advance(0)
    end
    local energyKeep = state().energy
    local b0 = state().rover.battery
    driveStep(5)
    check(
        math.abs(state().rover.battery - (b0 - rv.batteryDrainPerSecond * 0.25)) < 1e-6,
        string.format("주행 중 소모 (%.2f -> %.2f)", b0, state().rover.battery)
    )
    local b1 = state().rover.battery
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    check(state().rover.battery == b1, "정지 중에는 소모 없음")
    -- 25% 이하 경고 1회
    local lowText = string.format(Config.TEXTS.batteryLow, 25)
    ResourceState.patch(function(st)
        st.rover.battery = rv.batteryMax * rv.lowBatteryRatio + 0.05
    end)
    driveStep(5)
    driveStep(5)
    check(notices(lowText) == 1, "25% 이하 경고 한 번 (" .. notices(lowText) .. "회)")
    -- 기지 밖에서 배터리가 낮으면 미션 문구가 단계 문구보다 먼저
    chassis.CFrame = pad.CFrame + Vector3.new(100, 0, 0)
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    check(
        state().rover.away == true and state().missionText == Config.MISSION_TEXTS.batteryLow,
        "기지 밖 배터리 부족 미션 '" .. state().missionText .. "'"
    )
    -- 방전: 0이면 정지, 경고 1회, 미션 문구
    ResourceState.patch(function(st)
        st.rover.battery = 0.05
    end)
    driveStep(5)
    driveStep(5)
    check(
        state().rover.battery == 0
            and RoverDrive.getSpeedMultiplier() == 0
            and notices(Config.TEXTS.batteryEmpty) == 1
            and state().missionText == Config.MISSION_TEXTS.batteryEmpty,
        "방전: 배터리 0, 속도 배율 0, 경고 한 번, 미션 '"
            .. state().missionText
            .. "'"
    )
    -- 복구하면 배터리를 20%로 채워 돌아온다
    RoverBattery.onRecovered()
    check(
        math.abs(state().rover.battery - rv.batteryMax * rv.recoverBatteryRatio) < 1e-6
            and RoverDrive.getSpeedMultiplier() == 1,
        "복구하면 배터리 20%, 다시 달릴 수 있음"
    )
    ResourceState.patch(function(st)
        st.rover.battery = 0
    end)
    RoverBattery.onRecovered()
    -- 빈 좌석 로버 (Lune은 Occupant에 nil을 넣을 수 없어 로버를 지워 재복제 경로로 복구). 앞 복구의 쿨다운을 기다린다
    advance(Config.ROVER_RECOVERY.cooldownSeconds)
    rover:Destroy()
    advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
    rover = base:FindFirstChild("Rover")
    chassis = rover.Chassis
    check(
        state().rover.battery >= rv.batteryMax * rv.recoverBatteryRatio - 1e-6,
        string.format("재복제 복구 뒤 배터리 %.1f (20%% 이상)", state().rover.battery)
    )
    -- 패드 위 빈 좌석: 초당 2씩 기지 에너지에서 충전
    ResourceState.patch(function(st)
        st.rover.battery = 20
        st.energy = 100
    end)
    RoverBattery.step(0.25)
    RoverBattery.step(1)
    advance(0)
    check(
        math.abs(state().rover.battery - (20 + rv.chargeRatePerSecond * 1.25)) < 1e-6
            and math.abs(state().energy - (100 - rv.chargeRatePerSecond * 1.25)) < 1e-6
            and state().rover.charging == true
            and lastSent("StateUpdate").args[1].rover.charging == true,
        string.format(
            "패드 위 빈 좌석 충전: 배터리 %.1f, 에너지 %.1f, charging",
            state().rover.battery,
            state().energy
        )
    )
    -- 기지 에너지 0이면 충전 정지와 경고 (하루 한 번)
    ResourceState.patch(function(st)
        st.energy = 0
    end)
    local before = state().rover.battery
    RoverBattery.step(1)
    RoverBattery.step(1)
    advance(0)
    check(
        state().rover.battery == before
            and state().rover.charging == false
            and notices(Config.TEXTS.chargeNoEnergy) == 1,
        "기지 에너지 0이면 충전 정지, 경고 한 번"
    )
    -- 완충 알림 1회 (이번 충전에서. 앞 단계에서 로버를 옮긴 뒤 다시 찬 알림은 빼고 센다)
    local fullBefore = notices(Config.TEXTS.batteryFull)
    ResourceState.patch(function(st)
        st.energy = 100
        st.rover.battery = rv.batteryMax - 0.5
    end)
    RoverBattery.step(1)
    RoverBattery.step(1)
    advance(0)
    check(
        state().rover.battery == rv.batteryMax
            and notices(Config.TEXTS.batteryFull) - fullBefore == 1,
        "완충하면 '로버 충전 완료' 한 번"
    )
    -- 탑승하면 충전 정지
    ResourceState.patch(function(st)
        st.rover.battery = 30
    end)
    rover.DriverSeat:Sit(humanoid)
    advance(0)
    RoverBattery.step(1)
    advance(0)
    check(
        state().rover.battery == 30 and state().rover.charging == false,
        "탑승하면 충전하지 않음"
    )
    ResourceState.patch(function(st)
        st.energy = energyKeep
        st.rover.battery = rv.batteryMax
    end)
    newRover = rover
end

-- 충전 도크 상태와 효과음 헬퍼 (2026-10-18) ----------------------------------
print("[충전 도크]")
do
    local RoverBattery = loadModule(Server:FindFirstChild("RoverBattery"))
    local Sfx = loadModule(Server:FindFirstChild("Sfx"))
    local d = Config.CHARGE_DOCK
    local pad = base.ChargePad
    local rover = base.Rover
    local function trimColor()
        for _, child in pad:GetChildren() do
            if child.Name == "ChargePadTrim" then
                return child.Color
            end
        end
        return nil
    end
    local function rgb(t)
        return roblox.Color3.fromRGB(t[1], t[2], t[3])
    end
    local function colorNear(a, b)
        return a ~= nil
            and math.abs(a.R - b.R) < 0.01
            and math.abs(a.G - b.G) < 0.01
            and math.abs(a.B - b.B) < 0.01
    end
    local light = pad:FindFirstChildOfClass("SurfaceLight")
    local ring = pad:FindFirstChild("ChargePadRing")
    check(light ~= nil and ring ~= nil, "충전 패드에 SurfaceLight와 중앙 원판")
    -- 시작 상태: 탑승한 로버가 패드 위, 배터리 가득 -> full
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    check(
        pad:GetAttribute("DockState") == "full" and colorNear(trimColor(), rgb(d.fullColor)),
        "패드 위 만충 로버: DockState full, 초록 ('"
            .. tostring(pad:GetAttribute("DockState"))
            .. "')"
    )
    -- 로버가 떠나면 empty
    local home = rover.Chassis.CFrame
    rover.Chassis.CFrame = home + Vector3.new(40, 0, 0)
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    check(
        pad:GetAttribute("DockState") == "empty"
            and colorNear(trimColor(), rgb(d.emptyColor))
            and light.Enabled == false
            and ring.Transparency == 1,
        "로버가 떠나면 empty: 노란 테두리, 빛 없음, 원판 숨김"
    )
    -- 탑승한 채 들어오면 docked + 운전자에게 안내 + 도크 소리
    ResourceState.patch(function(st)
        st.rover.battery = 30
    end)
    local dockSounds = 0
    for _, entry in soundLog do
        if entry.name == "Sfx_rover_dock" then
            dockSounds += 1
        end
    end
    rover.Chassis.CFrame = home
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    advance(0)
    local dockSoundsAfter = 0
    for _, entry in soundLog do
        if entry.name == "Sfx_rover_dock" then
            dockSoundsAfter += 1
        end
    end
    check(
        pad:GetAttribute("DockState") == "docked"
            and colorNear(trimColor(), rgb(d.dockedColor))
            and light.Enabled == true
            and math.abs(light.Brightness - d.dockedLight) < 1e-6,
        "탑승한 채 도킹: DockState docked, 하늘색 테두리, 약한 빛"
    )
    do
        local told = false
        for i = #sent, math.max(1, #sent - 6), -1 do
            local s = sent[i]
            if
                s.name == "Notify"
                and s.target == alice
                and s.args[1] == Config.TEXTS.dockEntered
            then
                told = s.args[2] == "info"
            end
        end
        check(told, "도킹 순간 운전자에게 '하차하면 충전이 시작됩니다' (info)")
    end
    check(dockSoundsAfter == dockSounds + 1, "도크 진입 효과음 rover_dock 한 번")
    -- 하차 (Lune은 Occupant에 nil을 넣을 수 없어 로버를 지워 재복제한다: 빈 좌석으로 패드 위에 돌아온다)
    advance(Config.ROVER_RECOVERY.cooldownSeconds)
    rover:Destroy()
    advance(Config.ROVER_RECOVERY.checkSeconds + 0.1)
    rover = base:FindFirstChild("Rover")
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    advance(0)
    local started = false
    for i = #sent, math.max(1, #sent - 8), -1 do
        local s = sent[i]
        if
            s.name == "Notify"
            and string.find(tostring(s.args[1]), "충전 시작 (", 1, true) == 1
        then
            started = s.args[2] == "good"
        end
    end
    local chargeLoopOn = false
    for _, child in pad:GetChildren() do
        if child:IsA("Sound") and child.Name == "Sfx_rover_charge_loop" and child.Looped then
            chargeLoopOn = true
        end
    end
    check(
        pad:GetAttribute("DockState") == "charging"
            and state().rover.charging == true
            and ring.Transparency < 1
            and colorNear(trimColor(), rgb(d.chargingColor)),
        "하차하면 charging: 노란 테두리와 원판"
    )
    check(started, "충전 시작 순간 '충전 시작 (n / 50)' (good)")
    check(chargeLoopOn, "충전 중 패드에 rover_charge_loop 루프")
    -- 펄스: 시간이 지나면 밝기가 변한다
    local b1 = light.Brightness
    advance(d.pulsePeriod / 4)
    check(math.abs(light.Brightness - b1) > 1e-3, "충전 중 SurfaceLight 밝기 펄스")
    -- 기지 에너지 0이면 docked
    ResourceState.patch(function(st)
        st.energy = 0
    end)
    RoverBattery.step(0.25)
    advance(0)
    local loopGone = true
    for _, child in pad:GetChildren() do
        if child:IsA("Sound") and child.Name == "Sfx_rover_charge_loop" then
            loopGone = false
        end
    end
    check(
        pad:GetAttribute("DockState") == "docked" and state().rover.charging == false and loopGone,
        "기지 에너지 0이면 충전 멈추고 docked, 충전 루프 정지"
    )
    -- 다시 에너지가 생기면 charging, 가득 차면 full
    ResourceState.patch(function(st)
        st.energy = 100
        st.rover.battery = st.rover.batteryMax - 0.3
    end)
    RoverBattery.step(0.25)
    RoverBattery.step(0.25)
    advance(0)
    check(
        pad:GetAttribute("DockState") == "full" and colorNear(trimColor(), rgb(d.fullColor)),
        "가득 차면 full: 초록 고정"
    )
    rover.Chassis.CFrame = rover.Chassis.CFrame + Vector3.new(40, 0, 0)
    RoverBattery.step(0.25)
    check(pad:GetAttribute("DockState") == "empty", "로버가 떠나면 다시 empty")
    rover.Chassis.CFrame = home
    RoverBattery.step(0.25)

    -- 효과음 헬퍼: id 0이면 Sound를 만들지 않는다. 루프 핸들은 정지하면 지운다
    local SoundIds = loadModule(Shared:FindFirstChild("SoundIds"))
    local keep = SoundIds.rover_hit.id
    SoundIds.rover_hit.id = 0
    local silent = Sfx.play("rover_hit", pad)
    check(
        silent == nil and pad:FindFirstChild("Sfx_rover_hit") == nil,
        "id 0이면 Sound를 만들지 않음 (오류 없음)"
    )
    local silentLoop = Sfx.loop("rover_hit", pad)
    check(silentLoop ~= nil and silentLoop.sound == nil, "id 0 루프도 핸들은 돌려줌")
    silentLoop.stop()
    SoundIds.rover_hit.id = keep
    local played = Sfx.play("rover_hit", pad)
    check(
        played ~= nil
            and played.Parent == pad
            and played.SoundId == "rbxassetid://" .. tostring(keep)
            and played.RollOffMaxDistance == Config.SFX.rollOffMaxDistance
            and played.Looped == false,
        "id가 있으면 한 번 재생하는 Sound (RollOffMaxDistance 120)"
    )
    signalFor(played, "Ended"):Fire()
    advance(0)
    check(played.Parent == nil, "재생이 끝나면 Sound를 지움")
    local handle = Sfx.loop("build_loop", pad)
    local loopSound = handle.sound
    Sfx.setLoopSpeed(handle, 1.2)
    check(
        loopSound ~= nil
            and loopSound.Looped == true
            and math.abs(loopSound.PlaybackSpeed - 1.2) < 1e-4,
        "루프 Sound와 속도 조절"
    )
    handle.stop()
    check(loopSound.Parent == nil, "루프 핸들 stop은 Sound를 지움")
    -- 얼음 채취: 홀드하는 동안 ice_mine_loop
    local ice2 = Workspace.IceSites.Ice2
    local icePrompt2 = ice2:FindFirstChildOfClass("ProximityPrompt")
    signalFor(icePrompt2, "PromptButtonHoldBegan"):Fire(alice)
    advance(0)
    local mining = ice2:FindFirstChild("Sfx_ice_mine_loop")
    check(mining ~= nil and mining.Looped == true, "채취 홀드 시작: 얼음에 ice_mine_loop")
    signalFor(icePrompt2, "PromptButtonHoldEnded"):Fire(alice)
    advance(0)
    check(
        ice2:FindFirstChild("Sfx_ice_mine_loop") == nil,
        "홀드를 놓으면 채취 루프 정지"
    )
    rover.DriverSeat:Sit(humanoid)
    advance(0)
    ResourceState.patch(function(st)
        st.rover.battery = st.rover.batteryMax
    end)
    newRover = rover
end

-- 로버 부스터 (2026-10-18) ---------------------------------------------------
print("[부스터]")
do
    local RoverBattery = loadModule(Server:FindFirstChild("RoverBattery"))
    local RoverBoost = loadModule(Server:FindFirstChild("RoverBoost"))
    local RoverDrive = loadModule(Server:FindFirstChild("RoverDrive"))
    local rv = Config.ROVER
    local boostRemote = dm:GetService("ReplicatedStorage").Remotes.RoverBoost
    local rover = base.Rover
    local chassis = rover.Chassis
    check(rover.DriverSeat.Occupant == humanoid, "Alice가 로버에 타 있음")
    local function request(player, on)
        signalFor(boostRemote, "OnServerEvent"):Fire(player, on)
        advance(0)
    end
    ResourceState.patch(function(st)
        st.rover.battery = rv.batteryMax
        st.rover.boostHeat = 0
    end)
    request(bob, true)
    check(state().rover.boosting == false, "운전자가 아닌 Bob의 부스트 요청 거부")
    ResourceState.patch(function(st)
        st.rover.battery = rv.batteryMax * 0.15
    end)
    request(alice, true)
    check(state().rover.boosting == false, "배터리 15%에서 부스트 거부")
    ResourceState.patch(function(st)
        st.rover.battery = rv.batteryMax
    end)
    request(alice, "yes")
    check(state().rover.boosting == false, "boolean이 아닌 요청 무시")
    request(alice, true)
    check(
        state().rover.boosting == true
            and lastSent("StateUpdate").args[1].rover.boosting == true
            and math.abs(RoverDrive.getSpeedMultiplier() - rv.boostSpeedMultiplier) < 1e-9,
        "부스트: boosting, StateUpdate, 속도 배율 1.6"
    )
    -- 소모 3배: 한 주기(0.25초) 5 studs 이동
    RoverBattery.step(0.25)
    local b0 = state().rover.battery
    chassis.CFrame = chassis.CFrame + Vector3.new(5, 0, 0)
    RoverBattery.step(0.25)
    check(
        math.abs(
            (b0 - state().rover.battery) - rv.batteryDrainPerSecond * 0.25 * rv.boostDrainMultiplier
        ) < 1e-6,
        string.format("부스트 중 소모 3배 (%.3f)", b0 - state().rover.battery)
    )
    chassis.CFrame = chassis.CFrame - Vector3.new(5, 0, 0)
    -- 4초 연속이면 과열로 자동 해제
    local steps = 0
    while state().rover.boosting and steps < 40 do
        RoverBattery.step(0.25)
        steps += 1
    end
    advance(0)
    check(
        state().rover.boosting == false
            and state().rover.boostHeat == 1
            and RoverBoost.isOverheated()
            and RoverDrive.getSpeedMultiplier() == 1,
        string.format(
            "부스트 %.2f초 뒤 과열로 자동 해제 (게이지 1, 속도 배율 1)",
            (steps + 2) * 0.25
        )
    )
    request(alice, true)
    check(state().rover.boosting == false, "과열(쿨다운) 중 부스트 거부")
    -- 6초 동안 식으면 다시 사용 가능
    local cool = 0
    while RoverBoost.isOverheated() and cool < 60 do
        RoverBattery.step(0.25)
        cool += 1
    end
    check(
        not RoverBoost.isOverheated()
            and state().rover.boostHeat == 0
            and math.abs(cool * 0.25 - rv.boostCooldownSeconds) < 0.26,
        string.format("%.2f초 뒤 다 식어 다시 사용 가능", cool * 0.25)
    )
    request(alice, true)
    check(state().rover.boosting == true, "식은 뒤 다시 부스트")
    -- 하차하면 해제 (Lune은 Occupant에 nil을 넣을 수 없어 좌석이 빈 주기를 직접 넣는다)
    local released, changed = RoverBoost.tick(state(), 0.25, true, chassis)
    check(released.rover.boosting == false and changed, "좌석이 비면 부스트 해제")
    -- 배터리가 20% 아래로 내려가면 해제
    ResourceState.patch(function(st)
        st.rover.battery = rv.batteryMax * rv.boostMinBatteryRatio - 0.1
    end)
    RoverBattery.step(0.25)
    advance(0)
    check(
        state().rover.boosting == false and RoverDrive.getSpeedMultiplier() == 1,
        "배터리 부족이면 부스트 해제"
    )
    ResourceState.patch(function(st)
        st.rover.battery = rv.batteryMax
        st.rover.boostHeat = 0
    end)
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
local wasteSentBefore = 0
for _, s in sent do
    if s.name == "Notify" and s.args[1] == Config.TEXTS.energyWasted then
        wasteSentBefore += 1
    end
end
check(padAPrompt.Enabled == false, "건설 중 프롬프트 비활성")
-- 건설 연출 (2026-10-18): 착공하면 Ghost를 숨기고 Built가 완전히 묻힌 자리(바닥 = 지면 - 높이)에서 진행률만큼 올라온다
local Construction = loadModule(Server:FindFirstChild("Construction"))
local risingBuiltA = base.ModulePads.PadA:FindFirstChild("Built")
local builtHeightA = 0
do
    local _, size = risingBuiltA:GetBoundingBox()
    builtHeightA = size.Y
end
check(
    base.ModulePads.PadA:FindFirstChild("Ghost") == nil
        and risingBuiltA ~= nil
        and risingBuiltA.Parent ~= nil,
    "착공하면 Ghost 숨기고 Built가 나타남"
)
check(
    math.abs(Construction.builtOffset("A") + builtHeightA) < 1e-6,
    string.format(
        "착공 직후 Built 완전히 묻힘 (오프셋 %.2f, 높이 %.2f)",
        Construction.builtOffset("A"),
        builtHeightA
    )
)
do
    local anyCollide = false
    for _, d in risingBuiltA:GetDescendants() do
        if d:IsA("BasePart") and d.CanCollide then
            anyCollide = true
        end
    end
    check(not anyCollide, "올라오는 동안 Built 충돌 꺼짐")
end
check(
    math.abs(Construction.riseOffset(10, 0.5) + 5) < 1e-9
        and Construction.riseOffset(10, 0) == -10
        and Construction.riseOffset(10, 1) == 0,
    "riseOffset: 진행률 50%면 높이의 절반만큼 묻힘"
)
local dayStart = state().day
advance(Config.DAY_SECONDS * 2 + Config.BUILD_RISE_SECONDS + 0.1)
do
    local progress = state().modules.A.progress
    local expected = -builtHeightA * (1 - progress)
    check(
        state().modules.A.status == "building"
            and math.abs(progress - 0.4) < 1e-6
            and math.abs(Construction.builtOffset("A") - expected) < 1e-6,
        string.format(
            "진행률 %.0f%%: Built 오프셋 %.2f (기대 %.2f)",
            progress * 100,
            Construction.builtOffset("A"),
            expected
        )
    )
end
advance(
    Config.DAY_SECONDS * Config.MODULES.A.buildDays
        - (Config.DAY_SECONDS * 2 + Config.BUILD_RISE_SECONDS + 0.1)
)
check(state().day == dayStart + 5 and state().modules.A.status == "active", "5일 뒤 A 가동")
check(Construction.builtOffset("A") == 0, "완공하면 Built 최종 위치")
do
    -- 저장 상한: 940을 들고 있으면 첫 DayTick에 상한(150)으로 잘리고 한 번 알린다. 계속 버려지면 5일마다
    local wasteSent = -wasteSentBefore
    for _, s in sent do
        if s.name == "Notify" and s.args[1] == Config.TEXTS.energyWasted then
            wasteSent += 1
            if s.args[2] ~= "warn" then
                wasteSent = -100
            end
        end
    end
    check(
        wasteSent >= 1 and wasteSent <= 2,
        "배터리 가득 참 알림 (warn) " .. wasteSent .. "회 (5일 동안 1 ~ 2회)"
    )
end
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

-- Farm 가동 중지 (2026-10-18) ------------------------------------------------
do
    local padB = base.ModulePads.PadB.Pad
    local pausePrompt = padB:FindFirstChild("PausePrompt")
    local doneB = false
    for _, s in sent do
        if
            s.name == "Notify"
            and string.find(tostring(s.args[1]), "Farm 가동 시작", 1, true) == 1
            and string.find(
                tostring(s.args[1]),
                "물이 모자라면 Farm 패드에서 끌 수 있습니다",
                1,
                true
            )
        then
            doneB = true
        end
    end
    check(doneB, "Farm 완공 알림에 생산과 유지비, 끄는 법")
    check(
        pausePrompt ~= nil
            and pausePrompt:IsA("ProximityPrompt")
            and pausePrompt.ObjectText == "Farm"
            and pausePrompt.ActionText == Config.PROMPT_TEXTS.pauseModule
            and pausePrompt.HoldDuration == 0
            and pausePrompt.MaxActivationDistance == Config.PROMPT.pauseDistance
            and pausePrompt.Style == roblox.Enum.ProximityPromptStyle.Custom
            and pausePrompt.Enabled == true,
        "완공된 Farm 패드에 '가동 중지' 프롬프트 (Farm, 홀드 0, 거리 8, Custom)"
    )
    check(
        base.ModulePads.PadA.Pad:FindFirstChild("PausePrompt") == nil
            and base.ModulePads.PadC.Pad:FindFirstChild("PausePrompt") == nil,
        "Habitat A와 Lab C에는 가동 중지 프롬프트 없음"
    )
    signalFor(pausePrompt, "Triggered"):Fire(alice)
    advance(0)
    local sentState = lastSent("StateUpdate").args[1]
    check(
        state().modules.B.paused == true
            and sentState.modules.B.paused == true
            and sentState.modules.B.upkeepText == Config.TEXTS.upkeepPaused
            and pausePrompt.ActionText == Config.PROMPT_TEXTS.resumeModule
            and lastSent("Notify").args[1] == string.format(Config.TEXTS.modulePaused, "Farm")
            and lastSent("Notify").args[2] == "info",
        "가동 중지: paused, upkeepText '대기 중', 프롬프트 '가동 재개', 알림"
    )
    check(state().modules.C.status == "available", "Farm을 멈춰도 Lab C 착공 가능")
    signalFor(pausePrompt, "Triggered"):Fire(alice)
    advance(0)
    local B = Config.MODULES.B
    sentState = lastSent("StateUpdate").args[1]
    check(
        state().modules.B.paused == false
            and sentState.modules.B.upkeepText == string.format(
                "물 -%d/일, 전력 -%d/일, 식량 +%d/일",
                B.upkeep.water,
                B.upkeep.energy,
                B.foodPerDay
            )
            and pausePrompt.ActionText == Config.PROMPT_TEXTS.pauseModule
            and lastSent("Notify").args[1] == string.format(Config.TEXTS.moduleResumed, "Farm"),
        "가동 재개: upkeepText '" .. tostring(sentState.modules.B.upkeepText) .. "'"
    )
end

-- 배속 ------------------------------------------------------------------
print("[배속]")
-- 허용 배속은 Config.SPEEDS 기준 (2026-10-18: { 1 }만 허용, 2배속 제거)
do
    local base1 = Config.SPEEDS[1]
    check(state().speed == base1, "기본 배속 " .. base1)
    local rejected = { 3, "2", 0 }
    if not table.find(Config.SPEEDS, 2) then
        table.insert(rejected, 2)
    end
    for _, value in rejected do
        signalFor(speedRemote, "OnServerEvent"):Fire(bob, value)
    end
    advance(0)
    check(state().speed == base1, "SPEEDS에 없는 배속 요청 무시 (2 포함)")
    local d0 = state().day
    advance(Config.DAY_SECONDS)
    check(
        state().day == d0 + base1,
        string.format(
            "배속 %d에서 %d초에 %d일 진행",
            base1,
            Config.DAY_SECONDS,
            state().day - d0
        )
    )
    local other = Config.SPEEDS[2]
    if other then
        -- 배속이 다시 허용되면 적용과 쿨다운을 확인한다
        signalFor(speedRemote, "OnServerEvent"):Fire(bob, other)
        advance(0)
        check(state().speed == other, other .. "배속 적용")
        signalFor(speedRemote, "OnServerEvent"):Fire(bob, base1)
        advance(0)
        check(state().speed == other, "1초 쿨다운 안의 재요청 무시")
        advance(Config.SPEED_COOLDOWN_SECONDS + 0.1)
        signalFor(speedRemote, "OnServerEvent"):Fire(bob, base1)
        advance(0)
    end
end

-- 승리 ------------------------------------------------------------------
print("[승리]")
-- 저장 상한 (2026-10-18): A, B 가동이면 150 + 2 x 100. 위에서 넣은 1000은 DayTick마다 상한으로 잘렸다
check(
    state().energyCap == Config.ENERGY_CAP_BASE + 2 * Config.ENERGY_CAP_PER_MODULE
        and state().energy <= state().energyCap
        and lastSent("StateUpdate").args[1].energyCap == state().energyCap,
    string.format(
        "에너지 상한 %d (A, B 가동), 에너지 %.1f",
        state().energyCap,
        state().energy
    )
)
ResourceState.patch(function(s)
    s.energy = Config.MODULES.C.cost.energy + 50
end)
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
        and over.args[1].waterTrips == 2
        and over.args[1].oxygenDeaths == 2,
    "결과 요약 수치 (산소 고갈 1 + 초기화 1)"
)
do
    -- GameOver는 마지막 DayTick 시각에 나갔으므로 지금 기준 남은 시간은 0 초과 10 이하
    local remaining = over.args[1].restartAvailableAt - (1700000000 + now)
    check(
        over.args[1].chooserUserId == 1 and remaining > 0 and remaining <= Config.RESULT_MIN_SECONDS,
        string.format(
            "GameOver: chooserUserId(Alice), restartAvailableAt = 결과 시각 + 10초 (남은 %.1f초)",
            remaining
        )
    )
end
-- 결과 화면 10초 전에는 권한자도 재시작 불가
signalFor(restartRemote, "OnServerEvent"):Fire(alice)
advance(0)
check(
    state().phase == "won"
        and lastSent("Notify").target == alice
        and lastSent("Notify").args[2] == "info"
        and string.find(lastSent("Notify").args[1], "초 뒤에 다시 시작", 1, true) ~= nil,
    "결과 10초 안 재시작 거부 (" .. lastSent("Notify").args[1] .. ")"
)
print("        GameOver: day " .. over.args[1].day .. ", reason " .. over.args[1].reason)
local dayAtWin = state().day
advance(Config.DAY_SECONDS * 3)
check(state().day == dayAtWin, "승리 후 시계 정지")

-- 재시작과 타임아웃 -------------------------------------------------------
do
    -- 서버 효과음 연결 지점 (여기까지 흐름에서 한 번 이상 재생)
    local missing = {}
    for _, key in
        {
            "landing_thrust",
            "interior_hum_loop",
            "panel_install",
            "panel_unfold",
            "oxygen_rescue",
            "rover_board",
            "rover_engine_loop",
            "ice_collected",
            "ice_depleted",
            "water_unload",
            "water_processing",
            "rover_recover",
            "rover_hit",
            "rover_broken",
            "rover_repair",
            "rover_battery_low",
            "rover_dock",
            "rover_charge_loop",
            "rover_charge_full",
            "build_start",
            "build_loop",
            "build_complete",
        }
    do
        if not playedSound(key) then
            table.insert(missing, key)
        end
    end
    check(
        #missing == 0,
        "효과음 연결 지점 재생 (빠짐: " .. table.concat(missing, ", ") .. ")"
    )
end
print("[재시작]")
signalFor(restartRemote, "OnServerEvent"):Fire(bob)
advance(0)
check(
    state().phase == "won"
        and lastSent("Notify").target == bob
        and lastSent("Notify").args[1] == "재시작은 Alice 대원이 할 수 있습니다",
    "권한자가 아닌 Bob의 재시작 거부"
)
humanoid.Sit = true
signalFor(restartRemote, "OnServerEvent"):Fire(alice)
advance(0)
check(humanoid.Sit == false, "재시작 전 전원 하차")
check(
    state().phase == "selecting" and state().day == 0 and state().energy == Config.START.energy,
    "재시작: selecting, 상태 초기화"
)
do
    local ice1r = Workspace.IceSites.Ice1
    local ice2r = Workspace.IceSites.Ice2
    local glow = ice1r:FindFirstChild("IceGlow")
    local light = glow and glow:FindFirstChildOfClass("PointLight")
    check(
        ice1r:GetAttribute("Deposit") == Config.ICE_SITES[1].deposit
            and ice1r:FindFirstChild("MinedPatch") == nil
            and light ~= nil
            and light.Enabled == true
            and ice1r.Transparency < 1
            and math.abs(ice2r.Size.X - 14) < 1e-3
            and state().rover.damage == 0
            and state().rover.battery == Config.ROVER.batteryMax
            and state().rover.charging == false,
        "재시작: 매장량, 결정, 빛, 패치, 로버 파손, 배터리 초기화"
    )
end
check(Workspace:FindFirstChild("Base") == nil, "재시작: Base 제거")
check(
    loadModule(Server:FindFirstChild("Sfx")).loopCount() == 0,
    "재시작: 효과음 루프 모두 정지"
)
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
    check(playedSound("airlock_open"), "문 열림 효과음 airlock_open")
    check(n1 == 1 and kind == "info", "처음 문을 열면 안내 토스트(info) 한 번")
    advance(Config.AIRLOCK.openSeconds + 0.1)
    check(isClosed(), "6초 뒤 다시 닫힘")
    check(playedSound("airlock_close"), "문 닫힘 효과음 airlock_close")
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
-- 결과 화면 중 권한자(Alice)가 나가면 남은 Bob이 권한자가 되고 결과 정보를 다시 받는다
local gameOversBefore = countSent("GameOver")
leave(alice)
check(
    state().phase == "lost" and Workspace:FindFirstChild("Base") ~= nil,
    "한 명 남으면 그대로"
)
check(
    countSent("GameOver") == gameOversBefore + 1 and lastSent("GameOver").args[1].chooserUserId == 2,
    "권한자가 나가면 GameOver를 새 권한자(Bob)로 다시 보냄"
)
local opensBefore = countSent("SiteSelectionOpen")
leave(bob)
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
    math.abs(#greyRocks - #importRocks) <= #greyRocks * 0.05 and #importRocks >= 400,
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
        advance(Config.PANEL_UNFOLD_SECONDS + 0.1) -- 펼침 연출이 끝난 최종 자세를 잰다
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
    -- C까지 완공: B-C 대각선 통로 (에너지 저장 상한 때문에 C 비용을 다시 채운다)
    ResourceState2.patch(function(st)
        st.energy = Config.MODULES.C.cost.energy
    end)
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
    -- 재시작하면 Base 아래 장식은 함께 사라지고 행성은 남는다 (결과 화면 최소 시간 뒤)
    advance(Config.RESULT_MIN_SECONDS + 0.1)
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
