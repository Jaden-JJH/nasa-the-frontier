# 효과음 카탈로그와 검증 기록

대상 파일: `src/shared/SoundIds.luau` (서버와 클라이언트 공유). 검증일 2026-10-18.

## 구성 방식

- 모든 효과음은 `SoundIds` 테이블의 키 하나가 용도 하나에 대응한다. 키 이름이 곧 용도다.
- 각 항목은 `spec(id, volume, pitchJitter, loop, note)` 형태다.
  - `id`: Roblox 오디오 에셋 id. 0이면 재생하지 않는다(무음).
  - `volume`: 0..1.
  - `pitchJitter`: 재생마다 PlaybackSpeed에 더하는 무작위 폭. 0이면 고정.
  - `loop`: 반복 재생 여부.
  - `note`: 필요한 소리에 대한 한글 설명.
- 키 묶음: 로버(rover_*), 물(ice_*, water_*), 에어락과 건물(airlock_*, interior_hum_loop), 건설(panel_*, build_*), 산소(oxygen_*), UI와 흐름(ui_click, mission_advance, notify_*, landing_thrust, win, lose).

## 정책

- 2022년 Roblox 오디오 개인정보 변경 이후, 경험(experience)은 자신이 소유한 오디오나 공개로 배포된 오디오만 재생할 수 있다.
- 따라서 이 프로젝트는 Roblox 무료 오디오 라이브러리(Creator Store 오디오)의 공개 음원만 쓴다.
- 직접 업로드한 오디오는 Studio에서 업로드해 심의를 통과해야 하고, 소유 계정이나 그룹이 해당 경험과 일치해야 한다. 일정상 이번에는 쓰지 않는다.
- 제작자 구분:
  - Roblox(id 1): 구형 라이브러리와 신형 UI 음원.
  - ProSoundEffects(id 7462895450): Roblox 오디오 라이브러리에 제공된 Pro Sound Effects 음원. 설명에 "Courtesy of Pro Sound Effects"로 표기된다. 제작자가 Roblox 계정은 아니므로, 공개 여부를 아래 방법으로 별도 확인했다.

## 검증 방법

1. 검색: `https://apis.roblox.com/toolbox-service/v1/marketplace/3?keyword=<검색어>&creatorTargetId=<1 또는 7462895450>&creatorType=1&limit=30` (비인증 curl 동작).
2. 상세: `https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=<id,...>`. 이름, 길이, 제작자, typeId(3이 오디오)를 확인했다.
3. 공개 여부: 비인증 요청 `https://assetdelivery.roblox.com/v2/assetId/<id>`. 공개 에셋은 200과 다운로드 위치를 주고, 비공개 에셋은 401(Authentication required)을 준다. 선택한 34개 모두 200이었다. 비공개로 확인된 예: id 131412978408311(검색 결과의 사용자 업로드, 401)은 쓰지 않았다.
4. 한계: 이 검증은 웹 API 기준이다. 실제 경험 안에서의 재생은 Studio에서 한 번 확인해야 한다. economy 엔드포인트는 이름과 제작자 조회만 확인했고 판단 근거로 쓰지 않았다.
5. 길이는 API가 정수 초로 반올림해 준 값이다(0은 1초 미만).

## 검증 표 (34개 전부 검증 완료)

| 키 | id | 이름 | 길이 | 제작자 | assetdelivery 비인증 응답 |
|---|---|---|---|---|---|
| rover_board | 9116642648 | Metal Hatch 2 (SFX) | 2s | ProSoundEffects | 200 |
| rover_exit | 9116643292 | Metal Hatch 10 (SFX) | 3s | ProSoundEffects | 200 |
| rover_engine_loop | 9125767745 | Pod Idle Or Cruising Medium Speed Constant T (SFX) | 18s | ProSoundEffects | 200 |
| rover_hit | 9116673678 | Metal Impact Heavy Clunking Hits Scraping 1 (SFX) | 1s | ProSoundEffects | 200 |
| rover_broken | 9118805558 | Sci Fi Alarm Buzzy Whining Klaxon 1 (SFX) | 7s | ProSoundEffects | 200 |
| rover_repair | 9118047105 | Ratchet Wrench Gear Winding 4 (SFX) | 10s | ProSoundEffects | 200 |
| rover_recover | 9114055470 | Descending Synth Burst Tonal Light Phasing 2 (SFX) | 3s | ProSoundEffects | 200 |
| rover_dock | 9113867249 | Computer Beeps And Tones Synth Hits Bright 2 (SFX) | 1s | ProSoundEffects | 200 |
| rover_charge_loop | 9114246115 | Electric Hum 15 (SFX) | 3s | ProSoundEffects | 200 |
| rover_charge_full | 9126073938 | Synth Sparkle Tone High Pitch Tone Burst Din (SFX) | 1s | ProSoundEffects | 200 |
| rover_battery_low | 9113085764 | Alarm Buzzer 5 (SFX) | 1s | ProSoundEffects | 200 |
| ice_mine_loop | 9117875538 | Power Drill 1 (SFX) | 4s | ProSoundEffects | 200 |
| ice_collected | 9114863539 | Ice Cubes Fall Dropping To Floor 5 (SFX) | 3s | ProSoundEffects | 200 |
| ice_depleted | 12222005 | glassbreak.wav | 2s | Roblox | 200 |
| water_unload | 9120577126 | Water Pour Plastic Bucket 7 (SFX) | 4s | ProSoundEffects | 200 |
| water_processing | 9120578114 | Water Pump 8 (SFX) | 3s | ProSoundEffects | 200 |
| airlock_open | 9125610263 | Hydraulic Hatch Vehicle Rear Open Click Whoo (SFX) | 4s | ProSoundEffects | 200 |
| airlock_close | 9116644054 | Metal Hatch Squeak Open Quickly Close 2 (SFX) | 2s | ProSoundEffects | 200 |
| interior_hum_loop | 9125446543 | Command Room Tone Deep Air Conditioning Hum  (SFX) | 18s | ProSoundEffects | 200 |
| panel_install | 9116320146 | Locking Wrench 3 (SFX) | 1s | ProSoundEffects | 200 |
| panel_unfold | 9118934517 | Servo Motor 11 (SFX) | 2s | Roblox | 200 |
| build_start | 9117882918 | Power Up Accelerating Motors 2 (SFX) | 4s | ProSoundEffects | 200 |
| build_loop | 9116639168 | Metal Hammering 1 (SFX) | 5s | ProSoundEffects | 200 |
| build_complete | 9116395179 | Magic Glows Soft Clusters Of Chiming Hits 6 (SFX) | 3s | ProSoundEffects | 200 |
| oxygen_breath_loop | 9113073789 | Air Regulator Scuba Tank 1 (SFX) | 3s | ProSoundEffects | 200 |
| oxygen_low_beep | 9113880475 | Computer Keyboard Beep 3 (SFX) | 0s | ProSoundEffects | 200 |
| oxygen_rescue | 9113056997 | Air Burst Scuba Gear 4 (SFX) | 3s | ProSoundEffects | 200 |
| ui_click | 15675059323 | Roblox_UI_Bright_Click | 0s | Roblox | 200 |
| mission_advance | 17208361335 | Roblox GUI - Notification High | 2s | Roblox | 200 |
| notify_warn | 17208353912 | Roblox GUI - Negative | 0s | Roblox | 200 |
| notify_good | 9114132512 | Door Chime 10 (SFX) | 5s | ProSoundEffects | 200 |
| landing_thrust | 12222095 | Rocket whoosh 01.wav | 6s | Roblox | 200 |
| win | 9125641025 | Magic Synth Stinger Glassine Multi Tone Burs (SFX) | 7s | ProSoundEffects | 200 |
| lose | 9119903219 | Synth Zap Tones Descending Throbby 3 (SFX) | 4s | ProSoundEffects | 200 |

후보(미검증): 없음. id 0으로 남은 키도 없다.

## 품질 메모 (Studio에서 들어보고 판단할 것)

- rover_engine_loop(18초), interior_hum_loop(18초): 루프 권장 길이(2~15초)보다 길지만 이름에 Constant, 지속음이 들어 있다. 이음매가 거슬리면 대체한다.
- rover_repair: 원본이 10초다. 4초 홀드 동안 재생하다가 끝나면 Stop 처리를 권장한다.
- rover_battery_low, oxygen_low_beep: 짧은 단발 비프다. 반복은 호출 쪽에서 처리한다.
- oxygen_low_beep(Computer Keyboard Beep 3)과 ui_click, notify_warn은 길이가 1초 미만이다.
- rover_recover는 텔레포트 전용 음원이 없어 Synth Burst Phasing 계열로 대체했다.
- build_complete와 win은 팡파르 음원이 없어 Magic 계열 스팅어로 대체했다.

## 음원 교체 방법

1. Studio Toolbox(도구상자)에서 Audio 탭을 연다. 필터에서 Creator를 Roblox 또는 Pro Sound Effects로 지정하고 아래 검색어로 찾는다. 에셋 우클릭, Copy Asset ID로 id를 얻는다.
2. `src/shared/SoundIds.luau`에서 해당 키의 첫 인자 숫자만 바꾼다. 키 이름과 구조는 건드리지 않는다.
3. id를 0으로 두면 무음이다.
4. 새 id는 위 검증 방법 3번의 assetdelivery 주소로 200이 나오는지 확인한 뒤 이 표를 갱신한다.
5. 음량은 volume, 반복은 loop, 음높이 변화는 pitchJitter로 조정한다.
6. 포맷 확인: `stylua src/shared/SoundIds.luau; selene src/shared/SoundIds.luau`.

## 대체 음원 검색어 (Toolbox 오디오 탭)

- 로버: rover, electric motor, engine loop, hatch, hydraulic door, metal impact, crash, servo
- 수리와 건설: wrench, repair, ratchet, hammer, construction, power drill, unfold, power up
- 충전과 도크: charging, electric hum, dock, computer beep, chime
- 경고와 UI: alarm, klaxon, beep, buzzer, ui click, button, notification, negative
- 물과 얼음: ice crack, ice hammer, glass break, water pour, water pump, liquid, drill
- 에어락과 산소: airlock, pressurize, air burst, scuba, regulator, breathing, valve
- 흐름: rocket, thruster, whoosh, fanfare, stinger, victory, game over, descending tone, teleport, phasing
- 분위기: air conditioning hum, room tone, force field, spaceship interior
