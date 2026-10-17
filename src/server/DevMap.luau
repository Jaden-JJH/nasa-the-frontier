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
local LANDING_PAD_SIZE = Vector3.new(48, 1, 48) -- 윗면은 GROUND_TOP + 0.5. 지면까지 아래로 늘려 묻는다
local ICE_SIZE = Vector3.new(14, 3, 14)
local ICE_LIGHT_RANGE = 18
local ICE_LIGHT_BRIGHTNESS = 1.2
local ICE_TRANSPARENCY = 0.1 -- 얼음 덩어리 (Part와 결정 메시 공통)

-- 달 지형 (Roblox Terrain). Terrain이 없는 환경(Lune 스모크)에서는 평평한 지면 Part로 대신한다
-- 다시 켬(3차 플레이테스트): 기지는 콘크리트 판(윗면 GROUND_TOP) 위에 놓고, 지형은 그보다 1 stud 낮게 깔아
-- Terrain 복셀(4 studs)이 얇은 패드와 슬롯을 덮지 않게 한다. false면 예전처럼 평평한 지면 Part 하나
local TERRAIN_ENABLED = true
local TERRAIN_TOP = GROUND_TOP - 1 -- 지형 윗면 (콘크리트 판보다 1 stud 아래)
local SURFACE_Y = if TERRAIN_ENABLED then TERRAIN_TOP else GROUND_TOP -- 얼음, 바위가 놓이는 자연 지면
local TERRAIN_THICKNESS = 24
local TERRAIN_SEED_OFFSET = 1 -- 바위 배치와 다른 난수 흐름 (같은 시드에서 결정적)
local TERRAIN_EDGE_MARGIN = 10 -- 지형 특징을 맵 가장자리에서 띄우는 거리
local PAD_TERRAIN_CLEARANCE = 80 -- 착륙 패드 중심 반지름 (콘크리트 판 포함) 안은 평지 유지
local ICE_TERRAIN_CLEARANCE = 30 -- 얼음 지점 중심 반지름 안은 평지 유지
local CORRIDOR_CLEARANCE = 12 -- 착륙 패드에서 가장 가까운 얼음까지 폭 24 주행 회랑의 반폭 (지형, 바위 금지)
local FEATURE_ATTEMPTS = 40
local CRATER_RADIUS_MIN, CRATER_RADIUS_MAX = 12, 40 -- 복셀 4 studs라 반지름 12 미만은 만들지 않는다
local CRATER_DEPTH_RATIO = 0.2 -- 사발 깊이 = 반지름 x 비율 (얕은 사발)
local CRATER_RIM_HEIGHT_RATIO = 0.08 -- 테두리 둔덕 높이 = 반지름 x 비율
local CRATER_RIM_HEIGHT_MAX = 1.5
local CRATER_RIM_PIECES = 12 -- 테두리는 가장자리를 따라 작은 공을 둘러 만든다
local CRATER_RIM_PIECE_RATIO = 0.3 -- 테두리 공 반지름 = 크레이터 반지름 x 비율
local CRATER_RIM_PIECE_MIN = 4
local CRATERS_NEAR_SITE = { 1, 2, 2, 6 } -- 착륙지 주변 크레이터 (Pad4는 지형 위험 높음)
local CRATER_NEAR_RING = 220 -- 착륙지 "주변" 거리
local CRATERS_SCATTERED = 9 -- 맵 전체 (주변 11개와 합쳐 20개)
local HILL_COUNT = 7
local HILL_RADIUS_MIN, HILL_RADIUS_MAX = 40, 80
local HILL_HEIGHT_MIN, HILL_HEIGHT_MAX = 2, 4 -- 지형 위로 솟는 높이

-- 기지 콘크리트 판 (지형을 켤 때 기지 키트에 포함): 키트 바닥 면적 + 여유, 윗면은 GROUND_TOP
local APRON_MARGIN = 8
local APRON_THICKNESS = 2
local RAMP_WIDTH, RAMP_LENGTH = 10, 4 -- 판 가장자리 4면 중앙의 경사로 (판과 지형 사이 1 stud 단차)
local greyboxTerrainBuilt = false -- 이번 세션에 지형을 켠 그레이박스 맵을 만들었는지 (콘크리트 판 여부)

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

local KIT_CLEARANCE = 80 -- 패드 중심에서 이 거리 안에는 바위를 두지 않는다 (콘크리트 판 포함)
local ICE_CLEARANCE = 20 -- 얼음 중심 주변 바위 금지 거리
local CLUSTER_SPREAD = 22 -- 회랑 가장자리 밖으로 바위 무더기가 퍼지는 폭
local CLUSTER_BEYOND_ICE = 60 -- 회랑 방향으로 얼음 너머까지 무더기를 두는 거리
local CLUSTER_MIN_LENGTH = 140 -- 패드에서 무더기 구간 최소 길이 (얼음이 가까운 Pad4도 조밀하게)
local BIG_BOULDER_CHANCE = 0.1 -- 전체의 약 10%는
local BIG_BOULDER_SCALE = 2 -- 2배 크기
local BOULDER_MIN, BOULDER_MAX = 3, 8
local BOULDER_ATTEMPTS = 20
local BOULDER_EMBED_RATIO = 0.2 -- 바위 높이의 이 비율만큼 지면에 묻는다

-- 기지 키트 배치 상수 (Origin 기준 로컬 좌표, 앞쪽 = -Z = 얼음 방향) -------

local ORIGIN_SIZE = Vector3.new(4, 1, 4)
local FLOOR_Y = -ORIGIN_SIZE.Y / 2 -- 패드 윗면 높이
local EMBED = 1 -- 패드 밖 지면(패드 윗면보다 0.5 낮음)까지 닿도록 바닥 파트를 아래로 늘리는 길이

local LANDER_CENTER = Vector3.new(0, 0, 6)
local LANDER_SIZE = Vector3.new(14, 10, 14) -- 폭, 높이, 깊이
local ROVER_CENTER = Vector3.new(0, 0, -16)
-- 로버 주차 위치 옆. 운전석에 앉은 채 하역 프롬프트(활성 거리 12)가 닿도록 로버에서 약 10 studs
local WATER_TANK_POSITION = Vector3.new(-10, 0, -14)
local WATER_TANK_SIZE = Vector3.new(6, 8, 6)
-- 로버 복구 콘솔: 착륙선 오른쪽(+X) 바깥, 문과 겹치지 않게 앞쪽. 상자 4개는 그 뒤(+Z)
local ROVER_CONSOLE_SIZE = Vector3.new(2, 3, 1)
local ROVER_CONSOLE_SIDE_GAP = 1.5 -- 충돌 벽 바깥에서 콘솔까지
local ROVER_CONSOLE_FROM_FRONT = 2 -- 착륙선 앞면에서 안쪽으로
local RADAR_SIDE_GAP = 2 -- 레이더(지상 장비)는 착륙선 왼쪽(-X) 충돌 벽 바깥

local SOLAR_CENTER = Vector3.new(34, 0, 6)
local SOLAR_COLUMNS, SOLAR_ROWS = 5, 6
-- 슬롯 한 칸 5 x 4, 간격 1 (필드 전체 약 29 x 29). 키트 패널 바닥 비율(약 1.29 : 1.67)에 맞춰
-- 정사각형 대신 5 x 4로 두어 균일 스케일해도 두 변이 모두 슬롯의 90% 이상을 채운다
local SLOT_SIZE = Vector3.new(5, 0.2, 4)
local SLOT_GAP_X, SLOT_GAP_Z = 1, 1
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
local WHEEL_CHASSIS_GAP = 0.2 -- 섀시 옆면과 바퀴 안쪽 사이 틈
local WHEEL_OFFSET_X = CHASSIS_SIZE.X / 2 + WHEEL_CHASSIS_GAP + WHEEL_WIDTH / 2
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
local ROVER_VISUAL_LENGTH = 11 -- 로버 메시 앞뒤 길이 (리그 길이). 폭과 높이는 원본 비율 그대로
local ROVER_MIN_WHEEL_OFFSET_X = 2.5 -- 메시가 아주 좁아도 바퀴 간격은 이보다 좁히지 않는다 (전복 방지)
-- 좌석은 캐빈 안: 앞쪽(-Z) 끝에서 메시 길이의 35% 지점, 메시 바닥에서 높이의 35% (앉은 캐릭터 머리가 천장 아래)
local ROVER_SEAT_HEIGHT_RATIO = 0.35 -- 좌석 중심 높이 = 메시 바닥에서 메시 높이의 이 비율
local ROVER_SEAT_MAX_HEIGHT = 4.5 -- 좌석 중심 높이 상한 (메시 바닥 기준)
local ROVER_SEAT_FROM_FRONT_RATIO = 0.35 -- 좌석 중심 = 메시 앞쪽 끝에서 메시 길이의 이 비율만큼 뒤
local ROVER_SHOW_RIG_WHEELS = false -- 메시를 쓸 때 물리 바퀴 원기둥을 보일지 (메시 바퀴와 겹치므로 기본은 숨김)
local LANDER_VISUAL_BOX = Vector3.new(14, 40, 14) -- 폭 약 14, 높이는 원본 비율대로 (높이 상한은 사실상 없음)
local MODULE_VISUAL_BOX = {
    A = Vector3.new(17, 12, 17),
    B = Vector3.new(17, 10, 17),
    C = Vector3.new(20, 16, 20),
}
local PANEL_FILL = 0.95 -- 패널 바닥이 슬롯 x, z의 이 비율을 채운다 (메시와 그레이박스 공통)
local PANEL_MAX_HEIGHT = 20 -- 메시 패널 높이 상한 (사실상 없음, 높이는 원본 비율대로)
local PANEL_FRAME_HEIGHT, PANEL_GLASS_HEIGHT = 0.2, 0.3 -- 그레이박스 패널 틀과 판 두께
local PANEL_GLASS_INSET = 0.1 -- 그레이박스 패널 판이 틀 안쪽으로 들어가는 폭
local ROCK_BASE_SIZE = 5.5 -- 바위 메시의 기준 크기 (가장 긴 변)
local ROCK_SCALE_MIN, ROCK_SCALE_MAX = 0.7, 1.4 -- 기준 크기에 곱하는 무작위 배율

-- KitImports 장식 (선택, 외형 전용). 그레이박스 조립 때만 쓴다
local ICE_CRYSTAL_FILL = 0.85 -- 얼음 Part 바닥 넓이 대비 결정 메시 폭 (Part보다 약간 작게)
local ICE_CRYSTAL_MAX_HEIGHT = 9 -- 결정은 위로 솟아도 되지만 이 높이까지
local ICE_CRYSTAL_EMBED = 0.3 -- 지면에 묻는 깊이
local WATER_TANK_VISUAL_BOX = Vector3.new(7, 7, 7)
local PAD_RING_MAX_HEIGHT = 1.5 -- 링 메시 높이 상한
local PAD_RING_RAISE = 0.1 -- 링 윗면이 패드 윗면보다 이만큼만 올라오게 묻는다 (Ghost, Built와 겹치지 않게)
local MAST_BOX = Vector3.new(1.5, 2.5, 1.5) -- 착륙선 꼭대기 안테나 (높이 2.5)
local RADAR_BOX = Vector3.new(2.5, 2.5, 2.5) -- 착륙선 왼쪽 바닥의 지상 레이더 (높이 2.5)
local CONSOLE_MAST_BOX = Vector3.new(1, 1.5, 1) -- 로버 복구 콘솔 위 안테나 (높이 1.5)
local CRATE_SIZE = 3
local CRATE_BEHIND_CONSOLE = 3 -- 콘솔 중심에서 상자 첫 줄까지 (+Z)
local CRATE_PITCH = 3.8
local CRATE_YAWS = { 0, 12, -8, 20 } -- 2 x 2 상자의 회전(도)

-- 색상
local COLORS = {
    landingPad = Color3.fromRGB(150, 150, 155),
    ice = Color3.fromRGB(170, 225, 255),
    boulder = Color3.fromRGB(90, 88, 86), -- 표토와 어울리는 회색 바위 (KitImports 바위 메시도 이 색)
    regolith = Color3.fromRGB(128, 126, 122), -- 달 표토 (Terrain 재질 색)
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
    door = Color3.fromRGB(table.unpack(Config.AIRLOCK.doorColor)),
    doorFrame = Color3.fromRGB(table.unpack(Config.AIRLOCK.frameColor)),
    interiorLight = Color3.fromRGB(table.unpack(Config.AIRLOCK.lightColor)),
    apron = Color3.fromRGB(105, 105, 108), -- 기지 콘크리트 판
}

-- 하늘 (맵 종류와 관계없이 적용). Sky는 Attribute KeepSky = true가 아니면 덮어쓴다.
-- 밤에는 Roblox가 달 자리에 MoonTexture를 그리므로 내장 태양 텍스처를 써서 검은 하늘에 태양이 뜨게 한다.
-- ClockTime 2.5: 달(태양) 자리가 비스듬히 보이는 시각
local SKY = {
    moonTextureId = "rbxasset://sky/sun.jpg",
    moonAngularSize = 14,
    starCount = 3000,
    clockTime = 2.5,
}

-- 조명 (그레이박스 맵을 만들 때만 적용)
-- 자정(0시)으로 두어 하늘을 검게 하고, 주변광을 밝게 올려 지면이 보이게 한다
local LIGHTING = {
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

-- 얼음 지점 외형: Part를 얼음 재질로 칠하고, IceCrystal 메시가 있으면 Part는 숨기고(프롬프트와 레이더
-- 거리 기준은 그대로) 메시를 텍스처 없는 얼음 덩어리로 얹는다. 중심에 하늘색 PointLight 하나
local function dressIce(ice: BasePart)
    ice.Color = COLORS.ice
    ice.Material = Enum.Material.Ice
    ice.Transparency = ICE_TRANSPARENCY
    local glowCenter = ice.CFrame.Position
    local crystal = KitImports.take("IceCrystal")
    if crystal then
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
        KitImports.recolor(crystal, COLORS.ice, Enum.Material.Ice, ICE_TRANSPARENCY)
        crystal.Name = "Crystal"
        crystal.Parent = ice
        ice.Transparency = 1
        ice.CanCollide = false -- 충돌은 결정 메시가 맡는다
        local lo, hi = KitImports.bounds(crystal)
        glowCenter = (lo + hi) / 2
    end
    local glow = Instance.new("Attachment")
    glow.Name = "IceGlow"
    glow.CFrame = ice.CFrame:ToObjectSpace(CFrame.new(glowCenter))
    glow.Parent = ice
    local light = Instance.new("PointLight")
    light.Color = COLORS.ice
    light.Range = ICE_LIGHT_RANGE
    light.Brightness = ICE_LIGHT_BRIGHTNESS
    light.Parent = glow
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

-- 그레이박스 맵 밝기 (주변광을 올려 밤하늘 아래에서도 지면이 보이게)
local function buildLighting()
    Lighting.Brightness = LIGHTING.brightness
    Lighting.Ambient = LIGHTING.ambient
    Lighting.OutdoorAmbient = LIGHTING.outdoorAmbient
end

-- 하늘: Sky(태양 텍스처), Atmosphere(달에는 대기가 없다), ClockTime. 반환: 로그용 설명 두 개
local function setupSky(): (string, string)
    local skyNote: string
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if sky and sky:GetAttribute("KeepSky") == true then
        skyNote = "Sky 유지(KeepSky)"
    else
        if sky then
            skyNote = "Sky 덮어씀"
        else
            sky = Instance.new("Sky")
            skyNote = "Sky 생성"
        end
        local target = sky :: Sky
        target.MoonTextureId = SKY.moonTextureId
        target.MoonAngularSize = SKY.moonAngularSize
        target.StarCount = SKY.starCount
        target.CelestialBodiesShown = true
        target.Parent = Lighting
    end
    local atmosphereNote: string
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if not atmosphere then
        atmosphereNote = "Atmosphere 없음"
    elseif atmosphere:GetAttribute("KeepAtmosphere") == true then
        atmosphereNote = "Atmosphere 유지(KeepAtmosphere)"
    else
        atmosphere.Density = 0
        atmosphere.Haze = 0
        atmosphere.Glare = 0
        atmosphereNote = "Atmosphere 밀도 0"
    end
    Lighting.ClockTime = SKY.clockTime
    return skyNote, atmosphereNote
end

type Footprint = { x: number, z: number, r: number }

-- xz 평면에서 점과 선분 사이 거리
local function segmentDistance(point: Vector3, a: Vector3, b: Vector3): number
    local p = Vector3.new(point.X, 0, point.Z)
    local s0, s1 = Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z)
    local d = s1 - s0
    local lengthSq = d:Dot(d)
    local t = if lengthSq > 0 then math.clamp((p - s0):Dot(d) / lengthSq, 0, 1) else 0
    return (p - (s0 + d * t)).Magnitude
end

-- 가장 가까운 주행 회랑(각 착륙 패드 -> 가장 가까운 얼음) 중심선까지 거리
local function corridorDistance(point: Vector3, padPositions: { Vector3 }): number
    local best = math.huge
    for index, pad in padPositions do
        local ice = ICE_POSITIONS[PAD_LAYOUT[index].ice]
        best = math.min(best, segmentDistance(point, pad, ice))
    end
    return best
end

-- 바위를 놓아도 되는 자리인지 (기지, 얼음, 맵 경계, 크레이터와 언덕을 피한다)
local function isClear(
    position: Vector3,
    padPositions: { Vector3 },
    footprints: { Footprint }
): boolean
    local flat = Vector3.new(position.X, 0, position.Z)
    for _, f in footprints do
        if (flat - Vector3.new(f.x, 0, f.z)).Magnitude < f.r + BOULDER_MAX then
            return false
        end
    end
    -- 주행 회랑 안 금지 (큰 바위 반지름까지 감안)
    if corridorDistance(flat, padPositions) < CORRIDOR_CLEARANCE + BOULDER_MAX then
        return false
    end
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
local function makeBoulder(
    rng: Random,
    position: Vector3,
    parent: Instance,
    rocks: RockSet,
    scale: number
)
    local s = rng:NextNumber(BOULDER_MIN, BOULDER_MAX)
    local size = Vector3.new(s, s * rng:NextNumber(0.5, 0.9), s * rng:NextNumber(0.7, 1.2)) * scale
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
        KitImports.scaleBy(rock, (ROCK_SCALE_MIN + t * (ROCK_SCALE_MAX - ROCK_SCALE_MIN)) * scale)
        KitImports.rotateAboutCenter(rock, rotation)
        local lo, hi = KitImports.bounds(rock)
        local height = hi.Y - lo.Y
        KitImports.placeBottom(
            rock,
            Vector3.new(position.X, SURFACE_Y - height * BOULDER_EMBED_RATIO, position.Z)
        )
        rock.Name = "Boulder"
        rock:SetAttribute("BoulderScale", scale)
        rock.Parent = parent
        return
    end
    local part = makePart({
        name = "Boulder",
        size = size,
        cframe = CFrame.new(
            position.X,
            SURFACE_Y + size.Y * (0.5 - BOULDER_EMBED_RATIO),
            position.Z
        ) * rotation,
        color = COLORS.boulder,
        material = Enum.Material.Basalt,
        parent = parent,
    })
    part:SetAttribute("BoulderScale", scale)
end

-- KitImports의 바위 메시를 기준 크기로 맞춘 원본 목록
local function prepareRocks(): RockSet
    local templates = KitImports.takeRocks()
    for _, rock in templates do
        KitImports.fitInto(rock, Vector3.one * ROCK_BASE_SIZE, Vector3.zero)
        KitImports.recolor(rock, COLORS.boulder, Enum.Material.Basalt)
        KitImports.forEachPart(rock, function(part)
            part.Anchored = true
            part.CanCollide = true
        end)
    end
    return { templates = templates, used = 0 }
end

local function buildBoulders(
    terrain: Instance,
    padPositions: { Vector3 },
    footprints: { Footprint }
)
    local rng = Random.new(Config.DEV_MAP.seed)
    local folder = makeFolder("Boulders", terrain)
    local rocks = prepareRocks()
    local function place(position: Vector3): boolean
        if not isClear(position, padPositions, footprints) then
            return false
        end
        local scale = if rng:NextNumber() < BIG_BOULDER_CHANCE then BIG_BOULDER_SCALE else 1
        makeBoulder(rng, position, folder, rocks, scale)
        return true
    end
    -- 주행 회랑 양옆 무더기 (회랑 안은 비운다). 얼음이 가까운 Pad4는 같은 구간에 더 많이 몰려 조밀하다
    for index, padPosition in padPositions do
        local ice = ICE_POSITIONS[PAD_LAYOUT[index].ice]
        local toIce = Vector3.new(ice.X - padPosition.X, 0, ice.Z - padPosition.Z)
        local dir = toIce.Unit
        local side = Vector3.new(-dir.Z, 0, dir.X)
        local reach =
            math.max(toIce.Magnitude + CLUSTER_BEYOND_ICE, KIT_CLEARANCE + CLUSTER_MIN_LENGTH)
        for _ = 1, Config.DEV_MAP.boulderCountBySite[index] do
            for _ = 1, BOULDER_ATTEMPTS do
                local along = rng:NextNumber(KIT_CLEARANCE, reach)
                local sign = if rng:NextNumber() < 0.5 then -1 else 1
                local lateral = CORRIDOR_CLEARANCE + BOULDER_MAX + rng:NextNumber(0, CLUSTER_SPREAD)
                if place(padPosition + dir * along + side * sign * lateral) then
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
            if place(position) then
                break
            end
        end
    end
end

-- 달 지형 계획 -----------------------------------------------------------
type Ball = { center: Vector3, radius: number, air: boolean }
type TerrainPlan = { balls: { Ball }, footprints: { Footprint } }

-- 공이 지표면(GROUND_TOP)과 만나는 원의 반지름 (안 만나면 0)
local function surfaceRadius(ball: Ball): number
    local dy = ball.center.Y - TERRAIN_TOP
    if math.abs(dy) >= ball.radius then
        return 0
    end
    return math.sqrt(ball.radius * ball.radius - dy * dy)
end

-- 공이 바꾸는 지표면 원이 보호 구역(패드, 얼음)과 맵 경계를 침범하지 않는지
local function ballAllowed(ball: Ball, padPositions: { Vector3 }): boolean
    local r = surfaceRadius(ball)
    local flat = Vector3.new(ball.center.X, 0, ball.center.Z)
    for _, pad in padPositions do
        if (flat - Vector3.new(pad.X, 0, pad.Z)).Magnitude < PAD_TERRAIN_CLEARANCE + r then
            return false
        end
    end
    for _, ice in ICE_POSITIONS do
        if (flat - Vector3.new(ice.X, 0, ice.Z)).Magnitude < ICE_TERRAIN_CLEARANCE + r then
            return false
        end
    end
    if corridorDistance(flat, padPositions) < CORRIDOR_CLEARANCE + r then
        return false
    end
    return math.abs(flat.X) + r < GROUND_SIZE.X / 2 - TERRAIN_EDGE_MARGIN
        and math.abs(flat.Z) + r < GROUND_SIZE.Z / 2 - TERRAIN_EDGE_MARGIN
end

-- 얕은 사발 크레이터: 가장자리를 따라 둔덕 공을 두르고, 표면 위에 중심을 둔 Air 공으로 판다
-- (중심을 표면 아래에 두면 너비보다 깊은 구멍이 되고, 큰 공 하나로 테두리를 만들면 돔 껍질이 남는다)
local function planCrater(cx: number, cz: number, radius: number): ({ Ball }, number)
    local depth = radius * CRATER_DEPTH_RATIO
    local edge = math.sqrt(radius * radius - (radius - depth) ^ 2)
    local rimHeight = math.min(radius * CRATER_RIM_HEIGHT_RATIO, CRATER_RIM_HEIGHT_MAX)
    local pieceRadius = math.max(CRATER_RIM_PIECE_MIN, radius * CRATER_RIM_PIECE_RATIO)
    local balls: { Ball } = {}
    for i = 1, CRATER_RIM_PIECES do
        local angle = 2 * math.pi * i / CRATER_RIM_PIECES
        table.insert(balls, {
            center = Vector3.new(
                cx + math.cos(angle) * edge,
                TERRAIN_TOP + rimHeight - pieceRadius,
                cz + math.sin(angle) * edge
            ),
            radius = pieceRadius,
            air = false,
        })
    end
    table.insert(balls, {
        center = Vector3.new(cx, TERRAIN_TOP + radius - depth, cz),
        radius = radius,
        air = true,
    })
    local rimFootprint = math.sqrt(pieceRadius * pieceRadius - (pieceRadius - rimHeight) ^ 2)
    return balls, edge + rimFootprint
end

-- 완만한 언덕: 중심을 표면 아래에 둔 큰 공이 height만큼 솟는다
local function planHill(cx: number, cz: number, radius: number, height: number): ({ Ball }, number)
    local ball: Ball = {
        center = Vector3.new(cx, TERRAIN_TOP + height - radius, cz),
        radius = radius,
        air = false,
    }
    return { ball }, surfaceRadius(ball)
end

-- 언덕과 크레이터 배치 (결정적). Terrain이 없어도 계산해서 바위 배치가 두 환경에서 같게 한다
local function planTerrain(padPositions: { Vector3 }): TerrainPlan
    local rng = Random.new(Config.DEV_MAP.seed + TERRAIN_SEED_OFFSET)
    local plan: TerrainPlan = { balls = {}, footprints = {} }
    local halfX, halfZ = GROUND_SIZE.X / 2, GROUND_SIZE.Z / 2
    local function tryAdd(balls: { Ball }, footprint: number, cx: number, cz: number): boolean
        for _, ball in balls do
            if not ballAllowed(ball, padPositions) then
                return false
            end
        end
        for _, ball in balls do
            table.insert(plan.balls, ball)
        end
        table.insert(plan.footprints, { x = cx, z = cz, r = footprint })
        return true
    end
    for _ = 1, HILL_COUNT do
        for _ = 1, FEATURE_ATTEMPTS do
            local cx, cz = rng:NextNumber(-halfX, halfX), rng:NextNumber(-halfZ, halfZ)
            local balls, footprint = planHill(
                cx,
                cz,
                rng:NextNumber(HILL_RADIUS_MIN, HILL_RADIUS_MAX),
                rng:NextNumber(HILL_HEIGHT_MIN, HILL_HEIGHT_MAX)
            )
            if tryAdd(balls, footprint, cx, cz) then
                break
            end
        end
    end
    -- 착륙지 주변 (지형 위험이 높은 곳일수록 많이)
    for index, pad in padPositions do
        for _ = 1, CRATERS_NEAR_SITE[index] or 0 do
            for _ = 1, FEATURE_ATTEMPTS do
                local angle = rng:NextNumber(0, 2 * math.pi)
                local distance = rng:NextNumber(PAD_TERRAIN_CLEARANCE, CRATER_NEAR_RING)
                local cx = pad.X + math.cos(angle) * distance
                local cz = pad.Z + math.sin(angle) * distance
                local balls, footprint =
                    planCrater(cx, cz, rng:NextNumber(CRATER_RADIUS_MIN, CRATER_RADIUS_MAX))
                if tryAdd(balls, footprint, cx, cz) then
                    break
                end
            end
        end
    end
    -- 맵 전체
    for _ = 1, CRATERS_SCATTERED do
        for _ = 1, FEATURE_ATTEMPTS do
            local cx, cz = rng:NextNumber(-halfX, halfX), rng:NextNumber(-halfZ, halfZ)
            local balls, footprint =
                planCrater(cx, cz, rng:NextNumber(CRATER_RADIUS_MIN, CRATER_RADIUS_MAX))
            if tryAdd(balls, footprint, cx, cz) then
                break
            end
        end
    end
    return plan
end

-- 지형 적용: Terrain이 있으면 표토를 채우고 언덕과 크레이터를 만든다. 없으면 평평한 지면 Part
local function applyTerrain(plan: TerrainPlan, folder: Instance)
    local terrain = if TERRAIN_ENABLED then workspace:FindFirstChildOfClass("Terrain") else nil
    if not terrain then
        makePart({
            name = "MoonGround",
            size = GROUND_SIZE,
            cframe = CFrame.new(0, SURFACE_Y - GROUND_SIZE.Y / 2, 0),
            color = COLORS.regolith,
            material = Enum.Material.Sand,
            parent = folder,
        })
        return
    end
    local material = Enum.Material.Sand
    terrain:FillBlock(
        CFrame.new(0, TERRAIN_TOP - TERRAIN_THICKNESS / 2, 0),
        Vector3.new(GROUND_SIZE.X, TERRAIN_THICKNESS, GROUND_SIZE.Z),
        material
    )
    terrain:SetMaterialColor(material, COLORS.regolith)
    for _, ball in plan.balls do
        terrain:FillBall(ball.center, ball.radius, if ball.air then Enum.Material.Air else material)
    end
    -- 기본 Baseplate가 있으면 크레이터 바닥을 평평하게 가리므로 플레이 중에만 숨긴다
    local baseplate = workspace:FindFirstChild("Baseplate")
    if baseplate and baseplate:IsA("BasePart") then
        baseplate.Transparency = 1
        baseplate.CanCollide = false
        baseplate.CanQuery = false
        for _, child in baseplate:GetChildren() do
            if child:IsA("Decal") or child:IsA("Texture") then
                child.Transparency = 1
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
    local padPositions: { Vector3 } = {}
    for index in Config.SITES do
        table.insert(padPositions, sitePadPosition(index))
    end
    local plan: TerrainPlan = if TERRAIN_ENABLED
        then planTerrain(padPositions)
        else { balls = {}, footprints = {} }
    applyTerrain(plan, terrain)
    greyboxTerrainBuilt = TERRAIN_ENABLED

    local iceFolder = makeFolder("IceSites", workspace)
    for index, position in ICE_POSITIONS do
        local ice = makePart({
            name = "Ice" .. index,
            size = ICE_SIZE,
            cframe = CFrame.new(position.X, SURFACE_Y + ICE_SIZE.Y / 2, position.Z),
            color = COLORS.ice,
            material = Enum.Material.Ice,
            parent = iceFolder,
        })
        ServerUtil.safeCall("DevMap IceCrystal", dressIce, ice)
    end

    local padsFolder = makeFolder("LandingPads", workspace)
    for index, site in Config.SITES do
        local position = padPositions[index]
        local ice = ICE_POSITIONS[PAD_LAYOUT[index].ice]
        -- 윗면은 GROUND_TOP + 0.5로 고정하고, 자연 지면(SURFACE_Y)까지 아래로 늘려 묻는다
        local padTop = GROUND_TOP + LANDING_PAD_SIZE.Y / 2
        local padHeight = padTop - SURFACE_Y + LANDING_PAD_SIZE.Y / 2
        local center = Vector3.new(position.X, padTop - padHeight / 2, position.Z)
        -- 패드의 앞쪽(-Z, LookVector)이 얼음을 향하게 해서 복제된 기지의 로버가 얼음 쪽을 보게 한다
        local pad = makePart({
            name = "Pad" .. index,
            size = Vector3.new(LANDING_PAD_SIZE.X, padHeight, LANDING_PAD_SIZE.Z),
            cframe = CFrame.lookAt(center, Vector3.new(ice.X, center.Y, ice.Z)),
            color = COLORS.landingPad,
            material = Enum.Material.Concrete,
            parent = padsFolder,
        })
        pad:SetAttribute("SiteName", site.name)
        pad:SetAttribute("Sunlight", site.sunlight)
        pad:SetAttribute("IceDistanceLabel", site.iceDistanceLabel)
        pad:SetAttribute("HazardLabel", site.hazardLabel)
        pad:SetAttribute("Description", site.description)
    end

    verifyDistances(padPositions)
    buildBoulders(terrain, padPositions, plan.footprints)
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

    -- 외형 메시 (KitImports.Rover)를 먼저 앞뒤 길이 기준으로 스케일해서 바퀴 간격을 메시 폭에 맞춘다
    local visual, yawSet = KitImports.take("Rover")
    local wheelOffsetX = WHEEL_OFFSET_X
    local chassisSize = CHASSIS_SIZE
    if visual then
        if not yawSet then
            KitImports.alignLongAxis(visual, "Z")
        end
        KitImports.fitLength(
            visual,
            ROVER_VISUAL_LENGTH,
            Vector3.new(chassisCFrame.X, FLOOR_Y + WHEEL_CLEARANCE, chassisCFrame.Z)
        )
        local lo, hi = KitImports.bounds(visual)
        wheelOffsetX = math.max((hi.X - lo.X) / 2 - WHEEL_WIDTH / 2, ROVER_MIN_WHEEL_OFFSET_X)
        -- 섀시는 두 바퀴 사이에 들어가는 폭으로 (기본 폭보다 넓히지는 않는다)
        local innerWidth = 2 * (wheelOffsetX - WHEEL_WIDTH / 2 - WHEEL_CHASSIS_GAP)
        chassisSize =
            Vector3.new(math.min(CHASSIS_SIZE.X, innerWidth), CHASSIS_SIZE.Y, CHASSIS_SIZE.Z)
    end

    local chassis = makePart({
        name = "Chassis",
        size = chassisSize,
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
        local localPosition = Vector3.new(sx * wheelOffsetX, wheelY - chassisY, sz * WHEEL_OFFSET_Z)
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

    -- 메시를 섀시에 용접한다 (물리 리그는 그대로)
    local seatCFrame = chassisCFrame
        * CFrame.new(0, CHASSIS_SIZE.Y / 2 + ROVER_SEAT_SIZE.Y / 2, 1.5)
    if visual then
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
        -- 좌석은 캐빈 안 (앞쪽 = -Z). 메시는 CanCollide가 꺼져 있어 캐릭터가 메시와 겹쳐 앉아도 된다.
        -- 걸어서 닿기 어려우므로 탑승은 RoverDrive의 "탑승" 프롬프트가 맡는다
        local lo, hi = KitImports.bounds(visual)
        local seatHeight = math.min((hi.Y - lo.Y) * ROVER_SEAT_HEIGHT_RATIO, ROVER_SEAT_MAX_HEIGHT)
        local seatFromFront = (hi.Z - lo.Z) * ROVER_SEAT_FROM_FRONT_RATIO
        seatCFrame = CFrame.new(chassisCFrame.X, lo.Y + seatHeight, lo.Z + seatFromFront)
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
    if visual then
        seat.Transparency = 1 -- 캐빈 안에 숨긴다 (메시가 외형)
    end
    seat.Parent = rover
    weld(chassis, seat)
end

-- 기지 키트 -------------------------------------------------------------

-- 걸어 들어가는 건물 (착륙선, Habitat A) ---------------------------------------
-- 건물 외형(메시 또는 오두막)은 충돌을 끄고, 경계 상자 lo, hi 둘레에 보이지 않는 충돌 벽을 세운다.
-- 정면(-Z) 가운데는 문 폭만큼 비워 문으로만 드나든다. shape "octagon"은 돔을 8각형으로, "box"는 4면.
-- 정면에는 어두운 문 판과 밝은 프레임(열린 통로라 충돌 없음), 그 위에 "AIRLOCK" 표지, 안에는 따뜻한 빛.
-- 반환: 산소 구역 최소점, 최대점 (경계 상자를 각 면 zoneInset씩 줄이고 문 앞 zoneDoorMargin 포함), 문 z
local function buildEntry(
    parent: Instance,
    lo: Vector3,
    hi: Vector3,
    floorY: number,
    shape: "octagon" | "box"
): (Vector3, Vector3, number)
    local a = Config.AIRLOCK
    local entry = makeModel("Entry", parent)
    local cx, cz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
    local doorZ = lo.Z + a.doorInset

    local function wall(name: string, length: number, center: Vector3, outward: Vector3)
        local position = Vector3.new(center.X, floorY + a.wallHeight / 2, center.Z)
        local part = makePart({
            name = name,
            size = Vector3.new(length, a.wallHeight, a.wallThickness),
            cframe = CFrame.lookAt(position, position + outward),
            color = COLORS.door,
            transparency = 1,
            canCollide = true,
            parent = entry,
        })
        part.CanQuery = false
        part.CanTouch = false
        part.CastShadow = false
    end
    -- 정면 벽: 가운데 문 폭을 비우고 양쪽 조각만
    local function frontWall(length: number, center: Vector3, tangent: Vector3, outward: Vector3)
        local piece = (length - a.doorGap) / 2
        if piece <= 0 then
            return
        end
        for _, side in { -1, 1 } do
            wall(
                if side < 0 then "WallFrontLeft" else "WallFrontRight",
                piece,
                center + tangent * side * (a.doorGap / 2 + piece / 2),
                outward
            )
        end
    end

    local t = a.wallThickness
    if shape == "octagon" then
        local radius = math.max(hi.X - lo.X, hi.Z - lo.Z) / 2
        local apothem = radius + t / 2
        local side = 2 * apothem * math.tan(math.pi / 8) + t -- 모서리가 벌어지지 않게 조금 겹친다
        for k = 0, 7 do
            local phi = k * math.pi / 4
            local outward = Vector3.new(math.sin(phi), 0, -math.cos(phi)) -- k = 0이 정면(-Z)
            local tangent = Vector3.new(math.cos(phi), 0, math.sin(phi))
            local center = Vector3.new(cx, 0, cz) + outward * apothem
            if k == 0 then
                frontWall(side, center, tangent, outward)
            else
                wall("Wall" .. k, side, center, outward)
            end
        end
    else
        local halfX, halfZ = (hi.X - lo.X) / 2, (hi.Z - lo.Z) / 2
        frontWall(
            2 * (halfX + t),
            Vector3.new(cx, 0, lo.Z - t / 2),
            Vector3.xAxis,
            Vector3.new(0, 0, -1)
        )
        wall("WallBack", 2 * (halfX + t), Vector3.new(cx, 0, hi.Z + t / 2), Vector3.zAxis)
        wall("WallLeft", 2 * halfZ, Vector3.new(lo.X - t / 2, 0, cz), Vector3.new(-1, 0, 0))
        wall("WallRight", 2 * halfZ, Vector3.new(hi.X + t / 2, 0, cz), Vector3.xAxis)
    end

    -- 문: 어두운 판 뒤로 조금 더 큰 밝은 프레임을 겹친다
    local doorY = floorY + a.doorHeight / 2
    local frame = makePart({
        name = "DoorFrame",
        size = Vector3.new(
            a.doorWidth + 2 * a.frameBorder,
            a.doorHeight + a.frameBorder,
            a.doorThickness / 2
        ),
        cframe = CFrame.new(
            cx,
            floorY + (a.doorHeight + a.frameBorder) / 2,
            doorZ + a.doorThickness / 2
        ),
        color = COLORS.doorFrame,
        material = Enum.Material.Metal,
        canCollide = false,
        parent = entry,
    })
    frame.CanQuery = false
    local door = makePart({
        name = "Door",
        size = Vector3.new(a.doorWidth, a.doorHeight, a.doorThickness),
        cframe = CFrame.new(cx, doorY, doorZ),
        color = COLORS.door,
        material = Enum.Material.Metal,
        canCollide = false,
        parent = entry,
    })
    door.CanQuery = false
    -- 문 위 작은 표지
    local sign = makePart({
        name = "DoorSign",
        size = Vector3.new(a.doorWidth, a.signHeight, a.doorThickness / 2),
        cframe = CFrame.new(
            cx,
            floorY + a.doorHeight + a.frameBorder + a.signHeight / 2,
            doorZ - a.doorThickness / 4
        ),
        color = COLORS.door,
        material = Enum.Material.SmoothPlastic,
        canCollide = false,
        parent = entry,
    })
    sign.CanQuery = false
    local gui = Instance.new("SurfaceGui")
    gui.Name = "SignGui"
    gui.Face = Enum.NormalId.Front
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = 40
    gui.Parent = sign
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextColor3 = COLORS.doorFrame
    label.TextScaled = true
    label.Font = Enum.Font.GothamMedium
    label.Text = a.signText
    label.Parent = gui

    -- 내부의 따뜻한 빛
    local glow = Instance.new("Attachment")
    glow.Name = "InteriorLight"
    glow.CFrame = CFrame.new(cx, floorY + (hi.Y - floorY) * 0.6, cz)
    local light = Instance.new("PointLight")
    light.Color = COLORS.interiorLight
    light.Range = a.lightRange
    light.Brightness = a.lightBrightness
    light.Parent = glow
    -- Attachment는 파트 아래에만 둘 수 있어 문 표지 파트에 붙이고 위치는 월드 기준으로 맞춘다
    glow.CFrame = sign.CFrame:ToObjectSpace(glow.CFrame)
    glow.Parent = sign

    local zoneMin = Vector3.new(lo.X + a.zoneInset, floorY, doorZ - a.zoneDoorMargin)
    local zoneMax = Vector3.new(
        hi.X - a.zoneInset,
        math.max(hi.Y - a.zoneInset, floorY + a.doorHeight),
        hi.Z - a.zoneInset
    )
    return zoneMin, zoneMax, doorZ
end

-- 건물 외형을 걸어 들어갈 수 있게: 충돌 끄기, 메시는 양면 렌더링
local doubleSidedWarned = false
local function makeWalkIn(model: Instance, keepFloor: boolean)
    KitImports.forEachPart(model, function(part)
        if keepFloor and part.Name == "Floor" then
            return
        end
        part.CanCollide = false
        if part:IsA("MeshPart") then
            -- 스크립트에서 쓰기가 막혀 있는 환경도 있어 실패하면 한 번만 알린다
            local ok = pcall(function()
                (part :: MeshPart).DoubleSided = true
            end)
            if not ok and not doubleSidedWarned then
                doubleSidedWarned = true
                warn(
                    "[DevMap] MeshPart.DoubleSided를 스크립트에서 바꿀 수 없어 안쪽 면이 안 보일 수 있습니다"
                )
            end
        end
    end)
end

local function buildLander(kit: Model)
    local lander = makeModel("Lander", kit)
    local lo: Vector3
    local hi: Vector3
    local floorTop: number
    local shape: "octagon" | "box"
    local visual = KitImports.take("Lander")
    if visual then
        -- 착륙 데크(Floor, PrimaryPart) 위에 메시를 올리고 안으로 걸어 들어갈 수 있게 한다
        floorTop = buildFloor(lander, LANDER_CENTER, LANDER_SIZE)
        KitImports.fitInto(
            visual,
            LANDER_VISUAL_BOX,
            Vector3.new(LANDER_CENTER.X, floorTop, LANDER_CENTER.Z)
        )
        visual.Name = "Visual"
        KitImports.forEachPart(visual, function(part)
            part.Anchored = true
        end)
        makeWalkIn(visual, false)
        visual.Parent = lander
        lo, hi = KitImports.bounds(visual)
        shape = "octagon"
    else
        floorTop = buildHut(lander, LANDER_CENTER, LANDER_SIZE, COLORS.lander, Enum.Material.Metal)
        lo, hi = KitImports.bounds(lander)
        makeWalkIn(lander, true)
        shape = "box"
    end
    lander.PrimaryPart = lander:FindFirstChild("Floor") :: BasePart
    local cx, cz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2

    -- 문, 충돌 벽, 내부 산소 구역. 스폰은 문에서 spawnInset 안쪽 (스폰하면 실내)
    local zoneMin, zoneMax, doorZ = buildEntry(lander, lo, hi, floorTop, shape)
    makeMarker("OxygenZone", zoneMax - zoneMin, CFrame.new((zoneMin + zoneMax) / 2), lander)
    local spawnPoint = makePart({
        name = "SpawnPoint",
        size = Vector3.new(4, 0.2, 4),
        cframe = CFrame.new(cx, floorTop + 0.1, doorZ + Config.AIRLOCK.spawnInset),
        color = COLORS.spawn,
        material = Enum.Material.Neon,
        transparency = 0.6,
        canCollide = false,
        parent = lander,
    })
    spawnPoint.CanTouch = false

    -- 로버 복구 콘솔: 오른쪽(+X) 충돌 벽 바깥, 앞쪽 (RoverRecovery가 프롬프트를 붙인다)
    local wallOut = Config.AIRLOCK.wallThickness
    local consolePosition = Vector3.new(
        hi.X + wallOut + ROVER_CONSOLE_SIDE_GAP + ROVER_CONSOLE_SIZE.X / 2,
        0,
        lo.Z + ROVER_CONSOLE_FROM_FRONT
    )
    local consoleCFrame, consoleTotal =
        slabCFrame(CFrame.identity, consolePosition, ROVER_CONSOLE_SIZE.Y)
    makePart({
        name = "RoverConsole",
        size = Vector3.new(ROVER_CONSOLE_SIZE.X, consoleTotal, ROVER_CONSOLE_SIZE.Z),
        cframe = consoleCFrame,
        color = COLORS.console,
        material = Enum.Material.Metal,
        parent = lander,
    })

    -- KitImports 장식: 꼭대기 안테나, 왼쪽(-X) 바닥 지상 레이더, 콘솔 위 안테나 (충돌 없음)
    ServerUtil.safeCall("DevMap LanderDecor", function()
        placeDecor("Antenna", MAST_BOX, Vector3.new(cx, hi.Y, cz), false, lander, "RoofAntenna")
        placeDecor(
            "Radar",
            RADAR_BOX,
            Vector3.new(lo.X - wallOut - RADAR_SIDE_GAP - RADAR_BOX.X / 2, FLOOR_Y, cz),
            false,
            lander,
            "GroundRadar"
        )
        local consoleTop =
            Vector3.new(consolePosition.X, FLOOR_Y + ROVER_CONSOLE_SIZE.Y, consolePosition.Z)
        placeDecor("Antenna", CONSOLE_MAST_BOX, consoleTop, false, lander, "ConsoleAntenna")
    end)
    return consolePosition
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
        padModel:SetAttribute("ModuleId", id) -- 클라이언트 패드 표지판이 찾는 키
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
                -- 걸어 들어가는 건물: 정면(-Z, A-B 통로 반대편) 문, 4면 충돌 벽, 내부 산소 구역.
                -- 문, 벽, 빛은 Built 안이라 완공 때 함께 나타나고, 구역은 PadA 아래(가동 중일 때만 유효)
                local lo, hi = KitImports.bounds(visual)
                makeWalkIn(visual, false)
                local zoneMin, zoneMax = buildEntry(visual, lo, hi, top, "box")
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
            -- Habitat A: 오두막 + 문, 충돌 벽, 내부 산소 구역 (메시 경로와 같은 판정)
            local hutFloor = buildHut(
                built,
                layout.center,
                layout.body,
                COLORS.habitat,
                Enum.Material.SmoothPlastic
            )
            local lo, hi = KitImports.bounds(built)
            makeWalkIn(built, true)
            local zoneMin, zoneMax = buildEntry(built, lo, hi, hutFloor, "box")
            makeMarker(
                "OxygenZone",
                zoneMax - zoneMin,
                CFrame.new((zoneMin + zoneMax) / 2),
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
local function addCrates(kit: Model, consolePosition: Vector3)
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
                        consolePosition.X + column * CRATE_PITCH,
                        FLOOR_Y,
                        consolePosition.Z + CRATE_BEHIND_CONSOLE + row * CRATE_PITCH
                    )
                )
                KitImports.setStatic(crate, true)
                crate.Name = "Crate"
                crate.Parent = crates
            end
        end
    end
end

-- 지형을 켠 그레이박스 맵에서만: 키트 바닥 전체를 덮는 콘크리트 판(윗면 = 착륙 패드 윗면 - 0.5 = 월드 GROUND_TOP)
-- 판은 x 방향으로 대칭이라 정면 경사로가 로버 차선(x = 0)에 온다. 가장자리 4면 중앙에 지형으로 내려가는 경사로
local function buildApron(kit: Model)
    local lo, hi = KitImports.bounds(kit)
    local halfX = math.max(math.abs(lo.X), math.abs(hi.X)) + APRON_MARGIN
    local minZ, maxZ = lo.Z - APRON_MARGIN, hi.Z + APRON_MARGIN
    local top = FLOOR_Y - LANDING_PAD_SIZE.Y / 2
    local midZ = (minZ + maxZ) / 2
    makePart({
        name = "Apron",
        size = Vector3.new(2 * halfX, APRON_THICKNESS, maxZ - minZ),
        cframe = CFrame.new(0, top - APRON_THICKNESS / 2, midZ),
        color = COLORS.apron,
        material = Enum.Material.Concrete,
        parent = kit,
    })
    local drop = GROUND_TOP - TERRAIN_TOP
    local ramps = makeModel("Ramps", kit)
    local edges = {
        { name = "RampFront", point = Vector3.new(0, 0, minZ), outward = Vector3.new(0, 0, -1) },
        { name = "RampBack", point = Vector3.new(0, 0, maxZ), outward = Vector3.zAxis },
        {
            name = "RampLeft",
            point = Vector3.new(-halfX, 0, midZ),
            outward = Vector3.new(-1, 0, 0),
        },
        { name = "RampRight", point = Vector3.new(halfX, 0, midZ), outward = Vector3.xAxis },
    }
    for _, edge in edges do
        -- WedgePart는 뒤(+Z)가 높고 앞(-Z, LookVector)으로 낮아진다: 앞을 바깥으로 향하게
        local center = edge.point
            + edge.outward * (RAMP_LENGTH / 2)
            + Vector3.new(0, top - drop / 2, 0)
        local ramp = Instance.new("WedgePart")
        ramp.Name = edge.name
        ramp.Size = Vector3.new(RAMP_WIDTH, drop, RAMP_LENGTH)
        ramp.CFrame = CFrame.lookAt(center, center + edge.outward)
        ramp.Color = COLORS.apron
        ramp.Material = Enum.Material.Concrete
        ramp.Anchored = true
        ramp.TopSurface = Enum.SurfaceType.Smooth
        ramp.BottomSurface = Enum.SurfaceType.Smooth
        ramp.Parent = ramps
    end
end

local function buildBaseKit()
    local kit = makeModel("BaseKit", nil)
    local origin = makeMarker("Origin", ORIGIN_SIZE, CFrame.identity, kit)
    kit.PrimaryPart = origin
    local consolePosition = buildLander(kit)
    buildRover(kit)
    buildSolarField(kit)
    buildModulePads(kit)
    buildWaterTank(kit)
    ServerUtil.safeCall("DevMap Crates", addCrates, kit, consolePosition)
    if greyboxTerrainBuilt then
        buildApron(kit)
    end
    kit.Parent = ServerStorage
end

local function buildPanelTemplate()
    local visual, yawSet = KitImports.take("Panel")
    if visual then
        -- 외형 메시: 슬롯 바닥을 꽉 채우게 균일 스케일 (긴 변을 슬롯의 긴 변 X에 맞추고 높이는 비율대로)
        if not yawSet then
            KitImports.alignLongAxis(visual, "X")
        end
        local footprint =
            Vector3.new(SLOT_SIZE.X * PANEL_FILL, PANEL_MAX_HEIGHT, SLOT_SIZE.Z * PANEL_FILL)
        KitImports.fitInto(visual, footprint, Vector3.zero)
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
    -- 그레이박스 패널도 같은 규칙: 틀이 슬롯 x, z의 PANEL_FILL을 채운다
    local template = makeModel("PanelTemplate", nil)
    local frameX, frameZ = SLOT_SIZE.X * PANEL_FILL, SLOT_SIZE.Z * PANEL_FILL
    local panel = makePart({
        name = "Panel",
        size = Vector3.new(
            frameX - 2 * PANEL_GLASS_INSET,
            PANEL_GLASS_HEIGHT,
            frameZ - 2 * PANEL_GLASS_INSET
        ),
        cframe = CFrame.new(0, PANEL_FRAME_HEIGHT + PANEL_GLASS_HEIGHT / 2, 0),
        color = COLORS.panel,
        material = Enum.Material.Glass,
        parent = template,
    })
    panel.Reflectance = 0.2
    makePart({
        name = "Frame",
        size = Vector3.new(frameX, PANEL_FRAME_HEIGHT, frameZ),
        cframe = CFrame.new(0, PANEL_FRAME_HEIGHT / 2, 0),
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

    -- 하늘과 행성 (맵 종류와 관계없이). 행성은 기본 착륙지에서 가장 가까운 얼음 쪽에 두고,
    -- 착륙지가 정해지면 GameFlow가 그 기지 기준으로 다시 조준한다
    local skyNote, atmosphereNote = setupSky()
    local planetNote = "만들지 못함"
    local planetCenter: Vector3? = nil
    ServerUtil.safeCall("KitImports Planet", function()
        planetNote = KitImports.ensurePlanet()
        local pads = workspace:FindFirstChild("LandingPads")
        local pad = pads and pads:FindFirstChild("Pad" .. Config.DEFAULT_SITE_ID)
        local origin = if pad and pad:IsA("BasePart") then pad.CFrame.Position else Vector3.zero
        planetCenter = KitImports.aimPlanetFrom(origin)
    end)
    local center = planetCenter
    print(
        string.format(
            "[DevMap] 하늘: %s, %s, ClockTime %.1f, 행성 위치 %s, 행성 %s",
            skyNote,
            atmosphereNote,
            SKY.clockTime,
            if center
                then string.format("(%.0f, %.0f, %.0f)", center.X, center.Y, center.Z)
                else "없음",
            planetNote
        )
    )
end

return DevMap
