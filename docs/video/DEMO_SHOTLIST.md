# The Frontier 데모 영상 촬영 계획 (2~3분)

챌린지: "Build a Junior Astronaut Mission Trainer" (7~12세, 실제 NASA 데이터, 모든 선택에 대가). 작성 2026-11-15, 코드와 docs 기준(PRESENTATION_BRIEF, V2_PLAN 15~16절, FACTS_V2, BALANCE_LOG 8~9절, HANDOFF_V2). 짝 파일: `docs/video/scene_setup.luau`(장면 세팅 명령).

## 30초 버전 (2026-11-15 확정안, 웹 버전 포함)
전체 30초 중 Roblox 약 18초, 웹 버전 약 10초, 끝 2초. Roblox 장면은 각각 5 ~ 10초씩 찍고 편집에서 2 ~ 4초로 자른다. 아래 장면 번호는 이 문서 전체 대본의 장면 번호.

| 초 | 장면 | 화면 | 대본 장면 / 준비 |
|---|---|---|---|
| 0 ~ 2 | 타이틀 | "The Frontier", Real NASA data | 장면 0 |
| 2 ~ 5 | 착륙과 HUD | 남극 착륙, "Day 1 of 60" | 장면 2 ~ 3 |
| 5 ~ 8 | 그린하우스 | 그린하우스 솟아오름과 완공(time-lapse 자막) | 장면 7 |
| 8 ~ 11 | 로버 파견 | 콘솔 지도에서 Ice Site로 보내기, 거리 m | 장면 8 |
| 11 ~ 15 | 우주 날씨 | SEP 15초 경보, NASA DONKI 실제 날짜, 대피 | 장면 10 |
| 15 ~ 18 | 금메달 | 결과 화면, 메달, 점수 | 장면 13 |
| 18 ~ 28 | 웹 버전 | Mahi 웹판(같은 미션, 브라우저) | 웹팀 촬영 |
| 28 ~ 30 | 끝 | 로고, "Roblox + Web" | 편집 |

## 0. 요약

- 장면 16개(0~15), 전체 약 173초(2분 53초). 2명이 필요한 장면 12를 빼면 159초(2분 39초), 장면 9와 12를 빼면 145초(2분 25초).
- 2명 필요: 장면 12(관제사 핀과 역할 미션, 선택 장면). 나머지는 솔로 한 판으로 찍을 수 있다. 직접 운전(장면 9)은 코드상 솔로에서도 된다(RoverFleet.luau 헤더 "직접 운전(멀티, 솔로도 가능)").
- 새 서버 도우미가 필요한 곳: 장면 9(로버 배터리 값 맞추기, 없어도 촬영 가능), 장면 13(DataStore가 켜져 있을 때만), 재촬영이 잦을 때 미션 확정(필수 아님). 제안은 `scene_setup.luau` 맨 아래 H1~H3. 나머지 장면은 기존 코드만으로 된다.
- 우주 기상 구간은 `2023-01-27` 하나로 통일한다. SEP 29일(2일, 실제 날짜 2023-02-24)이 GST 32일(Kp 7, 2023-02-27)보다 앞이라 장면 10 다음 장면 11로 이어 찍으면 날짜가 늘기만 한다.
- MCP `screen_capture`가 PlayerGui 아래 BillboardGui(E 프롬프트와 비용 줄)를 못 찍는 장면: 4, 5, 6, 7, 9, 10(문 잠김 프롬프트). 실제 화면 녹화에는 문제없다.

## 1. 진행 방식

1. 사용자는 Studio에서 Play하고 화면을 녹화한다. 장면마다 5~30초짜리 테이크로 끊어 찍는 것을 권한다(리드 명령 사이에 녹화를 멈추거나, 계속 돌리고 편집에서 자른다).
2. 리드는 장면 사이에 `scene_setup.luau`의 PRELUDE + 해당 블록을 execute_luau(Server, Play 중)로 보낸다. 블록 이름은 아래 "사전 명령" 칸의 `4a`처럼 파일 안 `do -- 4a` 주석과 같다.
3. 처음 한 번 `PROBE` 블록으로 서버 모듈 인스턴스가 같은지 확인한다(출력의 phase, day, 자원이 HUD와 같아야 한다). 다르면 멈추고 사용자에게 알린다.
4. 녹화 창은 높이 720 이상(16:9)이 좋다. 높이 600 미만이면 화면이 compact 배치로 바뀐다(src/client/Layout.luau:13-14, 39-41).
5. 우측 하단 설정 패널에 Tips, Fact cards 체크박스가 있다. 프롬프트와 비용 줄을 보여 주는 장면 4~7은 Tips를 꺼서 화면을 깨끗하게 하고, 교육 카드가 의미 있는 장면 3, 8, 10, 11은 켠다.
6. 시계는 장면 3에서 멈추고(하루 30초가 흘러가며 자원이 줄지 않게) `advance`로만 하루를 넘긴다. 장면 8만 시계를 켠다(자율주행 지도 아이콘 이동 계산에 필요).

## 2. 말할 때 지킬 선 (PRESENTATION_BRIEF, FACTS_V2 확인 결과)

- 우주 날씨는 지난 NASA DONKI 기록을 다시 보여 주는 것이다. "실시간", "오늘의 우주 날씨"라고 하지 않는다(타이틀 About에도 "Nothing here is live").
- GST는 달 표면 현상이 아니라 지구 쪽 지원(GPS, 무선, 지도 안내) 장애로 말한다. 게임 안 문구도 같다(`event.gst.edu`).
- 착륙지 이름은 "2024년 NASA가 발표한 달 남극 착륙 후보 지역"에서 빌려 왔다. "아르테미스 III 착륙지"라고 하지 않는다.
- 얼음은 "후보지"다. 얼음이 확인된 곳이라고 하지 않는다(About: "places to search for ice, not places where ice was found").
- 화면의 미터 숫자는 게임 지도 기준이다(1 stud 약 1.25 m, MissionConfig.luau:49). 얼음 후보지 위치는 NASA 영구 음영 지도에 맞춰 게임 크기로 줄여 놓았다. "실제 거리"라고 단정하지 않는다.
- 스크립트로 날짜, 자원, 건설을 건너뛴 장면(7, 8 귀환, 10, 11, 13)에는 편집 자막으로 "time-lapse" 같은 표시를 넣는다. 연출 상태 점프를 자연 플레이처럼 보이게 하지 않는다.
- 순위 칸은 서버가 보내는 그대로 쓴다. 가짜 이름의 기록을 넣지 않는다. 저장이 꺼져 있으면 화면이 "Records are not saved on this server."라고 정직하게 말한다.

## 3. 장면표

| # | 장면 | 초 | 누적 | 사전 명령 | 인원 |
|---|---|---|---|---|---|
| 0 | 오프닝 (타이틀 위 나레이션) | 7 | 0:07 | S0 | 1 |
| 1 | 타이틀과 About the data | 10 | 0:17 | - | 1 |
| 2 | 미션 선택 (남극 지도, A/D 잠금) | 10 | 0:27 | - | 1 |
| 3 | 착륙과 HUD | 10 | 0:37 | S3 | 1 |
| 4 | 에어록 점검과 산소 | 12 | 0:49 | 4a, 4b | 1 |
| 5 | 태양광 패널 | 8 | 0:57 | 5a, 5b | 1 |
| 6 | 건설 비용 프롬프트와 건물 정보 카드 | 10 | 1:07 | 6a, 6b, 6c | 1 |
| 7 | 그린하우스 솟아오름과 식량 | 12 | 1:19 | 7b, 7c (7a 대체, 7r 재촬영) | 1 |
| 8 | 자율주행 로버와 콘솔 지도 | 18 | 1:37 | 8a, (8c), 8d | 1 (솔로 전용) |
| 9 | 직접 운전, 배터리, 충전 | 14 | 1:51 | 9a ~ 9e | 1 (멀티 장면이지만 솔로 가능) |
| 10 | SEP: 15초 경보와 대피 | 14 | 2:05 | 10a, 10b | 1 |
| 11 | GST: 지도 끊김 | 10 | 2:15 | 11a, 11c (11b 선택) | 1 |
| 12 | 관제사 핀 화살표와 역할 미션 (선택) | 14 | 2:29 | 12a ~ 12e | 2 이상 |
| 13 | 메달 결과 화면, 점수, 순위 | 12 | 2:41 | 13a, 13b (13c 대체) | 1 |
| 14 | EN / KR 전환 | 6 | 2:47 | 14 ko, 14 en | 1 |
| 15 | 클로징 | 6 | 2:53 | - | 1 |

## 4. 장면별 상세

참고 걷기 거리(V2_PLAN 16절 표시 좌표 기준 수평 거리, 걷기 속도 16 stud/s. 기지를 다시 옮겼다면 달라진다): 스폰 -> 에어록 약 63 stud(4초), 에어록 -> 착륙선 약 56(3.5초), 에어록 -> 태양광 필드 약 69(4.5초), 태양광 필드 -> 그린하우스 자리 약 57(3.5초), 에어록 -> 로버 주차장 약 80(5초), 착륙선 -> 로버 주차장 약 90(5.5초). 걷기를 줄이려면 `stand("...")`로 자리에 세운다.

### 장면 0. 오프닝 (7초)
- 화면: 타이틀 화면(배지 "Moon South Pole Mission", 제목 The Frontier, 부제 "Build a Moon base and keep your crew safe for 60 days."). 챌린지 이름 자막 "Build a Junior Astronaut Mission Trainer" (편집에서 얹기).
- 플레이어: 아직 Start를 누르지 않는다.
- EN: "Every Moon choice has a cost. This is The Frontier: our Junior Astronaut Mission Trainer."
- KR: "달에서는 모든 선택에 대가가 따라요. 우리가 만든 주니어 우주비행사 미션 트레이너, The Frontier예요."
- 사전 명령: `S0` (다음 판 구간 고정과 저장 상태 출력. 출력의 records가 "ok"면 장면 13 주의를 본다).

### 장면 1. 타이틀과 About the data (10초)
- 화면: 오른쪽 위 EN | KR 토글, 왼쪽 아래 칩 3개(Make Energy, Get Water from ice, Grow Food). "About the data" 버튼을 누르면 문단 7개가 뜬다: DONKI 설명, 지난 기록 재생("We play back past records. Nothing here is live."), 2024년 NASA 착륙 후보 지역, 얼음 후보지 5곳, LOLA 지형, 사실 카드 출처.
- 플레이어: "About the data" 클릭, 2~3초 읽게 두고 Close.
- EN: "Our space weather is real: NASA DONKI records of past solar storms, replayed in the game. The terrain comes from NASA LOLA laser height data."
- KR: "우주 날씨는 실제 NASA DONKI 기록이에요. 지난 태양 폭풍을 게임에서 다시 보여 줘요. 지형은 NASA LOLA 고도 자료로 만들었어요."
- 사전 명령: 없음.

### 장면 2. 미션 선택 (10초)
- 화면: 달 남극 지도에 기지 핀 A~D. C 식량 생산 기지(Nobile Rim 1)는 "Start here", B 발전 기지는 "Coming soon", A와 D는 "Not ready yet". 오른쪽에 이름, 착륙지, 한 줄 설명, 아래 "Start mission". 지도 아래 "This map is simplified. Places and distances are not exact."
- 플레이어: Start 클릭 -> B 핀 클릭(읽기만, "This base opens in a future update.") -> C 핀 클릭 -> "Start mission". 이 화면에 들어온 순간부터 30초 카운트다운이 돈다(MissionFlow.luau:1084-1091). 30초 안에 확정한다.
- EN: "Four bases, named after landing regions NASA announced in 2024. Today we play the Food Base."
- KR: "기지 네 곳의 이름은 NASA가 2024년에 발표한 착륙 후보 지역에서 따왔어요. 오늘은 식량 생산 기지를 해 봐요."
- 사전 명령: 없음. "Start mission"을 누른 직후 `S3`를 실행한다.

### 장면 3. 착륙과 HUD (10초)
- 화면: 착륙 카메라가 착륙선 위 200 stud에서 내려온다(5초, LandingCamera). 이어 HUD: 왼쪽 위 자원 칩 3개 Energy 40, Water 50, Food 37(막대 상한 100), 가운데 위 "Day 1 of 60", 미션 문구 "Check the Airlock so it can refill your Oxygen." 첫 착륙 때 사실 카드 "Artemis: back to the Moon to stay"와 Tip이 뜰 수 있다.
- 플레이어: 착륙 연출을 그대로 본 뒤 가만히 HUD가 보이게 둔다.
- EN: "We land with limited Energy, Water, and Food. Sixty days, three resources, and every choice has a cost."
- KR: "에너지, 물, 식량은 한정돼 있어요. 60일 동안 세 자원을 지켜야 하고, 모든 선택에는 대가가 있어요."
- 사전 명령: `S3` (playing이 되면 시계 정지).

### 장면 4. 에어록 점검과 산소 (12초)
- 화면: 에어록 패널 프롬프트 "Start check" 아래 비용 줄(비용 0, 2일). 산소 바가 밖에서 줄어든다. 20 이하에서 토스트 "Oxygen is low! Go inside or get in the rover." 점검이 끝나면 "Airlock is ready!" 뒤 에어록 안에 들어가면 산소가 초당 2씩 찬다.
- 플레이어: (4a가 에어록 패널 앞에 세우고 산소를 35로 낮춘다) 줄어드는 산소를 2~3초 보여 준 뒤 E를 1초 눌러 점검 시작 -> 리드가 4b -> 완료 뒤 에어록 안으로 걸어 들어가 산소가 차는 것을 보여 준다.
- EN: "Outdoors, your Oxygen drains in sixty seconds. Check the Airlock, and it refills your air."
- KR: "밖에서는 60초면 산소가 바닥나요. 에어록을 점검하면 산소를 다시 채울 수 있어요."
- 사전 명령: `4a`, 사용자가 점검을 시작한 뒤 `4b` (사용자가 E를 못 누르면 `4c`).
- 주의: 산소가 0이 되면 구조되어 점수 -100과 에어록 안으로 이동한다. 35에서 0까지 약 21초이니 서두른다.
- MCP 캡처 불가: 에어록 프롬프트, 산소 바 토스트.

### 장면 5. 태양광 패널 (8초)
- 화면: 태양광 필드 프롬프트 "Build solar panel"(에너지 4). E 3초 동안 설치, 패널이 땅에서 솟아오르고 토스트 "Solar panel built! (1 / 13)", 왼쪽 아래 건물 카드 "Solar Field ... Panels built: 1 / 13", HUD 에너지 칩이 4 줄어든다. 컷 전환 뒤 패널이 여러 장 깔린 필드.
- 플레이어: 패널 자리에서 E 3초 한 장. 이어 컷.
- EN: "Each solar panel costs Energy now, then makes Energy every day. Two a day, thirteen in all."
- KR: "태양광 패널은 에너지를 먼저 쓰지만 날마다 에너지를 만들어요. 하루 두 장, 모두 열세 장이에요."
- 사전 명령: `5a`, 컷 전환용 `5b` (8장).
- 숫자 근거: 비용 4, 장당 하루 2, 하루 최대 2장, 전체 13장(MissionConfig.luau:151-161).
- MCP 캡처 불가: 패널 프롬프트.

### 장면 6. 건설 비용 프롬프트와 건물 정보 카드 (10초)
- 화면 1: 그린하우스 자리에서 프롬프트 "Build Greenhouse"와 비용 줄(에너지 10, 물 5, 3일, 낼 수 있으면 평소 색). 왼쪽 아래 건물 카드(이름, 한 문장 설명 "Grows Food for the crew...", 상태, 하루 유지비).
- 화면 2: 에너지가 모자라면 숫자가 빨갛게(6b).
- 화면 3: 물 파이프 자리 프롬프트: 비용 에너지 60, 물 40, 5일, 해금 전이라 "Unload Water 5 times to unlock the Water Pipe (0 / 5)." (파이프는 해금 전에도 비용이 보인다, Interactions.luau 헤더 13-15)
- 플레이어: 자리 앞에서 가만히 프롬프트와 카드를 보여 준다(누르지 않는다).
- EN: "Before you press E, the prompt shows the cost: Energy, Water, and days. Every build is a trade-off."
- KR: "E를 누르기 전에 에너지, 물, 걸리는 날이 먼저 보여요. 모든 건설은 선택이에요."
- 사전 명령: `6a`, `6b`, `6c`.
- MCP 캡처 불가: 비용 줄이 있는 프롬프트 전부(`workspace:SetAttribute("DebugPrompts", true)`는 디버그용일 뿐 영상에는 쓰지 않는다).

### 장면 7. 그린하우스 솟아오름과 식량 (12초)
- 화면: 그린하우스가 3일 동안 1/3씩 땅에서 솟아오르고(하루 넘길 때마다), 마지막에 "Greenhouse is ready!". 이어 첫 수확 토스트 "Harvest time! +26 Food", 식량 칩이 뛰어오른다. 사실 카드 "Fresh food from a space garden"이 뜰 수 있다.
- 플레이어: 자리에서 E 1초(착공). 안에 서 있지 않는다. 완공 때 건물 안에 있으면 정면 바깥으로 옮겨진다(갇힘 방지).
- EN: "The Greenhouse rises over three days, then harvests twenty-six Food every five days. But it uses Energy and Water every day."
- KR: "그린하우스는 사흘 동안 지어지고, 5일마다 식량 26을 수확해요. 대신 날마다 에너지와 물을 써요."
- 사전 명령: 사용자가 E를 누르면 `7b`(3일을 3초 간격으로), 곧바로 `7c`(수확). 사용자가 못 누르면 `7a`. 재촬영은 `7r`로 지운다.
- 자막 권장: "time-lapse: days skipped".
- MCP 캡처 불가: 착공 프롬프트.

### 장면 8. 자율주행 로버와 콘솔 지도 (18초)
- 화면: 착륙선 안 콘솔 프롬프트 "Open console" -> "Lander Console" 지도 탭: 기지와 얼음 후보지 5곳(번호, 쿨타임). 후보지 4를 누르면 "Ice Site 4", "Ready", 거리 약 516 m, 카드 "Round trip: about 1 day / Energy cost 11 / Brings back 30 / Risk Low". "Hurry"를 켜면 에너지와 위험도가 오른다(1 / 16). "Send rover" -> 토스트 "Rover sent to Ice Site 4! Back in about 1 day. Energy -11". 로버가 기지 출구로 달려 사라지고 지도 아이콘이 이동, 사실 카드 "Rovers that drive themselves, and rovers we steer". 돌아오면 "The rover is back from Ice Site 4 with 30 Water!"
- 얼음 후보지별(BALANCE_LOG 8.6, 거리는 stud x 1.2524, 화면에서 한 번 확인): 4번 약 516 m, 1일, 에너지 11, 낮음 / 5번 약 527 m, 1일, 11, 낮음 / 1번 약 810 m, 2일, 17, 중간 / 3번 약 1,014 m, 2일, 21, 중간 / 2번 약 1,174 m, 3일, 25, 높음.
- 플레이어: 콘솔 E -> 지도에서 4번 클릭 -> (Hurry 한 번 켰다 끄기) -> Send rover -> 지도 아이콘 지켜보기.
- EN: "Playing alone, you send a self-driving rover from the console. See distance in meters, days, Energy, and risk before you go. Hurry is faster, but riskier."
- KR: "혼자 할 때는 콘솔에서 자율주행 로버를 보내요. 가기 전에 거리(미터), 걸리는 날, 에너지, 위험도를 확인해요. 서둘러 가면 빠르지만 더 위험해요."
- 사전 명령: `8a` (시계 켬, 콘솔 앞). 사용자가 UI로 보낸다(대체 `8b`). 하루 뒤쪽 절반에 보내서 귀환이 늦으면 `8c`. 컷으로 줄이려면 `8d`.
- 자막 권장: 귀환을 `8d`로 앞당겼다면 "time-lapse".

### 장면 9. 직접 운전, 배터리, 충전 (14초)
- 화면: 로버 "Get in" -> 운전. 오른쪽 위 배터리 칩("Battery N", 막대), Shift를 누르면 부스터(배터리가 빨리 준다, Tip "Hold Shift to boost"). 얼음 후보지에서 "Dig ice"(E 3초) 토스트 "Got ice at Ice Site 5! The rover carries 30 Water.", 물탱크에서 "Unload Water" 토스트 "You put 30 Water in the tank!". 주차장에 세우고 내리면 HUD 알약 "Charging"과 로버 위 표지, 기지 에너지가 20 이하면 "Not charging: base Energy is 20 or less".
- 플레이어: Get in -> W로 출발, Shift 부스터 2초 -> (컷: 9b로 얼음 옆) Dig ice -> (컷: 9c로 물탱크 옆) Unload -> 주차장으로 돌아와 Space로 내려 충전 표지.
- EN: "With a team, you drive. The battery drains, boost drains it faster, and charging spends base Energy."
- KR: "여럿이 할 때는 직접 운전해요. 배터리는 닳고, 부스터는 더 빨리 닳게 하고, 충전은 기지 에너지를 써요."
- 사전 명령: `9a`, `9b`, `9c`, 충전이 막힌 이유 컷 `9d`, 충전 컷 `9e`.
- 도우미: 배터리를 값으로 맞출 기존 함수가 없다(RoverFleet.luau:128 모듈 안 변수). 풀 배터리 50에서 초당 0.15(부스터 x2)라 짧은 컷에서는 변화가 작다. H1 `RoverFleet.debugSetBattery`가 있으면 `9a`가 32로 맞춘다. 없어도 촬영은 된다(부스터로 달려 줄이기).
- MCP 캡처 불가: 탑승, Dig ice, Unload 프롬프트.

### 장면 10. SEP: 15초 경보와 대피 (14초)
- 화면: 로버 주차장 근처에 서 있는데, 화면 가장자리가 붉게 깜빡이고 배너 "Solar storm coming! Get inside or into a rover."(15초). 15초 뒤 SEP 시작: 화면이 어두워지고 배너 "Solar Radiation Storm", "Solar storm! Stay inside.", 출처 "NASA DONKI record, February 24, 2023", "Solar storm: 2 days left". 토스트 "Solar storm! You were moved into the rover to stay safe."(빈 로버가 40 stud 안일 때, 아니면 에어록 안으로 이동). 에어록 문 프롬프트 "Locked (solar storm)". 사실 카드 "Fast particles from the Sun".
- 플레이어: 밖에 서서 경보를 맞고, 자동 대피를 본다. 문 앞에서 잠긴 프롬프트를 잠깐 보여 준다.
- EN: "From NASA DONKI, February 24, 2023: a solar radiation storm. Fifteen seconds of warning, then the crew shelters and the doors lock."
- KR: "NASA DONKI 기록, 2023년 2월 24일의 태양 방사선 폭풍이에요. 15초 경보 뒤 대원은 대피하고 문이 잠겨요."
- 사전 명령: `10a` (28일로 점프, 경보 즉시, 실제 15초 뒤 하루 넘김. 시계는 멈춘 채). 끝낼 때 `10b`(틱 2번, "The solar storm is over.").
- 자막 권장: 날짜 점프를 쓰므로 "time-lapse".
- MCP 캡처 불가: 문 잠김 프롬프트.

### 장면 11. GST: 지도 끊김 (10초)
- 화면: 배너 "Geomagnetic Storm"과 "Geomagnetic storm! Earth support is down: no map or GPS.", 출처 "NASA DONKI record, February 27, 2023", "Map back in 1 day". 콘솔 지도가 지직거리고 "Offline", 로버 보내기와 핀 버튼이 꺼진다. 사실 카드 "When Earth's magnetic bubble shakes". (선택 11b: 로버가 나가 있는 채로 맞으면 "Your rover lost its location data and stopped.")
- 플레이어: 콘솔 E로 열어 꺼진 지도를 2~3초 보여 준다.
- EN: "February 27, 2023: a geomagnetic storm. On Earth it disturbs GPS and radio, so in the game the map goes offline."
- KR: "2023년 2월 27일, 지자기 폭풍이에요. 지구에서는 GPS와 무선이 흔들려서, 게임에서는 지도가 끊겨요."
- 사전 명령: `11a` (31일로 점프 후 틱 1번 = 32일 GST). 끝낼 때 `11c`("Earth support is back."). 선택 `11b`는 시계를 켜는 변형(GST가 다음 진짜 하루 마감에 끝남).
- 순서: 장면 10을 `10b`까지 끝낸 뒤 이어서 찍는다.

### 장면 12. 관제사 핀 화살표와 역할 미션 (14초, 2명 필요, 선택)
- 준비: Studio Test 탭에서 2명(Local Server)으로 시작. 미션 확정 순간 인원으로 멀티가 정해진다(MissionFlow.luau:805-806). 확정 뒤 10초 역할 선택 화면("Pick your job": Mission Control, Explorer, Engineer 카드).
- 화면(탐사대원 창): HUD "Job Mission" 카드(예: "Unload Water into the Water Tank", 0/3, "Just for teamwork. It does not change your score."). 관제사가 핀을 찍으면 화면 가장자리에 민트 화살표와 "Ice Site 1  (거리) m"(내 캐릭터에서 목표까지 거리), 가까워지면 그 자리 위 마름모. 길잡이 미션 완료 토스트 "Job mission done! Your pins helped the team reach the ice sites."
- 화면(관제사 창): 콘솔 지도에서 "Pin this site".
- 플레이어: 관제사 창에서 콘솔 지도 핀 찍기(3초) -> 탐사대원 창으로 전환해 화살표 따라가기.
- EN: "With friends, one player is Mission Control. They pin an ice site, and the explorer follows the arrow. No chat needed. Job missions reward teamwork, not score."
- KR: "친구와 함께하면 한 명은 관제사예요. 지도에 핀을 찍으면 탐사대원 화면에 화살표가 떠요. 채팅이 없어도 돼요. 역할 미션은 점수가 아니라 팀워크를 위한 거예요."
- 사전 명령: 역할 선택 중에 `12a`, 플레이 시작 뒤 `12b`(핀), `12c`(탐사대원을 핀 근처로), `12d`(두 번째 핀으로 완료), 선택 `12e`(물 미션 3회를 바로 채움, 결과의 물 숫자도 오른다).
- 주의: 역할 미션은 점수와 메달에 영향이 없다. 두 창을 번갈아 녹화하거나 창 하나만 녹화한다.

### 장면 13. 메달 결과 화면 (12초)
- 화면: "MISSION COMPLETE", "Great job, crew!", 금메달, 지낸 날 34, 점수 950과 "Points lost" 목록("Energy was low for 3 days: -30", "Food was low for 2 days: -20"), "Space weather this game: Real NASA records from January 27, 2023 to March 27, 2023 / 3 solar radiation storms / 2 geomagnetic storms", "What we did together", 오른쪽에 미션 상위 5와 전체 상위 5("You" 줄), "Play again".
- 플레이어: 수경 재배 자리에서 E 1초(에너지 60, 물 40, 1일) -> 리드가 `13b`로 하루를 넘기면 금메달 조건 충족 즉시 결과 화면.
- EN: "Gold medal! The score starts at one thousand, and every day a resource runs low costs points. The weather shows which real NASA records this run replayed."
- KR: "금메달! 점수는 1000점에서 시작하고, 자원이 부족한 날마다 점수가 깎여요. 이번 판에 쓴 실제 NASA 기록도 보여 줘요."
- 사전 명령: `13a` (금메달 직전 상태, 수경 재배만 남김) -> 사용자가 착공 -> `13b` (대체 `13c`).
- 저장소 주의: 메달을 따면 MissionFlow가 순위 저장을 부른다(MissionFlow.luau:898-908). `S0` 출력의 records가 "ok"(DataStore 켜짐)면 연출 판이 진짜 순위에 올라가므로 `13a`가 스스로 멈춘다. 사용자 허락 뒤 `ALLOW_REAL_RECORD = true`로 바꾸거나 H3를 쓴다. "offline"이면 서버 메모리 순위만 쓴다.
- 점수와 감점 목록은 연출용이다(`13a`가 에너지 부족 3일, 식량 부족 2일을 넣는다. 0으로 바꾸면 "You lost no points. Amazing!"). 자막 권장: "time-lapse".

### 장면 14. EN / KR 전환 (6초)
- 화면: 오른쪽 아래 EN | KR 토글(Tips, Fact cards 옆)을 누르면 HUD, 미션 문구, 프롬프트, 토스트가 한국어로 바뀌고 다시 EN으로. 서버가 문장이 아니라 키만 보내서 같은 서버에서도 아이마다 다른 언어를 쓸 수 있다.
- 플레이어: 토글 KR -> 2초 -> EN. 결과 화면에서는 설정 패널이 숨겨지므로(SettingsUI는 플레이 중에만 보인다) 플레이 중에 따로 찍어 편집에서 끝에 붙인다.
- EN: "Switch between English and Korean any time, even in the same server."
- KR: "언제든 영어와 한국어를 바꿀 수 있어요. 같은 서버에서도 아이마다 다른 언어를 쓸 수 있어요."
- 사전 명령: 없음(사용자가 클릭). 대체로 `14 ko`, `14 en`(PlayerPrefs.setLanguage).

### 장면 15. 클로징 (6초)
- 화면: 장면 11 직후 기지 전경(패널, 그린하우스)을 천천히 도는 샷, 또는 결과 화면. 자막 "The Frontier  |  Team Sirius"(선택).
- EN: "Real NASA data. Real trade-offs. The Frontier: our Junior Astronaut Mission Trainer."
- KR: "실제 NASA 데이터, 진짜 선택의 대가. 우리의 주니어 우주비행사 미션 트레이너, The Frontier."
- 사전 명령: 없음.

## 5. 촬영 순서 (편집 순서와 다르다)

세션 A (솔로 한 판, 시계 정지, 날짜는 늘기만 한다)
1. Play 직후 `PROBE`, `S0` -> 장면 0, 1, 2 -> "Start mission" 직후 `S3` -> 장면 3.
2. 장면 4(`4a`, 점검 후 `4b`) -> 5(`5a`, `5b`) -> 6(`6a`, `6b`, `6c`) -> 7(착공 후 `7b`, `7c`).
3. 장면 14(HUD가 보이는 지금 토글을 찍는다).
4. 장면 8(`8a`) -> 9(`9a` ~ `9e`) -> 10(`10a`, `10b`) -> 11(`11a`, `11c`) -> 장면 15 기지 전경 샷.
5. 장면 13(`13a`, 착공, `13b`). 결과 화면 뒤 "Play again"(고른 사람만, 10초 뒤)으로 다음 판.

세션 B (2명, 별도 Play): 장면 12. 필요하면 장면 2를 두 창으로(두 번째 창은 "is picking a mission" 문구).

막혔을 때: `RESCUE`(문 열림, 시계 켜짐). 재촬영: 자원은 `setRes`, 패널은 `setPanels`, 그린하우스는 `7r`로 되돌린다.

## 6. 아직 Studio에서 확인하지 못한 것 (UNVERIFIED)

이 계획은 코드를 읽고, `scene_setup.luau`를 실제 Rules와 모의 서버로 돌려(상태 변화, 금메달, 점수 950, 날짜 2023-03-27, SEP 29~30일, GST 32일 Kp 7 확인) 검증했다. Roblox Studio 도구는 쓰지 않았다. 아래는 실제 Studio에서 확인해야 한다.
- execute_luau가 Main.server와 같은 모듈 인스턴스를 받는지(`PROBE`). 안 받으면 전체 계획이 막힌다.
- `stand(...)`로 세운 자리가 벽 안이나 허공이 아닌지(`away` 값으로 조정).
- `task.delay` 같은 예약 작업이 MCP 호출이 끝난 뒤에도 도는지(장면 10a의 15초 뒤 하루 넘김. 안 돌면 `10b` 전에 `advance(1)`을 직접 보낸다).
- SEP 대피가 로버에 태우는지(빈 로버 40 stud 안) 에어록으로 옮기는지는 로버 위치에 달렸다.
- 장면 9 `9b`, `9c`의 로버 순간 이동 뒤 운전석 탑승 상태가 유지되는지.
- 2인 Local Server 테스트에서 `Players:GetPlayers()` 순서가 1번 = 관제사로 맞는지(`12a`).
- 사실 카드와 Tip이 프롬프트 패널과 겹치는 프레임이 있는지(겹치면 설정에서 끈다).
- 장면 13의 점수 950, 지낸 날 34는 모의 결과다. 실제 화면 숫자를 한 번 확인하고 나레이션의 "one thousand"만 쓴다(950은 말하지 않아도 된다).
