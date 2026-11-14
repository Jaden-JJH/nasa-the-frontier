--!strict
-- v2 우주복 산소 (V2_PLAN Q28, Q3, Q4. docs/CONTRACT_V2.md 4.1 OxygenUpdate, 7.5 산소 구역)
--   야외: MissionConfig.OXYGEN.outdoorSeconds(60초)에 max(100) 소모
--   대피처(shelter): 그대로 유지. 착륙선은 늘, 에어록은 점검 전과 멈춤일 때
--   회복(refill): 가동 중 에어록 안 airlockRefillPerSecond, 로버 운전석 roverSeatRefillPerSecond (초당 2)
--   구역 판정은 MissionWorld.zoneAt(태그 OxygenZone, Attribute ZoneKind)이 한다. 로버 좌석은 MissionFlow가 알려 준다.
--   0이 되면 즉시 실패가 아니라 Rules.recordOxygenRescue(숨은 점수 -100)로 기록하고 에어록 안으로 옮기며 산소를 채운다.
--   playing이 아닐 때는 줄지 않는다(구역만 보낸다).
-- 송신: OxygenUpdate(oxygen, max, zone) 값이나 구역이 바뀌면, 초당 CONFIG.maxUpdatesPerSecond번까지.
-- v1 Oxygen은 v1 상태(ResourceState)와 v1 문장에 묶여 있어 v2용으로 따로 둔다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Rules = require(ReplicatedStorage.Shared.Rules)
local MissionWorld = require(script.Parent.MissionWorld)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

local OxygenV2 = {}

-- 엔진 수준 값 (산소 양과 속도는 MissionConfig.OXYGEN)
OxygenV2.CONFIG = {
    tickSeconds = 0.2,
    maxUpdatesPerSecond = 5,
    lowRatio = 0.2, -- 이 비율 이하로 떨어지면 한 번 경고 (v1 lowWarning 20 / 100)
    rescueLift = 0, -- 구조 이동 지점 위로 더 올리는 높이
}
local CFG = OxygenV2.CONFIG
local RATE_TOLERANCE = 0.9

type Record = {
    oxygen: number,
    zone: string,
    lastSentAt: number,
    lastSentOxygen: number,
    lastSentZone: string,
    lowWarned: boolean,
}

local records: { [Player]: Record } = {}
local initialized = false
local flow: any = nil

local function maxOxygen(): number
    return MissionConfig.OXYGEN.max
end

local function newRecord(): Record
    return {
        oxygen = maxOxygen(),
        zone = "shelter",
        lastSentAt = -math.huge,
        lastSentOxygen = -1,
        lastSentZone = "",
        lowWarned = false,
    }
end

local function send(player: Player, record: Record, now: number)
    record.lastSentAt = now
    record.lastSentOxygen = record.oxygen
    record.lastSentZone = record.zone
    Remotes.get("OxygenUpdate"):FireClient(player, record.oxygen, maxOxygen(), record.zone)
end

local function maybeSend(player: Player, record: Record, now: number)
    if record.zone ~= record.lastSentZone then
        send(player, record, now)
        return
    end
    if record.oxygen == record.lastSentOxygen then
        return
    end
    if now - record.lastSentAt >= (1 / CFG.maxUpdatesPerSecond) * RATE_TOLERANCE then
        send(player, record, now)
    end
end

-- 지금 구역: "refill" | "shelter" | "outside"
function OxygenV2.zoneOf(player: Player): string
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or not root:IsA("BasePart") then
        return "shelter"
    end
    local seat = if flow then flow.roverSeat() else nil
    if seat and humanoid.SeatPart == seat and seat:IsDescendantOf(workspace) then
        return "refill"
    end
    local zone = MissionWorld.zoneAt(root.CFrame.Position)
    return zone
end

local function rateFor(zone: string): number
    local o = MissionConfig.OXYGEN
    if zone == "outside" then
        return -o.max / o.outdoorSeconds
    elseif zone == "refill" then
        return o.airlockRefillPerSecond
    end
    return 0
end

local function seatRate(player: Player): number
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local seat = if flow then flow.roverSeat() else nil
    if humanoid and seat and humanoid.SeatPart == seat then
        return MissionConfig.OXYGEN.roverSeatRefillPerSecond
    end
    return MissionConfig.OXYGEN.airlockRefillPerSecond
end

-- 에어록 안으로 옮긴다 (에어록이 없으면 착륙선)
function OxygenV2.moveInside(player: Player): boolean
    local character = player.Character
    if not character then
        return false
    end
    local shelter = MissionWorld.getShelter("airlock") or MissionWorld.getShelter("lander")
    if not shelter then
        return false
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    ServerUtil.unseat(humanoid)
    local ok = pcall(function()
        character:PivotTo(shelter.inside * CFrame.new(0, CFG.rescueLift, 0))
    end)
    return ok
end

local function rescue(player: Player, record: Record, now: number)
    record.oxygen = 0
    send(player, record, now)
    local character = player.Character
    Sfx.play("oxygen_rescue", character and character:FindFirstChild("HumanoidRootPart"))
    if flow and flow.phase() == "playing" then
        flow.act(player, Rules.recordOxygenRescue, { private = true, okKind = "warn" })
        flow.contribute(player, "rescues", 1)
    end
    OxygenV2.moveInside(player)
    record.oxygen = maxOxygen()
    record.lowWarned = false
    record.zone = OxygenV2.zoneOf(player)
    send(player, record, now)
end

-- 한 주기(dt초) 계산. 서버 루프와 테스트가 같은 경로를 쓴다
function OxygenV2.step(dt: number, now: number)
    local playing = flow ~= nil and flow.phase() == "playing"
    for player, record in records do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 then
            local zone = OxygenV2.zoneOf(player)
            record.zone = zone
            if playing then
                local rate = if zone == "refill" then seatRate(player) else rateFor(zone)
                record.oxygen = math.clamp(record.oxygen + rate * dt, 0, maxOxygen())
                if record.oxygen <= maxOxygen() * CFG.lowRatio then
                    if not record.lowWarned and record.oxygen > 0 then
                        record.lowWarned = true
                        flow.notify(player, Msg.new("toast.oxygen.low"), "warn")
                    end
                else
                    record.lowWarned = false
                end
                if record.oxygen <= 0 then
                    rescue(player, record, now)
                    continue
                end
            end
            maybeSend(player, record, now)
        end
    end
end

-- 지금 산소 (테스트와 진단용)
function OxygenV2.get(player: Player): (number?, string?)
    local record = records[player]
    if not record then
        return nil, nil
    end
    return record.oxygen, record.zone
end

-- 테스트용: 산소 값을 바로 바꾼다
function OxygenV2.set(player: Player, value: number)
    local record = records[player]
    if record then
        record.oxygen = math.clamp(value, 0, maxOxygen())
    end
end

function OxygenV2.addPlayer(player: Player)
    local record = newRecord()
    records[player] = record
    send(player, record, os.clock())
    player.CharacterAdded:Connect(function()
        local current = records[player]
        if current then
            current.oxygen = maxOxygen()
            current.lowWarned = false
            send(player, current, os.clock())
        end
    end)
end

function OxygenV2.removePlayer(player: Player)
    records[player] = nil
end

-- 모두 최대로 (재시작)
function OxygenV2.resetAll()
    local now = os.clock()
    for player, record in records do
        record.oxygen = maxOxygen()
        record.lowWarned = false
        send(player, record, now)
    end
end

function OxygenV2.init(api: any)
    flow = api
    if initialized then
        return
    end
    initialized = true
    task.spawn(function()
        local last = os.clock()
        while true do
            task.wait(CFG.tickSeconds)
            local now = os.clock()
            local dt = now - last
            last = now
            ServerUtil.safeCall("OxygenV2", OxygenV2.step, dt, now)
        end
    end)
    Players.PlayerRemoving:Connect(OxygenV2.removePlayer)
end

return OxygenV2
