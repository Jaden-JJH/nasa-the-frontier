--!strict
-- 다국어 해석기 (docs/I18N_PLAN.md 4.4). 순수 모듈, Roblox API를 쓰지 않는다 (Lune 테스트 대상).
-- 클라이언트는 Localizer를 통해서만 쓴다. 서버는 해석하지 않는다.
-- 웹판 i18n/loc.js와 규칙이 똑같아야 하며, 둘 다 i18n/golden.json으로 검사한다. 규칙을 바꾸면 세 곳을 같이 고친다.
--
-- 규칙
-- 1. 자리표시자 {name}(영문, 숫자, 밑줄). {{ 는 {, }} 는 }. 값이 없으면 {name} 을 그대로 둔다.
-- 2. 복수형: args.count가 숫자면 en은 count == 1일 때 key.one, 그 밖은 key.other. ko(와 다른 언어)는 항상 other.
--    찾는 순서(언어마다): count가 숫자면 key.<형태>, key.other, key / 아니면 key, key.other.
-- 3. 대체: 요청 언어 -> en -> 키 문자열 그대로. 빈 칸은 없는 것으로 본다. en으로 대체되면 en 복수형 규칙을 쓴다.
-- 4. 값: 문자열은 그대로, 숫자는 formatNumber, 불리언은 "true"/"false", Msg는 같은 요청 언어로 먼저 해석(중첩).
--    깊이가 MAX_DEPTH를 넘으면 그 Msg의 키를 넣는다.
-- 5. .rich 마디가 있는 키만 <b></b>를 쓴다. 그 템플릿에 넣는 값은 escape한다(중첩 Msg가 .rich면 그대로).
-- 6. 숫자: 정수는 그대로, 소수는 둘째 자리까지 반올림(floor(|n| * 100 + 0.5))하고 끝 0을 지운다.
--    NaN, 무한대, 절댓값 1e15 이상은 "?".
-- 7. 날짜: fmt.date.<style> 템플릿에 year, month, day, month_name(date.month.N), month_short(date.month_short.N).

export type Args = { [string]: any }
export type Msg = { key: string, args: Args? }
export type Entry = { [string]: string? }
export type StringTable = { [string]: Entry }
export type DateParts = { year: number, month: number, day: number }

local Loc = {}

Loc.SUPPORTED = { "en", "ko" }
Loc.DEFAULT = "en"
Loc.FALLBACK = "en"
Loc.MAX_DEPTH = 10

local supported: { [string]: boolean } = {}
for _, code in Loc.SUPPORTED do
    supported[code] = true
end

local EMPTY: StringTable = {}

-- 지원 언어 코드로 정리. 아니면 nil (서버 화이트리스트와 같은 판정)
function Loc.normalize(code: any): string?
    if type(code) ~= "string" then
        return nil
    end
    local lower = string.lower(code)
    if supported[lower] then
        return lower
    end
    return nil
end

function Loc.pluralForm(lang: string, count: number): string
    if lang == "en" and count == 1 then
        return "one"
    end
    return "other"
end

function Loc.formatNumber(n: number): string
    if type(n) ~= "number" or n ~= n or math.abs(n) >= 1e15 then
        return "?"
    end
    if n == math.floor(n) then
        return string.format("%d", n)
    end
    local rounded = math.floor(math.abs(n) * 100 + 0.5)
    local whole = rounded // 100
    local frac = rounded % 100
    local text = string.format("%d", whole)
    if frac ~= 0 then
        if frac % 10 == 0 then
            text ..= "." .. string.format("%d", frac // 10)
        else
            text ..= "." .. string.format("%02d", frac)
        end
    end
    if n < 0 and rounded > 0 then
        text = "-" .. text
    end
    return text
end

local ESCAPES = {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&apos;",
}

-- RichText에 넣을 값 이스케이프
function Loc.escape(text: string): string
    return (string.gsub(text, "[&<>\"']", ESCAPES))
end

function Loc.isRich(key: string): boolean
    return string.find("." .. key .. ".", ".rich.", 1, true) ~= nil
end

local function cell(strings: StringTable, key: string, lang: string): string?
    local entry = strings[key]
    if type(entry) ~= "table" then
        return nil
    end
    local text = entry[lang]
    if type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

-- 템플릿 찾기. 반환: 템플릿, 실제 키 (없으면 nil, nil)
function Loc.lookup(
    strings: StringTable,
    key: string,
    lang: string,
    args: Args?
): (string?, string?)
    local count = if args then args.count else nil
    local chain = if lang == Loc.FALLBACK then { lang } else { lang, Loc.FALLBACK }
    for _, l in chain do
        local candidates
        if type(count) == "number" then
            candidates = { key .. "." .. Loc.pluralForm(l, count), key .. ".other", key }
        else
            candidates = { key, key .. ".other" }
        end
        for _, candidate in candidates do
            local text = cell(strings, candidate, l)
            if text then
                return text, candidate
            end
        end
    end
    return nil, nil
end

local resolveAt: (msg: Msg, lang: string, strings: StringTable, depth: number) -> string

local function valueText(
    value: any,
    lang: string,
    strings: StringTable,
    rich: boolean,
    depth: number
): string?
    local kind = type(value)
    if kind == "string" then
        return if rich then Loc.escape(value) else value
    elseif kind == "number" then
        return Loc.formatNumber(value)
    elseif kind == "boolean" then
        return if value then "true" else "false"
    elseif kind == "table" and type(value.key) == "string" then
        local text = resolveAt(value, lang, strings, depth + 1)
        if rich and not Loc.isRich(value.key) then
            return Loc.escape(text)
        end
        return text
    end
    return nil
end

local function interpolateAt(
    template: string,
    args: Args?,
    lang: string,
    strings: StringTable,
    rich: boolean,
    depth: number
): string
    local out = {}
    local n = #template
    local i = 1
    while i <= n do
        local c = string.sub(template, i, i)
        if c == "{" then
            if string.sub(template, i + 1, i + 1) == "{" then
                table.insert(out, "{")
                i += 2
                continue
            end
            local close = string.find(template, "}", i + 1, true)
            local name = if close then string.sub(template, i + 1, close - 1) else ""
            if close and string.match(name, "^[%w_]+$") then
                local value = if args then args[name] else nil
                local text = if value ~= nil
                    then valueText(value, lang, strings, rich, depth)
                    else nil
                table.insert(out, text or ("{" .. name .. "}"))
                i = close + 1
                continue
            end
            table.insert(out, "{")
            i += 1
        elseif c == "}" then
            table.insert(out, "}")
            if string.sub(template, i + 1, i + 1) == "}" then
                i += 2
            else
                i += 1
            end
        else
            -- 다음 중괄호까지 한 번에 붙인다
            local nextBrace = string.find(template, "[{}]", i)
            local stop = if nextBrace then nextBrace - 1 else n
            table.insert(out, string.sub(template, i, stop))
            i = stop + 1
        end
    end
    return table.concat(out)
end

resolveAt = function(msg: Msg, lang: string, strings: StringTable, depth: number): string
    if depth > Loc.MAX_DEPTH then
        return msg.key
    end
    local template = Loc.lookup(strings, msg.key, lang, msg.args)
    if template == nil then
        return msg.key
    end
    return interpolateAt(template, msg.args, lang, strings, Loc.isRich(msg.key), depth)
end

-- 템플릿에 값 넣기 (strings는 값 안의 중첩 Msg를 해석할 때만 필요)
function Loc.interpolate(
    template: string,
    args: Args?,
    lang: string,
    strings: StringTable?,
    rich: boolean?
): string
    return interpolateAt(template, args, lang, strings or EMPTY, rich == true, 0)
end

-- Msg(또는 키 문자열)를 lang으로 해석한다. 잘못된 msg는 "".
function Loc.resolve(msg: Msg | string, lang: string, strings: StringTable): string
    local target: Msg
    if type(msg) == "string" then
        target = { key = msg }
    elseif type(msg) == "table" and type(msg.key) == "string" then
        target = msg
    else
        return ""
    end
    local code = if type(lang) == "string" then lang else Loc.DEFAULT
    return resolveAt(target, code, strings or EMPTY, 0)
end

-- 날짜 { year, month, day }를 fmt.date.short 또는 fmt.date.long으로 (Msg.date와 같은 구조)
function Loc.formatDate(date: DateParts, lang: string, style: string?, strings: StringTable): string
    local month = date.month
    local monthText = if type(month) == "number"
            and month % 1 == 0
            and math.abs(month) < 1e15
        then string.format("%d", month)
        else "?"
    return Loc.resolve({
        key = "fmt.date." .. (style or "long"),
        args = {
            year = date.year,
            month = date.month,
            day = date.day,
            month_name = { key = "date.month." .. monthText },
            month_short = { key = "date.month_short." .. monthText },
        },
    }, lang, strings)
end

return Loc
