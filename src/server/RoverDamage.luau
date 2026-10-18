--!strict
-- 로버 파손과 수리 (2026-10-18, CONTRACT 3절 RoverDamage)
--   감지: 로버의 모든 파트(섀시, 바퀴)의 Touched. 상대가 바위(자신이나 조상에 Attribute BoulderLayer)이고
--         충돌 속도가 Config.ROVER_DAMAGE.speedThreshold 이상이면 파손 +1 (hitCooldown초 안의 연속 접촉은 한 번).
--         충돌 속도 = max(접촉 순간 섀시 AssemblyLinearVelocity 크기, 직전 Heartbeat에 잰 크기).
--         Touched가 오는 시점에는 충돌 반발로 속도가 이미 줄어 있을 수 있어 직전 프레임 값을 같이 본다.
--   효과: RoverDrive가 Simulation.roverSpeedMultiplier(파손)로 바퀴 모터 속도를 줄인다 (3이면 0, 고장).
--   수리: 섀시의 "수리" 프롬프트(키 R, 홀드 repairHold초, 거리 promptDistance). 파손 > 0이고 좌석이 비었을 때만.
--         기지 에너지 repairEnergy를 내고 파손 0. 로버 복구(RoverRecovery)도 파손을 0으로 되돌린다.
--   Config.ROVER_DAMAGE.enabled = false면 아무 것도 연결하지 않는다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Contributions = require(script.Parent.Contributions)
local ResourceState = require(script.Parent.ResourceState)
local RoverDrive = require(script.Parent.RoverDrive)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

local RoverDamage = {}

local connections: { RBXScriptConnection } = {}
local repairPrompt: ProximityPrompt? = nil
local currentSeat: VehicleSeat? = nil
local chassis: BasePart? = nil
local lastHitAt = -math.huge -- os.clock 기준 마지막으로 파손을 센 시각
local sampledSpeed = 0 -- 직전 Heartbeat의 섀시 속도

-- 맞은 파트가 바위인지: 자신이나 조상(바위 메시 Model)에 Attribute BoulderLayer
local function isBoulder(hit: Instance): boolean
    local current: Instance? = hit
    while current and current ~= workspace do
        if current:GetAttribute("BoulderLayer") ~= nil then
            return true
        end
        current = current.Parent
    end
    return false
end

-- 수리 프롬프트 활성: 플레이 중, 파손 > 0, 좌석 비어 있음
function RoverDamage.refresh()
    local prompt = repairPrompt
    if not prompt then
        return
    end
    local state = ResourceState.get()
    -- 로버를 다시 만드는 중이면 예전 좌석이 지워져 있으므로 매번 지금 로버의 좌석을 찾는다
    local seat = ServerUtil.getRoverSeat()
    if not seat then
        return -- 로버가 사라졌다 (복구가 다시 만들고 attach를 다시 부른다)
    end
    prompt.Enabled = state.phase == "playing" and state.rover.damage > 0 and seat.Occupant == nil
end

-- 상태의 파손 값을 구동과 프롬프트에 반영한다 (상태를 바꾼 뒤 부른다)
function RoverDamage.sync()
    RoverDrive.setSpeedMultiplier(
        if Config.ROVER_DAMAGE.enabled
            then Simulation.roverSpeedMultiplier(ResourceState.get().rover.damage, Config)
            else 1
    )
    RoverDamage.refresh()
end

-- 충돌 한 번 처리. 테스트와 Touched가 같은 경로를 쓴다. 파손을 셌으면 true
function RoverDamage.registerHit(speed: number): boolean
    local d = Config.ROVER_DAMAGE
    if not d.enabled then
        return false
    end
    local state = ResourceState.get()
    if state.phase ~= "playing" or speed < d.speedThreshold then
        return false
    end
    local now = os.clock()
    if now - lastHitAt < d.hitCooldown then
        return false
    end
    local new, changed = Simulation.applyRoverHit(state, Config)
    if not changed then
        return false
    end
    lastHitAt = now
    ResourceState.set(new)
    local t = Config.TEXTS
    local damage, max = new.rover.damage, d.maxDamage
    local seat = currentSeat
    local driver = if seat then ServerUtil.playerFromHumanoid(seat.Occupant) else nil
    if driver then
        ResourceState.notify(driver, string.format(t.roverHitDriver, damage, max), "warn")
        ResourceState.notifyOthers(driver, string.format(t.roverHitOthers, damage, max), "warn")
    else
        ResourceState.notifyAll(string.format(t.roverHitOthers, damage, max), "warn")
    end
    Sfx.play("rover_hit", chassis)
    if new.rover.broken then
        ResourceState.notifyAll(t.roverBroken, "warn")
        Sfx.play("rover_broken", chassis)
    end
    RoverDamage.sync()
    ResourceState.publish()
    return true
end

-- 수리 홀드 동안 공구 소리 루프
local repairLoop: Sfx.Handle? = nil
local function stopRepairLoop()
    local handle = repairLoop
    repairLoop = nil
    if handle then
        handle.stop()
    end
end

local function onTouched(hit: BasePart)
    if not isBoulder(hit) then
        return
    end
    local body = chassis
    local speed = sampledSpeed
    if body then
        speed = math.max(speed, body.AssemblyLinearVelocity.Magnitude)
    end
    RoverDamage.registerHit(speed)
end

local function onRepair(player: Player)
    local seat = currentSeat
    if seat and seat.Occupant ~= nil then
        ResourceState.notify(player, Config.TEXTS.repairOccupied, "warn")
        return
    end
    local ok, new, message, kind = Simulation.repairRover(ResourceState.get(), Config)
    if not ok then
        ResourceState.notify(player, message, ResourceState.kind(kind))
        return
    end
    ResourceState.set(new)
    Contributions.add(player, "repairs", 1)
    ResourceState.notifyAll(message, ResourceState.kind(kind))
    stopRepairLoop()
    Sfx.play("rover_repair", chassis)
    RoverDamage.sync()
    ResourceState.publish()
end

-- 새 기지(또는 다시 만든 로버)에 연결
function RoverDamage.attach(base: Model)
    RoverDamage.detach()
    local d = Config.ROVER_DAMAGE
    if not d.enabled then
        RoverDrive.setSpeedMultiplier(1)
        return
    end
    local rover = ServerUtil.findModel(base, "Rover")
    local seat = ServerUtil.getRoverSeat()
    if not rover or not seat then
        return
    end
    local body: BasePart = rover.PrimaryPart or seat
    currentSeat = seat
    chassis = body
    for _, descendant in rover:GetDescendants() do
        if descendant:IsA("BasePart") then
            table.insert(connections, descendant.Touched:Connect(onTouched))
        end
    end
    table.insert(
        connections,
        RunService.Heartbeat:Connect(function()
            sampledSpeed = body.AssemblyLinearVelocity.Magnitude
        end)
    )
    table.insert(
        connections,
        seat:GetPropertyChangedSignal("Occupant"):Connect(RoverDamage.refresh)
    )
    local prompt = ServerUtil.makePrompt(body, {
        actionText = Config.PROMPT_TEXTS.repairRover,
        objectText = Config.PROMPT_TEXTS.roverObject,
        holdDuration = d.repairHold,
        maxDistance = d.promptDistance,
        enabled = false,
    })
    prompt.KeyboardKeyCode = (Enum.KeyCode :: any)[d.repairKey]
    repairPrompt = prompt
    table.insert(connections, prompt.Triggered:Connect(onRepair))
    table.insert(
        connections,
        prompt.PromptButtonHoldBegan:Connect(function()
            stopRepairLoop()
            repairLoop = Sfx.loop("rover_repair", body)
        end)
    )
    table.insert(connections, prompt.PromptButtonHoldEnded:Connect(stopRepairLoop))
    RoverDamage.sync()
end

function RoverDamage.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    stopRepairLoop()
    if repairPrompt then
        repairPrompt:Destroy()
        repairPrompt = nil
    end
    currentSeat = nil
    chassis = nil
    sampledSpeed = 0
    lastHitAt = -math.huge
end

return RoverDamage
