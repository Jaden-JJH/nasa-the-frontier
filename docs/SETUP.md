# 개발 환경 설정 (SETUP)

이 문서는 개발자와 디자이너가 함께 읽는 설정 가이드입니다. Roblox Studio나 Luau를 처음 쓰는 사람도 순서대로 따라 할 수 있도록 썼습니다.

- 게임 규칙과 수치: [GDD.md](GDD.md)
- 서버와 클라이언트가 합의한 이름과 인터페이스: [CONTRACT.md](CONTRACT.md)
- 디자이너용 맵 이름과 Attribute 명세: [MAP_SPEC.md](MAP_SPEC.md)
- Creator Store 에셋 사용법: [ASSETS.md](ASSETS.md)

## 1. 전체 흐름

한 장으로 그리면 아래와 같습니다.

```text
Git 저장소의 src 폴더 (Luau 코드)
        |
        |  내 PC에서 rojo serve 실행
        v
Roblox Studio + Rojo 플러그인 (Connect 를 누른 상태)
        |
        |  Team Create 로 팀원 전체가 같은 플레이스를 편집
        v
디자이너가 만든 맵과 에셋 (Studio 파일 안에 저장됨)
```

역할은 이렇게 나눕니다.

- **코드는 Git 저장소가 진실입니다.** `src` 폴더의 파일이 원본입니다. 고친 내용은 브랜치와 Pull Request 로 합칩니다.
- **맵과 에셋은 Studio 파일이 진실입니다.** 디자이너가 Studio에서 배치한 Part, Model, Attribute 가 원본입니다. 맵 파일(`.rbxl`)은 Git에 올리지 않습니다.

## 2. 공통 설치

모든 팀원이 한 번만 하면 됩니다.

1. Roblox 계정을 만듭니다.
2. Roblox Studio를 설치합니다: https://create.roblox.com/
3. 저장소를 내려받습니다.

   ```sh
   git clone <저장소 주소>
   cd the-frontier
   ```

4. Rokit(도구 관리자)을 설치합니다. README에 있는 명령을 그대로 씁니다.

   ```sh
   curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
   ```

   설치 후 새 터미널을 열거나 아래 줄로 PATH 를 적용합니다.

   ```sh
   export PATH="$HOME/.rokit/bin:$PATH"
   ```

   Windows 를 쓰면 Rokit 공식 저장소 https://github.com/rojo-rbx/rokit 의 설치 안내를 따르세요.

5. 저장소 루트에서 도구를 설치합니다. `rokit.toml` 에 적힌 버전이 설치됩니다.

   ```sh
   rokit install
   ```

6. Rojo Studio 플러그인을 설치합니다.

   ```sh
   rojo plugin install
   ```

7. Roblox Studio가 이미 켜져 있었다면 재시작합니다. 재시작해야 Rojo 플러그인이 보입니다.

## 3. 개발자 루프

코드를 고치고 Studio에서 바로 확인하는 과정입니다.

1. 저장소 루트에서 동기화 서버를 켭니다.

   ```sh
   rojo serve
   ```

   이 터미널은 작업하는 동안 끄지 않고 둡니다.

2. Roblox Studio에서 플레이스를 엽니다. 팀 플레이스가 있으면 그것을 열고, 없으면 빈 플레이스를 만듭니다.
3. Studio의 Rojo 플러그인에서 **Connect** 를 누릅니다.
4. VS Code 같은 편집기로 `src` 안의 파일을 고치면 Studio에 바로 반영됩니다.
5. Studio 상단의 **Play** 버튼으로 테스트합니다. 끝내려면 **Stop** 을 누릅니다.

### 맵이 없을 때 생기는 자동 맵

처음 Play를 누를 때 `Workspace.LandingPads` 폴더가 없으면, 코드가 회색 상자로 된 임시 맵(그레이박스 맵)과 `ServerStorage.BaseKit` 을 자동으로 만듭니다. 이 기능을 DevMap 이라고 부릅니다. 덕분에 맵을 기다리지 않고 코드를 먼저 확인할 수 있습니다. 디자이너가 `LandingPads` 를 직접 만들면 자동 맵은 만들어지지 않습니다.

### Luau 가 무엇인가요

Luau 는 Roblox가 Lua 언어를 확장해서 만든 프로그래밍 언어입니다. Lua 계열이라서 문법이 짧고 읽기 쉽습니다. Roblox 게임 코드를 쓰는 데 주로 쓰입니다.

아래는 변수와 함수를 쓰는 짧은 예제입니다. `--` 뒤는 설명입니다.

```lua
local energy = 25                  -- 숫자 변수
local water = "물"                 -- 문자열 변수
local function addEnergy(amount)   -- 함수 정의. amount 를 받아서 energy 에 더함
    energy += amount               -- += 는 Luau 에서 쓸 수 있는 줄임 표현
end
addEnergy(5)                       -- 함수 호출. 이제 energy 는 30
```

### 브랜치와 PR

기능마다 브랜치를 만들고, `main` 에 직접 올리지 않고 Pull Request 로 합칩니다. 자세한 규칙은 README의 협업 규칙을 따릅니다.

## 4. 디자이너 루프

디자이너는 Studio에서 맵과 에셋을 만듭니다.

1. **Team Create 를 켭니다.** Studio 메뉴에서 Team Create 설정을 찾으세요. 같은 플레이스를 편집할 팀원을 초대합니다. Team Create 는 플레이스를 Roblox에 먼저 퍼블리시해야 쓸 수 있을 수 있으니, 자세한 조건은 공식 문서 https://create.roblox.com/docs 에서 확인하세요.
2. **이름을 그대로 씁니다.** 맵과 에셋을 배치할 때 [MAP_SPEC.md](MAP_SPEC.md) 의 이름을 한 글자도 다르지 않게 씁니다. `Pad1`, `Lander`, `DriverSeat` 같은 이름이 다르면 코드가 찾지 못합니다.
3. **Rojo가 관리하는 폴더는 Studio에서 직접 고치지 않습니다.** 아래 세 폴더가 대상입니다.
   - `ReplicatedStorage.Shared`
   - `ServerScriptService.Server`
   - `StarterPlayer.StarterPlayerScripts.Client`

   이 폴더 안을 Studio에서 고치면 다음 동기화 때 Git 파일 내용으로 되돌아갈 수 있습니다. 코드 수정이 필요하면 개발자에게 요청하거나 `src` 에서 고칩니다. 반대로 `Workspace`, `ServerStorage` 는 Rojo가 관리하지 않으므로 디자이너가 자유롭게 편집할 수 있습니다.

## 5. 퍼블리시와 제출

해커톤 제출은 Roblox 게임 링크입니다.

1. Studio 상단 **File** 메뉴에서 **Publish to Roblox** 를 선택합니다. 처음이면 게임 이름과 설명을 정합니다.
2. Studio 메뉴에서 게임 설정(Game Settings)을 찾으세요. 서버 최대 인원을 **4** 로 설정합니다.
3. 같은 설정 메뉴에서 플레이 가능 여부를 **Public(공개)** 으로 바꿉니다. 게임 페이지 링크를 복사해서 제출합니다.
4. 제출 전에 링크를 다른 계정이나 브라우저에서 열어 실제로 들어가지는지 한 번 확인합니다.

## 6. 문제 해결 FAQ

**Q. Rojo 에서 Connect 가 안 됩니다.**
터미널에서 `rojo serve` 가 실행 중인지 확인하세요. 그 명령을 끈 상태이거나 다른 프로그램이 같은 연결을 쓰고 있을 수 있습니다. `rojo serve` 를 다시 실행한 뒤 Connect 를 다시 누릅니다.

**Q. `rokit` 명령을 찾을 수 없다고 나옵니다.**
PATH 설정이 안 된 상태입니다. 새 터미널을 열거나 아래 줄을 실행하세요.

```sh
export PATH="$HOME/.rokit/bin:$PATH"
```

**Q. Studio 탐색기에 스크립트가 안 보입니다.**
Rojo 에 Connect 하지 않았거나 동기화가 끊어졌을 가능성이 큽니다. Rojo 플러그인에서 Connect 상태를 확인하세요. 그래도 안 보이면 `ServerScriptService` 아래에 `Server` 폴더가 있는지 확인합니다.

**Q. Play 를 눌렀는데 아무 UI 도 보이지 않습니다.**
화면이 아니라 코드에서 오류가 났을 가능성이 높습니다. Studio 메뉴에서 Output 창을 찾아 열고 빨간 글씨 오류를 확인하세요. 오류 내용을 개발자에게 그대로 전달합니다.

**Q. 팀원이 만든 맵이 내 Studio 에 없습니다.**
Team Create 를 쓰지 않으면 각자의 Studio 파일에만 맵이 있습니다. 팀원과 같은 플레이스를 Team Create 로 함께 편집해야 합니다. Git에는 맵이 올라가지 않으므로 Git pull 로는 받을 수 없습니다.

## 7. Studio MCP (선택)

Roblox 는 Studio 와 AI 도구를 연결하는 MCP 서버를 제공합니다. 이 서버를 쓰면 Claude가 Studio 안에서 코드를 실행하거나 모델을 넣을 수 있습니다. 프로젝트 초기에 Roblox 공식 저장소 https://github.com/roblox/studio-rust-mcp-server 가 소개되었지만, 이 저장소는 현재 보관(archived) 상태이고 더 이상 개발되지 않습니다. Roblox 는 Studio 에 들어 있는 내장 MCP 서버 사용을 권장합니다. 설치 방법은 공식 문서 https://create.roblox.com/docs 에서 MCP 항목을 찾아 따르세요. 쓰지 않아도 게임 개발에는 문제가 없습니다.
