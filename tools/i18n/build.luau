--!strict
-- 다국어 빌드 (docs/I18N_PLAN.md 4.3). 저장소 루트에서 실행한다.
--   lune run tools/i18n/build.luau          CSV 검사 후 src/shared/Strings.luau, i18n/strings.json 생성
--   lune run tools/i18n/build.luau --check  CSV 검사 + 생성물이 CSV와 같은지만 확인 (CI용, 파일을 쓰지 않음)
-- 검사 오류가 있거나(--check에서) 생성물이 오래되면 종료 코드 1. 경고는 출력만 한다.
-- 규칙은 tools/i18n/lib.luau 맨 위 설명을 본다.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Lib = require("./lib")

local checkOnly = table.find(process.args, "--check") ~= nil

if not fs.isFile(Lib.CSV_PATH) then
    print("[i18n] " .. Lib.CSV_PATH .. " 이 없습니다. 저장소 루트에서 실행하세요.")
    process.exit(1)
end

local result = Lib.load(fs.readFile(Lib.CSV_PATH))

for _, issue in result.warnings do
    print("경고  " .. Lib.formatIssue(issue))
end
for _, issue in result.errors do
    print("오류  " .. Lib.formatIssue(issue))
end

local parts = {}
for _, item in Lib.countByDomain(result.rows) do
    table.insert(parts, item.domain .. " " .. tostring(item.count))
end
print(
    string.format(
        "[i18n] 행 %d개 (%s), 오류 %d, 경고 %d",
        #result.rows,
        table.concat(parts, ", "),
        #result.errors,
        #result.warnings
    )
)

if #result.errors > 0 then
    print("[i18n] 오류가 있어 생성하지 않았습니다.")
    process.exit(1)
end

local outputs = {
    { path = Lib.LUAU_PATH, content = Lib.generateLuau(result.rows) },
    { path = Lib.JSON_PATH, content = Lib.generateJson(result.rows) },
}

if checkOnly then
    local stale = {}
    for _, output in outputs do
        if not fs.isFile(output.path) or fs.readFile(output.path) ~= output.content then
            table.insert(stale, output.path)
        end
    end
    if #stale > 0 then
        print(
            "[i18n] 생성물이 CSV와 다릅니다: "
                .. table.concat(stale, ", ")
                .. ". lune run tools/i18n/build.luau 로 다시 만드세요."
        )
        process.exit(1)
    end
    print("[i18n] --check 통과: 생성물이 CSV와 같습니다.")
    process.exit(0)
end

for _, output in outputs do
    local same = fs.isFile(output.path) and fs.readFile(output.path) == output.content
    if not same then
        fs.writeFile(output.path, output.content)
    end
    print(string.format("[i18n] %s %s", output.path, if same then "(변경 없음)" else "생성"))
end
