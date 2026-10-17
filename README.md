# The Frontier

달 기지 건설 생존 교육 게임입니다. Roblox(Luau)로 만들며, 해커톤 출품작입니다. 플레이어는 달 표면에서 기지를 짓고 산소, 전력, 물 같은 자원을 관리하며 생존하는 과정에서 우주 과학 지식을 배웁니다. 상세 기획은 [docs/GDD.md](docs/GDD.md) 를 참고하세요.

## 개발 환경 준비

1. Rokit(도구 관리자) 설치

   ```sh
   curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
   ```

   설치 후 새 터미널을 열거나 아래 줄로 PATH 를 적용합니다.

   ```sh
   export PATH="$HOME/.rokit/bin:$PATH"
   ```

2. 저장소 루트에서 도구 설치 (rojo, selene, stylua, luau-lsp, lune 이 `rokit.toml` 버전으로 설치됨)

   ```sh
   rokit install
   ```

3. Roblox Studio 설치: https://create.roblox.com/
4. Rojo Studio 플러그인 설치

   ```sh
   rojo plugin install
   ```

5. 동기화 서버 시작 후 Studio 의 Rojo 플러그인에서 Connect 를 누릅니다.

   ```sh
   rojo serve
   ```

### 폴더 구조

| 경로 | Studio 위치 |
| --- | --- |
| `src/shared` | ReplicatedStorage.Shared |
| `src/server` | ServerScriptService.Server |
| `src/client` | StarterPlayer.StarterPlayerScripts.Client |
| `tests` | 게임에 동기화되지 않음 (Lune 테스트) |

`ReplicatedStorage.Remotes` 는 빈 Folder 이며, 코드가 런타임에 RemoteEvent 를 만들어 넣습니다. Workspace 중력은 프로젝트 파일에서 16 으로 설정되어 있습니다.

### 린트와 포맷

```sh
selene src tests
stylua --check src tests
stylua src tests            # 자동 포맷
```

타입 분석(luau-lsp)은 Roblox API 정의 파일이 필요합니다. 아래처럼 gitignore 된 `.cache/` 에 한 번 내려받습니다.

```sh
mkdir -p .cache
curl -sSfL -o .cache/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --definitions=.cache/globalTypes.d.luau src
```

### 테스트

```sh
lune run tests/run.luau
```

### 빌드

```sh
rojo build default.project.json -o build.rbxl
```

## 협업 규칙

- 기능마다 브랜치를 만듭니다. 예: `feat/oxygen-system`
- main 에 직접 푸시하지 않고 Pull Request 로 병합합니다.
- CI(selene, stylua, rojo build, lune)가 통과해야 병합합니다.
- 비밀 값(API 키, 토큰)은 커밋하지 않습니다.

## 문서

- [GDD](docs/GDD.md): 게임 기획서. 규칙과 밸런스 수치를 담고 있습니다.
- [CONTRACT](docs/CONTRACT.md): 서버와 클라이언트가 합의한 이름과 인터페이스입니다.
- [SETUP](docs/SETUP.md): 개발 환경 설치, Studio 연결, 퍼블리시 방법입니다.
- [MAP_SPEC](docs/MAP_SPEC.md): 디자이너가 Studio에서 맵을 만들 때 따르는 명세입니다.
- [ASSETS](docs/ASSETS.md): Creator Store 무료 모델과 이미지 사용 가이드입니다.
