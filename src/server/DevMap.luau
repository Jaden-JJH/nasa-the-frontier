--!strict
-- 그레이박스 맵 생성기 (CONTRACT 4절)
-- 디자이너 맵이 없으면 빈 Baseplate에서도 끝까지 플레이할 수 있게 Part로 맵을 만든다.
--   Workspace.LandingPads가 없으면: 지면, 착륙 패드 4곳, 얼음 지점 3곳, 바위, 조명
--   ServerStorage.BaseKit이 없으면: 착륙선, 로버, 솔라 필드, 모듈 패드 3개, 물탱크
--   ServerStorage.PanelTemplate이 없으면: 태양광 패널 1장
-- 게임 수치(얼음 거리, 바위 수, 로버 성능)는 Config에서 오고, 아래 상수는 배치와 모양만 정한다.
--
-- 간편 경로 (KitImports): 편집 중 Workspace.KitImports에 Rover, Lander, HabitatA/B/C, Panel, Rock1.. 메시를
-- 넣어 두면 해당 부분의 외형만 그 메시로 바꾼다. 판정과 물리 파트(Origin, DriverSeat, 바퀴 힌지, SpawnPoint,
-- OxygenZone, Pad, Ghost, Built, 속성, 프롬프트 대상)의 이름과 구조는 그레이박스와 똑같다.
-- KitImports 폴더는 서버 시작 시 ServerStorage로 옮겨져 플레이 중에는 보이지 않는다 (KitImports.luau).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local KitImports = require(script.Parent.KitImports)
local ServerUtil = require(script.Parent.ServerUtil)

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
local BOULDER_EMBED_RATIO = 0.2 -- 바위 높이의 이 비율만큼 지면에 묻는다

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

-- KitImports 외형 목표 크기 (studs, 폭 X, 높이 Y, 깊이 Z). 메시는 이 상자 안에 들어가게 균일 스케일한다
local ROVER_SEAT_SIZE = Vector3.new(2, 1, 2)
local ROVER_VISUAL_BOX = Vector3.new(8.8, 3.5, 11) -- 바퀴 포함 리그 크기. 높이를 낮게 두어 좌석 높이를 제한
local ROVER_SHOW_RIG_WHEELS = false -- 메시를 쓸 때 물리 바퀴 원기둥을 보일지 (메시 바퀴와 겹치므로 기본은 숨김)
local LANDER_VISUAL_BOX = Vector3.new(14, 18, 14) -- 그레이박스 착륙선 바닥 넓이 안
local LANDER_ZONE_MARGIN = 4 -- 착륙선 메시 경계 상자 바깥으로 산소 구역을 넓히는 거리
local MODULE_VISUAL_BOX = {
    A = Vector3.new(17, 12, 17),
    B = Vector3.new(17, 10, 17),
    C = Vector3.new(20, 16, 20),
}
local HABITAT_ZONE_MARGIN = 4 -- Habitat 메시 경계 상자 바깥으로 산소 구역을 넓히는 거리
local PANEL_VISUAL_BOX = Vector3.new(4.8, 1.5, 3.4) -- 슬롯(5 x 3.5) 안
local ROCK_BASE_SIZE = 5.5 -- 바위 메시의 기준 크기 (가장 긴 변)
local ROCK_SCALE_MIN, ROCK_SCALE_MAX = 0.7, 1.4 -- 기준 크기에 곱하는 무작위 배율

-- KitImports 장식 (선택, 외형 전용). 그레이박스 조립 때만 쓴다
local ICE_CRYSTAL_FILL = 0.85 -- 얼음 Part 바닥 넓이 대비 결정 메시 폭 (Part보다 약간 작게)
local ICE_CRYSTAL_MAX_HEIGHT = 9 -- 결정은 위로 솟아도 되지만 이 높이까지
local ICE_CRYSTAL_EMBED = 0.3 -- 지면에 묻는 깊이
local WATER_TANK_VISUAL_BOX = Vector3.new(8, 7, 8)
local PAD_RING_MAX_HEIGHT = 1.5 -- 링 메시 높이 상한
local PAD_RING_RAISE = 0.1 -- 링 윗면이 패드 윗면보다 이만큼만 올라오게 묻는다 (Ghost, Built와 겹치지 않게)
local MAST_BOX = Vector3.new(2, 3.5, 2) -- 착륙선 지붕 안테나
local RADAR_BOX = Vector3.new(3.5, 3.5, 3.5) -- 착륙선 지붕 레이더
local CONSOLE_MAST_BOX = Vector3.new(1.2, 3, 1.2) -- 로버 복구 콘솔 위 안테나
local ROOF_DECOR_OFFSET = 3 -- 지붕 중심에서 안테나와 레이더를 좌우로 띄우는 거리 (지붕 반폭의 절반까지)
local CRATE_SIZE = 3
local CRATE_ORIGIN = Vector3.new(11, 0, 16) -- 착륙선 뒤 오른쪽 (스폰, 로버 경로, 모듈 통로를 피함)
local CRATE_PITCH = 3.8
local CRATE_YAWS = { 0, 12, -8, 20 } -- 2 x 2 상자의 회전(도)

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

-- KitImports 장식 하나를 box에 맞춰 바닥 중심 bottomCenter에 놓는다 (메시가 없으면 nil)
local function placeDecor(
    importName: string,
    box: Vector3,
    bottomCenter: Vector3,
    canCollide: boolean,
    parent: Instance,
    name: string
): Model?
    local model = KitImports.take(importName)
    if not model then
        return nil
    end
    KitImports.fitInto(model, box, bottomCenter)
    KitImports.setStatic(model, canCollide)
    model.Name = name
    model.Parent = parent
    return model
end

-- 패드 윗면에 링 메시를 패드 크기로 얹고 대부분을 묻는다 (프롬프트 대상은 패드 Part 그대로)
local function addPadRing(pad: BasePart)
    local ring = KitImports.take("Pad")
    if not ring then
        return
    end
    KitImports.fitInto(ring, Vector3.new(pad.Size.X, PAD_RING_MAX_HEIGHT, pad.Size.Z), Vector3.zero)
    local lo, hi = KitImports.bounds(ring)
    local padTop = pad.CFrame.Position.Y + pad.Size.Y / 2
    KitImports.placeBottom(
        ring,
        Vector3.new(
            pad.CFrame.Position.X,
            padTop + PAD_RING_RAISE - (hi.Y - lo.Y),
            pad.CFrame.Position.Z
        )
    )
    KitImports.setStatic(ring, false)
    ring.Name = "Ring"
    ring.Parent = pad
end

-- 얼음 Part는 숨기고(프롬프트와 레이더 거리 기준은 그대로) 결정 메시를 얹는다
local function dressIce(ice: BasePart)
    local crystal = KitImports.take("IceCrystal")
    if not crystal then
        return
    end
    local box = Vector3.new(
        ice.Size.X * ICE_CRYSTAL_FILL,
        ICE_CRYSTAL_MAX_HEIGHT,
        ice.Size.Z * ICE_CRYSTAL_FILL
    )
    local p = ice.CFrame.Position
    KitImports.fitInto(
        crystal,
        box,
        Vector3.new(p.X, p.Y - ice.Size.Y / 2 - ICE_CRYSTAL_EMBED, p.Z)
    )
    KitImports.setStatic(crystal, true)
    crystal.Name = "Crystal"
    crystal.Parent = ice
    ice.Transparency = 1
    ice.CanCollide = false -- 충돌은 결정 메시가 맡는다
end

-- 바닥에 놓이는 슬래브: 윗면이 floorY + height, 아래로 EMBED만큼 묻힌다
local function slabCFrame(base: CFrame, position: Vector3, height: number): (CFrame, number)
    local total = height + EMBED
    return base * CFrame.new(position.X, FLOOR_Y + height - total / 2, position.Z), total
end

-- 건물 바닥 슬래브 "Floor". 반환: 바닥 윗면 높이
local function buildFloor(parent: Instance, center: Vector3, size: Vector3): number
    local floorCFrame, floorTotal = slabCFrame(CFrame.identity, center, WALL)
    makePart({
        name = "Floor",
        size = Vector3.new(size.X, floorTotal, size.Z),
        cframe = floorCFrame,
        color = COLORS.landerTrim,
        material = Enum.Material.DiamondPlate,
        parent = parent,
    })
    return FLOOR_Y + WALL
end

-- 문이 앞쪽(-Z)에 난 상자형 건물 (바닥, 지붕, 벽 4면). 반환: 바닥 윗면 높이
local function buildHut(
    parent: Instance,
    center: Vector3,
    size: Vector3,
    color: Color3,
    material: Enum.Material
): number
    local floorTop = buildFloor(parent, center, size)
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

type RockSet = { templates: { Model }, used: number }

-- 바위 1개. 난수는 메시 여부와 관계없이 같은 순서로 6개를 써서 바위 위치 배치가 항상 같다
local function makeBoulder(rng: Random, position: Vector3, parent: Instance, rocks: RockSet)
    local s = rng:NextNumber(BOULDER_MIN, BOULDER_MAX)
    local size = Vector3.new(s, s * rng:NextNumber(0.5, 0.9), s * rng:NextNumber(0.7, 1.2))
    local rotation = CFrame.Angles(
        math.rad(rng:NextNumber(-15, 15)),
        math.rad(rng:NextNumber(0, 360)),
        math.rad(rng:NextNumber(-15, 15))
    )
    if #rocks.templates > 0 then
        -- Rock1, Rock2 ... 순환, 기준 크기의 0.7 ~ 1.4배
        rocks.used += 1
        local rock = rocks.templates[(rocks.used - 1) % #rocks.templates + 1]:Clone()
        local t = (s - BOULDER_MIN) / (BOULDER_MAX - BOULDER_MIN)
        KitImports.scaleBy(rock, ROCK_SCALE_MIN + t * (ROCK_SCALE_MAX - ROCK_SCALE_MIN))
        KitImports.rotateAboutCenter(rock, rotation)
        local lo, hi = KitImports.bounds(rock)
        local height = hi.Y - lo.Y
        KitImports.placeBottom(
            rock,
            Vector3.new(position.X, GROUND_TOP - height * BOULDER_EMBED_RATIO, position.Z)
        )
        rock.Name = "Boulder"
        rock.Parent = parent
        return
    end
    makePart({
        name = "Boulder",
        size = size,
        cframe = CFrame.new(
            position.X,
            GROUND_TOP + size.Y * (0.5 - BOULDER_EMBED_RATIO),
            position.Z
        ) * rotation,
        color = COLORS.boulder,
        material = Enum.Material.Basalt,
        parent = parent,
    })
end

-- KitImports의 바위 메시를 기준 크기로 맞춘 원본 목록
local function prepareRocks(): RockSet
    local templates = KitImports.takeRocks()
    for _, rock in templates do
        KitImports.fitInto(rock, Vector3.one * ROCK_BASE_SIZE, Vector3.zero)
        KitImports.forEachPart(rock, function(part)
            part.Anchored = true
            part.CanCollide = true
        end)
    end
    return { templates = templates, used = 0 }
end

local function buildBoulders(terrain: Instance, padPositions: { Vector3 })
    local rng = Random.new(Config.DEV_MAP.seed)
    local folder = makeFolder("Boulders", terrain)
    local rocks = prepareRocks()
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
                    makeBoulder(rng, position, folder, rocks)
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
                makeBoulder(rng, position, folder, rocks)
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
        ServerUtil.safeCall("DevMap IceCrystal", dressIce, ice)
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
        local ice = makePart({
            name = "Ice" .. index,
            size = ICE_SIZE,
            cframe = CFrame.new(position.X, GROUND_TOP + ICE_SIZE.Y / 2, position.Z),
            color = COLORS.ice,
            material = Enum.Material.Ice,
            parent = iceFolder,
        })
        ServerUtil.safeCall("DevMap IceCrystal", dressIce, ice)
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
    local wheels: { BasePart } = {}

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
        table.insert(wheels, wheel)

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

    -- 외형 메시 (KitImports.Rover). 물리 리그는 그대로 두고 메시를 얹어 섀시에 용접한다
    local seatCFrame = chassisCFrame
        * CFrame.new(0, CHASSIS_SIZE.Y / 2 + ROVER_SEAT_SIZE.Y / 2, 1.5)
    local visual, yawSet = KitImports.take("Rover")
    if visual then
        if not yawSet then
            KitImports.alignLongAxis(visual, "Z")
        end
        KitImports.fitInto(
            visual,
            ROVER_VISUAL_BOX,
            Vector3.new(chassisCFrame.X, FLOOR_Y + WHEEL_CLEARANCE, chassisCFrame.Z)
        )
        visual.Name = "Visual"
        KitImports.forEachPart(visual, function(part)
            part.Anchored = false
            part.Massless = true
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            weld(chassis, part)
        end)
        visual.Parent = rover
        -- 리그는 판정과 물리만 맡고 보이지 않게 (메시가 외형)
        chassis.Transparency = 1
        tankBox.Transparency = 1
        if not ROVER_SHOW_RIG_WHEELS then
            for _, wheel in wheels do
                wheel.Transparency = 1
            end
        end
        -- 좌석은 메시 윗면 중앙에 올려 보이고 탈 수 있게 한다
        local _, top = KitImports.bounds(visual)
        seatCFrame = CFrame.new(chassisCFrame.X, top.Y + ROVER_SEAT_SIZE.Y / 2, chassisCFrame.Z)
    end

    -- 좌석은 위치를 정한 뒤 용접한다
    local seat = Instance.new("VehicleSeat")
    seat.Name = "DriverSeat"
    seat.Size = ROVER_SEAT_SIZE
    seat.CFrame = seatCFrame
    seat.Color = COLORS.landerTrim
    seat.Anchored = false
    seat.MaxSpeed = rv.maxSpeed
    seat.Torque = rv.torque
    seat.TurnSpeed = rv.turnSpeed
    seat:SetAttribute("Tank", 0)
    seat.Parent = rover
    weld(chassis, seat)
end

-- 기지 키트 -------------------------------------------------------------

local function buildLander(kit: Model)
    local lander = makeModel("Lander", kit)
    local zoneFront = SPAWN_POSITION.Z - 3 -- 산소 구역은 문 앞 스폰 위치까지 덮는다
    local zoneMin: Vector3
    local zoneMax: Vector3
    local roofCenter: Vector3 -- 지붕 장식 기준 (윗면 중심)
    local roofHalfWidth: number
    local visual = KitImports.take("Lander")
    if visual then
        -- 착륙 데크(Floor, PrimaryPart) 위에 메시를 올린다
        local floorTop = buildFloor(lander, LANDER_CENTER, LANDER_SIZE)
        KitImports.fitInto(
            visual,
            LANDER_VISUAL_BOX,
            Vector3.new(LANDER_CENTER.X, floorTop, LANDER_CENTER.Z)
        )
        visual.Name = "Visual"
        KitImports.forEachPart(visual, function(part)
            part.Anchored = true
            part.CanCollide = true
        end)
        visual.Parent = lander
        -- 메시 경계 상자를 덮고 바깥으로 여유를 둔 산소 구역
        local lo, hi = KitImports.bounds(visual)
        local m = LANDER_ZONE_MARGIN
        zoneMin = Vector3.new(lo.X - m, floorTop, math.min(lo.Z - m, zoneFront))
        zoneMax = Vector3.new(hi.X + m, math.max(hi.Y, floorTop + LANDER_SIZE.Y), hi.Z + m)
        roofCenter = Vector3.new((lo.X + hi.X) / 2, hi.Y, (lo.Z + hi.Z) / 2)
        roofHalfWidth = (hi.X - lo.X) / 2
    else
        local floorTop =
            buildHut(lander, LANDER_CENTER, LANDER_SIZE, COLORS.lander, Enum.Material.Metal)
        -- 실내와 문 앞(스폰 위치 포함)을 덮는 산소 구역
        local halfInside = LANDER_SIZE.X / 2 - WALL
        zoneMin = Vector3.new(LANDER_CENTER.X - halfInside, floorTop, zoneFront)
        zoneMax = Vector3.new(
            LANDER_CENTER.X + halfInside,
            floorTop + LANDER_SIZE.Y,
            LANDER_CENTER.Z + LANDER_SIZE.Z / 2 - WALL
        )
        roofCenter = Vector3.new(LANDER_CENTER.X, floorTop + LANDER_SIZE.Y + WALL, LANDER_CENTER.Z)
        roofHalfWidth = LANDER_SIZE.X / 2
    end
    lander.PrimaryPart = lander:FindFirstChild("Floor") :: BasePart
    makeMarker("OxygenZone", zoneMax - zoneMin, CFrame.new((zoneMin + zoneMax) / 2), lander)

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

    -- KitImports 장식: 지붕 안테나와 레이더, 콘솔 위 안테나 (충돌 없음)
    ServerUtil.safeCall("DevMap LanderDecor", function()
        local offset = Vector3.new(math.min(ROOF_DECOR_OFFSET, roofHalfWidth / 2), 0, 0)
        placeDecor("Antenna", MAST_BOX, roofCenter + offset, false, lander, "RoofAntenna")
        placeDecor("Radar", RADAR_BOX, roofCenter - offset, false, lander, "RoofRadar")
        local consoleTop = Vector3.new(
            ROVER_CONSOLE_POSITION.X,
            FLOOR_Y + ROVER_CONSOLE_SIZE.Y,
            ROVER_CONSOLE_POSITION.Z
        )
        placeDecor("Antenna", CONSOLE_MAST_BOX, consoleTop, false, lander, "ConsoleAntenna")
    end)
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
    ServerUtil.safeCall("DevMap PadRing", addPadRing, installPad)

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
        local padPart = makePart({
            name = "Pad",
            size = Vector3.new(layout.pad.X, padTotal, layout.pad.Z),
            cframe = padCFrame,
            color = COLORS.modulePad,
            material = Enum.Material.Concrete,
            parent = padModel,
        })
        ServerUtil.safeCall("DevMap PadRing", addPadRing, padPart)
        local top = FLOOR_Y + layout.pad.Y

        local visual = KitImports.take("Habitat" .. id)
        if visual then
            -- 외형 메시: 패드 폭에 맞게 스케일하고 바닥을 Pad 윗면에 맞춘다. Ghost는 같은 메시의 반투명 복제본
            KitImports.fitInto(
                visual,
                MODULE_VISUAL_BOX[id],
                Vector3.new(layout.center.X, top, layout.center.Z)
            )
            KitImports.forEachPart(visual, function(part)
                part.Anchored = true
                part.CanCollide = true
            end)
            local ghost = visual:Clone()
            ghost.Name = "Ghost"
            KitImports.ghostify(ghost, COLORS.ghost, Config.GHOST_TRANSPARENCY)
            ghost.Parent = padModel
            visual.Name = "Built"
            visual.Parent = padModel
            if id == Config.OXYGEN.habitatModule then
                -- Built 경계 상자를 덮고 바깥으로 여유를 둔 산소 구역
                local lo, hi = KitImports.bounds(visual)
                local m = HABITAT_ZONE_MARGIN
                local zoneMin = Vector3.new(lo.X - m, top, lo.Z - m)
                local zoneMax = Vector3.new(hi.X + m, hi.Y + m, hi.Z + m)
                makeMarker(
                    "OxygenZone",
                    zoneMax - zoneMin,
                    CFrame.new((zoneMin + zoneMax) / 2),
                    padModel
                )
            end
            continue
        end

        buildGhost(padModel, layout.center, top, layout.body)
        local built = makeModel("Built", padModel)
        if id == Config.OXYGEN.habitatModule then
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

    -- KitImports 장식: 탱크 Part는 숨기고(프롬프트와 하역 거리 기준은 그대로) 메시를 같은 자리에
    ServerUtil.safeCall("DevMap WaterTank", function()
        local bottom = Vector3.new(WATER_TANK_POSITION.X, FLOOR_Y, WATER_TANK_POSITION.Z)
        if placeDecor("WaterTank", WATER_TANK_VISUAL_BOX, bottom, true, tank, "Visual") then
            tank.Transparency = 1
            tank.CanCollide = false
        end
    end)
end

-- KitImports 장식: 착륙선 옆 바닥에 상자 2 x 2
local function addCrates(kit: Model)
    if not KitImports.has("Crate") then
        return
    end
    local crates = makeModel("Crates", kit)
    local index = 0
    for row = 0, 1 do
        for column = 0, 1 do
            index += 1
            local crate = KitImports.take("Crate")
            if crate then
                KitImports.fitInto(crate, Vector3.one * CRATE_SIZE, Vector3.zero)
                KitImports.rotateAboutCenter(
                    crate,
                    CFrame.Angles(0, math.rad(CRATE_YAWS[index]), 0)
                )
                KitImports.placeBottom(
                    crate,
                    Vector3.new(
                        CRATE_ORIGIN.X + column * CRATE_PITCH,
                        FLOOR_Y,
                        CRATE_ORIGIN.Z + row * CRATE_PITCH
                    )
                )
                KitImports.setStatic(crate, true)
                crate.Name = "Crate"
                crate.Parent = crates
            end
        end
    end
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
    ServerUtil.safeCall("DevMap Crates", addCrates, kit)
    kit.Parent = ServerStorage
end

local function buildPanelTemplate()
    local visual, yawSet = KitImports.take("Panel")
    if visual then
        -- 외형 메시: 슬롯 크기에 맞게 스케일 (긴 변을 슬롯의 긴 변 X에 맞춘다)
        if not yawSet then
            KitImports.alignLongAxis(visual, "X")
        end
        KitImports.fitInto(visual, PANEL_VISUAL_BOX, Vector3.zero)
        KitImports.forEachPart(visual, function(part)
            part.Anchored = true
            part.CanCollide = false
        end)
        visual.Name = "PanelTemplate"
        if not visual.PrimaryPart then
            visual.PrimaryPart = KitImports.largestPart(visual)
        end
        visual.Parent = ServerStorage
        return
    end
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
    -- Workspace.KitImports를 ServerStorage로 옮기고 항목을 검사한다 (플레이 중에는 보이지 않게)
    KitImports.load()
    -- 하늘의 행성은 맵 종류와 관계없이 (Workspace.Decor.Planet이 이미 있으면 건너뜀)
    ServerUtil.safeCall("KitImports Planet", KitImports.ensurePlanet)
    local kitParts = { "Rover", "Lander", "HabitatA", "HabitatB", "HabitatC" }
    if ServerStorage:FindFirstChild("BaseKit") then
        for _, name in kitParts do
            if KitImports.has(name) then
                warn(
                    "[DevMap] ServerStorage.BaseKit이 이미 있어 KitImports의 기지 외형은 쓰지 않습니다"
                )
                break
            end
        end
    end
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
