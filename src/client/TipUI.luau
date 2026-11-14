--!nonstrict
-- 상황별 일회성 Tip 카드 (v2, 문구는 tip.* 키). 우측 하단에 아래에서 올라오며 뜬다(v1 14차 자리와 모양 유지).
-- PC: 오른쪽 16, 아래 56(SettingsUI 패널 바로 위), 폭 360(가상 좌표). compact: 오른쪽 12px, 아래 230px(실제 px).
-- 한 번에 하나, 대기열 순차 표시, 표시 사이 최소 3초, 판마다 각 Tip 1회(selecting이면 초기화).
-- 트리거는 모두 클라이언트(StateUpdate, OxygenUpdate, 탑승, 우주 기상, 핀). 플레이 중에만 보인다.
-- 언어가 바뀌면 지금 카드 글자도 다시 그린다(Localizer.bind).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Layout = require(script.Parent.Layout)
local RoverBoost = require(script.Parent.RoverBoost)
local SoundFX = require(script.Parent.SoundFX)
local UI = require(script.Parent.UI)

local TipUI = {}

local CARD_WIDTH = 360 -- 가상 좌표(배율 적용 전)
local BODY_TEXT_SIZE = 17
local BADGE_TEXT_SIZE = 14
local FADE_IN = 0.3
local HOLD = 7
local FADE_OUT = 0.5
local MIN_GAP = 3
local RISE = 24
local SINK = 12
local PC_MARGIN = 16
local PC_BOTTOM = 60 -- 설정 패널(아래 12, 높이 44) 바로 위
local COMPACT_RIGHT = 12 -- 실제 px
local COMPACT_BOTTOM = 240 -- 실제 px. 설정 패널(아래 190) 위
local COMPACT_SIDE_PAD = 24
local FALLBACK_VIEWPORT = Vector2.new(1280, 720)
local TIP_SOUND_VOLUME = 0.3
local PANELS_TIP_DELAY = 20 -- 첫 Tip(에어록) 뒤 패널 Tip까지
local OXYGEN_TIP_BELOW = 50
local LOW_THRESHOLD = MissionConfig.SCORE.lowThreshold

local CREAM = Color3.fromRGB(245, 240, 225)
local INK = Color3.fromRGB(40, 36, 28)
local AMBER = Color3.fromRGB(255, 200, 40)
local BASE_GRAY = Color3.fromRGB(120, 110, 90)

-- 리터럴 키 표 (I18N_PLAN 4.2)
local TIP_KEYS = {
    airlock = "tip.airlock",
    oxygen = "tip.oxygen",
    console = "tip.console",
    console_team = "tip.console_team",
    pin = "tip.pin",
    pause = "tip.pause",
    rover_damage = "tip.rover_damage",
    pipe = "tip.pipe",
    boost = "tip.boost",
    low_food = "tip.low_food",
    low_water = "tip.low_water",
    low_water_team = "tip.low_water_team",
    sep = "tip.sep",
    panels = "tip.panels",
}

local gui
local tipRoot
local group
local textLabel

local shown = {} -- { [id] = true } 큐에 넣은 Tip
local queue = {}
local suppressed = true
local enabled = true
local generation = 0
local lastEnd = -math.huge

local mode = "solo"
local role = nil
local prev = {}

function TipUI.push(id)
    if suppressed or shown[id] or not TIP_KEYS[id] then
        return
    end
    shown[id] = true
    table.insert(queue, id)
end

local function clearQueue()
    queue = {}
    generation += 1
end

function TipUI.reset()
    shown = {}
    prev = {}
    clearQueue()
end

function TipUI.setSuppressed(value)
    if value == suppressed then
        return
    end
    suppressed = value
    if value then
        clearQueue()
    end
end

function TipUI.setEnabled(value)
    if value == enabled then
        return
    end
    enabled = value
    if not value then
        generation += 1
    end
end

-- 솔로/멀티와 내 역할 (Main.client가 RoleUpdate와 StateUpdate에서 알려 준다)
function TipUI.setContext(newMode, newRole)
    mode = newMode or "solo"
    role = newRole
end

local function waitFor(seconds, myGeneration)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if generation ~= myGeneration then
            return false
        end
        task.wait(0.1)
    end
    return generation == myGeneration
end

local function cardLayout()
    local viewport = gui.AbsoluteSize
    if viewport.X <= 0 or viewport.Y <= 0 then
        viewport = FALLBACK_VIEWPORT
    end
    local scale = Layout.scale()
    local virtualWidth = viewport.X / scale
    if Layout.isCompact() then
        return math.min(CARD_WIDTH, virtualWidth - COMPACT_SIDE_PAD / scale),
            COMPACT_RIGHT / scale,
            COMPACT_BOTTOM / scale
    end
    return math.min(CARD_WIDTH, virtualWidth - PC_MARGIN * 2), PC_MARGIN, PC_BOTTOM
end

local function cardPosition(right, bottom, dy)
    return UDim2.new(1, -right, 1, -bottom + dy)
end

local function showCard(id, myGeneration)
    UI.msg(textLabel, TIP_KEYS[id])
    local width, right, bottom = cardLayout()
    group.Size = UDim2.fromOffset(width, 0)
    group.GroupTransparency = 1
    group.Position = cardPosition(right, bottom, RISE)
    local info = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(group, info, { GroupTransparency = 0 }):Play()
    TweenService:Create(group, info, { Position = cardPosition(right, bottom, 0) }):Play()
    group.Visible = true

    local completed = waitFor(FADE_IN + HOLD, myGeneration)
    local fade = if completed then FADE_OUT else 0.2
    local outInfo = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(group, outInfo, { GroupTransparency = 1 }):Play()
    TweenService:Create(group, outInfo, { Position = cardPosition(right, bottom, SINK) }):Play()
    task.wait(fade)
    if generation == myGeneration or not completed then
        group.Visible = false
    end
end

local function worker()
    while true do
        task.wait(0.25)
        if not suppressed and enabled and #queue > 0 and os.clock() - lastEnd >= MIN_GAP then
            local id = table.remove(queue, 1)
            local myGeneration = generation
            SoundFX.playVolume("mission_advance", TIP_SOUND_VOLUME)
            showCard(id, myGeneration)
            lastEnd = os.clock()
        end
    end
end

local function makeBulb()
    return UI.create("Frame", {
        Name = "Bulb",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(32, 40),
        BackgroundTransparency = 1,
    }, {
        UI.create("Frame", {
            Name = "Glass",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 2),
            Size = UDim2.fromOffset(24, 24),
            BackgroundColor3 = AMBER,
        }, { UI.roundCorner() }),
        UI.create("Frame", {
            Name = "BaseUpper",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 28),
            Size = UDim2.fromOffset(14, 4),
            BackgroundColor3 = BASE_GRAY,
        }, { UI.corner(2) }),
        UI.create("Frame", {
            Name = "BaseLower",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 34),
            Size = UDim2.fromOffset(10, 4),
            BackgroundColor3 = BASE_GRAY,
        }, { UI.corner(2) }),
    })
end

function TipUI.init(_ctx)
    gui = UI.gui("Tip", 14)
    tipRoot = Layout.root(gui)

    textLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = INK,
        Font = UI.Font,
        TextSize = BODY_TEXT_SIZE,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local badge = UI.create("TextLabel", {
        Name = "TipBadge",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 22),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 0,
        BackgroundColor3 = AMBER,
        TextColor3 = INK,
        TextSize = BADGE_TEXT_SIZE,
        Font = UI.FontBold,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }) })
    UI.msg(badge, "tip.badge")

    local card = UI.create("Frame", {
        Name = "Card",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = CREAM,
    }, {
        UI.corner(12),
        UI.stroke(AMBER, 1.5),
        UI.padding(14),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 12),
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        makeBulb(),
        UI.create("Frame", {
            Name = "Body",
            LayoutOrder = 2,
            Size = UDim2.new(1, -44, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
        }, {
            UI.list(Enum.FillDirection.Vertical, 4),
            badge,
            textLabel,
        }),
    })

    group = UI.create("CanvasGroup", {
        Name = "Group",
        AnchorPoint = Vector2.new(1, 1),
        Position = cardPosition(PC_MARGIN, PC_BOTTOM, 0),
        Size = UDim2.fromOffset(CARD_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
        Parent = tipRoot,
    }, { card })

    RoverBoost.drivingChanged:Connect(function(driving)
        if driving then
            TipUI.push("boost")
        end
    end)

    task.spawn(worker)
end

local function anyFacilityRunning(state)
    for _, f in pairs(state.facilities or {}) do
        if type(f) == "table" and f.status == "active" then
            return true
        end
    end
    return type(state.airlock) == "table" and state.airlock.status == "active"
end

function TipUI.onState(state)
    local phase = state.phase
    if phase == "selecting" then
        TipUI.reset()
    end
    TipUI.setSuppressed(phase ~= "playing")
    if phase ~= "playing" then
        return
    end
    mode = state.mode or mode

    -- 시작: 에어록 점검, 조금 뒤 패널
    local airlock = state.airlock or {}
    if not prev.started then
        prev.started = true
        if airlock.status == "idle" then
            TipUI.push("airlock")
        end
        task.delay(PANELS_TIP_DELAY, function()
            TipUI.push("panels")
        end)
    end
    -- 에어록 점검을 시작하면 콘솔 안내 (솔로: 로버 파견, 멀티: 관제사 핀)
    if airlock.status ~= nil and airlock.status ~= "idle" then
        if mode == "solo" then
            TipUI.push("console")
        elseif role == "controller" then
            TipUI.push("console_team")
        end
    end

    local resources = state.resources or {}
    local lowWarn = state.lowWarn or {}
    if
        (lowWarn.energy or (resources.energy or 100) < LOW_THRESHOLD) and anyFacilityRunning(state)
    then
        TipUI.push("pause")
    end
    local farm = (state.facilities or {}).farm
    local farmBuilt = type(farm) == "table"
        and (farm.status == "active" or farm.status == "building")
    if (lowWarn.food or (resources.food or 100) < LOW_THRESHOLD) and not farmBuilt then
        TipUI.push("low_food")
    end
    if lowWarn.water or (resources.water or 100) < LOW_THRESHOLD then
        TipUI.push(if mode == "solo" then "low_water" else "low_water_team")
    end

    local rover = state.rover or {}
    local damage = rover.damage or 0
    if prev.damage ~= nil and damage > prev.damage then
        TipUI.push("rover_damage")
    end
    prev.damage = damage

    local pipe = (state.facilities or {}).pipe
    if type(pipe) == "table" and pipe.status == "available" then
        TipUI.push("pipe")
    end

    local weather = state.weather
    if type(weather) == "table" and weather.kind == "SEP" then
        TipUI.push("sep")
    end
end

function TipUI.onOxygen(oxygen, _max, zone)
    if zone == "outside" and type(oxygen) == "number" and oxygen < OXYGEN_TIP_BELOW then
        TipUI.push("oxygen")
    end
end

-- 핀이 찍히면 탐사대원에게 화살표 안내
function TipUI.onPin(siteIndex)
    if siteIndex ~= nil and mode == "multi" and role ~= "controller" then
        TipUI.push("pin")
    end
end

return TipUI
