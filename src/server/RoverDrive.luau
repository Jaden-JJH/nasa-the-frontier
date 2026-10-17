--!strict
-- 로버 구동과 탑승
--   탑승: 섀시(로버 PrimaryPart)에 "탑승" 프롬프트. 좌석이 캐빈 안이라 이것이 기본 탑승 수단이다.
--         누가 앉아 있으면 꺼지고, 하차는 기본 동작(Space). 첫 탑승 때 조작 안내 토스트.
--   구동: DriverSeat의 ThrottleFloat, SteerFloat를 바퀴 HingeConstraint에 반영한다.
--         Attribute "RoverRole"이 "Drive"인 힌지는 모터(바퀴 회전), "Steer"인 힌지는 서보(앞바퀴 조향)로 쓴다.
--         해당 Attribute가 있는 힌지가 없으면 (자체 스크립트가 있는 외부 로버 모델 등) 구동은 하지 않는다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

local RoverDrive = {}

local connections: { RBXScriptConnection } = {}
local boardPrompt: ProximityPrompt? = nil
-- 최고 속도 배율 요소: damage(RoverDamage, 파손 3이면 0) x battery(RoverBattery, 방전이면 0)
-- boost(RoverBoost)는 1보다 클 수 있다
local speedFactors: { [string]: number } = { damage = 1, battery = 1, boost = 1 }
local speedMultiplier = 1 -- 위 요소의 곱
local applyDrive: (() -> ())? = nil -- 현재 로버의 바퀴 갱신 함수
-- 첫 탑승 안내를 이미 받은 플레이어 (서버 세션 동안 한 번, 나간 플레이어는 자동으로 빠진다)
local boardedOnce: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function onBoardTriggered(player: Player, seat: VehicleSeat, anchor: BasePart)
    if seat.Occupant ~= nil then
        return
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
        return
    end
    if not root or not root:IsA("BasePart") then
        return
    end
    -- 클라이언트가 보낸 요청이므로 서버에서도 거리를 확인한다 (지연 여유 포함)
    local limit = Config.PROMPT.boardDistance + Config.PROMPT.serverDistanceSlack
    if (root.CFrame.Position - anchor.CFrame.Position).Magnitude > limit then
        return
    end
    seat:Sit(humanoid)
end

local wasOccupied = false -- 직전 좌석 상태 (승차, 하차 효과음)

local function onOccupantChanged(seat: VehicleSeat)
    local occupied = seat.Occupant ~= nil
    if occupied ~= wasOccupied then
        wasOccupied = occupied
        Sfx.play(if occupied then "rover_board" else "rover_exit", seat)
    end
    local current = boardPrompt
    if current then
        current.Enabled = seat.Occupant == nil
    end
    local player = ServerUtil.playerFromHumanoid(seat.Occupant)
    if player and not boardedOnce[player] then
        boardedOnce[player] = true
        ResourceState.notify(
            player,
            string.format(Config.TEXTS.firstBoard, Config.ROVER.boostDrainMultiplier),
            "info"
        )
    end
    -- 튜토리얼: 탑승하면 find_ice 단계로 (이미 지났으면 그대로)
    local state = ResourceState.get()
    if player and state.phase == "playing" then
        local new = Simulation.markBoarded(state, Config)
        if new.missionStage ~= state.missionStage then
            ResourceState.set(new)
            ResourceState.publish()
        end
    end
end

function RoverDrive.attach(base: Model)
    RoverDrive.detach()
    local rover = ServerUtil.findModel(base, "Rover")
    local seat = ServerUtil.getRoverSeat()
    if not rover or not seat or not seat:IsDescendantOf(rover) then
        return
    end

    -- 탑승 프롬프트 (구동 힌지가 없는 외부 로버에도 붙인다)
    local anchor: BasePart = rover.PrimaryPart or seat
    local prompt = ServerUtil.makePrompt(anchor, {
        actionText = Config.PROMPT_TEXTS.board,
        objectText = Config.PROMPT_TEXTS.roverObject,
        holdDuration = 0,
        maxDistance = Config.PROMPT.boardDistance,
        enabled = seat.Occupant == nil,
    })
    boardPrompt = prompt
    wasOccupied = seat.Occupant ~= nil
    table.insert(
        connections,
        prompt.Triggered:Connect(function(player: Player)
            onBoardTriggered(player, seat, anchor)
        end)
    )
    table.insert(
        connections,
        seat:GetPropertyChangedSignal("Occupant"):Connect(function()
            onOccupantChanged(seat)
        end)
    )
    local driveHinges: { HingeConstraint } = {}
    local steerHinges: { HingeConstraint } = {}
    for _, descendant in rover:GetDescendants() do
        if descendant:IsA("HingeConstraint") then
            local role = descendant:GetAttribute("RoverRole")
            if role == "Drive" then
                table.insert(driveHinges, descendant)
            elseif role == "Steer" then
                table.insert(steerHinges, descendant)
            end
        end
    end
    if #driveHinges == 0 and #steerHinges == 0 then
        return
    end

    local rv = Config.ROVER
    local function update()
        local throttle, steer = 0, 0
        if seat.Occupant ~= nil then
            throttle = math.clamp(seat.ThrottleFloat, -1, 1)
            steer = math.clamp(seat.SteerFloat, -1, 1)
        end
        for _, hinge in driveHinges do
            local radius = hinge:GetAttribute("WheelRadius")
            local wheelRadius = if typeof(radius) == "number" and radius > 0
                then radius
                else rv.wheelRadius
            hinge.MotorMaxTorque = seat.Torque
            hinge.AngularVelocity = throttle
                * seat.MaxSpeed
                * speedMultiplier
                / wheelRadius
                * rv.driveSign
        end
        for _, hinge in steerHinges do
            hinge.TargetAngle = steer * rv.steerAngle * rv.steerSign
        end
    end

    table.insert(connections, seat:GetPropertyChangedSignal("ThrottleFloat"):Connect(update))
    table.insert(connections, seat:GetPropertyChangedSignal("SteerFloat"):Connect(update))
    table.insert(connections, seat:GetPropertyChangedSignal("Occupant"):Connect(update))
    applyDrive = update
    update()
end

-- 최고 속도 배율 요소 하나를 바꾼다. 스로틀을 그대로 누르고 있어도 바로 반영되게 바퀴를 다시 맞춘다
function RoverDrive.setSpeedFactor(key: string, value: number)
    speedFactors[key] = math.max(0, value)
    local product = 1
    for _, factor in speedFactors do
        product *= factor
    end
    speedMultiplier = product
    local apply = applyDrive
    if apply then
        apply()
    end
end

-- 파손에 따른 최고 속도 배율 (RoverDamage)
function RoverDrive.setSpeedMultiplier(multiplier: number)
    RoverDrive.setSpeedFactor("damage", multiplier)
end

function RoverDrive.getSpeedMultiplier(): number
    return speedMultiplier
end

function RoverDrive.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    applyDrive = nil
    if boardPrompt then
        boardPrompt:Destroy()
        boardPrompt = nil
    end
end

return RoverDrive
