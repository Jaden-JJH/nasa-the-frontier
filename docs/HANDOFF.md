# The Frontier 핸드오프 (2026-11-14 작성)

다음 세션의 Claude가 이 문서 하나로 이어서 일할 수 있게 쓴 인수인계서다. 기준 시점: 2026-11-14, 저장소 HEAD `9038307`, 원격과 동기화 완료, 미커밋 변경 없음.

## 0. 다음 세션 시작 순서

1. 이 문서를 끝까지 읽는다.
2. 아래를 읽는다. `docs/GDD.md`(확정 기획, 수치, 각 라운드 절), `docs/CONTRACT.md`(서버-클라이언트 계약, 모듈 경계, Config 키), `docs/FEEDBACK_2026-10-19.md`(최근 사용자 피드백 추적), 필요 시 `docs/MAP_SPEC.md`.
3. 상태 확인 명령(저장소 루트에서, 한 줄씩):
   ```
   git status -sb && git log --oneline -5
   export PATH="$HOME/.rokit/bin:$PATH"
   lune run tests/run.luau; rm -rf build
   ```
   기대값: 단위 71 통과, 스모크 OK 527, 실패 0.
4. 에이전트를 띄우기 전 구독 인증 확인: `claude auth status --json`에서 loggedIn true, authMethod claude.ai, apiProvider firstParty, apiKeySource 없음, subscriptionType team. 2026-11-14 확인 완료.
5. 사용자에게 먼저 물을 것: (a) 해커톤 제출 일정과 남은 기간, (b) 2026-10-19 이후 Studio에서 직접 바꾼 것이 있는지(라이브 게임이 2026-11-13에 다시 게시됐지만 저장소는 10-19 이후 변경 없음), (c) 팀원과 함께 플레이해 본 결과와 RunLog 기록.
6. 아주 자세한 맥락이 필요하면 전체 대화 기록: `/Users/jaden/.claude/projects/-Users-jaden-Documents-------/72a6c3ac-e3e1-43b9-b19b-150c13dc03b7.jsonl` (약 27MB).

## 1. 프로젝트 개요

- 행사: 해커톤, NASA 테마. 작업 폴더 `/Users/jaden/Documents/해커톤/나사`. 같은 폴더의 `NASA/`는 9월 CubeTrust용 Next.js 프로젝트로 이 게임과 무관.
- 팀 4명: 재은(기획), 지원(기획 50, 디자인 50), Mahim(개발 80, 기획 20), 진협 = Jaden = 사용자(개발 100). 사용자는 Luau를 모르며 코드는 Claude가 쓰고 사용자는 읽고 판단한다.
- 게임: "The Frontier". 달 남극 기지 건설 협력 생존 교육 게임. 게임 안 90일(현실 15분, 1일 = 10초) 안에 Habitat A -> Farm B -> Research Lab C를 완성하면 승리. 자원 Energy, Water, Food. 플레이어 HP = 우주복 산소. 서버 하나에 기지 하나를 2~4명이 공유.
- 대상: 비전공 학생과 교사. 심사위원이 15분 플레이.
- 플랫폼: Roblox(Luau). 원래 언리얼 계획에서 2026-10-17 전환. Rojo + Git + PR 협업, Team Create. 해커톤 제출은 Roblox 링크 허용.
- 비주얼: Quaternius Ultimate Space Kit(로우폴리, CC0). Figma Planning의 Concept 2 프레임(node 177:41). 지원의 매핑: A = 구부러진 생활동(House Long), B = 검은 뚜껑 재배동(Base Large), C = 큰 돔(Geodesic Dome), 로버는 큰 쪽.

## 2. 그라운드 룰 (반드시 지킬 것)

전역 규칙은 `~/.claude/CLAUDE.md`에 있고 매 세션 자동 로드된다. 요약:

- 에이전트 실행은 구독 계정만. API 키 과금 금지. 자식 에이전트에게도 같은 지시를 전달. 구독 한도에 걸려도 API로 우회 금지. 비밀 값 출력 금지. 쉘 환경에 ANTHROPIC_API_KEY가 설정돼 있으나 세션은 claude.ai 인증을 쓴다.
- 타이포그래피(비협상): 파일, 주석, 커밋 메시지, 챗 응답 모두 em dash(U+2014), en dash(U+2013), horizontal bar(U+2015), minus sign(U+2212), middle dot(U+00B7), bullet(U+2022), U+2027, U+2219, U+30FB 금지. ASCII `-`와 쉼표만. PreToolUse 훅 `~/.claude/hooks/no-fancy-typography.js`가 Write/Edit를 막는다. 커밋 전 검사:
  ```
  grep -rlP '[\x{2013}\x{2014}\x{2015}\x{2212}\x{00B7}\x{2022}\x{2027}\x{2219}\x{30FB}]' src tests docs
  ```
  출력이 없어야 한다(종료 코드 1이 정상).
- 작업 후 내가 만든 임시 파일만 정리. 사용자 파일 삭제 금지, 애매하면 확인.
- LLM API 비용이 드는 작업은 사전 동의.
- 언어: 사용자 응답은 한국어. 게임 문구와 주석은 한국어, 식별자는 영문. 스크립트 확장자 `.luau`.
- 수치와 문구는 전부 `src/shared/Config.luau`에 둔다.
- 문서 편집: `docs/GDD.md` 등은 앵커 기준 삽입, 치환만. 절을 통째로 다시 쓰지 않는다(과거 "밸런스 검증 메모"~"5. 플레이 흐름" 재작성으로 효과음, 충전 도크 절이 삭제돼 `7ec2ecd`로 복원한 사고).
- 검사 명령(저장소 루트, 각 줄 따로 실행):
  ```
  export PATH="$HOME/.rokit/bin:$PATH"
  stylua src tests
  selene src tests
  rojo sourcemap default.project.json -o sourcemap.json && luau-lsp analyze --sourcemap=sourcemap.json --definitions=.cache/globalTypes.d.luau src; rm sourcemap.json
  lune run tests/run.luau; rm -rf build
  ```
  selene 기존 경고 1건(`tests/server_smoke.luau` 변수 가림 `origin`)은 정상. `grep -c`는 0이면 && 체인을 끊으니 검사 명령을 && 체인에 섞지 않는다. `lune run`은 `build/smoke.rbxl`을 만드니 `rm -rf build`.
- Git: 커밋 메시지는 영어 conventional(feat, fix, docs, balance, test, chore), AI 표기 없음. 사용자 전역 pre-push 훅(`~/.git-hooks/pre-push`, `core.hooksPath`)이 하루 3회 푸시 한도를 건다(스크립트가 "0\n0" bash 파싱 오류를 출력하지만 동작함). `--no-verify` 우회는 사용자가 2026-10-19 한 번 허락했을 뿐이며 다시 쓰려면 다시 물어야 한다. 사용자는 "푸시는 Claude가 해라"라고 했다.
- 커밋은 에이전트 작업이 끝난 뒤에만. 두 에이전트가 같은 파일을 동시에 고치거나 스테이징과 겹치면 레이스가 난다(실제로 SPEEDS/food 변경이 다른 커밋에 섞인 적 있음).

## 3. 사용자 작업 방식과 취향

- 기획 빈칸은 진행하면서 계속 질문. grill-me(한 번에 한 질문 + 추천 답) 형식 수용.
- "너가 직접 하지 말고 서브에이전트를 적절한 모델로 나눠서 시켜, 너는 검수." 구현은 서브에이전트, 리드(Claude)는 지시서 작성, 검수, 커밋, 문서 병합.
- 라운드가 끝나면 바로 커밋하고 알린다. 푸시도 Claude가 한다.
- UI 위치를 이유 없이 바꾸는 것을 싫어한다. 배치 변경은 이유와 함께 보고.
- "애매하게 수정하지 말고, 실제 우주라면 어떻게 할지 생각해서 직관적으로, 기존 인게임 디자인과 인터랙션에 맞게." (19차 제어반 사례)
- 웹 UI 수준의 디자인을 원한다. UI를 크게 바꿀 때는 먼저 HTML 목업을 여러 안으로 보여 주고 고르게 한다. "덜 AI처럼"(유리 카드, 흰 1px 테두리, 알약 배지, 점 게이지 같은 템플릿 요소 피하기).
- 밸런스는 "너무 쉬워지게 말고 미세조정". 사실적인 달 분위기(검은 하늘, 회색 표토, 얼음은 결정 덩어리), 캐릭터는 우주복, 월드 문구는 디자인된 패널, 안내 문구(튜토리얼 힌트)를 중시.
- 응답은 짧게, 결론 먼저.

## 4. 현재 상태 스냅샷

| 항목 | 값 |
|---|---|
| 저장소 | https://github.com/Jaden-JJH/the-frontier (private, gh 계정 Jaden-JJH), 로컬 `/Users/jaden/Documents/해커톤/나사/the-frontier` |
| HEAD | `9038307` (커밋 60개, 원격과 동일) |
| 테스트 | 단위 71, 스모크 OK 527, 실패 0 |
| 플레이 링크 | https://www.roblox.com/games/73322847605665/The-Frontier |
| 제작자 대시보드 | https://create.roblox.com/dashboard/creations/experiences/10771556681/overview |
| Universe / Root Place | 10771556681 / 73322847605665 |
| 제작자 Roblox 계정 | Jaden950130 (user id 11824484899) |
| 라이브 게임 마지막 업데이트 | 2026-11-13 13:46 UTC (저장소는 2026-10-19 이후 변경 없음, 확인 필요) |
| 방문 수 | 26 (2026-11-14 조회) |
| Max Players | 50 (권장 4, 여유 6으로 낮출 것. 미조치) |
| Studio API 접근 | 꺼짐(Studio 테스트에서 명예의 전당이 "저장소 연결 안 됨". 라이브는 정상) |
| 공개 상태 | 사용자가 2026-10-19 "팀원 초대해서 플레이할 수 있게 됐다"고 보고. 계정 2일 조건 통과 |
| 팀원 안내문 | `/Users/jaden/Documents/해커톤/나사/팀원_플레이_안내.txt` (8부 34단계, 게임 링크 기입 완료) |

## 5. 배포 절차 (코드를 고친 뒤 라이브에 반영)

1. 터미널에서 저장소 루트 `rojo serve` 실행(Rokit 1.2.0, PATH는 `~/.zshenv`). 종료하지 말 것.
2. Studio에 뜨는 Rojo 창 "Project 'TheFrontier' is serving at localhost:34872" 에서 Connect. 로컬 동기화이므로 localhost가 정상.
3. 확인: Explorer의 ReplicatedStorage.Shared, ServerScriptService.Server, StarterPlayerScripts.Client. Play 한 번 눌러 Output에 `[DevMap] 조명` 줄 확인 후 Stop.
4. File > Publish to Roblox. 기존 경험 "The Frontier"로 올린다(새로 만들지 않음).
5. Creator Hub에서 업데이트 시각과 Access(친구/공개) 확인.
6. Rojo가 관리하는 것은 `default.project.json` 기준 ReplicatedStorage.Shared, ReplicatedStorage.Remotes 폴더, ServerScriptService.Server, StarterPlayerScripts.Client, Workspace.Gravity 32.7뿐이다. Workspace.KitImports(사용자가 Studio에서 Import 3D로 넣은 메시 19개), Lighting의 Sky, Atmosphere 등은 플레이스 파일에만 있고 저장소에 없다.

Roblox 공개 정책(2026-10 공식 문서 확인): 16세 이상 공개는 계정 2일 경과 + 연령 확인 + 연령 제한 콘텐츠 질문(No -> Content May Vary). 요건은 첫 릴리스, 업데이트, 대상 변경 모두에 적용. 16세 미만(Kids & Select)은 신분증, 2FA, Premium 2개월 또는 1,000 Robux, 250 플레이 평가가 필요해 해커톤 안에 불가. 제출 설명에 "학생 바로 체험 가능"이라고 쓰지 말 것. 미공개 상태에서는 Collaborators(Edit/Playtest)와 Early testers(친구 10명)만 플레이 가능.

## 6. 게임 시스템과 현재 수치

모든 값의 원본은 `src/shared/Config.luau`. 아래는 2026-11-14 기준.

### 6.1 시간, 자원, 승패
- DAY_SECONDS 10(90일 = 15분), SPEEDS {1}(2배속 제거, 사용자 결정).
- START: energy 50, water 25, food 35. CREW 하루 food 1, water 1.
- 패널: PANELS_TOTAL 25(슬롯 5 x 5), PANELS_PER_DAY 3, PANEL_OUTPUT 1 E/일/장 x 착륙지 일조율. 설치 시 펼침 1.5초 연출.
- 에너지 상한: ENERGY_CAP_BASE 150 + 모듈당 100. 넘치면 버림(energyWasted).
- 물 처리 전력: WATER_PROCESS_ENERGY_PER_W 0.35 (20차 S3, 이전 0.5).
- 실패: 물 또는 식량 부족 연속 SHORTAGE_DAYS_TO_LOSE 4일(20차 S3, 이전 3), 90일 안에 C 미완공, 산소 0이면 즉시 실패(12차). 승리: WIN_MODULE C 가동 즉시.
- RESULT_MIN_SECONDS 10. 재시작은 착륙지 선택 권한자만.

### 6.2 모듈
| 모듈 | 비용 | 건설 | 유지비/일 | 생산 | 비고 |
|---|---|---|---|---|---|
| A Habitat | E 60, W 20 | 5일 | E 3, W 1 | 없음 | 산소 회복 구역 |
| B Farm | E 80, W 30 | 5일 | E 6, W 2 | 식량 +2 | canPause(제어반에서 대기 전환) |
| C Research Lab | E 150, W 50 | 7일 | E 8, W 3 | 없음 | 완공 = 승리 |

### 6.3 착륙지 (DEFAULT_SITE_ID 2)
| 착륙지 | 일조율 | 가까운 얼음까지(studs) | 얼음 거리 표기 | 지형 위험 |
|---|---|---|---|---|
| 1 Shackleton Rim | 1.00 | 450 | 멀다 | 낮음 |
| 2 de Gerlache Ridge | 0.85 | 300 | 중간 | 중간 |
| 3 Malapert Massif | 0.70 | 180 | 가깝다 | 중간 |
| 4 Nobile Crater | 0.60 | 100 | 매우 가깝다 | 높음 (숙련 팀 추천) |

### 6.4 얼음 매장지 8곳 (합계 590 W, 고갈 있음)
Ice1 mid 55, Ice2 easy 45, Ice3 easy 45, Ice4 mid 60, Ice5 mid 55, Ice6 hard 110, Ice7 hard 110, Ice8 hard 110. hard는 바위 고리(입구 60도)와 크레이터 사이, 레이더에서 보라 점. Attributes: Deposit, DepositMax, Difficulty. Ice1~Ice3 위치는 첫 원정 거리 기준이라 바꾸지 않는다.

### 6.5 로버
- tankMax 60, fillHold 3초, maxSpeed 18, torque 1200, driveSign -1, steerSign -1(거꾸로 가면 1로).
- 배터리: batteryMax 50, 주행 중 0.3/s, 0이면 정지, ChargePad(반경 10, 빈 좌석일 때) 2 E/s 기지 에너지 차감, 복구 시 20%. DockState empty(노랑) -> docked(하늘색) -> charging(노랑 펄스) -> full(초록).
- 부스터: Shift, 속도 1.6배, 소모 3배, 연속 4초 후 쿨다운 6초, 배터리 20% 이하 불가. 파티클, 빛, 과열 연기, 클라이언트 FOV +12, 비네트.
- 파손(ROVER_DAMAGE): 속도 12 이상 충돌, 3회면 정지, 1회당 10% 감속, R 4초 + 10 E 수리.
- 복구(ROVER_RECOVERY): 뒤집힘/추락/소실 시 착륙선 콘솔 E, 빈 좌석만, 탱크 물 잃음, 쿨다운 15초.

### 6.6 산소
max 100, 야외 60초에 소진, 실내 초당 10 회복, 20 이하 경고음. 0이면 즉시 실패. Config.OXYGEN.deathPenalty와 Simulation.applyOxygenDeath는 쓰러짐 집계용으로 남아 있다(확인 후 정리 후보). 에어락: 착륙선과 Habitat A 정면 문, E로 열기 6초, 산소 구역은 건물 내부만.

### 6.7 랜덤 이벤트 (15차, Config.EVENTS)
- 태양 입자 폭풍: 게임당 1회, 30~50일 시작, 2일 전 예고, 2일 지속. 패널 x0.5, 실외 산소 소모 x1.5.
- 미세운석: 1~2회, 15~80일, 10일 이상 간격, 폭풍 기간과 겹치지 않음. 가동 모듈(승리 모듈 제외) 외벽 손상(생산 정지, 유지비 계속), 후보 없으면 패널 1장 파괴, 패널도 없으면 빗나감. 공정성: 가동 5일 유예(graceDaysAfterActivation, ModuleState.activatedDay), 직전 대상 연속 금지(noRepeatTarget). 수리는 제어반에서 R 4초 + 10 E.
- 시드 기반 일정(GameState.eventSchedule, 클라이언트는 읽지 않음). 알림: Day 패널 아래 배너(예고 회색, 진행 빨강, 교육 한 줄), 우상단 토스트, 모듈 행 "손상, R로 수리", 첫 발생 Tip.

### 6.8 모듈 제어반 (19차, ModulePanels.luau)
- 완공 모듈마다 Origin 쪽 외벽, 면 중앙에서 오른쪽 3, 패드 윗면 + 3.2 높이에 3 x 1.9 패널. 상태등 초록(가동), 노랑(대기), 빨강 0.8초 깜빡임(손상). SurfaceGui: 이름, 상태, 효과, 조작 안내.
- Farm 가동 중지/재개 E 1초 홀드, 외벽 수리 R 4초, 거리 8. 토글음 ui_click. 패드 표지판은 완공 뒤 이름과 상태 배지(+ 손상 배지)만.
- 스모크 실측(Shackleton, 기지 기준): A (-23.3, 3.3, -9.1) +X면, B (-23.8, 3.3, 22.1) +X면, C (3.3, 3.3, 26.7) -Z면. 둥근 메시는 Studio에서 광선으로 벽에 붙음(스모크는 상자 기준만 검증).
- 배경: 이전 가동 중지 프롬프트는 패드 중심(건물 안) 반경 8이라 17 x 17 건물 밖에서 닿지 않았다(사용자 버그 보고).

### 6.9 기여도와 기록 (16, 17차)
- Contributions: 플레이어별 패널, 처리한 물, 착공, 수리, 산소 고갈(쓰러짐 포함). MVP 없음.
- Ranking(순수 로직, 일수 오름차순, 동률은 먼저 세운 기록) + Records(DataStore "FrontierRecords", 키 "top", 상위 10, pcall + 1회 재시도, 실패 시 메모리 폴백과 offline 상태). Remote Records(S->C). 날짜는 한국 시간 고정.
- 표시: 결과 화면에서만(사용자 결정 17차. 타이틀 패널과 기지 기록판은 제거).

### 6.10 교육과 안내
- Facts.luau 10개(landing_site, first_panel, first_water, module_A, module_B, module_C, oxygen_low, gravity, result_win, result_lose). FactUI: 화면 오른쪽 세로 중앙 남색 카드, 10초, 세션당 1회, 상태 트리거 4초 지연. 결과 화면 "오늘 배운 것" 최대 3개. 제외한 불확실 사실 목록은 GDD "교육 사실 카드" 절.
- TIPS 11개: start, boost, radar, farmWater, panelLimit, airlock, damage, energyCap, storm, moduleDamage, waterTripNow(물 15일분 이하 + 아직 하역 0이면, WATER_TRIP_TIP_DAYS 15). MISSION_TEXTS.boardRover에도 "물이 15일분 아래면 바로 원정" 힌트가 15로 직접 적혀 있어 WATER_TRIP_TIP_DAYS를 바꾸면 함께 고칠 것.
- SettingsUI: 우하단 체크박스 "Tip 표시", "알고 있나요? 표시"(세션 메모리).

### 6.11 조명과 지형 (DevMap.luau)
Brightness 7, Ambient (75,76,86), OutdoorAmbient (120,122,138), ExposureCompensation 0.6, ShadowSoftness 0, GlobalShadows true, EnvironmentDiffuse/SpecularScale 0, Fog 90000/100000, ClockTime 0, GeographicLatitude 70(광원 고도 약 20도는 가정 공식, 시작 로그 `[DevMap] 조명`의 측정값으로 확인), ColorShift_Top (255,248,235). 표토 (150,148,144), 산 (110,108,106), 바위 (118,116,114). Lighting Attribute KeepLighting / KeepSky / KeepAtmosphere가 true면 서버가 덮어쓰지 않는다. Lighting.Technology는 ShadowMap 또는 Future여야 그림자가 나온다(스크립트로 변경 불가). 지구는 Neon 구/메시, 광원 방향에서 30도 이상 떨어지게 자동 배치. 지형: 기지 콘크리트 판 윗면 1.5, 바깥 Terrain -1.5, 약 2600 x 2200, 크레이터 80, 바위 약 575, 산(가장자리 봉우리 90 + 능선 5).

### 6.12 UI 배치
- Layout.luau: 배율 = 화면 높이/720(0.7~1.25), compact = 터치 전용 또는 높이 600 미만. 뷰포트 높이 200 미만이면 1280x720으로 간주.
- HUD: 좌상단 자원 패널, 그 아래 모듈 A/B/C 패널(compact는 상단 중앙 칩 한 줄), 상단 중앙 Day + 미션 + 이벤트 배너, 우상단 패널 수, 탱크, 배터리, 부스트 게이지(주황, 사용자 지시로 유지).
- 레이더: PC 좌하단 지름 180, compact 자원 패널 아래 140. 라벨 왼쪽 정렬 폭 지름 + 140.
- Tip 카드: 우하단, Layout 배율 적용, PC 오른쪽 16 아래 56 폭 360 본문 18, compact 오른쪽 12px 아래 230px. 체크 패널은 그 바로 아래(PC 아래 12, compact 아래 190px).
- 토스트: PC 우측 열 실제 하단 + 8, compact 상단 중앙.
- 산소 바: 하단 중앙. 부스터 버튼(터치): 점프 버튼 위.
- 색 의미: 노랑 에너지, 하늘색 물, 초록 식량, 주황 산소, 보라 바위밭 얼음, 에어락 태그 초록.
- 메뉴 3종(18차): 전체 C "루나 소프트"(남색-보라 그라데이션, 둥근 패널, Nunito, RobotoMono). 타이틀(달, 지평선, 시작하기). 착륙지 선택은 남극 지도(위도 링, 크레이터, 번호 핀, Config.SITE_MAP) + 오른쪽 상세(일조율 바, 얼음 거리, 로버 왕복 시간, 지형 위험) + 4행 목록, 미리보기 -> "여기에 착륙" 확정 2단계(권한자만 확정). 결과 화면은 C 바탕과 오른쪽 열(명예의 전당, 오늘 배운 것)에 왼쪽 열만 A "관제실"(상태 라벨, 제목, 모노 숫자 타일, CREW LOG, 재도전).
- HTML 목업 캔버스(claude.ai Design 아티팩트, 사용자 소유): https://claude.ai/artifact/USwQLy63bv16woWfDE1eNC . A/B/C 각 3장. 최종안은 C 줄(v13). 로컬 스크래치 사본은 세션 종료로 사라졌고 캔버스가 유일한 원본.

### 6.13 사운드
`src/shared/SoundIds.luau` 36키, 전부 Roblox 공개 라이브러리 음원(creator Roblox user 1, ProSoundEffects)으로 비인증 API로 공개 확인. Studio 실제 재생은 미확인. 서버 3D(Sfx.luau), 클라이언트 2D(SoundFX.luau, 호흡 루프). 18초 루프 2개는 PlaybackRegion으로 이음매 개선 여지. 새 id 추가 시 검증 기록은 `docs/SOUNDS.md`.

### 6.14 RunLog (20차 보조)
서버가 매 DayTick 스냅샷과 사건(첫 패널, 탑승, 원정 출발과 하역량, 착공과 완공, 가동 중지, 손상과 수리, 산소 고갈, 폭풍, 운석)을 모으고, 10일마다 `[RunLog] D10 ...` 한 줄, GameOver 때 `[RunLog] ===== 플레이 기록 =====` 요약(60줄 이내)을 Output에 찍는다. 로버 수리(RoverDamage)는 기록하지 않는다. 사용자에게 이 블록을 받아 봇 보정에 쓰기로 했다(아직 못 받음).

## 7. 밸런스 근거 (봇 시뮬레이션)

`tests/bot.luau`에 프로필 3종: perfect(완벽 동선), semi("한 번 해 본 사람": 시작 대기 1일, 패널 처음 5일 2장, 원정 x1.3, 지연 10%, 첫 원정 물 14일분 이하, 이후 "지난 원정 + 3일분", 가까운 두 곳 중 큰 쪽, 착공은 원정 물을 남길 때만, Farm 중지 80%), human("처음 하는 사람": 시작 대기 2일, 패널 2장 + 20% 건너뜀, 원정 x1.6 + 지연 20%, 가장 가까운 얼음만, 첫 원정 물 10일분, 착공 1일 지연, Farm 중지 50%).

20차 경과: 사용자 "기본 난이도 너무 높다, 딱딱 맞게 해도 부족" + "너무 쉬워지게 말고 미세조정". 기존 밸런스는 perfect만 이기는 칼날이었다(human, semi 0%). 시작 자원 +5~7, 부족 4일, easy 35 같은 미세조정은 승률 0%p. 원인은 Farm 뒤 물 소비(하루 4)를 원정 수입이 못 따라가는 구조. 1차 큰 폭 안(물 60, 부족 7, Lab 물 30 등)은 너무 쉬워 철회. 승인된 S3:

| 변경 | 이전 | S3 |
|---|---|---|
| easy 매장량 | 30 | 45 |
| mid 매장량 | 40/50/40 | 55/60/55 |
| 물 처리 전력 | 0.5 E/W | 0.35 E/W |
| 부족 실패 | 3일 | 4일 |

S3 결과(시드 300, 이벤트 포함):

| 착륙지 | perfect 승리일(전 -> 후) | semi 승률 / 평균 | human 승률 |
|---|---|---|---|
| Shackleton | 60 -> 40 | 93% / 55일 | 0% |
| de Gerlache | 57 -> 37 | 98% / 53일 | 0% |
| Malapert | 55 -> 36 | 92% / 65일 | 0% |
| Nobile | 61 -> 52 | 0% | 0% |

- 기여도(ablation): 매장량이 유일한 1차 손잡이(semi +57~91%p), 처리 0.35는 그 위에서 Malapert +14%p, 부족 4일은 그 위에서 +7~22%p.
- 이벤트 최악 격자(perfect, 곳당 3,835판) 패배 0.
- Nobile semi 0%는 전부 식량. "숙련 팀 추천"으로 유지.
- 다이얼: 너무 쉬우면 mid 50/55/50(perfect 40/47/45, semi 63/97/88%).
- human 0%는 수치가 아니라 안내 문제로 보고 첫 원정 Tip을 넣었다(봇은 Tip을 못 읽어 효과 미측정).
- DAY_SECONDS 민감도: 10초(15분) perfect 60/57/55/61, 12초(18분) 47/50/43/72, 15초(22.5분) 35/40/49/시간초과. 하루를 늘리면 숙련자만 빨라지고 Nobile은 하루 충전량 증가로 Lab 전력이 안 모여 깨진다. 10초 유지 결정.
- 이전 라운드 결론(유지): 하루 패널 3장(2장 이하는 A 지연 -> Farm 식량 마감 -> 저일조 패배), 패널 25, Farm 전력 6, Farm 물 2(3~4면 Nobile 항상 패배), Lab 물 50, hard 110, 탱크 60. 전력 압박이 착륙지에 비대칭인 것은 설계 트레이드오프로 수용(사용자 "원안대로").

## 8. 미결 과제와 다음 할 일

### 8.1 사용자 쪽 확인 대기 (Studio 또는 라이브)
- RunLog 블록 받기(팀원과 한 판 뒤 Output 복사).
- Max Players 50 -> 4(또는 6).
- 원하면 Game Settings > Security > Enable Studio Access to API Services 켜기.
- 미확인 시각 점검: 메뉴 3종(폰트 Nunito/RobotoMono, RichText, 상단 바 겹침, 폰 세로 스택), 제어반(메시 벽 부착, 글자 가독성, 프롬프트 겹침, 작물 가림), 조명 밝기와 광원 고도(로그 측정값), Technology ShadowMap/Future, 사실 카드와 Tip 겹침, 이벤트 배너/토스트/수리, 명예의 전당 저장, 첫 원정 Tip 시점, boardRover 문구 넘침, 물 0 4일째 실패, 사운드 실제 재생.

### 8.2 다음 작업 후보 (우선순위 제안)
1. 다중 접속 테스트: 이전엔 공동 체험 불가로 후순위였으나 이제 팀원 접속 가능. 4인 동시 플레이에서 권한자, 재시작, 로버 좌석, 프롬프트 경합 확인.
2. RunLog로 human/semi 봇 보정 후 밸런스 재확인(필요 시 mid 다이얼).
3. 인게임 HUD를 메뉴와 같은 루나 톤으로 리디자인(제안만 한 상태, 사용자 승인 전. 먼저 HTML 목업).
4. 제출 체크리스트: `docs/reviews/00_통합_우선순위.md` 5절(MaxPlayers 4, 비권한 계정 입장 시험, 제출 설명 첫 문장 "Roblox 계정과 Player 필요", 아이콘과 썸네일, 2분 녹화본, Git SHA와 플레이스 버전 기록, 에셋 소유 목록, 크레딧 Quaternius).
5. 교사용 가이드(사용자: 나중에).
6. 정리 후보: boardRover 문구의 하드코딩 15, RunLog에 로버 수리 기록 추가, OXYGEN.deathPenalty 잔존 경로 점검, GDD "미결과 현장 후보" 절 갱신.
7. 미해결 외부: Figma 디자인 파일(`u2iUOOVtVDSTl5BUHFxPIZ`)은 MCP 계정(kaist)에 편집 권한이 없어 403. 소유자가 편집자 초대 필요.

## 9. 알려진 함정과 교훈

- 뷰포트 의존 배치를 init에서 한 번만 정하면 Studio 초기 뷰포트가 작아 compact로 굳는다(14차). Layout.changed나 주기 루프에서 재적용.
- Terrain이 얇은 패드를 덮는다 -> 기지는 콘크리트 판(윗면 1.5), 바깥 Terrain(-1.5).
- 에어락 통로(Connector 튜브)는 방향/높이가 어긋나 폐기, 문 + 보이지 않는 벽 방식.
- 프롬프트 키가 한글 자판 글자(ㄷ)로 보임 -> KeyCode.Name 사용.
- 프롬프트를 건물 안 파트에 붙이면 밖에서 안 닿는다(19차) -> 외벽 제어반.
- 바위와 크레이터가 얼음 주변에만 몰림 -> 기지 둘레 링, 회랑 옆, 산포 3층 재분배.
- 로버 파손 임계 15는 파손 후 최고속 14.4보다 높아 2차 파손 불가 -> 12, 10%/hit.
- 롤백 요청 시 밸런스까지 되돌린 줄 사용자가 걱정함 -> 무엇을 되돌렸는지 명확히 보고.
- 봇 결함이 밸런스 결론을 왜곡할 수 있다(Nobile 80일은 원정 복귀일 충전 결함, 61일이 실제).
- 큰 폭 조정 보고가 사용자 지시 변경("미세조정")보다 먼저 도착할 수 있다. 지시 변경 뒤 도착한 결과는 커밋하지 말 것.

## 10. 에이전트 운영

- 서브에이전트는 세션 소속이라 다음 세션에서는 이전 에이전트(core2, client2, client3, gitmaster2, events, edu, moon, records, ui-a, panels, telemetry 등)를 재사용할 수 없다. 새로 띄우고 GDD, CONTRACT, MAP_SPEC, 해당 모듈을 다시 읽힌다.
- 모델 선택: 규칙/밸런스/여러 파일 서버 작업과 큰 UI 재작성은 opus, 국소 수정과 문서는 sonnet.
- Opus 에이전트는 긴 라운드에서 "Prompt is too long"으로 종료된 적이 있다(core -> core2 -> core3). 라운드 단위로 교체.
- 에이전트는 SendMessage 보고와 idle_notification을 둘 다 보내 같은 결과가 두 번 온다. 한 번만 처리.
- 동시 실행 시 파일 범위를 겹치지 않게 나누고, 문서는 리드만 편집(에이전트는 스크래치 notes 파일로 전달).
- 지시서 공통 블록(그대로 붙여 쓸 것): 구독 계정만, 모델 API 직접 호출 금지, 금지 문자 9종, 한국어 문구/영문 식별자/.luau, 수치는 Config, git add/commit/push 금지, 스크래치 경로, 수정 허용 파일 목록, 위 검사 명령 5줄, 보고 형식(변경 파일, 검사 수치, Studio 체크리스트, 지시와 다르게 한 점).

## 11. 파일 지도

- 문서: `docs/GDD.md`, `docs/CONTRACT.md`, `docs/MAP_SPEC.md`, `docs/SETUP.md`, `docs/ASSETS.md`(Sketchfab/키트 절), `docs/SOUNDS.md`, `docs/FEEDBACK_2026-10-19.md`, `docs/review-prompts/`(Codex용 적대적 리뷰 프롬프트 7종), `docs/reviews/`(00 통합 우선순위, 02~06 Codex 보고서, 07 UI 배치 검토), 이 문서.
- shared: Config, Simulation(순수 규칙), Remotes(StateUpdate, OxygenUpdate, Notify, SiteSelectionOpen, LandingSequence, GameOver, Records, SelectSite, SetSpeed, RequestRestart, RoverBoost), Types, SoundIds, Facts, Ranking.
- server: Main.server, GameClock, ResourceState, GameFlow, LandingSite, SolarPanels, Construction, ModulePanels, ModuleRepair, WaterLoop, Oxygen, Airlock, Spacesuit, RoverDrive, RoverRecovery, RoverDamage, RoverBattery, RoverBoost, KitImports, DevMap, BaseLights, Sfx, Events, Contributions, Records, RunLog, ServerUtil.
- client: Main.client, UI, Layout, HUD, TitleUI, SiteSelectUI, LandingCamera, OxygenBar, RadarUI, ToastUI, ResultUI, PromptUI, PadSignUI, DockSignUI, RoverHint, ObjectiveHighlight, RoverBoost, BoostFX, SoundFX, TipUI, FactUI, SettingsUI.
- tests: `run.luau`, `simulation.spec.luau`(단위), `ranking.spec.luau`, `bot.luau`(perfect/semi/human), `server_smoke.luau`(Lune 에뮬레이터), `harness.luau`. CI `.github/workflows/ci.yml`(setup-rokit v0.2.1).
- 도구: Rokit 1.2.0으로 rojo 7.7.1, selene 0.32, stylua 2.6, luau-lsp 1.70, lune 0.11.
- 외부 에셋: `~/Downloads/the-frontier-kit/`(Rover, Lander = House Cylinder, HabitatA/B/C, Panel, Rock1-3, extras 10종 Planet, IceCrystal = Rock Large-d2VWOdthtR, WaterTank = House Single, Connector, ConnectorElbow, Pad, Antenna, Radar, Crate, Crop, README.txt). OpenGameArt CC0 GLB 미러에서 받아 glTF로 변환. Studio의 Workspace.KitImports에 19개 가져옴.
- 사용자 폴더: `/Users/jaden/Documents/해커톤/나사/팀원_플레이_안내.txt`.
- Claude 메모리: `/Users/jaden/.claude/projects/-Users-jaden-Documents-------/memory/`(MEMORY.md, the-frontier-roblox-game.md, the-frontier-ui-mockups.md, jaden-profile.md, figma-the-frontier-planning.md).
- Figma Planning(읽기 가능): https://www.figma.com/design/ZySLM8Tomev3cjXVKnA4hZ/Planning (Concept 2 node 177:41).

## 12. 라운드 이력 요약 (커밋)

- 2026-10-17: 스캐폴드, 공용/서버/클라이언트 1차, 테스트 하네스, 키트 조립, 우주복, 커스텀 프롬프트, 지형, 걸어 들어가는 건물(`0d203aa` ~ `5315135`).
- 10-18 1~4차: 플랫 apron, 크레이터/바위 재분배, 에어락 문, 외부 리뷰 1차 컷, 1배속 고정, 식량 35(`5681f09` ~ `e508371`).
- 5차 얼음 매장량/고갈, 에너지 상한, 건설 연출, 로버 파손(`e8e7756`, `8ae3163`, `64c1761`). 6차 산, 배터리, 충전 패드(`b2d5947`, `cc0c3d8`). 7차 사운드(`2ab9cf0`, `2ddb26f`, `4f35d10`), 패널 25와 Farm 전력 6(`08fbdc0`). 8차 부스터와 Farm 가동 중지(`13d129f`, `04803c4`). 9차 부스터 연출과 사운드 보강(`20c97bd`, `feb9911`, `5b3255a`). 10차 Tip 카드(`6efaf7d`). 11차 기지 레이아웃(`a93716e`), GDD 복원(`7ec2ecd`). 12차 산소 0 즉시 실패(`833407f`, `6e329f4`). 13차 UI 검토 반영(`9a0013e`). 14차 레이더 복구, Tip 우하단(`d5447a9`, `796b13c`).
- 10-18~19 15차: 달 조명(`ef64228`), 사실 카드(`8a76f23`), 랜덤 이벤트(`bbeea63`, `55045bc`), 문서(`4952dc6`). 16차 기여도와 기록(`63029cb`).
- 10-19 17차 토글, 결과 화면 전용 명예의 전당, 밝은 조명(`93a0db6`). 18차 메뉴 리디자인(`1a6f41a`). 19차 외벽 제어반(`8b4122c`). 20차 RunLog(`9202b85`), S3 밸런스(`9038307`). 같은 날 팀원 안내문 작성, 배포 링크 확인.
