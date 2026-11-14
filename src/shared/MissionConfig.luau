--!strict
-- The Frontier v2 미션 수치 모음 (기준: docs/V2_PLAN.md 15절 grill 결정 Q1 ~ Q38)
-- 규칙 코드(Rules.luau)와 봇 시뮬레이션(tests/bot_v2.luau)이 같은 값을 쓴다. Roblox 전역을 쓰지 않는다.
-- 화면 문장은 넣지 않는다 (docs/I18N_PLAN.md 4.1). 이름과 문구는 클라이언트가 키로 찾는다.
--
-- 출처 표기
--   [카드] Figma 우선순위 카드, [스티커] Figma 게임 시간과 소비 스티커, [손글씨] Figma 손글씨 메모
--   [회의1~3] docs/meetings/meetingN.txt, [Qn] V2_PLAN 15절 grill 결정, [측정] Studio 실측
--   [sim] 봇 시뮬레이션(tests/run_v2.luau)으로 맞춘 값. 회의 값과 다르면 "회의 X -> Y"로 적는다
--   [제안] 회의와 grill에 숫자가 없어 규칙 담당이 정한 출발값

export type Cost = { energy: number, water: number }

-- 시설 정의. kind로 효과를 나눈다
--   airlock: 산소 회복 (하루 단위 규칙에는 효과 없음, 서버가 active 여부를 읽는다)
--   farm: harvestEveryDays마다 harvestAmount 식량
--   upgrade: 재배 공간 보조 (farm이 돌아갈 때만 유지비와 효과)
--   pipe: 연결한 얼음 지점에서 deliverEveryDays마다 deliverAmount 물
-- buildFrom: "outdoor"(사람이 가서 짓는다, SEP 중 불가) | "map"(지도에서 클릭, GST 중 불가)
export type FacilityDef = {
    kind: string,
    cost: Cost,
    buildDays: number,
    upkeep: Cost,
    requires: { string },
    canPause: boolean,
    buildFrom: string,
    multi: boolean?,
    maxCount: number?,
    harvestEveryDays: number?,
    harvestAmount: number?,
    farmEnergyUpkeepMultiplier: number?,
    farmWaterUpkeepMultiplier: number?,
    unlockDeliveries: number?,
    deliverEveryDays: number?,
    deliverAmount: number?,
}

export type RiskLevel = {
    maxDistance: number?, -- 이 거리(studs) 미만이면 이 등급. nil이면 마지막 등급
    damageChance: number, -- 왕복 한 번에 파손이 날 확률 (서둘러 가기면 한 등급 위 값)
    speedFactor: number, -- 경로 지형 때문에 느려지는 비율 (거리로 정한 등급에만 적용, 서둘러 가기와 무관)
}

local MissionConfig = {
    -- 시간 ---------------------------------------------------------------
    DAY_SECONDS = 30, -- [Q1, 스티커] 1일 30초
    -- [리드 전달] 디자이너 높이맵 2.56 km = 2044 studs. 내부 거리는 studs, 화면 Msg의 거리만 정수 미터로 보낸다
    metersPerStud = 2560 / 2044,
    TOTAL_DAYS = 60, -- [Q1, 스티커] 60일 = 30분
    RESOURCE_DECIMALS = 2, -- 배율 곱셈(LED 전력 x1.2 등)의 부동소수 오차 정리용

    -- 실패 ----------------------------------------------------------------
    SHORTAGE_DAYS_TO_LOSE = 4, -- [Q3] 물 또는 식량 0이 4일 연속이면 실패
    RESOURCES = { "energy", "water", "food" },

    -- 숨은 점수 [Q4] -------------------------------------------------------
    SCORE = {
        start = 1000,
        lowThreshold = 20, -- 하루 끝에 이 값 미만이면 lowPenalty
        lowPenalty = 10,
        zeroPenalty = 30, -- 0이면 lowPenalty 대신
        oxygenRescuePenalty = 100, -- 산소 0으로 에어록 구조 1회
        minScore = 0,
    },

    -- 산소와 걷기 [Q28, Q37] ---------------------------------------------------
    OXYGEN = {
        max = 100,
        outdoorSeconds = 60, -- [Q28] 야외 60초에 산소 100 소모
        airlockRefillPerSecond = 2, -- [Q28, 카드] 점검 뒤 가동 중 에어록 안
        roverSeatRefillPerSecond = 2, -- [Q28] 로버 좌석
    },
    WALK_REPAIR = {
        walkSpeed = 16, -- Roblox 기본 걷기 속도(studs/s)
        repairHoldSeconds = 4, -- v1 ROVER_DAMAGE.repairHold
        -- [제안] 산소의 80%만 쓴다고 보고 한 방향 걷기 거리 한도를 계산한다. 수리 뒤에는 로버 좌석에 타서
        -- 산소를 회복하며 돌아온다고 본다. 한도 = (60 x 0.8 - 4) x 16 = 704 studs
        oxygenSafetyRatio = 0.8,
        -- 고장 난 로버는 기지에서 걸어간다. 출발은 에어록. 걷는 거리 = BaseExit 기준 고장 위치 + 에어록에서 BaseExit까지
        -- (한도 704와 비교, 삼각 부등식의 위쪽 값이라 실제보다 길게 잡는다)
        -- [측정 2026-11-15, 리드 전달] 기지를 중간 지점으로 옮기고 출구를 얼음 쪽으로 다시 놓은 뒤 에어록 -> BaseExit 149 studs.
        -- 그래서 BaseExit 기준 고장 위치 555 studs까지 걸어서 수리할 수 있다. 이전 값 176 (2026-11-14 기지)
        startOffset = 149,
    },

    -- 우주 기상 [Q14, Q15] -------------------------------------------------
    WEATHER = {
        SEP = {
            blocksOutdoor = true, -- 패널 설치, 현장 건설 착공, 로버 주차 자리 수리, 걸어서 수리 불가
            pausesRover = true, -- 자율주행 이동과 원격 회수 진행이 멈춘다
        },
        GST = {
            minKp = 6, -- [Q14] Kp 6 이상만 사건으로 쓴다 (데이터에 kp가 있으면 규칙도 한 번 더 거른다)
            pausesRover = true, -- [Q14] 솔로 자율주행 정지
            blocksMap = true, -- 지도 장애: 로버 파견, 원격 회수, 지도에서 짓는 파이프 불가
        },
    },

    -- 수동 운전 비교용 (멀티는 사람이 운전, 보고서 계산에만 쓴다) -----------------------
    MANUAL_DRIVE = {
        v1MaxSpeed = 18, -- v1 Config.ROVER.maxSpeed
        v1BoostMultiplier = 1.6, -- v1 Config.ROVER.boostSpeedMultiplier
        v1BoostOnSeconds = 4, -- v1 boostMaxSeconds
        v1BoostCooldownSeconds = 6, -- v1 boostCooldownSeconds
        fillSeconds = 3, -- v1 ROVER.fillHold
        unloadSeconds = 3, -- [제안] 하역 홀드
        detourFactor = 1.25, -- [제안] 바위와 크레이터를 돌아가는 실제 경로 / 직선 거리
        -- 배터리 (v1 Config.ROVER, Q29 C와 B 모두 켬). 충전 패드는 기지 에너지에서 1:1로 채운다 (Rules.payEnergy)
        batteryMax = 50,
        -- [sim, 2026-11-14 새 목표] v1 0.3, 부스터 x3 -> 0.15, x2. v1 값이면 수동 왕복 한 번 충전이 25 ~ 45로 자율주행
        -- (9 ~ 24)의 두 배라 멀티 팀이 업그레이드에 쓸 에너지를 모으지 못했다. 서버 RoverBattery가 이 값을 쓴다
        batteryDrainPerSecond = 0.15,
        boostDrainMultiplier = 2,
        -- [제안, sim] 충전 패드는 기지 에너지 중 이 값을 넘는 만큼만 쓴다. 없으면(v1 그대로) 수동 왕복 한 번의 충전(20 ~ 45)이
        -- 기지 에너지를 0으로 만들어 재배 공간이 멈추고, 2명 팀 봇이 실력과 무관하게 75 ~ 95% 굶어 실패했다
        chargeKeepEnergy = 20,
        repairEnergy = 10, -- v1 ROVER_DAMAGE.repairEnergy, 현장 R 수리
        repairSeconds = 4, -- v1 repairHold
    },

    MISSIONS = {},
}

-- C 식량 생산 기지 (Nobile Rim 1) --------------------------------------------
-- 밸런스 (2026-11-14 새 목표, 리드 전달): 솔로 처음 실패 50 동 40 은 9 금 1, 두 번째 실패 30 동 50 은 15 금 5,
-- 멀티 2명 처음 실패 30 이하 동 50 은 17 금 3, 두 번째 실패 15 동 50 은 27 금 8, 3 ~ 4명은 2명보다 조금 쉽게.
-- tests/run_v2.luau 봇(실력이 판마다 퍼진 사람 계열 + 멀티 수동 운전) x 실제 DONKI 구간 5개 x 시드 40으로 맞췄다.
-- 실패는 주로 식량: 시작 식량이 적어(35, 약 12일) 재배 공간을 늦게 지으면 첫 수확 전에 바닥난다(계획 실수).
-- 판을 가장 크게 움직이는 값은 시작 식량이다 (32/35/38에서 솔로 처음 실패 56/50/25%, 보고서 민감도 표).
-- 이전 조정(Q31 사다리, 2026-11-14 오전): 시작 70/70/70, 패널 10 x 3, 업그레이드와 파이프 E70 W30, LED 유지 E7, 자율주행 9
local missionC = {
    id = "C",
    playable = true,
    -- [sim] 스티커 70/70/70 -> 에너지 40, 물 50, 식량 35. 디자이너 제안 50/50/50에서 출발해 새 목표(실패 비율)에 맞춤.
    -- 에너지가 적어 첫 며칠 패널, 재배 공간, 로버 중 무엇부터 할지 고르게 되고, 식량이 적어 재배 공간 시기가 갈린다
    -- [2026-11-14 사용자 "조금 쉽게", 리드 시뮬레이션] 식량 35 -> 37 (36은 봇 반응 문턱 때문에 변화 없음)
    start = { energy = 40, water = 50, food = 37 },
    cap = 100, -- [스티커, 손글씨 강조] 상한 100. 넘친 양은 버려진다 [Q9]
    crew = { energy = 12, water = 3, food = 3 }, -- [스티커] 하루 기본 소비
    -- [리드 지시, 결정 전] 대원 소비를 인원에 비례시킬지. 켜면 2번째 대원부터 1명당 아래만큼 더한다 (대원 1명 기준 소비 위에)
    crewScaling = false,
    crewPerExtraPlayer = { energy = 0, water = 1, food = 1 },
    -- 자원이 모자라 유지비를 다 못 낼 때 [Q3]: "all" 모든 시설 정지(처음 구현), "priority" shedOrder 앞쪽부터 멈춤.
    -- [결정 대기, 리드 보고 2026-11-14] "all"이면 이른 에너지 부족에 재배 공간도 같이 멈춰 수확 타이머가 얼고,
    -- 새 목표 후보 경제에서 실패 100%가 "재배 공간은 지었는데 한 번도 수확 못 함"이었다
    stallMode = "priority", -- [sim, 리드 결정 대기] 처음 구현 "all"
    shedOrder = { "led", "nutrient", "hydroponics", "pipe", "airlock", "farm" }, -- 앞쪽이 먼저 멈춘다
    -- [결정 대기] true면 시설 에너지 유지비를 대원 에너지(12)보다 먼저 낸다. false면 대원이 먼저라 초반에 재배 공간이 멈춘다
    crewEnergyLast = true, -- [sim, 리드 결정 대기] 처음 구현 false
    panels = {
        cost = 4, -- [카드] 에너지 4
        output = 2, -- [sim] 카드 3 -> 2 (디자이너 제안 2)
        perDay = 2, -- [카드] 하루 최대 2장
        total = 13, -- [sim] 카드 20 -> 13 (하루 최대 26). 오전 조정 10 x 3 = 30
        installSeconds = 3, -- [카드] 설치 3초 (서버 홀드 시간)
        -- [제안, sim] 구조 장치: 에너지가 비용보다 적고 패널 발전(장수 x 3)이 대원 소비 12보다 작으면 남은 에너지만 내고
        -- 설치할 수 있다. 없으면 패널 0 ~ 1장에서 에너지를 다 쓴 아이는 다시는 패널을 못 사서 회복할 수 없다
        -- (대원 소비가 발전을 매일 다 먹는다). 처음 하는 사람 봇이 회의 숫자로 이 함정에 빠졌다
        emergencyInstall = true,
    },
    facilityOrder = { "airlock", "farm", "led", "nutrient", "pipe", "hydroponics" },
    -- [Q11] 시설의 건설비와 유지비는 에너지와 물만. 카드의 식량 비용과 식량 유지비는 모두 뺐다
    facilities = {
        -- [카드, Q28] 처음부터 있는 건물을 "점검". 비용 없음, 2일, 유지 E2 W1
        airlock = {
            kind = "airlock",
            cost = { energy = 0, water = 0 },
            buildDays = 2,
            upkeep = { energy = 2, water = 1 },
            requires = {},
            canPause = true, -- [Q33] 유지비가 있는 시설은 모두 멈출 수 있다
            buildFrom = "outdoor",
        },
        -- [카드] E10 W5, 3일, 유지 E3 W2. [Q12] 5일마다 26 자동 수확
        farm = {
            kind = "farm",
            cost = { energy = 10, water = 5 },
            buildDays = 3,
            upkeep = { energy = 3, water = 2 },
            requires = {},
            canPause = true,
            buildFrom = "outdoor",
            harvestEveryDays = 5,
            harvestAmount = 26,
        },
        -- [카드] 1일, 유지 물 1. [Q12] 4일마다 수확. [Q13, 카드] 재배 공간 전력 +20%
        -- [sim] 비용 카드 E8 W4 -> E35 W20, 유지 전력 카드 E3 -> E5 ("LED = 전력을 더 먹는 속도"). 오전 조정 E70 W30, E7
        led = {
            kind = "upgrade",
            cost = { energy = 35, water = 20 },
            buildDays = 1,
            upkeep = { energy = 5, water = 1 },
            requires = { "farm" },
            canPause = true,
            buildFrom = "outdoor",
            harvestEveryDays = 4,
            farmEnergyUpkeepMultiplier = 1.2,
        },
        -- [Q13] 재배 공간 물 유지비 절반. 회의와 카드에 숫자가 없어 유지비 E2 W0은 [제안]
        -- [sim] 비용 제안 E8 W4 -> E35 W20 (은메달 두 업그레이드를 같은 급으로). 오전 조정 E70 W30
        nutrient = {
            kind = "upgrade",
            cost = { energy = 35, water = 20 },
            buildDays = 1,
            upkeep = { energy = 2, water = 0 },
            requires = { "farm" },
            canPause = true,
            buildFrom = "outdoor",
            farmWaterUpkeepMultiplier = 0.5,
        },
        -- [Q10] 5일, 유지 E2 W1, 3일마다 물 30, 해금은 기지 하역 5회(자율주행 포함), 1개로 시작
        -- [회의1] 지도에서 고른 얼음 지점에 클릭 한 번으로 설치 -> buildFrom "map"
        -- [sim] 비용 Q10 E15 W4 -> E60 W40 (금메달 단계는 은메달 단계보다 비싸게). 오전 조정 E70 W30
        pipe = {
            kind = "pipe",
            cost = { energy = 60, water = 40 },
            buildDays = 5,
            upkeep = { energy = 2, water = 1 },
            requires = {},
            canPause = true,
            buildFrom = "map",
            multi = true,
            maxCount = 1,
            unlockDeliveries = 5,
            deliverEveryDays = 3,
            deliverAmount = 30,
        },
        -- [카드] 1일, 유지 E2 W2. [Q12] 한 번에 34. [Q10, 회의1] 파이프가 있어야 짓는다
        -- [sim] 비용 카드 E6 W3 -> E60 W40. 오전 조정 E70 W30
        hydroponics = {
            kind = "upgrade",
            cost = { energy = 60, water = 40 },
            buildDays = 1,
            upkeep = { energy = 2, water = 2 },
            requires = { "farm", "pipe" },
            canPause = true,
            buildFrom = "outdoor",
            harvestAmount = 34,
        },
    } :: { [string]: FacilityDef },
    -- [Q9] 1회 채취 30(지점 무관), 지점마다 쿨타임 3일
    ice = { amountPerTrip = 30, cooldownDays = 3 },
    -- [Q37] 얼음 후보지는 실제 NASA 후보 좌표를 줄여 배치했다 (위치는 그대로, 기지가 옮겨 감).
    -- 규칙은 번호가 아니라 거리로 순서를 정한다 (newState가 가까운 순으로 정렬, siteIndex 1 = 가장 가까운 곳).
    -- 서버는 실측 거리를 newState options.iceDistances로 넘겨 이 값을 덮어쓸 수 있다
    -- [측정 2026-11-15, 리드 전달] 플레이 테스트 "얼음이 너무 가깝다"(V2_PLAN 16절 1번)로 기지를 지금 자리와 원래 자리의
    -- 중간으로 옮기고 BaseExit를 얼음 쪽 가장자리에 다시 놓은 뒤, BaseExit에서 얼음 후보지까지 수평 거리(studs).
    -- 자율주행 왕복은 BaseExit에서 시작한다. 가까운 순서 Ice4, Ice5, Ice1, Ice3, Ice2.
    -- 이전 값(2026-11-14 얼음 쪽 기지): Ice1 314, Ice2 430, Ice3 504, Ice4 185, Ice5 610
    -- 처음 값(착륙선 기준): Ice5 881, Ice4 1032, Ice1 1229, Ice3 1347, Ice2 1577
    iceSites = {
        { id = "Ice1", distance = 647 },
        { id = "Ice2", distance = 937 },
        { id = "Ice3", distance = 810 },
        { id = "Ice4", distance = 412 },
        { id = "Ice5", distance = 421 },
    },
    -- [측정 2026-11-15, 리드 전달] 수동 운전(멀티)은 RoverPark에서 출발. 지점마다 거리(studs).
    -- 자율주행(BaseExit 기준)과 가까운 순서가 조금 다르다(Ice5가 가장 가깝다). 규칙은 쓰지 않고 봇과 보고서만 쓴다
    -- 이전 값: Ice1 562, Ice2 548, Ice3 749, Ice4 402, Ice5 465
    manualDriveDistances = { Ice1 = 750, Ice2 = 1037, Ice3 = 910, Ice4 = 515, Ice5 = 412 },
    rover = {
        -- [sim, 2026-11-15 기지 이동 뒤] 자율주행 속도: 하루(30초)에 700 studs = 23.3 studs/s. 왕복 일수 = 2 x 거리 /
        -- (속도 x 지형 배율), 반올림, 최소 1일. Ice4 1.18일(1일), Ice5 1.20(1), Ice1 1.85(2), Ice3 2.31(2), Ice2 2.68(3)
        -- [Q37 목표 가까운 곳 약 1일, 먼 곳 약 3일]. 이 목표를 지키는 속도 범위는 550 ~ 749 (BALANCE_LOG 8절).
        -- 반올림 경계(x.5)에서 모두 60 studs 이상 떨어져 있다 (Ice3 875 이상이면 3일, Ice2 875 미만이면 2일).
        -- 이전 값 410 (2026-11-14 거리 185 ~ 610), 처음 1600 (옛 거리 881 ~ 1577)
        fsdStudsPerDay = 700,
        -- [Q7] 비용 = 이동 일수(반올림 전) x 하루당 에너지, 올림. [회의1, 손글씨] 가장 가까운 곳 왕복이 10 근처가 되게.
        -- [sim, 2026-11-15 기지 이동 뒤] 12 -> 9. 지점별 11, 11, 17, 21, 25 (이전 11, 19, 26, 30, 36).
        -- 솔로 결과를 가장 크게 움직이는 것은 가장 가까운 곳 비용이었다: 12로 두면 14 ~ 16이 되어 솔로 처음 실패가
        -- 28%에서 36 ~ 43%로 뛰었다. 9면 가장 가까운 곳 11(확정 밸런스와 같음)이고 결과가 7.5.1과 거의 같다.
        -- 속도 690 ~ 720이면 지점별 비용과 결과가 같다(평평한 구간). 멀티는 수동 운전이라 영향 없음.
        -- 이전 값 12 (2026-11-14 새 목표), 그 전 9
        energyPerTravelDay = 9,
        -- [Q30] 서둘러 가기: 시간 x0.65(v1 부스터 x1.6의 역수 근처), 에너지 x1.5, 위험 한 등급 위
        rushTimeFactor = 0.65,
        rushEnergyFactor = 1.5,
        -- [Q30] 파손 1 ~ 2회는 물을 싣고 돌아오고 다음 이동부터 10%씩 느려진다. 3회면 고장(지도 위에서 멈춤)
        maxDamage = 3,
        slowdownPerDamage = 0.1,
        repairEnergy = 10, -- v1 ROVER_DAMAGE.repairEnergy (주차 자리 R 수리, 걸어서 수리 공용)
        remoteRecoverDays = 1, -- [Q30] 원격 회수 1일, 싣고 있던 물은 잃는다
        remoteRecoverEnergy = 0, -- [제안] 회수 자체는 무료. 돌아온 뒤 수리비(repairEnergy)는 따로 낸다
        damageChanceMultiplier = 1, -- [Q30] C는 1, B는 2
        -- [Q30] 경로 위험. 거리로 정한다(2026-11-15 거리: Ice4, Ice5 낮음, Ice1, Ice3 중간, Ice2 높음).
        -- 경계는 이웃 지점 사이 가운데 근처: 421과 647 사이 530, 810과 937 사이 875.
        -- 지형 배율(speedFactor)은 옛 거리에서 1일 ~ 3일을 맞추려고 넣었던 값이다. 지금 거리는 거리만으로 1 ~ 3일이 되어 모두 1
        -- 확률은 C 가까운 곳 약 5% ~ 먼 곳 약 15% (바꾸지 않음). extreme은 높음 경로를 서둘러 갈 때만
        riskOrder = { "low", "mid", "high", "extreme" },
        risk = {
            low = { maxDistance = 530, damageChance = 0.05, speedFactor = 1 }, -- 이전 350, 처음 1100
            mid = { maxDistance = 875, damageChance = 0.10, speedFactor = 1 }, -- 이전 550, 처음 1450, 지형 0.85
            high = { damageChance = 0.15, speedFactor = 1 }, -- 이전 지형 0.7
            extreme = { damageChance = 0.25, speedFactor = 1 },
        } :: { [string]: RiskLevel },
    },
    -- [Q20 C, V2_PLAN 15.6] 메달: 지은(완공한) 시설로 판정. 금은 그 순간 임무 완료 [Q2]
    medalOrder = { "gold", "silver", "bronze" },
    medals = {
        bronze = { "farm" },
        silver = { "farm", "led", "nutrient" },
        gold = { "farm", "led", "nutrient", "hydroponics" }, -- 수경 재배의 선행 조건에 파이프가 있다
    },
}

-- B 발전 기지 (Mons Mouton Plateau) 자리 표시 -----------------------------------
-- [Q20] 메달 기준만 확정. 나머지 숫자는 C 다음에 시뮬레이션으로 정한다 (playable = false, 규칙이 아직 받지 않는다)
local missionB = {
    id = "B",
    playable = false,
    start = { energy = 70, water = 70, food = 70 },
    cap = 100,
    crew = { energy = 12, water = 3, food = 3 },
    panels = {
        cost = 4, -- [회의3] Frame 5는 E2, 카드는 E4 (미정)
        output = 4, -- [회의3] 장당 하루 4
        perDay = 1, -- [회의3] 하루 최대 1장
        total = 5, -- [회의3] 전체 5장
        installSeconds = 3,
    },
    facilityOrder = { "airlock", "farm", "tower", "powerline" }, -- CONTRACT_V2 시설 id
    facilities = {
        airlock = {
            kind = "airlock",
            cost = { energy = 0, water = 0 },
            buildDays = 2,
            upkeep = { energy = 2, water = 1 },
            requires = {},
            canPause = true,
            buildFrom = "outdoor",
        },
        -- [카드] E6 W4 F5, 3일, 유지 E3 F2, 식량 30. [Q11] 식량 비용 제외. 수확 주기는 C를 따른다 [제안]
        farm = {
            kind = "farm",
            cost = { energy = 6, water = 4 },
            buildDays = 3,
            upkeep = { energy = 3, water = 0 },
            requires = {},
            canPause = true,
            buildFrom = "outdoor",
            harvestEveryDays = 5,
            harvestAmount = 30,
        },
        -- [카드] 태양 전지 타워 E10 W6 F5, 3일, 유지 E3 W1 F2. [Q11] 식량 제외
        tower = {
            kind = "tower",
            cost = { energy = 10, water = 6 },
            buildDays = 3,
            upkeep = { energy = 3, water = 1 },
            requires = {},
            canPause = true,
            buildFrom = "outdoor",
            multi = true,
            maxCount = 3,
        },
        -- [카드] 전력 수송망 E8 W2 F3, 2일, 유지 E2 F1. [Q11] 식량 제외
        powerline = {
            kind = "powerline",
            cost = { energy = 8, water = 2 },
            buildDays = 2,
            upkeep = { energy = 2, water = 0 },
            requires = { "tower" },
            canPause = true,
            buildFrom = "outdoor",
            multi = true,
            maxCount = 3,
        },
    } :: { [string]: FacilityDef },
    towerSites = {
        { id = "Tower1", output = 15 }, -- [회의3, 손글씨] 지점별 하루 15 / 25 / 30
        { id = "Tower2", output = 25 },
        { id = "Tower3", output = 30 },
    },
    ice = { amountPerTrip = 30, cooldownDays = 3 },
    iceSites = {}, -- [손글씨] 얼음 매장 3곳. 거리는 B 지형이 들어오면 측정
    rover = {
        damageChanceMultiplier = 2, -- [Q30] B는 C의 두 배
        roverCount = 2, -- [회의3] 물 로버(솔로 자율주행) + 타워 로버(사람이 운전)
    },
    medalOrder = { "gold", "silver", "bronze" },
    medalTowers = { bronze = 1, silver = 2, gold = 3 }, -- [Q20] 수송망까지 연결해 가동한 타워 수
}

MissionConfig.MISSIONS = {
    C = missionC,
    B = missionB,
}

return MissionConfig
