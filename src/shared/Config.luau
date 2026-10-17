--!strict
-- The Frontier 설정 상수 모음 (GDD 4절, CONTRACT 6절)
-- 게임 로직에 쓰이는 모든 수치와 한국어 문구는 이 파일에서만 바꾼다.
-- 이 모듈은 Roblox 전역(Vector3, Color3, game 등)을 쓰지 않는다. Lune 테스트에서도 그대로 불러온다.

export type Cost = { energy: number, water: number }

export type ModuleDef = {
    name: string, -- CONTRACT 이름 (예: "Habitat")
    displayName: string, -- 화면 표시용 (예: "Habitat A")
    cost: Cost, -- 착공 시 즉시 차감
    buildDays: number, -- 건설 기간 (DayTick 횟수)
    upkeep: Cost, -- 가동 중 매일 유지 소비
    requires: { string }, -- 선행 모듈 id 목록
    foodPerDay: number, -- 가동 중 하루 식량 생산 (Farm만 0보다 큼)
}

export type SiteDef = {
    id: number,
    name: string,
    sunlight: number,
    iceDistanceLabel: string,
    hazardLabel: string,
    description: string,
}

local Config = {
    -- 시간
    DAY_SECONDS = 10, -- 게임 1일 = 현실 10초 (1배속)
    TOTAL_DAYS = 90,
    FAST_FORWARD = 2,
    SPEEDS = { 1, 2 }, -- SetSpeed로 허용되는 배속
    SPEED_COOLDOWN_SECONDS = 1, -- 플레이어별 SetSpeed 최소 간격(초)

    -- 인트로
    LANDING_SECONDS = 5,
    SITE_SELECT_TIMEOUT = 30,
    DEFAULT_SITE_ID = 2,

    -- 시작 자원 (착륙선)
    -- energy 50 = 착륙선 잔여 배터리. 첫 물 원정(약 6일)에서 돌아오면 Habitat A(60E)를 바로 착공할 수 있게
    -- (2026-10-17 밸런스 조정, tests/simulation.spec.luau 현실적 봇 기준)
    START = { energy = 50, water = 25, food = 30 },

    -- 크루 생명유지 (매일)
    CREW = { food = 1, water = 1 },

    -- 태양광 패널
    PANELS_TOTAL = 30,
    PANELS_PER_DAY = 3,
    PANEL_OUTPUT = 1, -- E/일/장, 착륙지 일조율을 곱한다
    PANEL_INSTALL_HOLD = 2,

    -- 모듈 (건설 순서 A -> B -> C)
    MODULES = {
        A = {
            name = "Habitat",
            displayName = "Habitat A",
            cost = { energy = 60, water = 20 },
            buildDays = 5,
            upkeep = { energy = 3, water = 1 },
            requires = {},
            foodPerDay = 0,
        },
        B = {
            name = "Farm",
            displayName = "Farm B",
            cost = { energy = 80, water = 30 },
            buildDays = 5,
            upkeep = { energy = 5, water = 2 },
            requires = { "A" },
            foodPerDay = 2,
        },
        C = {
            name = "Research Lab",
            displayName = "Research Lab C",
            cost = { energy = 150, water = 30 }, -- 물 40 -> 30: 최적 착륙지 승리를 45일 안으로 (후반 병목은 여전히 물)
            buildDays = 7,
            upkeep = { energy = 8, water = 1 },
            requires = { "A", "B" },
            foodPerDay = 0,
        },
    } :: { [string]: ModuleDef },
    MODULE_ORDER = { "A", "B", "C" },
    WIN_MODULE = "C", -- 이 모듈이 가동되면 즉시 승리

    -- 로버와 물
    ROVER = {
        tankMax = 40,
        fillHold = 3, -- 얼음 지점 E 홀드 시간(초)
        maxSpeed = 18, -- studs/s. VehicleSeat.MaxSpeed 초기값
        -- 바퀴 모터 최대 토크. VehicleSeat.Torque 초기값
        -- 중력 32.7, 로버+탑승자 약 170에서 앞바퀴가 들리는 토크(바퀴당 약 2900)의 절반 이하로 보수적으로 잡았다
        torque = 1200,
        turnSpeed = 1, -- VehicleSeat.TurnSpeed 초기값
        steerAngle = 30, -- 앞바퀴 최대 조향 각도(도)
        steerSpeed = 4, -- 조향 서보 회전 속도(rad/s)
        steerTorque = 5000, -- 조향 서보 최대 토크 (바퀴 마찰 저항의 약 4배)
        driveSign = -1, -- 바퀴 회전 방향 보정. Studio에서 거꾸로 가면 1로 바꾼다
        steerSign = -1, -- 조향 방향 보정. 좌우가 반대면 1로 바꾼다
        wheelRadius = 1.5, -- 그레이박스 바퀴 반지름(studs). 모터 각속도 = maxSpeed / 반지름
        wheelFriction = 1.5,
        chassisDensity = 2, -- 저중력에서 뒤집힘을 줄이려고 차체를 무겁게
    },
    SPAWN_HEIGHT_OFFSET = 3, -- SpawnPoint 윗면에서 캐릭터 중심까지 높이(studs)
    CHARACTER_LOAD_TIMEOUT = 5, -- 리스폰 후 HumanoidRootPart를 기다리는 최대 시간(초)
    ICE_PROMPT_DISTANCE = 20, -- 로버와 얼음 파트 표면 사이 거리 기준
    ICE_PROMPT_POLL_SECONDS = 0.5,
    TANK_UNLOAD_DISTANCE = 15, -- 하역하려면 DriverSeat가 WaterTank 파트 표면에서 이 거리 안에 있어야 한다

    -- 로버 복구 (뒤집힘, 추락, 소실)
    ROVER_RECOVERY = {
        checkSeconds = 1, -- 자동 검사 주기(초)
        flipUpY = 0.3, -- 시트 UpVector.Y가 이보다 작으면 뒤집힌 것으로 본다
        flipSeconds = 3, -- 무인 상태로 뒤집힌 채 이만큼 지나면 자동 복구
        fallDepth = 20, -- 기지 Origin보다 이만큼 아래로 떨어지면 자동 복구
        hold = 1, -- 수동 복구 프롬프트 홀드 시간(초)
    },
    RADAR_RANGE = 150,

    -- 산소 (플레이어 HP)
    OXYGEN = {
        max = 100,
        drainPerSecond = 100 / 60, -- 야외 60초에 소진
        refillPerSecond = 10,
        deathPenalty = { food = 1, water = 2 },
        tickSeconds = 0.2, -- 서버 산소 계산 주기
        maxUpdatesPerSecond = 5, -- OxygenUpdate 송신 상한
        habitatModule = "A", -- 산소 회복 구역이 있어야 하는 모듈
    },

    -- 실패와 승리
    SHORTAGE_DAYS_TO_LOSE = 3,

    -- 자원 값 반올림 자릿수 (일조율 곱셈의 부동소수 오차 제거용)
    RESOURCE_DECIMALS = 2,

    -- ProximityPrompt 공통
    PROMPT = {
        maxDistance = 12,
        buildHold = 0.5, -- 건설 시작 홀드 시간(초)
        unloadHold = 0, -- 물 하역은 즉시
    },

    -- 고스트 모델 투명도 (GDD 6절)
    GHOST_TRANSPARENCY = 0.7,

    -- 모듈 패드 위 상태 표시판 (BillboardGui, 픽셀과 studs)
    WORLD_LABEL = {
        width = 220,
        height = 50,
        offsetY = 14,
        maxDistance = 150,
        textSize = 20,
    },

    -- 착륙지 4곳 (NASA 남극 후보지 이름)
    SITES = {
        {
            id = 1,
            name = "Shackleton Rim",
            sunlight = 1.00,
            iceDistanceLabel = "멀다",
            hazardLabel = "낮음",
            description = "전력은 넉넉하지만 얼음까지 길이 멀다",
        },
        {
            id = 2,
            name = "de Gerlache Ridge",
            sunlight = 0.85,
            iceDistanceLabel = "중간",
            hazardLabel = "중간",
            description = "모든 면에서 균형 잡힌 후보지",
        },
        {
            id = 3,
            name = "Malapert Massif",
            sunlight = 0.70,
            iceDistanceLabel = "가깝다",
            hazardLabel = "중간",
            description = "물은 가깝지만 발전이 느리다",
        },
        {
            id = 4,
            name = "Nobile Crater",
            sunlight = 0.60,
            iceDistanceLabel = "매우 가깝다",
            hazardLabel = "높음",
            description = "얼음이 코앞이지만 지형이 험하다",
        },
    } :: { SiteDef },

    -- 그레이박스 맵(DevMap) 게임 영향 수치. 레이아웃 좌표는 DevMap.luau 상단 상수에 있다
    DEV_MAP = {
        iceDistanceBySite = { 450, 300, 180, 100 }, -- 패드 중심에서 가장 가까운 얼음 지점까지 studs
        boulderCountBySite = { 6, 14, 14, 28 }, -- 패드와 얼음 사이 통로의 바위 수 (지형 위험)
        scatterBoulders = 40, -- 맵 전체에 흩뿌리는 바위 수
        seed = 20261017, -- 바위 배치 난수 시드 (항상 같은 맵)
    },

    -- 단계별 미션 문구. 서버가 state.missionText로 내려준다
    -- %d, %s 자리는 Simulation.missionText가 Config 값으로 채운다
    MISSION_TEXTS = {
        selecting = "착륙지를 선택하세요",
        landing = "착륙 중입니다. 잠시 기다리세요",
        installPanels = "솔라 필드에서 패널 %d장을 설치하세요",
        firstWaterTrip = "로버를 타고 얼음 지점에서 물을 채운 뒤 기지 물탱크에 하역하세요",
        -- 모듈별 착공 안내 (Habitat A, Farm B, Research Lab C)
        build = {
            A = "Habitat A를 착공하세요 (Energy %d, Water %d 필요)",
            B = "Farm B를 착공하세요 (Energy %d, Water %d 필요)",
            C = "Research Lab C를 착공하세요 (Energy %d, Water %d 필요)",
        } :: { [string]: string },
        building = "%s 건설 중: %d일 남음. 패널과 물을 계속 모으세요",
        shortage = "경고: %s이 바닥났습니다. %d일 안에 보충하지 않으면 실패합니다",
        won = "임무 성공! 달 기지를 완성했습니다",
        lost = "임무 실패. 재도전으로 다시 시작하세요",
    },

    -- 토스트(Notify)와 판정 사유 문구
    TEXTS = {
        resourceEnergy = "Energy",
        resourceWater = "Water",
        waterKo = "물",
        foodKo = "식량",
        waterAndFoodKo = "물과 식량",
        listSeparator = ", ",

        notPlaying = "지금은 할 수 없습니다",
        unknownModule = "알 수 없는 모듈입니다",
        alreadyBuilding = "이미 건설 중입니다",
        alreadyActive = "이미 완공되었습니다",
        needPrereq = "먼저 %s 완공이 필요합니다",
        notEnoughResources = "자원이 부족합니다: %s 필요",
        resourceAmount = "%s %d",

        panelLimit = "오늘 설치 한도에 도달했습니다",
        panelsFull = "모든 패널을 설치했습니다",
        panelInstalled = "패널 설치 완료 (오늘 %d/%d, 전체 %d/%d)",

        buildStarted = "%s 착공 (%d일 소요)",
        buildDone = "%s 완공",
        moduleUnlocked = "%s 착공 가능",

        tankFilled = "로버 탱크 만충 (%dW)",
        tankAlreadyFull = "로버 탱크가 이미 가득 찼습니다",
        tankEmpty = "로버 탱크가 비어 있습니다",
        needDriver = "로버 운전석에 앉아 있어야 채취할 수 있습니다",
        waterUnloaded = "물 %dW 하역 완료",
        needRoverAtTank = "로버를 물탱크 옆에 세워야 하역할 수 있습니다",
        roverRecovered = "로버가 복구되었습니다",

        oxygenDepleted = "산소 고갈. 착륙선에서 구조되었습니다",
        oxygenDepletedOther = "%s 대원의 산소가 고갈되었습니다. Food -%d, Water -%d",

        modulesStalled = "전력 부족으로 모듈이 정지했습니다",
        shortageWarn = "%s이 바닥났습니다 (%d/%d일)",
        speedChanged = "%d배속으로 진행합니다",
        notChooser = "착륙지는 %s 대원이 선택합니다",

        endWon = "Research Lab 완공",
        endShortage = "%s이 %d일 연속 바닥났습니다",
        endTimeout = "%d일 안에 완공하지 못했습니다",

        labelLocked = "%s (잠김)",
        labelAvailable = "%s 착공 가능",
        labelBuilding = "%s 건설 중 %d일 남음",
        labelActive = "%s 가동 중",
    },

    -- ProximityPrompt 문구
    PROMPT_TEXTS = {
        installPanel = "패널 설치",
        installTomorrow = "내일 다시",
        solarObject = "솔라 필드 %d/%d",
        build = "건설 시작",
        buildObject = "%s (Energy %d, Water %d)",
        fillIce = "얼음 채취",
        iceObject = "얼음 지점",
        unload = "물 하역",
        tankObject = "기지 물탱크 (로버 %d/%dW)",
        recoverRover = "로버 복구",
        recoverObject = "착륙선 콘솔",
    },
}

return Config
