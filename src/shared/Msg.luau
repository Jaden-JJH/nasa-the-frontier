--!strict
-- 화면 문구 메시지 (docs/I18N_PLAN.md 4.5). 서버와 shared 규칙은 문장을 만들지 않고 Msg(키 + 값)만 보낸다.
-- 번역은 클라이언트 Localizer(내부적으로 Shared.Loc)만 한다. Roblox API를 쓰지 않는다 (Lune 테스트 대상).
-- 웹판 i18n/loc.js의 msg, msgCount, msgDate, msgDateFromTime, msgList, isMsg, equals와 규칙이 같다.
--
-- 값 종류
-- - string: 번역하지 않는 값 그대로 (플레이어 이름 등)
-- - number: Loc.formatNumber 규칙으로 표시 (정수는 그대로, 소수는 둘째 자리까지 반올림)
-- - boolean: "true" / "false"
-- - Msg: 같은 언어로 먼저 해석한 뒤 넣는다 (중첩, 깊이 제한 Loc.MAX_DEPTH)
-- args는 복사하지 않는다. 보낸 뒤에 고치지 않는다.

export type ArgValue = string | number | boolean | Msg
export type Args = { [string]: ArgValue }
export type Msg = { key: string, args: Args? }
export type DateParts = { year: number, month: number, day: number }
export type DateStyle = "short" | "long"

local Msg = {}

Msg.MAX_DEPTH = 10 -- Loc.MAX_DEPTH와 같은 값
Msg.MAX_KEY_LENGTH = 200

-- 기본 생성자
function Msg.new(key: string, args: Args?): Msg
    return { key = key, args = args }
end

-- 복수형 메시지. args를 얕게 복사하고 count를 넣는다 (key.one / key.other 중 고른다)
function Msg.count(key: string, count: number, args: Args?): Msg
    local copy: Args = {}
    if args then
        for name, value in args do
            copy[name] = value
        end
    end
    copy.count = count
    return { key = key, args = copy }
end

-- 날짜 메시지 (fmt.date.short 또는 fmt.date.long). 템플릿에 year, month, day, month_name, month_short를 넘긴다.
-- 웹판, Loc.formatDate와 같은 구조여야 한다.
function Msg.date(date: DateParts, style: DateStyle?): Msg
    local month = date.month
    local monthText = if type(month) == "number"
            and month % 1 == 0
            and math.abs(month) < 1e15
        then string.format("%d", month)
        else "?"
    return {
        key = "fmt.date." .. (style or "long"),
        args = {
            year = date.year,
            month = month,
            day = date.day,
            month_name = { key = "date.month." .. monthText },
            month_short = { key = "date.month_short." .. monthText },
        },
    }
end

-- os.time() 값을 UTC 날짜 메시지로 (v1의 한국 시간 고정은 폐지, I18N_PLAN 4.4)
function Msg.dateFromTime(unixSeconds: number, style: DateStyle?): Msg
    local t = os.date("!*t", math.floor(unixSeconds))
    return Msg.date({ year = t.year, month = t.month, day = t.day }, style)
end

-- 목록 값 (fmt.list.*). 0개면 "", 1개면 그 값, 2개 이상이면 중첩 Msg. 결과는 다른 Msg의 값으로 쓴다.
-- 예: Msg.new("result.crew", { names = Msg.list({ "Mia", "Leo", "Sam" }) })
function Msg.list(items: { ArgValue }): ArgValue
    local n = #items
    if n == 0 then
        return ""
    elseif n == 1 then
        return items[1]
    elseif n == 2 then
        return { key = "fmt.list.two", args = { a = items[1], b = items[2] } }
    end
    local acc: Msg = { key = "fmt.list.end", args = { a = items[n - 1], b = items[n] } }
    for i = n - 2, 2, -1 do
        acc = { key = "fmt.list.middle", args = { a = items[i], b = acc } }
    end
    return { key = "fmt.list.start", args = { a = items[1], b = acc } }
end

local function isMsgAt(value: any, depth: number): boolean
    if type(value) ~= "table" then
        return false
    end
    local key = value.key
    if type(key) ~= "string" or key == "" or #key > Msg.MAX_KEY_LENGTH then
        return false
    end
    for field in value do
        if field ~= "key" and field ~= "args" then
            return false
        end
    end
    local args = value.args
    if args == nil then
        return true
    end
    if type(args) ~= "table" then
        return false
    end
    for name, arg in args do
        if type(name) ~= "string" then
            return false
        end
        local kind = type(arg)
        if kind == "table" then
            if depth >= Msg.MAX_DEPTH or not isMsgAt(arg, depth + 1) then
                return false
            end
        elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
            return false
        end
    end
    return true
end

-- 형식 검사 (원격 이벤트로 받은 값 검증용). key는 비어 있지 않은 문자열, args는 문자열 키 표
function Msg.isMsg(value: any): boolean
    return isMsgAt(value, 0)
end

local function argsEqual(a: any, b: any): boolean
    local left = if type(a) == "table" then a else {}
    local right = if type(b) == "table" then b else {}
    for name, value in left do
        if not Msg.equals(value, right[name]) then
            return false
        end
    end
    for name in right do
        if left[name] == nil then
            return false
        end
    end
    return true
end

-- 키와 값이 모두 같으면 true (다시 그리기 건너뛰기용, I18N_PLAN 4.6). args가 nil과 빈 표는 같다고 본다
function Msg.equals(a: any, b: any): boolean
    if type(a) == "table" and type(b) == "table" then
        return a.key == b.key and argsEqual(a.args, b.args)
    end
    return a == b
end

return Msg
