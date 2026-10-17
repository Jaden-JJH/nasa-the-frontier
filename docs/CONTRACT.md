# The Frontier - 코드 계약 (CONTRACT v1)

이 문서는 서버 코드(src/server, src/shared)와 클라이언트 코드(src/client)가 서로 합의한 인터페이스다.
두 쪽은 병렬로 작성되므로 여기 적힌 이름, 타입, 의미를 바꾸지 않는다. 바꿔야 하면 이 문서를 먼저 고치고 양쪽을 같이 고친다.
수치는 전부 `src/shared/Config.lua`에서 온다. 코드에 숫자를 직접 쓰지 않는다.

## 1. Rojo 트리

| 폴더 | Roblox 경로 | 설명 |
|---|---|---|
| src/shared | ReplicatedStorage.Shared | Config, Remotes, Types, 순수 로직(시뮬레이션 계산) |
| src/server | ServerScriptService.Server | 서버 권위 게임 로직. `Main.server.lua`가 진입점 |
| src/client | StarterPlayer.StarterPlayerScripts.Client | UI와 표시. `Main.client.lua`가 진입점 |
| (project json) | ReplicatedStorage.Remotes | 빈 Folder. 서버가 시작 시 RemoteEvent들을 생성 |
| tests | (동기화 안 함) | Lune로 실행하는 순수 로직 테스트 |

## 2. Remotes 모듈 (`src/shared/Remotes.lua`)

```lua
local Remotes = require(ReplicatedStorage.Shared.Remotes)
Remotes.init()                 -- 서버 전용. ReplicatedStorage.Remotes 아래에 아래 이름의 RemoteEvent를 전부 생성
local ev = Remotes.get("StateUpdate")  -- 서버: 즉시 반환. 클라이언트: WaitForChild로 대기 후 반환
```

RemoteEvent 이름과 방향, 페이로드:

### 서버 -> 클라이언트

**StateUpdate** `(state: GameState)` - FireAllClients. 상태가 바뀔 때마다, 그리고 플레이어 입장 직후 그 플레이어에게 FireClient. 매 DayTick마다 최소 1회.

```lua
export type ModuleStatus = "locked" | "available" | "building" | "active"
export type ModuleState = {
    status: ModuleStatus,
    progress: number,     -- 0..1, building일 때만 의미
    daysLeft: number,     -- building일 때 남은 일수, 아니면 0
}
export type GameState = {
    phase: "selecting" | "landing" | "playing" | "won" | "lost",
    day: number,              -- 1부터. selecting 중에는 0
    totalDays: number,        -- Config.TOTAL_DAYS
    speed: number,            -- 1 또는 2
    energy: number,
    water: number,
    food: number,
    netEnergy: number,        -- 어제 대비 오늘 순증감. 첫날은 0
    netWater: number,
    netFood: number,
    panelsInstalled: number,
    panelsInstalledToday: number,
    panelsTotal: number,      -- Config.PANELS_TOTAL
    panelsPerDay: number,     -- Config.PANELS_PER_DAY
    modules: { A: ModuleState, B: ModuleState, C: ModuleState },
    rover: { tank: number, tankMax: number },
    siteId: number?,          -- 선택된 착륙 패드 1..4. selecting 중 nil
    siteName: string?,
    sunlight: number?,        -- 0..1
    missionText: string,      -- HUD 상단에 그대로 표시할 한국어 한 줄
    waterTrips: number,       -- 기지 물탱크 하역 횟수
    oxygenDeaths: number,
    shortageDays: number,     -- Food 또는 Water가 0인 연속 일수 (0..3)
    modulesStalled: boolean,  -- 오늘 전력 부족으로 모듈이 정지했는지
}
```

**OxygenUpdate** `(oxygen: number, max: number, inside: boolean)` - FireClient, 해당 플레이어에게만. 값이 바뀔 때 전송 (최대 초당 5회).

**Notify** `(text: string, kind: "info" | "warn" | "good")` - FireClient 또는 FireAllClients. 토스트 메시지. 예: "오늘 설치 한도에 도달했습니다", "자원이 부족합니다: Water 20 필요", "Habitat A 완공".

**SiteSelectionOpen** `(info: SiteSelectionInfo)` - FireAllClients. phase가 selecting일 때 전송. 늦게 들어온 플레이어에게도 FireClient.

```lua
export type SiteInfo = {
    id: number,               -- 1..4
    name: string,             -- 예: "Shackleton Rim"
    sunlight: number,         -- 0..1
    iceDistanceLabel: string, -- "멀다" | "중간" | "가깝다" | "매우 가깝다"
    hazardLabel: string,      -- "낮음" | "중간" | "높음"
    description: string,      -- 한 줄 설명 (한국어)
}
export type SiteSelectionInfo = {
    chooserUserId: number,    -- 선택 권한이 있는 플레이어
    chooserName: string,
    deadlineUnix: number,     -- workspace:GetServerTimeNow() 기준 자동 선택 시각 (클라이언트도 같은 함수로 비교)
    defaultSiteId: number,
    sites: { SiteInfo },
}
```

**LandingSequence** `(siteId: number, landerCFrame: CFrame)` - FireAllClients. phase가 landing으로 바뀔 때 1회. 클라이언트는 Config.LANDING_SECONDS 동안 카메라 연출을 하고 끝낸다. 서버는 같은 시간 뒤 phase를 playing으로 바꾼다.

**GameOver** `(result: GameOverInfo)` - FireAllClients.

```lua
export type GameOverInfo = {
    won: boolean,
    reason: string,           -- 한국어. 예: "Research Lab 완공", "물이 3일 연속 바닥났습니다", "90일 안에 완공하지 못했습니다"
    day: number,
    waterTrips: number,
    oxygenDeaths: number,
    siteName: string,
}
```

### 클라이언트 -> 서버

**SelectSite** `(siteId: number)` - 선택 권한자(chooserUserId)가 보낸 것만 서버가 수락. 범위 1..4 검증.

**SetSpeed** `(speed: number)` - 1 또는 2만 수락. 아무나 보낼 수 있음.

**RequestRestart** `()` - phase가 won 또는 lost일 때만 수락. 서버가 상태 리셋 후 selecting으로.

## 3. 서버 전용 모듈 경계 (src/server)

| 모듈 | 책임 |
|---|---|
| Main.server.lua | 부팅 순서: Remotes.init -> DevMap.ensure -> GameFlow.start |
| GameClock.lua | DayTick 신호. Config.DAY_SECONDS / speed 간격. 일시정지(phase가 playing 아닐 때) |
| ResourceState.lua | GameState 단일 테이블 보유. 변경 함수와 `publish()`(StateUpdate 송신). 순수 계산은 Shared.Simulation 호출 |
| LandingSite.lua | 선택 단계, 권한자, 타임아웃, BaseKit 복제와 배치 |
| SolarPanels.lua | InstallPad 프롬프트, 하루 설치 제한, 슬롯에 패널 복제 |
| Construction.lua | PadA/B/C 프롬프트, 비용 검증, 건설 타이머, 고스트/완성 모델 전환, 선행 조건 |
| WaterLoop.lua | 로버 탱크(Attribute "Tank"), 얼음 지점 프롬프트(만충), 물탱크 프롬프트(하역, 로버가 TANK_UNLOAD_DISTANCE 안에 있을 때만), 로버 복구(수동 프롬프트 + 자동) |
| Oxygen.lua | 플레이어별 산소. 실내 판정(OxygenZone 파트 안 또는 VehicleSeat 착석). 0이면 리스폰과 페널티 |
| GameFlow.lua | phase 전이, 승리/실패 판정, 재시작 |
| DevMap.lua | Workspace.LandingPads가 없으면 그레이박스 맵과 ServerStorage.BaseKit을 Part로 생성 |

`src/shared/Simulation.lua`는 Roblox API를 전혀 쓰지 않는 순수 함수 모음이다 (Lune 테스트 대상):
- `Simulation.dailyProduction(state, config) -> energy, water, food` (패널, Farm)
- `Simulation.dailyConsumption(state, config) -> energy, water, food` (크루 + 가동 모듈)
- `Simulation.applyDay(state, config) -> newState` (하루 처리. 에너지 0이면 모듈 정지 규칙 포함)
- `Simulation.canBuild(state, config, moduleId) -> ok, reasonText`
- `Simulation.checkEnd(state, config) -> "none" | "won" | "lost", reasonText`

## 4. 맵 인스턴스 계약 (Workspace, ServerStorage)

디자이너가 Studio에서 만들거나 DevMap이 Part로 생성한다. 이름과 Attribute가 정확히 일치해야 코드가 찾는다.

```
Workspace
  LandingPads (Folder)
    Pad1 .. Pad4 (Part, Anchored)   Attributes: SiteName(string), Sunlight(number 0..1),
                                     IceDistanceLabel(string), HazardLabel(string), Description(string)
  IceSites (Folder)
    Ice1 .. Ice3 (Part, Anchored)   얼음 지점. 로버가 150 studs 안에 오면 레이더 반응
  Base (Model)                      LandingSite가 BaseKit을 복제해 선택 패드 위에 놓은 결과. 시작 시 없음

ServerStorage
  BaseKit (Model, PrimaryPart = Origin)
    Origin (Part)                   패드 중심에 PivotTo로 맞춤
    Lander (Model)
      SpawnPoint (Part)             플레이어 스폰 위치
      OxygenZone (Part, CanCollide false, Transparency 1)   건물 내부(경계 상자를 각 면 1 stud 줄인 박스) + 문 앞 1 stud (2026-10-17 3차). 정면 문과 보이지 않는 충돌 벽은 코드가 생성
    Rover (Model, PrimaryPart 있음)
      DriverSeat (VehicleSeat)       Attributes: Tank(number) 서버가 관리
    SolarField (Model)
      InstallPad (Part)             ProximityPrompt 부착 대상. ActionText "패널 설치", HoldDuration Config.PANEL_INSTALL_HOLD
      Slots (Folder)
        Slot1 .. Slot30 (Part)      패널이 놓일 자리. 설치되면 PanelTemplate 복제본이 위에 생김
    ModulePads (Folder)
      PadA, PadB, PadC (Model)    Attribute ModuleId(string, A/B/C). 클라이언트 표지판이 이걸로 찾는다
        Pad (Part)                  ProximityPrompt 부착 대상. ActionText "건설 시작"
        Ghost (Model)               반투명 미리보기. building 중 표시
        Built (Model)               완공 모델. active 전에는 Parent를 ServerStorage로 빼두거나 투명
        OxygenZone (Part)           PadA에만 있음
    WaterTank (Part)                ProximityPrompt. ActionText "물 하역"
  PanelTemplate (Model)             태양광 패널 1장
```

ProximityPrompt 공통: `RequiresLineOfSight = false`, `MaxActivationDistance = 12`, `Style = Custom`(2026-10-17 변경). 서버는 ObjectText(대상 이름)와 ActionText(동작)만 채우고, 화면 표시는 클라이언트 PromptUI가 ProximityPromptService 이벤트로 그린다. 로버 탑승은 로버 섀시의 프롬프트(ObjectText "로버", ActionText "탑승")로 하며 Triggered 시 서버가 seat:Sit를 호출한다. 에어락 문 프롬프트(ObjectText "에어락", ActionText "열기", 거리 8)는 서버 Airlock 모듈이 관리하고 열림 상태를 문 Part의 Transparency와 CanCollide로 표현한다. 로버 복구 콘솔 프롬프트 거리는 8. 모듈 패드 표지판은 서버가 만들지 않고 클라이언트 PadSignUI가 PadX 모델의 Attribute `ModuleId`(A/B/C)와 state.modules로 그린다. 로버 얼음 프롬프트는 각 Ice 파트에 서버가 부착하고, 로버 DriverSeat에 플레이어가 앉아 있고 Ice와 로버 거리가 Config.ICE_PROMPT_DISTANCE 이내일 때만 Enabled.

## 5. 클라이언트 모듈 경계 (src/client)

| 모듈 | 책임 |
|---|---|
| Main.client.lua | Remotes 연결, 각 UI 모듈 init, phase에 따라 어느 화면을 보일지 결정 |
| TitleUI.lua | 타이틀 화면. 시작 버튼을 누르면 로컬에서만 숨김 (서버 phase는 이미 selecting) |
| SiteSelectUI.lua | SiteSelectionOpen 수신. 카드 4장. 권한자만 버튼 활성. 남은 시간 표시. SelectSite 송신 |
| LandingCamera.lua | LandingSequence 수신. Config.LANDING_SECONDS 동안 카메라 Scriptable로 하강 연출 후 Custom 복귀 |
| HUD.lua | StateUpdate 수신. Energy/Water/Food/Day, 순증감(+3/일 형식, 음수는 빨강), 패널 n/30 (오늘 k/3), 모듈 A/B/C 상태와 진행바, 로버 탱크, 미션 텍스트, 2배속 토글(SetSpeed) |
| OxygenBar.lua | OxygenUpdate 수신. 실외일 때 강조, 20 이하 경고 |
| PromptUI.lua | 커스텀 ProximityPrompt 표시(키 아이콘, ObjectText, ActionText, 홀드 진행 바). 서버 프롬프트는 전부 Style Custom |
| PadSignUI.lua | 모듈 패드 위 표지판(이름, 상태 배지, 진행 바, 비용). PadX의 ModuleId Attribute와 state.modules 사용 |
| RadarUI.lua | 로컬 계산. 자신이 DriverSeat에 앉아 있을 때만 표시. Workspace.IceSites 각 파트까지 거리로 점 크기와 방향 표시, Config.RADAR_RANGE 안이면 비프(사운드 선택) |
| ToastUI.lua | Notify 수신. 3초 표시 후 사라짐. 최대 3개 스택 |
| ResultUI.lua | GameOver 수신. 승리/실패 공용. 요약 수치. 재도전 버튼(RequestRestart) |

UI 스타일: 다크 배경(어두운 남색 계열), 흰 글씨, 강조색은 에너지 노랑, 물 하늘색, 식량 초록, 산소 주황. 폰트 GothamMedium 계열. 모바일 터치도 고려해 버튼 최소 44px.

## 6. Config 키 (src/shared/Config.lua)

GDD 4절의 값. 키 이름을 이대로 쓴다.

```lua
DAY_SECONDS = 10, TOTAL_DAYS = 90, SPEEDS = {1, 2},
LANDING_SECONDS = 5, SITE_SELECT_TIMEOUT = 30, DEFAULT_SITE_ID = 2,
START = { energy = 50, water = 25, food = 30 },  -- energy 50은 착륙선 잔여 배터리 (2026-10-17 플레이테스트 후 조정)
CREW = { food = 1, water = 1 },
PANELS_TOTAL = 30, PANELS_PER_DAY = 3, PANEL_OUTPUT = 1, PANEL_INSTALL_HOLD = 2,
MODULES = {
  A = { name = "Habitat", cost = { energy = 60, water = 20 }, buildDays = 5, upkeep = { energy = 3, water = 1 }, requires = {} },
  B = { name = "Farm", cost = { energy = 80, water = 30 }, buildDays = 5, upkeep = { energy = 5, water = 2 }, requires = {"A"}, foodPerDay = 2 },
  C = { name = "Research Lab", cost = { energy = 150, water = 30 }, buildDays = 7, upkeep = { energy = 8, water = 1 }, requires = {"A", "B"} },
},
MODULE_ORDER = {"A", "B", "C"},
ROVER = { tankMax = 40, fillHold = 3 }, ICE_PROMPT_DISTANCE = 20, RADAR_RANGE = 150,
OXYGEN = { max = 100, drainPerSecond = 100 / 60, refillPerSecond = 10, deathPenalty = { food = 1, water = 2 } },
SHORTAGE_DAYS_TO_LOSE = 3,
SITES = {
  { id = 1, name = "Shackleton Rim", sunlight = 1.00, iceDistanceLabel = "멀다", hazardLabel = "낮음", description = "전력은 넉넉하지만 얼음까지 길이 멀다" },
  { id = 2, name = "de Gerlache Ridge", sunlight = 0.85, iceDistanceLabel = "중간", hazardLabel = "중간", description = "모든 면에서 균형 잡힌 후보지" },
  { id = 3, name = "Malapert Massif", sunlight = 0.70, iceDistanceLabel = "가깝다", hazardLabel = "중간", description = "물은 가깝지만 발전이 느리다" },
  { id = 4, name = "Nobile Crater", sunlight = 0.60, iceDistanceLabel = "매우 가깝다", hazardLabel = "높음", description = "얼음이 코앞이지만 지형이 험하다" },
},
MISSION_TEXTS = { ... }  -- 단계별 미션 문구는 Config에 두고 서버가 state.missionText로 내려준다
```
