--!strict
-- 다국어 소스 검사 (docs/I18N_PLAN.md 4.1, 4.3). 저장소 루트에서: lune run tools/i18n/lint.luau
-- 1) src/server, src/shared의 문자열 리터럴 중 한글이 든 것을 센다. 로그 호출(print, warn, error, assert와
--    lib.luau LOG_CALLS의 로그 래퍼 warnOnce, safe) 안은 뺀다.
--    v1 파일은 아래 ALLOW 표의 상한까지 허용한다(2026-11-14 개수). 상한을 넘거나 표에 없는 파일(v2 새 코드)에 있으면 실패.
--    생성물 src/shared/Strings.luau는 검사하지 않는다. 주석은 검사하지 않는다.
-- 2) src 전체에서 문구 키 리터럴(첫 마디가 아는 도메인인 domain.name 모양, 위치 무관)이
--    i18n/strings.csv에 있는지 본다 (판정은 lib.luau Lib.keyUse).
--    없으면 실패, CSV에만 있는 키는 개수만 경고한다 (v2 화면이 키로 바뀌면 줄어든다).
-- 실패가 하나라도 있으면 종료 코드 1. --verbose 를 주면 파일마다 줄 번호와 리터럴을 출력한다.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Lib = require("./lib")

local verbose = table.find(process.args, "--verbose") ~= nil

local KOREAN_ROOTS = { "src/server", "src/shared" }
local KEY_ROOTS = { "src" }
local SKIP = {
    [Lib.LUAU_PATH] = true, -- 생성물 (CSV 사본)
}
-- v1 파일의 한글 리터럴 상한 (2026-11-14 측정). v1 문구를 키로 옮기면 숫자를 낮추고, 0이 되면 줄을 지운다.
local ALLOW: { [string]: number } = {
    -- ALLOW_TABLE_START
    ["src/server/Construction.luau"] = 1,
    ["src/server/DevMap.luau"] = 12,
    ["src/server/KitImports.luau"] = 3,
    ["src/server/ModulePanels.luau"] = 2,
    ["src/server/ModuleRepair.luau"] = 1,
    ["src/server/Oxygen.luau"] = 2,
    ["src/server/RoverDrive.luau"] = 1,
    ["src/server/RunLog.luau"] = 19,
    ["src/server/SolarPanels.luau"] = 3,
    ["src/server/WaterLoop.luau"] = 2,
    ["src/shared/Config.luau"] = 230,
    ["src/shared/Facts.luau"] = 20,
    ["src/shared/SoundIds.luau"] = 36,
    -- ALLOW_TABLE_END
}

local function listFiles(root: string, out: { string })
    if not fs.isDir(root) then
        return
    end
    local names = fs.readDir(root)
    table.sort(names)
    for _, name in names do
        local path = root .. "/" .. name
        if fs.isDir(path) then
            listFiles(path, out)
        elseif string.match(name, "%.luau?$") then
            table.insert(out, path)
        end
    end
end

local function main(): number
    if not fs.isFile(Lib.CSV_PATH) then
        print(
            "[i18n lint] "
                .. Lib.CSV_PATH
                .. " 이 없습니다. 저장소 루트에서 실행하세요."
        )
        return 1
    end
    local failures = 0

    -- 1) 한글 리터럴
    print("[i18n lint] src/server, src/shared 한글 리터럴 (로그 호출 제외)")
    local files: { string } = {}
    for _, root in KOREAN_ROOTS do
        listFiles(root, files)
    end
    local seen: { [string]: boolean } = {}
    local total, logTotal = 0, 0
    for _, path in files do
        if SKIP[path] then
            continue
        end
        seen[path] = true
        local hits: { Lib.Literal } = {}
        local logs = 0
        for _, literal in Lib.scanLuau(fs.readFile(path)) do
            if Lib.hasHangul(literal.text) then
                if literal.inLog then
                    logs += 1
                else
                    table.insert(hits, literal)
                end
            end
        end
        logTotal += logs
        total += #hits
        local limit = ALLOW[path]
        if #hits == 0 and not limit then
            continue
        end
        local mark = "통과"
        local failed = false
        if not limit then
            mark = "실패 (허용 목록 밖, v2 코드는 문구 키를 쓰세요)"
            failed = true
        elseif #hits > limit then
            mark = string.format("실패 (상한 %d 초과)", limit)
            failed = true
        elseif #hits < limit then
            mark = string.format("통과 (상한을 %d로 낮출 수 있음)", #hits)
        end
        if failed then
            failures += 1
        end
        print(string.format("  %-40s %4d  %s", path, #hits, mark))
        if verbose or failed then
            for _, literal in hits do
                print(string.format("      %d: %s", literal.line, literal.text))
            end
        end
    end
    for path in ALLOW do
        if not seen[path] then
            print("  " .. path .. ": 파일이 없습니다. ALLOW 표에서 지우세요")
        end
    end
    print(string.format("  합계 %d개 (로그 안 %d개는 허용)", total, logTotal))

    -- 2) 문구 키
    print("[i18n lint] 코드의 문구 키가 i18n/strings.csv에 있는지")
    local result = Lib.load(fs.readFile(Lib.CSV_PATH))
    local csvKeys: { [string]: boolean } = {}
    for _, row in result.rows do
        csvKeys[row.key] = true
        local base = Lib.pluralParts(row.key)
        if base then
            csvKeys[base] = true
        end
    end
    local used: { [string]: boolean } = {}
    local keyFiles: { string } = {}
    for _, root in KEY_ROOTS do
        listFiles(root, keyFiles)
    end
    local missing = 0
    for _, path in keyFiles do
        if SKIP[path] then
            continue
        end
        for _, literal in Lib.scanLuau(fs.readFile(path)) do
            local key = Lib.keyUse(literal)
            if key then
                used[key] = true
                if not csvKeys[key] then
                    missing += 1
                    print(string.format("  실패 %s:%d 없는 키 %s", path, literal.line, key))
                end
            end
        end
    end
    local usedCount, unused = 0, 0
    for _ in used do
        usedCount += 1
    end
    for _, row in result.rows do
        local base = Lib.pluralParts(row.key) or row.key
        if not used[row.key] and not used[base] then
            unused += 1
        end
    end
    failures += missing
    print(
        string.format(
            "  코드에서 쓰는 키 %d개, 없는 키 %d개, CSV에만 있는 행 %d개 (경고)",
            usedCount,
            missing,
            unused
        )
    )

    if failures > 0 then
        print(string.format("[i18n lint] 실패 %d건", failures))
        return 1
    end
    print("[i18n lint] 통과")
    return 0
end

process.exit(main())
