--!strict
-- 그레이박스 맵 생성기 (CONTRACT 4절)
-- 디자이너 맵이 없으면 빈 Baseplate에서도 끝까지 플레이할 수 있게 Part로 맵을 만든다.
--   Workspace.LandingPads가 없으면: 지면, 착륙 패드 4곳, 얼음 지점 3곳, 바위, 조명
--   ServerStorage.BaseKit이 없으면: 착륙선, 로버, 솔라 필드, 모듈 패드 3개, 물탱크
--   ServerStorage.PanelTemplate이 없으면: 태양광 패널 1장
-- 게임 수치(얼음 거리, 바위 수, 로버 성능)는 Config에서 오고, 아래 상수는 배치와 모양만 정한다.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local DevMap = {}

-- 맵 배치 상수 (studs) --------------------------------------------------

local GROUND_TOP = 0.5 -- 기본 Baseplate 윗면(0)과 겹쳐 깜빡이지 않도록 살짝 위
local GROUND_SIZE = Vector3.new(1400, 4, 1100)
local LANDING_PAD_SIZE = Vector3.new(48, 1, 48) -- 절반이 지면에 묻힌다
local ICE_SIZE = Vector3.new(14, 3, 14)
local ICE_LIGHT_RANGE = 18

-- 얼음 지점 위치 (x, z)
local ICE_POSITIONS = {
    Vector3.new(-75, 0, 50),
    Vector3.new(425, 0, 350),
    Vector3.new(-525, 0, 400),
}

-- 각 패드가 기준으로 삼는 얼음 지점과 그 얼음에서 패드 쪽 방향.
-- 패드 위치 = 얼음 위치 + 방향 x Config.DEV_MAP.iceDistanceBySite[i]
local PAD_LAYOUT = {
    { ice = 1, direction = Vector3.new(0, 0, -1) },
    { ice = 2, direction = Vector3.new(0, 0, -1) },
    { ice = 3, direction = Vector3.new(0, 0, -1) },
    { ice = 2, direction = Vector3.new(1, 0, 0) },
}

local KIT_CLEARANCE = 65 -- 패드 중심에서 이 거리 안에는 바위를 두지 않는다 (기지 키트 반경 약 55)
local ICE_CLEARANCE = 20 -- 얼음 중심 주변 바위 금지 거리
local CORRIDOR_HALF_WIDTH = 45 -- 패드와 얼음 사이 통로 반폭
local CORRIDOR_START, CORRIDOR_END = 0.12, 0.92 -- 통로 구간 (패드 0 -> 얼음 1)
local BOULDER_MIN, BOULDER_MAX = 3, 8
local BOULDER_ATTEMPTS = 20

-- 기지 키트 배치 상수 (Origin 기준 로컬 좌표, 앞쪽 = -Z = 얼음 방향) -------

local ORIGIN_SIZE = Vector3.new(4, 1, 4)
local FLOOR_Y = -ORIGIN_SIZE.Y / 2 -- 패드 윗면 높이
local EMBED = 1 -- 패드 밖 지면(패드 윗면보다 0.5 낮음)까지 닿도록 바닥 파트를 아래로 늘리는 길이

local LANDER_CENTER = Vector3.new(0, 0, 6)
local LANDER_SIZE = Vector3.new(14, 10, 14) -- 폭, 높이, 깊이
local SPAWN_POSITION = Vector3.new(0, 0, -5)
local ROVER_CENTER = Vector3.new(0, 0, -16)
-- 로버 주차 위치 옆. 운전석에 앉은 채 하역 프롬프트(활성 거리 12)가 닿도록 로버에서 약 10 studs
local WATER_TANK_POSITION = Vector3.new(-10, 0, -14)
local WATER_TANK_SIZE = Vector3.new(6, 8, 6)
-- 로버 복구 콘솔: 착륙선 문 오른쪽 바깥, 착륙선 산소 구역 안
local ROVER_CONSOLE_POSITION = Vector3.new(4.5, 0, -2.5)
local ROVER_CONSOLE_SIZE = Vector3.new(2, 3, 1)

local SOLAR_CENTER = Vector3.new(34, 0, 6)
local SOLAR_COLUMNS, SOLAR_ROWS = 5, 6
local SLOT_SIZE = Vector3.new(5, 0.2, 3.5)
local SLOT_GAP_X, SLOT_GAP_Z = 1.2, 1.5
local INSTALL_PAD_POSITION = Vector3.new(34, 0, -13)
local INSTALL_PAD_SIZE = Vector3.new(6, 0.6, 6)

local MODULE_LAYOUT = {
    A = {
        center = Vector3.new(-30, 0, -2),
        pad = Vector3.new(20, 0.6, 20),
        body = Vector3.new(16, 9, 16),
    },
    B = {
        center = Vector3.new(-30, 0, 24),
        pad = Vector3.new(20, 0.6, 20),
        body = Vector3.new(16, 7, 18),
    },
    C = {
        center = Vector3.new(2, 0, 34),
        pad = Vector3.new(24, 0.6, 24),
        body = Vector3.new(20, 12, 20),
    },
}

local DOOR_WIDTH, DOOR_HEIGHT = 6, 7
local WALL = 1

-- 로버 치수
local CHASSIS_SIZE = Vector3.new(6, 1, 10)
local WHEEL_WIDTH = 1.2
local WHEEL_OFFSET_X = CHASSIS_SIZE.X / 2 + 0.2 + WHEEL_WIDTH / 2
local WHEEL_OFFSET_Z = 3.5
local WHEEL_CLEARANCE = 0.1
-- 바퀴 위치 부호 (x: 좌 -1 우 1, z: 앞 -1 뒤 1)
local WHEEL_CORNERS: { { x: number, z: number, tag: string } } = {
    { x = -1, z = -1, tag = "FL" },
    { x = 1, z = -1, tag = "FR" },
    { x = -1, z = 1, tag = "RL" },
    { x = 1, z = 1, tag = "RR" },
}

-- 색상
local COLORS = {
    ground = Color3.fromRGB(118, 118, 122),
    landingPad = Color3.fromRGB(150, 150, 155),
    ice = Color3.fromRGB(175, 225, 255),
    boulder = Color3.fromRGB(58, 58, 62),
    lander = Color3.fromRGB(210, 190, 130),
    landerTrim = Color3.fromRGB(90, 90, 95),
    spawn = Color3.fromRGB(255, 255, 255),
    rover = Color3.fromRGB(225, 225, 230),
    wheel = Color3.fromRGB(35, 35, 38),
    tankBlue = Color3.fromRGB(110, 185, 255),
    slot = Color3.fromRGB(70, 72, 82),
    installPad = Color3.fromRGB(255, 205, 60),
    modulePad = Color3.fromRGB(90, 92, 104),
    ghost = Color3.fromRGB(80, 160, 255),
    habitat = Color3.fromRGB(235, 235, 240),
    farm = Color3.fromRGB(120, 200, 120),
    lab = Color3.fromRGB(245, 245, 250),
    panel = Color3.fromRGB(25, 40, 95),
    panelFrame = Color3.fromRGB(150, 150, 155),
    console = Color3.fromRGB(255, 140, 60),
}

-- 조명 (그레이박스 맵을 만들 때만 적용)
-- 자정(0시)으로 두어 하늘을 검게 하고, 주변광을 밝게 올려 지면이 보이게 한다
local LIGHTING = {
    clockTime = 0,
    brightness = 3,
    ambient = Color3.fromRGB(130, 130, 140),
    outdoorAmbient = Color3.fromRGB(170, 170, 180),
}

-- 파트 생성 도우미 ------------------------------------------------------

type PartSpec = {
    name: string,
    size: Vector3,
    cframe: CFrame,
    color: Color3,
    material: Enum.Material?,
    transparency: number?,
    canCollide: boolean?,
    anchored: boolean?,
    shape: Enum.PartType?,
    parent: Instance,
}

local function makePart(spec: PartSpec): Part
    local part = Instance.new("Part")
    part.Name = spec.name
    if spec.shape then
        part.Shape = spec.shape
    end
    part.Size = spec.size
    part.CFrame = spec.cframe
    part.Color = spec.color
    part.Material = spec.material or Enum.Material.SmoothPlastic
    part.Transparency = spec.transparency or 0
    part.CanCollide = if spec.canCollide == nil then true else spec.canCollide
    part.Anchored = if spec.anchored == nil then true else spec.anchored
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = spec.parent
    return part
end

-- 보이지 않는 판정용 파트 (OxygenZone, Origin, SpawnPoint 등)
local function makeMarker(name: string, size: Vector3, cframe: CFrame, parent: Instance): Part
    local part = makePart({
        name = name,
        size = size,
        cframe = cframe,
        color = COLORS.spawn,
        transparency = 1,
        canCollide = false,
        parent = parent,
    })
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    return part
end

local function makeModel(name: string, parent: Instance?): Model
    local model = Instance.new("Model")
    model.Name = name
    model.Parent = parent
    return model
end

local function makeFolder(name: string, parent: Instance): Folder
    local folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

local function makeSign(part: BasePart, text: string, offsetY: number)
    local layout = Config.WORLD_LABEL
    local gui = Instance.new("BillboardGui")
    gui.Name = "Sign"
    gui.Size = UDim2.fromOffset(layout.width, layout.height)
    gui.StudsOffset = Vector3.new(0, offsetY, 0)
    gui.MaxDistance = layout.maxDistance * 4
    gui.Parent = part
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextColor3 = COLORS.spawn
    label.TextStrokeTransparency = 0.4
    label.Font = Enum.Font.GothamMedium
    label.TextSize = layout.textSize
    label.Text = text
    label.Parent = gui
end

-- 바닥에 놓이는 슬래브: 윗면이 floorY + height, 아래로 EMBED만큼 묻힌다
local function slabCFrame(base: CFrame, position: Vector3, height: number): (CFrame, number)
    local total = height + EMBED
    return base * CFrame.new(position.X, FLOOR_Y + height - total / 2, position.Z), total
end

-- 문이 앞쪽(-Z)에 난 상자형 건물 (바닥, 지붕, 벽 4면). 반환: 바닥 윗면 높이
local function buildHut(
    parent: Instance,
    center: Vector3,
    size: Vector3,
    color: Color3,
    material: Enum.Material
): number
    local floorHeight = WALL
    local floorCFrame, floorTotal = slabCFrame(CFrame.identity, center, floorHeight)
    makePart({
        name = "Floor",
        size = Vector3.new(size.X, floorTotal, size.Z),
        cframe = floorCFrame,
        color = COLORS.landerTrim,
        material = Enum.Material.DiamondPlate,
        parent = parent,
    })
    local floorTop = FLOOR_Y + floorHeight
    local wallY = floorTop + size.Y / 2
    local half = size / 2

    local function wall(name: string, wallSize: Vector3, offset: Vector3)
        makePart({
            name = name,
            size = wallSize,
            cframe = CFrame.new(center.X + offset.X, offset.Y, center.Z + offset.Z),
            color = color,
            material = material,
            parent = parent,
        })
    end

    wall("Roof", Vector3.new(size.X, WALL, size.Z), Vector3.new(0, floorTop + size.Y + WALL / 2, 0))
    wall("BackWall", Vector3.new(size.X, size.Y, WALL), Vector3.new(0, wallY, half.Z - WALL / 2))
    wall("LeftWall", Vector3.new(WALL, size.Y, size.Z), Vector3.new(-half.X + WALL / 2, wallY, 0))
    wall("RightWall", Vector3.new(WALL, size.Y, size.Z), Vector3.new(half.X - WALL / 2, wallY, 0))

    local sideWidth = (size.X - DOOR_WIDTH) / 2
    local frontZ = -half.Z + WALL / 2
    wall(
        "FrontLeft",
        Vector3.new(sideWidth, size.Y, WALL),
        Vector3.new(-(DOOR_WIDTH + sideWidth) / 2, wallY, frontZ)
    )
    wall(
        "FrontRight",
        Vector3.new(sideWidth, size.Y, WALL),
        Vector3.new((DOOR_WIDTH + sideWidth) / 2, wallY, frontZ)
    )
    local lintelHeight = size.Y - DOOR_HEIGHT
    if lintelHeight > 0 then
        wall(
            "Lintel",
            Vector3.new(DOOR_WIDTH, lintelHeight, WALL),
            Vector3.new(0, floorTop + DOOR_HEIGHT + lintelHeight / 2, frontZ)
        )
    end
    return floorTop
end

-- 지형 ------------------------------------------------------------------

local function sitePadPosition(index: number): Vector3
    local layout = PAD_LAYOUT[index]
    local ice = ICE_POSITIONS[layout.ice]
    local distance = Config.DEV_MAP.iceDistanceBySite[index]
    return ice + layout.direction.Unit * distance
end

local function buildLighting()
    Lighting.ClockTime = LIGHTING.clockTime
    Lighting.Brightness = LIGHTING.brightness
    Lighting.Ambient = LIGHTING.ambient
    Lighting.OutdoorAmbient = LIGHTING.outdoorAmbient
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if atmosphere then
        -- 달에는 대기가 없다
        atmosphere.Density = 0
        atmosphere.Haze = 0
        atmosphere.Glare = 0
    end
end

local function isClear(position: Vector3, padPositions: { Vector3 }): boolean
    local flat = Vector3.new(position.X, 0, position.Z)
    for _, pad in padPositions do
        if (flat - Vector3.new(pad.X, 0, pad.Z)).Magnitude < KIT_CLEARANCE then
            return false
        end
    end
    for _, ice in ICE_POSITIONS do
        if (flat - Vector3.new(ice.X, 0, ice.Z)).Magnitude < ICE_CLEARANCE then
            return false
        end
    end
    local halfX, halfZ = GROUND_SIZE.X / 2, GROUND_SIZE.Z / 2
    return math.abs(position.X) < halfX - BOULDER_MAX and math.abs(position.Z) < halfZ - BOULDER_MAX
end

local function makeBoulder(rng: Random, position: Vector3, parent: Instance)
    local s = rng:NextNumber(BOULDER_MIN, BOULDER_MAX)
    local size = Vector3.new(s, s * rng:NextNumber(0.5, 0.9), s * rng:NextNumber(0.7, 1.2))
    local rotation = CFrame.Angles(
        math.rad(rng:NextNumber(-15, 15)),
        math.rad(rng:NextNumber(0, 360)),
        math.rad(rng:NextNumber(-15, 15))
    )
    makePart({
        name = "Boulder",
        size = size,
        cframe = CFrame.new(position.X, GROUND_TOP + size.Y * 0.3, position.Z) * rotation,
        color = COLORS.boulder,
        material = Enum.Material.Basalt,
        parent = parent,
    })
end

local function buildBoulders(terrain: Instance, padPositions: { Vector3 })
    local rng = Random.new(Config.DEV_MAP.seed)
    local folder = makeFolder("Boulders", terrain)
    -- 패드와 얼음 사이 통로 (지형 위험)
    for index, padPosition in padPositions do
        local ice = ICE_POSITIONS[PAD_LAYOUT[index].ice]
        local along = ice - padPosition
        local side = Vector3.new(-along.Z, 0, along.X).Unit
        for _ = 1, Config.DEV_MAP.boulderCountBySite[index] do
            for _ = 1, BOULDER_ATTEMPTS do
                local t = rng:NextNumber(CORRIDOR_START, CORRIDOR_END)
                local lateral = rng:NextNumber(-CORRIDOR_HALF_WIDTH, CORRIDOR_HALF_WIDTH)
                local position = padPosition + along * t + side * lateral
                if isClear(position, padPositions) then
                    makeBoulder(rng, position, folder)
                    break
                end
            end
        end
    end
    -- 맵 전체에 흩뿌리기
    for _ = 1, Config.DEV_MAP.scatterBoulders do
        for _ = 1, BOULDER_ATTEMPTS do
            local position = Vector3.new(
                rng:NextNumber(-GROUND_SIZE.X / 2, GROUND_SIZE.X / 2),
                0,
                rng:NextNumber(-GROUND_SIZE.Z / 2, GROUND_SIZE.Z / 2)
            )
            if isClear(position, padPositions) then
                makeBoulder(rng, position, folder)
                break
            end
        end
    end
end

-- 각 패드의 가장 가까운 얼음 거리가 설계값과 맞는지 확인 (레이아웃을 바꿨을 때 경고)
local function verifyDistances(padPositions: { Vector3 })
    for index, padPosition in padPositions do
        local nearest = math.huge
        for _, ice in ICE_POSITIONS do
            nearest = math.min(
                nearest,
                (Vector3.new(ice.X, 0, ice.Z) - Vector3.new(padPosition.X, 0, padPosition.Z)).Magnitude
            )
        end
        local expected = Config.DEV_MAP.iceDistanceBySite[index]
        if math.abs(nearest - expected) > 1 then
            warn(
                string.format(
                    "[DevMap] Pad%d 최근접 얼음 거리 %.0f, 설계값 %d",
                    index,
                    nearest,
                    expected
                )
            )
        end
    end
end

local function buildTerrainAndSites()
    local terrain = makeFolder("DevTerrain", workspace)
    makePart({
        name = "MoonGround",
        size = GROUND_SIZE,
        cframe = CFrame.new(0, GROUND_TOP - GROUND_SIZE.Y / 2, 0),
        color = COLORS.ground,
        material = Enum.Material.Sand,
        parent = terrain,
    })

    local iceFolder = makeFolder("IceSites", workspace)
    for index, position in ICE_POSITIONS do
        local ice = makePart({
            name = "Ice" .. index,
            size = ICE_SIZE,
            cframe = CFrame.new(position.X, GROUND_TOP + ICE_SIZE.Y / 2, position.Z),
            color = COLORS.ice,
            material = Enum.Material.Ice,
            parent = iceFolder,
        })
        local light = Instance.new("PointLight")
        light.Color = COLORS.ice
        light.Range = ICE_LIGHT_RANGE
        light.Parent = ice
    end

    local padsFolder = makeFolder("LandingPads", workspace)
    local padPositions: { Vector3 } = {}
    for index, site in Config.SITES do
        local position = sitePadPosition(index)
        table.insert(padPositions, position)
        local ice = ICE_POSITIONS[PAD_LAYOUT[index].ice]
        local center = Vector3.new(position.X, GROUND_TOP, position.Z)
        -- 패드의 앞쪽(-Z, LookVector)이 얼음을 향하게 해서 복제된 기지의 로버가 얼음 쪽을 보게 한다
        local pad = makePart({
            name = "Pad" .. index,
            size = LANDING_PAD_SIZE,
            cframe = CFrame.lookAt(center, Vector3.new(ice.X, GROUND_TOP, ice.Z)),
            color = COLORS.landingPad,
            material = Enum.Material.Concrete,
            parent = padsFolder,
        })
        pad:SetAttribute("SiteName", site.name)
        pad:SetAttribute("Sunlight", site.sunlight)
        pad:SetAttribute("IceDistanceLabel", site.iceDistanceLabel)
        pad:SetAttribute("HazardLabel", site.hazardLabel)
        pad:SetAttribute("Description", site.description)
        makeSign(pad, string.format("%d. %s", index, site.name), Config.WORLD_LABEL.offsetY)
    end

    verifyDistances(padPositions)
    buildBoulders(terrain, padPositions)
    buildLighting()
end

local function buildIceOnly()
    local iceFolder = makeFolder("IceSites", workspace)
    for index, position in ICE_POSITIONS do
        makePart({
            name = "Ice" .. index,
            size = ICE_SIZE,
            cframe = CFrame.new(position.X, GROUND_TOP + ICE_SIZE.Y / 2, position.Z),
            color = COLORS.ice,
            material = Enum.Material.Ice,
            parent = iceFolder,
        })
    end
end

-- 로버 ------------------------------------------------------------------

local function attachment(name: string, parent: BasePart, cframe: CFrame): Attachment
    local a = Instance.new("Attachment")
    a.Name = name
    a.CFrame = cframe
    a.Parent = parent
    return a
end

local function noCollide(a: BasePart, b: BasePart, parent: Instance)
    local constraint = Instance.new("NoCollisionConstraint")
    constraint.Part0 = a
    constraint.Part1 = b
    constraint.Parent = parent
end

local function weld(a: BasePart, b: BasePart)
    local w = Instance.new("WeldConstraint")
    w.Part0 = a
    w.Part1 = b
    w.Parent = a
end

local function motorHinge(
    name: string,
    a0: Attachment,
    a1: Attachment,
    parent: Instance
): HingeConstraint
    local hinge = Instance.new("HingeConstraint")
    hinge.Name = name
    hinge.Attachment0 = a0
    hinge.Attachment1 = a1
    hinge.ActuatorType = Enum.ActuatorType.Motor
    hinge.MotorMaxTorque = Config.ROVER.torque
    hinge.AngularVelocity = 0
    hinge:SetAttribute("RoverRole", "Drive")
    hinge:SetAttribute("WheelRadius", Config.ROVER.wheelRadius)
    hinge.Parent = parent
    return hinge
end

local function buildRover(kit: Model)
    local rv = Config.ROVER
    local rover = makeModel("Rover", kit)
    local wheelY = FLOOR_Y + rv.wheelRadius + WHEEL_CLEARANCE
    local chassisY = wheelY + CHASSIS_SIZE.Y / 2 - 0.2
    local chassisCFrame = CFrame.new(ROVER_CENTER.X, chassisY, ROVER_CENTER.Z)

    local chassis = makePart({
        name = "Chassis",
        size = CHASSIS_SIZE,
        cframe = chassisCFrame,
        color = COLORS.rover,
        material = Enum.Material.Metal,
        anchored = false,
        parent = rover,
    })
    chassis.CustomPhysicalProperties = PhysicalProperties.new(rv.chassisDensity, 0.3, 0, 1, 1)
    rover.PrimaryPart = chassis

    local seat = Instance.new("VehicleSeat")
    seat.Name = "DriverSeat"
    seat.Size = Vector3.new(2, 1, 2)
    seat.CFrame = chassisCFrame * CFrame.new(0, CHASSIS_SIZE.Y / 2 + 0.5, 1.5)
    seat.Color = COLORS.landerTrim
    seat.Anchored = false
    seat.MaxSpeed = rv.maxSpeed
    seat.Torque = rv.torque
    seat.TurnSpeed = rv.turnSpeed
    seat:SetAttribute("Tank", 0)
    seat.Parent = rover
    weld(chassis, seat)

    local tankBox = makePart({
        name = "WaterTankBox",
        size = Vector3.new(4, 2, 2),
        cframe = chassisCFrame * CFrame.new(0, CHASSIS_SIZE.Y / 2 + 1, 4),
        color = COLORS.tankBlue,
        material = Enum.Material.Metal,
        anchored = false,
        parent = rover,
    })
    weld(chassis, tankBox)

    local wheelProps = PhysicalProperties.new(0.7, rv.wheelFriction, 0, 100, 1)
    local upAxis = CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, Vector3.xAxis)

    for _, corner in WHEEL_CORNERS do
        local sx, sz, tag = corner.x, corner.z, corner.tag
        local localPosition =
            Vector3.new(sx * WHEEL_OFFSET_X, wheelY - chassisY, sz * WHEEL_OFFSET_Z)
        local wheelCFrame = chassisCFrame * CFrame.new(localPosition)
        local wheel = makePart({
            name = "Wheel" .. tag,
            shape = Enum.PartType.Cylinder, -- 원기둥 축 = 파트 X축 = 바퀴 축
            size = Vector3.new(WHEEL_WIDTH, rv.wheelRadius * 2, rv.wheelRadius * 2),
            cframe = wheelCFrame,
            color = COLORS.wheel,
            material = Enum.Material.Rubber,
            anchored = false,
            parent = rover,
        })
        wheel.CustomPhysicalProperties = wheelProps
        noCollide(chassis, wheel, wheel)

        local isFront = sz < 0 -- 앞쪽 = -Z
        if isFront then
            -- 차체 -(서보, 세로축)-> 조향 너클 -(모터, 바퀴축)-> 바퀴
            local knuckle = makePart({
                name = "Knuckle" .. tag,
                size = Vector3.new(1, 1, 1),
                cframe = wheelCFrame,
                color = COLORS.wheel,
                transparency = 1,
                canCollide = false,
                anchored = false,
                parent = rover,
            })
            local steer = Instance.new("HingeConstraint")
            steer.Name = "Steer" .. tag
            steer.Attachment0 =
                attachment("SteerChassis" .. tag, chassis, CFrame.new(localPosition) * upAxis)
            steer.Attachment1 = attachment("SteerKnuckle" .. tag, knuckle, upAxis)
            steer.ActuatorType = Enum.ActuatorType.Servo
            steer.ServoMaxTorque = rv.steerTorque
            steer.AngularSpeed = rv.steerSpeed
            steer.LimitsEnabled = true
            steer.LowerAngle = -rv.steerAngle
            steer.UpperAngle = rv.steerAngle
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
end

-- 기지 키트 -------------------------------------------------------------

local function buildLander(kit: Model)
    local lander = makeModel("Lander", kit)
    local floorTop =
        buildHut(lander, LANDER_CENTER, LANDER_SIZE, COLORS.lander, Enum.Material.Metal)
    lander.PrimaryPart = lander:FindFirstChild("Floor") :: BasePart

    -- 실내와 문 앞(스폰 위치 포함)을 덮는 산소 구역
    local zoneFront = SPAWN_POSITION.Z - 3
    local zoneBack = LANDER_CENTER.Z + LANDER_SIZE.Z / 2 - WALL
    local zoneDepth = zoneBack - zoneFront
    makeMarker(
        "OxygenZone",
        Vector3.new(LANDER_SIZE.X - 2 * WALL, LANDER_SIZE.Y, zoneDepth),
        CFrame.new(LANDER_CENTER.X, floorTop + LANDER_SIZE.Y / 2, zoneFront + zoneDepth / 2),
        lander
    )

    local spawnPoint = makePart({
        name = "SpawnPoint",
        size = Vector3.new(4, 0.2, 4),
        cframe = CFrame.new(SPAWN_POSITION.X, FLOOR_Y + 0.1, SPAWN_POSITION.Z),
        color = COLORS.spawn,
        material = Enum.Material.Neon,
        transparency = 0.6,
        canCollide = false,
        parent = lander,
    })
    spawnPoint.CanTouch = false

    -- 로버 복구 콘솔 (RoverRecovery가 프롬프트를 붙인다)
    local consoleCFrame, consoleTotal =
        slabCFrame(CFrame.identity, ROVER_CONSOLE_POSITION, ROVER_CONSOLE_SIZE.Y)
    local console = makePart({
        name = "RoverConsole",
        size = Vector3.new(ROVER_CONSOLE_SIZE.X, consoleTotal, ROVER_CONSOLE_SIZE.Z),
        cframe = consoleCFrame,
        color = COLORS.console,
        material = Enum.Material.Metal,
        parent = lander,
    })
    makeSign(console, Config.PROMPT_TEXTS.recoverRover, ROVER_CONSOLE_SIZE.Y)
end

local function buildSolarField(kit: Model)
    local field = makeModel("SolarField", kit)
    local installCFrame, installTotal =
        slabCFrame(CFrame.identity, INSTALL_PAD_POSITION, INSTALL_PAD_SIZE.Y)
    local installPad = makePart({
        name = "InstallPad",
        size = Vector3.new(INSTALL_PAD_SIZE.X, installTotal, INSTALL_PAD_SIZE.Z),
        cframe = installCFrame,
        color = COLORS.installPad,
        material = Enum.Material.Metal,
        parent = field,
    })
    makeSign(installPad, Config.PROMPT_TEXTS.installPanel, Config.WORLD_LABEL.offsetY / 2)

    local slots = makeFolder("Slots", field)
    local pitchX = SLOT_SIZE.X + SLOT_GAP_X
    local pitchZ = SLOT_SIZE.Z + SLOT_GAP_Z
    local startX = SOLAR_CENTER.X - pitchX * (SOLAR_COLUMNS - 1) / 2
    local startZ = SOLAR_CENTER.Z - pitchZ * (SOLAR_ROWS - 1) / 2
    local index = 0
    for row = 0, SOLAR_ROWS - 1 do
        for column = 0, SOLAR_COLUMNS - 1 do
            index += 1
            local position = Vector3.new(startX + column * pitchX, 0, startZ + row * pitchZ)
            local slotCFrame, slotTotal = slabCFrame(CFrame.identity, position, SLOT_SIZE.Y)
            makePart({
                name = "Slot" .. index,
                size = Vector3.new(SLOT_SIZE.X, slotTotal, SLOT_SIZE.Z),
                cframe = slotCFrame,
                color = COLORS.slot,
                material = Enum.Material.Concrete,
                parent = slots,
            })
        end
    end
end

-- 고스트: 완성 모델 크기의 반투명 파란 상자
local function buildGhost(padModel: Model, center: Vector3, top: number, body: Vector3)
    local ghost = makeModel("Ghost", padModel)
    makePart({
        name = "GhostBox",
        size = body,
        cframe = CFrame.new(center.X, top + body.Y / 2, center.Z),
        color = COLORS.ghost,
        material = Enum.Material.SmoothPlastic,
        transparency = Config.GHOST_TRANSPARENCY,
        canCollide = false,
        parent = ghost,
    })
end

local function buildModulePads(kit: Model)
    local pads = makeFolder("ModulePads", kit)
    for _, id in Config.MODULE_ORDER do
        local layout = MODULE_LAYOUT[id]
        local padModel = makeModel("Pad" .. id, pads)
        local padCFrame, padTotal = slabCFrame(CFrame.identity, layout.center, layout.pad.Y)
        makePart({
            name = "Pad",
            size = Vector3.new(layout.pad.X, padTotal, layout.pad.Z),
            cframe = padCFrame,
            color = COLORS.modulePad,
            material = Enum.Material.Concrete,
            parent = padModel,
        })
        local top = FLOOR_Y + layout.pad.Y
        buildGhost(padModel, layout.center, top, layout.body)

        local built = makeModel("Built", padModel)
        if id == "A" then
            -- Habitat A: 안에 들어갈 수 있는 건물 + 산소 구역
            local hutTop = buildHut(
                built,
                layout.center,
                layout.body,
                COLORS.habitat,
                Enum.Material.SmoothPlastic
            )
            makeMarker(
                "OxygenZone",
                Vector3.new(layout.body.X - 2 * WALL, layout.body.Y, layout.body.Z - 2 * WALL),
                CFrame.new(layout.center.X, hutTop + layout.body.Y / 2, layout.center.Z),
                padModel
            )
        elseif id == "B" then
            -- Farm B: 온실
            makePart({
                name = "Greenhouse",
                size = layout.body,
                cframe = CFrame.new(layout.center.X, top + layout.body.Y / 2, layout.center.Z),
                color = COLORS.farm,
                material = Enum.Material.Glass,
                transparency = 0.3,
                parent = built,
            })
        else
            -- Research Lab C: 본관 + 돔
            makePart({
                name = "LabBody",
                size = layout.body,
                cframe = CFrame.new(layout.center.X, top + layout.body.Y / 2, layout.center.Z),
                color = COLORS.lab,
                material = Enum.Material.SmoothPlastic,
                parent = built,
            })
            local dome = layout.body.X * 0.6
            makePart({
                name = "Dome",
                shape = Enum.PartType.Ball,
                size = Vector3.new(dome, dome, dome),
                cframe = CFrame.new(layout.center.X, top + layout.body.Y, layout.center.Z),
                color = COLORS.lab,
                material = Enum.Material.SmoothPlastic,
                parent = built,
            })
        end
    end
end

local function buildWaterTank(kit: Model)
    local tankCFrame, tankTotal =
        slabCFrame(CFrame.identity, WATER_TANK_POSITION, WATER_TANK_SIZE.Y)
    local tank = makePart({
        name = "WaterTank",
        size = Vector3.new(WATER_TANK_SIZE.X, tankTotal, WATER_TANK_SIZE.Z),
        cframe = tankCFrame,
        color = COLORS.tankBlue,
        material = Enum.Material.Metal,
        parent = kit,
    })
    makeSign(tank, Config.PROMPT_TEXTS.unload, WATER_TANK_SIZE.Y)
end

local function buildBaseKit()
    local kit = makeModel("BaseKit", nil)
    local origin = makeMarker("Origin", ORIGIN_SIZE, CFrame.identity, kit)
    kit.PrimaryPart = origin
    buildLander(kit)
    buildRover(kit)
    buildSolarField(kit)
    buildModulePads(kit)
    buildWaterTank(kit)
    kit.Parent = ServerStorage
end

local function buildPanelTemplate()
    local template = makeModel("PanelTemplate", nil)
    local panel = makePart({
        name = "Panel",
        size = Vector3.new(4.6, 0.3, 3.2),
        cframe = CFrame.new(0, 0.35, 0),
        color = COLORS.panel,
        material = Enum.Material.Glass,
        parent = template,
    })
    panel.Reflectance = 0.2
    makePart({
        name = "Frame",
        size = Vector3.new(4.8, 0.2, 3.4),
        cframe = CFrame.new(0, 0.1, 0),
        color = COLORS.panelFrame,
        material = Enum.Material.Metal,
        parent = template,
    })
    template.PrimaryPart = panel
    template.Parent = ServerStorage
end

-- 진입점: 없는 것만 만든다
function DevMap.ensure()
    if not workspace:FindFirstChild("LandingPads") then
        buildTerrainAndSites()
    elseif not workspace:FindFirstChild("IceSites") then
        buildIceOnly()
    end
    if not ServerStorage:FindFirstChild("BaseKit") then
        buildBaseKit()
    end
    if not ServerStorage:FindFirstChild("PanelTemplate") then
        buildPanelTemplate()
    end
end

return DevMap
