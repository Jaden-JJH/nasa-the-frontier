--!strict
-- 로버 부스터 (2026-10-18, CONTRACT RoverBoost Remote)
--   요청: RoverBoost(on: boolean). 보낸 플레이어가 DriverSeat 탑승자이고, 플레이 중이고, 배터리가
--         ROVER.boostMinBatteryRatio 이상이고, 과열(쿨다운) 중이 아니어야 켠다. 조건이 안 맞으면 조용히 무시한다.
--   효과: RoverDrive 속도 요소 "boost" = boostSpeedMultiplier, RoverBattery 소모 x boostDrainMultiplier,
--         섀시에 rover_boost_loop.
--   과열: 부스트 중 초당 1/boostMaxSeconds 증가, 1이면 꺼지고 과열. 아닐 때 초당 1/boostCooldownSeconds 감소,
--         과열 뒤 0까지 식으면 다시 쓸 수 있고 rover_boost_ready 1회.
--   자동 해제: 하차(좌석 빔), 배터리 부족(비율 미만), 과열. 계산은 RoverBattery 주기(tick)에서 같이 한다.
--   시각 효과 (Config.ROVER.boostFx): 섀시 뒤쪽 양옆 Attachment의 불꽃 ParticleEmitter(뒤쪽으로 뿜음),
--         뒤쪽 하늘색 PointLight, 바퀴 색 살짝 밝게. 켜는 순간 burst, 과열로 꺼지면 회색 연기 한 번.
--         Highlight는 쓰지 않는다(목표 Highlight와 충돌). 로버를 다시 만들면 attach를 다시 부른다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local RoverDrive = require(script.Parent.RoverDrive)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type GameState = Simulation.GameState

local RoverBoost = {}

local overheated = false -- 과열로 꺼진 뒤 아직 0까지 식지 않음
local boostLoop: Sfx.Handle? = nil
local initialized = false

-- 지금 로버에 붙인 시각 효과
type Fx = {
    flames: { ParticleEmitter },
    smoke: ParticleEmitter?,
    light: PointLight?,
    wheels: { [BasePart]: Color3 }, -- 바퀴와 원래 색
    on: boolean,
}
local fx: Fx = { flames = {}, smoke = nil, light = nil, wheels = {}, on = false }

local function rgb(values: { number }): Color3
    return Color3.fromRGB(values[1], values[2], values[3])
end

local function makeEmitter(parent: Attachment, name: string): ParticleEmitter
    local f = Config.ROVER.boostFx
    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = name
    emitter.Rate = 0
    emitter.Lifetime = NumberRange.new(f.lifetime[1], f.lifetime[2])
    emitter.Speed = NumberRange.new(f.speed[1], f.speed[2])
    emitter.Size = NumberSequence.new(f.size[1], f.size[2])
    emitter.Transparency = NumberSequence.new(f.transparency[1], f.transparency[2])
    emitter.LightEmission = 1
    emitter.Color = ColorSequence.new(rgb(f.color), rgb(f.colorEnd))
    emitter.SpreadAngle = Vector2.new(f.spread, f.spread)
    emitter.EmissionDirection = Enum.NormalId.Back -- 섀시 뒤쪽(+Z, 로버 앞은 -Z)
    emitter.Parent = parent
    return emitter
end

-- 섀시 뒤쪽 양옆에 불꽃, 뒤쪽 가운데에 빛과 연기. 바퀴(이름이 Wheel로 시작하는 파트) 원래 색 저장
function RoverBoost.attach(base: Model)
    RoverBoost.detachFx()
    local rover = ServerUtil.findModel(base, "Rover")
    local chassis = rover and rover.PrimaryPart
    if not rover or not chassis then
        return
    end
    local f = Config.ROVER.boostFx
    local half = chassis.Size / 2
    for _, side in { -1, 1 } do
        local a = Instance.new("Attachment")
        a.Name = "BoostFlame"
        a.Position = Vector3.new(side * (half.X - f.sideInset), 0, half.Z)
        a.Parent = chassis
        table.insert(fx.flames, makeEmitter(a, "BoostFlames"))
    end
    local center = Instance.new("Attachment")
    center.Name = "BoostRear"
    center.Position = Vector3.new(0, 0, half.Z)
    center.Parent = chassis
    local light = Instance.new("PointLight")
    light.Name = "BoostLight"
    light.Color = rgb(f.color)
    light.Range = f.lightRange
    light.Brightness = f.lightBrightness
    light.Enabled = false
    light.Parent = center
    fx.light = light
    local smoke = Instance.new("ParticleEmitter")
    smoke.Name = "BoostSmoke"
    smoke.Rate = 0
    smoke.Lifetime = NumberRange.new(f.smokeLifetime)
    smoke.Speed = NumberRange.new(f.smokeSpeed)
    smoke.Size = NumberSequence.new(f.smokeSize[1], f.smokeSize[2])
    smoke.Transparency = NumberSequence.new(f.smokeTransparency[1], f.smokeTransparency[2])
    smoke.Color = ColorSequence.new(rgb(f.smokeColor))
    smoke.EmissionDirection = Enum.NormalId.Top
    smoke.Parent = center
    fx.smoke = smoke
    for _, descendant in rover:GetDescendants() do
        if descendant:IsA("BasePart") and string.sub(descendant.Name, 1, 5) == "Wheel" then
            fx.wheels[descendant] = descendant.Color
        end
    end
    fx.on = false
end

-- 효과 참조를 비운다 (인스턴스는 로버와 함께 지워진다). 바퀴 색은 되돌린다
function RoverBoost.detachFx()
    for wheel, color in fx.wheels do
        -- 예전 로버가 이미 지워졌을 수 있다
        pcall(function()
            wheel.Color = color
        end)
    end
    fx = { flames = {}, smoke = nil, light = nil, wheels = {}, on = false }
end

-- 부스트 켜짐/꺼짐을 효과에 반영. 켜지는 순간 burst
local function setFx(on: boolean)
    if fx.on == on then
        return
    end
    fx.on = on
    local f = Config.ROVER.boostFx
    for _, emitter in fx.flames do
        emitter.Rate = if on then f.rate else 0
        if on then
            emitter:Emit(f.burst)
        end
    end
    local light = fx.light
    if light then
        light.Enabled = on
    end
    local white = Color3.new(1, 1, 1)
    for wheel, color in fx.wheels do
        wheel.Color = if on then color:Lerp(white, f.wheelBrighten) else color
    end
end

-- 테스트용: 지금 효과 참조
function RoverBoost.getFx(): Fx
    return fx
end

local function stopLoop()
    local handle = boostLoop
    boostLoop = nil
    if handle then
        handle.stop()
    end
end

-- 상태의 boosting을 속도 요소와 부스트 루프에 반영한다
function RoverBoost.apply(state: GameState)
    local boosting = state.rover.boosting
    RoverDrive.setSpeedFactor("boost", if boosting then Config.ROVER.boostSpeedMultiplier else 1)
    setFx(boosting)
    if boosting and not boostLoop then
        local rover = ServerUtil.findModel(ServerUtil.getBase(), "Rover")
        boostLoop = Sfx.loop("rover_boost_loop", rover and rover.PrimaryPart)
    elseif not boosting then
        stopLoop()
    end
end

function RoverBoost.isOverheated(): boolean
    return overheated
end

-- 원격 요청 처리 (테스트도 같은 경로를 쓴다)
function RoverBoost.request(player: Player, on: any)
    if typeof(on) ~= "boolean" then
        return
    end
    local seat = ServerUtil.getRoverSeat()
    if not seat or ServerUtil.playerFromHumanoid(seat.Occupant) ~= player then
        return
    end
    local state = ResourceState.get()
    if on == state.rover.boosting then
        return
    end
    if on and not Simulation.canBoost(state, Config, overheated) then
        return
    end
    ResourceState.patch(function(s)
        s.rover.boosting = on
        Simulation.refreshDerived(s, Config)
    end)
    RoverBoost.apply(ResourceState.get())
    ResourceState.publish()
end

-- RoverBattery 주기마다: 자동 해제와 과열 게이지. 반환: 새 상태, boosting이 바뀌었는지
function RoverBoost.tick(
    state: GameState,
    dt: number,
    seatEmpty: boolean,
    chassis: BasePart?
): (GameState, boolean)
    local new = state
    local r = state.rover
    if
        r.boosting and (seatEmpty or r.battery < r.batteryMax * Config.ROVER.boostMinBatteryRatio)
    then
        new = Simulation.copy(state)
        new.rover.boosting = false
    end
    local overheatNow
    new, overheatNow = Simulation.boostTick(new, Config, dt)
    if overheatNow then
        overheated = true
        -- 과열 연기 한 번
        local smoke = fx.smoke
        if smoke then
            smoke:Emit(Config.ROVER.boostFx.smokeBurst)
        end
    elseif overheated and new.rover.boostHeat <= 0 then
        overheated = false
        Sfx.play("rover_boost_ready", chassis)
    end
    return new, new.rover.boosting ~= state.rover.boosting
end

function RoverBoost.reset()
    overheated = false
    stopLoop()
    RoverDrive.setSpeedFactor("boost", 1)
    RoverBoost.detachFx()
end

function RoverBoost.init()
    if initialized then
        return
    end
    initialized = true
    Remotes.get("RoverBoost").OnServerEvent:Connect(function(player: Player, on: any)
        ServerUtil.safeCall("RoverBoost", RoverBoost.request, player, on)
    end)
end

return RoverBoost
