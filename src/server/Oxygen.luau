--!strict
-- 플레이어별 우주복 산소 (CONTRACT 3절)
-- 실내 = 로버 DriverSeat 착석, 또는 Workspace.Base 아래 OxygenZone 파트 안.
-- ModulePads.PadX 아래의 OxygenZone은 모듈 X가 가동 중일 때만 실내로 친다 (Habitat A 산소 회복 지점).
-- 0이 되면 즉시 임무 실패(GameFlow, 2026-10-18). Reset Character 같은 다른 사망은 Food, Water 페널티 후 착륙선 리스폰.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type GameState = Simulation.GameState
type Record = {
    oxygen: number,
    inside: boolean,
    lastSentAt: number,
    lastSentOxygen: number,
    lastSentInside: boolean,
    lowWarned: boolean, -- 산소 부족 경고를 이번 하락에서 이미 보냈는지
    rescuing: boolean, -- 산소 고갈 구조 처리 중 (이 사이의 사망은 초기화 페널티를 다시 매기지 않는다)
}
type Zone = { part: BasePart, moduleId: string? }

local Oxygen = {}

-- 0.2초 주기의 타이밍 흔들림 때문에 송신이 한 틱씩 밀리지 않도록 최소 간격에 주는 여유 비율
local RATE_TOLERANCE = 0.9

local records: { [Player]: Record } = {}
local zones: { Zone } = {}
local initialized = false

local function newRecord(): Record
    return {
        oxygen = Config.OXYGEN.max,
        inside = true,
        lastSentAt = 0,
        lastSentOxygen = -1,
        lastSentInside = false,
        lowWarned = false,
        rescuing = false,
    }
end

local function send(player: Player, record: Record, now: number)
    record.lastSentAt = now
    record.lastSentOxygen = record.oxygen
    record.lastSentInside = record.inside
    Remotes.get("OxygenUpdate"):FireClient(player, record.oxygen, Config.OXYGEN.max, record.inside)
end

local function maybeSend(player: Player, record: Record, now: number)
    local changed = record.oxygen ~= record.lastSentOxygen or record.inside ~= record.lastSentInside
    local minInterval = 1 / Config.OXYGEN.maxUpdatesPerSecond
    if changed and now - record.lastSentAt >= minInterval * RATE_TOLERANCE then
        send(player, record, now)
    end
end

-- OxygenZone 파트가 어느 모듈 패드 아래에 있는지 (없으면 nil = 항상 유효)
local function moduleIdOf(zone: BasePart, base: Model): string?
    local pads = base:FindFirstChild("ModulePads")
    if not pads then
        return nil
    end
    for _, id in Config.MODULE_ORDER do
        local padModel = pads:FindFirstChild("Pad" .. id)
        if padModel and zone:IsDescendantOf(padModel) then
            return id
        end
    end
    return nil
end

local function isZoneActive(zone: Zone, state: GameState): boolean
    if zone.moduleId == nil then
        return true
    end
    local m = state.modules[zone.moduleId]
    return m ~= nil and m.status == "active"
end

local function isInside(humanoid: Humanoid, position: Vector3, state: GameState): boolean
    local seat = ServerUtil.getRoverSeat()
    if seat and humanoid.SeatPart == seat then
        return true
    end
    for _, zone in zones do
        if
            zone.part:IsDescendantOf(workspace)
            and isZoneActive(zone, state)
            and ServerUtil.isInsidePart(zone.part, position)
        then
            return true
        end
    end
    return false
end

-- 산소 0: 즉시 임무 실패 (2026-10-18 사용자 결정). 게임 종료는 GameFlow가 setDepletedHandler로 맡긴 함수가 한다.
-- 구조(착륙선 이동)와 Food, Water 페널티는 하지 않는다 (다른 사망의 페널티는 onDied에 그대로)
local depletedHandler: ((Player) -> ())? = nil

function Oxygen.setDepletedHandler(handler: (Player) -> ())
    depletedHandler = handler
end

local function onDepleted(player: Player, record: Record, now: number)
    record.rescuing = true
    record.oxygen = 0
    send(player, record, now)
    local character = player.Character
    Sfx.play("oxygen_rescue", character and character:FindFirstChild("HumanoidRootPart"))
    local handler = depletedHandler
    if handler then
        handler(player)
    end
    record.rescuing = false
end

-- 캐릭터 초기화(Reset Character)나 추락사로 죽으면 산소 고갈 구조와 같은 페널티 (리뷰 I17).
-- 산소 고갈 구조는 캐릭터를 죽이지 않고 착륙선으로 옮기므로 겹치지 않지만, 구조 중 플래그로 한 번 더 막는다
local function onDied(player: Player)
    local record = records[player]
    if not record or record.rescuing then
        return
    end
    local state = ResourceState.get()
    if state.phase ~= "playing" or not ServerUtil.getBase() then
        return
    end
    local penalty = Config.OXYGEN.deathPenalty
    ResourceState.set(Simulation.applyOxygenDeath(state, Config))
    ResourceState.notify(
        player,
        string.format(Config.TEXTS.resetPenalty, penalty.food, penalty.water),
        "warn"
    )
    ResourceState.notifyOthers(
        player,
        string.format(
            Config.TEXTS.resetPenaltyOther,
            player.DisplayName,
            penalty.food,
            penalty.water
        ),
        "warn"
    )
    ResourceState.publish()
end

-- 캐릭터의 Humanoid.Died에 페널티 처리를 연결한다
local function watchDeath(player: Player, character: Model)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        local found = character:WaitForChild("Humanoid", Config.CHARACTER_LOAD_TIMEOUT)
        humanoid = if found and found:IsA("Humanoid") then found else nil
    end
    if humanoid then
        humanoid.Died:Connect(function()
            onDied(player)
        end)
    end
end

local function step(dt: number, now: number)
    local state = ResourceState.get()
    if state.phase ~= "playing" then
        return
    end
    local o = Config.OXYGEN
    -- 태양 입자 폭풍 중에는 실외 소모만 늘어난다 (2026-10-18 15차. 실내와 로버 좌석은 그대로 회복)
    local drain = o.drainPerSecond * Simulation.outdoorOxygenMultiplier(state, Config)
    for player, record in records do
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
            local inside = isInside(humanoid, root.CFrame.Position, state)
            local rate = if inside then o.refillPerSecond else -drain
            record.oxygen = math.clamp(record.oxygen + rate * dt, 0, o.max)
            record.inside = inside
            -- 산소 부족 경고: 하락할 때 한 번, lowWarning 위로 회복하면 다시 경고할 수 있다
            if record.oxygen <= o.lowWarning then
                if not record.lowWarned then
                    record.lowWarned = true
                    ResourceState.notify(player, Config.TEXTS.lowOxygen, "warn")
                end
            else
                record.lowWarned = false
            end
            if record.oxygen <= 0 then
                onDepleted(player, record, now)
                -- 임무가 끝났으면 다른 플레이어는 더 계산하지 않는다
                state = ResourceState.get()
                if state.phase ~= "playing" then
                    return
                end
            else
                maybeSend(player, record, now)
            end
        end
    end
end

function Oxygen.addPlayer(player: Player)
    local record = newRecord()
    records[player] = record
    send(player, record, os.clock())
    -- 다른 이유로 죽어 리스폰하면 산소를 채워 준다 (페널티는 Died에서 이미 매겼다)
    player.CharacterAdded:Connect(function(character: Model)
        local current = records[player]
        if current then
            current.oxygen = Config.OXYGEN.max
            current.inside = true
            send(player, current, os.clock())
        end
        watchDeath(player, character)
    end)
    local existing = player.Character
    if existing then
        task.spawn(watchDeath, player, existing)
    end
end

function Oxygen.removePlayer(player: Player)
    records[player] = nil
end

-- 모든 플레이어 산소를 최대로 (재시작)
function Oxygen.resetAll()
    local now = os.clock()
    for player, record in records do
        record.oxygen = Config.OXYGEN.max
        record.inside = true
        send(player, record, now)
    end
end

-- 새 기지의 OxygenZone 목록을 모은다.
-- Construction.attach가 Built를 빼기 전에 불러야 Built 안에 둔 구역도 잡힌다.
function Oxygen.attach(base: Model)
    table.clear(zones)
    local habitatZone = false
    for _, descendant in base:GetDescendants() do
        if descendant.Name == "OxygenZone" and descendant:IsA("BasePart") then
            local moduleId = moduleIdOf(descendant, base)
            table.insert(zones, { part = descendant, moduleId = moduleId })
            if moduleId == Config.OXYGEN.habitatModule then
                habitatZone = true
            end
        end
    end
    if not habitatZone then
        warn(
            string.format(
                "[Oxygen] Pad%s에서 OxygenZone을 찾지 못했습니다. 완공 후에도 산소가 회복되지 않습니다",
                Config.OXYGEN.habitatModule
            )
        )
    end
end

function Oxygen.detach()
    table.clear(zones)
end

-- 산소 계산 루프 시작 (한 번만)
function Oxygen.init()
    if initialized then
        return
    end
    initialized = true
    task.spawn(function()
        local last = os.clock()
        while true do
            task.wait(Config.OXYGEN.tickSeconds)
            local now = os.clock()
            local dt = now - last
            last = now
            ServerUtil.safeCall("Oxygen", step, dt, now)
        end
    end)
    Players.PlayerRemoving:Connect(Oxygen.removePlayer)
end

return Oxygen
