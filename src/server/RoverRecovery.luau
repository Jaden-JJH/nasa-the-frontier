--!strict
-- 로버 복구: 기지가 놓일 때 로버 홈 위치를 저장하고, 아래 경우 홈으로 되돌린다.
--   수동: 착륙선 콘솔(Lander.RoverConsole, 없으면 SpawnPoint)의 "로버 복구" 프롬프트. 운전석이 비어 있을 때만
--   자동: 무인 상태로 뒤집힌 채 Config.ROVER_RECOVERY.flipSeconds 이상, 또는 Origin보다 fallDepth 아래로 추락
--   소실: DriverSeat가 사라졌으면(FallenPartsDestroyHeight 등) ServerStorage.BaseKit.Rover를 다시 복제
-- 악용 차단 (리뷰 I01): 복구하면 탱크의 물은 잃고(물 순간 운송 금지), 복구 뒤 cooldownSeconds 동안은
-- 수동과 자동 모두 다시 복구하지 않는다. 쿨다운 중 프롬프트 ActionText에 남은 초를 보인다.
-- 복구하면 로버 파손(RoverDamage)도 0으로 되돌린다 (2026-10-18). 탱크와 쿨다운 규칙은 그대로.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ResourceState = require(script.Parent.ResourceState)
local RoverDamage = require(script.Parent.RoverDamage)
local RoverDrive = require(script.Parent.RoverDrive)
local ServerUtil = require(script.Parent.ServerUtil)
local WaterLoop = require(script.Parent.WaterLoop)

local RoverRecovery = {}

local currentBase: Model? = nil
local homePivot: CFrame? = nil
local prompt: ProximityPrompt? = nil
local connections: { RBXScriptConnection } = {}
local flippedSince: number? = nil
local cooldownUntil = 0 -- os.clock 기준 다음 복구 가능 시각 (수동, 자동 공용)
local initialized = false

local function cooldownRemaining(now: number): number
    return math.max(0, cooldownUntil - now)
end

-- 프롬프트 문구: 쿨다운 중이면 남은 초
local function updatePromptText(now: number)
    local current = prompt
    if not current then
        return
    end
    local remaining = cooldownRemaining(now)
    local text = if remaining > 0
        then string.format(Config.PROMPT_TEXTS.recoverCooldown, math.ceil(remaining))
        else Config.PROMPT_TEXTS.recoverRover
    if current.ActionText ~= text then
        current.ActionText = text
    end
end

local function resetMotion(model: Model)
    for _, descendant in model:GetDescendants() do
        if descendant:IsA("BasePart") then
            descendant.AssemblyLinearVelocity = Vector3.zero
            descendant.AssemblyAngularVelocity = Vector3.zero
        end
    end
end

-- 추락 판정 기준 높이: 기지 Origin, 없으면 로버 홈 위치
local function referenceY(base: Model, home: CFrame): number
    local origin = base.PrimaryPart or ServerUtil.findPart(base, "Origin")
    if origin then
        return origin.CFrame.Position.Y
    end
    return home.Position.Y
end

-- 로버를 홈 위치로 되돌린다. 탱크는 비우고 쿨다운을 시작한다. 성공하면 true.
-- 운전석 검사와 쿨다운 검사는 호출하는 쪽(수동 프롬프트, 자동 검사)이 한다
function RoverRecovery.recover(): boolean
    local base = currentBase
    local home = homePivot
    if not base or not home or not base:IsDescendantOf(workspace) then
        return false
    end
    local rover = ServerUtil.findModel(base, "Rover")
    local seat = ServerUtil.getRoverSeat()
    if rover and seat and seat:IsDescendantOf(rover) then
        ServerUtil.unseat(seat.Occupant)
        rover:PivotTo(home)
        resetMotion(rover)
    else
        local template = ServerUtil.findModel(ServerStorage:FindFirstChild("BaseKit"), "Rover")
        if not template then
            warn(
                "[RoverRecovery] ServerStorage.BaseKit.Rover가 없어 로버를 다시 만들 수 없습니다"
            )
            return false
        end
        if rover then
            rover:Destroy()
        end
        local fresh = template:Clone()
        fresh:PivotTo(home)
        fresh.Parent = base
        RoverDrive.attach(base)
        RoverDamage.attach(base)
    end
    -- 물 유실: 복구는 물을 기지로 옮겨 주지 않는다. 파손은 복구와 함께 고쳐진다
    local lostWater = ResourceState.get().rover.tank > 0
    ResourceState.patch(function(s)
        s.rover.tank = 0
        s.rover.damage = 0
        s.rover.broken = false
    end)
    RoverDamage.sync()
    WaterLoop.mirrorTank()
    WaterLoop.refresh()
    flippedSince = nil
    local now = os.clock()
    cooldownUntil = now + Config.ROVER_RECOVERY.cooldownSeconds
    updatePromptText(now)
    ResourceState.notifyAll(Config.TEXTS.roverRecovered, "info")
    if lostWater then
        ResourceState.notifyAll(Config.TEXTS.tankLostOnRecover, "warn")
    end
    ResourceState.publish()
    return true
end

-- 수동 복구 요청 (콘솔 프롬프트)
local function onManualRecover(player: Player)
    if ResourceState.get().phase ~= "playing" then
        return
    end
    local seat = ServerUtil.getRoverSeat()
    if seat and seat.Occupant ~= nil then
        ResourceState.notify(player, Config.TEXTS.roverOccupied, "warn")
        return
    end
    local remaining = cooldownRemaining(os.clock())
    if remaining > 0 then
        ResourceState.notify(
            player,
            string.format(Config.TEXTS.recoverCooldown, math.ceil(remaining)),
            "info"
        )
        return
    end
    RoverRecovery.recover()
end

-- 1초 주기 자동 검사. 쿨다운 중에는 자동 복구도 기다린다
local function check(now: number)
    updatePromptText(now)
    local base = currentBase
    local home = homePivot
    if not base or not home or not base:IsDescendantOf(workspace) then
        return
    end
    local cooling = cooldownRemaining(now) > 0
    local seat = ServerUtil.getRoverSeat()
    if not seat then
        if not cooling then
            RoverRecovery.recover()
        end
        return
    end
    local r = Config.ROVER_RECOVERY
    local position = seat.CFrame.Position
    if position.Y < referenceY(base, home) - r.fallDepth then
        if not cooling then
            RoverRecovery.recover()
        end
        return
    end
    local flipped = seat.Occupant == nil and seat.CFrame.UpVector.Y < r.flipUpY
    if not flipped then
        flippedSince = nil
        return
    end
    local since = flippedSince
    if since == nil then
        flippedSince = now
    elseif now - since >= r.flipSeconds and not cooling then
        RoverRecovery.recover()
    end
end

-- 수동 복구 프롬프트는 playing일 때만 활성
function RoverRecovery.refresh()
    local current = prompt
    if current then
        current.Enabled = ResourceState.get().phase == "playing"
    end
end

-- 새 기지에 연결. 기지가 막 놓인 직후(물리 시작 전)에 불러야 홈 위치가 정확하다
function RoverRecovery.attach(base: Model)
    RoverRecovery.detach()
    currentBase = base
    local rover = ServerUtil.findModel(base, "Rover")
    if rover then
        homePivot = rover:GetPivot()
    else
        warn("[RoverRecovery] Base.Rover를 찾지 못했습니다")
    end
    local lander = ServerUtil.findModel(base, "Lander")
    local anchor = ServerUtil.findPart(lander, "RoverConsole")
        or ServerUtil.findPart(lander, "SpawnPoint")
    if not anchor then
        warn(
            "[RoverRecovery] Lander.RoverConsole 또는 SpawnPoint가 없어 복구 프롬프트를 만들지 못했습니다"
        )
        return
    end
    local newPrompt = ServerUtil.makePrompt(anchor, {
        actionText = Config.PROMPT_TEXTS.recoverRover,
        objectText = Config.PROMPT_TEXTS.recoverObject,
        holdDuration = Config.ROVER_RECOVERY.hold,
        maxDistance = Config.ROVER_RECOVERY.promptDistance,
        enabled = false,
    })
    prompt = newPrompt
    table.insert(connections, newPrompt.Triggered:Connect(onManualRecover))
    RoverRecovery.refresh()
end

function RoverRecovery.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    if prompt then
        prompt:Destroy()
        prompt = nil
    end
    currentBase = nil
    homePivot = nil
    flippedSince = nil
    cooldownUntil = 0
end

-- 자동 검사 루프 시작 (한 번만)
function RoverRecovery.init()
    if initialized then
        return
    end
    initialized = true
    task.spawn(function()
        while true do
            task.wait(Config.ROVER_RECOVERY.checkSeconds)
            ServerUtil.safeCall("RoverRecovery", check, os.clock())
        end
    end)
end

return RoverRecovery
