--!strict
-- 클라이언트 다국어 창구 (docs/I18N_PLAN.md 4.6). 화면 문구는 모두 여기서 해석한다.
-- - get(): 지금 언어 코드. 서버가 복제한 LocalPlayer 속성 "Lang"을 따른다 (없으면 en).
-- - set(code): 바로 화면을 바꾸고(낙관적) SetLanguage를 보낸다. 서버 제한(1초에 1번)에 걸리지 않게
--   SEND_INTERVAL 간격으로 보내고, 그 사이에 여러 번 바꾸면 마지막 값만 보낸다.
--   보낸 값의 응답(속성 변경)을 기다리는 동안 다른 속성 값은 무시하고, IN_FLIGHT_TIMEOUT초 안에 안 오면 서버 값을 따른다.
-- - changed: 언어가 바뀌면 (code)로 발생.
-- - text(msg): Msg 또는 키 문자열을 지금 언어로. 잘못된 값은 "".
-- - bind(guiObject, msg): 등록해 두면 언어가 바뀔 때 다시 그린다. 같은 Msg로 다시 bind하면 그리지 않는다.
--   등록 표는 약한 키 표라 지운 라벨은 따로 풀지 않아도 된다. AutoLocalize를 끈다(Q38, Roblox 자동 번역 금지).
--   키에 .rich 마디가 있으면 RichText를 켠다.
-- - bindTextKeys(root): 지원이 만든 화면처럼 TextKey 속성이 붙은 라벨을 한 번에 등록한다(Q38).
-- - setKeyLabels(labels): 입력 장치별 키 라벨(I18N_PLAN 4.4). 문구의 {key_interact}, {key_repair}, {key_boost}는
--   서버가 넣지 않고 여기서 채운다. 값은 문자열("E") 또는 Msg({ key = "key.touch.tap" }). 기본값은 키보드.
--   장치가 바뀌면 화면 쪽(v2 UI)이 불러 주고, 등록된 라벨을 다시 그린다. Msg에 같은 이름의 값이 있으면 그 값이 이긴다.
-- 처음 쓸 때 속성 감시를 시작한다. 토스트처럼 잠깐 뜨는 글은 bind하지 않고 text()만 쓴다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loc = require(ReplicatedStorage.Shared.Loc)
local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Strings = require(ReplicatedStorage.Shared.Strings)

local Localizer = {}

Localizer.ATTRIBUTE = "Lang"
Localizer.TEXT_KEY_ATTRIBUTE = "TextKey"
Localizer.SEND_INTERVAL = 1.1 -- 초. 서버 PlayerPrefs.RATE_LIMIT(1초)보다 조금 길게
Localizer.IN_FLIGHT_TIMEOUT = 5 -- 초

type Binding = { msg: Msg.Msg, property: string }

local changedEvent = Instance.new("BindableEvent")
Localizer.changed = changedEvent.Event

local current = Loc.DEFAULT
local started = false
local lastSent = -math.huge
local pending: string? = nil -- 보내기를 기다리는 선택
local sendScheduled = false
local inFlight: string? = nil -- 보냈고 서버 응답을 기다리는 값
local inFlightSerial = 0

-- 입력 키 라벨 (키보드 기본값)
Localizer.DEFAULT_KEY_LABELS = { key_interact = "E", key_repair = "R", key_boost = "Shift" }
local keyLabels: { [string]: any } = table.clone(Localizer.DEFAULT_KEY_LABELS)
local KEY_LABEL_DEPTH = 10

-- Msg 복사본에 키 라벨을 채운다 (중첩 Msg 포함, 원본은 바꾸지 않는다)
local function withKeyLabels(msg: Msg.Msg, depth: number): Msg.Msg
    local args: { [string]: any } = {}
    for name, value in msg.args or {} do
        if type(value) == "table" and type(value.key) == "string" and depth < KEY_LABEL_DEPTH then
            args[name] = withKeyLabels(value, depth + 1)
        else
            args[name] = value
        end
    end
    for name, label in keyLabels do
        if args[name] == nil then
            args[name] = label
        end
    end
    return { key = msg.key, args = args }
end

local function resolve(msg: Msg.Msg): string
    return Loc.resolve(withKeyLabels(msg, 0), current, Strings.strings)
end

-- 약한 키 등록 표. 값은 라벨을 참조하지 않는다
local registry: { [Instance]: Binding } = setmetatable({}, { __mode = "k" }) :: any

local function render(object: Instance, binding: Binding)
    local text = resolve(binding.msg)
    local target = object :: any
    if Loc.isRich(binding.msg.key) then
        target.RichText = true
    end
    target[binding.property] = text
end

local function renderAll()
    for object, binding in registry do
        render(object, binding)
    end
end

local function setCurrent(lang: string)
    if lang == current then
        return
    end
    current = lang
    renderAll()
    changedEvent:Fire(lang)
end

local function attributeValue(): string?
    local player = Players.LocalPlayer
    if not player then
        return nil
    end
    return Loc.normalize(player:GetAttribute(Localizer.ATTRIBUTE))
end

-- 서버 값 따르기 (보낼 값이나 응답 대기 중인 값이 없을 때만)
local function adoptAttribute()
    if pending or inFlight then
        return
    end
    local value = attributeValue()
    if value then
        setCurrent(value)
    end
end

local function onAttributeChanged()
    local value = attributeValue()
    if not value or pending then
        return
    end
    if inFlight then
        if value == inFlight then
            inFlight = nil
        end
        return
    end
    setCurrent(value)
end

local function ensureStarted()
    if started then
        return
    end
    started = true
    local player = Players.LocalPlayer
    if player then
        player:GetAttributeChangedSignal(Localizer.ATTRIBUTE):Connect(onAttributeChanged)
        adoptAttribute()
    end
end

local function sendNow()
    local lang = pending
    pending = nil
    if not lang then
        return
    end
    if attributeValue() == lang then
        inFlight = nil
        return
    end
    lastSent = os.clock()
    inFlight = lang
    inFlightSerial += 1
    local serial = inFlightSerial
    task.spawn(function()
        Remotes.get("SetLanguage"):FireServer(lang)
    end)
    task.delay(Localizer.IN_FLIGHT_TIMEOUT, function()
        if inFlightSerial == serial and inFlight == lang then
            inFlight = nil
            adoptAttribute()
        end
    end)
end

local function requestSend(lang: string)
    pending = lang
    local waitTime = lastSent + Localizer.SEND_INTERVAL - os.clock()
    if waitTime <= 0 then
        sendNow()
    elseif not sendScheduled then
        sendScheduled = true
        task.delay(waitTime, function()
            sendScheduled = false
            sendNow()
        end)
    end
end

function Localizer.get(): string
    ensureStarted()
    return current
end

-- 언어 바꾸기. 지원하지 않는 코드면 false
function Localizer.set(code: string): boolean
    ensureStarted()
    local lang = Loc.normalize(code)
    if not lang then
        return false
    end
    setCurrent(lang)
    requestSend(lang)
    return true
end

-- Msg 또는 키 문자열을 지금 언어로
function Localizer.text(msg: Msg.Msg | string | nil): string
    ensureStarted()
    if type(msg) == "string" then
        return resolve({ key = msg })
    end
    if not Msg.isMsg(msg) then
        return ""
    end
    return resolve(msg :: Msg.Msg)
end

-- 입력 장치별 키 라벨 바꾸기 (예: 터치면 { key_interact = { key = "key.touch.tap" }, key_boost = { key = "key.touch.boost" } }).
-- 넘긴 이름만 바꾸고 나머지는 그대로. 등록된 라벨을 다시 그린다
function Localizer.setKeyLabels(labels: { [string]: any })
    ensureStarted()
    for name, label in labels do
        keyLabels[name] = label
    end
    renderAll()
end

-- 날짜 { year, month, day }를 지금 언어로 ("short" | "long")
function Localizer.date(date: Msg.DateParts, style: Msg.DateStyle?): string
    ensureStarted()
    return Loc.formatDate(date, current, style, Strings.strings)
end

-- 라벨 등록. msg가 nil이면 등록을 푼다. property 기본값 "Text". object를 그대로 돌려준다
function Localizer.bind<T>(object: T & Instance, msg: Msg.Msg | string | nil, property: string?): T
    ensureStarted()
    local target = object :: any
    target.AutoLocalize = false
    if msg == nil then
        registry[object] = nil
        return object
    end
    local value: Msg.Msg = if type(msg) == "string" then { key = msg } else msg
    local prop = property or "Text"
    local existing = registry[object]
    if existing and existing.property == prop and Msg.equals(existing.msg, value) then
        return object
    end
    local binding = { msg = value, property = prop }
    registry[object] = binding
    render(object, binding)
    return object
end

function Localizer.unbind(object: Instance)
    registry[object] = nil
end

-- TextKey 속성이 붙은 글자 요소를 모두 등록하고, 모든 글자 요소의 AutoLocalize를 끈다. 등록한 수를 돌려준다
function Localizer.bindTextKeys(root: Instance): number
    ensureStarted()
    local count = 0
    for _, object in root:GetDescendants() do
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            local key = object:GetAttribute(Localizer.TEXT_KEY_ATTRIBUTE)
            if type(key) == "string" and key ~= "" then
                Localizer.bind(object, { key = key })
                count += 1
            else
                (object :: any).AutoLocalize = false
            end
        end
    end
    return count
end

return Localizer
