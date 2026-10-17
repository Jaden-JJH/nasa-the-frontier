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

local cache = {}
local loadModule
local function makeEnv(scriptInst)
    return {
        script = scriptInst,
        game = dm,
        workspace = dm:GetService("Workspace"),
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
            table.insert(warnings, text)
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
local Shared = dm:GetService("ReplicatedStorage"):FindFirstChild("Shared")
local Workspace = dm:GetService("Workspace")
local ServerStorage = dm:GetService("ServerStorage")

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
character.Parent = Workspace
alice.Character = character

table.insert(players, alice)
signalFor(PlayersService, "PlayerAdded"):Fire(alice)
advance(0)
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
check(installPrompt.ActionText == "내일 다시", "한도 도달 시 프롬프트 '내일 다시'")
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

advance(Config.DAY_SECONDS)
check(
    state().day == 2 and state().energy == 3 and state().panelsInstalledToday == 0,
    "DayTick: day 2, energy 3, 오늘 설치 초기화"
)
check(installPrompt.ActionText == "패널 설치", "다음 날 프롬프트 복귀")

-- 산소: 야외에 세워 두면 고갈 ---------------------------------------------
print("[산소]")
root.CFrame = CFrame.new(pad1.CFrame.Position + Vector3.new(0, 3, 200))
local deathsBefore = state().oxygenDeaths
advance(61)
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

-- 건설 -----------------------------------------------------------------
print("[건설]")
local padAPrompt = base.ModulePads.PadA.Pad:FindFirstChildOfClass("ProximityPrompt")
local padBPrompt = base.ModulePads.PadB.Pad:FindFirstChildOfClass("ProximityPrompt")
local padCPrompt = base.ModulePads.PadC.Pad:FindFirstChildOfClass("ProximityPrompt")
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
    state().phase == "selecting" and state().day == 0 and state().energy == 0,
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
