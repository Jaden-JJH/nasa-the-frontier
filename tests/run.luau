-- 테스트 진입점: 저장소 루트에서 lune run tests/run.luau (CI .github/workflows/ci.yml)
-- 1) 순수 로직 단위 테스트: v1 Simulation, Ranking (v1 파일을 지울 때 함께 뺀다), v2 Rules, RankingV2, 다국어, WorldMath, ClientMath
-- 2) 하위 프로세스 (Roblox API 흉내와 process.exit가 단위 테스트 환경에 섞이지 않도록 따로 돌린다)
--    - tests/world_smoke.luau     MissionWorld 배치 스모크 (rojo build -> build/world_smoke.rbxl)
--    - tests/server_smoke_v2.luau v2 서버 흐름 스모크 (rojo build -> build/server_smoke_v2.rbxl)
--    - tools/i18n/build.luau --check  CSV와 생성물(Strings.luau, strings.json) 일치
--    - tools/i18n/lint.luau           서버, shared 한글 리터럴과 코드의 문구 키
--    - tools/rules/export.luau --check  MissionConfig와 data/rules_v2.json(웹판 공유) 일치
--    v1 server_smoke.luau는 v1 부팅이 없어져 돌리지 않는다(파일은 남겨 둔다).
--    rojo가 없거나 저장소 루트가 아니면 스모크는 건너뛰고 그 사실을 출력한다.
-- 실패가 하나라도 있으면 종료 코드 1

local fs = require("@lune/fs")
local process = require("@lune/process")
local harness = require("./harness")

local BUILD_DIR = "build"

local specs = {
    { name = "Simulation (v1)", run = require("./simulation.spec") },
    { name = "Ranking (v1)", run = require("./ranking.spec") },
    { name = "Rules v2", run = require("./rules.spec") },
    { name = "RankingV2", run = require("./ranking_v2.spec") },
    { name = "I18n", run = require("./i18n.spec") },
    { name = "World", run = require("./world.spec") },
    { name = "Client", run = require("./client.spec") },
}

for _, spec in specs do
    print("[" .. spec.name .. "]")
    spec.run(harness)
end

local _, failed = harness.report()

local function atRoot(): boolean
    return fs.isFile("default.project.json")
end

-- 하위 프로세스 하나. 성공하면 summary를 담은 줄만, 실패하면 전체 출력. 실패하면 true
local function runProcess(label: string, args: { string }, summary: string?): boolean
    print("")
    print("[" .. label .. "]")
    local ran, result = pcall(process.exec, "lune", args)
    if not ran then
        print(
            "  실패: lune 하위 프로세스를 실행할 수 없습니다 ("
                .. tostring(result)
                .. ")"
        )
        return true
    end
    if result.ok then
        local okCount = select(2, string.gsub(result.stdout, "\n  OK ", ""))
        local printed = false
        for line in string.gmatch(result.stdout, "[^\n]+") do
            if summary and string.find(line, summary, 1, true) then
                print(string.format("  %s (OK %d)", line, okCount))
                printed = true
            end
        end
        if not printed then
            local last = nil
            for line in string.gmatch(result.stdout, "[^\n]+") do
                last = line
            end
            print("  통과 " .. (last or ""))
        end
        return false
    end
    print(result.stdout)
    print(result.stderr)
    return true
end

-- rojo로 place를 빌드해 스모크 스크립트를 돌린다. 실패하면 true
local function runSmoke(label: string, script: string, place: string, summary: string): boolean
    if not atRoot() or not fs.isFile(script) then
        print("")
        print("[" .. label .. "]")
        print("  건너뜀: 저장소 루트에서 실행하지 않았습니다")
        return false
    end
    if not fs.isDir(BUILD_DIR) then
        fs.writeDir(BUILD_DIR)
    end
    local spawned, build =
        pcall(process.exec, "rojo", { "build", "default.project.json", "-o", place })
    if not spawned then
        print("")
        print("[" .. label .. "]")
        print("  건너뜀: rojo를 실행할 수 없습니다 (" .. tostring(build) .. ")")
        return false
    end
    if not build.ok then
        print("")
        print("[" .. label .. "]")
        print("  실패: rojo build")
        print(build.stdout .. build.stderr)
        return true
    end
    return runProcess(label, { "run", script, place }, summary)
end

local smokeFailed = false
smokeFailed = runSmoke(
    "WorldSmoke",
    "tests/world_smoke.luau",
    BUILD_DIR .. "/world_smoke.rbxl",
    "월드 스모크 결과"
) or smokeFailed
smokeFailed = runSmoke(
    "ServerSmokeV2",
    "tests/server_smoke_v2.luau",
    BUILD_DIR .. "/server_smoke_v2.rbxl",
    "v2 서버 스모크 결과"
) or smokeFailed
if atRoot() then
    smokeFailed = runProcess("I18n build --check", { "run", "tools/i18n/build.luau", "--check" })
        or smokeFailed
    smokeFailed = runProcess("I18n lint", { "run", "tools/i18n/lint.luau" }, "[i18n lint] 통과")
        or smokeFailed
    smokeFailed = runProcess(
        "Rules export --check",
        { "run", "tools/rules/export.luau", "--check" }
    ) or smokeFailed
end

if failed > 0 or smokeFailed then
    process.exit(1)
end
