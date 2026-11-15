# The Frontier v2 인수인계 (최종 갱신 2026-11-15 약 03:00)

압축 뒤의 Claude가 이 문서 하나로 이어 갈 수 있게 쓴다. 결정 근거와 세부는 아래 문서에 있고, 이 문서는 "지금 어디까지 왔고 다음에 무엇을 하나"만 담는다.

## 0. 먼저 읽을 문서 (저장소 docs/)
| 문서 | 내용 |
|---|---|
| `V2_PLAN.md` | v2 계획. **15절 = grill 확정 결정 Q1~Q38**(본문보다 우선). 15.5, 15.11에 기지 이동, 에셋 기록 |
| `CONTRACT_V2.md` | 서버-클라이언트 계약(월드, 모듈, 프롬프트 Attribute, Remotes, 상태, 결과, 저장, 7.5 MissionWorld 연결 규칙) |
| `I18N_PLAN.md` | 다국어 구조(EN 기본, KR 전환, CSV key,en,ko, 서버는 키만 전송) |
| `BALANCE_LOG.md` | 밸런스 시뮬레이션 일지(발표 소재). 7.5.1 = 확정값 최종 결과 |
| `PRESENTATION_BRIEF.md` | 발표 PPT 7장용 근거(데이터, 결정, AI 사용, 사실 확인 결과) |
| `content/FACTS_V2.md` | 교육 사실 카드 17장(EN/KO, 출처), 발표 사실 확인 판정 |
| `meetings/meeting1~3.txt` | 2026-11-14 오전 회의 원문 |
| `HANDOFF.md` | v1 인수인계(이력 참고용, v1 다음 작업 후보는 폐기) |

## 1. 지금 상태 한 줄
- **2026-11-15 12:20 배포:** 사용자가 Studio File > Publish와 공개 설정을 마쳐 "[NASA] The Frontier"가 16세 이상 공개(Content May Vary). 아이콘과 썸네일 없음, 최대 인원 4 설정과 16세 미만 공개(Expand your audience)는 남음. 데모 영상 계획은 docs/video/(video-sonnet).
2026-11-15: 팀 플레이 테스트 피드백 8건(V2_PLAN 16절)을 모두 반영하고 Studio에서 확인 중. 기지를 중간 지점으로 옮기고 밸런스를 다시 맞췄다(BALANCE_LOG 8절). 남은 확인은 에어록 프롬프트 눈 확인(MCP 캡처는 PlayerGui의 BillboardGui를 못 찍음), 직접 운전 충돌 오판, 걸어서 수리, 멀티 역할 미션.

## 2. 서브에이전트 (이름으로 SendMessage 하면 이어서 일함, 2026-11-15 세션)
11-14 세션의 v2-* 에이전트 6명은 세션이 바뀌며 없어졌다. 11-15에 새로 띄운 4명(모두 완료, 대기):
| 이름 | 소유 파일 | 한 일 |
|---|---|---|
| fb-server | `src/server/*`(MissionWorld 포함), `src/shared/WorldMath.luau`, `Remotes.luau`, `tests/server_smoke_v2.luau`, `world_smoke.luau`, `world.spec.luau` | S1 비용 Attribute, S2 그린하우스 갇힘, S3 패널 충돌, S4 천장, S5 얼음 외형, S6 충전 상태, S7 역할 미션(`RoleMissions.luau`), S8 픽스처 이전, S9 에어록 DoorOffsetX와 길 검사, S10 배터리 버그, S11 얼음 번호, S12 덩어리 지면 맞춤 |
| fb-client | `src/client/*`, `src/shared/ClientMath.luau`, `tests/client.spec.luau`, `run_client.luau` | C1 비용 줄, C2 충전 표시(`RoverChargeSign`), C3 건물 카드(`BuildingInfoUI`), C4 역할 미션 화면(`ScoutMarkers`), C5 프롬프트 보호와 `DebugPrompts` 스위치, 얼음 번호 표시, Localizer TextArgs |
| fb-i18n | `i18n/*`, `tools/i18n/*`, `Strings.luau`, `Msg.luau`, `Loc.luau`, i18n 테스트 | **CSV 유일한 관리자.** info, 충전, 역할 미션 키 추가(CSV 522행) |
| fb-balance | `MissionConfig.luau`, `Rules.luau`, `bot_v2`, `rules.spec`, `run_v2`, BALANCE_LOG 8절 | 기지 이동 뒤 재조정 |
- 규칙(모두 같음): 구독 계정만(API 키 금지, 한도에 걸리면 멈춤), git 금지, 금지 문자 9종 금지, stylua는 자기 파일만, selene 경고 0.
- 에이전트끼리 서로 기다리다 멈추는 일이 두 번 있었다(키 이름을 다른 담당이 이미 바꿔 둔 경우). 담당이 "기다리는 중"이라고 하면 리드가 CSV나 코드를 직접 보고 정확한 이름을 알려 준다.

## 3. 검사 상태 (2026-11-15 03:00)
- `lune run tests/run.luau` 종료 코드 0: 단위 302(Client 포함), 월드 스모크 271, v2 서버 스모크 315, rules export --check, i18n build --check, lint 누락 0. stylua 통과, selene 오류 0 경고 0.
- 검사 명령(저장소 루트): `export PATH="$HOME/.rokit/bin:$PATH"`; `stylua --check src tests`; `selene src tests`(경고도 CI 실패); `lune run tests/run.luau`; `rm -rf build`.
- zsh 주의: `git show "${rev}:path"`처럼 중괄호를 쓴다(`$rev:s...`는 zsh 변형 기호로 해석됨).

## 4. 커밋 상태
- 저장소: **`Jaden-JJH/the-frontier-NSAC`(비공개)가 origin.** 옛 `Jaden-JJH/the-frontier`는 remote `legacy`(푸시하지 않음). 협업자(쓰기, 개인 저장소 최대 권한): jiwon-lab(수락), MuhtasimMahim, ryujaen(초대).
- 마지막 푸시 `cd82738`(2026-11-15). 2026-11-15 푸시 3회를 모두 썼다. 그 뒤 커밋은 다음 날 푸시하거나 사용자에게 `--no-verify` 허락을 다시 받는다.
- 커밋 메시지 영어 conventional, AI 표기 없음. 에이전트 작업 중에는 커밋하지 않는다.
- 팀원 테스트 방식: 팀원은 Team Create로 같은 플레이스를 열고 Play만 한다. Rojo Connect는 Jaden(리드)만(여러 명이 연결하면 옛 코드가 덮어쓸 수 있음).

## 5. Roblox 새 프로젝트
- 경험 `[NASA] The Frontier`, 소유 Jaden(user 11824484899), Universe 10776510720, Place 139751582320388(이름 11142026_1). Team Create에 지원 참여. Rojo 7.7.1 플러그인 설치됨.
- Roblox Studio MCP 연결됨. `list_roblox_studios`로 studio_id를 먼저 얻는다(세션마다 바뀜). execute_luau, screen_capture, open_cloud_invoke 사용 가능. Open Cloud 권한: asset 읽기/쓰기와 업로드 폴더 `the-frontier/assets/models` 허용됨, `universe.place:write`는 미허용(최대 인원 변경 실패).
- `Workspace.MissionC` 표시 13개(Lander, SpawnLocation, Airlock, SolarField, FarmPad, WaterTank, RoverPark, BaseExit, Ice1~5), 모두 Anchored. 기지는 얼음 쪽으로 옮김(원래 좌표는 V2_PLAN 15.5). 지형 2,044 stud = 실제 2.56 km(LOLA), 1 stud 약 1.25 m.
- `ServerStorage.Assets`: Greenhouse(88099979185265 rev2), WaterTank(99174776271901), Pipe(125305563695112), Kit(126313812422876, v1 키트 19개). `Workspace.AssetPreview`에 미리보기(실행 시 서버가 숨김). FarmPad, WaterTank 표시는 투명도 1(원래 값 Attribute OriginalTransparency).
- `Workspace.StreamingEnabled = true`(반경 1024). 클라이언트는 멀리 있는 인스턴스 대신 StateUpdate 좌표를 쓴다.
- 보류: Studio API 접근 켜기, 최대 인원 50 -> 4. **게임 설정 메뉴 위치를 추측해서 안내하지 말 것**(사용자 강한 지적, 메모리 feedback-no-guessing-ui-paths). 스크립트로 저장소 접근 여부를 확인하거나 MCP 권한 허용으로 처리.
- 원본 파일: 옛 플레이스 백업 `../thefrontier.rbxl`(스크립트 56개 = 저장소 v1과 동일 확인), 새 플레이스 백업 `../frontier_new.rbxl`.

## 6. 오늘 grill 뒤에 정한 것 (V2_PLAN 15절 이후, 문서 반영 위치)
- 기지를 얼음 쪽 평평한 자리로 평행 이동, BaseExit는 얼음 쪽으로(V2_PLAN 15.5). 자율주행 거리(출구 기준) 185/314/430/504/610, 직접 운전(주차 기준) 402/465/548/562/749.
- 화면 거리 단위는 미터(`metersPerStud = 2560/2044`), 내부는 stud.
- 정지 규칙: 우선순위 정지(LED, 영양분, 수경, 파이프, 에어록, 그린하우스 마지막) + 시설 유지비를 대원 에너지보다 먼저(대원 에너지 미납은 실패 아님, 에너지 감점과 경고 배너)(BALANCE_LOG 6.2).
- 밸런스 확정(사용자 "추천대로"): 시작 에너지 40, 물 50, **식량 37**, 패널 13장 x 2, LED/영양분 E35 W20, LED 유지 5, 파이프/수경 E60 W40, 자율주행 하루 에너지 12, 직접 운전 배터리 0.15/s, 부스터 x2, 충전 시 에너지 20 남김, 인원 비례 소비 끔. 결과는 BALANCE_LOG 7.5.1(솔로 처음 실패 28%, 2회차 20%, 2인 처음 32%, 4인 처음 10%, 모두 식량 실패). 사용자 목표는 "조금 쉽게" 조정 뒤 이 값.
- 걸어서 수리: 고친 대원을 로버 운전석에 태우고 직접 몰고 귀환(순간 이동 없음). 걷기 출발은 에어록, 한도 704 stud = 882 m.
- 직접 운전 충돌: CONTRACT 9.1 8번(2026-11-15 S13, 정면 가파른 벽이나 RoverHazard만, 기준 속도 15).
- 얼음 후보지 이름은 모든 화면에서 "Ice Site N / 얼음 후보지 N"(중첩 Msg map.ice.label).
- 시설 이름: Greenhouse/그린하우스, LED Grow Lights/LED 조명, Nutrient System/영양분 관리, Hydroponics/수경 재배, Water Pipe/물 파이프. 관제사 역할 영어 "Mission Control". 영어 날짜는 "August 12, 2024".
- 사실 확인: 아르테미스 III는 2027년 저궤도 시험, 첫 착륙은 2028년 아르테미스 IV(NASA 2026-02-27 직접 확인) -> "2024년 NASA가 발표한 남극 착륙 후보 지역 9곳(원래 아르테미스 III용)". 얼음 = "탐사 후보지". GST = "지구 쪽 지원 시스템 장애". 지형 = 지원의 LOLA 데이터(PRESENTATION_BRIEF 3.7).
- 그린하우스 LED 바와 수경 베드는 해당 업그레이드 가동 때만 보임. 사실 카드 artemis는 첫 착륙 직후, 긴 카드는 약 14초 표시. Tip `tip.pause_to_save`는 첫 업그레이드 가동 직후.
- 웹판은 Mahi가 PlayCanvas로 만든다. 공유 파일: `i18n/strings.json`, `i18n/loc.js`, `i18n/golden.json`, `data/donki/windows.json`. 규칙 수치 공유용 `data/rules_v2.json`은 `tools/rules/export.luau`가 만들고 run.luau가 `--check`로 검사(2026-11-15). MissionConfig를 바꾸면 export를 다시 돌린다.

## 7. 다음 할 일 (순서, 2026-11-15)
1. Studio 확인(사용자 허락: 수정되면 바로 Play 가능. 단 Play 시작 전 알리고, 사용자가 직접 할 때는 건드리지 않는다):
   - 에어록 프롬프트와 비용 줄은 사용자 눈으로 확인(MCP screen_capture는 PlayerGui 아래 BillboardGui를 찍지 못함, 빨간 시험 상자로 확인). 디버그는 서버에서 `workspace:SetAttribute("DebugPrompts", true)`.
   - 직접 운전 충돌 오판, 걸어서 수리 흐름, 주차 브레이크가 걸린 로버 타기, 충전 막힘 이유(에너지/판 밖), 멀티 역할 미션(2인 이상), 에어록이 동쪽(+X)을 보는 방향이 괜찮은지, 언어 전환.
   - 확인 완료: HUD, 배터리 칩, 건물 카드, 새 에어록 모델과 계단 해치 출입구, 가만히 둔 로버 배터리 유지, 얼음 70 stud 안 보임과 30 stud 이름표 "Ice Site N"과 덩어리.
   - 결과로 BALANCE_LOG 7.6을 채우고, 2인 처음 은메달(22 -> 16%) 조정 여부 판단(fb-balance 추천: 그대로 두고 실측 뒤).
2. 번역 검수(CSV 522행, 7 ~ 12세 쉬운 영어와 사실 문구, 리뷰 2명이 제안하고 fb-i18n이 반영).
3. (완료) `rules_v2.json` 생성 도구. Mahi에게 `data/rules_v2.json`, `data/README_rules.md` 전달.
4. B 발전 기지(V2_PLAN 5절, 15.7). `ServerStorage.Assets.SolarTower` 준비됨.
5. 발표 자료(PRESENTATION_BRIEF [확인 필요]: 비즈니스 모델, 데모 영상), v1 파일 삭제(B 전), Figma Page 1 API 키 스크린샷 삭제 권고. Studio API 접근과 최대 인원 4는 여전히 보류(메뉴 위치 추측 금지).
- 참고: 에셋 ID 203785492가 "Asset type does not match" 경고를 낸다(소리나 이미지 ID 종류 불일치로 추정, 아직 원인 미확인).

## 8. 사용자 작업 방식 (요약)
- 응답은 한국어, 짧게 결론 먼저. 큰 결정은 추천 답과 함께 하나씩 묻는다. 기술적인 세부는 리드가 정하고 알린다.
- 구현은 서브에이전트, 리드는 지시서, 검수, 문서, 커밋. 보고를 그대로 믿지 말고 검사를 직접 돌린다.
- 확인 안 된 UI 경로나 사실을 추측해서 말하지 않는다. 숫자와 사실은 실측, 공식 문서, 추정을 구분한다.
- 발표 소재가 될 과정(조사, 기준, 시뮬레이션, 의사결정)은 문서에 기록한다(BALANCE_LOG, PRESENTATION_BRIEF).
- 금지 문자 9종(em dash 등)은 파일과 응답 모두에서 쓰지 않는다.
