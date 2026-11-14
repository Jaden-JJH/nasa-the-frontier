# The Frontier v2 인수인계 (2026-11-14 약 17:40, 컨텍스트 압축 직전)

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
v2 라운드 3 코드 완료(2026-11-14 18:00). 에이전트 6명 모두 완료(대기). 전체 검사 통과, 커밋/푸시 뒤 Studio 시험 단계.

## 2. 서브에이전트 (이름으로 SendMessage 하면 이어서 일함)
| 이름 | 소유 파일 | 상태 |
|---|---|---|
| v2-rules | `src/shared/MissionConfig.luau`, `Rules.luau`, `tests/bot_v2.luau`, `rules.spec.luau`, `run_v2.luau` | 완료(대기). 테스트 45 |
| v2-i18n | `i18n/*`, `tools/i18n/*`, `src/shared/Msg.luau`, `Loc.luau`, `Strings.luau`(생성), `src/server/PlayerPrefs.luau`, `src/client/Localizer.luau`, `LanguageToggle.luau`, `tests/i18n.spec.luau`, `run_i18n.luau` | **CSV 유일한 관리자**, 대기. CSV 481행 |
| v2-world | `src/server/MissionWorld.luau`, `src/shared/WorldMath.luau`, `tests/world.spec.luau`, `world_smoke.luau`, `run_world.luau` | 완료(대기). 스모크 173 |
| v2-server | `src/server/*`(v2 모듈), `src/shared/Remotes.luau`, `RankingV2.luau`, `tests/server_smoke_v2.luau`, `ranking_v2.spec.luau`, **`tests/run.luau`** | 완료(대기). v2 서버 스모크 219 |
| v2-client | `src/client/*`, `src/shared/ClientMath.luau`, `tests/client.spec.luau`, `run_client.luau` | 완료(대기). 클라이언트 테스트 15. 키 11개는 기존 toast.* 키로 교체 |
| v2-facts | `docs/content/FACTS_V2.md` | 완료 |
- 모든 에이전트 규칙: 구독 계정만(API 키 금지), git add/commit/push 금지, 금지 문자 9종 금지, stylua는 자기 파일에만(전체는 `--check`).
- 2026-11-14 16:46 첫 계정이 구독 5시간 한도(18:20 초기화)에 걸려 사용자가 다른 계정(team 구독, `claude auth status`로 확인 완료)으로 로그인. 한도에 또 걸리면 API로 우회하지 말고 멈춘 지점을 알린다.
- 에이전트는 같은 보고를 SendMessage와 idle_notification으로 두 번 보낸다. 한 번만 처리.

## 3. 검사 상태 (2026-11-14 18:00 기준)
- **전부 통과**: `lune run tests/run.luau` 종료 코드 0(단위 288 = 기존 273 + Client 15, 월드 스모크 173, v2 서버 스모크 219, build --check, lint 누락 0). stylua 통과, selene 오류 0(v1 경고 1). 아래 17:35 기록은 이력.
- `lune run tests/run.luau`(서버 담당이 통합): 단위 273, 월드 스모크 173, v2 서버 스모크 219, `tools/i18n/build.luau --check` 통과. **`tools/i18n/lint.luau`만 실패 12건(모두 src/client의 키)** -> v2-client가 기존 키로 바꾸면 통과하고 CI 초록.
- v1 서버 스모크는 run.luau에서 뺐다(파일은 남음). v1 모듈 파일은 남아 있지만 부팅하지 않는다(Main.server가 v2 부팅).
- 검사 명령(저장소 루트, 각각): `export PATH="$HOME/.rokit/bin:$PATH"`; `stylua --check src tests`; `selene src tests`(v1 server_smoke 경고 1개는 정상); `lune run tests/run.luau`; `rm -rf build`.

## 4. 커밋 상태
- 마지막 커밋 `09c6ae8`(원격과 같음). 그 뒤 v2 코드, 문서, 에셋, 데이터가 전부 **미커밋**(`git status`로 확인).
- 화면 담당이 끝나고 전체 검사가 통과하면 커밋한다(에이전트 작업 중 커밋 금지: 레이스). 커밋 메시지는 영어 conventional, AI 표기 없음.
- 푸시: 사용자 pre-push 훅이 하루 3회 제한. **2026-11-14는 2회 사용, 1회 남음.** `--no-verify` 우회는 사용자에게 다시 물어야 한다.
- 저장소는 2026-11-14 사용자 요청으로 비공개 전환(Jaden-JJH/the-frontier). `v1-final` 태그 = `2d6307d`.
- `.gitignore`: `.env`, `*.rbxm`(그래서 `assets/models/KitImports_v1.rbxm`은 제외됨), `.omc/`.

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
- 직접 운전 충돌: 지형 포함 급정거 감지(0.25초 안 속도 12 이상에서 절반 아래) + RoverHazard 태그. Studio에서 오판 보정 필요.
- 얼음 후보지 이름은 모든 화면에서 "Ice Site N / 얼음 후보지 N"(중첩 Msg map.ice.label).
- 시설 이름: Greenhouse/그린하우스, LED Grow Lights/LED 조명, Nutrient System/영양분 관리, Hydroponics/수경 재배, Water Pipe/물 파이프. 관제사 역할 영어 "Mission Control". 영어 날짜는 "August 12, 2024".
- 사실 확인: 아르테미스 III는 2027년 저궤도 시험, 첫 착륙은 2028년 아르테미스 IV(NASA 2026-02-27 직접 확인) -> "2024년 NASA가 발표한 남극 착륙 후보 지역 9곳(원래 아르테미스 III용)". 얼음 = "탐사 후보지". GST = "지구 쪽 지원 시스템 장애". 지형 = 지원의 LOLA 데이터(PRESENTATION_BRIEF 3.7).
- 그린하우스 LED 바와 수경 베드는 해당 업그레이드 가동 때만 보임. 사실 카드 artemis는 첫 착륙 직후, 긴 카드는 약 14초 표시. Tip `tip.pause_to_save`는 첫 업그레이드 가동 직후.
- 웹판은 Mahi가 PlayCanvas로 만든다. 공유 파일: `i18n/strings.json`, `i18n/loc.js`, `i18n/golden.json`, `data/donki/windows.json`. 규칙 수치 공유용 `rules_v2.json` 생성 도구는 아직 없음(할 일).

## 7. 다음 할 일 (순서)
1. v2-client 최종 보고 받기 -> lint 0, `lune run tests/run.luau` 전체 통과(종료 코드 0), stylua/selene 확인을 리드가 직접 실행.
2. 계약 정리: v2-server와 v2-client가 보고한 계약 차이를 `CONTRACT_V2.md`에 반영(서버 차이 1~11은 승인됨: AirlockDoors/OxygenV2/ContributionsV2 신규, RoleUpdate 문자열 키, warning은 15초 경보 뒤, 추가 필드, Records 개인별, 원격 회수 겸용, 핀 규칙, RankingV2, 출구 40 stud 출발 등).
3. 커밋(여러 개로 나눠: feat(shared) 규칙과 설정, feat(i18n), feat(server), feat(client), feat(world), test, docs, assets/data) 후 푸시 1회(오늘 남은 1회).
4. Studio 시험: 리드가 `rojo serve`를 백그라운드로 켜고(저장소 루트, Rokit PATH) 사용자는 Studio Rojo 플러그인에서 Connect만 누름. 이후 MCP로 Play 시작/정지, Output 읽기(get_console_output), 화면 캡처.
   - 확인 목록: 부팅 로그와 오류, 미션 선택 지도(A/D 잠김), 착륙 연출, HUD(EN/KR 전환), 에어록 점검과 산소, 패널 설치, 그린하우스 착공과 솟아오름, 자율주행 파견과 지도 아이콘, SEP 15초 경보와 대피, GST 지도 지직거림, 핀 화살표, 걸어서 수리 흐름, 충돌 판정 오판, 결과 화면과 순위, 그린하우스 방향(FarmPad Yaw), 에어록 크기, 바닥 판 묻힘, DoubleSided 경고, Studio API 접근 없으면 기록 offline 표시.
   - 시험 결과로 BALANCE_LOG 7.6을 채우고 시작 식량(35~38) 등 미세 조정.
5. 번역 검수: 번역 담당 2명이 CSV(481행)를 나눠 교차 검수(7~12세 쉬운 영어, 사실 문구 정확성), 리드 최종 확인.
6. `rules_v2.json` 생성 도구(Mahi 공유, Q22).
7. B 발전 기지(V2_PLAN 5절, 15.7): 지원에게 MissionB 표시와 더 험한 지형 요청, 타워 3기와 수송망, 로버 2대.
8. 발표 자료 마무리(PRESENTATION_BRIEF의 [확인 필요] 남은 것: 비즈니스 모델(재은), 데모 영상), 정리 대상: v1 파일 삭제(B 전에), Figma Page 1 API 키 스크린샷 삭제 권고.

## 8. 사용자 작업 방식 (요약)
- 응답은 한국어, 짧게 결론 먼저. 큰 결정은 추천 답과 함께 하나씩 묻는다. 기술적인 세부는 리드가 정하고 알린다.
- 구현은 서브에이전트, 리드는 지시서, 검수, 문서, 커밋. 보고를 그대로 믿지 말고 검사를 직접 돌린다.
- 확인 안 된 UI 경로나 사실을 추측해서 말하지 않는다. 숫자와 사실은 실측, 공식 문서, 추정을 구분한다.
- 발표 소재가 될 과정(조사, 기준, 시뮬레이션, 의사결정)은 문서에 기록한다(BALANCE_LOG, PRESENTATION_BRIEF).
- 금지 문자 9종(em dash 등)은 파일과 응답 모두에서 쓰지 않는다.
