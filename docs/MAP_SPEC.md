# 맵 명세 (MAP_SPEC)

이 문서는 디자이너가 Roblox Studio에서 맵을 그대로 만들 수 있도록 [CONTRACT.md](CONTRACT.md) 4절을 풀어 쓴 것입니다. 이름과 Attribute 가 한 글자라도 다르면 코드가 찾지 못하니, 아래 이름을 그대로 씁니다.

크기와 배치 값은 권장값입니다. 이름, 클래스, Attribute 는 필수이고, 크기와 배치는 맵 느낌에 맞게 조정해도 됩니다.

## 1. 전체 트리

아래 트리가 정답입니다. 들여쓰기 한 칸이 부모-자식 관계입니다.

```text
Workspace
  LandingPads (Folder)
    Pad1 (Part)                     Attributes: SiteName, Sunlight, IceDistanceLabel, HazardLabel, Description
    Pad2 (Part)                     (값은 아래 표 참고)
    Pad3 (Part)
    Pad4 (Part)
  IceSites (Folder)
    Ice1 (Part)
    Ice2 (Part)
    Ice3 (Part)
  (Base 는 시작할 때 없음. 코드가 선택한 패드 위에 만들어 줌)

ServerStorage
  BaseKit (Model)                   PrimaryPart = Origin
    Origin (Part)
    Lander (Model)
      SpawnPoint (Part)
      OxygenZone (Part)
    Rover (Model)                   PrimaryPart 설정 필요
      DriverSeat (VehicleSeat)      Attributes: Tank (number, 코드가 관리)
    SolarField (Model)
      InstallPad (Part)
      Slots (Folder)
        Slot1 (Part) ... Slot30 (Part)
    ModulePads (Folder)
      PadA (Model)
        Pad (Part)
        Ghost (Model)
        Built (Model)
        OxygenZone (Part)
      PadB (Model)
        Pad (Part)
        Ghost (Model)
        Built (Model)
      PadC (Model)
        Pad (Part)
        Ghost (Model)
        Built (Model)
    WaterTank (Part)
  PanelTemplate (Model)             태양광 패널 1장
```

## 2. 착륙 패드 (Workspace.LandingPads)

패드는 착륙지 4곳입니다. 플레이어가 고른 패드 위에 기지 키트(BaseKit)가 복제되어 올라갑니다.

공통 사항은 다음과 같습니다.

- 클래스: Part
- 이름: `Pad1`, `Pad2`, `Pad3`, `Pad4` (숫자는 SITES 의 id 와 같습니다)
- Anchored: 체크 (움직이지 않는 땅이므로)
- 크기 (권장): 기지 키트 전체가 올라갈 만큼 넓고 얇은 판. 예를 들어 약 80 x 1 x 80 스터드
- 배치: 맵 안에서 서로 떨어진 곳에 둡니다. 패드 윗면 중앙이 기지의 기준점이 됩니다.

각 패드에 아래 Attribute 다섯 개를 넣습니다. 타입을 꼭 확인하세요.

| Attribute | 타입 | Pad1 | Pad2 | Pad3 | Pad4 |
| --- | --- | --- | --- | --- | --- |
| SiteName | string | Shackleton Rim | de Gerlache Ridge | Malapert Massif | Nobile Crater |
| Sunlight | number | 1.00 | 0.85 | 0.70 | 0.60 |
| IceDistanceLabel | string | 멀다 | 중간 | 가깝다 | 매우 가깝다 |
| HazardLabel | string | 낮음 | 중간 | 중간 | 높음 |
| Description | string | 전력은 넉넉하지만 얼음까지 길이 멀다 | 모든 면에서 균형 잡힌 후보지 | 물은 가깝지만 발전이 느리다 | 얼음이 코앞이지만 지형이 험하다 |

Sunlight 값은 숫자입니다. `"1.00"` 처럼 따옴표를 붙여 문자열로 넣으면 안 됩니다.

배치 힌트는 다음과 같습니다.

- Pad1 에서 가장 가까운 얼음(Ice)까지 거리: 약 450 스터드
- Pad2 에서 가장 가까운 얼음까지 거리: 약 300 스터드
- Pad3 에서 가장 가까운 얼음까지 거리: 약 180 스터드
- Pad4 에서 가장 가까운 얼음까지 거리: 약 100 스터드
- Pad4 주변에는 바위를 많이 배치합니다. 지형 위험이 "높음" 이기 때문입니다.

## 3. 얼음 지점 (Workspace.IceSites)

얼음 지점은 로버가 물을 채우러 가는 곳입니다. 고정 3곳이고, 고갈되지 않습니다.

- 클래스: Part
- 이름: `Ice1`, `Ice2`, `Ice3`
- Anchored: 체크
- 크기 (권장): 약 8 x 2 x 8 스터드
- 색: 밝은 하늘색 계열로 칠하면 찾기 쉽습니다.
- 배치: 위의 거리 힌트를 지키도록 패드와의 거리를 맞춥니다. 로버가 150 스터드 안에 들어오면 레이더에 반응합니다.

얼음 지점의 프롬프트(E 홀드)는 코드가 붙입니다. 디자이너가 만들 필요는 없습니다.

## 4. 기지 키트 (ServerStorage.BaseKit)

BaseKit 은 기지 전체를 담은 Model 하나입니다. 코드가 이 Model 을 복제해서 선택한 패드 위에 놓습니다.

- 클래스: Model
- 이름: `BaseKit`
- PrimaryPart: `Origin`
- 위치: ServerStorage 안에 둡니다. Workspace 에 두면 게임 시작 때 기지가 보여서 안 됩니다.

### 4-1. Origin

- 클래스: Part
- 이름: `Origin`
- 역할: 기지의 기준점입니다. 패드 중심에 맞춰 PivotTo 로 옮겨집니다.
- 배치: 나머지 기지 부품은 모두 Origin 을 기준으로 배치합니다.

### 4-2. Lander (착륙선)

- 클래스: Model
- 이름: `Lander`
- 크기 (권장): 약 14 x 12 x 14 스터드
- 안에 두 가지를 넣습니다.
  - `SpawnPoint` (Part): 플레이어가 태어나는 위치입니다. 착륙선 앞쪽 바닥에 둡니다. Anchored 체크.
  - `OxygenZone` (Part): 아래 5절을 보세요.

### 4-3. Rover (로버)

- 클래스: Model
- 이름: `Rover`
- PrimaryPart: 로버 본체 Part 중 하나를 지정합니다. 이 설정이 없으면 코드가 로버를 옮길 수 없습니다.
- 크기: 플레이어가 탈 수 있을 만큼의 차량 크기입니다.
- 안에 `DriverSeat` 가 반드시 있어야 합니다.
  - 클래스: VehicleSeat
  - 이름: `DriverSeat` (정확히 이 이름)
  - Attribute `Tank` (number): 로버 물탱크 양입니다. 값은 코드가 관리하므로 디자이너가 넣을 필요는 없습니다.

로버 모델을 무료 에셋으로 가져왔다면 시트를 VehicleSeat 로 바꾸고 이름을 `DriverSeat` 로 바꿉니다. 자세한 방법은 [ASSETS.md](ASSETS.md) 를 보세요.

### 4-4. SolarField (태양광 필드)

- 클래스: Model
- 이름: `SolarField`
- 역할: 패널을 설치할 격자 영역입니다.
- `InstallPad` (Part): 플레이어가 E 를 2초 누르면 패널이 설치되는 자리입니다. 프롬프트는 코드가 붙입니다. 필드 입구 근처에 둡니다.
- `Slots` (Folder): 패널이 놓일 자리 30개가 들어 있습니다.
  - 클래스: Part
  - 이름: `Slot1` 부터 `Slot30` 까지 번호를 빠짐없이 붙입니다.
  - 배치: 5 x 6 격자 (5열, 6행)로 나란히 놓습니다.
  - 크기: 패널 한 장이 들어갈 크기로 맞춥니다. 이 크기가 `PanelTemplate` 의 기준입니다.

### 4-5. ModulePads (건설 패드 3개)

건설 위치가 3곳입니다. 이름은 `PadA`, `PadB`, `PadC` 입니다. 순서는 A, B, C 이지만 배치는 자유입니다.

각 PadX 는 Model 이고, 아래 네 가지를 가집니다.

| 이름 | 클래스 | 설명 |
| --- | --- | --- |
| Pad | Part | 플레이어가 E 를 눌러 건설을 시작하는 자리입니다. 프롬프트는 코드가 붙입니다. Anchored 체크. |
| Ghost | Model | 건설 중에 보이는 반투명 미리보기입니다. 완공 모양과 같게 만들고, 투명도(Transparency)는 0.7 로 둡니다. |
| Built | Model | 완공된 모습입니다. 완공 모양으로 만들어 PadX 안에 넣습니다. 완공 전에는 코드가 숨깁니다. |
| OxygenZone | Part | PadA 에만 있습니다. 아래 5절을 보세요. |

Ghost 와 Built 의 차이를 정리하면 다음과 같습니다.

- 건설 중에는 Ghost 가 반투명하게 보입니다.
- 건설이 끝나면 Built 가 불투명하게 나타납니다.
- Ghost 와 Built 의 모양은 같아야 전환될 때 어색하지 않습니다.

각 PadX 의 Pad 크기는 해당 건물 바닥에 맞춥니다. 예를 들어 약 12 x 1 x 12 스터드입니다.

### 4-6. WaterTank (기지 물탱크)

- 클래스: Part
- 이름: `WaterTank`
- Anchored: 체크
- 역할: 로버가 가져온 물을 기지 물로 옮기는 곳입니다. 프롬프트는 코드가 붙입니다.
- 배치: 기지 안에서 접근하기 쉬운 곳에 둡니다. 로버가 바로 닿는 위치가 좋습니다.

## 5. 산소 구역 (OxygenZone)

OxygenZone 은 플레이어가 "실내"에 있다고 판단하는 보이지 않는 영역입니다.

- 클래스: Part
- 이름: `OxygenZone` (두 곳 모두 같은 이름)
- CanCollide: 체크 해제 (플레이어가 부딪히지 않게)
- Transparency: 1 (보이지 않게)
- 위치: 두 곳입니다.
  - `BaseKit.Lander.OxygenZone`: 착륙선 내부를 덮습니다. 착륙선 크기보다 약간 크게 두어 안쪽 전체가 들어가게 합니다.
  - `BaseKit.ModulePads.PadA.OxygenZone`: Habitat A 내부를 덮습니다. 건물 안쪽 공간을 채우도록 맞춥니다.

로버 안에서도 산소가 회복되지만, 그 판정은 DriverSeat 에 앉았는지로 하므로 로버에는 OxygenZone 을 두지 않아도 됩니다.

## 6. 패널 원본 (ServerStorage.PanelTemplate)

- 클래스: Model
- 이름: `PanelTemplate`
- 위치: ServerStorage 안에 둡니다.
- 크기: `SolarField.Slots` 의 한 칸 크기와 같게 맞춥니다.
- 역할: 패널을 설치할 때 코드가 이 Model 을 복제해서 빈 슬롯 위에 놓습니다. 원본 자체는 게임 안에 보이지 않아야 하므로 ServerStorage 에 둡니다.

## 7. 체크리스트

맵을 넘기기 전에 아래 항목을 하나씩 확인하세요.

- [ ] 이름 오타가 없는지 확인했습니다. (대소문자까지 정확히. `Pad1` 과 `pad1` 은 다릅니다)
- [ ] 패드 4곳의 Attribute 다섯 개가 모두 있고, 값이 표와 같습니다.
- [ ] Attribute 타입을 확인했습니다. Sunlight 는 number, 나머지 네 개는 string 입니다.
- [ ] Anchored 를 확인했습니다. 패드, 얼음 지점, 슬롯, 건물 부품 등 움직이지 않는 것은 Anchored 입니다. 로버는 움직여야 하므로 Anchored 를 끕니다.
- [ ] BaseKit 과 PanelTemplate 은 ServerStorage 안에 있습니다. Workspace 에 있으면 안 됩니다.
- [ ] BaseKit 의 PrimaryPart 가 `Origin` 으로 설정되어 있습니다.
- [ ] 로버의 PrimaryPart 가 설정되어 있고, `DriverSeat` 가 VehicleSeat 로 들어 있습니다.
- [ ] 패널 슬롯은 `Slot1` 부터 `Slot30` 까지 있습니다.
- [ ] Ghost 의 투명도는 0.7 입니다.
- [ ] 두 곳의 OxygenZone 은 CanCollide 가 꺼져 있고 Transparency 가 1 입니다.
- [ ] 무료 모델을 가져왔다면 [ASSETS.md](ASSETS.md) 의 안전 점검을 마쳤습니다.
- [ ] 맵을 Play 해서 Output 창에 빨간 오류가 없는지 확인했습니다.
