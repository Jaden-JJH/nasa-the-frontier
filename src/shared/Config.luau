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
    canPause: boolean, -- 완공 뒤 패드 프롬프트로 가동 중지/재개 가능 (2026-10-18, Farm만)
}

export type IceDifficulty = "easy" | "mid" | "hard"

-- 얼음 매장지 하나. 위치(x, z)는 로버 왕복 시간을 정하므로 게임 수치로 본다 (그레이박스 DevMap과 봇 테스트가 같이 쓴다)
export type IceSiteDef = {
    x: number,
    z: number,
    deposit: number, -- 처음 매장량(W). 채취하면 줄고 0이면 고갈
    difficulty: IceDifficulty,
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
    SPEEDS = { 1 }, -- SetSpeed로 허용되는 배속 (2026-10-18 사용자 결정: 2배속 제거. GameClock의 배속 경로는 남겨 둔다)
    SPEED_COOLDOWN_SECONDS = 1, -- 플레이어별 SetSpeed 최소 간격(초)

    -- 인트로
    LANDING_SECONDS = 5,
    SITE_SELECT_TIMEOUT = 30,
    DEFAULT_SITE_ID = 2,

    -- 시작 자원 (착륙선)
    -- energy 50 = 착륙선 잔여 배터리. 첫 물 원정(약 6일)에서 돌아오면 Habitat A(60E)를 바로 착공할 수 있게
    -- (2026-10-17 밸런스 조정, tests/simulation.spec.luau 현실적 봇 기준)
    START = { energy = 50, water = 25, food = 35 },

    -- 크루 생명유지 (매일)
    CREW = { food = 1, water = 1 },

    -- 태양광 패널
    -- 30 -> 25 (2026-10-18 사용자: 에너지가 넉넉하다). 봇 비교에서 하루 2장, 1장은 Habitat A가 늦어져 Malapert, Nobile이
    -- 졌고(하루 2장 + 20장도), 하루 3장 + 25장이 목표(최적 55 ~ 75일)를 지키면서 버려지는 전력이 가장 적었다
    PANELS_TOTAL = 25,
    PANELS_PER_DAY = 3,
    PANEL_OUTPUT = 1, -- E/일/장, 착륙지 일조율을 곱한다
    PANEL_INSTALL_HOLD = 2,
    -- 설치 연출: 홀드가 끝나면 패널이 슬롯 아래 PANEL_SINK_DEPTH에서 올라오며 펼쳐진다. 그동안 설치 프롬프트는 꺼진다
    PANEL_UNFOLD_SECONDS = 1.5,
    PANEL_SINK_DEPTH = 2,
    PANEL_FOLD_ANGLE = 70, -- 펼침 시작 각도(도). 슬롯 x축으로 접힌 채 올라와 0도로 펼쳐진다
    ANIMATION_HZ = 30, -- 서버 위치 보간 주기 (패널 펼침, 모듈 상승)

    -- 에너지 저장 상한 (2026-10-18): 기본 + 가동 모듈 수 x 모듈당. 넘치는 발전은 버려진다
    ENERGY_CAP_BASE = 150,
    ENERGY_CAP_PER_MODULE = 100,
    ENERGY_WASTE_NOTIFY_DAYS = 5, -- 계속 버려지면 이 일수마다 다시 알린다 (매일 토스트는 시끄럽다)
    -- 물 처리 전력: 하역한 물 1 W당 에너지. 모자라면 처리 가능한 만큼만 하역하고 나머지는 탱크에 남긴다
    WATER_PROCESS_ENERGY_PER_W = 0.5,

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
            canPause = false,
        },
        B = {
            name = "Farm",
            displayName = "Farm B",
            cost = { energy = 80, water = 30 },
            buildDays = 5,
            -- 물 유지 2 유지 (2026-10-18: 3이나 4로 올리면 Farm 뒤 하루 5 ~ 6 W를 8 ~ 10일 원정으로 메우지 못해
            -- 봇이 Nobile에서 항상 32일에 진다. 후반 물 압박은 Lab 건설 물 50으로 준다)
            -- 에너지 5 -> 6 (2026-10-18 사용자: 에너지가 넉넉하다. 재배 조명과 난방). 7 이상이나 물 처리 전력 0.75 이상,
            -- 저장 상한 120과의 조합은 일조 60%인 Nobile이 90일 안에 Lab 전력을 못 모아 봇이 졌다
            upkeep = { energy = 6, water = 2 },
            requires = { "A" },
            foodPerDay = 2,
            canPause = true,
        },
        C = {
            name = "Research Lab",
            displayName = "Research Lab C",
            cost = { energy = 150, water = 50 }, -- 물 30 -> 50 (2026-10-18 사용자 피드백: 너무 쉽다)
            buildDays = 7,
            upkeep = { energy = 8, water = 3 }, -- 물 1 -> 3 (완공 = 승리라 체감은 없지만 일관성)
            requires = { "A", "B" },
            foodPerDay = 0,
            canPause = false,
        },
    } :: { [string]: ModuleDef },
    MODULE_ORDER = { "A", "B", "C" },
    WIN_MODULE = "C", -- 이 모듈이 가동되면 즉시 승리
    -- 건설 연출: building 동안 완성 모델이 지면 아래에서 진행률만큼 올라온다. DayTick마다 이 시간 동안 부드럽게
    BUILD_RISE_SECONDS = 1,

    -- 얼음 매장지 8곳 (2026-10-18: 3곳 고정 무한에서 매장량과 고갈로). 합계 520 W.
    -- Ice1 ~ Ice3은 착륙 패드별 최근접 얼음(DEV_MAP.iceDistanceBySite, 첫 원정 거리)이라 위치를 바꾸지 않는다.
    -- Ice1은 Pad1에서 450이라 어느 패드에서도 350 이상 떨어져 mid로 둔다. easy는 Ice2(Pad2, Pad4 공용), Ice3(Pad3)
    -- mid는 모든 패드에서 350 이상, hard는 500 이상이며 바위 고리와 크레이터 사이에 있다.
    -- 패드가 남, 동, 서로 흩어져 한 패드가 닿는 매장량이 합계보다 훨씬 적다. 처음 안(합계 275, 탱크 40)은
    -- Farm 뒤 하루 4 W 소비를 8 ~ 10일 원정으로 메우지 못해 봇이 네 곳 모두 졌다. 매장량 약 1.4배와 탱크 60으로
    -- 네 곳 모두 41 ~ 50일 승리. Ice3(Malapert 첫 원정)은 30으로 올려 Farm 전 식량 여유 5 이상을 지킨다.
    -- 2차 (사용자: 너무 쉽다): Lab 건설 물 50과 로버 배터리를 넣고 hard 매장량을 110으로 올려 60 ~ 71일 승리
    -- (tests/simulation.spec.luau 현실적 봇)
    ICE_SITES = {
        { x = -75, z = 50, deposit = 40, difficulty = "mid" }, -- Ice1: Pad1 450, Pad2 500, Pad3 481
        { x = 425, z = 350, deposit = 30, difficulty = "easy" }, -- Ice2: Pad2 300, Pad4 100
        { x = -525, z = 400, deposit = 30, difficulty = "easy" }, -- Ice3: Pad3 180
        { x = 80, z = 160, deposit = 50, difficulty = "mid" }, -- Ice4: Pad2 362, Pad4 484, Pad1 581, Pad3 608
        { x = -560, z = -200, deposit = 40, difficulty = "mid" }, -- Ice5: Pad3 421, Pad1 525
        { x = -20, z = 290, deposit = 110, difficulty = "hard" }, -- Ice6: Pad2 506, Pad3 510, Pad4 548
        { x = 380, z = -650, deposit = 110, difficulty = "hard" }, -- Ice7: Pad1 519, Pad2 701
        { x = 950, z = 650, deposit = 110, difficulty = "hard" }, -- Ice8: Pad4 520, Pad2 797
    } :: { IceSiteDef },
    ICE_DEFAULT_DEPOSIT = 30, -- 디자이너 맵 얼음에 Deposit Attribute도 없고 번호도 ICE_SITES 밖일 때
    -- 고갈 표시: 결정 크기 = 남은 / 처음 (하한 minScale). 0이면 결정과 빛을 없애고 어두운 패치를 깐다
    ICE_VISUAL = {
        minScale = 0.35,
        patchSize = { 10, 0.2, 10 },
        patchColor = { 45, 45, 50 },
    },

    -- 로버와 물
    ROVER = {
        tankMax = 60, -- 40 -> 60 (2026-10-18): hard 매장지(65 ~ 70)를 한 번에 거의 비우고, 8 ~ 10일 원정이 Farm 뒤 소비를 넘게
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
        -- 배터리 (2026-10-18, RoverBattery): 주행 중(섀시 속도 > movingSpeed)에만 닳고, 0이면 멈춘다.
        -- 기지 충전 패드(ChargePad) 반경 chargeRadius 안에 빈 좌석으로 세우면 기지 에너지에서 1:1로 충전
        batteryMax = 50,
        batteryDrainPerSecond = 0.3, -- 0.4 -> 0.3: 0.4면 de Gerlache가 90일 안에 못 이긴다 (봇)
        movingSpeed = 1, -- studs/s. 이보다 빠를 때만 배터리 소모
        chargeRatePerSecond = 2,
        chargeRadius = 10, -- 섀시에서 충전 패드 중심까지 수평 거리
        lowBatteryRatio = 0.25,
        recoverBatteryRatio = 0.2, -- 복구하면 배터리를 최소 이 비율로 채워 돌아온다
        awayDistance = 60, -- 섀시가 충전 패드에서 이보다 멀면 "기지 밖" (미션 문구)
        batteryTickSeconds = 0.25, -- 서버 배터리 계산 주기
        batteryPublishSeconds = 0.5, -- 배터리 값만 바뀌었을 때 StateUpdate 최소 간격 (초당 최대 2회)
        -- 부스터 (2026-10-18, RoverBoost Remote): 운전자가 켜면 속도 x boostSpeedMultiplier, 배터리 소모 x boostDrainMultiplier.
        -- 연속 boostMaxSeconds면 과열로 꺼지고 boostCooldownSeconds 동안 식는다. 배터리가 boostMinBatteryRatio 미만이면 못 켠다
        boostSpeedMultiplier = 1.6,
        boostDrainMultiplier = 3,
        boostMaxSeconds = 4,
        boostCooldownSeconds = 6,
        boostMinBatteryRatio = 0.2,
        -- 부스터 시각 효과 (2026-10-18, RoverBoost): 섀시 뒤쪽 양옆 불꽃 입자 + 뒤쪽 하늘색 빛 + 바퀴 색 살짝 밝게.
        -- 켜는 순간 burst개를 한 번에 뿜고, 과열로 꺼지면 회색 연기를 smokeBurst개. 색은 RGB 0..255
        boostFx = {
            rate = 120,
            burst = 30,
            lifetime = { 0.25, 0.4 },
            speed = { 25, 35 },
            size = { 0.6, 0 },
            transparency = { 0.2, 1 },
            color = { 120, 200, 255 },
            colorEnd = { 255, 255, 255 },
            spread = 12, -- 뒤쪽 방향에서 퍼지는 각도(도)
            sideInset = 0.8, -- 섀시 옆면에서 불꽃 위치까지 안쪽 거리
            lightRange = 14,
            lightBrightness = 2,
            smokeBurst = 20,
            smokeColor = { 150, 150, 150 },
            smokeLifetime = 1.2,
            smokeSpeed = 4,
            smokeSize = { 1.2, 2.5 },
            smokeTransparency = { 0.3, 1 },
            wheelBrighten = 0.35, -- 부스트 중 바퀴 색을 흰색 쪽으로 이 비율만큼
        },
    },
    SPAWN_HEIGHT_OFFSET = 3, -- SpawnPoint 윗면에서 캐릭터 중심까지 높이(studs)
    CHARACTER_LOAD_TIMEOUT = 5, -- 리스폰 후 HumanoidRootPart를 기다리는 최대 시간(초)
    ICE_PROMPT_DISTANCE = 20, -- 로버와 얼음 파트 표면 사이 거리 기준
    ICE_PROMPT_POLL_SECONDS = 0.5,
    TANK_UNLOAD_DISTANCE = 15, -- 하역하려면 DriverSeat가 WaterTank 파트 표면에서 이 거리 안에 있어야 한다

    -- 로버 파손 (2026-10-18, RoverDamage): 바위(BoulderLayer Attribute)에 speedThreshold 이상으로 부딪히면 +1.
    -- 파손당 최고 속도 speedPenaltyPerDamage 감소, maxDamage면 정지. 로버 섀시의 "수리" 프롬프트(R 홀드)로 복구
    ROVER_DAMAGE = {
        enabled = true,
        -- studs/s, 충돌 순간 섀시 AssemblyLinearVelocity 크기. 파손 2의 최고 속도(18 x 0.8 = 14.4)보다 낮아
        -- 평지에서도 세 번째 파손(고장)까지 날 수 있다 (2026-10-18: 15 -> 12)
        speedThreshold = 12,
        hitCooldown = 1, -- 초. 이 안의 연속 접촉은 한 번으로 센다
        maxDamage = 3,
        speedPenaltyPerDamage = 0.1, -- 파손 1: 16.2, 파손 2: 14.4 studs/s. 3이면 정지 (0.2 -> 0.1)
        repairHold = 4,
        repairEnergy = 10,
        promptDistance = 8,
        repairKey = "R", -- 탑승 프롬프트(E)와 같은 섀시에 붙으므로 키를 나눈다 (Enum.KeyCode 이름)
    },

    -- 로버 복구 (뒤집힘, 추락, 소실)
    ROVER_RECOVERY = {
        checkSeconds = 1, -- 자동 검사 주기(초)
        flipUpY = 0.3, -- 시트 UpVector.Y가 이보다 작으면 뒤집힌 것으로 본다
        flipSeconds = 3, -- 무인 상태로 뒤집힌 채 이만큼 지나면 자동 복구
        fallDepth = 20, -- 기지 Origin보다 이만큼 아래로 떨어지면 자동 복구
        hold = 1, -- 수동 복구 프롬프트 홀드 시간(초)
        cooldownSeconds = 15, -- 복구(수동, 자동 공용) 뒤 다음 복구까지 기다리는 시간(초). 복구하면 탱크의 물은 잃는다
        promptDistance = 8, -- 콘솔 프롬프트 활성 거리 (에어락 문에서 14 studs 넘게 떨어져 있어 문 앞에서는 안 뜬다)
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
        lowWarning = 20, -- 이 값 이하로 떨어지면 한 번 경고 (이 값 위로 회복하면 다시 경고 가능)
    },

    -- 실패와 승리
    SHORTAGE_DAYS_TO_LOSE = 3,
    RESULT_MIN_SECONDS = 10, -- 결과 화면이 뜬 뒤 재시작을 받기까지 최소 시간(초). 재시작은 선택 권한자만

    -- 자원 값 반올림 자릿수 (일조율 곱셈의 부동소수 오차 제거용)
    RESOURCE_DECIMALS = 2,

    -- 서버 효과음 (Sfx, 2026-10-18). 음원 id와 볼륨은 Shared.SoundIds. 여기는 재생 방식만
    SFX = {
        rollOffMaxDistance = 120, -- 3D 효과음 기본 최대 거리
        interiorRollOff = 25, -- 건물 내부 허밍 최대 거리
        oneShotLifetime = 15, -- 한 번 재생하는 소리가 Ended를 못 받아도 이 초 뒤에 지운다
        engineMinSpeed = 0.8, -- 로버 주행 루프 PlaybackSpeed (정지 ~ 최고 속도)
        engineMaxSpeed = 1.4,
        engineBoostMaxSpeed = 1.8, -- 부스트 중 PlaybackSpeed 상한
        engineIdleVolume = 0.1, -- 탑승 중 정지 상태 볼륨 (빈 로버는 0)
        engineFade = 0.5, -- 배터리 주기마다 목표 볼륨으로 다가가는 비율
    },

    -- 충전 도크 표시 (2026-10-18): ChargePad Attribute DockState에 따라 테두리, 중앙 원판, SurfaceLight
    CHARGE_DOCK = {
        emptyColor = { 245, 200, 40 }, -- 비어 있음: 노란 테두리 (빛 없음)
        dockedColor = { 120, 200, 255 }, -- 도킹(탑승 중이거나 기지 에너지 0): 하늘색 + 약한 빛
        chargingColor = { 255, 210, 50 }, -- 충전 중: 노란 Neon 테두리와 중앙 원판이 펄스
        fullColor = { 90, 220, 110 }, -- 완충: 초록 고정
        dockedLight = 0.6,
        chargingLightMax = 2.5,
        fullLight = 1.2,
        lightRange = 12,
        pulsePeriod = 0.8, -- 충전 중 밝기 펄스 주기(초)
        pulseHz = 10, -- 서버 펄스 갱신 주기
    },

    -- ProximityPrompt 공통
    PROMPT = {
        maxDistance = 12,
        buildHold = 0.5, -- 건설 시작 홀드 시간(초)
        unloadHold = 0, -- 물 하역은 즉시
        boardDistance = 10, -- 로버 탑승 프롬프트 활성 거리
        pauseDistance = 8, -- 모듈 가동 중지/재개 프롬프트 활성 거리
        serverDistanceSlack = 6, -- 서버가 탑승 요청 거리를 검사할 때 지연을 감안한 여유
    },

    -- 고스트 모델 투명도 (GDD 6절)
    GHOST_TRANSPARENCY = 0.7,

    -- 걸어 들어가는 건물 (착륙선, Habitat A): 정면(-Z) 문으로만 들어간다. 산소 구역 = 건물 내부
    AIRLOCK = {
        doorWidth = 4.5,
        doorHeight = 5.5,
        doorThickness = 0.4,
        doorColor = { 60, 62, 68 }, -- 어두운 회색 문 판 (닫혀 있으면 충돌, 4차)
        frameColor = { 205, 208, 215 }, -- 문 둘레에 겹쳐 보이는 밝은 프레임
        frameBorder = 0.3,
        doorInset = 0.5, -- 건물 경계 상자 앞면에서 안쪽으로
        signText = "AIRLOCK",
        signHeight = 0.7,
        wallHeight = 6, -- 보이지 않는 충돌 벽
        wallThickness = 0.5,
        doorGap = 5, -- 정면 벽에서 비우는 폭
        zoneInset = 1, -- 산소 구역 = 경계 상자를 각 면 이만큼 줄인 박스
        zoneDoorMargin = 1, -- 산소 구역이 문 앞으로 더 나가는 거리
        spawnInset = 2, -- 착륙선 스폰 지점 = 문에서 이만큼 안쪽
        lightColor = { 255, 210, 160 }, -- 내부 따뜻한 빛
        lightRange = 18,
        lightBrightness = 1,
        -- 문 여닫기 (Airlock 모듈, 4차): E로 열면 openSeconds 동안 열리고, 문 범위에 캐릭터가 있으면 닫지 않는다
        openSeconds = 6,
        openTransparency = 0.75,
        openColor = { 160, 175, 190 }, -- 열린 문은 밝은 색
        promptDistance = 8, -- 문 프롬프트 활성 거리
        closeCheckDepth = 1.6, -- 닫기 전 캐릭터를 찾는 범위 = 문 두께 + 이 깊이 (문 앞뒤 1 stud. 문에서 2 안쪽 스폰은 닿지 않게)
        closeRetrySeconds = 0.5, -- 문 범위에 캐릭터가 있으면 이 간격으로 다시 확인
    },

    -- 우주복 (서버가 캐릭터마다 입힌다). 색은 RGB 0..255, 크기는 studs
    SUIT = {
        suitColor = { 240, 240, 245 }, -- 몸통, 오른팔, 다리
        accentColor = { 255, 140, 40 }, -- 왼팔 포인트
        helmetColor = { 170, 220, 255 }, -- 반투명 유리 헬멧
        helmetTransparency = 0.55,
        helmetScale = 1.4, -- 머리 크기 대비 헬멧 지름
        headMinSize = 1.2, -- 머리 크기 계산 하한 (R6 머리 Part는 실제 메시보다 얇다)
        packColor = { 120, 124, 132 }, -- 생명유지 배낭
        packSize = { 1.6, 2, 0.8 },
        packOffsetY = 0.2,
        panelColor = { 255, 140, 40 }, -- 가슴 제어판
        panelSize = { 0.8, 0.5, 0.15 },
        panelOffsetY = 0.3,
        loadTimeout = 5, -- 머리와 몸통 파트를 기다리는 최대 시간(초)
    },

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
        -- 패드 위치 = ICE_SITES[ice] 위치 + (dirX, dirZ) x iceDistanceBySite (봇 테스트도 이 값으로 거리를 잰다)
        padLayout = {
            { ice = 1, dirX = 0, dirZ = -1 },
            { ice = 2, dirX = 0, dirZ = -1 },
            { ice = 3, dirX = 0, dirZ = -1 },
            { ice = 2, dirX = 1, dirZ = 0 },
        },
        -- hard 매장지 둘레 바위 고리 (그 지점 iceBoulderCap 대상에서 빠진다)
        hardRingRocks = { 12, 20 }, -- 지점마다 개수 범위 (시드로 결정)
        hardRingRadius = { 25, 45 }, -- 얼음 중심에서 바위 중심까지
        -- 위험 경로 크레이터: 각 패드에서 mid, hard 매장지로 가는 직선 위 (회랑, 판 + 25, 얼음 30 안은 제외)
        routeCraters = 26, -- hard 양옆 2개씩 포함. 전체 약 80개 (예전 54 + 이것)
        routeMidReach = 650, -- 이 거리 안의 mid 매장지 경로에 놓는다
        routeHardReach = 850, -- 이 거리 안의 hard 매장지 경로에 놓는다
        -- 바위 4층 (4차 추가, 합계 약 560): 기지 둘레 고리 + 주행 회랑 양옆 무더기 + 맵 전체 산포 + 기지 근처 추가 산포
        baseRingBouldersBySite = { 36, 40, 40, 46 }, -- 착륙지별 기지 판 둘레 (판 가장자리 + 6 ~ + 45). 어느 기지에서도 약 40개
        boulderCountBySite = { 16, 26, 26, 40 }, -- 착륙지별 주행 회랑 양옆 바위 무더기 (지형 위험)
        scatterBoulders = 260, -- 맵 전체(2600 x 2200)에 흩뿌리는 바위 수
        scatterOuterDensity = 0.5, -- 중심 구역(1400 x 1100) 밖 산포 밀도 배율 (멀수록 듬성듬성)
        nearBaseScatterFactor = 1.5, -- 판 가장자리 + 45 ~ + 200 띠의 산포 밀도 = 중심 구역의 이 배율
        iceBoulderCap = 12, -- 얼음 지점 하나 주변 바위 상한 (얼음이 바위에 묻히지 않게)
        iceBoulderCapRadius = 40, -- 위 상한을 세는 반지름
        seed = 20261017, -- 바위 배치 난수 시드 (항상 같은 맵)
    },

    -- 단계별 미션 문구. 서버가 state.missionText로 내려준다
    -- %d, %s 자리는 Simulation.missionText가 Config 값으로 채운다
    MISSION_TEXTS = {
        selecting = "착륙지를 선택하세요",
        landing = "착륙 중입니다. 잠시 기다리세요",
        installPanels = "솔라 필드에서 패널 %d장을 설치하세요",
        -- 튜토리얼 단계(missionStage)는 날짜가 아니라 행동 완료로 넘어간다
        boardRover = "로버에 다가가 E로 탑승하세요",
        findIce = "레이더의 점을 따라 얼음 지점으로 가서 E를 길게 눌러 물을 채우세요",
        unloadWater = "기지로 돌아와 물탱크 옆에 로버를 세우고 E로 물을 하역하세요",
        -- 모듈별 착공 안내 (Habitat A, Farm B, Research Lab C)
        build = {
            A = "Habitat A를 착공하세요 (Energy %d, Water %d 필요)",
            B = "Farm B를 착공하세요 (Energy %d, Water %d 필요)",
            C = "Research Lab C를 착공하세요 (Energy %d, Water %d 필요)",
        } :: { [string]: string },
        building = "%s 건설 중: %d일 남음. 패널과 물을 계속 모으세요",
        roverBroken = "로버를 수리하세요 (전력 %d)",
        batteryEmpty = "로버 배터리 방전. 복구 콘솔을 사용하세요",
        batteryLow = "배터리가 부족합니다. 기지로 돌아와 충전하세요",
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
        -- 모듈별 완공 알림 (유지비 포함, %d 자리는 Construction이 Config 값으로 채운다). 없는 모듈은 buildDone
        buildDoneBy = {
            A = "Habitat A 가동. 물 -%d/일, 전력 -%d/일. 안에서 산소가 회복됩니다",
            B = "Farm 가동 시작. 식량 +%d/일, 물 -%d/일, 전력 -%d/일. 물이 모자라면 Farm 패드에서 끌 수 있습니다",
        } :: { [string]: string },
        modulePaused = "%s 가동 중지. 식량 생산과 물, 전력 소비가 멈춥니다",
        moduleResumed = "%s 가동 재개",
        cannotPause = "지금은 가동을 멈출 수 없습니다",
        upkeepWater = "물 -%d/일",
        upkeepEnergy = "전력 -%d/일",
        upkeepFood = "식량 +%d/일",
        upkeepPaused = "대기 중",
        moduleUnlocked = "%s 착공 가능",

        tankFilled = "로버 탱크 만충 (%dW)",
        iceExtracted = "얼음 %d W 채취 (남은 매장량 %d)",
        iceDepleted = "이 얼음 지점은 다 캤습니다. 레이더로 다른 지점을 찾으세요",
        waterPartial = "전력이 부족해 물 %d W만 처리했습니다. 나머지는 탱크에 남습니다",
        waterNoEnergy = "전력이 부족해 물을 처리할 수 없습니다. 1 W에 전력 %s이 필요합니다",
        energyWasted = "배터리가 가득 차 전력이 버려지고 있습니다. 건설을 시작하세요",
        roverHitDriver = "로버 파손 %d/%d",
        roverHitOthers = "로버가 바위에 부딪혔습니다 (파손 %d/%d)",
        roverBroken = "로버 고장. 수리가 필요합니다",
        repairNeedEnergy = "수리에 전력 %d이 필요합니다",
        repairDone = "로버 수리 완료",
        repairNotNeeded = "로버가 멀쩡합니다",
        repairOccupied = "탑승 중에는 수리할 수 없습니다",
        batteryEmpty = "로버 배터리가 바닥났습니다. 복구 콘솔로 끌어오세요",
        batteryLow = "로버 배터리가 %d%% 남았습니다. 기지로 돌아와 충전하세요",
        batteryFull = "로버 충전 완료",
        chargeNoEnergy = "기지 에너지가 없어 로버를 충전할 수 없습니다",
        dockEntered = "충전 도크 도킹. 하차하면 충전이 시작됩니다",
        chargeStarted = "충전 시작 (%d / %d)",
        tankAlreadyFull = "로버 탱크가 이미 가득 찼습니다",
        tankEmpty = "로버 탱크가 비어 있습니다",
        needDriver = "로버 운전석에 앉아 있어야 채취할 수 있습니다",
        firstBoard = "W A S D 이동, Space 하차, Shift 부스터(배터리 %d배 소모). 레이더의 점을 따라가세요",
        waterUnloaded = "물 %dW 하역 완료",
        needRoverAtTank = "로버를 물탱크 옆에 세워야 하역할 수 있습니다",
        roverRecovered = "로버가 복구되었습니다",
        roverOccupied = "탑승 중에는 복구할 수 없습니다",
        tankLostOnRecover = "복구 중 탱크의 물을 잃었습니다",
        recoverCooldown = "로버 복구는 %d초 뒤에 할 수 있습니다",

        oxygenDepleted = "산소 고갈. 착륙선에서 구조되었습니다",
        airlock = "에어락",
        lowOxygen = "산소 부족. 가까운 에어락 문을 E로 열고 안으로 들어가세요",
        airlockOpened = "에어락이 열렸습니다. 안으로 들어가면 산소가 회복됩니다",
        oxygenDepletedOther = "%s 대원의 산소가 고갈되었습니다. Food -%d, Water -%d",

        modulesStalled = "전력 부족으로 모듈이 정지했습니다",
        stallReason = "전력 부족으로 시설이 멈췄습니다. 패널을 더 설치하세요",
        resetPenalty = "쓰러져서 착륙선으로 구조되었습니다. Food -%d, Water -%d",
        resetPenaltyOther = "%s 대원이 쓰러져 구조되었습니다. Food -%d, Water -%d",
        restartTooSoon = "결과를 확인하는 시간입니다. %d초 뒤에 다시 시작할 수 있습니다",
        restartNotChooser = "재시작은 %s 대원이 할 수 있습니다",
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
        -- ObjectText: 대상 이름
        solarObject = "태양광 필드",
        buildObject = "%s 패드",
        iceObject = "얼음",
        iceObjectAmount = "얼음 (남은 %d W)",
        tankObject = "물탱크",
        recoverObject = "착륙선 콘솔",
        roverObject = "로버",
        airlockObject = "에어락",
        -- ActionText: 동작
        installPanel = "패널 설치 (오늘 %d/%d)",
        installTomorrow = "내일 다시 (오늘 %d/%d)",
        build = "건설 시작",
        fillIce = "얼음 채취",
        unload = "물 하역",
        recoverRover = "로버 복구",
        recoverCooldown = "로버 복구 (%d초 뒤)",
        repairRover = "수리",
        installing = "설치 중",
        board = "탑승",
        openDoor = "열기",
        pauseModule = "가동 중지",
        resumeModule = "가동 재개",
    },
}

return Config
