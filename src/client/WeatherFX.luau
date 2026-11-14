--!nonstrict
-- 우주 기상 화면 효과 (V2_PLAN 15.8 Q15). 문구 배너는 HUDV2가 그리고, 여기서는 글자 없는 효과만 맡는다.
-- - SEP 경보(SpaceWeather stage "warning", 시작 15초 전): 화면 테두리 붉은 깜빡임
-- - SEP 진행 중(state.weather SEP active): 화면 딤드 (HUD는 그 위에 보인다)
-- GST 효과는 콘솔 지도(지직거림)와 핀 화살표 숨김이 맡는다.

local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)
local L = UI.Luna

local WeatherFX = {}

local EDGE = 70
local FLASH_SECONDS = 15
local FLASH_PERIOD = 0.6
local DIM_TRANSPARENCY = 0.55
local FADE = 0.6

local gui
local edges = {}
local dim
local flashUntil = 0
local flashing = false
local dimmed = false

local function edge(name, anchor, position, size, rotation)
    return UI.create("Frame", {
        Name = name,
        AnchorPoint = anchor,
        Position = position,
        Size = size,
        BackgroundColor3 = L.red,
        BackgroundTransparency = 1,
        Interactable = false,
        Parent = gui,
    }, {
        UI.create("UIGradient", {
            Rotation = rotation,
            Transparency = NumberSequence.new(0, 1),
        }),
    })
end

local function setEdges(transparency, seconds)
    for _, frame in ipairs(edges) do
        TweenService
            :Create(frame, TweenInfo.new(seconds), { BackgroundTransparency = transparency })
            :Play()
    end
end

local function startFlash()
    flashUntil = os.clock() + FLASH_SECONDS
    if flashing then
        return
    end
    flashing = true
    task.spawn(function()
        local on = false
        while os.clock() < flashUntil and flashing do
            on = not on
            setEdges(if on then 0.25 else 0.85, FLASH_PERIOD * 0.8)
            task.wait(FLASH_PERIOD)
        end
        flashing = false
        setEdges(1, FADE)
    end)
end

function WeatherFX.init(_ctx)
    gui = UI.gui("WeatherFX", 8)
    dim = UI.create("Frame", {
        Name = "Dim",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(20, 8, 30),
        BackgroundTransparency = 1,
        Interactable = false,
        Parent = gui,
    })
    edges = {
        edge("Top", Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.new(1, 0, 0, EDGE), 90),
        edge("Bottom", Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.new(1, 0, 0, EDGE), -90),
        edge("Left", Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.new(0, EDGE, 1, 0), 0),
        edge("Right", Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.new(0, EDGE, 1, 0), 180),
    }
end

-- SpaceWeather(S->C) { kind, stage, day, durationDays, sourceDate }
function WeatherFX.onSpaceWeather(payload)
    if type(payload) ~= "table" or payload.kind ~= "SEP" then
        return
    end
    if payload.stage == "warning" then
        startFlash()
    elseif payload.stage == "active" or payload.stage == "ended" then
        flashing = false
    end
end

function WeatherFX.update(state)
    local weather = type(state) == "table" and state.weather or nil
    local playing = type(state) == "table" and state.phase == "playing"
    local sep = playing
        and type(weather) == "table"
        and weather.kind == "SEP"
        and weather.stage == "active"
    if sep ~= dimmed then
        dimmed = sep
        TweenService:Create(dim, TweenInfo.new(FADE), {
            BackgroundTransparency = if sep then DIM_TRANSPARENCY else 1,
        }):Play()
    end
    if not playing then
        flashing = false
    end
end

return WeatherFX
