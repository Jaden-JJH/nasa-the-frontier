-- v2 클라이언트 순수 계산 테스트 단독 진입점: 저장소 루트에서 lune run tests/run_client.luau
-- tests/run.luau에도 { name = "Client" }로 합쳐져 있다. 이 파일은 클라이언트 테스트만 빨리 돌릴 때 쓴다.
-- 실패가 하나라도 있으면 종료 코드 1

local process = require("@lune/process")
local harness = require("./harness")

print("[Client]")
require("./client.spec")(harness)

local _, failed = harness.report()
if failed > 0 then
    process.exit(1)
end
