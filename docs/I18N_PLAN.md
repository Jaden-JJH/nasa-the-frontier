# The Frontier v2 다국어 계획 (2026-11-14)

게임 기본 언어는 영어, 한국어를 함께 제공한다. 이 문서는 v1 코드 전수 조사(서브에이전트 3명, 서로 다른 방법)와 교차 확인 결과를 바탕으로 v2의 다국어 구조를 정한다. 문구 목록은 `docs/i18n/v1_strings_inventory.csv`.

## 1. 확정한 결정 (grill, 2026-11-14)
- 한 게임 안에서 언어를 바꾼다. 게임을 KR, EN 두 개로 나누지 않는다.
- 기본은 모두 EN. 타이틀 화면과 설정에서 KR로 바꾸고, 선택은 플레이어별로 DataStore에 기억한다.
- 같은 서버에서 플레이어마다 다른 언어가 가능해야 한다. 그래서 서버는 문장을 만들지 않고 키와 값만 보낸다.
- 문구는 CSV 하나(`key,en,ko`)에만 둔다. Mahi의 PlayCanvas 웹판도 같은 CSV(생성된 JSON)를 쓴다.
- v1 라이브 게임에는 백포트하지 않는다. v2에서만 도입한다.

## 2. 조사 결과 요약
- 방법: A 문자열 기계 스캔(리터럴 2,567개, 한글 428개), B 화면 요소에서 거꾸로 추적(표면 77곳), C 서버에서 화면까지 데이터 흐름과 계약 변경점.
- 교차 확인: 서로 다른 문구 610개, 셋 다 찾은 것 421개. 한 명만 찾은 보이는 문구 59개는 하나씩 확인했고, 대부분 전송 지점이나 플레이어 이름 같은 비번역 값이었다. 실제 화면 문구 중 빠진 것은 없었다. 판정이 갈린 30여 개는 안 쓰는 문구(2배속 버튼, 참조 없는 Config 키)였다.
- 보이는 문구 약 370~395개. v2 기준 재사용 약 155, 교체 약 140~190, 미정 약 25~85(조사자마다 기준이 조금 다름).
- 정리할 것: 안 쓰는 Config 키 13개(`TEXTS.airlock`, `recordRank`, `crew*` 7개, `label*` 4개), 테스트 전용 3개, 의미 중복 28행("가동 중", "대기 중", "충전 중", "외벽 손상"이 여러 곳에 따로 있음).

## 3. 지금 구조에서 깨지는 곳
1. 서버가 한국어 문장을 완성해 모두에게 보낸다: `StateUpdate.missionText`, `stallReason`, `modules[].upkeepText`, `event.text/eduText`, `siteName`, `Notify(text)`(호출 47곳), `GameOver.reason`, `SiteSelectionOpen`, `Records.site`(DataStore에 문자열로 저장).
2. Remote가 아니라 Instance 속성으로 새는 글자: ProximityPrompt `ObjectText/ActionText`(서버가 씀, 일부는 매초 갱신), 서버가 만든 SurfaceGui(제어반, AIRLOCK 표지), 패드 Attribute(SiteName, Description 등).
3. 한국어가 로직 키로 쓰인다: `hazardLabel == "높음"`, `siteHazardDetail["낮음"]`.
4. 영어 서식 위험: 조사가 변수에 붙은 문장 32개, 복수형 필요 35개, 조각 이어붙이기 34개, 키 이름이 문장에 박힘 20개("E를 길게"), 숫자가 문구에 하드코딩 20개("배터리 3배"), 날짜가 한국 시간 M/D 고정.
5. 용어 불일치: 같은 자원이 Energy, 전력, 에너지로 섞여 있다. 영어가 한국어 문장 안에 섞인 곳도 있다.
6. 테스트 약 70곳이 한국어 문구를 직접 비교한다.
7. 영어가 길어 넘칠 곳 약 25개: 프롬프트(폭 138px), 표지판 배지(110x26px), 경고 배너(높이 36px), 제어반(3 x 1.9 stud), 착륙지 상세 라벨. TextScaled는 한 곳뿐.

## 4. v2 구조
### 4.1 원칙
- 서버와 shared 규칙(Simulation, Ranking)은 언어를 모른다. 출력은 `Msg`(키 + 값), 숫자, 열거형 id뿐이다.
- 번역은 클라이언트의 해석기 하나(`Localizer`)만 한다. 웹은 같은 규칙의 JS 해석기를 쓴다.
- 플레이어 이름은 번역하지 않는 값으로 그대로 넣는다.
- 코드에는 화면 문장을 두지 않는다(로그 제외). lint로 막는다.

### 4.2 키 이름
- 형식 `domain.area.name`, 소문자, 숫자, 밑줄, 점. 위치가 아니라 의미로 짓는다(`hud.water.label`).
- 도메인: `hud`, `mission`, `toast`, `banner`, `prompt.obj`, `prompt.act`, `panel`, `sign`, `map`, `role`, `tip`, `fact`, `result`, `score`, `medal`, `record`, `title`, `settings`, `mission_select`, `event`, `end`, `facility`, 공용 `res.*`(자원 용어), `unit.*`, `key.*`, `date.*`, `fmt.*`.
- 의미가 바뀌면 키를 새로 만든다. 동적 키는 리터럴 키 테이블 조회만 허용한다.

### 4.3 CSV와 빌드
- `i18n/strings.csv`, UTF-8, 앞 세 열 `key,en,ko` 고정. 선택 열 `args`, `note`(번역 맥락, 대상 7~12세), `max_len`.
- 셀 안 줄바꿈은 두 글자 `\n`.
- `tools/i18n/build.luau`(Lune) 하나로 `src/shared/Strings.luau`(생성물, 커밋)와 웹용 `i18n/strings.json`을 만든다. CI는 `--check`로 CSV와 생성물 불일치를 막는다.
- 빌드 검사(실패): 키 형식, 중복, en 비어 있음, 언어 간 자리표시자 불일치, 복수형 `.other` 누락, 중괄호 짝, 금지 문자. 경고: ko 누락, 한국어 조사가 자리표시자 바로 뒤에 붙음, `max_len` 초과.
- 소스 검사: 코드의 리터럴 키가 CSV에 없으면 실패, CSV에만 있는 키는 경고, `src/server`와 `src/shared`의 한국어 리터럴은 실패(로그 허용 목록 제외).

### 4.4 자리표시자, 복수형, 날짜, 단위
- `{name}` 이름형 자리표시자만 쓴다. `%d`, `%s`는 폐지. 리터럴 중괄호는 `{{ }}`. 어순을 언어마다 바꿀 수 있고 Luau와 JS 규칙이 같다. Luau와 JS 해석기는 같은 골든 테스트 파일(`i18n/golden.json`)로 결과가 같은지 검사한다.
- 복수형: `key.one`, `key.other`. en은 `count == 1`이면 one, ko는 항상 other.
- 날짜: 숫자(년, 월, 일)로 보내고 `fmt.date.long`(en `{month_name} {day}, {year}`, ko `{year}년 {month}월 {day}일`)으로 조립. 시간대는 UTC로 통일하고 v1의 한국 시간 고정은 폐지. DONKI 출처 표시("NASA DONKI record, Aug 12, 2024")가 이 경로를 쓴다.
- 단위와 자원 이름은 `unit.*`, `res.*` 키로 통일한다.
- 입력 키 안내는 `{key_interact}`, `{key_repair}`, `{key_boost}` 값으로 넣고, 장치별 라벨(E, R, Shift, 터치, 게임패드)은 클라이언트가 채운다. ko 문장은 "{key_interact} 키를"처럼 고정 명사를 붙여 조사 문제를 피한다.
- 굵게가 필요한 문장만 `.rich` 키로 `<b>`를 허용하고, 값은 이스케이프한다.

### 4.5 서버 송신
- `Msg = { key: string, args: { [string]: string | number | boolean | Msg }? }`. 번역해야 하는 값은 중첩 `Msg`로 넘긴다.
- `Notify(msg, kind)`, StateUpdate는 `mission: Msg`, `stalled`, 시설별 숫자 유지비, `event = { kind, stage, daysLeft, sourceDate }`, `missionId`. GameOver는 `reason: Msg`, `deductions: { Msg }`, `missionId`. RecordEntry는 `missionId`(표시 이름 문자열 저장 금지, `RECORDS.version` 2).
- 새 Remote `SetLanguage(code)`: 화이트리스트 en, ko, 초당 1회 제한. 서버 `PlayerPrefs`가 DataStore에서 읽어 `player:SetAttribute("Lang", code)`로 복제하고, 저장은 디바운스 후 나갈 때 flush.
- 프롬프트: 서버는 `ActionKey`, `ObjectKey`, `ActionArgs`(JSON) Attribute만 쓰고, PromptUI가 해석한다. 쿨다운은 `CooldownUntil` 시각 Attribute로 두어 매초 복제를 없앤다.
- 3D 제어반: 서버는 `ControlPanel` 파트에 상태 Attribute만 쓰고, 클라이언트 `PanelSurfaceUI`가 SurfaceGui를 로컬에서 그린다.
- 맵 Instance 이름과 Attribute에는 id, 숫자, 열거형만 둔다(디자이너 약속에 추가).

### 4.6 클라이언트 갱신
- `Localizer.get/set/changed/text(msg)`. 정적 라벨은 `Localizer.bind(label, msg)`로 등록해 언어를 바꾸면 다시 그린다. HUD, 결과, 미션 선택, Tip, 사실 카드는 마지막 상태를 캐시해 다시 그린다. 토스트(3초)는 다시 그리지 않는다.
- StateUpdate마다 해석하지 않고 키와 값이 같으면 건너뛴다.
- 영어 길이 대비: 넘칠 위험이 있는 라벨은 자동 크기(AutomaticSize)나 TextScaled 상한을 쓰고 `max_len` 경고를 둔다.

### 4.7 검토하고 쓰지 않는 것
- Roblox 내장 LocalizationService와 LocalizationTable: 웹판과 같은 CSV 규칙을 써야 하고, Lune 테스트와 shared 규칙에서 쓸 수 없으며, 언어 전환이 계정 언어에 묶여 "기본 EN, 게임 안 전환" 요구와 맞지 않는다.

## 5. 진행 순서
1. 도구: `i18n/strings.csv` 골격, `tools/i18n/build.luau`, lint. 용어 행(`res.*`, `unit.*`, `key.*`, `date.*`, `fmt.*`)부터.
2. shared `Msg`, `Loc`(해석기, 복수형, 폴백 en) 순수 모듈 + Lune 테스트 + 골든 테스트.
3. `PlayerPrefs`, `SetLanguage`, 클라이언트 `Localizer`와 `bind`, 타이틀과 설정의 EN/KR 토글.
4. CONTRACT 갱신(문서 먼저).
5. v2 새 모듈은 처음부터 키로 작성: 미션 선택, 착륙선 콘솔과 지도, 역할, 핀 화살표, 시설과 업그레이드, 파이프, 메달과 감점, DONKI 사건과 출처, 결과 화면.
6. 재사용 모듈 전환: Toast, Tip, 사실 카드, 설정, 프롬프트, 산소, 로버(배터리, 부스터, 파손, 복구), 결과 틀, 기록. v1 문구는 inventory CSV의 `suggest_key`를 참고해 옮긴다. 교체 모듈의 v1 문구는 번역하지 않는다.
7. 번역: C 기지 문구가 CSV에 모이면 번역 담당 2명이 나눠 번역하고 서로 교차 검수한다. 영어는 7~12세가 읽는 쉬운 단어와 짧은 문장, 교육 문장(사실 카드, DONKI 설명)은 사실 정확성까지 검수한다. 마지막에 리드가 전체를 읽고 확정한다.
8. QA: 언어 전환 매트릭스(HUD, 토스트, 프롬프트, 제어반, 결과, 미션 선택, Tip, 사실 카드), 두 플레이어가 다른 언어로 한 서버에서 플레이, 영어 레이아웃 점검.
9. 웹(Mahi): `strings.json`, JS 해석기, 골든 테스트 공유.

## 6. 아직 정할 것
1. 물 단위 표기: 영어에서 "W"는 Watt로 읽힌다. 후보: "L"(리터), 또는 아이콘 + 숫자.
2. 에너지 약어 "E"와 용어 통일(Energy 하나로).
3. 고유명사(Nobile Rim 1, Mons Mouton 등)와 시설 이름을 ko에서 음차할지 영어 그대로 둘지.
4. HUD의 영어 라벨(Energy, Day, MISSION COMPLETE 등)을 ko에서도 영어로 둘지.
5. AIRLOCK 같은 3D 표지를 언어 중립 영어 아트로 고정할지.
6. 지원이 만드는 랜딩, 로딩 화면 이미지 안 글자 처리(글자 없는 이미지 + 코드 텍스트 권장).
