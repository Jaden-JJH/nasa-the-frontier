--!strict
-- 그레이박스 맵 생성기 (CONTRACT 4절)
-- 디자이너 맵이 없으면 빈 Baseplate에서도 끝까지 플레이할 수 있게 Part로 맵을 만든다.
--   Workspace.LandingPads가 없으면: 지면, 착륙 패드 4곳, 얼음 매장지 8곳(Config.ICE_SITES), 바위, 조명
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

-- 기지 콘크리트 판 윗면 (월드 y). 착륙 패드 윗면은 이보다 0.5 위 (4차: 0.5 -> 1.5, 지형과 3 studs 단차)
local GROUND_TOP = 1.5
-- 지형 채움 범위. 어느 착륙 패드에서도 가장자리가 보이지 않게 넓힌다 (4차 추가: 1400 x 1100 -> 2600 x 2200)
local GROUND_SIZE = Vector3.new(2600, 4, 2200)
-- 중심 구역 (착륙지와 얼음이 있는 예전 맵 범위). 밖은 산포 바위와 크레이터 밀도를 낮춘다
local CORE_HALF_X, CORE_HALF_Z = 700, 550
local PART_MAX_SIZE = 2048 -- Roblox Part 한 변 최대 크기 (지형을 끈 평지 지면은 타일로 나눈다)
local LANDING_PAD_SIZE = Vector3.new(48, 1, 48) -- 윗면은 GROUND_TOP + 0.5 (기지 키트 바닥). 지면까지 아래로 늘려 묻는다
local ICE_SIZE = Vector3.new(14, 3, 14)
local ICE_LIGHT_RANGE = 18
local ICE_LIGHT_BRIGHTNESS = 1.2
local ICE_TRANSPARENCY = 0.1 -- 얼음 덩어리 (Part와 결정 메시 공통)

-- 달 지형 (Roblox Terrain). Terrain이 없는 환경(Lune 스모크)에서는 평평한 지면 Part로 대신한다
-- 기지는 콘크리트 판(윗면 GROUND_TOP) 위에 놓고, 지형은 그보다 APRON_TERRAIN_STEP 낮게 깐다.
-- Terrain 복셀은 4 studs이고 표면이 매끄럽게 부풀어서 1 stud 단차로는 판과 슬롯이 묻혔다(4차 플레이테스트).
-- false면 예전처럼 평평한 지면 Part 하나
local TERRAIN_ENABLED = true
local APRON_TERRAIN_STEP = 3 -- 판 윗면과 지형 윗면의 높이 차
local TERRAIN_TOP = GROUND_TOP - APRON_TERRAIN_STEP -- 지형 윗면 (y -1.5)
local SURFACE_Y = if TERRAIN_ENABLED then TERRAIN_TOP else GROUND_TOP -- 얼음, 바위가 놓이는 자연 지면
local TERRAIN_THICKNESS = 24
local TERRAIN_SEED_OFFSET = 1 -- 바위 배치와 다른 난수 흐름 (같은 시드에서 결정적)
local TERRAIN_EDGE_MARGIN = 10 -- 지형 특징을 맵 가장자리에서 띄우는 거리
local APRON_TERRAIN_CLEARANCE = 25 -- 콘크리트 판 가장자리에서 이 거리 안은 평지 유지 (크레이터, 언덕 금지)
local ICE_TERRAIN_CLEARANCE = 30 -- 얼음 지점 중심 반지름 안은 평지 유지
local CORRIDOR_CLEARANCE = 12 -- 착륙 패드에서 가장 가까운 얼음까지 폭 24 주행 회랑의 반폭 (지형, 바위 금지)
local FEATURE_ATTEMPTS = 60
local CRATER_RADIUS_MIN, CRATER_RADIUS_MAX = 12, 50 -- 복셀 4 studs라 반지름 12 미만은 만들지 않는다
local CRATER_DEPTH_RATIO = 0.2 -- 사발 깊이 = 반지름 x 비율 (얕은 사발)
local CRATER_RIM_HEIGHT_RATIO = 0.08 -- 테두리 둔덕 높이 = 반지름 x 비율
local CRATER_RIM_HEIGHT_MAX = 1.5
local CRATER_RIM_PIECES = 12 -- 테두리는 가장자리를 따라 작은 공을 둘러 만든다
local CRATER_RIM_PIECE_RATIO = 0.3 -- 테두리 공 반지름 = 크레이터 반지름 x 비율
local CRATER_RIM_PIECE_MIN = 4
local CRATERS_NEAR_SITE = { 8, 8, 9, 11 } -- 착륙지 주변 크레이터 (Pad4는 지형 위험 높음)
local CRATER_NEAR_REACH = 120 -- 착륙지 "주변" = 콘크리트 판 가장자리에서 크레이터 중심까지 이 거리 안
local BIG_NEAR_CRATERS = 2 -- 착륙지 주변 크레이터 중 앞의 이 개수는 크게 (기지에서 눈에 띄게)
local BIG_CRATER_RADIUS_MIN = 30
local CRATERS_SCATTERED = 18 -- 맵 전체 (중심 구역 밖은 OUTER_FEATURE_DENSITY배 밀도). 주변 36개와 합쳐 54개
local OUTER_FEATURE_DENSITY = 0.5 -- 중심 구역 밖 크레이터와 언덕 밀도 배율
local HILL_COUNT = 12
local HILL_RADIUS_MIN, HILL_RADIUS_MAX = 40, 80
local HILL_HEIGHT_MIN, HILL_HEIGHT_MAX = 2, 4 -- 지형 위로 솟는 높이

-- 기지 콘크리트 판 (지형을 켤 때 기지 키트에 포함): 키트 바닥 면적 + 여유, 윗면은 GROUND_TOP
local APRON_MARGIN = 8
local APRON_THICKNESS = 2
local RAMP_WIDTH, RAMP_LENGTH = 10, 10 -- 판 가장자리 4면 중앙의 경사로 (판과 지형 사이 3 studs 단차를 완만하게)
local RAMP_LANE_HALF = RAMP_WIDTH / 2 + 4 -- 경사로 앞 바위 금지 차선의 반폭
local greyboxTerrainBuilt = false -- 이번 세션에 지형을 켠 그레이박스 맵을 만들었는지 (콘크리트 판 여부)
local groundStats: GroundStats? = nil -- 이번 세션에 만든 그레이박스 지면 요약 (시작 로그용)
-- 이번 세션에 계획한 산 (테스트와 디버그용, DevMap.getMountains)
export type MountainPlan = {
    edgePeaks: number,
    ridges: { { a: Vector3, b: Vector3, width: number } },
    footprints: { { x: number, z: number, r: number } },
}
local mountainPlan: MountainPlan? = nil

-- 얼음 매장지 위치 (x, z). 왕복 시간이 게임 수치라 Config.ICE_SITES에서 온다 (2026-10-18: 8곳)
local ICE_POSITIONS: { Vector3 } = {}
for _, site in Config.ICE_SITES do
    table.insert(ICE_POSITIONS, Vector3.new(site.x, 0, site.z))
end

-- 각 패드가 기준으로 삼는 얼음 지점과 그 얼음에서 패드 쪽 방향 (Config.DEV_MAP.padLayout).
-- 패드 위치 = 얼음 위치 + 방향 x Config.DEV_MAP.iceDistanceBySite[i]
local PAD_LAYOUT: { { ice: number, direction: Vector3 } } = {}
for _, layout in Config.DEV_MAP.padLayout do
    table.insert(
        PAD_LAYOUT,
        { ice = layout.ice, direction = Vector3.new(layout.dirX, 0, layout.dirZ) }
    )
end

-- hard 매장지 둘레 바위 고리와 위험 경로 크레이터 (개수와 범위는 Config.DEV_MAP)
local HARD_RING_SEED_OFFSET = 2 -- 다른 바위 층과 독립된 난수 흐름 (기존 층 배치를 흔들지 않는다)
local ROUTE_SEED_OFFSET = 3
local ROUTE_T_MIN, ROUTE_T_MAX = 0.2, 0.85 -- 패드 -> 매장지 직선에서 크레이터를 놓는 구간 (비율)
local ROUTE_LATERAL = 35 -- 직선에서 옆으로 벗어나는 최대 거리 (직선 위를 막아 돌아가게)
local ROUTE_CRATER_RADIUS_MAX = 32
local HARD_FLANK_DISTANCE = { 85, 115 } -- hard 매장지 중심에서 양옆 크레이터 중심까지 (바위 고리 바깥)

-- 산 (2026-10-18): 가장자리 산맥이 지평선을 막고, 내부 능선이 패드 -> mid/hard 직선 경로를 가로막아 돌아가게 한다.
-- 봉우리 = 원뿔에 내접하는 공을 축 위로 쌓은 것 (FillBall만으로 원뿔 모양). 재질 Rock, 표토보다 어두운 회색
local MOUNTAIN_SEED_OFFSET = 4 -- 산 배치 난수 흐름 (크레이터와 언덕 흐름과 분리)
local EDGE_BAND = 200 -- 지형 가장자리에서 이 띠 안에 봉우리를 잇는다
local EDGE_PEAK_INSET = EDGE_BAND / 2 -- 봉우리 중심의 기본 위치 = 가장자리에서 띠 가운데
local EDGE_PEAK_JITTER = 30 -- 위 위치에서 흔드는 폭
local EDGE_PEAK_RADIUS = { 60, 120 } -- 바닥 반지름
local EDGE_PEAK_HEIGHT = { 40, 90 }
local EDGE_PEAK_STEP = 1.1 -- 다음 봉우리까지 거리 = 반지름 x 비율 (바닥 원이 서로 겹친다)
local RIDGE_COUNT = 5 -- 내부 능선 수 (4 ~ 6)
local RIDGE_LENGTH = { 120, 250 }
local RIDGE_WIDTH = { 40, 70 } -- 바닥 폭 (봉우리 바닥 반지름의 2배)
local RIDGE_HEIGHT = { 20, 45 }
local RIDGE_ROUTE_T = { 0.35, 0.65 } -- 패드 -> 매장지 직선에서 능선 중심을 놓는 구간 (비율)
local RIDGE_TILT = 20 -- 경로에 수직인 방향에서 흔드는 각도(도)
local RIDGE_PEAK_STEP = 0.7 -- 능선 봉우리 간격 = 바닥 반지름 x 비율
local MOUNTAIN_APRON_CLEARANCE = 60 -- 판 가장자리 + 25와 경사로 차선(판 + 55)을 모두 피한다
local MOUNTAIN_ICE_CLEARANCE = 40 -- 얼음 중심에서 산 바닥까지 (로버가 지나갈 틈 30 이상)
local MOUNTAIN_BASE_DEPTH = 0.5 -- 맨 아래 공 중심 깊이 = 바닥 반지름 x 비율
local MOUNTAIN_BALL_STEP = 0.6 -- 다음 공 중심 = 지금 공 반지름 x 비율만큼 위
local MOUNTAIN_MIN_BALL = 4 -- 이보다 작은 공은 쌓지 않는다 (복셀 4 studs)
local MOUNTAIN_FEATURE_GAP = 4 -- 크레이터, 언덕, 바위가 산 바닥 원에서 띄우는 거리
local MOUNTAIN_MATERIAL = Enum.Material.Rock

-- 바위 3층: 기지 둘레 고리, 주행 회랑 양옆 무더기, 맵 전체 산포 (개수는 Config.DEV_MAP)
local APRON_ROCK_GAP = 6 -- 콘크리트 판 가장자리에서 바위 가장자리까지 최소 거리
local BASE_RING_REACH = 45 -- 기지 둘레 고리 바깥 경계 (판 가장자리에서 바위 중심까지)
local NEAR_SCATTER_REACH = 200 -- 고리 바깥 ~ 이 거리까지는 산포 밀도를 Config.DEV_MAP.nearBaseScatterFactor배로
local ICE_CLEARANCE = 15 -- 얼음 중심 주변 바위 금지 거리
local CLUSTER_SPREAD = 22 -- 회랑 가장자리 밖으로 바위 무더기가 퍼지는 폭
local CLUSTER_BEYOND_ICE = 60 -- 회랑 방향으로 얼음 너머까지 무더기를 두는 거리
local CLUSTER_MIN_LENGTH = 140 -- 판 앞 가장자리에서 무더기 구간 최소 길이 (얼음이 가까운 Pad4도 조밀하게)
local ROCK_RADIUS_RATIO = 0.6 -- 바위 반지름 추정 = BOULDER_MAX x 비율 x 크기 배율 (간격 계산용)
local BIG_BOULDER_CHANCE = 0.1 -- 전체의 약 10%는
local BIG_BOULDER_SCALE = 2 -- 2배 크기
local BOULDER_MIN, BOULDER_MAX = 3, 8
local BOULDER_ATTEMPTS = 20
local BOULDER_EMBED_RATIO = 0.2 -- 바위 높이의 이 비율만큼 지면에 묻는다

-- 기지 키트 배치 상수 (Origin 기준 로컬 좌표, 앞쪽 = -Z = 얼음 방향) -------

local ORIGIN_SIZE = Vector3.new(4, 1, 4)
local FLOOR_Y = -ORIGIN_SIZE.Y / 2 -- 패드 윗면 높이
local EMBED = LANDING_PAD_SIZE.Y / 2 -- 패드 밖 콘크리트 판(패드 윗면보다 0.5 낮음)까지 바닥 파트를 아래로 늘리는 길이

local LANDER_CENTER = Vector3.new(0, 0, 6)
local LANDER_SIZE = Vector3.new(14, 10, 14) -- 폭, 높이, 깊이
local ROVER_CENTER = Vector3.new(0, 0, -16)
-- 로버 주차 위치 옆. 운전석에 앉은 채 하역 프롬프트(활성 거리 12)가 닿도록 로버에서 약 10 studs
local WATER_TANK_POSITION = Vector3.new(-10, 0, -14)
-- 로버 충전 패드 (2026-10-18): 로버 주차 자리 바로 아래, 물탱크 옆. 바닥보다 아주 조금만 올라와 바퀴를 들지 않는다
local CHARGE_PAD_SIZE = Vector3.new(12, 0.05, 12) -- 바닥 위로 보이는 크기 (아래로 EMBED만큼 묻는다)
local CHARGE_PAD_TRIM = 0.6 -- 노란 테두리 폭
local CHARGE_PAD_TRIM_HEIGHT = 0.06 -- 테두리 윗면 = 바닥 + 이 값 (로버 바퀴 여유 0.1보다 낮게)
local CHARGE_PAD_RING_DIAMETER = 5 -- 중앙 원판 지름
local CHARGE_PAD_RING_THICKNESS = 0.04
local CHARGE_PAD_RING_RAISE = 0.05 -- 원판 중심 = 바닥 + 이 값 (윗면 0.07, 바퀴 여유 0.1보다 낮게)
local WATER_TANK_SIZE = Vector3.new(6, 8, 6)
-- 로버 복구 콘솔: 착륙선 왼쪽 앞 판 위에 선 주황 기둥. 문 중심에서 14 studs 넘게 떨어뜨려
-- 문 앞에서는 콘솔 프롬프트(활성 거리 Config.ROVER_RECOVERY.promptDistance)가 뜨지 않게 한다
local ROVER_CONSOLE_SIZE = Vector3.new(1.4, 3.2, 1.4) -- 바닥 위로 보이는 크기
local ROVER_CONSOLE_FROM_DOOR = Vector3.new(-14, 0, -6.5) -- 문 중심 기준 (왼쪽 -X, 앞 -Z), 거리 약 15.4
local CONSOLE_PANEL_SIZE = Vector3.new(1.2, 0.15, 1.2) -- 기둥 윗면의 어두운 조작판
local RADAR_SIDE_GAP = 2 -- 레이더(지상 장비)는 착륙선 왼쪽(-X) 충돌 벽 바깥

local SOLAR_CENTER = Vector3.new(34, 0, 6)
-- 슬롯 수 = Config.PANELS_TOTAL (2026-10-18: 30 -> 25, 5 x 5). 열은 5로 두고 행은 패널 수에서 정한다
local SOLAR_COLUMNS = 5
local SOLAR_ROWS = math.ceil(Config.PANELS_TOTAL / SOLAR_COLUMNS)
-- 슬롯 한 칸 5 x 4, 간격 1 (필드 전체 약 29 x 24). 키트 패널 바닥 비율(약 1.29 : 1.67)에 맞춰
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
local ICE_CRYSTAL_EMBED = 0 -- 지면에 묻는 깊이 (4차: 바닥을 지형 윗면에 맞춘다)
local WATER_TANK_VISUAL_BOX = Vector3.new(7, 7, 7)
local PAD_RING_MAX_HEIGHT = 1.5 -- 링 메시 높이 상한
local PAD_RING_RAISE = 0.1 -- 링 윗면이 패드 윗면보다 이만큼만 올라오게 묻는다 (Ghost, Built와 겹치지 않게)
local MAST_BOX = Vector3.new(1.5, 2.5, 1.5) -- 착륙선 꼭대기 안테나 (높이 2.5)
local RADAR_BOX = Vector3.new(2.5, 2.5, 2.5) -- 착륙선 왼쪽 바닥의 지상 레이더 (높이 2.5)
local CONSOLE_MAST_BOX = Vector3.new(1, 1.5, 1) -- 로버 복구 콘솔 위 안테나 (높이 1.5)
local CRATE_SIZE = 3
local CRATE_BEHIND_GAP = 1 -- 착륙선 뒤 충돌 벽에서 상자 첫 줄 가장자리까지 (+Z)
local CRATE_SIDE_OFFSET = -9 -- 착륙선 중심에서 상자 첫 열 중심까지 (-X, 모듈 C 패드와 겹치지 않게 왼쪽 뒤)
local CRATE_PITCH = 3.8
local CRATE_YAWS = { 0, 12, -8, 20 } -- 2 x 2 상자의 회전(도)

-- 색상
local COLORS = {
    landingPad = Color3.fromRGB(150, 150, 155),
    ice = Color3.fromRGB(170, 225, 255),
    boulder = Color3.fromRGB(90, 88, 86), -- 표토와 어울리는 회색 바위 (KitImports 바위 메시도 이 색)
    regolith = Color3.fromRGB(128, 126, 122), -- 달 표토 (Terrain 재질 색)
    mountain = Color3.fromRGB(78, 77, 75), -- 산 (Terrain Rock 재질 색, 표토보다 어둡다)
    chargePad = Color3.fromRGB(38, 40, 46), -- 로버 충전 패드 (어두운 판)
    chargeTrim = Color3.fromRGB(245, 200, 40), -- 충전 패드 노란 테두리
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
    consolePanel = Color3.fromRGB(40, 42, 48), -- 콘솔 윗면 조작판
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
    -- 링 바닥이 패드 바닥(콘크리트 판 윗면)보다 내려가지 않게 높이를 제한한다
    local maxHeight = math.min(PAD_RING_MAX_HEIGHT, pad.Size.Y + PAD_RING_RAISE)
    KitImports.fitInto(ring, Vector3.new(pad.Size.X, maxHeight, pad.Size.Z), Vector3.zero)
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

-- 얼음 매장지 Attribute (CONTRACT 4절): Deposit(남은 양), DepositMax(처음 양), Difficulty
local function setIceAttributes(ice: BasePart, index: number)
    local def = Config.ICE_SITES[index]
    local amount = if def then def.deposit else Config.ICE_DEFAULT_DEPOSIT
    ice:SetAttribute("Deposit", amount)
    ice:SetAttribute("DepositMax", amount)
    ice:SetAttribute("Difficulty", if def then def.difficulty else "mid")
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
-- 기지 키트 바닥 사각형 (Origin 기준 x, z). 콘크리트 판이 있으면 판 자체
type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }
-- 착륙지 하나: 패드 중심(y 0), 얼음 쪽을 보는 수평 프레임, 가장 가까운 얼음
type Site = { position: Vector3, frame: CFrame, ice: Vector3 }
type RockLayer = "ring" | "corridor" | "scatter" | "near" | "hardRing"
type GroundStats = {
    edgePeaks: number,
    ridges: number,
    craters: number,
    routeCraters: number,
    hills: number,
    ring: number,
    corridor: number,
    scatter: number,
    near: number,
    hardRing: number,
}

-- xz 평면 거리
local function flatDistance(a: Vector3, b: Vector3): number
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

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
local function corridorDistance(point: Vector3, sites: { Site }): number
    local best = math.huge
    for _, site in sites do
        best = math.min(best, segmentDistance(point, site.position, site.ice))
    end
    return best
end

-- 기지 키트가 차지할 바닥 사각형. 판이 있으면 판, 없으면 키트 전체 범위 + APRON_MARGIN
local function kitFootprint(): Rect
    local kit = ServerStorage:FindFirstChild("BaseKit")
    if kit and kit:IsA("Model") then
        local frame = if kit.PrimaryPart then kit.PrimaryPart.CFrame else kit:GetPivot()
        local apron = kit:FindFirstChild("Apron")
        local target: Instance = if apron and apron:IsA("BasePart") then apron else kit
        local margin = if target == kit then APRON_MARGIN else 0
        local lo, hi = KitImports.boundsIn(target, frame)
        if lo.X < hi.X and lo.Z < hi.Z then
            return {
                minX = lo.X - margin,
                maxX = hi.X + margin,
                minZ = lo.Z - margin,
                maxZ = hi.Z + margin,
            }
        end
    end
    return { minX = -50, maxX = 50, minZ = -40, maxZ = 50 }
end

-- 점에서 착륙지에 놓일 기지 판 가장자리까지 xz 거리 (판 안이면 0)
local function apronDistance(point: Vector3, site: Site, rect: Rect): number
    local p = site.frame:PointToObjectSpace(Vector3.new(point.X, 0, point.Z))
    local dx = math.max(rect.minX - p.X, 0, p.X - rect.maxX)
    local dz = math.max(rect.minZ - p.Z, 0, p.Z - rect.maxZ)
    return math.sqrt(dx * dx + dz * dz)
end

-- 판 밖, 네 경사로 앞으로 뻗은 차선 안인지 (로버가 판에서 내려가는 길에 바위를 두지 않는다)
local function inRampLane(point: Vector3, site: Site, rect: Rect): boolean
    local p = site.frame:PointToObjectSpace(Vector3.new(point.X, 0, point.Z))
    local midX, midZ = (rect.minX + rect.maxX) / 2, (rect.minZ + rect.maxZ) / 2
    local reach = RAMP_LENGTH + BASE_RING_REACH
    local alongZ = math.abs(p.X - midX) < RAMP_LANE_HALF
        and p.Z > rect.minZ - reach
        and p.Z < rect.maxZ + reach
    local alongX = math.abs(p.Z - midZ) < RAMP_LANE_HALF
        and p.X > rect.minX - reach
        and p.X < rect.maxX + reach
    return alongZ or alongX
end

-- 판 둘레 띠 안의 무작위 점 (판 가장자리에서 reach 안). 사각형 범위에서 뽑고 띠 밖이면 nil
local function sampleAroundApron(rng: Random, site: Site, rect: Rect, reach: number): Vector3?
    local lx = rng:NextNumber(rect.minX - reach, rect.maxX + reach)
    local lz = rng:NextNumber(rect.minZ - reach, rect.maxZ + reach)
    local world = site.frame:PointToWorldSpace(Vector3.new(lx, 0, lz))
    if apronDistance(world, site, rect) > reach then
        return nil
    end
    return Vector3.new(world.X, 0, world.Z)
end

-- 중심 구역(착륙지와 얼음이 있는 범위) 안인지
local function inCore(x: number, z: number): boolean
    return math.abs(x) <= CORE_HALF_X and math.abs(z) <= CORE_HALF_Z
end

-- 거리에 따른 밀도 솎기: 중심 구역 밖의 후보는 factor 확률로만 받는다 (난수 1개를 항상 쓴다)
local function keepByDensity(rng: Random, x: number, z: number, factor: number): boolean
    local roll = rng:NextNumber()
    return inCore(x, z) or roll < factor
end

-- 판(W x H) 가장자리에서 거리 inner ~ outer 사이 띠의 넓이
local function bandArea(rect: Rect, inner: number, outer: number): number
    local w, h = rect.maxX - rect.minX, rect.maxZ - rect.minZ
    local function within(r: number): number
        return w * h + 2 * r * (w + h) + math.pi * r * r
    end
    return within(outer) - within(inner)
end

-- 바위를 놓아도 되는 자리인지 (radius = 바위 반지름 추정)
-- 기지 판 + APRON_ROCK_GAP, 경사로 차선, 주행 회랑, 얼음, 맵 경계, 크레이터와 언덕을 피한다
local function isClear(
    position: Vector3,
    radius: number,
    sites: { Site },
    rect: Rect,
    footprints: { Footprint }
): boolean
    local flat = Vector3.new(position.X, 0, position.Z)
    for _, f in footprints do
        if (flat - Vector3.new(f.x, 0, f.z)).Magnitude < f.r + radius then
            return false
        end
    end
    if corridorDistance(flat, sites) < CORRIDOR_CLEARANCE + radius then
        return false
    end
    for _, site in sites do
        if apronDistance(flat, site, rect) < APRON_ROCK_GAP + radius then
            return false
        end
        if inRampLane(flat, site, rect) then
            return false
        end
    end
    local iceClearance = math.max(ICE_CLEARANCE, ICE_SIZE.X / 2 + radius)
    for _, ice in ICE_POSITIONS do
        if flatDistance(flat, ice) < iceClearance then
            return false
        end
    end
    local halfX, halfZ = GROUND_SIZE.X / 2, GROUND_SIZE.Z / 2
    return math.abs(position.X) < halfX - radius and math.abs(position.Z) < halfZ - radius
end

type RockSet = { templates: { Model }, used: number }

-- 바위 1개. 난수는 메시 여부와 관계없이 같은 순서로 6개를 써서 바위 위치 배치가 항상 같다
local function makeBoulder(
    rng: Random,
    position: Vector3,
    parent: Instance,
    rocks: RockSet,
    scale: number
): Instance
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
        return rock
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
    return part
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

-- 바위 3층 (결정적): 기지 둘레 고리 -> 주행 회랑 양옆 무더기 -> 맵 전체 산포.
-- 각 바위에 Attribute BoulderLayer(ring, corridor, scatter). 얼음 반지름 ICE_CAP_RADIUS 안은 상한까지만
local function buildBoulders(
    terrain: Instance,
    sites: { Site },
    rect: Rect,
    footprints: { Footprint },
    stats: GroundStats
)
    local dev = Config.DEV_MAP
    local rng = Random.new(dev.seed)
    local folder = makeFolder("Boulders", terrain)
    local rocks = prepareRocks()
    local iceCounts: { number } = {}
    for index in ICE_POSITIONS do
        iceCounts[index] = 0
    end
    local function drawScale(): number
        return if rng:NextNumber() < BIG_BOULDER_CHANCE then BIG_BOULDER_SCALE else 1
    end
    local function radiusOf(scale: number): number
        return BOULDER_MAX * ROCK_RADIUS_RATIO * scale
    end
    -- source: 바위 모양에 쓸 난수 (hard 고리는 별도 흐름). hard 고리 바위는 얼음 주변 상한에 세지 않는다
    local function place(
        position: Vector3,
        layer: RockLayer,
        scale: number,
        source: Random?
    ): boolean
        if not isClear(position, radiusOf(scale), sites, rect, footprints) then
            return false
        end
        if layer ~= "hardRing" then
            local nearIce: { number } = {}
            for index, ice in ICE_POSITIONS do
                if flatDistance(position, ice) < dev.iceBoulderCapRadius then
                    if iceCounts[index] >= dev.iceBoulderCap then
                        return false
                    end
                    table.insert(nearIce, index)
                end
            end
            for _, index in nearIce do
                iceCounts[index] += 1
            end
        end
        local rock = makeBoulder(source or rng, position, folder, rocks, scale)
        rock:SetAttribute("BoulderLayer", layer)
        stats[layer] += 1
        return true
    end

    -- 1) 기지 둘레 고리: 판 가장자리 + APRON_ROCK_GAP ~ BASE_RING_REACH (경사로 차선은 비운다)
    for index, site in sites do
        for _ = 1, dev.baseRingBouldersBySite[index] or 0 do
            for _ = 1, BOULDER_ATTEMPTS do
                local scale = drawScale()
                local point = sampleAroundApron(rng, site, rect, BASE_RING_REACH)
                if point and place(point, "ring", scale) then
                    break
                end
            end
        end
    end

    -- 2) 주행 회랑 양옆 무더기 (회랑 안은 비운다). 판 앞 가장자리부터 얼음 너머까지
    for index, site in sites do
        local toIce = Vector3.new(site.ice.X - site.position.X, 0, site.ice.Z - site.position.Z)
        local dir = toIce.Unit
        local side = Vector3.new(-dir.Z, 0, dir.X)
        local frontEdge = -rect.minZ -- 패드 중심에서 판 앞 가장자리까지 (앞 = 얼음 쪽 = 로컬 -Z)
        local reach = math.max(toIce.Magnitude + CLUSTER_BEYOND_ICE, frontEdge + CLUSTER_MIN_LENGTH)
        for _ = 1, dev.boulderCountBySite[index] or 0 do
            for _ = 1, BOULDER_ATTEMPTS do
                local scale = drawScale()
                local along = rng:NextNumber(frontEdge, reach)
                local sign = if rng:NextNumber() < 0.5 then -1 else 1
                local lateral = CORRIDOR_CLEARANCE
                    + radiusOf(scale)
                    + rng:NextNumber(0, CLUSTER_SPREAD)
                if
                    place(site.position + dir * along + side * sign * lateral, "corridor", scale)
                then
                    break
                end
            end
        end
    end

    -- 3) 맵 전체 산포: 중심 구역은 기본 밀도, 밖은 scatterOuterDensity배 (거리에 따라 낮춘다)
    local scattered: { Vector3 } = {}
    for _ = 1, dev.scatterBoulders do
        for _ = 1, BOULDER_ATTEMPTS do
            local scale = drawScale()
            local position = Vector3.new(
                rng:NextNumber(-GROUND_SIZE.X / 2, GROUND_SIZE.X / 2),
                0,
                rng:NextNumber(-GROUND_SIZE.Z / 2, GROUND_SIZE.Z / 2)
            )
            if
                keepByDensity(rng, position.X, position.Z, dev.scatterOuterDensity)
                and place(position, "scatter", scale)
            then
                table.insert(scattered, position)
                break
            end
        end
    end

    -- 4) 기지 근처 추가 산포: 고리 바깥 ~ NEAR_SCATTER_REACH 띠의 산포 바위가
    --    중심 밀도 x nearBaseScatterFactor x 띠 넓이가 되도록 모자란 만큼 띠 안에 더 놓는다.
    --    (띠에는 크레이터, 회랑, 경사로 차선이 많아 3층 산포가 덜 들어가므로 실제 개수를 세어 채운다)
    local coreArea = 4 * CORE_HALF_X * CORE_HALF_Z
    local mapArea = GROUND_SIZE.X * GROUND_SIZE.Z
    local coreDensity = dev.scatterBoulders
        / (coreArea + dev.scatterOuterDensity * (mapArea - coreArea))
    local target = math.round(
        dev.nearBaseScatterFactor
            * coreDensity
            * bandArea(rect, BASE_RING_REACH, NEAR_SCATTER_REACH)
    )
    for _, site in sites do
        local existing = 0
        for _, position in scattered do
            local d = apronDistance(position, site, rect)
            if d >= BASE_RING_REACH and d <= NEAR_SCATTER_REACH then
                existing += 1
            end
        end
        for _ = 1, math.max(0, target - existing) do
            for _ = 1, BOULDER_ATTEMPTS do
                local scale = drawScale()
                local point = sampleAroundApron(rng, site, rect, NEAR_SCATTER_REACH)
                if
                    point
                    and apronDistance(point, site, rect) >= BASE_RING_REACH
                    and place(point, "near", scale)
                then
                    break
                end
            end
        end
    end

    -- 5) hard 매장지 바위 고리: 얼음 중심에서 hardRingRadius 사이에 hardRingRocks개.
    --    가장 가까운 착륙지 반대쪽에 60도 입구를 남겨 돌아 들어가게 한다 (얼음 중심 ICE_CLEARANCE 안은 isClear가 막는다)
    local ringRng = Random.new(dev.seed + HARD_RING_SEED_OFFSET)
    local minRocks, maxRocks = dev.hardRingRocks[1], dev.hardRingRocks[2]
    local minRadius, maxRadius = dev.hardRingRadius[1], dev.hardRingRadius[2]
    local gapHalf = math.rad(30)
    for index, def in Config.ICE_SITES do
        if def.difficulty == "hard" then
            local center = ICE_POSITIONS[index]
            local nearestPad, best = center, math.huge
            for _, site in sites do
                local d = flatDistance(site.position, center)
                if d < best then
                    nearestPad, best = site.position, d
                end
            end
            local away = Vector3.new(center.X - nearestPad.X, 0, center.Z - nearestPad.Z)
            local gapAngle = math.atan2(away.Z, away.X)
            local count = math.min(maxRocks, math.floor(ringRng:NextNumber(minRocks, maxRocks + 1)))
            local span = 2 * math.pi - 2 * gapHalf
            for k = 1, count do
                for _ = 1, BOULDER_ATTEMPTS do
                    local angle = gapAngle
                        + gapHalf
                        + span * (k - 0.5 + ringRng:NextNumber(-0.35, 0.35)) / count
                    local radius = ringRng:NextNumber(minRadius, maxRadius)
                    local point = center
                        + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
                    if place(point, "hardRing", 1, ringRng) then
                        break
                    end
                end
            end
        end
    end
end

-- 달 지형 계획 -----------------------------------------------------------
type Ball = { center: Vector3, radius: number, air: boolean, rock: boolean? }
type Ridge = { a: Vector3, b: Vector3, width: number }
type TerrainPlan = {
    balls: { Ball },
    footprints: { Footprint },
    mountainFootprints: { Footprint }, -- 봉우리 바닥 원 (크레이터, 언덕, 바위 금지)
    craters: number,
    routeCraters: number,
    hills: number,
    edgePeaks: number,
    ridges: { Ridge },
}

-- 공이 지표면(TERRAIN_TOP)과 만나는 원의 반지름 (안 만나면 0)
local function surfaceRadius(ball: Ball): number
    local dy = ball.center.Y - TERRAIN_TOP
    if math.abs(dy) >= ball.radius then
        return 0
    end
    return math.sqrt(ball.radius * ball.radius - dy * dy)
end

-- 공이 바꾸는 지표면 원이 보호 구역(기지 판 + 25, 얼음, 회랑)과 맵 경계를 침범하지 않는지
local function ballAllowed(ball: Ball, sites: { Site }, rect: Rect): boolean
    local r = surfaceRadius(ball)
    local flat = Vector3.new(ball.center.X, 0, ball.center.Z)
    for _, site in sites do
        if apronDistance(flat, site, rect) < APRON_TERRAIN_CLEARANCE + r then
            return false
        end
    end
    for _, ice in ICE_POSITIONS do
        if flatDistance(flat, ice) < ICE_TERRAIN_CLEARANCE + r then
            return false
        end
    end
    if corridorDistance(flat, sites) < CORRIDOR_CLEARANCE + r then
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
-- 원뿔 봉우리 하나: 바닥 반지름 radius, 높이 height. 원뿔에 내접하는 공을 축 위로 쌓는다. 반환: 공들, 바닥 원 반지름
local function planCone(cx: number, cz: number, radius: number, height: number): ({ Ball }, number)
    local slope = height / radius
    local k = math.sqrt(1 + slope * slope) -- 축 위 점에서 원뿔 옆면까지 거리 = (꼭대기 높이 - 점 높이) / k
    local apex = TERRAIN_TOP + height
    local y = TERRAIN_TOP - radius * MOUNTAIN_BASE_DEPTH
    local balls: { Ball } = {}
    local footprint = 0
    while true do
        local r = (apex - y) / k
        if r < MOUNTAIN_MIN_BALL then
            break
        end
        local ball: Ball = { center = Vector3.new(cx, y, cz), radius = r, air = false, rock = true }
        table.insert(balls, ball)
        footprint = math.max(footprint, surfaceRadius(ball))
        y += r * MOUNTAIN_BALL_STEP
    end
    return balls, footprint
end

-- 산 바닥 원이 보호 구역(판 + 60, 얼음 40, 주행 회랑)을 침범하지 않는지
local function mountainAllowed(
    cx: number,
    cz: number,
    footprint: number,
    sites: { Site },
    rect: Rect
): boolean
    local flat = Vector3.new(cx, 0, cz)
    for _, site in sites do
        if apronDistance(flat, site, rect) < MOUNTAIN_APRON_CLEARANCE + footprint then
            return false
        end
    end
    for _, ice in ICE_POSITIONS do
        if flatDistance(flat, ice) < MOUNTAIN_ICE_CLEARANCE + footprint then
            return false
        end
    end
    return corridorDistance(flat, sites) >= CORRIDOR_CLEARANCE + footprint
end

-- 직사각형 둘레(반폭 hx, hz) 위의 점. s는 (-hx, -hz)에서 시계 반대로 잰 거리
local function perimeterPoint(s: number, hx: number, hz: number): (number, number)
    local w, h = 2 * hx, 2 * hz
    if s < w then
        return -hx + s, -hz
    elseif s < w + h then
        return hx, -hz + (s - w)
    elseif s < 2 * w + h then
        return hx - (s - w - h), hz
    end
    return -hx, hz - (s - 2 * w - h)
end

-- 가장자리 산맥과 내부 능선 (결정적, 별도 난수). 크레이터와 언덕보다 먼저 계획해 그 바닥을 피하게 한다
local function planMountains(plan: TerrainPlan, sites: { Site }, rect: Rect)
    local dev = Config.DEV_MAP
    local rng = Random.new(dev.seed + MOUNTAIN_SEED_OFFSET)
    local function addCone(cx: number, cz: number, radius: number, height: number): boolean
        local balls, footprint = planCone(cx, cz, radius, height)
        if #balls == 0 or not mountainAllowed(cx, cz, footprint, sites, rect) then
            return false
        end
        for _, ball in balls do
            table.insert(plan.balls, ball)
        end
        local circle = { x = cx, z = cz, r = footprint }
        table.insert(plan.mountainFootprints, circle)
        table.insert(plan.footprints, circle)
        return true
    end
    -- 1) 가장자리 산맥: 띠 가운데를 따라 둘레를 돌며 바닥이 겹치게 잇는다
    local hx, hz = GROUND_SIZE.X / 2 - EDGE_PEAK_INSET, GROUND_SIZE.Z / 2 - EDGE_PEAK_INSET
    local perimeter = 4 * (hx + hz)
    local s = 0
    while s < perimeter do
        local radius = rng:NextNumber(EDGE_PEAK_RADIUS[1], EDGE_PEAK_RADIUS[2])
        local height = rng:NextNumber(EDGE_PEAK_HEIGHT[1], EDGE_PEAK_HEIGHT[2])
        local px, pz = perimeterPoint(s, hx, hz)
        local jx = rng:NextNumber(-EDGE_PEAK_JITTER, EDGE_PEAK_JITTER)
        local jz = rng:NextNumber(-EDGE_PEAK_JITTER, EDGE_PEAK_JITTER)
        if addCone(px + jx, pz + jz, radius, height) then
            plan.edgePeaks += 1
        end
        s += radius * EDGE_PEAK_STEP
    end
    -- 2) 내부 능선: 패드 -> mid(routeMidReach 안), hard(routeHardReach 안) 직선 경로를 가로지른다.
    --    봉우리 하나라도 보호 구역을 침범하면 그 자리는 버리고 다시 뽑는다
    local routes: { { from: Vector3, to: Vector3 } } = {}
    for padIndex, site in sites do
        for index, def in Config.ICE_SITES do
            local reach = if def.difficulty == "mid"
                then dev.routeMidReach
                elseif def.difficulty == "hard" then dev.routeHardReach
                else 0
            local to = ICE_POSITIONS[index]
            if
                reach > 0
                and PAD_LAYOUT[padIndex].ice ~= index
                and flatDistance(site.position, to) <= reach
            then
                table.insert(routes, { from = site.position, to = to })
            end
        end
    end
    if #routes == 0 then
        return
    end
    local offset = math.floor(rng:NextNumber(0, #routes))
    for k = 1, #routes do
        if #plan.ridges >= RIDGE_COUNT then
            break
        end
        local route = routes[(offset + k * 3) % #routes + 1] -- 서로 다른 패드와 매장지로 흩어지게 건너뛴다
        local dir = Vector3.new(route.to.X - route.from.X, 0, route.to.Z - route.from.Z)
        for _ = 1, FEATURE_ATTEMPTS do
            local center = route.from + dir * rng:NextNumber(RIDGE_ROUTE_T[1], RIDGE_ROUTE_T[2])
            local angle = math.rad(90 + rng:NextNumber(-RIDGE_TILT, RIDGE_TILT))
            local u = dir.Unit
            local axis = Vector3.new(
                u.X * math.cos(angle) - u.Z * math.sin(angle),
                0,
                u.X * math.sin(angle) + u.Z * math.cos(angle)
            )
            local length = rng:NextNumber(RIDGE_LENGTH[1], RIDGE_LENGTH[2])
            local width = rng:NextNumber(RIDGE_WIDTH[1], RIDGE_WIDTH[2])
            local height = rng:NextNumber(RIDGE_HEIGHT[1], RIDGE_HEIGHT[2])
            local baseRadius = width / 2
            local count = math.ceil(length / (baseRadius * RIDGE_PEAK_STEP)) + 1
            local cones: { { balls: { Ball }, x: number, z: number, r: number } } = {}
            local ok = true
            for i = 0, count - 1 do
                local p = center + axis * (-length / 2 + length * i / (count - 1))
                local h = height * rng:NextNumber(0.85, 1.15)
                local balls, footprint = planCone(p.X, p.Z, baseRadius, h)
                if #balls == 0 or not mountainAllowed(p.X, p.Z, footprint, sites, rect) then
                    ok = false
                    break
                end
                table.insert(cones, { balls = balls, x = p.X, z = p.Z, r = footprint })
            end
            if ok then
                for _, cone in cones do
                    for _, ball in cone.balls do
                        table.insert(plan.balls, ball)
                    end
                    local circle = { x = cone.x, z = cone.z, r = cone.r }
                    table.insert(plan.mountainFootprints, circle)
                    table.insert(plan.footprints, circle)
                end
                table.insert(plan.ridges, {
                    a = center - axis * (length / 2),
                    b = center + axis * (length / 2),
                    width = width,
                })
                break
            end
        end
    end
end

local function planTerrain(sites: { Site }, rect: Rect): TerrainPlan
    local rng = Random.new(Config.DEV_MAP.seed + TERRAIN_SEED_OFFSET)
    local plan: TerrainPlan = {
        balls = {},
        footprints = {},
        mountainFootprints = {},
        craters = 0,
        routeCraters = 0,
        hills = 0,
        edgePeaks = 0,
        ridges = {},
    }
    planMountains(plan, sites, rect)
    local halfX, halfZ = GROUND_SIZE.X / 2, GROUND_SIZE.Z / 2
    local function tryAdd(balls: { Ball }, footprint: number, cx: number, cz: number): boolean
        for _, ball in balls do
            if not ballAllowed(ball, sites, rect) then
                return false
            end
            -- 산 바닥 안에는 크레이터와 언덕을 두지 않는다
            local r = surfaceRadius(ball)
            for _, m in plan.mountainFootprints do
                local d = Vector3.new(ball.center.X - m.x, 0, ball.center.Z - m.z).Magnitude
                if d < m.r + r + MOUNTAIN_FEATURE_GAP then
                    return false
                end
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
            if not keepByDensity(rng, cx, cz, OUTER_FEATURE_DENSITY) then
                continue
            end
            local balls, footprint = planHill(
                cx,
                cz,
                rng:NextNumber(HILL_RADIUS_MIN, HILL_RADIUS_MAX),
                rng:NextNumber(HILL_HEIGHT_MIN, HILL_HEIGHT_MAX)
            )
            if tryAdd(balls, footprint, cx, cz) then
                plan.hills += 1
                break
            end
        end
    end
    -- 착륙지 주변: 판 가장자리에서 CRATER_NEAR_REACH 안 (지형 위험이 높은 곳일수록 많이).
    -- 앞의 BIG_NEAR_CRATERS개는 반지름 BIG_CRATER_RADIUS_MIN 이상으로 크게
    for index, site in sites do
        for k = 1, CRATERS_NEAR_SITE[index] or 0 do
            local minRadius = if k <= BIG_NEAR_CRATERS
                then BIG_CRATER_RADIUS_MIN
                else CRATER_RADIUS_MIN
            for _ = 1, FEATURE_ATTEMPTS do
                local radius = rng:NextNumber(minRadius, CRATER_RADIUS_MAX)
                local point = sampleAroundApron(rng, site, rect, CRATER_NEAR_REACH)
                if point then
                    local balls, footprint = planCrater(point.X, point.Z, radius)
                    if tryAdd(balls, footprint, point.X, point.Z) then
                        plan.craters += 1
                        break
                    end
                end
            end
        end
    end
    -- 맵 전체 (아래 위험 경로 크레이터는 이 뒤에 별도 난수로 더한다)
    for _ = 1, CRATERS_SCATTERED do
        for _ = 1, FEATURE_ATTEMPTS do
            local cx, cz = rng:NextNumber(-halfX, halfX), rng:NextNumber(-halfZ, halfZ)
            if not keepByDensity(rng, cx, cz, OUTER_FEATURE_DENSITY) then
                continue
            end
            local balls, footprint =
                planCrater(cx, cz, rng:NextNumber(CRATER_RADIUS_MIN, CRATER_RADIUS_MAX))
            if tryAdd(balls, footprint, cx, cz) then
                plan.craters += 1
                break
            end
        end
    end
    -- 위험 경로 (2026-10-18): 각 착륙지에서 mid, hard 매장지로 가는 직선 위와 hard 매장지 양옆.
    -- 회랑(최근접 얼음), 판 + 25, 얼음 30 안은 ballAllowed가 막는다
    local dev = Config.DEV_MAP
    local routeRng = Random.new(dev.seed + ROUTE_SEED_OFFSET)
    local function addCrater(cx: number, cz: number, radius: number): boolean
        local balls, footprint = planCrater(cx, cz, radius)
        if tryAdd(balls, footprint, cx, cz) then
            plan.craters += 1
            plan.routeCraters += 1
            return true
        end
        return false
    end
    -- hard 매장지 양옆: 가장 가까운 착륙지 방향의 수직 양쪽
    for index, def in Config.ICE_SITES do
        if def.difficulty == "hard" then
            local center = ICE_POSITIONS[index]
            local nearestPad, best = center, math.huge
            for _, site in sites do
                local d = flatDistance(site.position, center)
                if d < best then
                    nearestPad, best = site.position, d
                end
            end
            local toward = Vector3.new(nearestPad.X - center.X, 0, nearestPad.Z - center.Z).Unit
            local side = Vector3.new(-toward.Z, 0, toward.X)
            for _, sign in { -1, 1 } do
                for _ = 1, FEATURE_ATTEMPTS do
                    local distance =
                        routeRng:NextNumber(HARD_FLANK_DISTANCE[1], HARD_FLANK_DISTANCE[2])
                    local p = center
                        + side * sign * distance
                        + toward * routeRng:NextNumber(0, HARD_FLANK_DISTANCE[1] / 2)
                    if
                        addCrater(
                            p.X,
                            p.Z,
                            routeRng:NextNumber(CRATER_RADIUS_MIN, ROUTE_CRATER_RADIUS_MAX)
                        )
                    then
                        break
                    end
                end
            end
        end
    end
    -- 경로 목록: (착륙지, mid 또는 hard 매장지), 회랑 얼음은 뺀다
    local routes: { { from: Vector3, to: Vector3 } } = {}
    for padIndex, site in sites do
        for index, def in Config.ICE_SITES do
            local reach = if def.difficulty == "mid"
                then dev.routeMidReach
                elseif def.difficulty == "hard" then dev.routeHardReach
                else 0
            local to = ICE_POSITIONS[index]
            if
                reach > 0
                and PAD_LAYOUT[padIndex].ice ~= index
                and flatDistance(site.position, to) <= reach
            then
                table.insert(routes, { from = site.position, to = to })
            end
        end
    end
    local target = dev.routeCraters - plan.routeCraters
    if #routes > 0 then
        for k = 1, math.max(0, target) do
            local route = routes[(k - 1) % #routes + 1]
            local dir = Vector3.new(route.to.X - route.from.X, 0, route.to.Z - route.from.Z)
            local side = Vector3.new(-dir.Unit.Z, 0, dir.Unit.X)
            for _ = 1, FEATURE_ATTEMPTS do
                local p = route.from
                    + dir * routeRng:NextNumber(ROUTE_T_MIN, ROUTE_T_MAX)
                    + side * routeRng:NextNumber(-ROUTE_LATERAL, ROUTE_LATERAL)
                if
                    addCrater(
                        p.X,
                        p.Z,
                        routeRng:NextNumber(CRATER_RADIUS_MIN, ROUTE_CRATER_RADIUS_MAX)
                    )
                then
                    break
                end
            end
        end
    end
    return plan
end

-- 지형 적용: Terrain이 있으면 표토를 채우고 언덕과 크레이터를 만든다. 없으면 평평한 지면 Part
local function applyTerrain(plan: TerrainPlan, folder: Instance)
    local terrain = if TERRAIN_ENABLED then workspace:FindFirstChildOfClass("Terrain") else nil
    if not terrain then
        -- Part 한 변은 PART_MAX_SIZE까지라 같은 크기 타일로 나눈다
        local tilesX = math.ceil(GROUND_SIZE.X / PART_MAX_SIZE)
        local tilesZ = math.ceil(GROUND_SIZE.Z / PART_MAX_SIZE)
        local tileX, tileZ = GROUND_SIZE.X / tilesX, GROUND_SIZE.Z / tilesZ
        for ix = 1, tilesX do
            for iz = 1, tilesZ do
                makePart({
                    name = "MoonGround",
                    size = Vector3.new(tileX, GROUND_SIZE.Y, tileZ),
                    cframe = CFrame.new(
                        -GROUND_SIZE.X / 2 + (ix - 0.5) * tileX,
                        SURFACE_Y - GROUND_SIZE.Y / 2,
                        -GROUND_SIZE.Z / 2 + (iz - 0.5) * tileZ
                    ),
                    color = COLORS.regolith,
                    material = Enum.Material.Sand,
                    parent = folder,
                })
            end
        end
        return
    end
    local material = Enum.Material.Sand
    terrain:FillBlock(
        CFrame.new(0, TERRAIN_TOP - TERRAIN_THICKNESS / 2, 0),
        Vector3.new(GROUND_SIZE.X, TERRAIN_THICKNESS, GROUND_SIZE.Z),
        material
    )
    terrain:SetMaterialColor(material, COLORS.regolith)
    terrain:SetMaterialColor(MOUNTAIN_MATERIAL, COLORS.mountain)
    for _, ball in plan.balls do
        local fill = if ball.air
            then Enum.Material.Air
            elseif ball.rock then MOUNTAIN_MATERIAL
            else material
        terrain:FillBall(ball.center, ball.radius, fill)
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

-- 지면, 얼음 지점, 착륙 패드, 바위. rect = 기지 키트 판 사각형 (기지 키트를 먼저 만든 뒤 부른다)
local function buildTerrainAndSites(rect: Rect): GroundStats
    local terrain = makeFolder("DevTerrain", workspace)
    local padPositions: { Vector3 } = {}
    local sites: { Site } = {}
    for index in Config.SITES do
        local position = sitePadPosition(index)
        local ice = ICE_POSITIONS[PAD_LAYOUT[index].ice]
        table.insert(padPositions, position)
        -- 패드의 앞쪽(-Z, LookVector)이 얼음을 향한다. 복제된 기지의 로버가 얼음 쪽을 본다
        table.insert(sites, {
            position = Vector3.new(position.X, 0, position.Z),
            frame = CFrame.lookAt(
                Vector3.new(position.X, 0, position.Z),
                Vector3.new(ice.X, 0, ice.Z)
            ),
            ice = Vector3.new(ice.X, 0, ice.Z),
        })
    end
    local plan: TerrainPlan = if TERRAIN_ENABLED
        then planTerrain(sites, rect)
        else {
            balls = {},
            footprints = {},
            mountainFootprints = {},
            craters = 0,
            routeCraters = 0,
            hills = 0,
            edgePeaks = 0,
            ridges = {},
        }
    mountainPlan =
        { edgePeaks = plan.edgePeaks, ridges = plan.ridges, footprints = plan.mountainFootprints }
    applyTerrain(plan, terrain)

    local iceFolder = makeFolder("IceSites", workspace)
    for index, position in ICE_POSITIONS do
        -- 얼음 바닥은 자연 지면(SURFACE_Y) 위
        local ice = makePart({
            name = "Ice" .. index,
            size = ICE_SIZE,
            cframe = CFrame.new(position.X, SURFACE_Y + ICE_SIZE.Y / 2, position.Z),
            color = COLORS.ice,
            material = Enum.Material.Ice,
            parent = iceFolder,
        })
        setIceAttributes(ice, index)
        ServerUtil.safeCall("DevMap IceCrystal", dressIce, ice)
    end

    local padsFolder = makeFolder("LandingPads", workspace)
    for index, site in Config.SITES do
        -- 윗면은 GROUND_TOP + 0.5로 고정하고, 자연 지면(SURFACE_Y)까지 아래로 늘려 묻는다
        local padTop = GROUND_TOP + LANDING_PAD_SIZE.Y / 2
        local padHeight = padTop - SURFACE_Y + LANDING_PAD_SIZE.Y / 2
        local frame = sites[index].frame
        local pad = makePart({
            name = "Pad" .. index,
            size = Vector3.new(LANDING_PAD_SIZE.X, padHeight, LANDING_PAD_SIZE.Z),
            cframe = frame + Vector3.new(0, padTop - padHeight / 2, 0),
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
    local stats: GroundStats = {
        edgePeaks = plan.edgePeaks,
        ridges = #plan.ridges,
        craters = plan.craters,
        routeCraters = plan.routeCraters,
        hills = plan.hills,
        ring = 0,
        corridor = 0,
        scatter = 0,
        near = 0,
        hardRing = 0,
    }
    buildBoulders(terrain, sites, rect, plan.footprints, stats)
    buildLighting()
    return stats
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
        setIceAttributes(ice, index)
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
    -- 문은 닫혀 있으면 막힌다. 여닫기와 프롬프트는 Airlock 모듈이 맡는다
    makePart({
        name = "Door",
        size = Vector3.new(a.doorWidth, a.doorHeight, a.doorThickness),
        cframe = CFrame.new(cx, doorY, doorZ),
        color = COLORS.door,
        material = Enum.Material.Metal,
        canCollide = true,
        parent = entry,
    })
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

    -- 로버 복구 콘솔: 문 중심에서 왼쪽 앞으로 떨어진 판 위 기둥 (RoverRecovery가 프롬프트를 붙인다)
    local wallOut = Config.AIRLOCK.wallThickness
    local consolePosition = Vector3.new(cx, 0, doorZ) + ROVER_CONSOLE_FROM_DOOR
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
    makePart({
        name = "ConsolePanel",
        size = CONSOLE_PANEL_SIZE,
        cframe = CFrame.new(
            consolePosition.X,
            FLOOR_Y + ROVER_CONSOLE_SIZE.Y + CONSOLE_PANEL_SIZE.Y / 2,
            consolePosition.Z
        ),
        color = COLORS.consolePanel,
        material = Enum.Material.SmoothPlastic,
        canCollide = false,
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
        local consoleTop = Vector3.new(
            consolePosition.X,
            FLOOR_Y + ROVER_CONSOLE_SIZE.Y + CONSOLE_PANEL_SIZE.Y,
            consolePosition.Z
        )
        placeDecor("Antenna", CONSOLE_MAST_BOX, consoleTop, false, lander, "ConsoleAntenna")
    end)
    -- 상자 자리: 착륙선 뒤 충돌 벽 바깥, 왼쪽 (첫 상자의 바닥 중심)
    return Vector3.new(
        cx + CRATE_SIDE_OFFSET,
        0,
        hi.Z + wallOut + CRATE_BEHIND_GAP + CRATE_SIZE / 2
    )
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

-- 로버 충전 패드: 어두운 판 + 노란 테두리 4줄. 시작 시 로버가 이 위에 주차되어 있다
local function buildChargePad(kit: Model)
    local padCFrame, padTotal = slabCFrame(CFrame.identity, ROVER_CENTER, CHARGE_PAD_SIZE.Y)
    local pad = makePart({
        name = "ChargePad",
        size = Vector3.new(CHARGE_PAD_SIZE.X, padTotal, CHARGE_PAD_SIZE.Z),
        cframe = padCFrame,
        color = COLORS.chargePad,
        material = Enum.Material.SmoothPlastic,
        parent = kit,
    })
    local half = CHARGE_PAD_SIZE.X / 2 - CHARGE_PAD_TRIM / 2
    local trims = {
        { Vector3.new(0, 0, -half), Vector3.new(CHARGE_PAD_SIZE.X, 0, CHARGE_PAD_TRIM) },
        { Vector3.new(0, 0, half), Vector3.new(CHARGE_PAD_SIZE.X, 0, CHARGE_PAD_TRIM) },
        { Vector3.new(-half, 0, 0), Vector3.new(CHARGE_PAD_TRIM, 0, CHARGE_PAD_SIZE.Z) },
        { Vector3.new(half, 0, 0), Vector3.new(CHARGE_PAD_TRIM, 0, CHARGE_PAD_SIZE.Z) },
    }
    for _, trim in trims do
        local offset, size = trim[1], trim[2]
        local position = ROVER_CENTER + offset
        local trimCFrame, trimTotal = slabCFrame(CFrame.identity, position, CHARGE_PAD_TRIM_HEIGHT)
        local part = makePart({
            name = "ChargePadTrim",
            size = Vector3.new(size.X, trimTotal, size.Z),
            cframe = trimCFrame,
            color = COLORS.chargeTrim,
            material = Enum.Material.Neon,
            parent = pad,
        })
        part.CanCollide = false
    end
    -- 중앙 원판: 충전 중과 완충일 때만 보인다 (RoverBattery가 색과 투명도를 바꾼다)
    local ring = makePart({
        name = "ChargePadRing",
        size = Vector3.new(
            CHARGE_PAD_RING_THICKNESS,
            CHARGE_PAD_RING_DIAMETER,
            CHARGE_PAD_RING_DIAMETER
        ),
        cframe = CFrame.new(ROVER_CENTER.X, FLOOR_Y + CHARGE_PAD_RING_RAISE, ROVER_CENTER.Z)
            * CFrame.Angles(0, 0, math.rad(90)),
        color = COLORS.chargeTrim,
        material = Enum.Material.Neon,
        parent = pad,
    })
    ring.Shape = Enum.PartType.Cylinder
    ring.CanCollide = false
    ring.Transparency = 1
end

-- KitImports 장식: 착륙선 뒤 바닥에 상자 2 x 2 (cratesStart = 첫 상자 바닥 중심)
local function addCrates(kit: Model, cratesStart: Vector3)
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
                        cratesStart.X + column * CRATE_PITCH,
                        FLOOR_Y,
                        cratesStart.Z + row * CRATE_PITCH
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
-- 판은 x 방향으로 대칭이라 정면 경사로가 로버 차선(x = 0)에 온다. 가장자리 4면 중앙에 지형(APRON_TERRAIN_STEP 아래)으로
-- 내려가는 길이 RAMP_LENGTH 경사로
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
    local cratesStart = buildLander(kit)
    buildRover(kit)
    buildSolarField(kit)
    buildModulePads(kit)
    buildWaterTank(kit)
    buildChargePad(kit)
    ServerUtil.safeCall("DevMap Crates", addCrates, kit, cratesStart)
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

-- 이번 세션에 계획한 산 (그레이박스 지형을 만들지 않았으면 nil)
function DevMap.getMountains(): MountainPlan?
    return mountainPlan
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
    -- 기지 키트를 먼저 만든다: 지형과 바위가 키트 판 크기를 피해 배치되기 때문
    local buildSites = not workspace:FindFirstChild("LandingPads")
    if buildSites then
        greyboxTerrainBuilt = TERRAIN_ENABLED
    end
    if not ServerStorage:FindFirstChild("BaseKit") then
        buildBaseKit()
    end
    if buildSites then
        groundStats = buildTerrainAndSites(kitFootprint())
    elseif not workspace:FindFirstChild("IceSites") then
        buildIceOnly()
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
    local stats = groundStats
    if stats then
        print(
            string.format(
                "[DevMap] 지면: 판 윗면 y %.1f, 지형 윗면 y %.1f, 범위 %d x %d, 산 %d(가장자리 봉우리 %d, 내부 능선 %d), 크레이터 %d(위험 경로 %d), 언덕 %d, 바위 %d(기지 둘레 %d, 회랑 옆 %d, 산포 %d, 기지 근처 산포 %d, hard 고리 %d)",
                GROUND_TOP,
                SURFACE_Y,
                GROUND_SIZE.X,
                GROUND_SIZE.Z,
                stats.edgePeaks + stats.ridges,
                stats.edgePeaks,
                stats.ridges,
                stats.craters,
                stats.routeCraters,
                stats.hills,
                stats.ring + stats.corridor + stats.scatter + stats.near + stats.hardRing,
                stats.ring,
                stats.corridor,
                stats.scatter,
                stats.near,
                stats.hardRing
            )
        )
    else
        print("[DevMap] 지면: 디자이너 맵 사용 (Workspace.LandingPads 있음)")
    end
end

return DevMap
