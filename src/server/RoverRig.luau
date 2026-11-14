--!strict
-- v2 직접 운전 로버 리그 (v1 DevMap.buildRover를 v2용으로 옮김).
-- 새 플레이스에는 운전할 수 있는 로버 원본이 없어서(ServerStorage.Assets.Kit.Rover는 메시뿐) 코드가 물리 리그를 만든다.
--   섀시(PrimaryPart "Chassis") + 바퀴 4개(원기둥, 모터 힌지 Attribute RoverRole "Drive") + 앞바퀴 조향 너클(서보, "Steer")
--   + VehicleSeat "DriverSeat". 외형은 MissionWorld.resolveAsset("Rover")(에셋 -> 키트 -> 대체 도형)를 섀시에 용접한다.
-- 로버 앞은 로컬 -Z. 모델 Attribute Role = "rover" (클라이언트 지도가 찾는다).
-- 수치는 v1 Config.ROVER와 같은 엔진 수준 값이고 최고 속도만 MissionConfig.MANUAL_DRIVE.v1MaxSpeed를 쓴다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local MissionWorld = require(script.Parent.MissionWorld)

local RoverRig = {}

RoverRig.CONFIG = {
    torque = 1200,
    turnSpeed = 1,
    steerAngle = 30,
    steerSpeed = 4,
    steerTorque = 5000,
    driveSign = -1, -- Studio에서 거꾸로 가면 1
    steerSign = -1, -- 좌우가 반대면 1
    wheelRadius = 1.5,
    wheelWidth = 1.2,
    wheelFriction = 1.5,
    chassisDensity = 2,
    chassisSize = { 6, 1, 10 },
    wheelChassisGap = 0.2,
    wheelOffsetZ = 3.5,
    minWheelOffsetX = 2.5,
    clearance = 0.1,
    seatSize = { 2, 1, 2 },
    visualLength = 11, -- 외형 앞뒤 길이
    seatHeightRatio = 0.35,
    seatMaxHeight = 4.5,
    seatFromFrontRatio = 0.35,
    showRigWheels = false,
    colors = { chassis = { 200, 200, 205 }, wheel = { 45, 45, 50 }, seat = { 255, 140, 60 } },
}
local CFG = RoverRig.CONFIG

local function rgb(values: { number }): Color3
    return Color3.fromRGB(values[1], values[2], values[3])
end

local function vec(values: { number }): Vector3
    return Vector3.new(values[1], values[2], values[3])
end

local function newPart(
    name: string,
    size: Vector3,
    cframe: CFrame,
    color: Color3,
    parent: Instance
): Part
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = cframe
    part.Color = color
    part.Anchored = false
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = parent
    return part
end

local function attachment(name: string, parent: BasePart, cframe: CFrame): Attachment
    local a = Instance.new("Attachment")
    a.Name = name
    a.CFrame = cframe
    a.Parent = parent
    return a
end

local function weld(a: BasePart, b: BasePart)
    local w = Instance.new("WeldConstraint")
    w.Part0 = a
    w.Part1 = b
    w.Parent = a
end

local function forEachPart(root: Instance, fn: (BasePart) -> ())
    if root:IsA("BasePart") then
        fn(root)
    end
    for _, d in root:GetDescendants() do
        if d:IsA("BasePart") then
            fn(d)
        end
    end
end

-- 월드 축 경계 상자 (파트 8개 꼭짓점)
local function bounds(root: Instance): (Vector3, Vector3)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    forEachPart(root, function(part)
        local cf, half = part.CFrame, part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local q = cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                    lo = Vector3.new(math.min(lo.X, q.X), math.min(lo.Y, q.Y), math.min(lo.Z, q.Z))
                    hi = Vector3.new(math.max(hi.X, q.X), math.max(hi.Y, q.Y), math.max(hi.Z, q.Z))
                end
            end
        end
    end)
    if lo.X == math.huge then
        return Vector3.zero, Vector3.zero
    end
    return lo, hi
end

-- 외형을 원점 기준(바닥 y = clearance, 앞뒤 = Z축, 길이 visualLength)으로 맞춘다
local function fitVisual(visual: Model)
    local lo, hi = bounds(visual)
    local size = hi - lo
    if size.X > size.Z then
        visual:PivotTo(CFrame.Angles(0, math.rad(90), 0) * visual:GetPivot())
        lo, hi = bounds(visual)
        size = hi - lo
    end
    if size.Z > 0 then
        local ok = pcall(function()
            visual:ScaleTo(visual:GetScale() * CFG.visualLength / size.Z)
        end)
        if ok then
            lo, hi = bounds(visual)
        end
    end
    local center = (lo + hi) / 2
    local offset = Vector3.new(-center.X, CFG.clearance - lo.Y, -center.Z)
    visual:PivotTo(CFrame.new(offset) * visual:GetPivot())
end

local function motorHinge(name: string, a0: Attachment, a1: Attachment, parent: Instance)
    local hinge = Instance.new("HingeConstraint")
    hinge.Name = name
    hinge.Attachment0 = a0
    hinge.Attachment1 = a1
    hinge.ActuatorType = Enum.ActuatorType.Motor
    hinge.MotorMaxTorque = CFG.torque
    hinge.AngularVelocity = 0
    hinge:SetAttribute("RoverRole", "Drive")
    hinge:SetAttribute("WheelRadius", CFG.wheelRadius)
    hinge.Parent = parent
end

-- 로버를 원점에서 만들고 target(바닥 윗면 중심, 앞 = LookVector)으로 옮긴다
function RoverRig.build(target: CFrame, parent: Instance): Model
    local rover = Instance.new("Model")
    rover.Name = "Rover"
    rover:SetAttribute("Role", "rover")

    local visual: Model? = nil
    local okVisual, made = pcall(function()
        local model = MissionWorld.resolveAsset("Rover")
        return model
    end)
    if okVisual and made then
        visual = made
        fitVisual(made)
    end

    local r = CFG.wheelRadius
    local chassisSize = vec(CFG.chassisSize)
    local wheelY = r + CFG.clearance
    local chassisY = wheelY + chassisSize.Y / 2 - 0.2
    local wheelOffsetX = chassisSize.X / 2 + CFG.wheelChassisGap + CFG.wheelWidth / 2
    if visual then
        local lo, hi = bounds(visual)
        wheelOffsetX = math.max((hi.X - lo.X) / 2 - CFG.wheelWidth / 2, CFG.minWheelOffsetX)
        local inner = 2 * (wheelOffsetX - CFG.wheelWidth / 2 - CFG.wheelChassisGap)
        chassisSize = Vector3.new(math.min(chassisSize.X, inner), chassisSize.Y, chassisSize.Z)
    end
    local chassisCFrame = CFrame.new(0, chassisY, 0)
    local chassis = newPart("Chassis", chassisSize, chassisCFrame, rgb(CFG.colors.chassis), rover)
    chassis.Material = Enum.Material.Metal
    chassis.CustomPhysicalProperties = PhysicalProperties.new(CFG.chassisDensity, 0.3, 0, 1, 1)
    rover.PrimaryPart = chassis

    local wheelProps = PhysicalProperties.new(0.7, CFG.wheelFriction, 0, 100, 1)
    local upAxis = CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, Vector3.xAxis)
    local wheels: { BasePart } = {}
    for _, corner in { { -1, -1, "FL" }, { 1, -1, "FR" }, { -1, 1, "RL" }, { 1, 1, "RR" } } do
        local sx, sz, tag = corner[1] :: number, corner[2] :: number, corner[3] :: string
        local localPosition =
            Vector3.new(sx * wheelOffsetX, wheelY - chassisY, sz * CFG.wheelOffsetZ)
        local wheelCFrame = chassisCFrame * CFrame.new(localPosition)
        local wheel = newPart(
            "Wheel" .. tag,
            Vector3.new(CFG.wheelWidth, r * 2, r * 2),
            wheelCFrame,
            rgb(CFG.colors.wheel),
            rover
        )
        wheel.Shape = Enum.PartType.Cylinder
        wheel.Material = Enum.Material.Rubber
        wheel.CustomPhysicalProperties = wheelProps
        local noCollide = Instance.new("NoCollisionConstraint")
        noCollide.Part0 = chassis
        noCollide.Part1 = wheel
        noCollide.Parent = wheel
        table.insert(wheels, wheel)
        if sz < 0 then
            local knuckle =
                newPart("Knuckle" .. tag, Vector3.one, wheelCFrame, rgb(CFG.colors.wheel), rover)
            knuckle.Transparency = 1
            knuckle.CanCollide = false
            local steer = Instance.new("HingeConstraint")
            steer.Name = "Steer" .. tag
            steer.Attachment0 =
                attachment("SteerChassis" .. tag, chassis, CFrame.new(localPosition) * upAxis)
            steer.Attachment1 = attachment("SteerKnuckle" .. tag, knuckle, upAxis)
            steer.ActuatorType = Enum.ActuatorType.Servo
            steer.ServoMaxTorque = CFG.steerTorque
            steer.AngularSpeed = CFG.steerSpeed
            steer.LimitsEnabled = true
            steer.LowerAngle = -CFG.steerAngle
            steer.UpperAngle = CFG.steerAngle
            steer.TargetAngle = 0
            steer:SetAttribute("RoverRole", "Steer")
            steer.Parent = knuckle
            motorHinge(
                "Drive" .. tag,
                attachment("DriveKnuckle" .. tag, knuckle, CFrame.identity),
                attachment("DriveWheel" .. tag, wheel, CFrame.identity),
                wheel
            )
        else
            motorHinge(
                "Drive" .. tag,
                attachment("DriveChassis" .. tag, chassis, CFrame.new(localPosition)),
                attachment("DriveWheel" .. tag, wheel, CFrame.identity),
                wheel
            )
        end
    end

    local seatSize = vec(CFG.seatSize)
    local seatCFrame = chassisCFrame * CFrame.new(0, chassisSize.Y / 2 + seatSize.Y / 2, 1.5)
    if visual then
        visual.Name = "Visual"
        forEachPart(visual, function(part)
            part.Anchored = false
            part.Massless = true
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            weld(chassis, part)
        end)
        visual.Parent = rover
        chassis.Transparency = 1
        if not CFG.showRigWheels then
            for _, wheel in wheels do
                wheel.Transparency = 1
            end
        end
        local lo, hi = bounds(visual)
        local seatHeight = math.min((hi.Y - lo.Y) * CFG.seatHeightRatio, CFG.seatMaxHeight)
        seatCFrame = CFrame.new(0, lo.Y + seatHeight, lo.Z + (hi.Z - lo.Z) * CFG.seatFromFrontRatio)
    end
    local seat = Instance.new("VehicleSeat")
    seat.Name = "DriverSeat"
    seat.Size = seatSize
    seat.CFrame = seatCFrame
    seat.Color = rgb(CFG.colors.seat)
    seat.Anchored = false
    seat.MaxSpeed = MissionConfig.MANUAL_DRIVE.v1MaxSpeed
    seat.Torque = CFG.torque
    seat.TurnSpeed = CFG.turnSpeed
    if visual then
        seat.Transparency = 1
    end
    seat.Parent = rover
    weld(chassis, seat)

    rover.Parent = parent
    rover:PivotTo(target * CFrame.new(0, chassisY, 0))
    return rover
end

return RoverRig
