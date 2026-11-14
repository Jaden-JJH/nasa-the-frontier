-- 다국어 테스트 단독 진입점: 저장소 루트에서 lune run tests/run_i18n.luau
-- tests/run.luau와 합치는 것은 리드가 나중에 한다 (specs 표에 { name = "I18n", run = require("./i18n.spec") } 추가).
-- 실패가 하나라도 있으면 종료 코드 1

local process = require("@lune/process")
local harness = require("./harness")

print("[I18n]")
require("./i18n.spec")(harness)

local _, failed = harness.report()
if failed > 0 then
    process.exit(1)
end
