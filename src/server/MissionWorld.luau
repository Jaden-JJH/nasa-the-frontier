--!strict
-- MissionWorld: v2 월드 배치 계층 (docs/CONTRACT_V2.md 1절, 2.2절 MissionWorld, V2_PLAN 15.4, 15.6, 15.11)
--
-- 하는 일
--   init(missionId): Workspace.Mission<Id> 표시를 읽고 필수 이름을 검사한다. Workspace.MissionRuntime을 만들고,
--     편집용 Workspace.AssetPreview는 실행 중에만 떼어 둔다(Parent = nil, 참조 유지). 표시 Part는 실행 중에만
--     고정하고 숨긴다(Studio 편집 화면에는 영향 없음). Terrain, Lighting, Sky는 절대 건드리지 않는다.
--   resolveAsset(role): ServerStorage.Assets.<역할> -> Assets.Kit 조합 -> 코드 도형 + 이름표(TextKey) 3단계 대체(Q27)
--   placeBase(): 착륙선과 에어록(걸어 들어가는 대피처: 문, 보이지 않는 벽, 산소 구역), 태양광 슬롯,
--     물탱크, 로버 주차판, 기지 출구, 얼음 지점, 재배 공간 착공 자리. 모두 표시 자리의 지형 높이에 맞춘다.
--   시설 손잡이: place, setBuildProgress(땅에서 솟아오름), setActive, setPaused, syncFacilities.
--     그린하우스 안 Grow_LED_Bar는 LED가 가동 중일 때만, Hydroponic_Bed는 수경 재배가 가동 중일 때만 보인다.
--   iceSites(): 얼음 표시를 번호가 아니라 실제 수평 거리로 정렬한 목록(Q37). 외형은 낮게 묻힌 표토 덩어리,
--     이름표와 반짝임은 가까이(CFG.ice.revealDistance)서만 보인다
--   갇힘 방지: 시설과 태양광 패널은 건설(솟아오름) 중 충돌이 없고, 충돌이 켜지는 순간 안에 있던 플레이어를
--     정면 바깥 지면으로 옮긴다(CFG.eject). 설치한 패널은 로버를 막고 RoverHazard 태그가 붙는다
--   reset(): 재시작. MissionRuntime을 비우고 기지를 다시 놓는다.
--
-- 서버는 화면 문장을 쓰지 않는다(CONTRACT 0절 2). 3D 글자(문 표지, 제어반, 대체 도형 이름표)는 TextLabel에
-- Attribute "TextKey"만 달고 Text는 비워 둔다. 클라이언트 Localizer.bindTextKeys가 언어에 맞게 채운다. AutoLocalize = false.
-- 숫자(크기, 간격, 색)는 아래 CFG에 모았다. 리드가 나중에 MissionConfig로 옮긴다.
-- 산소 구역 파트에는 태그 "OxygenZone"과 Attribute ZoneKind("shelter" | "refill"), ZoneId를 단다(Oxygen v2가 읽는다).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local WorldMath = require(ReplicatedStorage.Shared.WorldMath)

-- 설정 ------------------------------------------------------------------
-- 단위: studs, 초, 도. 색은 RGB 0..255
local CFG = {
    markerFolderPrefix = "Mission", -- Workspace.MissionC
    runtimeFolder = "MissionRuntime",
    previewFolder = "AssetPreview",
    assetsFolder = "Assets", -- ServerStorage.Assets (Rojo가 관리하지 않는다)
    kitFolder = "Kit",
    zoneTag = "OxygenZone",
    missions = {
        C = {
            required = {
                "Lander",
                "SpawnLocation",
                "Airlock",
                "SolarField",
                "FarmPad",
                "WaterTank",
                "RoverPark",
                "BaseExit",
            },
            iceExpected = 5,
            panelSlots = 20, -- MissionConfig.MISSIONS.C.panels.total이 있으면 그 값을 쓴다
        },
    } :: { [string]: { required: { string }, iceExpected: number, panelSlots: number } },
    icePattern = "^Ice(%d+)$",
    -- 얼음 정렬 기준 표시. 자율주행 출발점(Q8)이 기지 출구라 BaseExit. Rules.newState에는 iceDistances()를 넘겨 순서를 맞춘다
    iceSortFrom = "BaseExit",
    markerRuntime = {
        anchor = true, -- Studio 표시가 Anchored = false라 실행하면 떨어진다. 실행 중에만 고정
        hide = true, -- 실행 중에만 투명, 충돌 없음
        keepVisible = { SpawnLocation = true },
    },
    ground = {
        probeUp = 80, -- 표시 바닥 위 이 높이에서 아래로 광선
        probeDepth = 400,
        cornerRatio = 0.9, -- 바닥 넓이 모서리 샘플 위치 (반폭 비율)
        lift = 0.05, -- 기초 판 윗면 = 가장 높은 지면 + lift
        sink = 1, -- 기초 판 밑면 = 가장 낮은 지면 - sink
        smallSink = 0.3, -- 기초 판이 없는 작은 물체(얼음 결정, 기둥)를 묻는 깊이
    },
    yawStepDeg = 90, -- 문과 정면 방향을 표시 Part 축 기준 이 각도 배수로 맞춘다
    animation = {
        riseSeconds = 1, -- v1 BUILD_RISE_SECONDS
        hz = 30, -- v1 ANIMATION_HZ
        panelRiseSeconds = 1.2,
        panelSink = 2,
    },
    -- 걸어 들어가는 건물의 출입 구조 (v1 Config.AIRLOCK 값)
    entry = {
        doorWidth = 4.5,
        doorHeight = 5.5,
        doorThickness = 0.4,
        frameBorder = 0.3,
        doorInset = 0.5,
        signHeight = 0.7,
        signPixelsPerStud = 40,
        minWallHeight = 6,
        wallThickness = 0.5,
        doorGap = 5,
        zoneInset = 1,
        zoneDoorMargin = 1,
        lightRange = 18,
        lightBrightness = 1,
        insideHeight = 3, -- 대피 이동 지점 높이 (바닥 위)
    },
    shelters = {
        lander = {
            marker = "Lander",
            role = "Lander",
            model = "LanderShelter",
            faceToward = "SpawnLocation", -- 스폰에서 바로 문이 보이게
            zoneKind = "shelter", -- [Q28] 착륙선 안은 산소 유지
            minFootprint = 12,
            minHeight = 8,
            console = true,
            panel = false,
            signKey = "world.sign.lander",
        },
        airlock = {
            marker = "Airlock",
            role = "Airlock",
            model = "AirlockShelter",
            faceToward = "SpawnLocation",
            zoneKind = "shelter", -- 점검 전 유지, 가동하면 refill (airlockZoneKinds)
            minFootprint = 10,
            minHeight = 7,
            console = false,
            panel = true,
            signKey = "world.sign.airlock",
        },
    } :: { [string]: any },
    -- [Q28, Q33] 에어록 상태별 산소 구역 종류: 점검 전과 멈춤은 유지, 가동은 회복
    airlockZoneKinds = {
        idle = "shelter",
        inspecting = "shelter",
        active = "refill",
        paused = "shelter",
    } :: { [string]: string },
    console = { size = { 2, 3.2, 1.4 }, backGap = 1.2 },
    controlPanel = {
        size = { 1.6, 1.2, 0.25 },
        lightSize = { 1.6, 0.25, 0.3 },
        height = 3, -- 바닥 위 패널 중심 높이
        sideGap = 0.6, -- 문 틈 가장자리에서 패널까지
        wallGap = 0.15, -- 벽 바깥으로 띄우는 거리
        pixelsPerStud = 50,
        postWidth = 0.3, -- 패널 받침 기둥 굵기
    },
    solar = {
        marker = "SolarField",
        margin = 2,
        gap = 1,
        fill = 0.85, -- 패널 바닥이 슬롯 칸의 이 비율
        panelMaxHeight = 6,
        slotThickness = 0.2,
        installPadSize = { 6, 0.6, 6 },
        installPadGap = 2,
        orderFrom = "Lander", -- 이 표시에 가까운 슬롯부터 채운다
        hazardTag = "RoverHazard", -- RoverFleet.CONFIG.hazardTag와 같아야 한다 (설치한 패널에 붙인다)
    },
    -- 물탱크: 긴 축을 표시의 긴 변에 맞추고, 뒤 끝(+Z, 파이프가 붙는 쪽)이 얼음 쪽을 보게 놓는다.
    -- 디자이너 에셋(31 x 16.7 x 11.8)은 문과 경사로가 앞(-Z), 뒤쪽 설비가 뒤(+Z)다
    waterTank = {
        marker = "WaterTank",
        role = "WaterTank",
        assetFill = 1, -- 디자이너 에셋은 표시 크기 그대로
        fill = 0.8, -- 키트, 대체 도형
        longAxisRatio = 1.2, -- 에셋의 X가 Z보다 이 배 넘게 길면 90도 돌려 긴 축을 Z로
        padSize = { 5, 0.4, 5 }, -- 하역 자리, 파이프 착공 자리
        padGap = 2,
        dockSide = 10, -- 하역 자리 중심에서 자율주행 귀환 주차 자리까지 (문 쪽으로)
        dockSize = { 8, 0.3, 11 },
        pipeSpotSide = 6, -- 파이프 착공 자리: 뒤 끝 바깥, 탱크 축에서 착륙선 쪽 옆으로
    },
    roverPark = { marker = "RoverPark", faceToward = "BaseExit" },
    exit = { marker = "BaseExit", postSize = { 1, 6, 1 }, capSize = 1.4 },
    farm = {
        marker = "FarmPad",
        role = "Greenhouse",
        faceToward = "Lander",
        fill = 1,
        walkable = { "Floor", "Central_Walkway" }, -- 걸어 들어가는 건물에서 충돌을 남기는 파트 이름
        buildSpotSize = { 5, 0.4, 5 },
        buildSpotGap = 2,
        buildSpotSide = 9, -- 문 앞을 막지 않게 옆으로
        ledPrefixes = { "Grow_LED_Bar" },
        hydroPrefixes = { "Hydroponic_Bed" },
        cropPrefixes = { "Leafy_Crops", "Crop_Stems", "Crop" }, -- 재배 공간을 멈추면 어둡게
        -- 에셋에 LED 바와 수경 베드가 없을 때(키트, 대체 도형) 코드가 만드는 것
        generatedLed = { size = { 3.5, 0.25, 0.25 }, heightRatio = 0.7 },
        generatedBed = { size = { 4.3, 1, 4.9 } },
        generatedSpread = 0.25, -- 바닥 넓이 반폭 비율 (2 x 2 배치)
    },
    units = {
        led = { role = "LedUnit", side = "left" },
        nutrient = { role = "NutrientUnit", side = "right" },
        hydroponics = { role = "HydroUnit", side = "back" },
    } :: { [string]: { role: string, side: string } },
    unitSize = { 6, 5, 6 },
    unitGap = 2,
    -- 파이프: 디자이너 에셋은 탱크와 같은 단위라 같은 배율로 키우고, Tank_Connector_Ring이 탱크 뒤 끝 면에 닿게,
    -- Ground_Base 밑면이 지면에 오게 놓는다(엘보와 Buried_Sleeve가 땅속으로). 관로는 받침에서 얼음 지점까지 반쯤 묻힌다
    pipe = {
        role = "Pipe",
        wellheadRole = "PipeWellhead",
        ringPrefix = "Tank_Connector_Ring",
        basePrefix = "Ground_Base",
        stationSize = { 6, 5, 6 }, -- 키트, 대체 도형 파이프 크기 (같은 단위가 아닐 때)
        ringMargin = 0.3, -- 고리가 탱크 높이 범위 안에 남도록 위아래 여유
        lateralStep = 1, -- 둘째 파이프부터 옆으로 (파이프 폭 + 이 값)
        wellheadSize = { 4, 4, 4 },
        segmentLength = 24,
        radius = 0.7,
        lift = 0, -- 관 중심 높이 = 지면 (반쯤 묻힌 관로)
    },
    -- [2026-11-15 시험 피드백] 얼음은 영구 음영 크레이터의 어두운 표토에 섞여 있다(반짝이는 덩어리가 아니다).
    -- 낮고 대부분 묻힌 표토 색 덩어리 무리, 아주 약한 푸른 기만. 네온, 빛, 반짝이 효과 없음.
    -- 이름표와 작은 반짝임은 revealDistance(studs) 안에서만 보인다(BillboardGui.MaxDistance). 지도와 핀으로 찾게 한다
    ice = {
        role = "IceDeposit",
        fill = 0.45, -- 덩어리 무리가 차지하는 표시 바닥 넓이 비율
        maxHeight = 2.4, -- 덩어리 무리 전체 높이 상한 (묻기 전)
        buryRatio = 0.55, -- 그중 땅속에 묻는 비율 (보이는 높이 약 1)
        revealDistance = 40,
        glintSize = 0.5, -- 반짝임 점 크기 (studs)
        glintTransparency = 0.45,
        labelOffset = 3, -- MinePoint 중심 위 이름표 높이
        glintOffset = -1, -- MinePoint 중심 기준 반짝임 높이 (지면 근처)
    },
    -- 대체 도형 "deposit"의 덩어리 배치 (로컬, 바닥 중심 원점, 나중에 표시 크기에 맞춰 균일 배율)
    iceDeposit = {
        chunks = {
            { size = { 3.2, 1.6, 2.6 }, at = { 0, 0 }, yaw = 15, tilt = 8, tint = true },
            { size = { 2.4, 1.2, 2.0 }, at = { 2.8, 1.2 }, yaw = 60, tilt = -10, tint = false },
            { size = { 2.6, 1.4, 1.8 }, at = { -2.6, 0.8 }, yaw = -35, tilt = 12, tint = true },
            { size = { 1.8, 1.0, 1.6 }, at = { 1.2, -2.4 }, yaw = 80, tilt = 6, tint = false },
            { size = { 2.0, 1.1, 1.4 }, at = { -1.4, -2.2 }, yaw = 25, tilt = -8, tint = true },
            { size = { 1.4, 0.8, 1.2 }, at = { 3.4, -1.4 }, yaw = -50, tilt = 10, tint = false },
        },
    },
    -- [2026-11-15 시험 피드백] 완공(충돌이 켜지는) 순간 구조물 안에 있는 플레이어를 정면 바깥 지면으로 옮긴다
    eject = {
        margin = 1.5, -- 구조물 경계를 수평으로 이만큼 넓혀 검사
        headroom = 3, -- 구조물 윗면 위 이 높이까지 안으로 본다 (HumanoidRootPart는 발보다 약 3 높다)
        clearance = 4, -- 경계(넓히기 전) 바깥으로 이만큼 떨어진 자리
        panelClearance = 1.5, -- 태양광 패널은 가장 가까운 옆면으로 조금만
        spacing = 3, -- 여러 명이면 옆으로 이 간격
        rootHeight = 3, -- 지면 위 HumanoidRootPart 중심 높이 (R15 기본 HipHeight 2 + 반 높이 1)
    },
    -- 대체 도형 오두막(hut)은 걸어 들어가는 모양 그대로 충돌을 남긴다 (지붕과 벽이 카메라와 점프를 막는다).
    -- 키트, 에셋 외형은 충돌을 끄고 buildEntry의 보이지 않는 벽, 문 위 막이, 천장이 막는다
    hutSolid = {
        "Floor",
        "Central_Walkway",
        "WallBack",
        "WallLeft",
        "WallRight",
        "WallFrontLeft",
        "WallFrontRight",
        "Lintel",
        "Roof",
    },
    pausedUpgradeLook = "dim", -- 멈춘 LED, 수경: "dim"(보이되 꺼짐) | "hide"(숨김)
    dimFactor = 0.6, -- 멈춤 표시: 원래 색을 검정 쪽으로 이 비율만큼
    label = { width = 10, height = 2, offset = 1.5, maxDistance = 150 },
    colors = {
        door = { 60, 62, 68 },
        doorFrame = { 205, 208, 215 },
        interiorLight = { 255, 210, 160 },
        foundation = { 105, 105, 108 },
        slot = { 70, 72, 82 },
        pad = { 255, 205, 60 },
        parkPad = { 80, 82, 88 },
        post = { 58, 60, 64 },
        postCap = { 255, 205, 60 },
        panel = { 40, 42, 48 },
        console = { 255, 140, 60 },
        pipe = { 190, 192, 198 },
        ledGlow = { 255, 120, 220 },
        iceGlint = { 215, 232, 245 }, -- 얼음 후보지 가까이에서만 보이는 작은 반짝임
        bed = { 235, 236, 240 },
        labelText = { 255, 255, 255 },
        status = {
            idle = { 120, 120, 125 },
            inspecting = { 255, 200, 60 },
            building = { 255, 200, 60 },
            active = { 90, 220, 110 },
            paused = { 255, 140, 40 },
        } :: { [string]: { number } },
    },
}

-- 역할별 에셋 대체 규칙 ------------------------------------------------------
-- kit: Assets.Kit 조합. main은 본체, extras는 덧붙이는 조각
--   layout "top"(본체 위), "ring"(본체 둘레 count개), "endX"(본체 +X 끝). scale은 본체 수평 최대 길이 대비
-- shape: 대체 도형 "box" | "hut"(걸어 들어가는 오두막, 정면 -Z 가운데 비움) | "cylinder" | "panel"
--   | "deposit"(표토에 섞인 얼음: 낮은 덩어리 무리, CFG.iceDeposit. tint는 얼음이 섞인 덩어리 색)
-- textKey: 대체 도형 이름표 문구 키 (nil이면 이름표 없음)
type KitExtra = { name: string, layout: string, scale: number, count: number? }
type RoleSpec = {
    kit: { main: string, extras: { KitExtra }? }?,
    shape: string,
    size: { number },
    color: { number },
    tint: { number }?,
    textKey: string?,
}

local ROLES: { [string]: RoleSpec } = {
    Greenhouse = {
        kit = {
            main = "HabitatB",
            extras = { { name = "Crop", layout = "ring", scale = 0.18, count = 6 } },
        },
        shape = "hut",
        size = { 24, 12, 24 },
        color = { 200, 230, 210 },
        textKey = "facility.farm.name",
    },
    Pipe = { -- 물탱크 뒤 끝에 붙는 연결관 (디자이너 에셋 Assets.Pipe)
        kit = {
            main = "Connector",
            extras = { { name = "ConnectorElbow", layout = "endX", scale = 1 } },
        },
        shape = "cylinder",
        size = { 4, 5, 4 },
        color = { 190, 192, 198 },
        textKey = "facility.pipe.name",
    },
    Airlock = {
        kit = { main = "HabitatC" },
        shape = "hut",
        size = { 10, 8, 10 },
        color = { 225, 225, 230 },
        textKey = "facility.airlock.name",
    },
    Lander = {
        kit = { main = "Lander" },
        shape = "hut",
        size = { 12, 9, 12 },
        color = { 200, 200, 205 },
        textKey = "world.lander.name",
    },
    SolarPanel = {
        kit = { main = "Panel" },
        shape = "panel",
        size = { 5, 0.5, 4 },
        color = { 25, 40, 95 },
        textKey = nil, -- 20장마다 이름표는 시끄럽다
    },
    WaterTank = {
        kit = { main = "WaterTank" },
        shape = "cylinder",
        size = { 12, 14, 12 },
        color = { 110, 185, 255 },
        textKey = "world.water_tank.name",
    },
    Rover = {
        kit = { main = "Rover" },
        shape = "box",
        size = { 6, 4, 9 },
        color = { 225, 225, 230 },
        textKey = "world.rover.name",
    },
    -- B 미션용 (Q27 조합만 미리 적어 둔다)
    WaterRover = {
        kit = {
            main = "Rover",
            extras = { { name = "WaterTank", layout = "top", scale = 0.45 } },
        },
        shape = "box",
        size = { 6, 5, 9 },
        color = { 225, 225, 230 },
        textKey = "world.water_rover.name",
    },
    SolarTower = {
        kit = { main = "Antenna" },
        shape = "cylinder",
        size = { 4, 16, 4 },
        color = { 190, 192, 198 },
        textKey = "facility.tower.name",
    },
    -- 업그레이드 장치 (그린하우스 옆에 붙는 작은 건물, 건설 중 솟아오르고 제어반이 붙는다)
    LedUnit = {
        kit = nil,
        shape = "box",
        size = { 5, 4, 5 },
        color = { 255, 120, 220 },
        textKey = "facility.led.name",
    },
    NutrientUnit = {
        kit = { main = "Crate" },
        shape = "box",
        size = { 5, 4, 5 },
        color = { 120, 200, 120 },
        textKey = "facility.nutrient.name",
    },
    HydroUnit = {
        kit = { main = "WaterTank" },
        shape = "cylinder",
        size = { 5, 5, 5 },
        color = { 110, 185, 255 },
        textKey = "facility.hydroponics.name",
    },
    PipeWellhead = { -- 파이프가 연결된 얼음 지점의 우물머리
        kit = { main = "Connector" },
        shape = "cylinder",
        size = { 4, 4, 4 },
        color = { 190, 192, 198 },
        textKey = "facility.pipe.name",
    },
    IceCrystal = { -- 예전 얼음 외형 (v2는 IceDeposit을 쓴다. 너무 눈에 띄어 2026-11-15 교체)
        kit = { main = "IceCrystal" },
        shape = "box",
        size = { 6, 6, 6 },
        color = { 170, 220, 255 },
        textKey = "world.ice_site.name",
    },
    -- 얼음 후보지: 표토에 섞인 얼음 (Assets.IceDeposit -> 대체 도형). 반짝이는 Kit.IceCrystal은 쓰지 않는다.
    -- 이름표는 buildIceSites가 가까이서만 보이게 따로 단다
    IceDeposit = {
        kit = nil,
        shape = "deposit",
        size = { 9, 1.6, 7 },
        color = { 88, 88, 92 }, -- 어두운 표토
        tint = { 102, 108, 118 }, -- 얼음이 섞인 덩어리: 아주 약한 푸른 기
        textKey = nil,
    },
}

local DEFAULT_ROLE: RoleSpec = {
    kit = nil,
    shape = "box",
    size = { 6, 6, 6 },
    color = { 200, 200, 205 },
    textKey = "world.placeholder.name",
}

local MIN_EXTENT = 0.01

-- 타입 ------------------------------------------------------------------
export type MarkerInfo = {
    name: string,
    part: BasePart,
    cframe: CFrame,
    position: Vector3,
    size: Vector3,
    shape: string, -- "Block" | "Cylinder" | "Ball"
    rendered: Vector3, -- 실제로 그려지는 로컬 크기
    extents: Vector3, -- 렌더 모양의 월드 축 경계 크기
    yaw: number, -- 수평 방향 (라디안)
    bottomY: number,
    groundSamples: { number? },
    groundFound: boolean,
}

export type Shelter = {
    id: string,
    model: Model,
    frame: CFrame, -- 바닥 윗면 중심, 정면(문)이 LookVector
    door: BasePart?,
    zone: BasePart,
    console: BasePart?,
    panel: BasePart?,
    light: BasePart?,
    inside: CFrame, -- 대피 이동 지점
}

export type IceSite = {
    index: number, -- 정렬 순서 (1 = 기준 표시에서 가장 가까움)
    markerName: string,
    position: Vector3, -- 표시 중심의 지면 위치
    distanceFromExit: number,
    distanceFromRoverPark: number,
    distanceFromLander: number,
}

-- exitFrame, exitMode: 완공(충돌이 켜지는) 순간 안에 있는 플레이어를 내보낼 기준 (CFG.eject). exitFrame의 -Z가 정면
type Riser = {
    model: Model,
    pivot: CFrame,
    height: number,
    offset: number,
    exitFrame: CFrame?,
    exitMode: string?, -- "front" | "nearest"
    exitClearance: number?,
}

type Look = { transparency: number, material: Enum.Material, color: Color3 }

type Facility = {
    id: string,
    defId: string,
    container: Model,
    risers: { Riser },
    collide: { [BasePart]: boolean },
    progress: number,
    status: string, -- "building" | "active"
    paused: boolean,
    token: number,
    panel: BasePart?,
    light: BasePart?,
    segments: { BasePart },
    siteIndex: number?,
    dimParts: { BasePart },
    origin: Vector3?, -- 관로 시작점 (파이프 받침 바닥 중심, 완공 위치 기준)
}

type TankInfo = {
    frame: CFrame, -- 기초 판 윗면 중심. 로컬 +Z = 뒤 끝(얼음 쪽), -Z = 문과 경사로
    factor: number, -- 에셋에 곱한 배율 (같은 단위인 파이프에도 그대로)
    source: string,
    lo: Vector3, -- frame 로컬 경계
    hi: Vector3,
    side: number, -- 착륙선 쪽 옆면 (+1 = 로컬 +X)
}

type BaseOptions = { panelSlots: number? }

local MissionWorld = {}

-- 상태 ------------------------------------------------------------------
local currentMission: string? = nil
local markers: { [string]: MarkerInfo } = {}
local runtime: Folder? = nil
local preview: Instance? = nil -- 떼어 둔 AssetPreview (참조를 남겨 둔다)
local baseOptions: BaseOptions = {}
local basePlaced = false
local shelters: { [string]: Shelter } = {}
local anchors: { [string]: BasePart } = {}
local slots: { BasePart } = {}
local panelRisers: { [number]: Riser } = {}
local panelCount = 0
local facilities: { [string]: Facility } = {}
local farmFrame: CFrame? = nil
local tankInfo: TankInfo? = nil
local farmHalf = Vector3.zero
local upgradeParts: { [string]: { BasePart } } = { led = {}, hydroponics = {} }
local looks: { [BasePart]: Look } = {} -- 숨김, 어둡게 하기 전 원래 모습
local airlockStatus = "idle"
local generation = 0 -- init, reset마다 증가. 이전 연출 스레드를 멈춘다
local warnedOnce: { [string]: boolean } = {}

-- 작은 도우미 ------------------------------------------------------------

local function rgb(c: { number }): Color3
    return Color3.fromRGB(c[1], c[2], c[3])
end

local function vec(t: { number }): Vector3
    return Vector3.new(t[1], t[2], t[3])
end

local function warnOnce(key: string, message: string)
    if warnedOnce[key] then
        return
    end
    warnedOnce[key] = true
    warn("[MissionWorld] " .. message)
end

local function safe(label: string, fn: () -> ())
    local ok, err = pcall(fn)
    if not ok then
        warn("[MissionWorld] " .. label .. " 실패: " .. tostring(err))
    end
end

local function xz(v: Vector3): WorldMath.XZ
    return { X = v.X, Z = v.Z }
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

local function startsWithAny(name: string, prefixes: { string }): boolean
    for _, prefix in prefixes do
        if string.sub(name, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

type PartSpec = {
    name: string,
    size: Vector3,
    cframe: CFrame,
    color: Color3,
    material: Enum.Material?,
    transparency: number?,
    canCollide: boolean?,
    shape: Enum.PartType?,
    parent: Instance?,
}

local function newPart(spec: PartSpec): Part
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
    part.Anchored = true
    part.CanTouch = false
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = spec.parent
    return part
end

-- 보이지 않는 판정 파트 (산소 구역, 상호작용 자리)
local function newMarker(name: string, size: Vector3, cframe: CFrame, parent: Instance): Part
    local part = newPart({
        name = name,
        size = size,
        cframe = cframe,
        color = rgb(CFG.colors.slot),
        transparency = 1,
        canCollide = false,
        parent = parent,
    })
    part.CanQuery = false
    part.CastShadow = false
    return part
end

local function newModel(name: string, parent: Instance?): Model
    local model = Instance.new("Model")
    model.Name = name
    model.Parent = parent
    return model
end

local function childFolder(parent: Instance, name: string): Folder
    local existing = parent:FindFirstChild(name)
    if existing and existing:IsA("Folder") then
        return existing
    end
    local folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

-- 글자 요소: Text는 비우고 TextKey만 단다 (클라이언트가 언어에 맞게 채운다)
local function keyedLabel(parent: Instance, key: string, color: Color3): TextLabel
    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextColor3 = color
    label.TextScaled = true
    label.Font = Enum.Font.GothamBold
    label.Text = ""
    label.AutoLocalize = false
    label:SetAttribute("TextKey", key)
    label.Parent = parent
    return label
end

-- 기하 도우미 (v1 KitImports와 같은 방식) ---------------------------------

-- 모든 BasePart를 덮는 frame 좌표계 경계 상자 (frame이 없으면 월드 축)
local function boundsIn(root: Instance, frame: CFrame?): (Vector3, Vector3)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    forEachPart(root, function(part)
        local cf, half = part.CFrame, part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local p = cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                    if frame then
                        p = frame:PointToObjectSpace(p)
                    end
                    lo = Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
                    hi = Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
                end
            end
        end
    end)
    if lo.X > hi.X then
        return Vector3.zero, Vector3.zero
    end
    return lo, hi
end

local function translate(model: Model, delta: Vector3)
    model:PivotTo(CFrame.new(delta) * model:GetPivot())
end

local function scaleBy(model: Model, factor: number)
    if factor > 0 and factor < math.huge and math.abs(factor - 1) > 1e-6 then
        model:ScaleTo(model:GetScale() * factor)
    end
end

-- 경계 상자 바닥 중심을 원점에
local function bottomToOrigin(model: Model)
    local lo, hi = boundsIn(model)
    translate(model, -Vector3.new((lo.X + hi.X) / 2, lo.Y, (lo.Z + hi.Z) / 2))
end

local function placeBottom(model: Model, bottomCenter: Vector3)
    local lo, hi = boundsIn(model)
    translate(model, bottomCenter - Vector3.new((lo.X + hi.X) / 2, lo.Y, (lo.Z + hi.Z) / 2))
end

local function setStatic(model: Instance, canCollide: boolean)
    forEachPart(model, function(part)
        part.Anchored = true
        part.CanCollide = canCollide
        part.CanTouch = false
        part.CanQuery = canCollide
    end)
end

-- 모델을 frame 안 바닥 중심에 놓는다. box(로컬 크기 X, Z, 높이 상한 Y)에 맞춰 균일 배율, minHeight가 있으면 그만큼은 키운다
local function fitIntoFrame(
    model: Model,
    frame: CFrame,
    box: WorldMath.Footprint,
    minHeight: number?
): number
    bottomToOrigin(model)
    local lo, hi = boundsIn(model)
    local size = hi - lo
    local factor = WorldMath.fitScale(size, box)
    if minHeight ~= nil and size.Y * factor < minHeight then
        factor = minHeight / math.max(size.Y, MIN_EXTENT)
    end
    scaleBy(model, factor)
    bottomToOrigin(model)
    model:PivotTo(frame * model:GetPivot())
    return factor
end

-- 지면 ------------------------------------------------------------------

-- (x, z)의 지형 높이. Terrain만 맞히는 광선이라 표시, 런타임 파트, 캐릭터는 무시한다. 못 찾으면 nil
local function terrainHeight(x: number, z: number, nearY: number): number?
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if not terrain then
        return nil
    end
    local g = CFG.ground
    local ok, result = pcall(function()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = { terrain }
        return workspace:Raycast(
            Vector3.new(x, nearY + g.probeUp, z),
            Vector3.new(0, -(g.probeUp + g.probeDepth), 0),
            params
        )
    end)
    if ok and result then
        return result.Position.Y
    end
    return nil
end

-- frame(수평 회전) 기준 반폭 halfX, halfZ 바닥 넓이의 중심과 네 모서리 지면 샘플
local function footprintSamples(
    frame: CFrame,
    halfX: number,
    halfZ: number,
    nearY: number
): ({ number? }, boolean)
    local r = CFG.ground.cornerRatio
    local samples: { number? } = {}
    local found = false
    for i, offset in { { 0, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
        local p = frame * Vector3.new(offset[1] * halfX * r, 0, offset[2] * halfZ * r)
        local h = terrainHeight(p.X, p.Z, nearY)
        samples[i] = h
        if h ~= nil then
            found = true
        end
    end
    return samples, found
end

-- 갇힘 방지 ---------------------------------------------------------------
-- 건설 중인 시설은 충돌이 없어 안으로 걸어 들어갈 수 있다. 완공(충돌이 켜지는) 순간 그 안에 있던 플레이어는
-- 벽이나 바닥 판에 갇혔다 (2026-11-15 시험 피드백). 충돌을 켤 때마다 구조물 경계(조금 넓힘) 안의 플레이어를
-- 정면 바깥 지면(지형 광선)으로 옮기고 건물 반대쪽을 보게 한다

local function rootPartOf(player: Player): BasePart?
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root
    end
    return nil
end

-- root 경계(frame 좌표) 안의 플레이어를 바깥으로. mode "front"(frame -Z 면 바깥) | "nearest"(가장 가까운 옆면).
-- 운전석에 앉은 플레이어는 로버째 움직이므로 건드리지 않는다. 반환: 옮긴 플레이어 수
local function ejectPlayers(root: Instance, frame: CFrame, mode: string, clearance: number?): number
    local ej = CFG.eject
    local lo, hi = boundsIn(root, frame)
    if (hi - lo).Magnitude < MIN_EXTENT then
        return 0
    end
    local ok, list = pcall(function()
        return Players:GetPlayers()
    end)
    if not ok or typeof(list) ~= "table" then
        return 0
    end
    local moved = 0
    for _, player in list do
        local rootPart = rootPartOf(player)
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local seated = humanoid ~= nil and humanoid.SeatPart ~= nil
        if rootPart and character and not seated then
            local p = frame:PointToObjectSpace(rootPart.CFrame.Position)
            if WorldMath.insideBounds(p, lo, hi, ej.margin, ej.headroom) then
                moved += 1
                local spot, dx, dz = WorldMath.exitPoint(
                    { X = p.X, Z = p.Z },
                    { X = lo.X, Z = lo.Z },
                    { X = hi.X, Z = hi.Z },
                    clearance or ej.clearance,
                    mode,
                    WorldMath.spreadOffset(moved, ej.spacing)
                )
                local world = frame * Vector3.new(spot.X, 0, spot.Z)
                local outward = frame:VectorToWorldSpace(Vector3.new(dx, 0, dz))
                local flatOut = Vector3.new(outward.X, 0, outward.Z)
                if flatOut.Magnitude < 1e-3 then
                    flatOut = Vector3.new(0, 0, -1)
                end
                local h = terrainHeight(world.X, world.Z, frame.Position.Y)
                local at = Vector3.new(world.X, (h or frame.Position.Y) + ej.rootHeight, world.Z)
                local model = character :: Model
                local moveOk, moveErr = pcall(function()
                    model:PivotTo(CFrame.lookAt(at, at + flatOut.Unit))
                end)
                if not moveOk then
                    warn("[MissionWorld] 플레이어 내보내기 실패: " .. tostring(moveErr))
                end
                pcall(function()
                    rootPart.AssemblyLinearVelocity = Vector3.zero
                end)
            end
        end
    end
    return moved
end

local function ejectFromRiser(riser: Riser): number
    local frame = riser.exitFrame
    if frame == nil or riser.model.Parent == nil then
        return 0
    end
    return ejectPlayers(riser.model, frame, riser.exitMode or "front", riser.exitClearance)
end

-- 표시 정보 -------------------------------------------------------------

local function flatYaw(cf: CFrame): number
    local look = cf.LookVector
    if math.abs(look.X) + math.abs(look.Z) < 1e-3 then
        look = -cf.UpVector
    end
    return WorldMath.yawOfDirection(look.X, look.Z)
end

local function readMarker(part: BasePart): MarkerInfo
    local cf = part.CFrame
    local shape = "Block"
    if part:IsA("Part") then
        shape = (part :: Part).Shape.Name
    end
    local renderedT = WorldMath.renderedSize(part.Size, shape)
    local rendered = Vector3.new(renderedT.X, renderedT.Y, renderedT.Z)
    local ext = WorldMath.worldExtents(rendered, cf.RightVector, cf.UpVector, -cf.LookVector)
    local extents = Vector3.new(ext.X, ext.Y, ext.Z)
    local bottomY = cf.Position.Y - extents.Y / 2
    local yaw = flatYaw(cf)
    local frame = CFrame.new(cf.Position.X, bottomY, cf.Position.Z)
    -- 모서리 샘플은 월드 축 경계 크기로 (회전된 표시도 넓이를 덮는다)
    local samples, found = footprintSamples(frame, extents.X / 2, extents.Z / 2, bottomY)
    return {
        name = part.Name,
        part = part,
        cframe = cf,
        position = cf.Position,
        size = part.Size,
        shape = shape,
        rendered = rendered,
        extents = extents,
        yaw = yaw,
        bottomY = bottomY,
        groundSamples = samples,
        groundFound = found,
    }
end

-- 표시의 렌더 모양을 frame 축으로 본 경계 크기
local function footprintIn(info: MarkerInfo, frame: CFrame): Vector3
    local cf = info.cframe
    local r = frame:VectorToObjectSpace(cf.RightVector)
    local u = frame:VectorToObjectSpace(cf.UpVector)
    local b = frame:VectorToObjectSpace(-cf.LookVector)
    local e = WorldMath.worldExtents(info.rendered, r, u, b)
    return Vector3.new(e.X, e.Y, e.Z)
end

local function groundY(info: MarkerInfo, mode: string): number
    return WorldMath.groundFromSamples(info.groundSamples, mode, info.bottomY)
end

-- 정면 방향: 표시 Attribute "Yaw"(도) > faceToward 표시 쪽(표시 축 기준 yawStepDeg 배수) > 표시 자체 방향
local function facingYaw(info: MarkerInfo, faceToward: string?): number
    local attr = info.part:GetAttribute("Yaw")
    if typeof(attr) == "number" and attr == attr then
        return math.rad(attr)
    end
    local target = faceToward and markers[faceToward]
    if target then
        local raw = WorldMath.yawToward(xz(info.position), xz(target.position))
        local step = math.rad(CFG.yawStepDeg)
        return info.yaw + WorldMath.snapAngle(raw - info.yaw, step)
    end
    return info.yaw
end

local function yawFrame(position: Vector3, y: number, yaw: number): CFrame
    return CFrame.new(position.X, y, position.Z) * CFrame.Angles(0, yaw, 0)
end

-- 기초 판 (고르지 않은 지면 위 콘크리트 판). frame 원점 높이를 판 윗면으로 바꾼 frame과 판을 돌려준다
local function buildFoundation(
    parent: Instance,
    frame: CFrame,
    sizeX: number,
    sizeZ: number,
    name: string,
    color: Color3?
): (CFrame, Part)
    local g = CFG.ground
    local samples = footprintSamples(frame, sizeX / 2, sizeZ / 2, frame.Position.Y)
    local top, bottom = WorldMath.foundation(samples, frame.Position.Y, g.lift, g.sink)
    local height = top - bottom
    local topFrame = CFrame.new(frame.Position.X, top, frame.Position.Z) * frame.Rotation
    local slab = newPart({
        name = name,
        size = Vector3.new(sizeX, height, sizeZ),
        cframe = topFrame * CFrame.new(0, -height / 2, 0),
        color = color or rgb(CFG.colors.foundation),
        material = Enum.Material.Concrete,
        parent = parent,
    })
    return topFrame, slab
end

-- 에셋 3단계 대체 ---------------------------------------------------------

local function hasParts(inst: Instance): boolean
    if inst:IsA("BasePart") then
        return true
    end
    for _, d in inst:GetDescendants() do
        if d:IsA("BasePart") then
            return true
        end
    end
    return false
end

local function usable(inst: Instance?): boolean
    return inst ~= nil and (inst:IsA("Model") or inst:IsA("BasePart")) and hasParts(inst)
end

-- 원본을 복제해 Model로 돌려준다. 스크립트는 지운다. 원본은 바꾸지 않는다
local function cloneAsModel(source: Instance): Model
    local model: Model
    if source:IsA("Model") then
        model = source:Clone()
    else
        model = Instance.new("Model")
        model.Name = source.Name
        local part = source:Clone()
        part.Parent = model
        if part:IsA("BasePart") then
            model.PrimaryPart = part
        end
    end
    for _, d in model:GetDescendants() do
        if d:IsA("LuaSourceContainer") then
            d:Destroy()
        end
    end
    return model
end

local function assetsFolder(): Instance?
    return ServerStorage:FindFirstChild(CFG.assetsFolder)
end

-- 2단계: Kit 조합
local function buildKit(roleName: string, spec: RoleSpec): Model?
    local combo = spec.kit
    local assets = assetsFolder()
    local kit = assets and assets:FindFirstChild(CFG.kitFolder)
    if not combo or not kit then
        return nil
    end
    local mainSource = kit:FindFirstChild(combo.main)
    if not usable(mainSource) then
        return nil
    end
    local model = newModel(roleName, nil)
    local main = cloneAsModel(mainSource :: Instance)
    main.Name = "Main"
    main.Parent = model
    local lo, hi = boundsIn(main)
    local mainSize = hi - lo
    local center = (lo + hi) / 2
    local reach = math.max(mainSize.X, mainSize.Z)
    for _, extra in combo.extras or {} do
        local source = kit:FindFirstChild(extra.name)
        if usable(source) then
            local count = extra.count or 1
            for i = 1, count do
                local piece = cloneAsModel(source :: Instance)
                local plo, phi = boundsIn(piece)
                local psize = phi - plo
                scaleBy(piece, reach * extra.scale / math.max(psize.X, psize.Z, MIN_EXTENT))
                plo, phi = boundsIn(piece)
                psize = phi - plo
                local bottom: Vector3
                if extra.layout == "top" then
                    bottom = Vector3.new(center.X, hi.Y, center.Z)
                elseif extra.layout == "ring" then
                    local angle = 2 * math.pi * (i - 1) / count
                    local radius = reach / 2 + math.max(psize.X, psize.Z) / 2
                    bottom = Vector3.new(
                        center.X + math.sin(angle) * radius,
                        lo.Y,
                        center.Z - math.cos(angle) * radius
                    )
                else -- "endX"
                    bottom = Vector3.new(hi.X + psize.X / 2, lo.Y, center.Z)
                end
                placeBottom(piece, bottom)
                piece.Name = extra.name .. i
                piece.Parent = model
            end
        else
            warnOnce(
                "kit:" .. extra.name,
                "Kit." .. extra.name .. "이 없어 " .. roleName .. " 조합에서 뺍니다"
            )
        end
    end
    return model
end

-- 3단계: 코드 도형 + 이름표
local function makePlaceholder(roleName: string, spec: RoleSpec): Model
    local model = newModel(roleName, nil)
    local size = vec(spec.size)
    local color = rgb(spec.color)
    local body: BasePart
    if spec.shape == "hut" then
        local t = 0.4
        local gap = math.min(CFG.entry.doorGap, size.X - 2 * t)
        local doorTop = math.min(CFG.entry.doorHeight + CFG.entry.frameBorder + 0.5, size.Y - t)
        local function wall(name: string, s: Vector3, p: Vector3)
            newPart({
                name = name,
                size = s,
                cframe = CFrame.new(p),
                color = color,
                material = Enum.Material.Metal,
                parent = model,
            })
        end
        local side = (size.X - gap) / 2
        wall(
            "WallBack",
            Vector3.new(size.X, size.Y, t),
            Vector3.new(0, size.Y / 2, size.Z / 2 - t / 2)
        )
        wall(
            "WallLeft",
            Vector3.new(t, size.Y, size.Z),
            Vector3.new(-size.X / 2 + t / 2, size.Y / 2, 0)
        )
        wall(
            "WallRight",
            Vector3.new(t, size.Y, size.Z),
            Vector3.new(size.X / 2 - t / 2, size.Y / 2, 0)
        )
        for _, sign in { -1, 1 } do
            wall(
                if sign < 0 then "WallFrontLeft" else "WallFrontRight",
                Vector3.new(side, size.Y, t),
                Vector3.new(sign * (gap / 2 + side / 2), size.Y / 2, -size.Z / 2 + t / 2)
            )
        end
        wall(
            "Lintel",
            Vector3.new(gap, size.Y - doorTop, t),
            Vector3.new(0, (size.Y + doorTop) / 2, -size.Z / 2 + t / 2)
        )
        body = newPart({
            name = "Roof",
            size = Vector3.new(size.X, t, size.Z),
            cframe = CFrame.new(0, size.Y + t / 2, 0),
            color = color,
            material = Enum.Material.Metal,
            parent = model,
        })
    elseif spec.shape == "cylinder" then
        local d = math.min(size.X, size.Z)
        body = newPart({
            name = "Body",
            shape = Enum.PartType.Cylinder,
            size = Vector3.new(size.Y, d, d),
            cframe = CFrame.new(0, size.Y / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
            color = color,
            material = Enum.Material.Metal,
            parent = model,
        })
    elseif spec.shape == "deposit" then
        -- 표토 덩어리 무리: 네온, 반사 없음. 얼음이 섞인 덩어리만 아주 약하게 푸른 기
        local tint = if spec.tint then rgb(spec.tint) else color
        local first: BasePart? = nil
        for i, chunk in CFG.iceDeposit.chunks do
            local s = vec(chunk.size)
            local part = newPart({
                name = "Chunk" .. i,
                size = s,
                cframe = CFrame.new(chunk.at[1], s.Y / 2, chunk.at[2])
                    * CFrame.Angles(0, math.rad(chunk.yaw), 0)
                    * CFrame.Angles(math.rad(chunk.tilt), 0, 0),
                color = if chunk.tint then tint else color,
                material = Enum.Material.Slate,
                parent = model,
            })
            part.Reflectance = 0
            if first == nil then
                first = part
            end
        end
        body = first
            or newPart({
                name = "Body",
                size = size,
                cframe = CFrame.new(0, size.Y / 2, 0),
                color = color,
                material = Enum.Material.Slate,
                parent = model,
            })
    elseif spec.shape == "panel" then
        newPart({
            name = "Frame",
            size = Vector3.new(size.X, size.Y * 0.4, size.Z),
            cframe = CFrame.new(0, size.Y * 0.2, 0),
            color = rgb(CFG.colors.pipe),
            material = Enum.Material.Metal,
            parent = model,
        })
        body = newPart({
            name = "Glass",
            size = Vector3.new(size.X * 0.94, size.Y * 0.6, size.Z * 0.94),
            cframe = CFrame.new(0, size.Y * 0.7, 0),
            color = color,
            material = Enum.Material.Glass,
            parent = model,
        })
    else
        body = newPart({
            name = "Body",
            size = size,
            cframe = CFrame.new(0, size.Y / 2, 0),
            color = color,
            material = Enum.Material.Metal,
            parent = model,
        })
    end
    model.PrimaryPart = body
    if spec.textKey then
        local l = CFG.label
        local gui = Instance.new("BillboardGui")
        gui.Name = "Label"
        gui.Size = UDim2.fromScale(l.width, l.height) -- BillboardGui 비율 크기 = studs
        gui.StudsOffset = Vector3.new(0, l.offset + l.height / 2, 0)
        gui.MaxDistance = l.maxDistance
        gui.LightInfluence = 0
        gui.AutoLocalize = false
        gui.Parent = body
        local label = keyedLabel(gui, spec.textKey, rgb(CFG.colors.labelText))
        label.TextStrokeTransparency = 0.4
    end
    return model
end

-- 역할 이름으로 외형 Model을 만든다. 반환: 모델, 출처("asset" | "kit" | "placeholder")
-- 모델은 아직 어디에도 붙지 않았고(Parent nil) 위치와 크기는 원본 그대로다. 호출한 쪽이 맞춘다
function MissionWorld.resolveAsset(roleName: string): (Model, string)
    local spec = ROLES[roleName] or DEFAULT_ROLE
    local assets = assetsFolder()
    local direct = assets and assets:FindFirstChild(roleName)
    local model: Model? = nil
    local source = "placeholder"
    if direct and usable(direct) then
        model = cloneAsModel(direct)
        source = "asset"
    elseif direct then
        warnOnce(
            "asset:" .. roleName,
            "Assets."
                .. roleName
                .. "이 Model이나 BasePart가 아니거나 파트가 없어 대체합니다"
        )
    end
    if not model then
        local ok, kitModel = pcall(buildKit, roleName, spec)
        if ok and kitModel then
            model = kitModel
            source = "kit"
        elseif not ok then
            warn("[MissionWorld] Kit 조합 실패 " .. roleName .. ": " .. tostring(kitModel))
        end
    end
    local result = model or makePlaceholder(roleName, spec)
    result.Name = roleName
    result:SetAttribute("AssetRole", roleName)
    result:SetAttribute("AssetSource", source)
    return result, source
end

-- 걸어 들어가는 건물 ------------------------------------------------------

local doubleSidedWarned = false

-- 외형 충돌 끄기(walkable 이름은 남긴다), 메시는 양면 렌더링
local function makeWalkIn(model: Instance, walkable: { string })
    forEachPart(model, function(part)
        part.Anchored = true
        part.CanTouch = false
        if table.find(walkable, part.Name) == nil then
            part.CanCollide = false
            part.CanQuery = false
        end
        if part:IsA("MeshPart") then
            local ok = pcall(function()
                (part :: MeshPart).DoubleSided = true
            end)
            if not ok and not doubleSidedWarned then
                doubleSidedWarned = true
                warn(
                    "[MissionWorld] MeshPart.DoubleSided를 스크립트에서 바꿀 수 없어 안쪽 면이 안 보일 수 있습니다"
                )
            end
        end
    end)
end

-- frame 로컬 경계 lo, hi 둘레에 보이지 않는 충돌 벽. 정면(-Z) 가운데는 문 폭만큼 비운다.
-- withDoor이면 문, 프레임, 표지(signKey), 내부 빛을 "Entry" 모델에 만든다(v1 Airlock 모듈이 Entry.Door를 찾는다).
-- 문이 없으면 벽만 "Walls" 모델에. 반환: 만든 모델, 문 파트, 산소 구역 로컬 최소점, 최대점, 문 z
local function buildEntry(
    parent: Instance,
    frame: CFrame,
    lo: Vector3,
    hi: Vector3,
    shape: string,
    withDoor: boolean,
    signKey: string?
): (Model, BasePart?, Vector3, Vector3, number)
    local e = CFG.entry
    local entry = newModel(if withDoor then "Entry" else "Walls", parent)
    local cx, cz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
    local doorZ = lo.Z + e.doorInset
    local wallHeight = math.max(hi.Y, e.minWallHeight)
    local t = e.wallThickness

    local function wall(name: string, length: number, center: Vector3, outward: Vector3)
        local position = Vector3.new(center.X, wallHeight / 2, center.Z)
        local part = newPart({
            name = name,
            size = Vector3.new(length, wallHeight, t),
            cframe = frame * CFrame.lookAt(position, position + outward),
            color = rgb(CFG.colors.door),
            transparency = 1,
            canCollide = true,
            parent = entry,
        })
        part.CanQuery = false
        part.CastShadow = false
    end
    local function frontWall(length: number, center: Vector3, tangent: Vector3, outward: Vector3)
        local piece = (length - e.doorGap) / 2
        if piece <= 0 then
            return
        end
        for _, side in { -1, 1 } do
            wall(
                if side < 0 then "WallFrontLeft" else "WallFrontRight",
                piece,
                center + tangent * side * (e.doorGap / 2 + piece / 2),
                outward
            )
        end
    end

    if shape == "octagon" then
        local radius = math.max(hi.X - lo.X, hi.Z - lo.Z) / 2
        local apothem = radius + t / 2
        local side = 2 * apothem * math.tan(math.pi / 8) + t
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
        doorZ = cz - apothem + e.doorInset
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

    -- 대피처(문이 있는 건물): 보이지 않는 천장과 문 위 막이. 외형은 충돌이 없어 지붕을 뚫고 뛰어 나가거나 들어올 수
    -- 있었고, 문 틈은 벽 높이 끝까지 열려 있었다 (2026-11-15 시험 피드백). 천장은 벽 윗면에 딱 붙고 벽 바깥 두께까지 덮는다
    if withDoor then
        local function solid(name: string, size: Vector3, center: Vector3)
            local part = newPart({
                name = name,
                size = size,
                cframe = frame * CFrame.new(center),
                color = rgb(CFG.colors.door),
                transparency = 1,
                canCollide = true,
                parent = entry,
            })
            part.CanQuery = false
            part.CastShadow = false
        end
        local frontZ: number
        local ceilingX: number
        local ceilingZ: number
        if shape == "octagon" then
            local radius = math.max(hi.X - lo.X, hi.Z - lo.Z) / 2
            local apothem = radius + t / 2
            frontZ = cz - apothem
            ceilingX = 2 * (apothem + t) -- 대각 벽 모서리(바깥 반지름 apothem + 0.71t)까지 덮는다
            ceilingZ = ceilingX
        else
            frontZ = lo.Z - t / 2
            ceilingX = hi.X - lo.X + 2 * t
            ceilingZ = hi.Z - lo.Z + 2 * t
        end
        solid(
            "Ceiling",
            Vector3.new(ceilingX, t, ceilingZ),
            Vector3.new(cx, wallHeight + t / 2, cz)
        )
        local doorTop = e.doorHeight + e.frameBorder
        if wallHeight - doorTop > MIN_EXTENT then
            solid(
                "DoorLintel",
                Vector3.new(e.doorGap, wallHeight - doorTop, t),
                Vector3.new(cx, (doorTop + wallHeight) / 2, frontZ)
            )
        end
    end

    local door: BasePart? = nil
    if withDoor then
        local frameColor = rgb(CFG.colors.doorFrame)
        local doorFrame = newPart({
            name = "DoorFrame",
            size = Vector3.new(
                e.doorWidth + 2 * e.frameBorder,
                e.doorHeight + e.frameBorder,
                e.doorThickness / 2
            ),
            cframe = frame
                * CFrame.new(cx, (e.doorHeight + e.frameBorder) / 2, doorZ + e.doorThickness / 2),
            color = frameColor,
            material = Enum.Material.Metal,
            canCollide = false,
            parent = entry,
        })
        doorFrame.CanQuery = false
        -- 닫힌 문은 막힌다. 여닫기와 프롬프트는 Airlock 모듈이 맡는다
        door = newPart({
            name = "Door",
            size = Vector3.new(e.doorWidth, e.doorHeight, e.doorThickness),
            cframe = frame * CFrame.new(cx, e.doorHeight / 2, doorZ),
            color = rgb(CFG.colors.door),
            material = Enum.Material.Metal,
            canCollide = true,
            parent = entry,
        })
        local sign = newPart({
            name = "DoorSign",
            size = Vector3.new(e.doorWidth, e.signHeight, e.doorThickness / 2),
            cframe = frame * CFrame.new(
                cx,
                e.doorHeight + e.frameBorder + e.signHeight / 2,
                doorZ - e.doorThickness / 4
            ),
            color = rgb(CFG.colors.door),
            canCollide = false,
            parent = entry,
        })
        sign.CanQuery = false
        if signKey then
            local gui = Instance.new("SurfaceGui")
            gui.Name = "SignGui"
            gui.Face = Enum.NormalId.Front
            gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
            gui.PixelsPerStud = e.signPixelsPerStud
            gui.AutoLocalize = false
            gui.Parent = sign
            keyedLabel(gui, signKey, frameColor)
        end
        -- 내부의 따뜻한 빛 (Attachment는 파트 아래에만 둘 수 있어 표지에 붙이고 위치를 맞춘다)
        local glow = Instance.new("Attachment")
        glow.Name = "InteriorLight"
        local glowWorld = frame * CFrame.new(cx, math.max(hi.Y, e.doorHeight) * 0.6, cz)
        glow.CFrame = sign.CFrame:ToObjectSpace(glowWorld)
        local light = Instance.new("PointLight")
        light.Color = rgb(CFG.colors.interiorLight)
        light.Range = e.lightRange
        light.Brightness = e.lightBrightness
        light.Parent = glow
        glow.Parent = sign
    end

    local zoneMin = Vector3.new(lo.X + e.zoneInset, 0, doorZ - e.zoneDoorMargin)
    local zoneMax = Vector3.new(
        hi.X - e.zoneInset,
        math.max(hi.Y - e.zoneInset, e.doorHeight),
        hi.Z - e.zoneInset
    )
    return entry, door, zoneMin, zoneMax, doorZ
end

-- 제어반과 상태 표시등: frame 로컬 위치 localPos, 바깥 방향 outward(로컬). TextKey = 시설 이름
local function buildControlPanel(
    parent: Instance,
    frame: CFrame,
    localPos: Vector3,
    outward: Vector3,
    facilityId: string,
    textKey: string
): (Part, Part)
    local cp = CFG.controlPanel
    local size = vec(cp.size)
    local look = frame * CFrame.lookAt(localPos, localPos + outward)
    local panel = newPart({
        name = "ControlPanel",
        size = size,
        cframe = look,
        color = rgb(CFG.colors.panel),
        material = Enum.Material.Metal,
        canCollide = false,
        parent = parent,
    })
    panel:SetAttribute("FacilityId", facilityId)
    local gui = Instance.new("SurfaceGui")
    gui.Name = "PanelGui"
    gui.Face = Enum.NormalId.Front
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = cp.pixelsPerStud
    gui.AutoLocalize = false
    gui.Parent = panel
    keyedLabel(gui, textKey, rgb(CFG.colors.labelText))
    local lightSize = vec(cp.lightSize)
    local light = newPart({
        name = "StatusLight",
        size = lightSize,
        cframe = look * CFrame.new(0, size.Y / 2 + lightSize.Y / 2 + 0.05, 0),
        color = rgb(CFG.colors.status.idle),
        material = Enum.Material.Neon,
        canCollide = false,
        parent = parent,
    })
    light.CanQuery = false
    -- 받침 기둥: 둥근 건물(팔각 벽)처럼 패널이 벽에서 떨어져도 떠 보이지 않게 바닥까지 세운다
    local postHeight = localPos.Y - size.Y / 2
    if postHeight > MIN_EXTENT then
        local post = newPart({
            name = "PanelPost",
            size = Vector3.new(cp.postWidth, postHeight, cp.postWidth),
            cframe = frame * CFrame.new(localPos.X, postHeight / 2, localPos.Z),
            color = rgb(CFG.colors.post),
            material = Enum.Material.Metal,
            canCollide = false,
            parent = parent,
        })
        post.CanQuery = false
    end
    return panel, light
end

local function setStatusLight(light: BasePart?, status: string)
    if light then
        light.Color = rgb(CFG.colors.status[status] or CFG.colors.status.idle)
        light:SetAttribute("Status", status)
    end
end

local function registerAnchor(id: string, part: BasePart)
    part:SetAttribute("AnchorId", id)
    anchors[id] = part
end

local function newPad(
    name: string,
    size: Vector3,
    frame: CFrame,
    color: Color3,
    parent: Instance
): Part
    return newPart({
        name = name,
        size = size,
        cframe = frame * CFrame.new(0, size.Y / 2, 0),
        color = color,
        material = Enum.Material.SmoothPlastic,
        canCollide = false,
        parent = parent,
    })
end

-- 표시 바닥 넓이 바깥, frame 로컬 방향 (nx, nz) 쪽 면 가장자리에서 gap만큼 떨어진 자리 (지면 높이)
local function outsideFace(
    frame: CFrame,
    half: Vector3,
    nx: number,
    nz: number,
    gap: number,
    depth: number,
    lateral: number
): CFrame
    local along = if nx ~= 0 then half.X else half.Z
    local normal = Vector3.new(nx, 0, nz)
    local tangent = Vector3.new(-nz, 0, nx)
    local p = normal * (along + gap + depth / 2) + tangent * lateral
    local world = frame * CFrame.new(p)
    local h = terrainHeight(world.Position.X, world.Position.Z, frame.Position.Y)
    local y = if h then h + CFG.ground.lift else frame.Position.Y
    return CFrame.new(world.Position.X, y, world.Position.Z) * frame.Rotation
end

-- 대피처 (착륙선, 에어록) --------------------------------------------------

local function buildShelter(id: string, parent: Instance)
    local spec = CFG.shelters[id]
    local info = markers[spec.marker]
    if not info then
        warnOnce(
            "shelter:" .. id,
            spec.marker .. " 표시가 없어 " .. id .. " 대피처를 만들지 않습니다"
        )
        return
    end
    local model = newModel(spec.model, parent)
    model:SetAttribute("ShelterId", id)
    local yaw = facingYaw(info, spec.faceToward)
    local base = yawFrame(info.position, groundY(info, "max"), yaw)
    local foot = footprintIn(info, base)
    local footX = math.max(foot.X, spec.minFootprint)
    local footZ = math.max(foot.Z, spec.minFootprint)
    local frame = buildFoundation(model, base, footX, footZ, "Floor")

    local visual, source = MissionWorld.resolveAsset(spec.role)
    visual.Name = "Visual"
    fitIntoFrame(
        visual,
        frame,
        { X = footX, Z = footZ, Y = math.max(foot.Y, spec.minHeight) },
        spec.minHeight
    )
    makeWalkIn(visual, if source == "placeholder" then CFG.hutSolid else CFG.farm.walkable)
    visual.Parent = model
    local lo, hi = boundsIn(visual, frame)
    lo = Vector3.new(lo.X, 0, lo.Z)
    local shape = if info.shape == "Cylinder" and source ~= "placeholder" then "octagon" else "box"
    local _, door, zoneMin, zoneMax, doorZ =
        buildEntry(model, frame, lo, hi, shape, true, spec.signKey)

    local e = CFG.entry
    local zone = newMarker(
        "OxygenZone",
        zoneMax - zoneMin,
        frame * CFrame.new((zoneMin + zoneMax) / 2),
        model
    )
    zone:AddTag(CFG.zoneTag)
    zone:SetAttribute("ZoneId", id)
    zone:SetAttribute("ZoneKind", spec.zoneKind)

    local shelter: Shelter = {
        id = id,
        model = model,
        frame = frame,
        door = door,
        zone = zone,
        console = nil,
        panel = nil,
        light = nil,
        inside = frame * CFrame.new(0, e.insideHeight, (doorZ + hi.Z) / 2),
    }
    if spec.console then
        local size = vec(CFG.console.size)
        local console = newPart({
            name = "Console",
            size = size,
            cframe = frame
                * CFrame.new(0, size.Y / 2, hi.Z - e.zoneInset - CFG.console.backGap - size.Z / 2),
            color = rgb(CFG.colors.console),
            material = Enum.Material.Metal,
            parent = model,
        })
        shelter.console = console
        registerAnchor("console", console)
    end
    if spec.panel then
        local cp = CFG.controlPanel
        local panelSize = vec(cp.size)
        local x = e.doorGap / 2 + cp.sideGap + panelSize.X / 2
        local z = lo.Z - e.wallThickness - cp.wallGap - panelSize.Z / 2
        local panel, light = buildControlPanel(
            model,
            frame,
            Vector3.new(x, cp.height, z),
            Vector3.new(0, 0, -1),
            id,
            "facility." .. id .. ".name"
        )
        shelter.panel = panel
        shelter.light = light
        registerAnchor(id .. "Panel", panel)
    end
    shelters[id] = shelter
end

local function applyAirlockLook()
    local shelter = shelters.airlock
    if not shelter then
        return
    end
    local kind = CFG.airlockZoneKinds[airlockStatus] or "shelter"
    shelter.zone:SetAttribute("ZoneKind", kind)
    shelter.model:SetAttribute("Status", airlockStatus)
    setStatusLight(shelter.light, airlockStatus)
end

-- 태양광 판 ---------------------------------------------------------------

local function slotCount(options: BaseOptions): number
    if options.panelSlots then
        return options.panelSlots
    end
    local missionId = currentMission or "C"
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local module = shared and shared:FindFirstChild("MissionConfig")
    if module and module:IsA("ModuleScript") then
        local ok, config = pcall(require, module)
        local m = ok
            and typeof(config) == "table"
            and config.MISSIONS
            and config.MISSIONS[missionId]
        if m and m.panels and typeof(m.panels.total) == "number" then
            return m.panels.total
        end
    end
    local spec = CFG.missions[missionId]
    return if spec then spec.panelSlots else 0
end

local function buildSolarField(parent: Instance, count: number)
    local s = CFG.solar
    local info = markers[s.marker]
    if not info then
        warnOnce(
            "solar",
            s.marker .. " 표시가 없어 태양광 슬롯을 만들지 않습니다"
        )
        return
    end
    local field = newModel("SolarField", parent)
    local frame = yawFrame(info.position, groundY(info, "min"), info.yaw)
    local foot = footprintIn(info, frame)
    local grid = WorldMath.slotGrid(foot.X, foot.Z, count, s.margin, s.gap)
    -- 설치 자리: orderFrom 쪽 면 바깥
    local target = markers[s.orderFrom]
    local dir = if target
        then frame:VectorToObjectSpace(target.position - info.position)
        else Vector3.zAxis
    local nx, nz = WorldMath.faceToward(foot.X / 2, foot.Z / 2, dir.X, dir.Z)
    local padSize = vec(s.installPadSize)
    local padFrame = outsideFace(frame, foot / 2, nx, nz, s.installPadGap, padSize.Z, 0)
    local pad = newPad("InstallPad", padSize, padFrame, rgb(CFG.colors.pad), field)
    registerAnchor("installPad", pad)
    -- 가까운 슬롯부터 1번 (설치 자리 기준)
    local items = {}
    for _, cell in grid do
        local world = frame * Vector3.new(cell.x, 0, cell.z)
        table.insert(
            items,
            { name = string.format("%04d", cell.index), position = world, cell = cell }
        )
    end
    local byName = {}
    for _, item in items do
        byName[item.name] = item
    end
    local ordered = WorldMath.sortByDistance(items, xz(pad.CFrame.Position))
    local folder = childFolder(field, "Slots")
    table.clear(slots)
    for i, entry in ordered do
        local cell = byName[entry.name].cell
        local cellFrame = frame * CFrame.new(cell.x, 0, cell.z)
        local samples =
            footprintSamples(cellFrame, cell.sizeX / 2, cell.sizeZ / 2, frame.Position.Y)
        local top = WorldMath.groundFromSamples(samples, "max", frame.Position.Y) + CFG.ground.lift
        local slot = newPart({
            name = "Slot" .. i,
            size = Vector3.new(cell.sizeX, s.slotThickness, cell.sizeZ),
            cframe = CFrame.new(
                cellFrame.Position.X,
                top + s.slotThickness / 2,
                cellFrame.Position.Z
            ) * frame.Rotation,
            color = rgb(CFG.colors.slot),
            canCollide = false,
            parent = folder,
        })
        slot:SetAttribute("SlotIndex", i)
        table.insert(slots, slot)
    end
    childFolder(field, "Panels")
end

local function setRiser(riser: Riser, offset: number)
    riser.offset = offset
    riser.model:PivotTo(riser.pivot + Vector3.new(0, offset, 0))
end

-- risers를 targets(세로 오프셋)까지 seconds 동안 부드럽게 옮긴다. stillValid가 거짓이 되면 멈춘다.
-- onDone은 끝까지 옮겼을 때만 부른다 (멈추면 부르지 않는다)
local function animateRisers(
    risers: { Riser },
    targets: { number },
    seconds: number,
    stillValid: () -> boolean,
    onDone: (() -> ())?
)
    local froms = {}
    for i, riser in risers do
        froms[i] = riser.offset
    end
    if seconds <= 0 then
        for i, riser in risers do
            setRiser(riser, targets[i])
        end
        if onDone then
            onDone()
        end
        return
    end
    task.spawn(function()
        local steps = math.max(1, math.ceil(seconds * CFG.animation.hz))
        for step = 1, steps do
            task.wait(seconds / steps)
            if not stillValid() then
                return
            end
            local alpha = step / steps
            local eased = 1 - (1 - alpha) * (1 - alpha)
            for i, riser in risers do
                if riser.model.Parent ~= nil then
                    setRiser(riser, WorldMath.lerp(froms[i], targets[i], eased))
                end
            end
        end
        if onDone then
            onDone()
        end
    end)
end

local function spawnPanel(index: number, animate: boolean)
    local slot = slots[index]
    local field = runtime and runtime:FindFirstChild("Base")
    field = field and field:FindFirstChild("SolarField")
    local folder = field and field:FindFirstChild("Panels")
    if not slot or not folder then
        return
    end
    local s = CFG.solar
    local panel = MissionWorld.resolveAsset("SolarPanel")
    panel.Name = "Panel" .. index
    local top = slot.CFrame * CFrame.new(0, slot.Size.Y / 2, 0)
    fitIntoFrame(
        panel,
        top,
        { X = slot.Size.X * s.fill, Z = slot.Size.Z * s.fill, Y = s.panelMaxHeight }
    )
    -- [2026-11-15 시험 피드백] 설치한 패널은 로버를 막는다(충돌). RoverHazard 태그라 세게 부딪히면 로버 충돌 파손 1회
    -- (RoverFleet 수동 충돌 판정과 같은 경로, 패널은 고정이라 부서지지 않는다). 솟아오르는 동안만 충돌을 끈다
    setStatic(panel, true)
    panel:AddTag(s.hazardTag)
    panel:SetAttribute("SlotIndex", index)
    panel.Parent = folder
    local riser: Riser = {
        model = panel,
        pivot = panel:GetPivot(),
        height = CFG.animation.panelSink,
        offset = 0,
        exitFrame = top,
        exitMode = "nearest",
        exitClearance = CFG.eject.panelClearance,
    }
    panelRisers[index] = riser
    local function solidNow()
        setStatic(panel, true)
        ejectFromRiser(riser)
    end
    if animate then
        setStatic(panel, false)
        setRiser(riser, -CFG.animation.panelSink)
        local myGeneration = generation
        animateRisers({ riser }, { 0 }, CFG.animation.panelRiseSeconds, function()
            return myGeneration == generation and panelRisers[index] == riser
        end, solidNow)
    else
        solidNow()
    end
end

-- 설치된 패널 수만큼 슬롯 1..count에 패널을 둔다 (새로 생긴 것만 솟아오른다, 줄면 지운다)
function MissionWorld.setPanelCount(count: number)
    local target = math.clamp(math.floor(count), 0, #slots)
    for i = #slots, target + 1, -1 do
        local riser = panelRisers[i]
        if riser then
            riser.model:Destroy()
            panelRisers[i] = nil
        end
    end
    for i = 1, target do
        if not panelRisers[i] then
            spawnPanel(i, basePlaced)
        end
    end
    panelCount = math.max(0, math.floor(count))
end

function MissionWorld.panelSlots(): { BasePart }
    return table.clone(slots)
end

-- 물탱크, 로버 주차, 출구, 재배 공간 자리, 얼음 --------------------------------

local function iceMarkerNames(): { string }
    local names = {}
    for name in markers do
        if string.match(name, CFG.icePattern) then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local function iceCentroid(): Vector3?
    local names = iceMarkerNames()
    if #names == 0 then
        return nil
    end
    local sum = Vector3.zero
    for _, name in names do
        sum += markers[name].position
    end
    return sum / #names
end

-- 디자이너 에셋의 원래 충돌 설정은 두고 고정만 한다
local function anchorOnly(model: Instance)
    forEachPart(model, function(part)
        part.Anchored = true
        part.CanTouch = false
    end)
end

-- 이름이 prefix로 시작하는 첫 파트 (에셋 파트 이름에는 ".002" 같은 꼬리가 붙는다)
local function findPartByPrefix(root: Instance, prefix: string): BasePart?
    for _, d in root:GetDescendants() do
        if d:IsA("BasePart") and string.sub(d.Name, 1, #prefix) == prefix then
            return d
        end
    end
    return nil
end

-- 물탱크 frame: 로컬 Z를 표시의 긴 수평 변에, 뒤 끝(+Z)을 얼음 쪽으로. 표시 Attribute "Yaw"(도)가 있으면 그 방향
local function tankFrameFor(info: MarkerInfo, y: number): CFrame
    local attr = info.part:GetAttribute("Yaw")
    if typeof(attr) == "number" and attr == attr then
        return yawFrame(info.position, y, math.rad(attr))
    end
    local cf = info.cframe
    local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
    local back = Vector3.new(-cf.LookVector.X, 0, -cf.LookVector.Z)
    local long = if info.rendered.X >= info.rendered.Z then right else back
    if long.Magnitude < 1e-3 then
        long = Vector3.zAxis
    end
    long = long.Unit
    local centroid = iceCentroid()
    if centroid and (centroid - info.position):Dot(long) < 0 then
        long = -long
    end
    local origin = Vector3.new(info.position.X, y, info.position.Z)
    return CFrame.lookAt(origin, origin - long) -- LookVector = -long, 로컬 +Z = long
end

-- 에셋의 수평 긴 축이 X면 90도 돌려 Z로 (바닥 중심이 원점에 온다)
local function alignLongAxisZ(model: Model, ratio: number)
    bottomToOrigin(model)
    local lo, hi = boundsIn(model)
    local size = hi - lo
    if size.X > size.Z * ratio then
        model:PivotTo(CFrame.Angles(0, math.rad(90), 0) * model:GetPivot())
        bottomToOrigin(model)
    end
end

local function buildWaterTank(parent: Instance)
    local w = CFG.waterTank
    local info = markers[w.marker]
    if not info then
        warnOnce("tank", w.marker .. " 표시가 없어 물탱크를 만들지 않습니다")
        return
    end
    local model = newModel("WaterTank", parent)
    local base = tankFrameFor(info, groundY(info, "max"))
    local foot = footprintIn(info, base)
    local frame = buildFoundation(model, base, foot.X, foot.Z, "Foundation")
    local visual, source = MissionWorld.resolveAsset(w.role)
    visual.Name = "Visual"
    alignLongAxisZ(visual, w.longAxisRatio)
    local fill = if source == "asset" then w.assetFill else w.fill
    local factor = fitIntoFrame(visual, frame, { X = foot.X * fill, Z = foot.Z * fill, Y = foot.Y })
    if source == "asset" then
        anchorOnly(visual)
    else
        setStatic(visual, true)
    end
    visual.Parent = model
    local lo, hi = boundsIn(visual, frame)
    -- 착륙선 쪽 긴 옆면 (+1 = 로컬 +X)
    local side = 1
    local lander = markers.Lander
    if lander then
        side = if frame:VectorToObjectSpace(lander.position - info.position).X >= 0 then 1 else -1
    end
    tankInfo = { frame = frame, factor = factor, source = source, lo = lo, hi = hi, side = side }
    model:SetAttribute("AssetScale", factor)
    local half = foot / 2
    local padSize = vec(w.padSize)
    -- 하역 자리: 착륙선 쪽 긴 옆면 가운데 바깥. 자율주행 귀환 자리는 그 옆, 문(앞, -Z) 쪽으로
    local unloadFrame = outsideFace(frame, half, side, 0, w.padGap, padSize.X, 0)
    registerAnchor(
        "unloadPoint",
        newPad("UnloadPoint", padSize, unloadFrame, rgb(CFG.colors.pad), model)
    )
    local dockSize = vec(w.dockSize)
    local dockFrame = outsideFace(frame, half, side, 0, w.padGap, dockSize.X, -w.dockSide * side)
    registerAnchor(
        "roverDock",
        newPad("RoverDock", dockSize, dockFrame, rgb(CFG.colors.parkPad), model)
    )
    -- 파이프 착공 자리: 뒤 끝(+Z, 얼음 쪽) 바깥. 파이프가 붙을 탱크 축 가운데를 피해 착륙선 쪽 옆으로
    local pipeFrame = outsideFace(frame, half, 0, 1, w.padGap, padSize.Z, -side * w.pipeSpotSide)
    registerAnchor("pipeSpot", newPad("PipeSpot", padSize, pipeFrame, rgb(CFG.colors.pad), model))
end

local function buildRoverPark(parent: Instance)
    local r = CFG.roverPark
    local info = markers[r.marker]
    if not info then
        warnOnce("park", r.marker .. " 표시가 없어 로버 주차판을 만들지 않습니다")
        return
    end
    local model = newModel("RoverPark", parent)
    local target = markers[r.faceToward]
    local yaw = if target
        then WorldMath.yawToward(xz(info.position), xz(target.position))
        else info.yaw
    local base = yawFrame(info.position, groundY(info, "max"), info.yaw)
    local foot = footprintIn(info, base)
    local frame, slab =
        buildFoundation(model, base, foot.X, foot.Z, "ParkPad", rgb(CFG.colors.parkPad))
    registerAnchor("roverPark", slab)
    -- 로버가 설 자리: 판 윗면 중심, 출구 쪽을 본다 (RoverFleet이 roverParkCFrame()으로 읽는다)
    slab:SetAttribute("ParkYaw", math.deg(yaw))
    model:SetAttribute("TopY", frame.Position.Y)
end

local function buildExit(parent: Instance)
    local x = CFG.exit
    local info = markers[x.marker]
    if not info then
        warnOnce("exit", x.marker .. " 표시가 없어 출구 표시를 만들지 않습니다")
        return
    end
    local model = newModel("BaseExit", parent)
    local frame = yawFrame(info.position, groundY(info, "min") - CFG.ground.smallSink, info.yaw)
    local foot = footprintIn(info, frame)
    local postSize = vec(x.postSize)
    for _, sign in { -1, 1 } do
        local post = newPart({
            name = if sign < 0 then "PostLeft" else "PostRight",
            size = postSize,
            cframe = frame * CFrame.new(sign * foot.X / 2, postSize.Y / 2, 0),
            color = rgb(CFG.colors.post),
            material = Enum.Material.Metal,
            parent = model,
        })
        newPart({
            name = "Cap",
            size = Vector3.one * x.capSize,
            cframe = post.CFrame * CFrame.new(0, postSize.Y / 2 + x.capSize / 2, 0),
            color = rgb(CFG.colors.postCap),
            material = Enum.Material.Neon,
            canCollide = false,
            parent = model,
        })
    end
    local gate =
        newMarker("ExitPoint", Vector3.new(foot.X, 1, foot.Z), frame * CFrame.new(0, 0.5, 0), model)
    registerAnchor("exit", gate)
end

local function buildFarmSite(parent: Instance)
    local f = CFG.farm
    local info = markers[f.marker]
    if not info then
        warnOnce(
            "farm",
            f.marker .. " 표시가 없어 재배 공간 자리를 만들지 않습니다"
        )
        return
    end
    local model = newModel("FarmSite", parent)
    local yaw = facingYaw(info, f.faceToward)
    local frame = yawFrame(info.position, groundY(info, "max"), yaw)
    local foot = footprintIn(info, frame)
    farmFrame = frame
    farmHalf = foot / 2
    local padSize = vec(f.buildSpotSize)
    local spot = outsideFace(frame, farmHalf, 0, -1, f.buildSpotGap, padSize.Z, f.buildSpotSide)
    registerAnchor("buildSpot", newPad("BuildSpot", padSize, spot, rgb(CFG.colors.pad), model))
end

local iceSiteCache: { IceSite }? = nil

function MissionWorld.iceSites(): { IceSite }
    if iceSiteCache then
        return table.clone(iceSiteCache)
    end
    local items = {}
    for _, name in iceMarkerNames() do
        local info = markers[name]
        local p = Vector3.new(info.position.X, groundY(info, "average"), info.position.Z)
        table.insert(items, { name = name, position = p })
    end
    local from = markers[CFG.iceSortFrom] or markers.Lander
    local origin = if from then xz(from.position) else { X = 0, Z = 0 }
    local sorted = WorldMath.sortByDistance(items, origin)
    local function dist(markerName: string, p: Vector3): number
        local info = markers[markerName]
        return if info then WorldMath.horizontalDistance(xz(p), xz(info.position)) else 0
    end
    local result: { IceSite } = {}
    for _, entry in sorted do
        local p = entry.position :: Vector3
        table.insert(result, {
            index = entry.index,
            markerName = entry.name,
            position = p,
            distanceFromExit = dist("BaseExit", p),
            distanceFromRoverPark = dist("RoverPark", p),
            distanceFromLander = dist("Lander", p),
        })
    end
    iceSiteCache = result
    return table.clone(result)
end

-- Rules.newState options.iceDistances에 넘길 거리표 (정렬 기준 표시에서의 거리, 키는 표시 이름)
function MissionWorld.iceDistances(): { [string]: number }
    local result = {}
    for _, site in MissionWorld.iceSites() do
        local info = markers[CFG.iceSortFrom] or markers.Lander
        result[site.markerName] = if info
            then WorldMath.horizontalDistance(xz(site.position), xz(info.position))
            else 0
    end
    return result
end

-- 얼음 외형이 멀리서 보이지 않게: 네온은 표토 재질로, 빛은 끄고, 반짝이 효과는 끄고, 글자 GUI는 가까이서만
-- (디자이너 Assets.IceDeposit에 무엇이 들어 있어도 같은 규칙)
local function quietIceVisual(model: Instance, maxDistance: number)
    for _, d in model:GetDescendants() do
        if d:IsA("BasePart") then
            if d.Material == Enum.Material.Neon then
                d.Material = Enum.Material.Slate
            end
            d.Reflectance = 0
        elseif
            d:IsA("Light")
            or d:IsA("Highlight")
            or d:IsA("ParticleEmitter")
            or d:IsA("Sparkles")
            or d:IsA("Fire")
            or d:IsA("Smoke")
            or d:IsA("Beam")
            or d:IsA("Trail")
        then
            (d :: any).Enabled = false
        elseif d:IsA("BillboardGui") then
            d.MaxDistance = math.min(d.MaxDistance, maxDistance)
            d.AlwaysOnTop = false
        end
    end
end

-- 가까이에서만 보이는 이름표와 작은 반짝임 (BillboardGui.MaxDistance = revealDistance)
local function addIceReveal(point: BasePart)
    local i = CFG.ice
    local l = CFG.label
    local label = Instance.new("BillboardGui")
    label.Name = "Label"
    label.Size = UDim2.fromScale(l.width, l.height)
    label.StudsOffset = Vector3.new(0, i.labelOffset, 0)
    label.MaxDistance = i.revealDistance
    label.LightInfluence = 0
    label.AlwaysOnTop = false
    label.AutoLocalize = false
    label.Parent = point
    local text = keyedLabel(label, "world.ice_site.name", rgb(CFG.colors.labelText))
    text.TextStrokeTransparency = 0.4
    local glint = Instance.new("BillboardGui")
    glint.Name = "Glint"
    glint.Size = UDim2.fromScale(i.glintSize, i.glintSize)
    glint.StudsOffset = Vector3.new(0, i.glintOffset, 0)
    glint.MaxDistance = i.revealDistance
    glint.LightInfluence = 0
    glint.AlwaysOnTop = false
    glint.AutoLocalize = false
    glint.Parent = point
    local dot = Instance.new("Frame")
    dot.Name = "Dot"
    dot.Size = UDim2.fromScale(1, 1)
    dot.BackgroundColor3 = rgb(CFG.colors.iceGlint)
    dot.BackgroundTransparency = i.glintTransparency
    dot.BorderSizePixel = 0
    dot.Parent = glint
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = dot
end

local function buildIceSites(parent: Instance)
    local i = CFG.ice
    local folder = childFolder(parent, "IceSites")
    for _, site in MissionWorld.iceSites() do
        local info = markers[site.markerName]
        local model = newModel(site.markerName, folder)
        model:SetAttribute("SiteIndex", site.index)
        model:SetAttribute("MarkerName", site.markerName)
        local frame = yawFrame(info.position, groundY(info, "min") - CFG.ground.smallSink, info.yaw)
        local foot = footprintIn(info, frame)
        -- 표토에 섞인 얼음: 낮은 덩어리 무리를 맞춘 뒤 대부분 땅에 묻는다 (지면 위로 약 1만 보인다)
        local deposit = MissionWorld.resolveAsset(i.role)
        deposit.Name = "Deposit"
        fitIntoFrame(deposit, frame, { X = foot.X * i.fill, Z = foot.Z * i.fill, Y = i.maxHeight })
        local dlo, dhi = boundsIn(deposit)
        translate(deposit, Vector3.new(0, -(dhi.Y - dlo.Y) * i.buryRatio, 0))
        setStatic(deposit, false)
        quietIceVisual(deposit, i.revealDistance)
        deposit.Parent = model
        local point = newMarker(
            "MinePoint",
            Vector3.new(foot.X, 4, foot.Z),
            frame * CFrame.new(0, 2, 0),
            model
        )
        point:SetAttribute("SiteIndex", site.index)
        point:SetAttribute("MarkerName", site.markerName)
        addIceReveal(point)
    end
end

-- init, placeBase --------------------------------------------------------

local function hideMarker(part: BasePart)
    local m = CFG.markerRuntime
    if m.keepVisible[part.Name] then
        return
    end
    if m.hide then
        part.Transparency = 1
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.CastShadow = false
    end
end

local function ensureRuntime(): Folder
    local existing = workspace:FindFirstChild(CFG.runtimeFolder)
    if existing and existing:IsA("Folder") then
        for _, child in existing:GetChildren() do
            child:Destroy()
        end
        runtime = existing
        return existing
    end
    local folder = Instance.new("Folder")
    folder.Name = CFG.runtimeFolder
    folder.Parent = workspace
    runtime = folder
    return folder
end

local function clearState()
    generation += 1
    table.clear(shelters)
    table.clear(anchors)
    table.clear(slots)
    table.clear(panelRisers)
    table.clear(facilities)
    table.clear(looks)
    upgradeParts = { led = {}, hydroponics = {} }
    farmFrame = nil
    farmHalf = Vector3.zero
    tankInfo = nil
    basePlaced = false
end

-- 미션 표시를 읽고 실행용 폴더를 준비한다. 반환: 필수 표시가 모두 있는지, 없는 이름 목록
function MissionWorld.init(missionId: string): (boolean, { string })
    clearState()
    currentMission = missionId
    table.clear(markers)
    iceSiteCache = nil
    airlockStatus = "idle"
    panelCount = 0
    local spec = CFG.missions[missionId]
    local required = if spec then spec.required else {}
    local missing: { string } = {}
    local folder = workspace:FindFirstChild(CFG.markerFolderPrefix .. missionId)
    if not folder then
        warn(
            "[MissionWorld] Workspace."
                .. CFG.markerFolderPrefix
                .. missionId
                .. " 폴더가 없습니다"
        )
        -- 폴더 이름을 먼저 넣어 실패로 돌려준다 (필수 목록이 아직 없는 미션도)
        table.insert(missing, CFG.markerFolderPrefix .. missionId)
        for _, name in required do
            table.insert(missing, name)
        end
    else
        for _, child in folder:GetChildren() do
            if child:IsA("BasePart") then
                if CFG.markerRuntime.anchor then
                    child.Anchored = true
                end
                markers[child.Name] = readMarker(child)
            end
        end
        for _, name in required do
            if not markers[name] then
                table.insert(missing, name)
            end
        end
        local iceCount = #iceMarkerNames()
        if iceCount == 0 then
            table.insert(missing, "Ice1")
        elseif spec and iceCount < spec.iceExpected then
            warn(
                string.format(
                    "[MissionWorld] 얼음 표시가 %d개뿐입니다 (기대 %d)",
                    iceCount,
                    spec.iceExpected
                )
            )
        end
        for _, info in markers do
            hideMarker(info.part)
        end
    end
    if #missing > 0 then
        warn("[MissionWorld] 없는 표시: " .. table.concat(missing, ", "))
    end
    ensureRuntime()
    local previewFolder = workspace:FindFirstChild(CFG.previewFolder)
    if previewFolder then
        preview = previewFolder
        previewFolder.Parent = nil
    end
    return #missing == 0, missing
end

-- 두 표시 사이 곧은 수평 길이 태양광 판(SolarField 표시 바닥 넓이)을 지나는지. 표시가 없으면 nil
function MissionWorld.pathCrossesSolarField(fromName: string, toName: string): boolean?
    local field = markers[CFG.solar.marker]
    local a = markers[fromName]
    local b = markers[toName]
    if not field or not a or not b then
        return nil
    end
    local frame = yawFrame(field.position, field.position.Y, field.yaw)
    local foot = footprintIn(field, frame)
    local pa = frame:PointToObjectSpace(a.position)
    local pb = frame:PointToObjectSpace(b.position)
    return WorldMath.segmentHitsBox(
        { X = pa.X, Z = pa.Z },
        { X = pb.X, Z = pb.Z },
        foot.X / 2,
        foot.Z / 2
    )
end

-- 기지 고정 구조물을 놓는다 (init 뒤에). 다시 부르면 기지만 새로 만든다
function MissionWorld.placeBase(options: BaseOptions?)
    local root = runtime
    if not root then
        warn("[MissionWorld] init 전에 placeBase를 불렀습니다")
        return
    end
    baseOptions = options or {}
    local old = root:FindFirstChild("Base")
    if old then
        old:Destroy()
    end
    local old2 = root:FindFirstChild("IceSites")
    if old2 then
        old2:Destroy()
    end
    table.clear(shelters)
    table.clear(anchors)
    table.clear(slots)
    table.clear(panelRisers)
    tankInfo = nil
    local baseFolder = childFolder(root, "Base")
    safe("착륙선", function()
        buildShelter("lander", baseFolder)
    end)
    safe("에어록", function()
        buildShelter("airlock", baseFolder)
    end)
    safe("태양광 판", function()
        buildSolarField(baseFolder, slotCount(baseOptions))
    end)
    safe("물탱크", function()
        buildWaterTank(baseFolder)
    end)
    safe("로버 주차", function()
        buildRoverPark(baseFolder)
    end)
    safe("출구", function()
        buildExit(baseFolder)
    end)
    safe("재배 공간 자리", function()
        buildFarmSite(baseFolder)
    end)
    safe("얼음 지점", function()
        buildIceSites(root)
    end)
    childFolder(root, "Facilities")
    -- 설치한 패널은 로버를 막는다. 주차판에서 출구까지 곧은 길이 태양광 판을 지나면 표시를 옮기지 않고 알리기만 한다
    if MissionWorld.pathCrossesSolarField("RoverPark", "BaseExit") then
        warnOnce(
            "roverPath",
            "RoverPark에서 BaseExit까지 곧은 길이 SolarField를 지납니다. 패널이 로버를 막으니 표시 위치를 확인하세요"
        )
    end
    applyAirlockLook()
    -- 패널 수가 이미 있으면 연출 없이 다시 놓는다
    basePlaced = false
    MissionWorld.setPanelCount(panelCount)
    basePlaced = true
end

-- 시설 ------------------------------------------------------------------

local function facilitiesFolder(): Instance?
    local root = runtime
    return root and childFolder(root, "Facilities")
end

local function newRiser(model: Model): Riser
    local lo, hi = boundsIn(model)
    return {
        model = model,
        pivot = model:GetPivot(),
        height = math.max(hi.Y - lo.Y, MIN_EXTENT),
        offset = 0,
    }
end

local function disableCollision(fac: Facility)
    if next(fac.collide) ~= nil then
        return
    end
    forEachPart(fac.container, function(part)
        fac.collide[part] = part.CanCollide
        part.CanCollide = false
    end)
end

local function restoreCollision(fac: Facility)
    for part, value in fac.collide do
        part.CanCollide = value
    end
    table.clear(fac.collide)
end

local function rememberLook(part: BasePart)
    if not looks[part] then
        looks[part] =
            { transparency = part.Transparency, material = part.Material, color = part.Color }
    end
end

-- look: "on" | "hidden" | "dim"
local function applyLook(parts: { BasePart }, look: string)
    for _, part in parts do
        rememberLook(part)
        local base = looks[part]
        if look == "hidden" then
            part.Transparency = 1
        elseif look == "dim" then
            part.Transparency = base.transparency
            part.Material = Enum.Material.SmoothPlastic
            part.Color = base.color:Lerp(Color3.new(0, 0, 0), CFG.dimFactor)
        else
            part.Transparency = base.transparency
            part.Material = base.material
            part.Color = base.color
        end
    end
end

local function facilityOf(defId: string): Facility?
    for _, fac in facilities do
        if fac.defId == defId then
            return fac
        end
    end
    return nil
end

local function farmPaused(): boolean
    local farm = facilityOf("farm")
    return farm ~= nil and farm.paused
end

-- 그린하우스 안 업그레이드 파트: 가동이면 보이고, 멈춤이면 CFG.pausedUpgradeLook, 그 밖에는 숨김
local function refreshUpgradeLooks()
    for defId, parts in upgradeParts do
        local fac = facilityOf(defId)
        local look = "hidden"
        if fac and fac.status == "active" then
            if fac.paused or farmPaused() then
                look = if CFG.pausedUpgradeLook == "hide" then "hidden" else "dim"
            else
                look = "on"
            end
        end
        applyLook(parts, look)
    end
end

local function newFacility(id: string, defId: string, container: Model): Facility
    return {
        id = id,
        defId = defId,
        container = container,
        risers = {},
        collide = {},
        progress = 0,
        status = "building",
        paused = false,
        token = 0,
        panel = nil,
        light = nil,
        segments = {},
        siteIndex = nil,
        dimParts = {},
        origin = nil,
    }
end

-- 그린하우스에 LED 바와 수경 베드가 없으면 코드로 만든다 (키트, 대체 도형일 때)
local function ensureUpgradeParts(visual: Model, frame: CFrame, lo: Vector3, hi: Vector3)
    local f = CFG.farm
    local led, bed = {}, {}
    forEachPart(visual, function(part)
        if startsWithAny(part.Name, f.ledPrefixes) then
            table.insert(led, part)
        elseif startsWithAny(part.Name, f.hydroPrefixes) then
            table.insert(bed, part)
        end
    end)
    local cx, cz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
    local sx, sz = (hi.X - lo.X) * f.generatedSpread, (hi.Z - lo.Z) * f.generatedSpread
    local spots = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
    if #led == 0 then
        local size = vec(f.generatedLed.size)
        for i, s in spots do
            local part = newPart({
                name = f.ledPrefixes[1] .. (if i > 1 then "." .. i else ""),
                size = size,
                cframe = frame
                    * CFrame.new(cx + s[1] * sx, hi.Y * f.generatedLed.heightRatio, cz + s[2] * sz),
                color = rgb(CFG.colors.ledGlow),
                material = Enum.Material.Neon,
                canCollide = false,
                parent = visual,
            })
            table.insert(led, part)
        end
    end
    if #bed == 0 then
        local size = vec(f.generatedBed.size)
        for i, s in spots do
            local part = newPart({
                name = f.hydroPrefixes[1] .. (if i > 1 then "." .. i else ""),
                size = size,
                cframe = frame * CFrame.new(cx + s[1] * sx, size.Y / 2, cz + s[2] * sz),
                color = rgb(CFG.colors.bed),
                canCollide = false,
                parent = visual,
            })
            table.insert(bed, part)
        end
    end
    upgradeParts.led = led
    upgradeParts.hydroponics = bed
end

local function placeFarm(fac: Facility, parent: Instance): boolean
    local f = CFG.farm
    local info = markers[f.marker]
    local frame0 = farmFrame
    if not info or not frame0 then
        warnOnce("place:farm", f.marker .. " 표시가 없어 재배 공간을 놓지 못합니다")
        return false
    end
    local container = fac.container
    local half = farmHalf
    local frame = buildFoundation(container, frame0, half.X * 2, half.Z * 2, "Foundation")
    local visual = MissionWorld.resolveAsset(f.role)
    visual.Name = "Visual"
    fitIntoFrame(
        visual,
        frame,
        { X = half.X * 2 * f.fill, Z = half.Z * 2 * f.fill, Y = info.extents.Y * 2 }
    )
    makeWalkIn(visual, f.walkable)
    visual.Parent = container
    local lo, hi = boundsIn(visual, frame)
    lo = Vector3.new(lo.X, 0, lo.Z)
    buildEntry(container, frame, lo, hi, "box", false, nil)
    ensureUpgradeParts(visual, frame, lo, hi)
    forEachPart(visual, function(part)
        if startsWithAny(part.Name, f.cropPrefixes) then
            table.insert(fac.dimParts, part)
        end
    end)
    local e, cp = CFG.entry, CFG.controlPanel
    local panelSize = vec(cp.size)
    local panel, light = buildControlPanel(
        container,
        frame,
        Vector3.new(
            e.doorGap / 2 + cp.sideGap + panelSize.X / 2,
            cp.height,
            lo.Z - e.wallThickness - cp.wallGap
        ),
        Vector3.new(0, 0, -1),
        fac.id,
        "facility.farm.name"
    )
    fac.panel, fac.light = panel, light
    container.Parent = parent
    local riser = newRiser(container)
    riser.exitFrame = frame -- 정면(-Z, 착륙선 쪽)에 보이지 않는 벽의 출입 틈이 있다
    table.insert(fac.risers, riser)
    return true
end

local function placeUnit(fac: Facility, parent: Instance): boolean
    local spec = CFG.units[fac.defId]
    local frame0 = farmFrame
    if not spec or not frame0 then
        warnOnce(
            "place:" .. fac.defId,
            fac.defId .. " 장치를 놓을 재배 공간 자리가 없습니다"
        )
        return false
    end
    local size = vec(CFG.unitSize)
    local half, gap = farmHalf, CFG.unitGap
    local localPos: Vector3
    local outward: Vector3
    if spec.side == "left" then
        localPos = Vector3.new(-(half.X + gap + size.X / 2), 0, 0)
        outward = Vector3.new(-1, 0, 0)
    elseif spec.side == "right" then
        localPos = Vector3.new(half.X + gap + size.X / 2, 0, 0)
        outward = Vector3.xAxis
    else
        localPos = Vector3.new(0, 0, half.Z + gap + size.Z / 2)
        outward = Vector3.zAxis
    end
    -- 장치 정면(-Z)이 바깥을 보게
    local world = frame0 * CFrame.new(localPos)
    local base = CFrame.lookAt(world.Position, world.Position + frame0:VectorToWorldSpace(outward))
    local container = fac.container
    local frame = buildFoundation(container, base, size.X, size.Z, "Foundation")
    local visual = MissionWorld.resolveAsset(spec.role)
    visual.Name = "Visual"
    fitIntoFrame(visual, frame, { X = size.X * 0.9, Z = size.Z * 0.9, Y = size.Y })
    setStatic(visual, true)
    visual.Parent = container
    for _, part in visual:GetDescendants() do
        if part:IsA("BasePart") then
            table.insert(fac.dimParts, part)
        end
    end
    local cp = CFG.controlPanel
    local panelSize = vec(cp.size)
    local panel, light = buildControlPanel(
        container,
        frame,
        Vector3.new(0, cp.height, -size.Z / 2 - cp.wallGap - panelSize.Z / 2),
        Vector3.new(0, 0, -1),
        fac.id,
        "facility." .. fac.defId .. ".name"
    )
    fac.panel, fac.light = panel, light
    container.Parent = parent
    local riser = newRiser(container)
    riser.exitFrame = frame -- 장치 정면(-Z)은 그린하우스 바깥쪽
    table.insert(fac.risers, riser)
    return true
end

-- 파이프: 물탱크 뒤 끝 연결관(TankPipe) + 얼음 지점 우물머리 + 받침에서 얼음 지점까지 반쯤 묻힌 관로
local function buildPipeline(fac: Facility, siteIndex: number)
    local p = CFG.pipe
    local site = MissionWorld.iceSites()[siteIndex]
    local stationRiser = fac.risers[1]
    if not site or not stationRiser then
        warnOnce(
            "pipe:site" .. tostring(siteIndex),
            "얼음 지점 " .. tostring(siteIndex) .. "이 없어 관로를 만들지 않습니다"
        )
        return
    end
    -- 이전 관로와 우물머리 정리 (멈춤 표시 목록과 원래 모습 기록에서도 뺀다)
    local removed: { [Instance]: boolean } = {}
    for _, segment in fac.segments do
        removed[segment] = true
        looks[segment] = nil
        segment:Destroy()
    end
    table.clear(fac.segments)
    for i = #fac.risers, 2, -1 do
        for _, d in fac.risers[i].model:GetDescendants() do
            if d:IsA("BasePart") then
                removed[d] = true
                looks[d] = nil
            end
        end
        fac.risers[i].model:Destroy()
        table.remove(fac.risers, i)
    end
    local kept = {}
    for _, part in fac.dimParts do
        if not removed[part] then
            table.insert(kept, part)
        end
    end
    fac.dimParts = kept
    fac.siteIndex = siteIndex
    local container = fac.container
    local info = markers[site.markerName]
    -- 관로 시작점: 연결관 받침 바닥 중심 (없으면 연결관 바닥 중심, 땅속에 있으면 오프셋만큼 되돌린다)
    local stationPos = fac.origin
    if not stationPos then
        local slo, shi = boundsIn(stationRiser.model)
        stationPos =
            Vector3.new((slo.X + shi.X) / 2, slo.Y - stationRiser.offset, (slo.Z + shi.Z) / 2)
    end
    -- 우물머리: 얼음 지점 중심, 기지 쪽을 본다
    local yaw = WorldMath.yawToward(xz(site.position), xz(stationPos))
    local whFrame = yawFrame(site.position, groundY(info, "min") - CFG.ground.smallSink, yaw)
    local wellhead = newModel("Wellhead", container)
    local whSize = vec(p.wellheadSize)
    local visual = MissionWorld.resolveAsset(p.wellheadRole)
    visual.Name = "Visual"
    fitIntoFrame(visual, whFrame, { X = whSize.X, Z = whSize.Z, Y = whSize.Y })
    setStatic(visual, true)
    visual.Parent = wellhead
    forEachPart(visual, function(part)
        table.insert(fac.dimParts, part)
    end)
    local whRiser = newRiser(wellhead)
    whRiser.exitFrame = whFrame -- 우물머리 정면은 기지 쪽
    table.insert(fac.risers, whRiser)
    -- 관로: 펌프장에서 우물머리까지 segmentLength 간격, 점마다 지면 높이
    local points = WorldMath.pathPoints(xz(stationPos), xz(site.position), p.segmentLength)
    local line = newModel("Pipeline", container)
    local prev: Vector3? = nil
    for _, point in points do
        local h = terrainHeight(point.X, point.Z, stationPos.Y)
        local y = (h or WorldMath.lerp(stationPos.Y, site.position.Y, 0.5)) + p.lift
        local current = Vector3.new(point.X, y, point.Z)
        if prev then
            local length = (current - prev).Magnitude
            if length > MIN_EXTENT then
                local mid = (prev + current) / 2
                local segment = newPart({
                    name = "Segment" .. (#fac.segments + 1),
                    shape = Enum.PartType.Cylinder,
                    size = Vector3.new(length + p.radius, p.radius * 2, p.radius * 2),
                    cframe = CFrame.lookAt(mid, current) * CFrame.Angles(0, math.rad(90), 0),
                    color = rgb(CFG.colors.pipe),
                    material = Enum.Material.Metal,
                    canCollide = false,
                    parent = line,
                })
                segment.CanQuery = false
                table.insert(fac.segments, segment)
                table.insert(fac.dimParts, segment)
            end
        end
        prev = current
    end
    -- 지금 상태에 맞춰 우물머리 높이와 보이는 구간
    setRiser(
        whRiser,
        if fac.status == "active" then 0 else WorldMath.riseOffset(whRiser.height, fac.progress)
    )
end

local function refreshSegments(fac: Facility)
    local visible = if fac.status == "active"
        then #fac.segments
        else WorldMath.visibleSegments(#fac.segments, fac.progress)
    for i, segment in fac.segments do
        segment.Transparency = if i <= visible then 0 else 1
    end
end

local function placePipe(fac: Facility, parent: Instance, siteIndex: number?): boolean
    local p = CFG.pipe
    local tank = tankInfo
    if not tank or not anchors.pipeSpot then
        warnOnce("place:pipe", "물탱크가 없어 파이프를 놓지 못합니다")
        return false
    end
    local container = fac.container
    local frame = tank.frame
    local model = newModel("TankPipe", container)
    local visual, source = MissionWorld.resolveAsset(p.role)
    visual.Name = "Visual"
    bottomToOrigin(visual)
    -- 크기: 디자이너 에셋끼리는 같은 단위라 탱크와 같은 배율. 아니면 대체 크기에 맞춘다
    if source == "asset" and tank.source == "asset" then
        scaleBy(visual, tank.factor)
    else
        local lo, hi = boundsIn(visual)
        local box = vec(p.stationSize)
        scaleBy(visual, WorldMath.fitScale(hi - lo, { X = box.X, Z = box.Z, Y = box.Y }))
    end
    bottomToOrigin(visual)
    local ring = findPartByPrefix(visual, p.ringPrefix)
    local groundPart = findPartByPrefix(visual, p.basePrefix)
    -- 고리(없으면 탱크 축 방향 그대로)가 탱크 쪽(frame -Z)을 보게 원점 둘레로 돌린다
    local towardTank = frame:VectorToWorldSpace(Vector3.new(0, 0, -1))
    local ringDir = Vector3.zero
    if ring then
        local mlo, mhi = boundsIn(visual)
        local rlo, rhi = boundsIn(ring)
        local rel = (rlo + rhi) / 2 - (mlo + mhi) / 2
        ringDir = Vector3.new(rel.X, 0, rel.Z)
    end
    if ringDir.Magnitude > MIN_EXTENT then
        local turn = WorldMath.yawOfDirection(towardTank.X, towardTank.Z)
            - WorldMath.yawOfDirection(ringDir.X, ringDir.Z)
        visual:PivotTo(CFrame.Angles(0, turn, 0) * visual:GetPivot())
    else
        visual:PivotTo(frame.Rotation * visual:GetPivot())
    end
    translate(visual, frame.Position)
    -- 고리의 탱크 쪽 끝을 탱크 뒤 끝 면(frame 로컬 z = hi.Z)에, 가운데를 탱크 축에 맞춘다.
    -- 둘째 파이프부터는 파이프 착공 자리 반대쪽 옆으로 비켜 놓는다
    local contact: Instance = ring or visual
    local clo, chi = boundsIn(contact, frame)
    local vlo, vhi = boundsIn(visual, frame)
    local lateral = -tank.side
        * (WorldMath.facilityIndex(fac.id) - 1)
        * (vhi.X - vlo.X + p.lateralStep)
    translate(
        visual,
        frame:VectorToWorldSpace(Vector3.new(lateral - (clo.X + chi.X) / 2, 0, tank.hi.Z - clo.Z))
    )
    -- 높이: 받침 밑면을 그 자리 지면에. 고리가 탱크 높이 범위를 벗어나면 그 안으로 자른다
    local blo, bhi = boundsIn(groundPart or visual)
    local ground = terrainHeight((blo.X + bhi.X) / 2, (blo.Z + bhi.Z) / 2, frame.Position.Y)
    local dy = (ground or frame.Position.Y) - blo.Y
    if ring then
        local r0, r1 = boundsIn(ring)
        local low = frame.Position.Y + tank.lo.Y + p.ringMargin
        local high = frame.Position.Y + tank.hi.Y - p.ringMargin
        if r0.Y + dy < low then
            dy = low - r0.Y
        elseif r1.Y + dy > high then
            dy = high - r1.Y
        end
    end
    translate(visual, Vector3.new(0, dy, 0))
    if source == "asset" then
        anchorOnly(visual)
    else
        setStatic(visual, true)
    end
    visual.Parent = model
    forEachPart(visual, function(part)
        table.insert(fac.dimParts, part)
    end)
    local glo, ghi = boundsIn(groundPart or visual)
    fac.origin = Vector3.new((glo.X + ghi.X) / 2, glo.Y, (glo.Z + ghi.Z) / 2)
    -- 제어반: 파이프 옆, 파이프 착공 자리 쪽을 본다
    local cp = CFG.controlPanel
    local panelSize = vec(cp.size)
    vlo, vhi = boundsIn(visual, frame)
    local localPos = Vector3.new(
        (vlo.X + vhi.X) / 2 + tank.side * ((vhi.X - vlo.X) / 2 + cp.sideGap + panelSize.Z / 2),
        0,
        (vlo.Z + vhi.Z) / 2
    )
    local world = frame * localPos
    local h = terrainHeight(world.X, world.Z, frame.Position.Y)
    local panelFrame = CFrame.new(world.X, h or frame.Position.Y, world.Z) * frame.Rotation
    local panel, light = buildControlPanel(
        model,
        panelFrame,
        Vector3.new(0, cp.height, 0),
        Vector3.new(tank.side, 0, 0),
        fac.id,
        "facility.pipe.name"
    )
    fac.panel, fac.light = panel, light
    container.Parent = parent
    local riser = newRiser(model)
    -- 연결관은 탱크 뒤 끝에 붙는다. 정면(-Z)을 탱크 반대쪽(얼음 쪽)으로 둔 frame
    riser.exitFrame = CFrame.lookAt(frame.Position, frame.Position - frame.LookVector)
    table.insert(fac.risers, riser)
    if siteIndex then
        buildPipeline(fac, siteIndex)
    end
    return true
end

-- 시설을 건설 시작 상태(진행 0, 땅속)로 놓는다. 이미 있으면 true만 돌려준다.
-- facilityId는 Rules 인스턴스 id(farm, led, nutrient, hydroponics, pipe1, pipe2 ...). options.siteIndex는 파이프 얼음 지점
function MissionWorld.place(facilityId: string, options: { siteIndex: number? }?): boolean
    if facilities[facilityId] then
        return true
    end
    local parent = facilitiesFolder()
    if not parent then
        warn("[MissionWorld] init 전에 place를 불렀습니다: " .. facilityId)
        return false
    end
    local defId = WorldMath.facilityDefId(facilityId)
    if defId == "airlock" then
        return true -- 에어록 건물은 placeBase가 이미 놓았다 (상태는 setAirlockStatus)
    end
    local container = newModel(facilityId, nil)
    container:SetAttribute("FacilityId", facilityId)
    container:SetAttribute("DefId", defId)
    local fac = newFacility(facilityId, defId, container)
    local okPlace, placed = pcall(function(): boolean
        if defId == "farm" then
            return placeFarm(fac, parent)
        elseif defId == "pipe" then
            return placePipe(fac, parent, options and options.siteIndex)
        elseif CFG.units[defId] then
            return placeUnit(fac, parent)
        end
        warnOnce(
            "place:unknown:" .. defId,
            "모르는 시설 " .. facilityId .. "은 놓지 않습니다"
        )
        return false
    end)
    if not okPlace or not placed then
        if not okPlace then
            warn("[MissionWorld] " .. facilityId .. " 배치 실패: " .. tostring(placed))
        end
        container:Destroy()
        return false
    end
    facilities[facilityId] = fac
    disableCollision(fac)
    for _, riser in fac.risers do
        setRiser(riser, WorldMath.riseOffset(riser.height, 0))
    end
    refreshSegments(fac)
    setStatusLight(fac.light, "building")
    container:SetAttribute("Status", "building")
    refreshUpgradeLooks()
    return true
end

-- 파이프가 연결될 얼음 지점을 정하거나 바꾼다 (관로와 우물머리를 다시 만든다)
function MissionWorld.setPipeSite(facilityId: string, siteIndex: number): boolean
    local fac = facilities[facilityId]
    if not fac or fac.defId ~= "pipe" then
        return false
    end
    local wasCollide = next(fac.collide) ~= nil
    restoreCollision(fac)
    buildPipeline(fac, siteIndex)
    if wasCollide then
        disableCollision(fac)
    elseif fac.status == "active" then
        -- 가동 중에 지점을 바꾸면 새 우물머리가 바로 단단해진다
        for i = 2, #fac.risers do
            ejectFromRiser(fac.risers[i])
        end
    end
    if fac.paused then
        applyLook(fac.dimParts, "dim")
    end
    refreshSegments(fac)
    return true
end

-- 건설 진행률 0..1. 시설이 땅에서 진행률만큼 솟아오른다(riseSeconds 동안 부드럽게). 없으면 먼저 place
function MissionWorld.setBuildProgress(facilityId: string, progress: number, instant: boolean?)
    if WorldMath.facilityDefId(facilityId) == "airlock" then
        MissionWorld.setAirlockStatus("inspecting") -- 에어록 건물은 이미 있다. 점검 중 표시만
        return
    end
    if not facilities[facilityId] and not MissionWorld.place(facilityId) then
        return
    end
    local fac = facilities[facilityId]
    if not fac then
        return
    end
    fac.progress = WorldMath.clamp01(progress)
    if fac.status ~= "building" then
        fac.status = "building"
        fac.paused = false
        disableCollision(fac)
        setStatusLight(fac.light, "building")
        fac.container:SetAttribute("Status", "building")
        refreshUpgradeLooks()
    end
    fac.token += 1
    local token, myGeneration = fac.token, generation
    local targets = {}
    for i, riser in fac.risers do
        targets[i] = WorldMath.riseOffset(riser.height, fac.progress)
    end
    animateRisers(fac.risers, targets, if instant then 0 else CFG.animation.riseSeconds, function()
        return fac.token == token and myGeneration == generation
    end)
    refreshSegments(fac)
end

-- 가동 시작(true): 완공 위치에 붙이고 충돌을 되돌린다. false면 건설 중 상태로 돌아간다
function MissionWorld.setActive(facilityId: string, active: boolean)
    if WorldMath.facilityDefId(facilityId) == "airlock" then
        MissionWorld.setAirlockStatus(if active then "active" else "inspecting")
        return
    end
    if not facilities[facilityId] and not MissionWorld.place(facilityId) then
        return
    end
    local fac = facilities[facilityId]
    if not fac then
        return
    end
    fac.token += 1
    if active then
        fac.status = "active"
        fac.progress = 1
        for _, riser in fac.risers do
            setRiser(riser, 0)
        end
        restoreCollision(fac)
        -- 충돌이 켜지는 순간: 안에 있던 플레이어를 정면 바깥으로 (갇힘 방지)
        for _, riser in fac.risers do
            ejectFromRiser(riser)
        end
        setStatusLight(fac.light, if fac.paused then "paused" else "active")
        fac.container:SetAttribute("Status", if fac.paused then "paused" else "active")
    else
        fac.status = "building"
        fac.paused = false
        applyLook(fac.dimParts, "on")
        disableCollision(fac)
        for _, riser in fac.risers do
            setRiser(riser, WorldMath.riseOffset(riser.height, fac.progress))
        end
        setStatusLight(fac.light, "building")
        fac.container:SetAttribute("Status", "building")
    end
    refreshSegments(fac)
    refreshUpgradeLooks()
end

-- 멈춤 표시 (가동 중인 시설만): 표시등 주황, 장치와 작물 어둡게, LED와 수경은 CFG.pausedUpgradeLook
function MissionWorld.setPaused(facilityId: string, paused: boolean)
    if WorldMath.facilityDefId(facilityId) == "airlock" then
        if airlockStatus == "active" or airlockStatus == "paused" then
            MissionWorld.setAirlockStatus(if paused then "paused" else "active")
        end
        return
    end
    local fac = facilities[facilityId]
    if not fac or fac.status ~= "active" then
        return
    end
    fac.paused = paused
    applyLook(fac.dimParts, if paused then "dim" else "on")
    setStatusLight(fac.light, if paused then "paused" else "active")
    fac.container:SetAttribute("Status", if paused then "paused" else "active")
    refreshUpgradeLooks()
end

local function removeFacility(facilityId: string)
    local fac = facilities[facilityId]
    if not fac then
        return
    end
    fac.token += 1
    for _, part in fac.dimParts do
        looks[part] = nil
    end
    if fac.defId == "farm" then
        for _, parts in upgradeParts do
            for _, part in parts do
                looks[part] = nil
            end
        end
        upgradeParts = { led = {}, hydroponics = {} }
    end
    fac.container:Destroy()
    facilities[facilityId] = nil
    refreshUpgradeLooks()
end

-- 에어록 상태: "idle" | "inspecting" | "active" | "paused". 산소 구역 종류와 표시등을 맞춘다
function MissionWorld.setAirlockStatus(status: string)
    if CFG.airlockZoneKinds[status] == nil then
        warnOnce("airlock:" .. status, "모르는 에어록 상태 " .. status)
        return
    end
    airlockStatus = status
    applyAirlockLook()
end

function MissionWorld.getAirlockStatus(): string
    return airlockStatus
end

-- Rules 상태(state.facilities) 또는 MissionState.facilities를 그대로 넘기면 화면을 맞춘다.
-- 항목: status("building" | "active" | "paused" | "locked" | "available"), paused, daysLeft, buildDays, siteIndex, defId.
-- 목록에 없는 시설은 지운다. airlock 항목이 있을 때만 에어록 상태를 바꾼다 (없으면 그대로)
function MissionWorld.syncFacilities(list: { [string]: any })
    local seen: { [string]: boolean } = {}
    for id, f in list do
        local defId = f.defId or WorldMath.facilityDefId(id)
        local status = f.status
        local paused = f.paused == true or status == "paused"
        if defId == "airlock" then
            if status == "building" then
                MissionWorld.setAirlockStatus("inspecting")
            elseif status == "active" or status == "paused" then
                MissionWorld.setAirlockStatus(if paused then "paused" else "active")
            else
                MissionWorld.setAirlockStatus("idle")
            end
        elseif status == "building" or status == "active" or status == "paused" then
            seen[id] = true
            if MissionWorld.place(id, { siteIndex = f.siteIndex }) then
                local fac = facilities[id]
                if f.siteIndex and fac and fac.siteIndex ~= f.siteIndex then
                    MissionWorld.setPipeSite(id, f.siteIndex)
                end
                if status == "building" then
                    local progress = if typeof(f.buildDays) == "number"
                        then WorldMath.buildFraction(f.daysLeft or 0, f.buildDays)
                        else WorldMath.clamp01(f.progress or 0)
                    MissionWorld.setBuildProgress(id, progress)
                else
                    if fac and fac.status ~= "active" then
                        MissionWorld.setActive(id, true)
                    end
                    MissionWorld.setPaused(id, paused)
                end
            end
        end
    end
    for id in facilities do
        if not seen[id] then
            removeFacility(id)
        end
    end
end

-- 조회 ------------------------------------------------------------------

function MissionWorld.facilityModel(facilityId: string): Model?
    local fac = facilities[facilityId]
    return fac and fac.container
end

-- 시설 외벽 제어반 (Interactions가 멈춤 프롬프트를 붙인다)
function MissionWorld.controlPanel(facilityId: string): BasePart?
    if facilityId == "airlock" then
        local shelter = shelters.airlock
        return shelter and shelter.panel
    end
    local fac = facilities[facilityId]
    return fac and fac.panel
end

-- 테스트와 진단용: 시설의 지금 상태 요약
function MissionWorld.facilityInfo(facilityId: string): { [string]: any }?
    local fac = facilities[facilityId]
    if not fac then
        return nil
    end
    local offsets, heights = {}, {}
    for i, riser in fac.risers do
        offsets[i] = riser.offset
        heights[i] = riser.height
    end
    local visible = 0
    for _, segment in fac.segments do
        if segment.Transparency < 1 then
            visible += 1
        end
    end
    return {
        status = fac.status,
        paused = fac.paused,
        progress = fac.progress,
        offsets = offsets,
        heights = heights,
        segments = #fac.segments,
        visibleSegments = visible,
        siteIndex = fac.siteIndex,
    }
end

-- 그린하우스 업그레이드 파트 (defId "led" | "hydroponics")
function MissionWorld.upgradeParts(defId: string): { BasePart }
    return table.clone(upgradeParts[defId] or {})
end

function MissionWorld.getShelter(id: string): Shelter?
    return shelters[id]
end

-- 상호작용 자리: console, airlockPanel, installPad, buildSpot, unloadPoint, roverDock, pipeSpot, roverPark, exit
function MissionWorld.anchor(id: string): BasePart?
    return anchors[id]
end

function MissionWorld.anchors(): { [string]: BasePart }
    return table.clone(anchors)
end

function MissionWorld.getMarker(name: string): MarkerInfo?
    return markers[name]
end

function MissionWorld.runtimeFolder(): Folder?
    return runtime
end

-- 떼어 둔 편집용 미리보기 (없으면 nil)
function MissionWorld.previewReference(): Instance?
    return preview
end

-- 로버 주차 자리 (판 윗면 중심, 출구 쪽을 본다)
function MissionWorld.roverParkCFrame(): CFrame?
    local pad = anchors.roverPark
    if not pad then
        return nil
    end
    local yaw = pad:GetAttribute("ParkYaw")
    local top = pad.CFrame.Position + Vector3.new(0, pad.Size.Y / 2, 0)
    return CFrame.new(top)
        * CFrame.Angles(0, math.rad(if typeof(yaw) == "number" then yaw else 0), 0)
end

-- 기지 출구 (자율주행 로버가 사라지는 곳, 바깥 쪽을 본다)
function MissionWorld.exitCFrame(): CFrame?
    local exitPoint = anchors.exit
    if not exitPoint then
        return nil
    end
    return exitPoint.CFrame * CFrame.new(0, -exitPoint.Size.Y / 2, 0)
end

-- 산소 구역 파트 목록 (태그 OxygenZone, Attribute ZoneKind)
function MissionWorld.oxygenZones(): { BasePart }
    local result = {}
    for _, shelter in shelters do
        table.insert(result, shelter.zone)
    end
    return result
end

-- 위치의 산소 구역 종류: "refill" > "shelter" > "outside". 두 번째 값은 구역 id
function MissionWorld.zoneAt(position: Vector3): (string, string?)
    local best, bestId = "outside", nil
    for id, shelter in shelters do
        local zone = shelter.zone
        local p = zone.CFrame:PointToObjectSpace(position)
        if WorldMath.pointInBox(p, zone.Size) then
            local kind = zone:GetAttribute("ZoneKind")
            if kind == "refill" then
                return "refill", id
            elseif kind == "shelter" then
                best, bestId = "shelter", id
            end
        end
    end
    return best, bestId
end

-- 재시작: 연출을 멈추고 MissionRuntime을 비운다. rebuild가 false가 아니면 기지를 다시 놓는다.
-- MissionRuntime 안의 다른 모듈 것(로버, 프롬프트 파트)도 지워지므로 그 모듈은 reset 뒤 다시 붙인다.
-- 표시 숨김과 AssetPreview 떼기는 그대로 유지한다
function MissionWorld.reset(options: { rebuild: boolean? }?)
    local wasPlaced = basePlaced
    clearState()
    airlockStatus = "idle"
    panelCount = 0
    local root = runtime
    if root then
        for _, child in root:GetChildren() do
            child:Destroy()
        end
    end
    if wasPlaced and not (options and options.rebuild == false) then
        MissionWorld.placeBase(baseOptions)
    end
end

-- 테스트용 설정 읽기 (값을 바꾸지 않는다)
MissionWorld.CONFIG = CFG
MissionWorld.ROLES = ROLES

return MissionWorld
