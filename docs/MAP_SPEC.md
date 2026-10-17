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

## 간편 경로: KitImports 폴더로 자동 조립

디자이너가 BaseKit 을 직접 만들지 않아도, 가져온 로우폴리 메시(예: Quaternius Ultimate Space Kit)를 정해진 이름으로 폴더에 넣으면 서버가 그레이박스 상자 대신 그 메시를 외형으로 써서 BaseKit, PanelTemplate, 바위를 만듭니다.

- 바뀌는 것은 외형뿐입니다. Origin, DriverSeat, 바퀴 힌지, SpawnPoint, OxygenZone, Pad, Ghost, Built, Attribute, 프롬프트 대상은 그레이박스와 이름과 구조가 똑같습니다.
- 크기는 코드가 맞춥니다. 메시를 역할별 목표 크기 안에 들어가게 균일하게 키우거나 줄이고, 바닥을 제자리에 맞춥니다.
- 없는 항목은 그레이박스로 만듭니다. 이름 오타, Model 이나 MeshPart 가 아닌 것, 파트가 없는 빈 모델은 Output 창에 경고 한 줄을 남기고 그레이박스로 대체합니다.
- 원본은 바꾸지 않습니다. 코드는 복제본만 씁니다.
- Play 를 누르면 서버가 `Workspace.KitImports` 폴더를 ServerStorage 로 옮겨서 플레이 중에는 보이지 않게 합니다. 이 이동은 플레이 세션 안에서만 일어나므로 Stop 하면 편집 화면의 폴더는 그대로 남습니다.

### 폴더 안 이름 목록

2026-10-17 기준으로 위 역할 이름 그대로 저장한 glTF 묶음이 준비되어 있습니다(원본 Quaternius Ultimate Space Kit, CC0, OpenGameArt 미러 GLB를 변환). 개발 Mac의 `~/Downloads/the-frontier-kit/` 폴더에 `Rover.gltf`, `Lander.gltf`, `HabitatA.gltf`, `HabitatB.gltf`, `HabitatC.gltf`, `Panel.gltf`, `Rock1.gltf`, `Rock2.gltf`, `Rock3.gltf`(각각 .bin과 _tex0.png 동반)와 `glb/` 단일 파일 버전, 미리보기 `preview_all_pieces.png`, 안내문 `README.txt`가 들어 있습니다. 파일 이름이 역할 이름이라 Import 3D로 가져오면 바로 표의 이름으로 들어옵니다.

| 이름 | 역할 | 권장 조각 |
|---|---|---|
| `Rover` | 로버 외형. 기존 물리 리그(섀시, 바퀴 4개, 힌지, DriverSeat) 위에 얹고 섀시에 용접합니다. 충돌은 리그가 맡습니다. DriverSeat 는 메시 윗면 중앙에 놓입니다. | 로버 두 종류 중 큰 것. 키트 파일 `Rover-WRd1piJOfh.glb` |
| `Lander` | 착륙선 외형. 산소 구역이 메시를 덮도록 자동으로 커집니다. SpawnPoint 와 로버 복구 콘솔은 그대로 생깁니다. | 착륙선 또는 로켓. 키트 파일 `Spaceship-u105mYHLHU.glb` (노란 셔틀형) |
| `HabitatA` | Habitat A 완공 모델(Built)과 고스트(Ghost, 같은 메시의 반투명 복제본). 산소 회복 구역이 건물을 덮습니다. | 튜브형 생활동 건물. 키트 파일 `House Long.glb` |
| `HabitatB` | Farm B 완공 모델과 고스트 | 검은 뚜껑 모양 재배 시설. 키트 파일 `Base Large.glb` |
| `HabitatC` | Research Lab C 완공 모델과 고스트 | 큰 돔. 키트 파일 `Geodesic Dome.glb` |
| `Panel` | 태양광 패널 원본(PanelTemplate). 슬롯 한 칸 크기에 맞춥니다. | 지면형 태양광 패널 1장. 키트 파일 `Solar Panel Ground.glb` |
| `Rock1`, `Rock2`, ... | 지형 바위. 번호 순서로 돌려 쓰고 크기는 0.7 ~ 1.4배 사이에서 무작위입니다. 바위 위치는 그레이박스와 같습니다. | 바위. 키트 파일 `Rock Large.glb`, `Rock Large-li0YBlBEMz.glb`, `Rock.glb` |
| `Planet` | 하늘의 거대한 행성(지구). 맵 원점에서 약 1500 studs, 고도각 약 25도, 지름 약 400 studs 에 놓이고 충돌과 판정이 없습니다. `Workspace.Decor.Planet` 이 이미 있으면 만들지 않습니다. | 행성. 키트 파일 `Planet-B7xd3SZq0z.glb` |
| `IceCrystal` | 얼음 지점 외형. 그레이박스가 만든 Ice1 ~ Ice3 Part 는 숨기고(프롬프트와 레이더 거리 기준은 Part 그대로) 결정 메시를 Part 보다 약간 좁게 얹습니다. 충돌은 메시가 맡습니다. | 청록 결정 덩어리. 키트 파일 `Bush-RfUP3gXj69.glb` |
| `WaterTank` | 기지 물탱크 외형(약 8 x 7 x 8 studs). WaterTank Part 는 숨기고 하역 프롬프트와 하역 거리 기준은 Part 그대로입니다. | 다리 달린 원통 돔. 키트 파일 `House Cylinder.glb` |
| `Connector` | 모듈 연결 통로. 두 모듈이 모두 완공되는 순간 A-B, B-C 사이에 굵기 약 4 studs 튜브 세그먼트를 길이 방향으로 이어 붙여 놓습니다(늘리지 않음). Base 아래에 생겨 재시작하면 함께 사라집니다. | 직선 튜브. 키트 파일 `Connector.glb` |
| `ConnectorElbow` | 꺾인 통로용 예약 이름. 지금은 직선 통로만 놓으므로 넣어도 쓰이지 않습니다(경고도 없음). | L자 튜브. 키트 파일 `Building L.glb` |
| `Pad` | 모듈 패드 3개와 패널 설치대 위의 링 장식. 패드 크기에 맞추고 대부분을 묻어 윗면만 살짝 보이게 해서 고스트와 겹치지 않습니다. 프롬프트 대상은 패드 Part 그대로입니다. | 납작한 링. 키트 파일 `House Single Support.glb` |
| `Antenna` | 착륙선 지붕 안테나와 로버 복구 콘솔 위 안테나(높이 3 ~ 3.5 studs, 충돌 없음). | 가는 마스트. 키트 파일 `Roof Antenna.glb` |
| `Radar` | 착륙선 지붕 레이더 접시(충돌 없음). | 접시. 키트 파일 `Roof Radar.glb` |
| `Crate` | 착륙선 뒤 오른쪽 바닥의 상자 4개(2 x 2, 약 3 studs, 충돌 있음). 스폰 지점, 로버 경로, 모듈로 가는 길을 막지 않는 자리입니다. | 상자. 키트 파일 `Pickup Crate.glb` |
| `Crop` | Farm B 가 완공되는 순간 건물 앞쪽 반원 바닥에 작물 8개(약 2 studs, 충돌 없음). 정면 통로 자리는 비워 둡니다. Base 아래에 생겨 재시작하면 함께 사라집니다. | 초록 식물. 키트 파일 `Plant-VwXvoIpCHP.glb` |

- 각 항목은 Model 또는 MeshPart 하나입니다. MeshPart 하나만 넣어도 코드가 Model 로 감싸서 처리합니다.
- 방향: Rover 는 긴 쪽이 앞뒤, Panel 은 긴 쪽이 좌우가 되도록 코드가 90도 돌려 맞춥니다. 앞뒤가 반대로 보이면 그 항목에 number Attribute `Yaw` 를 추가해 각도(도)를 넣습니다. 예: 180. `Yaw` 가 있으면 자동 방향 맞춤은 하지 않습니다.
- 바위는 맵 전체를 그레이박스로 만들 때, 즉 `Workspace.LandingPads` 가 없을 때만 쓰입니다.
- 장식 10종은 모두 외형 전용이고, 없으면 지금과 똑같이 동작합니다. `IceCrystal` 은 코드가 얼음 지점을 만들 때만, `WaterTank`, `Pad`, `Antenna`, `Radar`, `Crate` 는 코드가 BaseKit 을 조립할 때만 쓰입니다. `Planet`, `Connector`, `Crop` 은 디자이너가 만든 BaseKit 이나 맵에서도 동작합니다.

### Studio 에서 하는 일

1. Import 3D 로 가져오기: Home 탭의 Import 3D 로 키트의 glTF 또는 FBX 파일을 하나씩 가져옵니다. 가져온 모델의 파트는 Anchored 를 켜 둡니다. 꺼져 있으면 Play 직후 떨어지면서 모양이 흐트러질 수 있습니다.
2. Workspace 에 KitImports 폴더 만들기: Explorer 에서 Workspace 를 오른쪽 클릭하고 Insert Object, Folder 를 고른 뒤 이름을 `KitImports` 로 바꿉니다.
3. 이름 바꾸기: 가져온 모델을 KitImports 폴더 안으로 옮기고 위 표의 이름으로 바꿉니다. 대소문자까지 정확히 씁니다.
4. Play: Output 창에서 `[KitImports]` 경고가 없는지 확인하고, 기지와 로버가 메시로 보이는지 확인합니다.

### 팁: 완성된 BaseKit 을 영구 저장하기

KitImports 로 만든 BaseKit 은 Play 중에만 존재합니다. 영구 저장하려면 이렇게 합니다.

1. Play 중 Explorer 에서 `ServerStorage.BaseKit` 를 선택하고 복사합니다. 패널도 저장하려면 `ServerStorage.PanelTemplate` 도 함께 복사합니다.
2. Stop 합니다.
3. 편집 화면의 ServerStorage 를 선택하고 붙여넣습니다.

ServerStorage 에 BaseKit 이 있으면 코드는 그것을 그대로 쓰고 KitImports 의 기지 외형은 쓰지 않습니다. 이때 Output 창에 경고 한 줄이 나옵니다. 붙여넣은 BaseKit 을 손으로 고쳐 쓸 수 있고, 다시 자동 조립하려면 ServerStorage 의 BaseKit 을 지우면 됩니다.

### 3차 라운드 메모 (2026-10-17)
- 기지 키트는 코드가 만드는 콘크리트 판 위에 놓이고, 판 밖은 Terrain(크레이터, 언덕)입니다. 디자이너 BaseKit을 쓸 때도 판은 코드가 깔아 줍니다.
- Lander와 HabitatA 메시는 걸어 들어가는 건물입니다. 코드가 정면에 문과 보이지 않는 충돌 벽, 내부 조명, 내부 산소 구역을 만듭니다. 메시는 속이 비어 보여야 하므로 가능하면 안쪽 면이 있는 모델을 고르거나, 코드가 DoubleSided를 켭니다.
- Antenna는 Lander 꼭대기 중심, Radar는 Lander 왼쪽 바닥(지상 장비)입니다.
