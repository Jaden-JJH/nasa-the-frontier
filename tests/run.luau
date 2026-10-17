-- 테스트 진입점: 저장소 루트에서 lune run tests/run.luau
-- 1) 순수 로직 단위 테스트 (Simulation)
-- 2) 서버 통합 스모크 (tests/server_smoke.luau): rojo로 place를 새로 빌드해 별도 lune 프로세스로 돌린다.
--    Roblox API 흉내가 단위 테스트 환경에 섞이지 않도록 하위 프로세스로 분리했다.
--    rojo가 없거나 저장소 루트가 아니면 건너뛰고 그 사실을 출력한다.
-- 실패가 하나라도 있으면 종료 코드 1 (CI에서 실패 처리)

local fs = require("@lune/fs")
local process = require("@lune/process")
local harness = require("./harness")

local SMOKE_DIR = "build"
local SMOKE_PLACE = "build/smoke.rbxl"
local SMOKE_SCRIPT = "tests/server_smoke.luau"

local specs = {
    { name = "Simulation", run = require("./simulation.spec") },
}

for _, spec in specs do
    print("[" .. spec.name .. "]")
    spec.run(harness)
end

local _, failed = harness.report()

-- 서버 스모크. 실패하면 true
local function runServerSmoke(): boolean
    print("")
    print("[ServerSmoke]")
    if not fs.isFile("default.project.json") or not fs.isFile(SMOKE_SCRIPT) then
        print("  건너뜀: 저장소 루트에서 실행하지 않았습니다")
        return false
    end
    if not fs.isDir(SMOKE_DIR) then
        fs.writeDir(SMOKE_DIR)
    end
    local spawned, build =
        pcall(process.exec, "rojo", { "build", "default.project.json", "-o", SMOKE_PLACE })
    if not spawned then
        print("  건너뜀: rojo를 실행할 수 없습니다 (" .. tostring(build) .. ")")
        return false
    end
    if not build.ok then
        print("  실패: rojo build")
        print(build.stdout .. build.stderr)
        return true
    end
    local ran, result = pcall(process.exec, "lune", { "run", SMOKE_SCRIPT, SMOKE_PLACE })
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
        for line in string.gmatch(result.stdout, "[^\n]+") do
            if string.find(line, "스모크 결과", 1, true) then
                print(string.format("  %s (OK %d)", line, okCount))
            end
        end
        return false
    end
    print(result.stdout)
    print(result.stderr)
    return true
end

local smokeFailed = runServerSmoke()

if failed > 0 or smokeFailed then
    process.exit(1)
end
