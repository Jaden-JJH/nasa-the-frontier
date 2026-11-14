-- 다국어 테스트 (v2, 2026-11-14, docs/I18N_PLAN.md 5절 1~3단계)
-- 1) 골든 벡터 i18n/golden.json (웹판 i18n/loc.js도 같은 파일로 검사한다)
-- 2) Loc, Msg 단위 테스트
-- 3) CSV 빌드 도구(tools/i18n/lib.luau): 파서, 검사 규칙, 생성물, 저장소의 생성물이 CSV와 같은지
-- 4) 소스 스캐너(lint)
-- 5) 서버 PlayerPrefs, 클라이언트 Localizer: 가짜 Roblox 환경(가상 시계, 신호, DataStore)에서 실행
-- 저장소 루트에서 실행한다 (파일을 상대 경로로 읽는다).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local Lib = require("../tools/i18n/lib")
local Loc = require("../src/shared/Loc")
local Msg = require("../src/shared/Msg")
local Strings = require("../src/shared/Strings")

local GOLDEN_PATH = "i18n/golden.json"

-- 골든 케이스 하나 실행 (i18n/test_golden.mjs의 runCase와 같은 분기)
local function runGolden(c: any, table_: any): any
    local kind = c.kind
    if kind == "resolve" then
        return Loc.resolve(c.msg, c.lang, table_)
    elseif kind == "template" then
        return Loc.interpolate(c.template, c.args, c.lang, table_, c.rich == true)
    elseif kind == "date" then
        return Loc.formatDate(c.date, c.lang, c.style, table_)
    elseif kind == "date_arg" then
        return Loc.resolve(Msg.new(c.key, { [c.arg] = Msg.date(c.date, c.style) }), c.lang, table_)
    elseif kind == "date_time" then
        return Loc.resolve(Msg.dateFromTime(c.time, c.style), c.lang, table_)
    elseif kind == "list" then
        return Loc.interpolate("{x}", { x = Msg.list(c.items) }, c.lang, table_, false)
    elseif kind == "escape" then
        return Loc.escape(c.text)
    elseif kind == "normalize" then
        return Loc.normalize(c.value) or ""
    elseif kind == "is_msg" then
        return Msg.isMsg(c.value)
    elseif kind == "equals" then
        return Msg.equals(c.a, c.b)
    end
    error("알 수 없는 kind: " .. tostring(kind))
end

-- 가짜 Roblox 환경 -------------------------------------------------------
-- 가상 시계(now), task.spawn/delay/wait, 신호, 플레이어 속성, DataStore. 모듈은 luau.load로 매번 새로 불러온다.

local function makeWorld()
    local world: any =
        { now = 0, queue = {}, seq = 0, errors = {}, warnings = {}, closeHandlers = {} }

    local function resume(co: thread, ...)
        local ok, err = coroutine.resume(co, ...)
        if not ok then
            table.insert(world.errors, tostring(err))
        end
    end

    local function schedule(at: number, co: thread, ...)
        world.seq += 1
        table.insert(world.queue, { at = at, seq = world.seq, co = co, args = table.pack(...) })
    end

    local fakeTask = {}
    function fakeTask.spawn(fn: any, ...)
        local co = if type(fn) == "thread" then fn else coroutine.create(fn)
        resume(co, ...)
        return co
    end
    function fakeTask.delay(t: number?, fn: any, ...)
        local co = coroutine.create(fn)
        schedule(world.now + (t or 0), co, ...)
        return co
    end
    function fakeTask.defer(fn: any, ...)
        return fakeTask.delay(0, fn, ...)
    end
    function fakeTask.wait(t: number?): number
        local co = coroutine.running()
        local start = world.now
        schedule(world.now + (t or 0), co)
        coroutine.yield()
        return world.now - start
    end
    world.task = fakeTask

    function world.advance(dt: number)
        local target = world.now + dt
        while true do
            local best = nil
            for index, item in world.queue do
                if item.at <= target then
                    local current = best and world.queue[best]
                    if
                        current == nil
                        or item.at < current.at
                        or (item.at == current.at and item.seq < current.seq)
                    then
                        best = index
                    end
                end
            end
            if best == nil then
                break
            end
            local item = table.remove(world.queue, best)
            world.now = math.max(world.now, item.at)
            resume(item.co, table.unpack(item.args, 1, item.args.n))
        end
        world.now = target
    end

    function world.signal()
        local s: any = { handlers = {} }
        function s:Connect(fn)
            table.insert(self.handlers, fn)
            local conn = {}
            function conn.Disconnect()
                local index = table.find(s.handlers, fn)
                if index then
                    table.remove(s.handlers, index)
                end
            end
            return conn
        end
        function s:Fire(...)
            for _, handler in table.clone(self.handlers) do
                fakeTask.spawn(handler, ...)
            end
        end
        return s
    end

    function world.player(userId: number)
        local attrs = {}
        local attrSignals = {}
        local p: any = { UserId = userId, Name = "P" .. tostring(userId) }
        function p:SetAttribute(name, value)
            if attrs[name] == value then
                return -- Roblox처럼 같은 값이면 신호 없음
            end
            attrs[name] = value
            if attrSignals[name] then
                attrSignals[name]:Fire()
            end
        end
        function p:GetAttribute(name)
            return attrs[name]
        end
        function p:GetAttributeChangedSignal(name)
            attrSignals[name] = attrSignals[name] or world.signal()
            return attrSignals[name]
        end
        return p
    end

    -- DataStore: latency초 걸리고 fail이면 오류
    local store: any = { data = {}, fail = false, latency = 0.1, gets = 0, sets = 0, setLog = {} }
    local ds = {}
    function ds:GetAsync(key)
        store.gets += 1
        fakeTask.wait(store.latency)
        if store.fail then
            error("가짜 DataStore 꺼짐")
        end
        return store.data[key]
    end
    function ds:SetAsync(key, value, userIds)
        store.sets += 1
        fakeTask.wait(store.latency)
        if store.fail then
            error("가짜 DataStore 꺼짐")
        end
        store.data[key] = value
        table.insert(store.setLog, { key = key, value = value, userIds = userIds })
    end
    store.service = {
        GetDataStore = function(_, name)
            store.name = name
            return ds
        end,
    }
    world.store = store

    -- Remote: 서버 쪽 OnServerEvent, 클라이언트 쪽 FireServer 기록
    local remote: any = { OnServerEvent = world.signal(), sent = {} }
    function remote:FireServer(...)
        table.insert(self.sent, (...))
        if world.onFireServer then
            world.onFireServer(...)
        end
    end
    world.remote = remote

    world.players = {
        PlayerAdded = world.signal(),
        PlayerRemoving = world.signal(),
        LocalPlayer = nil,
        list = {},
    }
    function world.players:GetPlayers()
        return table.clone(self.list)
    end

    world.services = {
        Players = world.players,
        DataStoreService = store.service,
        ReplicatedStorage = {
            Shared = {
                Loc = Loc,
                Msg = Msg,
                Strings = Strings,
                Remotes = {
                    get = function(name)
                        assert(name == "SetLanguage", "예상 밖 Remote " .. tostring(name))
                        return remote
                    end,
                },
            },
        },
    }

    function world.load(path: string): any
        local fakeGame = {}
        function fakeGame:GetService(name)
            local service = world.services[name]
            if service == nil then
                error("서비스 없음: " .. name)
            end
            return service
        end
        function fakeGame:BindToClose(fn)
            table.insert(world.closeHandlers, fn)
        end
        local env = {
            game = fakeGame,
            task = fakeTask,
            os = {
                clock = function()
                    return world.now
                end,
                time = function()
                    return 1700000000 + math.floor(world.now)
                end,
                date = os.date,
            },
            warn = function(...)
                table.insert(world.warnings, table.concat(table.pack(...), " "))
            end,
            print = function() end,
            require = function(target)
                return target
            end,
            Instance = {
                new = function(className)
                    assert(className == "BindableEvent", "예상 밖 Instance.new " .. className)
                    local event = world.signal()
                    return {
                        Event = event,
                        Fire = function(_, ...)
                            event:Fire(...)
                        end,
                    }
                end,
            },
            math = math,
            string = string,
            table = table,
            coroutine = coroutine,
            utf8 = utf8,
            pcall = pcall,
            xpcall = xpcall,
            error = error,
            assert = assert,
            type = type,
            typeof = typeof,
            tostring = tostring,
            tonumber = tonumber,
            pairs = pairs,
            ipairs = ipairs,
            next = next,
            select = select,
            setmetatable = setmetatable,
            getmetatable = getmetatable,
            rawget = rawget,
            rawset = rawset,
            rawequal = rawequal,
        }
        local fn = luau.load(
            fs.readFile(path),
            { debugName = path, environment = env, injectGlobals = false }
        )
        return fn()
    end

    function world.join(userId: number)
        local player = world.player(userId)
        table.insert(world.players.list, player)
        world.players.PlayerAdded:Fire(player)
        return player
    end

    function world.leave(player: any)
        local index = table.find(world.players.list, player)
        if index then
            table.remove(world.players.list, index)
        end
        world.players.PlayerRemoving:Fire(player)
    end

    return world
end

local function fakeLabel(className: string?): any
    local label: any =
        { Text = "", AutoLocalize = true, RichText = false, ClassName = className or "TextLabel" }
    local attrs = {}
    function label:IsA(name)
        return name == self.ClassName
    end
    function label:GetAttribute(name)
        return attrs[name]
    end
    function label:SetAttribute(name, value)
        attrs[name] = value
    end
    return label
end

local function issuesWith(list: { any }, part: string): number
    local count = 0
    for _, issue in list do
        if string.find(issue.message, part, 1, true) then
            count += 1
        end
    end
    return count
end

local function csv(body: string): string
    return "key,en,ko,args,note,max_len\n" .. body
end

return function(t)
    -- 1) 골든 ---------------------------------------------------------------
    local golden = serde.decode("json", fs.readFile(GOLDEN_PATH))
    for _, c in golden.cases do
        t.test("골든: " .. c.id, function()
            t.eq(runGolden(c, golden.strings), c.expected, c.id)
        end)
    end

    t.test("골든: 케이스 수와 종류", function()
        local kinds = {}
        for _, c in golden.cases do
            kinds[c.kind] = true
        end
        t.truthy(#golden.cases >= 80, "80개 이상")
        for _, kind in
            {
                "resolve",
                "template",
                "date",
                "date_arg",
                "date_time",
                "list",
                "escape",
                "normalize",
                "is_msg",
                "equals",
            }
        do
            t.truthy(kinds[kind], kind .. " 케이스 있음")
        end
    end)

    -- 2) Loc, Msg ---------------------------------------------------------
    t.test("Loc: 숫자 예외 값은 ?", function()
        t.eq(Loc.formatNumber(0 / 0), "?")
        t.eq(Loc.formatNumber(math.huge), "?")
        t.eq(Loc.formatNumber(-math.huge), "?")
        t.eq(Loc.formatNumber(-0), "0")
        t.eq(Loc.formatNumber(1000), "1000", "자릿수 쉼표 없음")
    end)

    t.test("Loc: 잘못된 msg와 언어", function()
        t.eq(Loc.resolve(nil :: any, "en", Strings.strings), "", "nil은 빈 문자열")
        t.eq(Loc.resolve({} :: any, "en", Strings.strings), "", "key 없는 표")
        t.eq(
            Loc.resolve("res.food.name", nil :: any, Strings.strings),
            "Food",
            "언어가 nil이면 en"
        )
        t.eq(
            Loc.interpolate("{x}", { x = Msg.new("res.food.name") }, "ko"),
            "res.food.name",
            "표 없이 중첩은 키"
        )
    end)

    t.test("Loc: 지원 언어와 기본값", function()
        t.eq(
            table.concat(Loc.SUPPORTED, ","),
            table.concat(Strings.languages, ","),
            "Loc과 CSV 언어 목록이 같다"
        )
        t.eq(Loc.DEFAULT, "en")
        t.eq(Loc.MAX_DEPTH, Msg.MAX_DEPTH, "Loc과 Msg 깊이 제한이 같다")
    end)

    t.test("Msg: count는 args를 복사하고 원본을 바꾸지 않는다", function()
        local args = { points = 10 }
        local m = Msg.count("score.deduct.food_low", 2, args)
        t.eq(m.args and m.args.count, 2)
        t.eq(m.args and m.args.points, 10)
        t.eq(args.count, nil, "원본 그대로")
        t.eq(Loc.resolve(m, "en", Strings.strings), "Food was low for 2 days: -10")
        t.eq(Loc.resolve(m, "ko", Strings.strings), "식량이 부족했던 날 2일: -10점")
    end)

    t.test("Msg: dateFromTime은 UTC (한국 시간 아님)", function()
        -- 2024-08-12 23:30 UTC = 한국 시간 8월 13일 08:30
        local m = Msg.dateFromTime(1723420800 + 23 * 3600 + 1800, "long")
        t.eq(Loc.resolve(m, "en", Strings.strings), "August 12, 2024")
        t.eq(Loc.resolve(m, "ko", Strings.strings), "2024년 8월 12일")
        t.eq(Loc.resolve(Msg.dateFromTime(1723420800, "short"), "en", Strings.strings), "Aug 12")
    end)

    t.test("Msg: isMsg 깊이 제한과 키 길이", function()
        local value: any = { key = "a.b" }
        for _ = 1, Msg.MAX_DEPTH do
            value = { key = "a.b", args = { x = value } }
        end
        t.truthy(Msg.isMsg(value), "MAX_DEPTH 단계까지는 통과")
        value = { key = "a.b", args = { x = value } }
        t.falsy(Msg.isMsg(value), "한 단계 더 깊으면 거절")
        t.falsy(Msg.isMsg({ key = string.rep("a", Msg.MAX_KEY_LENGTH + 1) }), "너무 긴 키")
        t.falsy(Msg.isMsg({ key = "a.b", args = { x = function() end } }), "함수 값")
    end)

    t.test("Msg: 목록 9개도 깊이 안에서 해석", function()
        local names = { "A", "B", "C", "D", "E", "F", "G", "H", "I" }
        t.eq(
            Loc.interpolate("{x}", { x = Msg.list(names) }, "en", Strings.strings),
            "A, B, C, D, E, F, G, H, and I"
        )
    end)

    t.test("Loc: 실제 문구 표 (Strings.luau)", function()
        local s = Strings.strings
        t.eq(Loc.resolve("res.energy.name", "en", s), "Energy")
        t.eq(Loc.resolve("res.energy.name", "ko", s), "에너지")
        t.eq(Loc.resolve(Msg.count("unit.day", 1), "en", s), "1 day")
        t.eq(Loc.resolve(Msg.count("unit.day", 1), "ko", s), "1일")
        t.eq(Loc.resolve(Msg.count("unit.day", 3), "en", s), "3 days")
        t.eq(
            Loc.resolve(
                Msg.new("event.source", { date = Msg.date({ year = 2024, month = 8, day = 12 }) }),
                "en",
                s
            ),
            "NASA DONKI record, August 12, 2024"
        )
        t.eq(
            Loc.resolve(
                Msg.new("event.source", { date = Msg.date({ year = 2024, month = 8, day = 12 }) }),
                "ko",
                s
            ),
            "NASA DONKI 기록, 2024년 8월 12일"
        )
        t.eq(Loc.formatDate({ year = 2025, month = 11, day = 3 }, "en", "short", s), "Nov 3")
        t.eq(Loc.formatDate({ year = 2025, month = 11, day = 3 }, "ko", "short", s), "11월 3일")
        t.eq(Loc.resolve(Msg.new("key.hold", { key = "E" }), "ko", s), "E 키를 길게 누르기")
        t.eq(
            Loc.resolve(
                Msg.new("mission_select.best_medal", { medal = Msg.new("medal.gold.name") }),
                "ko",
                s
            ),
            "최고 기록: 금메달"
        )
        t.eq(
            Loc.resolve(Msg.count("score.deduct.oxygen_rescue", 1, { points = 100 }), "en", s),
            "Needed an Oxygen rescue 1 time: -100"
        )
        t.eq(
            Loc.resolve("mission.c.site", "ko", s),
            "Nobile Rim 1",
            "착륙지 이름은 ko에서도 영어"
        )
        t.eq(
            Loc.resolve("settings.language.ko_name", "en", s),
            "한국어",
            "언어 이름은 자기 언어로"
        )
    end)

    -- 3) CSV 도구 ---------------------------------------------------------
    t.test("CSV 파서: 따옴표, 쉼표, CRLF, BOM, 빈 줄", function()
        local text = '\239\187\191a,b\r\n"x, y","say ""hi"""\r\n\r\nlast,""\n'
        local records, issues = Lib.parseCsv(text)
        t.eq(#issues, 0, "문제 없음")
        t.eq(#records, 3, "빈 줄은 건너뜀")
        t.eq(records[1].fields[1], "a", "BOM 제거")
        t.eq(records[2].fields[1], "x, y")
        t.eq(records[2].fields[2], 'say "hi"')
        t.eq(records[3].fields[2], "", "빈 따옴표 칸")
        t.eq(records[3].line, 4, "줄 번호")
    end)

    t.test("CSV 파서: 문법 오류", function()
        local _, a = Lib.parseCsv('k,"open\n')
        t.eq(issuesWith(a, "닫히지 않았습니다"), 1, "닫히지 않은 따옴표")
        local _, b = Lib.parseCsv('k,ab"c\n')
        t.eq(issuesWith(b, "칸 중간"), 1, "칸 중간 따옴표")
        local _, c = Lib.parseCsv('k,"ab"c\n')
        t.eq(issuesWith(c, "닫는 큰따옴표 뒤"), 1, "닫는 따옴표 뒤 글자")
    end)

    t.test("CSV 검사: 통과하는 행과 \\n 변환", function()
        local result = Lib.load(
            csv(
                'hud.a.one,"{count} thing",,"{count}",,\nhud.a.other,"{count} things","{count}개","{count}",,\nhud.b,"Line 1\\nLine 2","첫 줄\\n둘째 줄",,,\n'
            )
        )
        t.eq(#result.errors, 0, "오류 없음")
        t.eq(#result.warnings, 0, ".one 행의 ko 빈칸은 경고 아님")
        t.eq(result.rows[3].en, "Line 1\nLine 2", "\\n 은 줄바꿈")
    end)

    t.test("CSV 검사: 오류 규칙", function()
        local banned = utf8.char(0x2014)
        local cases = {
            { "머리글", "key,en,ko\nhud.a,A,가\n", "머리글은" },
            { "키 형식", csv("Hud.A,A,가,,,\n"), "키 형식" },
            { "점 하나 없는 키", csv("hud,A,가,,,\n"), "키 형식" },
            { "중복", csv("hud.a,A,가,,,\nhud.a,B,나,,,\n"), "중복 키" },
            { "en 빈칸", csv("hud.a,,가,,,\n"), "en이 비어" },
            {
                "언어 간 자리표시자",
                csv('hud.a,"{n} A","{m} 가","{n}",,\n'),
                "언어 간 자리표시자",
            },
            { "args 불일치", csv('hud.a,"{n} A","{n} 가","{m}",,\n'), "args 칸" },
            { "args 누락", csv('hud.a,"{n} A","{n} 가",,,\n'), "args 칸" },
            {
                ".other 없음",
                csv('hud.a.one,"{count} A",,"{count}",,\n'),
                ".other 가 없습니다",
            },
            {
                "기본 키와 복수형",
                csv('hud.a,A,가,,,\nhud.a.other,"{count} A","{count} 가","{count}",,\n'),
                "함께 둘 수 없습니다",
            },
            { "닫히지 않은 {", csv('hud.a,"A {n",가,,,\n'), "닫히지 않은 {" },
            { "짝 없는 }", csv('hud.a,"A }",가,,,\n'), "짝 없는 }" },
            {
                "자리표시자 이름",
                csv('hud.a,"A {Bad}","가 {Bad}",,,\n'),
                "이름이 잘못됨",
            },
            { "금지 문자", csv("hud.a,A " .. banned .. " B,가,,,\n"), "금지 문자 U+2014" },
            { "실제 줄바꿈", csv('hud.a,"A\nB",가,,,\n'), "실제 줄바꿈" },
            { "%d 폐지", csv('hud.a,"%d A",가,,,\n'), "폐지" },
            { "일반 키의 태그", csv('hud.a,"<b>A</b>",가,,,\n'), ".rich 키에서만" },
            {
                ".rich 키의 다른 태그",
                csv('hud.a.rich,"<i>A</i>",가,,,\n'),
                "허용하지 않는 태그",
            },
            { "<b> 짝", csv('hud.a.rich,"<b>A",가,,,\n'), "짝이 맞지 않습니다" },
            { "max_len 형식", csv("hud.a,A,가,,,abc\n"), "max_len은" },
            { "칸 수", csv("hud.a,A,가\n"), "칸이 3개" },
        }
        for _, case in cases do
            local result = Lib.load(case[2])
            t.truthy(issuesWith(result.errors, case[3]) >= 1, case[1] .. " (" .. case[3] .. ")")
        end
        t.eq(
            #Lib.load(csv('hud.a.rich,"<b>{n}</b>","<b>{n}</b>","{n}",,\n')).errors,
            0,
            ".rich 키의 <b>는 허용"
        )
        t.eq(
            #Lib.load(csv('hud.a,"{{x}} {n}","{{x}} {n}","{n}",,\n')).errors,
            0,
            "{{ }} 는 자리표시자가 아님"
        )
    end)

    t.test("CSV 검사: 경고 규칙", function()
        local cases = {
            { "ko 누락", csv("hud.a,A,,,,\n"), "ko 번역이 없습니다" },
            { "조사", csv('hud.a,"{name} came","{name}이 왔어요","{name}",,\n'), "조사" },
            { "max_len", csv("hud.a,Too long text,가,,,4\n"), "max_len 4" },
            { "모르는 도메인", csv("zzz.a,A,가,,,\n"), "목록에 없는 도메인" },
            { "앞뒤 공백", csv('hud.a," A",가,,,\n'), "공백" },
        }
        for _, case in cases do
            local result = Lib.load(case[2])
            t.eq(#result.errors, 0, case[1] .. " 오류 없음")
            t.truthy(issuesWith(result.warnings, case[3]) >= 1, case[1])
        end
        local ok = Lib.load(
            csv(
                'hud.a,"{name} came","{name} 님이 왔어요","{name}",,\nhud.b,"{count} d","{count}일","{count}",,\n'
            )
        )
        t.eq(#ok.warnings, 0, "님이, 일 같은 고정 글자는 경고 아님")
        t.eq(Lib.displayLength("{count} days"), 5 + Lib.PLACEHOLDER_WIDTH, "자리표시자 폭")
    end)

    t.test("CSV 생성물: Luau는 첫 줄 표시, 불러오면 같은 표", function()
        local result = Lib.load(csv('hud.b,"B ""q"" \\ x","나",,,\nhud.a,"Line\\nTwo",,,,\n'))
        t.eq(#result.errors, 0)
        local source = Lib.generateLuau(result.rows)
        t.eq(string.match(source, "^[^\n]+"), Lib.GENERATED_LINE, "첫 줄")
        local loaded = luau.load(source, { debugName = "generated" })()
        t.eq(loaded.count, 2)
        t.eq(loaded.strings["hud.a"].en, "Line\nTwo")
        t.eq(loaded.strings["hud.a"].ko, nil, "빈 ko는 빠진다")
        t.eq(loaded.strings["hud.b"].en, 'B "q" \\ x', "따옴표와 역슬래시 보존")
        local json = serde.decode("json", Lib.generateJson(result.rows))
        t.eq(json.strings["hud.a"].en, "Line\nTwo")
        t.eq(json.strings["hud.b"].ko, "나")
        t.eq(json.count, 2)
        t.eq(Lib.generateLuau(result.rows), source, "같은 입력이면 같은 출력")
    end)

    t.test("저장소: strings.csv는 오류와 경고가 없다", function()
        local result = Lib.load(fs.readFile(Lib.CSV_PATH))
        for _, issue in result.errors do
            print("        " .. Lib.formatIssue(issue))
        end
        for _, issue in result.warnings do
            print("        " .. Lib.formatIssue(issue))
        end
        t.eq(#result.errors, 0, "오류")
        t.eq(#result.warnings, 0, "경고")
        t.truthy(#result.rows >= 100, "행 100개 이상")
    end)

    t.test("저장소: 생성물이 CSV와 같다 (build --check와 같은 판정)", function()
        local result = Lib.load(fs.readFile(Lib.CSV_PATH))
        t.truthy(
            fs.readFile(Lib.LUAU_PATH) == Lib.generateLuau(result.rows),
            "Strings.luau가 오래됨: lune run tools/i18n/build.luau"
        )
        t.truthy(
            fs.readFile(Lib.JSON_PATH) == Lib.generateJson(result.rows),
            "strings.json이 오래됨: lune run tools/i18n/build.luau"
        )
        t.eq(Strings.count, #result.rows)
    end)

    t.test("저장소: 모든 행에 en, .one 밖의 행에 ko", function()
        local missing = {}
        for key, entry in Strings.strings do
            t.truthy(type(entry.en) == "string" and entry.en ~= "", key .. " en")
            local _, form = Lib.pluralParts(key)
            if form ~= "one" and (entry.ko == nil or entry.ko == "") then
                table.insert(missing, key)
            end
        end
        t.eq(table.concat(missing, ","), "", "ko 없는 행")
    end)

    -- 4) 소스 스캐너 ------------------------------------------------------
    t.test("CSV 검사: camelCase 자리표시자 허용 (Rules의 perDay)", function()
        local result = Lib.load(csv('hud.a,"{perDay} a day","하루 {perDay}","{perDay}",,\n'))
        t.eq(#result.errors, 0, "perDay 허용")
        t.eq(#result.warnings, 0)
        t.truthy(
            issuesWith(
                Lib.load(csv('hud.a,"{PerDay}","{PerDay}","{PerDay}",,\n')).errors,
                "이름이 잘못됨"
            ) >= 1,
            "대문자 시작은 거절"
        )
        t.eq(
            Loc.resolve(Msg.new("toast.panel.limit_today", { perDay = 1 }), "en", Strings.strings),
            "No more panels today (1 per day). Try again tomorrow."
        )
    end)

    t.test(
        "lint 키 판정: 필드, Msg 호출, domain.area.name 모양, 동적 키 제외",
        function()
            local source = table.concat({
                'local a = { signKey = "world.sign.lander", textKey = "world.rover.name", key = "fmt.plus" }',
                'local b = Msg.new("unit.percent", { n = 1 })',
                'buildPanel(frame, id, "facility.farm.name")',
                'local c = "facility." .. id .. ".name"',
                'local d = { file = "icon.png" }',
                'UI.msg(label, "hud.low")',
                'local e = "Assets.Kit.Rover"',
                'local f = "zzz.unknown.domain"',
            }, "\n")
            local found = {}
            for _, literal in Lib.scanLuau(source) do
                local key = Lib.keyUse(literal)
                if key then
                    table.insert(found, key)
                end
            end
            t.eq(
                table.concat(found, ","),
                "world.sign.lander,world.rover.name,fmt.plus,unit.percent,facility.farm.name,hud.low",
                "키로 보는 리터럴"
            )
        end
    )

    t.test("lint 스캐너: 로그 래퍼 warnOnce, safe 안은 로그", function()
        local source = table.concat({
            'warnOnce("k", "표시 " .. name .. "이 없어 만들지 않습니다")',
            'safe("착륙선", function() build() end)',
            'notify("보이는 문구")',
        }, "\n")
        local byText = {}
        for _, literal in Lib.scanLuau(source) do
            byText[literal.text] = literal
        end
        t.truthy(byText["표시 "] and byText["표시 "].inLog, "warnOnce 안")
        t.truthy(
            byText["이 없어 만들지 않습니다"]
                and byText["이 없어 만들지 않습니다"].inLog,
            "warnOnce 안 이어붙이기"
        )
        t.truthy(byText["착륙선"] and byText["착륙선"].inLog, "safe 이름표")
        t.truthy(
            byText["보이는 문구"] and not byText["보이는 문구"].inLog,
            "다른 함수는 로그 아님"
        )
    end)

    t.test("lint 스캐너: 주석, 로그 호출, 키 위치", function()
        local source = table.concat({
            '-- "주석 안 한글"',
            "--[[ 블록 주석 '한글' ]]",
            'warn(string.format("[X] %s 실패", y))',
            'print "직접 호출"',
            'local a = "보이는 문구"',
            'local m = Msg.new("hud.water.label", { n = 1 })',
            'local b = { key = "res.food.name", other = "x" }',
            "local c = [[긴 문자열]]",
            'local d = "따옴표 \\" 안 한글"',
            'error(("%s 오류"):format(1))',
        }, "\n")
        local literals = Lib.scanLuau(source)
        local byText = {}
        for _, literal in literals do
            byText[literal.text] = literal
        end
        t.eq(byText["주석 안 한글"], nil, "줄 주석 건너뜀")
        t.eq(byText["한글"], nil, "블록 주석 건너뜀")
        t.truthy(
            byText["[X] %s 실패"] and byText["[X] %s 실패"].inLog,
            "warn 안의 string.format"
        )
        t.truthy(byText["직접 호출"] and byText["직접 호출"].inLog, "괄호 없는 print")
        t.truthy(
            byText["보이는 문구"] and not byText["보이는 문구"].inLog,
            "일반 리터럴"
        )
        t.eq(byText["보이는 문구"].line, 5, "줄 번호")
        local m = byText["hud.water.label"]
        t.truthy(m and m.callee == "Msg.new" and m.argIndex == 1, "Msg.new 첫 인자")
        t.eq(byText["res.food.name"].field, "key", "key 필드")
        t.eq(byText["x"].field, "other")
        t.truthy(byText["긴 문자열"] ~= nil, "긴 문자열")
        t.truthy(byText['따옴표 \\" 안 한글'] ~= nil, "이스케이프된 따옴표")
        t.truthy(byText["%s 오류"] and byText["%s 오류"].inLog, "error 안의 메서드 호출")
        t.truthy(Lib.hasHangul("가a"), "한글 판정")
        t.falsy(Lib.hasHangul("abc"), "영문")
    end)

    -- 5) PlayerPrefs ------------------------------------------------------
    local PREFS = "src/server/PlayerPrefs.luau"

    t.test("PlayerPrefs: 기본 en, 저장된 ko를 읽어 속성으로 복제", function()
        local world = makeWorld()
        world.store.data["u_1"] = { lang = "ko", v = 1 }
        local prefs = world.load(PREFS)
        prefs.init()
        t.eq(world.store.name, "FrontierPrefs", "DataStore 이름")
        t.eq(prefs.status(), "ok")
        local p = world.join(1)
        t.eq(p:GetAttribute("Lang"), "en", "들어오자마자 기본 en")
        world.advance(0.5)
        t.eq(p:GetAttribute("Lang"), "ko", "읽은 뒤 ko")
        t.eq(prefs.getLanguage(p), "ko")
        t.eq(#world.errors, 0, table.concat(world.errors, "; "))
    end)

    t.test("PlayerPrefs: 화이트리스트와 1초 제한", function()
        local world = makeWorld()
        local prefs = world.load(PREFS)
        prefs.init()
        local p = world.join(2)
        world.advance(0.5)
        local fire = function(code)
            world.remote.OnServerEvent:Fire(p, code)
        end
        fire("ko")
        t.eq(p:GetAttribute("Lang"), "ko", "첫 요청 반영")
        world.advance(0.5)
        fire("en")
        t.eq(p:GetAttribute("Lang"), "ko", "1초 안의 요청은 버림")
        world.advance(0.6)
        fire("fr")
        t.eq(p:GetAttribute("Lang"), "ko", "지원하지 않는 언어")
        world.advance(1.1)
        fire(5)
        t.eq(p:GetAttribute("Lang"), "ko", "문자열이 아님")
        world.advance(1.1)
        fire("EN")
        t.eq(p:GetAttribute("Lang"), "en", "대문자도 정리해서 받음")
        t.eq(prefs.setLanguage(p, "xx"), false, "서버 쪽 잘못된 코드")
        t.eq(prefs.setLanguage(p, "ko"), true, "서버 쪽 변경은 제한 없음")
        t.eq(p:GetAttribute("Lang"), "ko")
    end)

    t.test("PlayerPrefs: 저장은 디바운스 한 번, 마지막 값", function()
        local world = makeWorld()
        local prefs = world.load(PREFS)
        prefs.init()
        local p = world.join(3)
        world.advance(0.5)
        world.remote.OnServerEvent:Fire(p, "ko")
        world.advance(1.5)
        world.remote.OnServerEvent:Fire(p, "en")
        world.advance(1.5)
        world.remote.OnServerEvent:Fire(p, "ko")
        world.advance(prefs.SAVE_DELAY - 1)
        t.eq(world.store.sets, 0, "조용해지기 전에는 저장하지 않음")
        world.advance(2)
        t.eq(world.store.sets, 1, "한 번만 저장")
        local entry = world.store.setLog[1]
        t.eq(entry.key, "u_3")
        t.eq(entry.value.lang, "ko", "마지막 값")
        t.eq(entry.value.v, 1, "형식 버전")
        t.eq(entry.userIds and entry.userIds[1], 3, "userIds")
        world.advance(prefs.SAVE_DELAY * 2)
        t.eq(world.store.sets, 1, "변경이 없으면 더 저장하지 않음")
    end)

    t.test("PlayerPrefs: 읽기 전에 고른 언어가 저장된 값보다 우선", function()
        local world = makeWorld()
        world.store.latency = 1
        world.store.data["u_4"] = { lang = "en", v = 1 }
        local prefs = world.load(PREFS)
        prefs.init()
        local p = world.join(4)
        world.advance(0.2)
        world.remote.OnServerEvent:Fire(p, "ko")
        world.advance(2)
        t.eq(p:GetAttribute("Lang"), "ko", "읽은 en으로 덮지 않음")
    end)

    t.test("PlayerPrefs: 나갈 때 바로 저장, 예약된 저장은 취소", function()
        local world = makeWorld()
        local prefs = world.load(PREFS)
        prefs.init()
        local p = world.join(5)
        world.advance(0.5)
        world.remote.OnServerEvent:Fire(p, "ko")
        world.advance(1)
        world.leave(p)
        world.advance(0.5)
        t.eq(world.store.sets, 1, "나갈 때 저장")
        t.eq(world.store.data["u_5"].lang, "ko")
        world.advance(prefs.SAVE_DELAY * 2)
        t.eq(world.store.sets, 1, "디바운스 저장이 또 일어나지 않음")
        t.eq(prefs.getLanguage(p), "en", "나간 플레이어는 기본값")
    end)

    t.test("PlayerPrefs: BindToClose에서 남은 변경을 저장하고 기다린다", function()
        local world = makeWorld()
        world.store.latency = 0.5
        local prefs = world.load(PREFS)
        prefs.init()
        local a = world.join(6)
        local b = world.join(7)
        world.advance(1)
        world.remote.OnServerEvent:Fire(a, "ko")
        world.remote.OnServerEvent:Fire(b, "ko")
        t.eq(#world.closeHandlers, 1, "BindToClose 등록")
        local done = false
        world.task.spawn(function()
            world.closeHandlers[1]()
            done = true
        end)
        t.falsy(done, "저장이 끝날 때까지 돌아오지 않음")
        world.advance(1)
        t.truthy(done, "저장 뒤 끝남")
        t.eq(world.store.sets, 2, "두 명 모두 저장")
        t.eq(world.store.data["u_6"].lang, "ko")
        t.eq(world.store.data["u_7"].lang, "ko")
    end)

    t.test(
        "PlayerPrefs: DataStore 실패면 메모리로 기억 (같은 서버 재입장)",
        function()
            local world = makeWorld()
            world.store.fail = true
            local prefs = world.load(PREFS)
            prefs.init()
            local p = world.join(8)
            world.advance(prefs.RETRY_DELAY + 1)
            t.eq(prefs.status(), "offline", "두 번 실패하면 offline")
            t.truthy(#world.warnings >= 1, "출력 창 경고")
            world.remote.OnServerEvent:Fire(p, "ko")
            t.eq(p:GetAttribute("Lang"), "ko", "저장소 없이도 바뀜")
            world.leave(p)
            world.advance(1)
            local again = world.join(8)
            t.eq(again:GetAttribute("Lang"), "ko", "다시 들어오면 메모리 값")
            t.eq(#world.errors, 0, table.concat(world.errors, "; "))
        end
    )

    t.test("PlayerPrefs: DataStore 서비스가 없으면 처음부터 offline", function()
        local world = makeWorld()
        world.services.DataStoreService = nil
        local prefs = world.load(PREFS)
        prefs.init()
        prefs.init() -- 두 번 불러도 연결은 한 번
        t.eq(prefs.status(), "offline")
        t.eq(#world.remote.OnServerEvent.handlers, 1, "Remote 연결 한 번")
        local p = world.join(9)
        world.advance(0.5)
        t.eq(p:GetAttribute("Lang"), "en")
        world.remote.OnServerEvent:Fire(p, "ko")
        t.eq(p:GetAttribute("Lang"), "ko")
        t.eq(#world.errors, 0, table.concat(world.errors, "; "))
    end)

    -- 6) Localizer --------------------------------------------------------
    local LOCALIZER = "src/client/Localizer.luau"

    -- 서버 흉내: FireServer를 받으면 0.1초 뒤 속성을 바꾼다 (echo가 false면 무시)
    local function clientWorld(echo: boolean)
        local world = makeWorld()
        local player = world.player(10)
        player:SetAttribute("Lang", "en")
        world.players.LocalPlayer = player
        world.onFireServer = function(code)
            if echo then
                world.task.delay(0.1, function()
                    player:SetAttribute("Lang", code)
                end)
            end
        end
        return world, player
    end

    t.test(
        "Localizer: bind는 그리고 AutoLocalize를 끄며 언어가 바뀌면 다시 그린다",
        function()
            local world = clientWorld(true)
            local L = world.load(LOCALIZER)
            local label = fakeLabel()
            local seen = {}
            L.changed:Connect(function(code)
                table.insert(seen, code)
            end)
            t.eq(L.bind(label, { key = "res.energy.name" }), label, "라벨을 돌려줌")
            t.eq(label.Text, "Energy")
            t.eq(label.AutoLocalize, false, "Roblox 자동 번역 끔 (Q38)")
            t.eq(L.get(), "en")
            t.truthy(L.set("ko"))
            t.eq(label.Text, "에너지", "바로 다시 그림")
            t.eq(table.concat(seen, ","), "ko", "changed")
            t.eq(table.concat(world.remote.sent, ","), "ko", "SetLanguage 한 번")
            t.falsy(L.set("fr"), "지원하지 않는 언어")
            t.eq(L.get(), "ko")
            t.eq(#world.errors, 0, table.concat(world.errors, "; "))
        end
    )

    t.test(
        "Localizer: 1.1초 간격으로 보내고 그 사이 선택은 마지막 값만",
        function()
            local world = clientWorld(true)
            local L = world.load(LOCALIZER)
            L.set("ko")
            world.advance(0.2)
            L.set("en")
            world.advance(0.2)
            L.set("ko")
            world.advance(1)
            t.eq(
                table.concat(world.remote.sent, ","),
                "ko",
                "서버가 이미 ko면 다시 보내지 않음"
            )
            world.advance(0.5)
            L.set("en")
            world.advance(0.3)
            L.set("ko")
            world.advance(0.2)
            L.set("en")
            world.advance(2)
            t.eq(table.concat(world.remote.sent, ","), "ko,en", "마지막 en만 보냄")
            t.eq(L.get(), "en")
            t.eq(world.players.LocalPlayer:GetAttribute("Lang"), "en")
        end
    )

    t.test("Localizer: 서버가 바꾼 속성(DataStore 값)을 따른다", function()
        local world, player = clientWorld(true)
        local L = world.load(LOCALIZER)
        local label = L.bind(fakeLabel(), Msg.count("unit.day", 2))
        t.eq(label.Text, "2 days")
        player:SetAttribute("Lang", "ko")
        t.eq(L.get(), "ko")
        t.eq(label.Text, "2일")
    end)

    t.test(
        "Localizer: 응답이 없으면 IN_FLIGHT_TIMEOUT 뒤 서버 값으로 돌아간다",
        function()
            local world = clientWorld(false)
            local L = world.load(LOCALIZER)
            L.set("ko")
            t.eq(L.get(), "ko", "낙관적 변경")
            world.advance(L.IN_FLIGHT_TIMEOUT - 1)
            t.eq(L.get(), "ko", "기다리는 중")
            world.advance(1.5)
            t.eq(L.get(), "en", "서버 값 en으로")
        end
    )

    t.test(
        "Localizer: 같은 Msg로 다시 bind하면 그리지 않고, nil이면 푼다",
        function()
            local world = clientWorld(true)
            local L = world.load(LOCALIZER)
            local label = L.bind(fakeLabel(), Msg.new("res.water.name"))
            label.Text = "x"
            L.bind(label, Msg.new("res.water.name"))
            t.eq(label.Text, "x", "같은 Msg는 건너뜀")
            L.bind(label, Msg.new("res.food.name"))
            t.eq(label.Text, "Food", "다른 Msg는 다시 그림")
            L.bind(label, nil)
            L.set("ko")
            t.eq(label.Text, "Food", "푼 뒤에는 그대로")
            local rich = L.bind(fakeLabel(), { key = "hud.sample.rich" })
            t.eq(rich.RichText, true, ".rich 키면 RichText")
            t.eq(rich.Text, "hud.sample.rich", "없는 키는 키 그대로")
        end
    )

    t.test(
        "Localizer: {key_*} 값은 클라이언트가 채우고 setKeyLabels로 바꾸면 다시 그린다",
        function()
            local world = clientWorld(true)
            local L = world.load(LOCALIZER)
            t.eq(
                L.text(Msg.new("toast.rover.first_board")),
                "You're driving! Hold Shift to go faster.",
                "키보드 기본값"
            )
            local label = L.bind(fakeLabel(), Msg.new("toast.rover.broken_manual"))
            t.eq(label.Text, "The rover is broken! Go to it and fix it (R).")
            L.setKeyLabels({ key_repair = { key = "key.touch.tap" } })
            t.eq(
                label.Text,
                "The rover is broken! Go to it and fix it (Tap).",
                "터치 라벨은 Msg, 바로 다시 그림"
            )
            L.set("ko")
            t.eq(label.Text, "로버가 고장 났어요! 가까이 가서 고치세요 (탭).")
            t.eq(
                L.text(Msg.new("toast.rover.first_board", { key_boost = "X" })),
                "운전 시작! X 키를 길게 누르면 더 빨리 가요.",
                "Msg 값이 이긴다"
            )
            t.eq(
                L.text(Msg.new("result.medal.earned", { medal = Msg.new("medal.gold.name") })),
                "금메달 획득!",
                "키 라벨이 없는 문구는 그대로"
            )
        end
    )

    t.test("Localizer: text와 date, bindTextKeys", function()
        local world = clientWorld(true)
        local L = world.load(LOCALIZER)
        t.eq(L.text(nil), "")
        t.eq(L.text({ bad = true } :: any), "", "Msg 형식이 아니면 빈 문자열")
        t.eq(L.text("res.oxygen.name"), "Oxygen")
        t.eq(
            L.text(Msg.new("result.medal.earned", { medal = Msg.new("medal.silver.name") })),
            "You got the Silver Medal!"
        )
        t.eq(L.date({ year = 2024, month = 3, day = 9 }, "long"), "March 9, 2024")
        local keyed = fakeLabel()
        keyed:SetAttribute("TextKey", "title.about.button")
        local plain = fakeLabel("TextButton")
        local root = {
            GetDescendants = function()
                return {
                    keyed,
                    plain,
                    {
                        IsA = function()
                            return false
                        end,
                    },
                }
            end,
        }
        t.eq(L.bindTextKeys(root), 1, "TextKey 하나")
        t.eq(keyed.Text, "About the data")
        t.eq(keyed.AutoLocalize, false)
        t.eq(plain.AutoLocalize, false, "TextKey 없는 글자 요소도 자동 번역 끔")
        L.set("ko")
        t.eq(keyed.Text, "데이터 출처")
    end)

    -- 7) Rules가 실제로 내는 Msg ----------------------------------------
    -- 봇이 여러 판을 도는 동안 Rules의 모든 공개 함수를 감싸 반환값 안의 Msg를 모은다.
    -- 모은 Msg를 en, ko로 해석해 키가 표에 있고 {name} 자리표시자가 남지 않는지 본다 (키 이름과 값 이름이 맞는지 확인).
    t.test("Rules 연동: 봇 플레이 중 나온 모든 Msg가 en, ko로 해석된다", function()
        if not fs.isFile("src/shared/Rules.luau") or not fs.isFile("tests/bot_v2.luau") then
            print("        건너뜀: Rules.luau 또는 bot_v2.luau 없음")
            return
        end
        local Rules = require("../src/shared/Rules")
        local MissionConfig = require("../src/shared/MissionConfig")
        local Bot = require("./bot_v2")

        local samples: { [string]: { any } } = {}
        local total = 0
        local function add(m: any)
            total += 1
            local list = samples[m.key]
            if not list then
                list = {}
                samples[m.key] = list
            end
            if #list < 6 then
                table.insert(list, m)
            end
        end
        local function collect(value: any, depth: number)
            if type(value) ~= "table" or depth > 2 then
                return
            end
            if Msg.isMsg(value) then
                add(value)
                return
            end
            for _, field in value do
                if type(field) == "table" then
                    if Msg.isMsg(field) then
                        add(field)
                    elseif depth < 2 then
                        collect(field, depth + 1)
                    end
                end
            end
        end

        local originals = {}
        for name, fn in Rules do
            if type(fn) == "function" then
                originals[name] = fn
                Rules[name] = function(...)
                    local results = table.pack(fn(...))
                    for i = 1, results.n do
                        collect(results[i], 0)
                    end
                    return table.unpack(results, 1, results.n)
                end
            end
        end
        local ok, err = pcall(function()
            for seed = 1, 5 do
                for _, profile in { "human", "semi", "multi_first" } do
                    Bot.simulate(
                        MissionConfig,
                        profile,
                        Bot.weatherFixtures[1 + (seed - 1) % #Bot.weatherFixtures],
                        seed
                    )
                end
            end
            Bot.simulate(MissionConfig, "perfect", Bot.weatherFixtures[1], 1)
        end)
        for name, fn in originals do
            Rules[name] = fn
        end
        t.truthy(ok, "봇 실행: " .. tostring(err))

        local function nestedKeysExist(m: any, lang: string, path: string)
            local template = Loc.lookup(Strings.strings, m.key, lang, m.args)
            t.truthy(template ~= nil, path .. " 키 없음 " .. m.key)
            for name, value in m.args or {} do
                if type(value) == "table" then
                    nestedKeysExist(value, lang, path .. "." .. name)
                end
            end
        end
        local keys = 0
        for key, list in samples do
            keys += 1
            for _, m in list do
                for _, lang in { "en", "ko" } do
                    nestedKeysExist(m, lang, key)
                    local text = Loc.resolve(m, lang, Strings.strings)
                    t.falsy(
                        string.find(text, "{[%a_][%w_]*}"),
                        lang .. " 자리표시자 남음: " .. key .. " -> " .. text
                    )
                end
            end
        end
        print(string.format("        Rules Msg %d개, 서로 다른 키 %d개 확인", total, keys))
        t.truthy(keys >= 25, "키 25개 이상 관찰")
    end)

    t.test("Rules 연동: 새 키 예시 (값 이름이 Rules와 같다)", function()
        local s = Strings.strings
        local farm = Msg.new("facility.farm.name")
        t.eq(
            Loc.resolve(
                Msg.count("toast.build.started", 3, { facility = farm, id = "farm1" }),
                "en",
                s
            ),
            "Work started on Greenhouse! Ready in 3 days."
        )
        t.eq(
            Loc.resolve(
                Msg.count("toast.build.started", 1, { facility = farm, id = "farm1" }),
                "ko",
                s
            ),
            "그린하우스 작업 시작! 1일 뒤 완료"
        )
        t.eq(
            Loc.resolve(
                Msg.count(
                    "toast.rover.dispatched",
                    2,
                    { site = Msg.new("map.ice.label", { n = 4 }), energy = 9 }
                ),
                "en",
                s
            ),
            "Rover sent to Ice Site 4! Back in about 2 days. Energy -9"
        )
        t.eq(
            Loc.resolve(
                Msg.count(
                    "toast.rover.dispatched",
                    2,
                    { site = Msg.new("map.ice.label", { n = 4 }), energy = 9 }
                ),
                "ko",
                s
            ),
            "로버 출발! 얼음 후보지 4까지 왕복 약 2일, 에너지 -9",
            "중첩 지점 이름, 받침과 상관없는 조사"
        )
        t.eq(
            Loc.resolve(Msg.count("banner.shortage.both", 1), "en", s),
            "Water and Food are out! Fix it within 1 day or the mission ends."
        )
        t.eq(
            Loc.resolve(Msg.new("toast.oxygen.rescued", { points = 100 }), "en", s),
            "Out of Oxygen! You were brought back to the Airlock.",
            "점수는 숨김 (Q4)"
        )
        t.eq(
            Loc.resolve(Msg.new("toast.pipe.locked", { done = 2, need = 5 }), "ko", s),
            "물을 5번 내리면 물 파이프가 열려요 (2 / 5)."
        )
    end)
end
