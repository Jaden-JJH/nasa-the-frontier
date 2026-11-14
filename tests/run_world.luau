-- v2 월드 배치 테스트 단독 진입점: 저장소 루트에서 lune run tests/run_world.luau
-- 1) WorldMath 단위 테스트 (tests/world.spec.luau)
-- 2) MissionWorld 스모크 (tests/world_smoke.luau): rojo로 place를 빌드해 MissionC 표시 픽스처를 놓고 별도 lune 프로세스로 돌린다.
-- tests/run.luau와 합치는 것은 리드가 나중에 한다 (specs 표에 { name = "World", run = require("./world.spec") } 추가,
-- 스모크는 runServerSmoke와 같은 방식으로 SMOKE_SCRIPT만 바꿔 한 번 더).
-- 실패가 하나라도 있으면 종료 코드 1

local fs = require("@lune/fs")
local process = require("@lune/process")
local harness = require("./harness")

local SMOKE_DIR = "build"
local SMOKE_PLACE = "build/world_smoke.rbxl"
local SMOKE_SCRIPT = "tests/world_smoke.luau"

print("[World]")
require("./world.spec")(harness)
local _, failed = harness.report()

-- MissionWorld 스모크. 실패하면 true
local function runWorldSmoke(): boolean
    print("")
    print("[WorldSmoke]")
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
            if string.find(line, "월드 스모크 결과", 1, true) then
                print(string.format("  %s (OK %d)", line, okCount))
            end
        end
        return false
    end
    print(result.stdout)
    print(result.stderr)
    return true
end

local smokeFailed = runWorldSmoke()

if failed > 0 or smokeFailed then
    process.exit(1)
end
