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
    unlocked: boolean,    -- 2026-10-18 추가. 선행 조건 충족 여부(비용과 무관)
    paused: boolean,      -- 2026-10-18 추가. 가동 중지(현재 Farm만 지원). true면 유지비와 생산 모두 없음
    upkeepText: string,   -- 2026-10-18 추가. 가동 중 유지비 요약 한 줄(예: "물 -2/일, 전력 -6/일, 식량 +2/일"), paused면 "대기 중", 미가동이면 ""
    shortfall: { energy: number, water: number },  -- 2026-10-18 추가. 착공에 부족한 양, 충분하면 0
    damaged: boolean,     -- 2026-10-18 15차 추가. 미세운석 외벽 손상. true면 생산(식량) 정지, 유지비는 계속, 가동 중지(paused)로 풀리지 않고 수리해야 false. upkeepText는 "외벽 손상: R로 수리 (전력 10)"
    activatedDay: number?, -- 2026-10-18 15차 후속 추가. 가동을 시작한 날(완공 DayTick 뒤의 day). 가동 전이면 nil. 미세운석 유예 기간 판정용
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
    rover: { tank: number, tankMax: number, damage: number, broken: boolean,
             battery: number, batteryMax: number, charging: boolean, away: boolean,
             boosting: boolean, boostHeat: number },  -- 2026-10-18 추가. boosting은 부스터 작동 중, boostHeat는 0..1 과열 게이지(1이면 쿨다운)  -- damage 0..3, broken은 damage >= 3. battery(2026-10-18 추가): 주행 중 초당 ROVER.batteryDrainPerSecond(0.3) 소모, 0이면 정지. charging은 충전 패드 위에서 빈 좌석일 때 true. away는 로버가 기지에서 ROVER.awayDistance(60) 밖에 있을 때 true(미션 문구용)
    energyCap: number,        -- 2026-10-18 추가. 에너지 저장 상한 = ENERGY_CAP_BASE(150) + 가동 모듈 수 x ENERGY_CAP_PER_MODULE(100)
    energyWasted: number,     -- 2026-10-18 추가. 오늘 상한 때문에 버려진 전력
    siteId: number?,          -- 선택된 착륙 패드 1..4. selecting 중 nil
    siteName: string?,
    sunlight: number?,        -- 0..1
    missionText: string,      -- HUD 상단에 그대로 표시할 한국어 한 줄
    waterTrips: number,       -- 기지 물탱크 하역 횟수
    oxygenDeaths: number,
    shortageDays: number,     -- Food 또는 Water가 0인 연속 일수 (0..3)
    modulesStalled: boolean,  -- 오늘 전력 부족으로 모듈이 정지했는지
    missionStage: string,     -- 2026-10-18 추가. "panels" | "board_rover" | "find_ice" | "unload" | "build_A" | "build_B" | "build_C" | "done". 클라이언트가 목표 대상 Highlight에 사용
    daysLeft: { water: number, food: number },  -- 2026-10-18 추가. 현재 소비율 기준 남은 일수(소비 0이면 999)
    stallReason: string,      -- 2026-10-18 추가. 모듈 정지 사유 한국어 한 줄, 정지 아니면 ""
    event: ActiveEvent?,      -- 2026-10-18 15차 추가. 지금 예고 중이거나 진행 중인 랜덤 이벤트(HUD 배너). 없으면 nil
    eventSchedule: { EventEntry },  -- 2026-10-18 15차 추가. 이번 게임 이벤트 일정(서버 규칙용). StateUpdate에 함께 실리지만 클라이언트는 읽지 않는다(예고는 event로만 보여 준다)
}

-- 랜덤 이벤트 (2026-10-18 15차). 수치와 문구는 Config.EVENTS, Config.TEXTS
export type EventKind = "solarStorm" | "micrometeoroid"
export type ActiveEvent = {
    kind: EventKind,
    stage: "warning" | "active",  -- warning: 폭풍 예고(시작 warningDays일 전부터), active: 폭풍 진행 중 또는 운석 충돌 뒤 bannerDays일
    daysLeft: number,             -- warning: 시작까지 남은 일수(D-n), active: 끝까지 남은 일수(오늘 포함)
    text: string,                 -- 배너 한 줄. 예: "태양 입자 폭풍 D-2", "태양 입자 폭풍 진행 중 (남은 1일)", "미세운석 충돌: Farm B 외벽 손상"
    eduText: string,              -- 배너 아래 교육 한 줄 (TEXTS.stormEdu, meteorEdu)
}
export type EventEntry = {
    kind: EventKind,
    day: number,          -- 폭풍: 진행 첫날. 운석: 충돌 날(그날로 넘어가는 DayTick에 처리)
    duration: number,     -- 폭풍: 진행 일수. 운석: 배너 일수
    warningDays: number,  -- 폭풍 예고 일수, 운석 0
    roll: number,         -- 운석 대상 고르기 난수 0..1
    resolved: boolean,    -- 운석을 처리했는지
    target: string,       -- 운석 결과 "A" | "B" | "C" | "panel" | "none", 폭풍은 ""
}
```

랜덤 이벤트 규칙(2026-10-18 15차): 일정은 새 게임마다 서버가 시드로 정한다(`Simulation.newState(config, seed)`). 폭풍은 진행 중 패널 발전 x EVENTS.solarStorm.panelMultiplier(0.5), 실외 산소 소모 x outdoorOxygenMultiplier(1.5, 실내와 로버 좌석은 영향 없음). 운석은 손상되지 않은 가동 모듈(승리 모듈 제외, 가동 첫날부터 graceDaysAfterActivation(5)일 안인 모듈 제외, noRepeatTarget이면 직전 운석이 때린 모듈 제외) 중 roll로 하나를 damaged로, 없으면 설치된 패널 1장 파괴(0 아래 없음), 패널도 0이면 빗나감. 일정과 효과는 DayTick에서만 전진한다.

**OxygenUpdate** `(oxygen: number, max: number, inside: boolean)` - FireClient, 해당 플레이어에게만. 값이 바뀔 때 전송 (최대 초당 5회).

**Notify** `(text: string, kind: "info" | "warn" | "good")` - FireClient 또는 FireAllClients. 토스트 메시지. 예: "오늘 설치 한도에 도달했습니다", "자원이 부족합니다: Water 20 필요", "Habitat A 완공". 랜덤 이벤트(15차): 폭풍 예고 TEXTS.stormWarning(warn), 시작 stormStart(warn), 끝 stormEnd(good), 운석 meteorModule / meteorPanel(warn), meteorMiss(info), 수리 moduleRepaired(good).

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
    restartAvailableAt: number,  -- 2026-10-18 추가. workspace:GetServerTimeNow() 기준 재도전 가능 시각(결과 화면 후 RESULT_MIN_SECONDS)
    chooserUserId: number,       -- 2026-10-18 추가. 재도전을 결정할 수 있는 플레이어
    crew: { CrewRow },           -- 2026-10-19 16차 추가. 플레이어별 기여도, 기여 합이 큰 순(최대 RECORDS.crewRows 4명). 순위 표기 없음(협력 게임, MVP 없음)
}
export type CrewRow = {          -- 2026-10-19 16차. 나간 플레이어도 남는다. 새 게임(beginNewGame)마다 초기화
    name: string,                -- DisplayName
    panels: number,              -- 패널 설치 성공 수 (SolarPanels)
    water: number,               -- 물 하역량 W, 전력 부족으로 일부만 처리하면 처리한 양 (WaterLoop)
    builds: number,              -- 착공 수 (Construction)
    repairs: number,             -- 로버 수리 + 모듈 외벽 수리 (RoverDamage, ModuleRepair)
    deaths: number,              -- 산소 고갈(산소 0) + 쓰러짐(초기화, 추락) 횟수 (Oxygen). 합은 요약의 oxygenDeaths와 같다
}
```

정렬용 기여 합 = panels + builds + repairs + water x RECORDS.crewWaterWeight(0.1). 같으면 먼저 들어온 순. GameOver에는 rank를 넣지 않는다.

**Records** `(payload: RecordsPayload)` - 2026-10-19 16차 추가. 승리 기록 상위 목록. 플레이어 입장 때 FireClient(서버 시작 로드가 끝났으면 즉시, 아니면 로드가 끝날 때 FireAllClients), 승리 기록 저장이 끝나면 FireAllClients(submitted = true). GameOver는 지금처럼 즉시 보내고 순위는 이 이벤트가 뒤따른다.

```lua
export type RecordEntry = { days: number, site: string, crew: { string }, at: number, version: number }  -- Shared.Ranking.Entry. crew는 기여 순 최대 RECORDS.crewNameLimit(4)명, at은 os.time()
export type RecordsPayload = {
    entries: { RecordEntry },    -- 상위 RECORDS.maxEntries(10)개, 순위 순 (일수 오름차순, 같으면 at 오름차순)
    rank: number?,               -- submitted일 때 이번 승리의 순위. 상위 밖이면 nil
    status: "loading" | "ok" | "offline",  -- offline: DataStore를 못 써서 이번 서버 메모리 기록만 (TEXTS.recordsOffline 표시)
    submitted: boolean,          -- true면 방금 끝난 승리를 반영한 결과
}
```

### 클라이언트 -> 서버

**SelectSite** `(siteId: number)` - 선택 권한자(chooserUserId)가 보낸 것만 서버가 수락. 범위 1..4 검증.

**SetSpeed** `(speed: number)` - 1 또는 2만 수락. 아무나 보낼 수 있음.

**RoverBoost** `(on: boolean)` - 2026-10-18 추가. 운전자(DriverSeat 탑승자)만 수락. 서버가 배터리 >= ROVER.boostMinBatteryRatio(0.2)와 과열 상태를 검증. 부스터 중 속도 x ROVER.boostSpeedMultiplier(1.6), 배터리 소모 x ROVER.boostDrainMultiplier(3). 연속 ROVER.boostMaxSeconds(4) 뒤 ROVER.boostCooldownSeconds(6) 쿨다운. 하차하면 자동 해제.

**RequestRestart** `()` - phase가 won 또는 lost이고 결과 화면이 뜬 지 Config.RESULT_MIN_SECONDS(10) 이상 지났을 때, 선택 권한자(chooser)만 수락(2026-10-18 리뷰 반영). 서버가 상태 리셋 후 selecting으로.

## 3. 서버 전용 모듈 경계 (src/server)

| 모듈 | 책임 |
|---|---|
| Main.server.lua | 부팅 순서: Remotes.init -> DevMap.ensure -> GameFlow.start |
| GameClock.lua | DayTick 신호. Config.DAY_SECONDS / speed 간격. 일시정지(phase가 playing 아닐 때) |
| ResourceState.lua | GameState 단일 테이블 보유. 변경 함수와 `publish()`(StateUpdate 송신). 순수 계산은 Shared.Simulation 호출 |
| LandingSite.lua | 선택 단계, 권한자, 타임아웃, BaseKit 복제와 배치 |
| SolarPanels.lua | InstallPad 프롬프트, 하루 설치 제한, 슬롯에 패널 복제. syncCount(15차): 월드 패널 수를 state.panelsInstalled에 맞춘다(운석 파괴면 번호가 큰 Panel{n}부터 지우고 충돌음, 다음 설치가 같은 슬롯을 채운다) |
| Construction.lua | PadA/B/C 프롬프트, 비용 검증, 건설 타이머, 고스트/완성 모델 전환, 선행 조건 |
| WaterLoop.lua | 로버 탱크(Attribute "Tank"), 얼음 지점 프롬프트(매장량만큼 채움, 고갈 처리), 물탱크 프롬프트(하역, 로버가 TANK_UNLOAD_DISTANCE 안에 있을 때만, 하역 1 W당 WATER_PROCESS_ENERGY_PER_W 에너지 소모, 에너지가 모자라면 처리 가능한 만큼만), 로버 복구(수동 프롬프트 + 자동) |
| Sfx.lua | 2026-10-18 추가. 서버 3D 효과음 재생 헬퍼. Shared.SoundIds의 키로 Sound를 만들어 파트에 붙여 재생(id 0이면 무음). 루프 사운드는 핸들을 돌려줘 멈출 수 있음 |
| RoverBattery.lua | 2026-10-18 추가. 로버 배터리 소모(주행 중, 속도 > 1일 때만), 0이면 RoverDrive 속도 배율 0. 충전 패드 판정과 충전(기지 에너지 차감). 25% 이하 경고 Notify 1회(충전되면 리셋) |
| RoverDamage.lua | 2026-10-18 추가. 바위(Attribute BoulderLayer)와 12 studs/s 이상 충돌 시 파손 +1(1초 중복 방지), 파손당 최고 속도 10% 감소(파손 1: 16.2, 파손 2: 14.4), 3이면 정지. 로버 섀시의 "수리" 프롬프트(키 R, 홀드 4초, 에너지 10, 좌석 비어 있을 때)로 복구. 탑승 프롬프트(E)와 같은 섀시라 키를 나눔. Config.ROVER_DAMAGE.enabled로 끌 수 있음 |
| Events.lua | 2026-10-18 15차 추가. DayTick 앞뒤 상태를 Simulation.eventNotices로 비교해 랜덤 이벤트 토스트(폭풍 예고, 시작, 끝, 운석 충돌)를 보내고 운석이 모듈을 때리면 그 Pad에서 rover_hit 효과음. 규칙은 전부 Simulation |
| ModuleRepair.lua | 2026-10-18 15차 추가. PadA/B/C의 Pad 파트마다 "외벽 수리" 프롬프트(이름 RepairPrompt, 키 EVENTS.micrometeoroid.repairKey R, 홀드 repairHold 4초, 거리 promptDistance 12). 그 모듈이 damaged이고 플레이 중일 때만 켜짐. Simulation.repairModule(전력 repairEnergy 10, 모자라면 거절 토스트). 홀드 동안 rover_repair 루프. 건설 프롬프트가 Pad의 첫 프롬프트로 남도록 Construction 다음에 붙인다 |
| Oxygen.lua | 플레이어별 산소. 실외 소모에 Simulation.outdoorOxygenMultiplier(폭풍 중 1.5)를 곱한다(15차). 실내 판정(OxygenZone 파트 안 또는 VehicleSeat 착석). 0이면 즉시 GameFlow.lose(2026-10-18 12차). 그 외 사망(리셋)에는 Food -1, Water -2 |
| GameFlow.lua | phase 전이, 승리/실패 판정, 재시작 |
| DevMap.lua | Workspace.LandingPads가 없으면 그레이박스 맵과 ServerStorage.BaseKit을 Part로 생성 |
| Contributions.lua | 2026-10-19 16차 추가. 플레이어별 기여도(서버 메모리, UserId 키, 나간 플레이어도 유지). 각 시스템 성공 지점에서 add(player, field, amount). reset()은 beginNewGame. crew(limit)은 GameOverInfo.crew, names(limit)은 승리 기록 승무원 |
| Records.lua | 2026-10-19 16차 추가. DataStore(RECORDS.datastoreName "FrontierRecords", 키 "top")에 상위 10개. 서버 시작 때 1회 GetAsync, 승리 때 submit -> UpdateAsync 병합 후 순위 계산. 모든 호출은 task.spawn 안에서 pcall + 1회 재시도(RECORDS.retryDelay 1초). 서비스가 없거나 실패하면 서버 메모리 목록으로 전환(status offline). 프롬프트 처리 함수 안에서 yield하지 않는다 |
| RecordBoard.lua | 2026-10-19 16차 추가. 기지가 놓일 때(onBasePlaced) Base 아래에 RecordBoard 파트와 SurfaceGui "명예의 전당"(상위 5줄, 상태 문구)을 만들고 Records가 바뀌면 글자만 갱신. 재시작 때 detach. 자리는 DevMap.RECORD_BOARD |

`src/shared/Simulation.lua`는 Roblox API를 전혀 쓰지 않는 순수 함수 모음이다 (Lune 테스트 대상):
- `Simulation.dailyProduction(state, config) -> energy, water, food` (패널, Farm)
- `Simulation.dailyConsumption(state, config) -> energy, water, food` (크루 + 가동 모듈)
- `Simulation.applyDay(state, config) -> newState` (하루 처리. 에너지 0이면 모듈 정지 규칙 포함)
- `Simulation.canBuild(state, config, moduleId) -> ok, reasonText`
- `Simulation.fillFromDeposit(tank, tankMax, deposit) -> fill, newTank, newDeposit` (2026-10-18 추가)
- `Simulation.checkEnd(state, config) -> "none" | "won" | "lost", reasonText`
- `Simulation.newState(config, seed?) -> GameState` (2026-10-18 15차: seed로 이벤트 일정. 없으면 os.time())
- `Simulation.makeEventSchedule(config, seed) -> { EventEntry }` (같은 시드면 같은 일정. EVENTS.enabled = false면 빈 목록)
- `Simulation.currentEvent(state, config) -> ActiveEvent?`, `Simulation.stormActive(state, config) -> boolean`, `Simulation.outdoorOxygenMultiplier(state, config) -> number`
- `Simulation.eventNotices(prev, new, config) -> { { text, kind, target? } }` (DayTick 토스트 목록)
- `Simulation.repairModule(state, config, moduleId) -> ok, newState, text, kind`

`src/shared/Ranking.lua`(2026-10-19 16차)도 순수 함수 모음이다 (Lune 테스트 대상, 서버 Records와 클라이언트 표시가 같이 쓴다):
- `Ranking.insert(list, entry, maxEntries) -> newList, rank?` (원본은 바꾸지 않음. 상위 밖이거나 잘못된 항목이면 rank nil. 같은 기록은 두 번 넣지 않음)
- `Ranking.sanitize(raw, maxEntries) -> { Entry }` (저장값에서 올바른 항목만 정렬, 중복 제거, 상한)
- `Ranking.isValid(entry)`, `Ranking.before(a, b)`, `Ranking.find(list, entry) -> rank?`
- `Ranking.formatLine(entry, rank, config) -> "1위  32일  Shackleton Rim  Alice, Bob 외 1명  10/19"` (날짜는 RECORDS.utcOffsetHours 9, 한국 시간)

## 4. 맵 인스턴스 계약 (Workspace, ServerStorage)

디자이너가 Studio에서 만들거나 DevMap이 Part로 생성한다. 이름과 Attribute가 정확히 일치해야 코드가 찾는다.

```
Workspace
  LandingPads (Folder)
    Pad1 .. Pad4 (Part, Anchored)   Attributes: SiteName(string), Sunlight(number 0..1),
                                     IceDistanceLabel(string), HazardLabel(string), Description(string)
  IceSites (Folder)
    Ice1 .. Ice8 (Part, Anchored)   얼음 지점(2026-10-18: 3곳에서 8곳으로, 위치와 매장량은 Config.ICE_SITES). 매장량 easy 30, 30 / mid 40, 50, 40 / hard 70, 70, 65 (합계 395). Attributes: Deposit(number, 남은 매장량 W), DepositMax(number), Difficulty(string: "easy" | "mid" | "hard"). hard 지점은 바위 고리(입구 60도)로 둘러싸임.
                                     채취하면 Deposit이 줄고 0이면 결정이 사라지며 프롬프트가 꺼진다(Part는 남음). 클라이언트 레이더는 Deposit > 0인 지점만 표시하고 60 studs 안에서 매장량 숫자를 보여 준다
  Base (Model)                      LandingSite가 BaseKit을 복제해 선택 패드 위에 놓은 결과. 시작 시 없음
    RecordBoard (Part, Anchored)    2026-10-19 16차. 서버 RecordBoard가 기지를 놓을 때 생성(키트에는 없음). 10 x 6 x 0.4 어두운 판, 자식 Trim(노란 Neon 테두리), Leg1, Leg2,
                                     SurfaceGui RecordGui(Front, PixelsPerStud 50, LightInfluence 0) > Root > Title, Line1..Line5, Status.
                                     자리: Origin 기준 (17, -26.5), 착륙선 문(0, -1)을 바라봄 (DevMap.RECORD_BOARD)

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
        Slot1 .. Slot25 (Part)      패널이 놓일 자리(2026-10-18: 30 -> 25, 5 x 5). 설치되면 PanelTemplate 복제본이 위에 생김
    ModulePads (Folder)
      PadA, PadB, PadC (Model)    Attribute ModuleId(string, A/B/C). 클라이언트 표지판이 이걸로 찾는다
        Pad (Part)                  ProximityPrompt 부착 대상. ActionText "건설 시작". PadB는 완공 후 두 번째 프롬프트 "가동 중지" / "가동 재개"(2026-10-18 추가, 서버 Construction이 관리). 세 패드 모두 "외벽 수리" 프롬프트 RepairPrompt(키 R, 15차, 서버 ModuleRepair, 손상일 때만 켜짐)
        Ghost (Model)               반투명 미리보기. 착공 가능할 때 표시, 착공하면 숨김(2026-10-18 변경). 건설 중에는 Built가 진행률만큼 땅에서 솟아오름
        Built (Model)               완공 모델. active 전에는 Parent를 ServerStorage로 빼두거나 투명
        OxygenZone (Part)           PadA에만 있음
    WaterTank (Part)                ProximityPrompt. ActionText "물 하역"
    ChargePad (Part)                2026-10-18 추가. 로버 충전 패드. Attribute DockState(string): "empty" | "docked"(로버가 반경 안, 아직 충전 전: 탑승 중이거나 기지 에너지 0) | "charging" | "full". 서버가 갱신하고 색과 빛을 바꾸며, 클라이언트는 이 값으로 패드 위 표지판을 그린다. 로버 섀시가 패드 위(반경 ROVER.chargeRadius)에 있고 좌석이 비어 있으면 초당 ROVER.chargeRatePerSecond만큼 기지 에너지에서 로버 배터리로 이동. 기지 에너지가 0이면 충전 정지. 시작 시 로버는 이 패드 위에 주차
  PanelTemplate (Model)             태양광 패널 1장
```

ProximityPrompt 공통: `RequiresLineOfSight = false`, `MaxActivationDistance = 12`, `Style = Custom`(2026-10-17 변경). 서버는 ObjectText(대상 이름)와 ActionText(동작)만 채우고, 화면 표시는 클라이언트 PromptUI가 ProximityPromptService 이벤트로 그린다. 로버 탑승은 로버 섀시의 프롬프트(ObjectText "로버", ActionText "탑승")로 하며 Triggered 시 서버가 seat:Sit를 호출한다. 에어락 문 프롬프트(ObjectText "에어락", ActionText "열기", 거리 8)는 서버 Airlock 모듈이 관리하고 열림 상태를 문 Part의 Transparency와 CanCollide로 표현한다. 로버 복구 콘솔 프롬프트 거리는 8. 모듈 패드 표지판은 서버가 만들지 않고 클라이언트 PadSignUI가 PadX 모델의 Attribute `ModuleId`(A/B/C)와 state.modules로 그린다. 로버 얼음 프롬프트는 각 Ice 파트에 서버가 부착하고, 로버 DriverSeat에 플레이어가 앉아 있고 Ice와 로버 거리가 Config.ICE_PROMPT_DISTANCE 이내일 때만 Enabled.

## 5. 클라이언트 모듈 경계 (src/client)

| 모듈 | 책임 |
|---|---|
| Main.client.lua | Remotes 연결, 각 UI 모듈 init, phase에 따라 어느 화면을 보일지 결정 |
| TitleUI.lua | 타이틀 화면. 시작 버튼을 누르면 로컬에서만 숨김 (서버 phase는 이미 selecting). 2026-10-19 16차: 오른쪽 "명예의 전당" 패널(상위 5개, Records 수신 때 갱신, 비면 TEXTS.recordsEmpty). compact(Layout.isCompact)면 시작 버튼 아래로 |
| SiteSelectUI.lua | SiteSelectionOpen 수신. 카드 4장. 권한자만 버튼 활성. 남은 시간 표시. SelectSite 송신 |
| LandingCamera.lua | LandingSequence 수신. Config.LANDING_SECONDS 동안 카메라 Scriptable로 하강 연출 후 Custom 복귀 |
| HUD.lua | (15차) 상단 중앙 Day 패널 아래 랜덤 이벤트 배너: state.event.text 한 줄(예고는 중립 회색, 진행 중은 빨강) + eduText 14pt, event가 nil이면 숨김. topCenter AutomaticSize 안에서 자라 compact 토스트를 밀어 낸다. 모듈 행과 칩에 damaged면 "손상, R로 수리"(빨강). StateUpdate 수신. Energy/Water/Food/Day, 순증감(+3/일 형식, 음수는 빨강), 패널 n/30 (오늘 k/3), 모듈 A/B/C 상태와 진행바, 로버 탱크, 미션 텍스트, 2배속 토글(SetSpeed) |
| OxygenBar.lua | OxygenUpdate 수신. 실외일 때 강조, 20 이하 경고 |
| PromptUI.lua | 커스텀 ProximityPrompt 표시(키 아이콘, ObjectText, ActionText, 홀드 진행 바). 서버 프롬프트는 전부 Style Custom |
| PadSignUI.lua | 모듈 패드 위 표지판(이름, 상태 배지, 진행 바, 비용). PadX의 ModuleId Attribute와 state.modules 사용 |
| Layout.lua | 2026-10-18 추가. 화면 높이 기준 배율(높이/720, 0.7~1.25)과 압축 배치 판정(터치 전용 또는 높이 600 미만). HUD, 토스트, 레이더, 산소 UI, Tip, 사실 카드가 공유 |
| SoundFX.lua | 2026-10-18 추가. 클라이언트 2D 효과음: 호흡 루프(산소 비례), 산소 경고, UI 클릭, 토스트음, 미션 전진, 승패 스팅어, 로버 승하차와 엔진(자기 로버) |
| DockSignUI.lua | 2026-10-18 추가. ChargePad 위 표지판: DockState와 state.rover.battery로 "도킹됨, 하차하면 충전 시작" / "충전 중 38/50" / "충전 완료" |
| RadarUI.lua | 로컬 계산. 자신이 DriverSeat에 앉아 있을 때만 표시. Workspace.IceSites 각 파트까지 거리로 점 크기와 방향 표시, Config.RADAR_RANGE 안이면 비프(사운드 선택). 2026-10-18 14차: PC는 좌하단 지름 180, compact(터치 전용 또는 낮은 화면)는 자원 패널 아래 140, 뷰포트가 바뀌면 다시 배치. 거리 문구는 왼쪽 정렬 한 줄(넘치면 말줄임), 배터리 문구는 2줄 |
| ToastUI.lua | Notify 수신. 3초 표시 후 사라짐. 최대 3개 스택 |
| ResultUI.lua | 2026-10-19 16차: 요약 아래 "함께 한 일" 표(이름, 패널, 물, 착공, 수리, 산소 고갈은 0이 아닐 때만, 14pt, 4명까지), 승리면 "역대 N위" 배지(Records submitted로 갱신, 저장 전 "기록 저장 중", 상위 밖이면 "상위 10위 밖, 1위 X일"), 명예의 전당 상위 5개(offline이면 상태 문구). 카드는 세로 ScrollingFrame으로 화면 높이 - 24를 넘으면 스크롤. GameOver 수신. 승리/실패 공용. 요약 수치. 재도전 버튼(RequestRestart). 2026-10-18 15차: 맨 아래 "오늘 배운 것"에 FactUI.seenTitles(3) 제목 목록, 없으면 FactUI.resultText(won) 한 문장 |
| FactUI.lua | 2026-10-18 15차 추가. 교육 사실 카드("알고 있나요?"). 화면 오른쪽 세로 중앙(Layout 배율), 한 번에 하나, 세션당 각 1회, 최소 4초 간격, 선택/착륙/결과 화면에서 억제. StateUpdate(phase, panelsInstalled, waterTrips, modules.status), OxygenUpdate(50 미만), RoverBoost.drivingChanged(첫 탑승 20초 뒤)로 트리거. 상태 트리거는 Tip과 겹치지 않게 4초 지연. seenTitles(n)/resultText(won)를 ResultUI에 제공 |
| Facts.lua (shared) | 2026-10-18 15차 추가. 사실 문구 목록 { key, title, body, trigger }와 byKey. body의 {site}는 착륙지 이름으로 치환. trigger가 result인 항목은 결과 화면 전용 |

UI 스타일: 다크 배경(어두운 남색 계열), 흰 글씨, 강조색은 에너지 노랑, 물 하늘색, 식량 초록, 산소 주황. 폰트 GothamMedium 계열. 모바일 터치도 고려해 버튼 최소 44px.

## 6. Config 키 (src/shared/Config.lua)

GDD 4절의 값. 키 이름을 이대로 쓴다.

```lua
DAY_SECONDS = 10, TOTAL_DAYS = 90, SPEEDS = {1, 2},
LANDING_SECONDS = 5, SITE_SELECT_TIMEOUT = 30, DEFAULT_SITE_ID = 2,
START = { energy = 50, water = 25, food = 30 },  -- energy 50은 착륙선 잔여 배터리 (2026-10-17 플레이테스트 후 조정)
CREW = { food = 1, water = 1 },
PANELS_TOTAL = 25, PANELS_PER_DAY = 3, PANEL_OUTPUT = 1, PANEL_INSTALL_HOLD = 2,  -- 2026-10-18: 패널 30 -> 25
MODULES = {
  A = { name = "Habitat", cost = { energy = 60, water = 20 }, buildDays = 5, upkeep = { energy = 3, water = 1 }, requires = {} },
  B = { name = "Farm", cost = { energy = 80, water = 30 }, buildDays = 5, upkeep = { energy = 6, water = 2 }, requires = {"A"}, foodPerDay = 2 },  -- 2026-10-18: 전력 5 -> 6
  C = { name = "Research Lab", cost = { energy = 150, water = 30 }, buildDays = 7, upkeep = { energy = 8, water = 1 }, requires = {"A", "B"} },
},
MODULE_ORDER = {"A", "B", "C"},
ROVER = { tankMax = 60, fillHold = 3 }  -- 2026-10-18: 40 -> 60 (매장량 차등과 함께), ICE_PROMPT_DISTANCE = 20, RADAR_RANGE = 150,
OXYGEN = { max = 100, drainPerSecond = 100 / 60, refillPerSecond = 10, deathPenalty = { food = 1, water = 2 } },
SHORTAGE_DAYS_TO_LOSE = 3,
SITES = {
  { id = 1, name = "Shackleton Rim", sunlight = 1.00, iceDistanceLabel = "멀다", hazardLabel = "낮음", description = "전력은 넉넉하지만 얼음까지 길이 멀다" },
  { id = 2, name = "de Gerlache Ridge", sunlight = 0.85, iceDistanceLabel = "중간", hazardLabel = "중간", description = "모든 면에서 균형 잡힌 후보지" },
  { id = 3, name = "Malapert Massif", sunlight = 0.70, iceDistanceLabel = "가깝다", hazardLabel = "중간", description = "물은 가깝지만 발전이 느리다" },
  { id = 4, name = "Nobile Crater", sunlight = 0.60, iceDistanceLabel = "매우 가깝다", hazardLabel = "높음", description = "얼음이 코앞이지만 지형이 험하다" },
},
MISSION_TEXTS = { ... }  -- 단계별 미션 문구는 Config에 두고 서버가 state.missionText로 내려준다
EVENTS = {  -- 2026-10-18 15차 랜덤 이벤트
  enabled = true,
  solarStorm = { startDayMin = 30, startDayMax = 50, warningDays = 2, durationDays = 2, panelMultiplier = 0.5, outdoorOxygenMultiplier = 1.5 },
  micrometeoroid = { countMin = 1, countMax = 2, dayMin = 15, dayMax = 80, minGapDays = 10, bannerDays = 2,
                     repairEnergy = 10, repairHold = 4, repairKey = "R", promptDistance = 12,
                     graceDaysAfterActivation = 5, noRepeatTarget = true },
},
-- TEXTS 추가 키(15차): stormWarning, stormStart, stormEnd, stormBannerWarning, stormBannerActive, stormEdu,
--   meteorModule, meteorPanel, meteorMiss, meteorBannerModule, meteorBannerPanel, meteorBannerMiss, meteorEdu,
--   moduleDamagedStatus, upkeepDamaged, moduleRepaired, moduleRepairNotNeeded
-- PROMPT_TEXTS.repairModule = "외벽 수리", TIPS.storm(첫 폭풍 예고), TIPS.moduleDamage(첫 모듈 손상, TipUI 트리거)
RECORDS = {  -- 2026-10-19 16차 기여도와 승리 기록
  enabled = true, datastoreName = "FrontierRecords", key = "top", maxEntries = 10, showTop = 5,
  crewNameLimit = 4, crewShowNames = 2, crewRows = 4, crewWaterWeight = 0.1, nameMaxLength = 20,
  retryDelay = 1, utcOffsetHours = 9, version = 1,
},
-- TEXTS 추가 키(16차): recordsTitle, recordsEmpty, recordsLoading, recordsOffline, recordSaving, recordRank, recordOutside,
--   recordLine, recordCrewMore, recordDate, crewTitle, crewName, crewPanels, crewWater, crewBuilds, crewRepairs, crewDeaths
```
