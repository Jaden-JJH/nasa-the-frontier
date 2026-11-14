# The Frontier v2 코드 계약 (CONTRACT v2, 초안 2026-11-14)

v2 서버(src/server), 공용(src/shared), 클라이언트(src/client)가 합의하는 인터페이스다. 결정 근거는 `docs/V2_PLAN.md` 15절, 다국어는 `docs/I18N_PLAN.md`. 이름, 타입, 의미를 바꾸려면 이 문서를 먼저 고친다. v1 계약(`docs/CONTRACT.md`)은 v1 모듈을 지울 때까지 참고용으로 남는다.

규칙 함수(`src/shared/Rules.luau`)와 수치(`src/shared/MissionConfig.luau`)는 v2-rules 라운드 결과를 따른다. 이 문서의 상태 필드는 서버가 Rules 상태를 클라이언트용으로 옮겨 담는 모양이며, Rules 결과에 맞춰 한 번 더 다듬는다([조정 예정] 표시).

## 0. 원칙
1. 서버 권위. 클라이언트는 표시와 요청만 한다.
2. 서버와 shared는 화면 문장을 만들지 않는다. 사람에게 보일 글자는 `Msg = { key: string, args: {...}? }`로 보내고 클라이언트 `Localizer`가 언어별로 만든다(I18N_PLAN 4.5).
3. 숫자와 문구 키의 원본은 `MissionConfig`와 `i18n/strings.csv`. 코드에 숫자를 직접 쓰지 않는다.
4. 디자이너의 Terrain, Lighting, Sky는 코드가 건드리지 않는다. v1 `DevMap`의 지형 생성과 조명 덮어쓰기는 v2 부팅에 넣지 않는다.

## 1. 월드 계약 (Studio, 디자이너와 공유)
```
Workspace
  MissionC (Folder)                    위치 표시, 디자이너가 Studio에서 놓음. 코드는 읽기만 한다
    Lander, SpawnLocation(SpawnLocation), Airlock, SolarField, FarmPad, WaterTank,
    RoverPark, BaseExit, Ice1 .. Ice5  (BasePart, Anchored). 번호가 아니라 실제 거리로 정렬해 쓴다
  MissionB (Folder)                    나중. Tower1 .. Tower3 추가
  MissionRuntime (Folder)              서버가 실행 중에 만드는 것(시설 모델, 로버, 프롬프트 파트). 재시작 때 비운다
  AssetPreview (Folder)                편집용 미리보기. 실행 시 서버가 비활성화(Parent = nil)한다
ServerStorage
  Assets (Folder)                      Rojo가 관리하지 않는다
    Greenhouse (Model)                 Attribute SourceFile, AssetId, Role = "facility.farm"
    Kit (Folder)                       v1 자리 표시 키트 19개(Antenna, Connector, ConnectorElbow, Crate, Crop,
                                       HabitatA/B/C, IceCrystal, Lander, Pad, Panel, Planet, Radar, Rock1~3, Rover, WaterTank)
```
- 에셋 찾기 순서(Q27): `Assets.<역할 이름>` -> `Assets.Kit` 조합 -> 코드 도형 + 이름표. 역할 이름: Greenhouse, Pipe, Airlock, Lander, SolarPanel, WaterTank, Rover, WaterRover(B), TowerRover(B), SolarTower(B), PowerLine(B). 크기는 표시 Part에 맞춘다.
- 그린하우스 안 `Grow_LED_Bar`는 LED 업그레이드 가동 때, `Hydroponic_Bed`는 수경 재배 가동 때 보인다(Q 확정).
- 모든 텍스트 GUI의 `AutoLocalize = false`(Roblox 자동 번역 금지, Q38).

## 2. 모듈 경계
### 2.1 shared
| 모듈 | 책임 |
|---|---|
| MissionConfig | v2 수치 전부(v2-rules) |
| Rules | 순수 규칙: 상태 생성, 하루 진행, 행동, 종료, 점수, 메달(v2-rules) |
| SpaceWeatherData | DONKI 60일 구간 5개(생성 파일, tools/donki/build_windows.py) |
| Msg, Loc, Strings | 다국어 메시지, 해석기, 생성된 문구표(v2-i18n) |
| Remotes | RemoteEvent 이름 등록(v1 파일에 v2 이름 추가) |
| Ranking | v1 순수 로직 재사용, 정렬 기준만 v2(메달 > 점수 > 일수 > 먼저) |

### 2.2 server (v2 신규, 이름 고정)
| 모듈 | 책임 |
|---|---|
| Main.server | 부팅: Remotes.init -> PlayerPrefs.init -> MissionWorld.init -> MissionFlow.start |
| MissionFlow | phase 전이(selecting -> landing -> playing -> result), 솔로/멀티 판정(Q6), 재시작, Rules 호출의 단일 창구, StateUpdate 발행 |
| MissionClock | 하루 30초 DayTick, phase가 playing일 때만 |
| MissionWorld | MissionC 표시 읽기, 에셋 3단계 대체로 시설 배치, 건설 솟아오름 연출, 업그레이드 표시, 에어록 문과 벽, AssetPreview 비활성화 |
| Interactions | ProximityPrompt 생성과 처리(Attribute 키 프로토콜, 3절) |
| RoverFleet | 로버 생성과 주차, 직접 운전(v1 RoverDrive, Battery, Boost, Damage, Recovery 재사용), 자율주행 파견 표현(출구까지 주행 후 숨김, 귀환), 원격 회수 |
| Roles | 역할 배정과 교체, 관제사 이탈 시 이전, 핀 |
| SpaceWeather | 그날의 사건을 Rules에서 받아 15초 경보, SEP 대피(로버 탑승 또는 에어록 이동, 문 잠금), GST 장애 표시 |
| Oxygen, Airlock, Spacesuit | v1 재사용. 산소 규칙만 v2(Q28) |
| PlayerPrefs | 언어 저장(v2-i18n) |
| RecordsV2 | 미션별 기록과 전체 리더보드 저장(DataStore, v1 Records 방식) |
| Contributions | v1 재사용 + 역할 |

### 2.3 client (v2 신규 또는 교체)
| 모듈 | 책임 |
|---|---|
| Main.client | Remotes 연결, Localizer 초기화, 화면 전환 |
| Localizer, LanguageToggle | v2-i18n |
| TitleV2 | 타이틀, 시작, 언어 전환, About the data |
| MissionSelectUI | 남극 지도 4기지(C 플레이, B 곧 열림, A/D 딤드 잠금), 미리보기 후 확정, 30초 자동 C, 내 최고 메달 배지 |
| HUDV2 | 자원 3개(아이콘 + 숫자, 상한 100), 하루와 남은 일수, 미션 문구(Msg), 우주 기상 배너, 산소 바, 대원 머리 위 상태 아이콘 |
| ConsoleUI | 착륙선 콘솔: 지도(얼음 5곳 쿨타임, 로버와 대원 위치, 자율주행 아이콘), 파견(비용, 왕복 일수, 위험, 서둘러 가기), 원격 회수, 시설 탭(멈춤), 역할 교체 |
| PinArrowUI | 탐사대원 화면의 A안: 화면 밖이면 가장자리 화살표 + 거리, 안이면 마름모 |
| RoleSelectUI | 멀티 시작 10초 역할 선택 |
| ResultV2 | 메달, 점수와 감점 내역, 이번 판 우주 날씨 한 줄, 미션 순위 5 + 전체 5, 함께 한 일(역할), 기분 나쁘지 않은 실패 문구 |
| PromptUI, ToastUI, TipUI, FactUI, SettingsUI, OxygenBar, SoundFX, Layout | v1 재사용, 문구는 Localizer로 전환 |

## 3. 프롬프트 Attribute 프로토콜 (서버가 문장을 쓰지 않는다)
- 서버는 ProximityPrompt에 Attribute만 쓴다: `ActionKey`, `ObjectKey`(문구 키), `ActionArgs`, `ObjectArgs`(JSON 문자열), `CooldownUntil`(서버 시각, 선택). `ActionText`, `ObjectText`는 비운다.
- PromptUI가 Attribute 변화를 구독해 현재 언어로 그린다. 키 안내는 `{key_interact}` 같은 값으로 장치별 라벨을 넣는다.
- 상호작용 목록(키 이름은 CSV와 맞춘다):
  - 에어록 점검 시작(Airlock), 패널 설치(SolarField), 시설 착공(FarmPad 자리: 재배 공간, 업그레이드 3종), 파이프 착공(WaterTank 옆, 해금 후 얼음 지점 선택은 콘솔), 얼음 채취(얼음 지점, 로버 운전석일 때), 물 하역(WaterTank), 로버 수리(로버 섀시, R), 시설 멈춤(건물 외벽 제어반, E 1초), 콘솔 열기(Lander 안).

## 4. Remotes
### 4.1 서버 -> 클라이언트
| 이름 | 페이로드 | 때 |
|---|---|---|
| StateUpdate | `MissionState`(5절) | 상태가 바뀔 때, 매 DayTick, 입장 직후 그 플레이어에게 |
| Notify | `(msg: Msg, kind: "info" | "warn" | "good")` | 토스트 |
| MissionSelectOpen | `{ chooserUserId, chooserName, deadline, defaultMissionId = "C", missions = { { id, state = "playable" | "soon" | "locked" } } }` | selecting 진입, 늦은 입장자 |
| LandingSequence | `(missionId, landerCFrame)` | landing 진입 1회 |
| SpaceWeather | `{ kind = "SEP" | "GST", stage = "warning" | "active" | "ended", day, durationDays, sourceDate = { year, month, day } }` | 경보 15초 전, 시작, 끝 |
| RoleUpdate | `{ [userId]: "controller" | "explorer" | "engineer" }`, `selecting: boolean`, `deadline?` | 멀티 시작과 변경 |
| PinUpdate | `{ siteIndex: number?, byUserId: number? }` | 관제사가 핀을 찍거나 지울 때 |
| OxygenUpdate | `(oxygen, max, zone: "outside" | "shelter" | "refill")` | v1과 같은 빈도 |
| GameOver | `MissionResult`(6절) | 종료 |
| Records | `{ mission = { entries, rank? }, global = { entries, rank? }, status = "loading" | "ok" | "offline", submitted }` | 입장, 저장 후 |

### 4.2 클라이언트 -> 서버
| 이름 | 페이로드 | 검증 |
|---|---|---|
| SelectMission | `(missionId)` | 선택 권한자, "C"(B는 구현 후) |
| ChooseRole | `(role)` | 멀티, 역할 인원 규칙(Q25) |
| SetPin | `(siteIndex?)` | 관제사만, GST 중 거절 |
| DispatchRover | `(siteIndex, rush: boolean)` | 솔로만, 콘솔 근처(착륙선 안), 로버 주차 중, 쿨타임과 파이프 전용 지점 제외, GST와 SEP 중 거절, 에너지 |
| RemoteRecoverRover | `()` | 로버 고장, 콘솔 근처 |
| SetFacilityPaused | `(facilityId, paused)` | 콘솔 근처 또는 해당 제어반 근처, 가동 중인 시설 |
| SetPipeSite | `(siteIndex)` | 파이프 해금 후 착공 전 |
| RequestRestart | `()` | 결과 뒤 RESULT_MIN_SECONDS, 권한자 |
| SetLanguage | `(code)` | v2-i18n(PlayerPrefs) |
| RoverBoost | `(on)` | v1과 같음 |

## 5. MissionState (서버 -> 클라이언트) [조정 예정]
```lua
export type MissionState = {
    phase: "selecting" | "landing" | "playing" | "result",
    missionId: string?,               -- "C"
    mode: "solo" | "multi",
    day: number, totalDays: number,   -- 1..60
    resources: { energy: number, water: number, food: number },
    cap: number,                      -- 100
    net: { energy: number, water: number, food: number },        -- 어제 대비
    daysLeft: { water: number, food: number },
    lowWarn: { energy: boolean, water: boolean, food: boolean },  -- 20 미만(머리 위 아이콘, 감점선)
    panels: { installed: number, today: number, perDay: number, total: number },
    airlock: { status: "idle" | "inspecting" | "active" | "paused", daysLeft: number },
    facilities: { [string]: {                                    -- farm, pipe, hydroponics, led, nutrient
        status: "locked" | "available" | "building" | "active" | "paused",
        progress: number, daysLeft: number,
        nextHarvestIn: number?,                                  -- farm
        unlockMsg: Msg?,                                         -- 잠김 사유(예: 하역 3/5)
    } },
    ice: { { index: number, markerName: string, cooldownDaysLeft: number, pipe: boolean,
             fsdDays: number, fsdEnergy: number, risk: "low" | "mid" | "high" } },
    rover: { state: "parked" | "driving" | "fsd" | "broken", damage: number, battery: number,
             batteryMax: number, tank: number, tankMax: number,
             fsd: { siteIndex: number, phase: "out" | "return", progress: number, rush: boolean }? },
    deliveries: number,                                          -- 파이프 해금(5)
    weather: { kind: "SEP" | "GST", stage: "warning" | "active", daysLeft: number, sourceDate: { year: number, month: number, day: number } }?,
    mission: Msg,                                                -- 상단 미션 문구
    stalled: boolean,
}
```
- 숨은 점수는 보내지 않는다(Q4). 결과에서만 공개.
- v2-rules 결과와 맞춘 점(2026-11-14):
  - 로버 상태는 Rules 기준 `parked`, `fsd`, `broken`. 원격 회수 중은 `fsd` + `recovering = true`(Rules.roverFsdView의 phase는 "return"). `driving`은 서버가 직접 운전 중일 때 붙인다.
  - 경로 위험은 `low`, `mid`, `high`, 그리고 "서둘러 가기" 미리보기에서만 `extreme`.
  - 에어록은 시설 인스턴스. Rules 상태가 `building`이면 화면에서는 "점검 중"(`inspecting`). 패널은 시설이 아니라 숫자.
  - 파이프 첫 인스턴스 id는 `pipe`(이후 `pipe2`, `pipe3`). B의 수송망은 `powerline`.
  - 화면용 도우미: `Rules.weatherStatus(state)` -> `{ kind, stage, daysLeft, sourceDate, banner: Msg }`, `Rules.roverFsdView(state)` -> `{ siteIndex, phase, progress, rush, recovering, stoppedBy }`. 서버는 이 값을 그대로 `weather`, `rover.fsd`에 담는다.
  - 자율주행 거리는 `MissionConfig`(BaseExit 기준), 실행 중에는 서버가 MissionWorld의 실측 거리로 `options.iceDistances`를 덮어쓴다.

## 6. MissionResult (GameOver)
```lua
export type MissionResult = {
    won: boolean, medal: "gold" | "silver" | "bronze" | nil,
    reason: Msg, day: number,
    score: number, deductions: { { reason: string, count: number, points: number, resource: string?, msg: Msg } },  -- reason은 CSV 키 끝부분(water_low, food_zero, oxygen_rescue 등), points는 양수
    weather: { windowId: string, startDate: {...}, endDate: {...}, sep: number, gst: number },
    crew: { { name: string, role: string?, panels: number, water: number, builds: number, repairs: number, rescues: number } },
    restartAvailableAt: number, chooserUserId: number,
}
```

## 7. 저장 (DataStore)
| 이름 | 키 | 값 |
|---|---|---|
| FrontierRecordsV2 | `mission_C`, `mission_B` | 상위 10개 `{ medal, score, days, crew, mode, at, missionId, version = 2 }` |
| FrontierLeaderboardV2 | `global` | 상위 50 `{ userId, name, goldMissions, bestScoreSum }`(Q5) |
| FrontierPrefs | `u_<userId>` | `{ lang }`(v2-i18n) |
- v1 `FrontierRecords`는 읽지도 쓰지도 않는다.
- Studio에서 시험하려면 Studio API 접근이 켜져 있어야 한다(보류 항목). 꺼져 있으면 v1처럼 메모리 대체와 offline 표시.

## 7.5 MissionWorld 연결 규칙 (v2-world 결과, 2026-11-14)
- 부팅 순서: `MissionWorld.init(missionId)` -> `placeBase(options?)` -> Interactions가 `anchor(id)`, `controlPanel(id)`에 프롬프트를 붙인다. `reset()`은 MissionRuntime을 통째로 비우고 기지를 다시 놓으므로 Interactions와 RoverFleet은 reset 뒤 다시 붙인다.
- 상호작용 자리 id: `console`, `airlockPanel`, `installPad`, `buildSpot`, `unloadPoint`, `roverDock`, `pipeSpot`, `roverPark`, `exit`. 얼음 채취 자리는 `MissionRuntime.IceSites.IceN.MinePoint`(Attribute `SiteIndex`, `MarkerName`).
- 얼음 순서: BaseExit 기준 거리로 정렬. `Rules.newState`에 `options.iceDistances = MissionWorld.iceDistances()`를 넘겨야 siteIndex가 맞는다.
- 시설 id: Rules 인스턴스 id(farm, led, nutrient, hydroponics, pipe, pipe2...). 끝 숫자를 떼면 정의 id. `syncFacilities(facilities)`로 Rules 상태를 한 번에 반영. 에어록은 `setAirlockStatus("idle" | "inspecting" | "active" | "paused")`.
- 산소 구역: 파트 태그 `OxygenZone`, Attribute `ZoneKind`("shelter" | "refill"), `ZoneId`("lander" | "airlock"). 착륙선은 늘 shelter, 에어록은 active일 때만 refill.
- 에어록과 착륙선 문은 v1 이름(`Entry.Door`)이라 v1 Airlock 모듈을 `Airlock.attach(workspace.MissionRuntime)`로 붙인다.
- 클라이언트는 `Localizer.bindTextKeys(workspace.MissionRuntime)`를 부르고 DescendantAdded에서도 다시 등록한다(시설이 나중에 생김).
- 디자이너 조정: FarmPad에 number Attribute `Yaw`(도)를 달면 그린하우스 방향을 그 각도로 놓는다. 멈춘 업그레이드는 꺼진 모습(`CFG.pausedUpgradeLook`).
- 실행 중 MissionC 표시는 고정하고 숨긴다(SpawnLocation 제외).

## 8. 테스트
- 순수 규칙: `tests/rules.spec.luau`, `tests/bot_v2.luau`(v2-rules), 다국어: `tests/i18n.spec.luau`(v2-i18n). 리드가 `tests/run.luau`에 합친다.
- v2 서버 스모크: v1 `server_smoke.luau` 방식으로 MissionC 표시 픽스처를 만들어 부팅, 하루 진행, 파견, 종료를 검사한다. v1 스모크는 v1 모듈을 지울 때 함께 정리한다.

## 9. 구현 반영 차이 (2026-11-14, 위 본문보다 우선)
### 9.1 서버 (v2-server 보고, 리드 승인)
1. 문, 산소, 기여도는 v1 모듈 대신 v2 모듈 `AirlockDoors`, `OxygenV2`, `ContributionsV2`를 쓴다(v1 모듈은 문장을 직접 쓰고 v1 상태에 묶여 있음). 7.5의 "v1 Airlock.attach"는 폐기.
2. `RoleUpdate(roles, selecting, deadline?)` 3인자. `roles`의 키는 `tostring(userId)`.
3. `weather`는 `Rules.weatherStatus` 그대로 보내되, `warning` 단계는 서버가 15초 전 경보를 보낸 뒤에만 넣는다.
4. 덧붙인 필드
   - MissionState: `players`, `chooserUserId`, `dayEndsAt`, `pipeSite`, `stallReason`
   - `ice[]`: `distance`, `rushDays`, `rushEnergy`, `rushRisk`, `rushHelps`
   - `rover`: `maxDamage`, `boosting`, `boostHeat`, `charging`, `atBase`, `broken = { siteIndex, position, distance, walkable }`
   - `facilities[]`: `upkeep`, `siteIndex`, `nextDeliveryIn`, `stalled`. `airlock.stalled`도 있다.
   - GameOver: `missionId`, `mode`, `players`, `startScore`
   - MissionSelectOpen: `bestMedals`, 플레이어마다 따로 보낸다.
   - LandingSequence: 세 번째 인자 `seconds`
5. Records는 플레이어마다 따로 보낸다. 모양 `{ missionId, mission = { entries, rank?, entry? }, global = { entries, rank?, mine? }, status, submitted }`. 전체 리더보드 줄에 최고 점수 합 계산용 `missions` 표를 더한다.
6. 원격 회수 요청은 직접 운전 로버가 기지 밖에 서 있을 때(방전, 끼임) 주차판으로 끌어오는 데도 쓴다. 탱크의 물은 잃고 쿨다운 15초.
7. `SetPipeSite`는 역할 제한이 없다. 핀은 멀티에서 관제사만, 솔로는 누구나.
8. 직접 운전 충돌 파손은 `Rules.applyRoverHit`, 그 자리 수리는 `Rules.repairRover`(처음 보고의 "상태 복사 후 damage만 올림"은 Rules 함수로 대체). 충돌 판정은 0.25초 안에 속도 12 이상에서 절반 아래로 떨어지는 급정거 + `RoverHazard` 태그.
9. 걸어서 수리: 고친 대원을 로버 운전석에 태우고 직접 몰고 귀환한다(`toast.rover.repaired_drive_back`, 순간 이동 없음). 처음 보고의 "에어록 안으로 옮김"은 폐기.
10. 자율주행 출발 연출은 출구 쪽으로 40 stud만 달린 뒤 사라진다(주차판에서 출구로 곧게 가면 착륙선을 뚫고 지나감).
11. 새 공용 모듈 `RankingV2`(v1 `Ranking`은 v1 결과 화면이 쓰고 있어 분리).
- 부팅 순서: `Remotes.init` -> `PlayerPrefs.init` -> `MissionWorld.init("C")` -> `placeBase` -> `MissionFlow.start("C")`. 재시작은 `MissionWorld.reset()` 뒤 문, 로버, 상호작용을 다시 붙인다.
- 운전용 로버는 `RoverRig`가 코드로 만든다(새 플레이스의 Kit.Rover는 메시뿐).

### 9.2 클라이언트 (v2-client 보고, 리드 승인)
1. 핀 화살표는 멀티에서 관제사가 아닌 모든 역할(탐사대원, 엔지니어)에게 보인다. GST 중이거나 콘솔이 열려 있으면 숨긴다.
2. 화면 거리는 `MissionConfig.metersPerStud`로 미터로 바꿔 표시한다. 서버 토스트와 같은 반올림이라 숫자가 맞다.
3. 콘솔은 프롬프트 Attribute `OpenUI == "console"` 또는 `ActionKey == "prompt.act.open_console"`이면 열리고, 25 stud 넘게 멀어지면 닫힌다.
4. 서버가 덧붙인 필드(9.1의 4번)를 쓴다. `dayEndsAt`은 자율주행 아이콘을 하루 안에서 부드럽게 움직이는 데 쓴다. 기록은 `mission.entry`, `global.mine`을 쓴다.
5. StreamingEnabled라 멀리 있는 인스턴스 대신 MissionState의 `ice[i].x/z`, `mapPoints`, `rover.x/z` 좌표를 쓴다(서버 구현 확인).
6. 미션 선택 지도는 단순화한 그림이다. 실제로는 B와 C가 아주 가까워서 읽기 쉽게 벌렸고, 지도 아래에 안내 문구(`mission_select.map_note`)를 단다.
7. HUD에 로버 상태 칩과 운전 중 배터리를 더했다. v1 RadarUI는 옮기지 않았다.
- 새 클라이언트 모듈: TitleV2, MissionSelectUI, RoleSelectUI, HUDV2, ConsoleUI, ConsoleMap, PinArrowUI, ResultV2, HeadStatus, WeatherFX, Net, Session, Icons, WorldPoints, 공용 `src/shared/ClientMath.luau`.
- v1 화면 파일(HUD, TitleUI, SiteSelectUI, ResultUI, RadarUI, DockSignUI, PadSignUI, ObjectiveHighlight, RoverHint, Layout)은 남아 있지만 Main이 불러오지 않는다. BoostFX는 그대로 쓴다.
- 모든 UI 글자 요소는 `AutoLocalize = false`이고 Localizer로 그린다. 서버가 보내는 문구 키 11개는 새 키를 만들지 않고 기존 `toast.*` 키로 맞췄다.
