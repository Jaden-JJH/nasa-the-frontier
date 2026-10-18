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

2026-10-18 2차 점검에서 일부 키의 id가 바뀌었다. 위 표의 해당 행은 문서 맨 아래 "2차 점검" 변경 표가 우선한다. 현재 id 0인 키는 없다.

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

## 2026-10-18 2차 점검

사용자 피드백(panel_install, panel_unfold가 띵 하는 완료음처럼 들림, boost 두 키 무음)에 따라 36개 키 전체를 다시 점검했다. 키 이름과 구조는 그대로이고 id, volume, note만 바꿨다.

### 검증 방법 (1차와 동일 + 음향 측정)

- 검색, 상세, 공개 여부는 위 "검증 방법" 1~3번을 그대로 썼다. 최종 파일의 id 36개 전부 비인증 assetdelivery 요청이 200이었다. 후보 선정은 ProSoundEffects 음원으로 한정했다.
- 이름과 길이만으로는 판단이 어려워 후보와 기존 음원을 공개 CDN 주소로 받아 ffmpeg로 분석했다(받은 파일은 실행하지 않고 데이터로만 읽음). 항목은 실제 길이, 평균과 최대 음량(dBFS), 시간대별 음량 곡선(앞 무음, 끝 페이드, 중간 끊김)이다.
- 이 분석으로 확인한 사실: 기존 panel_unfold(Servo Motor 11)는 서보음이 맞지만 최대 음량이 -20 dBFS로 매우 작아 거의 안 들린다. 기존 panel_install(Locking Wrench 3)은 0.6초 안에 끝나는 짧은 단발이다. 즉 이름은 기계음이지만 약하거나 짧아 완료음처럼 느껴질 수 있었다. 실제 청취 확인은 Studio에서 해야 한다.
- 한계: 두 톤 비프 판별은 주파수 분석(Goertzel)으로 했고, 소리의 질감은 귀로 확인하지 못했다.

### 변경 표 (id 교체 8개)

| 키 | 이전 id | 새 id | 에셋 이름 | 길이 | 제작자 | 검증 | 이유 |
|---|---|---|---|---|---|---|---|
| panel_install | 9116320146 | 9116727630 | Metal Latches 15 (SFX) | 1.5s | ProSoundEffects | 200 | 금속 래치 클릭. 최대 -6.5 dBFS로 기존(-8.6)과 비슷하지만 평균 음량이 -27 dB로 높고 0.4초 동안 울림이 남아 존재감이 있다. |
| panel_unfold | 9118934517 | 9118329245 | Robot Servo 6 (SFX) | 2.1s | ProSoundEffects | 200 | 일정한 서보 구동음. 기존 Servo Motor 11은 최대 -20 dBFS로 너무 작았다. 새 음원은 최대 -8.8 dBFS, 곡선이 평탄하다. 펼침 1.5초보다 0.6초 길어 끝을 호출 쪽에서 페이드아웃하면 된다. |
| rover_boost_loop | 0 | 9114253664 | Electric Motor Revs 1 (SFX) | 4.2s | ProSoundEffects | 200 | 전기 모터 고회전. 루프 후보 중 앞 0.1초, 끝 0.3초만 페이드이고 중간 음량이 -35 dB로 일정해 이음매가 가장 덜 거슬린다. |
| rover_boost_ready | 0 | 9113399643 | Beeps Short And Long Bursts 8 (SFX) | 1.3s | ProSoundEffects | 200 | 짧은 낮은 음(약 2.0 kHz) 뒤에 긴 높은 음(약 2.7 kHz)이 이어지는 두 톤 비프. 주파수 분석으로 두 음 구조를 확인했다. |
| rover_dock | 9113867249 | 9113561873 | Boxcar Latch 6 (SFX) | 1.6s | ProSoundEffects | 200 | 기존은 0.5초 컴퓨터 비프(UI 음)였다. 도크 결합은 금속 래치 소리가 맞다. 최대 -2.8 dBFS로 충분히 크다. |
| rover_broken | 9118805558 | 9118805673 | Sci Fi Alarm Buzzy Whining Klaxon 3 (SFX) | 2.5s | ProSoundEffects | 200 | 같은 클랙슨 계열의 짧은 버전. 기존은 6.9초라 단발 상한 4초를 넘었다. |
| rover_repair | 9118047105 | 9118047507 | Ratchet Wrench Gear Winding 1 (SFX) | 2.9s | ProSoundEffects | 200 | 같은 래칫 렌치 계열의 짧은 버전. 기존은 10.3초라 4초 홀드에 비해 너무 길었다. 4초 홀드는 호출 쪽에서 반복하거나 끝에 Stop 처리한다. |
| ice_mine_loop | 9117875538 | 9125883730 | Rock Scrape On Concrete Constant Dragging Dr (SFX) | 6.3s | ProSoundEffects | 200 | 기존 Power Drill 1은 중간 음량이 -45 dB로 매우 작고 앞 0.2초가 무음이라 루프 때 끊겼다. 새 음원은 앞 무음 0초, 중간 -28 dB로 일정한 긁는 소리라 "드릴 또는 긁는 소리" 요구에 맞는다. |

### 음량만 조정한 키

| 키 | 이전 | 새 값 | 이유 |
|---|---|---|---|
| ice_mine_loop | 0.6 | 0.45 | 루프 상한 0.45. 새 음원은 기존보다 훨씬 크므로 상한으로 충분하다. |
| mission_advance | 0.6 | 0.5 | UI 상한 0.5. |
| water_processing | 0.4 | 0.5 | 단발 하한 0.5. 원본이 -44 dB로 작은 편이다. |

### 점검했지만 유지한 키와 근거

| 키 | 현재 음원 | 유지 이유 |
|---|---|---|
| rover_engine_loop | 9125767745 (18s) | 15초 초과이지만 중간 음량이 -25 dB로 끝까지 일정하고 앞과 끝 음량이 같아 페이드 없는 지속음이다. 15초 이하 후보는 모두 끝이 페이드되어 이음매가 더 나빴다. |
| interior_hum_loop | 9125446543 (18s) | 위와 같다. 평탄도가 낮은 잡음형 허밍이고 앞과 끝 음량이 같다. 10초 안팎의 같은 계열은 끝이 -60 dB 이하로 사라졌다. |
| rover_charge_loop | 9114246115 (3.2s) | 중간이 일정한 전기 허밍이다. 같은 계열 Electric Hum 4는 0.3초마다 끊겨서 오히려 나쁘고, 끊김 없는 후보는 -34 dB 이하로 너무 작았다. 앞 0.5초가 무음이라 루프 때 약간 쉬는 구간이 생기는 것이 남은 약점이다. |
| build_loop | 9116639168 (4.9s) | 망치질 단발이 반복되는 음원이라 앞 무음 0.25초가 오히려 박자에 묻힌다. 기계음 요구에 맞다. |
| build_start | 9117882918 (3.5s) | 이름이 Power Up Accelerating Motors로 기계음이 맞다. 앞 0.5초가 거의 무음이라 반응이 약간 늦게 느껴질 수 있다. |
| water_unload | 9120577126 (3.9s) | Water Pour 계열로 액체 소리가 맞고 4초 이내다. 대체 후보(Plastic Water Jug Glugs 등)가 더 낫다는 근거가 없다. |
| water_processing | 9120578114 (3.4s) | 펌프 소리가 맞다. 펌프 계열이 전부 -40 dB대로 작아 대안이 없다. 음량만 올렸다. |
| airlock_open, airlock_close | 9125610263, 9116644054 | 유압 해치, 금속 해치로 이름과 용도가 맞다. |
| notify_good | 9114132512 (5.4s) | 문 차임이라 토스트에는 약간 어색하고 단발 4초를 넘지만 소리는 약 2초 안에 거의 사라진다(-35 dB 이하). 더 나은 완료 토스트 음원을 확신하지 못해 유지했다. Roblox GUI - Purchase(17208380755)나 Notification Low(17208372272)를 Studio에서 들어보고 바꿀 수 있다. |
| rover_charge_full | 9126073938 | 완료 차임이 의도된 용도라 UI 계열 음원이 맞다. |
| win, lose, build_complete, landing_thrust | 기존 | 요청에 따라 길이 상한 예외 대상이다. |
| 나머지(rover_board, rover_exit, rover_hit, rover_recover, rover_battery_low, ice_collected, ice_depleted, oxygen_*, ui_click, notify_warn) | 기존 | 이름과 길이가 노트에 부합하고 4초 이내이거나 루프 길이 기준에 맞는다. |

### 루프 이음매에 관한 메모

Roblox 라이브러리 음원은 대부분 앞뒤에 짧은 페이드나 무음이 있어 Sound.Looped만으로는 이음매가 약간 들릴 수 있다. 그럴 때는 Sound의 PlaybackRegion(PlaybackRegionsEnabled)으로 음원 중간의 일정한 구간만 반복하면 해결된다. 이는 코드 쪽 작업이라 이번 범위에서는 건드리지 않았다.

### 볼륨 점검 결과

루프는 0.2~0.45(interior 0.2, charge 0.3, build 0.3, breath 0.25, engine 0.35, boost 0.45, ice 0.45), 단발은 0.5~0.8, UI(ui_click, mission_advance, notify_warn, notify_good)는 0.5 이하로 모두 범위 안이다. 단 ui_click, notify_warn은 길이가 1초 미만이다.
