--!strict
-- 로버 구동: DriverSeat의 ThrottleFloat, SteerFloat를 바퀴 HingeConstraint에 반영한다.
-- Attribute "RoverRole"이 "Drive"인 힌지는 모터(바퀴 회전), "Steer"인 힌지는 서보(앞바퀴 조향)로 쓴다.
-- 해당 Attribute가 있는 힌지가 없으면 (자체 스크립트가 있는 외부 로버 모델 등) 아무 것도 하지 않는다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ServerUtil = require(script.Parent.ServerUtil)

local RoverDrive = {}

local connections: { RBXScriptConnection } = {}

function RoverDrive.attach(base: Model)
    RoverDrive.detach()
    local rover = ServerUtil.findModel(base, "Rover")
    local seat = ServerUtil.getRoverSeat()
    if not rover or not seat or not seat:IsDescendantOf(rover) then
        return
    end
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
            hinge.AngularVelocity = throttle * seat.MaxSpeed / wheelRadius * rv.driveSign
        end
        for _, hinge in steerHinges do
            hinge.TargetAngle = steer * rv.steerAngle * rv.steerSign
        end
    end

    table.insert(connections, seat:GetPropertyChangedSignal("ThrottleFloat"):Connect(update))
    table.insert(connections, seat:GetPropertyChangedSignal("SteerFloat"):Connect(update))
    table.insert(connections, seat:GetPropertyChangedSignal("Occupant"):Connect(update))
    update()
end

function RoverDrive.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
end

return RoverDrive
