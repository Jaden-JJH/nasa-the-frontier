# rules_v2.json (웹판 공유용 규칙 수치 / Shared game rules for the web version)

[한국어](#한국어) | [English](#english)

## 한국어

### 무엇인가
- Roblox판의 모든 규칙 수치(`src/shared/MissionConfig.luau`)를 그대로 옮긴 JSON이다. 웹판(PlayCanvas)이 같은 숫자를 쓰게 하려는 것(V2_PLAN Q22).
- 손으로 고치지 않는다. 숫자를 바꿀 때는 MissionConfig를 고치고 저장소 루트에서 `lune run tools/rules/export.luau`를 실행한다. CI(`lune run tests/run.luau`)는 `--check`로 둘이 같은지 검사한다.
- 키 이름과 구조는 MissionConfig와 같다. 객체 키는 정렬되어 있고, 맨 위 세 키만 예외다(`schemaVersion`, `generatedFrom`, `generatedBy`). 구조가 바뀌면 `schemaVersion`을 올린다.
- 규칙 계산의 기준 구현은 `src/shared/Rules.luau`다. 웹판 구현은 `derived` 값과 같은 결과가 나와야 한다.

### 단위
- 거리: stud(Roblox 단위). 화면에는 미터로 보여 준다: `m = round(stud x metersPerStud)`, `metersPerStud = 2560 / 2044`(약 1.25, NASA LOLA 지형 2.56 km = 2,044 stud).
- 시간: 게임 하루 = `DAY_SECONDS`(30초), 한 판 = `TOTAL_DAYS`(60일). `...Days`는 게임 일수, `...Seconds`, `...PerSecond`는 실제 초.
- 자원: 에너지(energy), 물(water), 식량(food). 상한 `cap`(100), 넘친 양은 버린다. 소수 계산은 `RESOURCE_DECIMALS`(2) 자리에서 반올림한다.
- 확률: 0 ~ 1(0.05 = 5%).

### 공용 값 (맨 위)
| 키 | 뜻 |
|---|---|
| `DAY_SECONDS`, `TOTAL_DAYS` | 하루 길이(초), 한 판 일수 |
| `SHORTAGE_DAYS_TO_LOSE` | 물 또는 식량 0이 이 일수만큼 이어지면 실패 |
| `RESOURCES` | 자원 순서 |
| `SCORE` | 숨은 점수. `start`에서 시작, 하루 끝에 자원마다 `lowThreshold` 미만이면 -`lowPenalty`, 0이면 그 대신 -`zeroPenalty`, 산소 구조 1회 -`oxygenRescuePenalty`, `minScore` 아래로 내려가지 않음 |
| `OXYGEN` | 야외 `outdoorSeconds`초에 산소 `max` 소모, 에어록 안과 로버 좌석에서 초당 회복 |
| `WALK_REPAIR` | 고장 난 로버까지 걸어서 수리. 한도 = floor((outdoorSeconds x oxygenSafetyRatio - repairHoldSeconds) x walkSpeed) = 704 stud. 걷는 거리 = 출구 기준 고장 위치 + `startOffset`(에어록 -> 출구) |
| `WEATHER` | 우주 기상 효과. SEP: 야외 금지, 로버 정지. GST: Kp `minKp` 이상만, 지도와 자율주행 정지. 실제 구간 데이터는 `data/donki/windows.json` |
| `MANUAL_DRIVE` | 멀티 직접 운전. 최고 속도 `v1MaxSpeed` stud/s, 부스터 x`v1BoostMultiplier`(`v1BoostOnSeconds`초 켜고 `v1BoostCooldownSeconds`초 식힘), 배터리 `batteryMax`, 움직일 때 초당 `batteryDrainPerSecond`(부스터 중 x`boostDrainMultiplier`), 충전은 기지 에너지에서 1:1이지만 `chargeKeepEnergy`는 남김, 현장 수리 `repairEnergy`. `detourFactor`, `fillSeconds`, `unloadSeconds`는 시뮬레이션 가정 |
| `metersPerStud` | 위 단위 참고 |
| `MISSIONS` | 미션별 값. `C`는 플레이 가능, `B`는 `playable: false` 자리 표시(숫자 미정, 쓰지 말 것) |
| `derived` | Rules.luau로 계산한 검산용 값(MissionConfig에는 없는 키). `walkRepairLimit`, 미션별 지점 `sites[]`(가까운 순, `siteIndex` 1부터)의 왕복 계획 `trip`과 서둘러 가기 `rushTrip` |

### 미션 C (`MISSIONS.C`)
| 키 | 뜻 |
|---|---|
| `start`, `cap`, `crew` | 시작 자원, 상한, 대원 하루 소비(인원과 무관, `crewScaling: false`면 `crewPerExtraPlayer`는 안 씀) |
| `stallMode`, `shedOrder`, `crewEnergyLast` | 유지비를 다 못 낼 때. `priority`면 `shedOrder` 앞쪽 시설부터 멈춘다(그린하우스 `farm`이 마지막). `crewEnergyLast: true`면 시설 에너지 유지비를 대원 에너지보다 먼저 낸다(대원 에너지 미납은 실패가 아니라 경고와 감점) |
| `panels` | 태양광 패널. 1장 에너지 `cost`, 1장 하루 발전 `output`, 하루 설치 최대 `perDay`, 전체 `total`, 설치 홀드 `installSeconds`. `emergencyInstall`: 에너지가 모자라고 발전이 대원 소비보다 작으면 남은 에너지로 설치 가능 |
| `facilityOrder`, `facilities` | 시설 정의. `cost`(건설비), `buildDays`, `upkeep`(하루 유지비), `requires`(먼저 지어야 하는 시설), `canPause`, `buildFrom`(`outdoor` 현장, `map` 지도에서), `harvestEveryDays`와 `harvestAmount`(수확), `farmEnergyUpkeepMultiplier`, `farmWaterUpkeepMultiplier`(재배 공간 유지비 배율), 파이프의 `unlockDeliveries`(기지 하역 횟수로 해금), `deliverEveryDays`, `deliverAmount`, `multi`, `maxCount` |
| `ice` | 1회 채취 `amountPerTrip`, 지점마다 쿨타임 `cooldownDays` |
| `iceSites` | 얼음 후보지와 기지 출구(BaseExit)에서의 거리(stud). 규칙은 번호가 아니라 거리순으로 정렬한다(`siteIndex` 1 = 가장 가까운 곳) |
| `manualDriveDistances` | 로버 주차 자리에서의 거리. 시뮬레이션 봇과 보고서만 쓴다 |
| `rover` | 솔로 자율주행(아래 공식), 파손과 수리, 경로 위험 `risk`(거리 < `maxDistance`인 첫 등급, `extreme`은 높음 경로를 서둘러 갈 때만) |
| `medalOrder`, `medals` | 메달 = 완공한 시설 목록. 금 조건을 채우면 그 순간 임무 완료 |

### 자율주행 공식 (Rules.tripPlan)
- `base = 2 x distance / (fsdStudsPerDay x risk[등급].speedFactor)`, `damageFactor = max(0.1, 1 - slowdownPerDamage x 파손 수)`
- `raw = base / damageFactor`, 서둘러 가기면 `x rushTimeFactor`. 왕복 일수 `days = max(1, floor(raw + 0.5))`
- 에너지 `energy = ceil(base x energyPerTravelDay x (서둘러 가기면 rushEnergyFactor) - 1e-9)`(파손은 에너지에 영향 없음)
- 서둘러 가기는 위험 한 등급 위. 파손 확률 = `risk[등급].damageChance x damageChanceMultiplier`
- `derived`의 `rawDays`는 화면용으로 소수 둘째 자리에서 반올림한 값이다. 일수 계산은 반올림 전 값으로 한다.

### 화면 문구
- JSON에는 문장이 없다. 이름과 문구는 `i18n/strings.json`의 키로 찾고 `i18n/loc.js`로 채운다.
- 예: 시설 `facility.<시설 id>.name`, 자원 `res.<energy|water|food>.name`, 얼음 후보지 `map.ice.label`(`{n}` = id의 숫자, Ice4 -> 4), 위험 `map.risk.<low|mid|high|extreme>`, 메달 `medal.<gold|silver|bronze>.name`, 감점 `score.deduct.<자원>_low`, `_zero`, `oxygen_rescue`(복수형 `.one`, `.other`는 `count`를 넘기면 loc.js가 고른다), 미션 `mission.c.name`, 거리 `map.ice.distance`(`{n}` = 미터).

## English

### What it is
- A JSON copy of every game rule number in the Roblox version (`src/shared/MissionConfig.luau`), so the web version (PlayCanvas) uses the same numbers (V2_PLAN Q22).
- Do not edit by hand. Change MissionConfig, then run `lune run tools/rules/export.luau` from the repo root. CI (`lune run tests/run.luau`) runs it with `--check` to make sure the two match.
- Key names and structure are the same as MissionConfig. Object keys are sorted, except the first three (`schemaVersion`, `generatedFrom`, `generatedBy`). `schemaVersion` goes up when the structure changes.
- The reference rules implementation is `src/shared/Rules.luau`. A web implementation should reproduce the `derived` values.

### Units
- Distance: studs (Roblox units). Show meters on screen: `m = round(studs x metersPerStud)`, `metersPerStud = 2560 / 2044` (about 1.25; the NASA LOLA terrain is 2.56 km = 2,044 studs).
- Time: one game day = `DAY_SECONDS` (30 s), one game = `TOTAL_DAYS` (60 days). `...Days` are game days, `...Seconds` and `...PerSecond` are real seconds.
- Resources: energy, water, food. Capped at `cap` (100); overflow is lost. Decimal math is rounded to `RESOURCE_DECIMALS` (2) places.
- Chances: 0 to 1 (0.05 = 5%).

### Shared values (top level)
| Key | Meaning |
|---|---|
| `DAY_SECONDS`, `TOTAL_DAYS` | Day length (s), days per game |
| `SHORTAGE_DAYS_TO_LOSE` | Lose when water or food stays at 0 for this many days in a row |
| `RESOURCES` | Resource order |
| `SCORE` | Hidden score. Starts at `start`; at the end of each day, per resource, -`lowPenalty` if below `lowThreshold`, or -`zeroPenalty` instead if at 0; -`oxygenRescuePenalty` per oxygen rescue; never below `minScore` |
| `OXYGEN` | Outdoors, `max` oxygen lasts `outdoorSeconds`; refills per second in the airlock and the rover seat |
| `WALK_REPAIR` | Walking to a broken-down rover. Limit = floor((outdoorSeconds x oxygenSafetyRatio - repairHoldSeconds) x walkSpeed) = 704 studs. Walk distance = breakdown point (from the base exit) + `startOffset` (airlock to exit) |
| `WEATHER` | Space weather effects. SEP: no going outside, rover stops. GST: only Kp >= `minKp`, map and self-driving stop. Real event windows are in `data/donki/windows.json` |
| `MANUAL_DRIVE` | Multiplayer manual driving. Top speed `v1MaxSpeed` studs/s, boost x`v1BoostMultiplier` (`v1BoostOnSeconds` s on, `v1BoostCooldownSeconds` s cooldown), battery `batteryMax`, drains `batteryDrainPerSecond` per second while moving (x`boostDrainMultiplier` while boosting), charges 1:1 from base energy but keeps `chargeKeepEnergy`, field repair costs `repairEnergy`. `detourFactor`, `fillSeconds`, `unloadSeconds` are simulation assumptions |
| `metersPerStud` | See Units |
| `MISSIONS` | Per-mission values. `C` is playable; `B` is a `playable: false` placeholder (numbers not final, do not use) |
| `derived` | Values computed by Rules.luau for checking (not keys in MissionConfig): `walkRepairLimit`, and per mission `sites[]` (nearest first, `siteIndex` from 1) with the round-trip plan `trip` and the rush plan `rushTrip` |

### Mission C (`MISSIONS.C`)
| Key | Meaning |
|---|---|
| `start`, `cap`, `crew` | Starting resources, cap, crew use per day (same for any team size; `crewPerExtraPlayer` is unused while `crewScaling` is false) |
| `stallMode`, `shedOrder`, `crewEnergyLast` | When upkeep cannot be paid. `priority` stops facilities from the front of `shedOrder` first (the greenhouse `farm` is last). With `crewEnergyLast: true`, facility energy upkeep is paid before crew energy (unpaid crew energy is a warning and a score penalty, not a loss) |
| `panels` | Solar panels. Energy `cost` each, `output` per panel per day, at most `perDay` installs per day, `total` panels, `installSeconds` hold. `emergencyInstall`: if energy is short and panel output is below crew use, a panel can be installed with the energy left |
| `facilityOrder`, `facilities` | Facility definitions: `cost` (build cost), `buildDays`, `upkeep` (per day), `requires` (must be built first), `canPause`, `buildFrom` (`outdoor` on site, `map` from the map), `harvestEveryDays` and `harvestAmount`, `farmEnergyUpkeepMultiplier` and `farmWaterUpkeepMultiplier` (greenhouse upkeep multipliers), and for the pipe `unlockDeliveries` (unlocks after this many base deliveries), `deliverEveryDays`, `deliverAmount`, `multi`, `maxCount` |
| `ice` | `amountPerTrip` per collection, `cooldownDays` per site |
| `iceSites` | Ice sites and their distance (studs) from the base exit (BaseExit). The rules sort by distance, not by number (`siteIndex` 1 = nearest) |
| `manualDriveDistances` | Distances from the rover parking spot. Used only by simulation bots and reports |
| `rover` | Solo self-driving (formula below), damage and repair, route `risk` (the first level with distance < `maxDistance`; `extreme` only when rushing a high-risk route) |
| `medalOrder`, `medals` | A medal = a list of completed facilities. Meeting the gold list ends the mission right away |

### Self-driving formula (Rules.tripPlan)
- `base = 2 x distance / (fsdStudsPerDay x risk[level].speedFactor)`, `damageFactor = max(0.1, 1 - slowdownPerDamage x damage)`
- `raw = base / damageFactor`, times `rushTimeFactor` when rushing. Round-trip days `days = max(1, floor(raw + 0.5))`
- Energy `energy = ceil(base x energyPerTravelDay x (rushEnergyFactor when rushing) - 1e-9)` (damage does not change energy)
- Rushing raises the risk by one level. Damage chance = `risk[level].damageChance x damageChanceMultiplier`
- `rawDays` in `derived` is rounded to 2 decimals for display. Compute days from the unrounded value.

### On-screen text
- The JSON has no sentences. Look up names and text by key in `i18n/strings.json` and fill them with `i18n/loc.js`.
- Examples: facility `facility.<facility id>.name`, resource `res.<energy|water|food>.name`, ice site `map.ice.label` (`{n}` = the number in the id, Ice4 -> 4), risk `map.risk.<low|mid|high|extreme>`, medal `medal.<gold|silver|bronze>.name`, score lines `score.deduct.<resource>_low`, `_zero`, `oxygen_rescue` (loc.js picks the `.one` or `.other` plural when you pass `count`), mission `mission.c.name`, distance `map.ice.distance` (`{n}` = meters).
