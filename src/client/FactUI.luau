--!nonstrict
-- "알고 있나요?" 교육 사실 카드 (15차). 화면 오른쪽 가장자리 세로 중앙에 슬라이드 인한다.
-- 우상단(패널/로버 열, 토스트)과 우하단(Tip 카드)을 피한 자리다. Tip(크림색)과 구분되는 짙은 남색 패널.
-- 한 번에 하나, 대기열 순차 표시, 표시 사이 최소 4초 간격, 세션당 각 사실 1회(재시작하면 초기화).
-- 문구는 shared/Facts.luau. 트리거는 전부 클라이언트 측(StateUpdate, OxygenUpdate, 탑승 이벤트).
-- Tip 카드와 같은 순간에 뜨지 않도록 상태 트리거는 4초 늦춰서 큐에 넣는다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Facts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Facts"))
local RoverBoost = require(script.Parent.RoverBoost)
local SoundFX = require(script.Parent.SoundFX)
local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local Colors = UI.Colors

local FactUI = {}

local CARD_WIDTH = 380 -- 가상 좌표(배율 적용 전)
local TITLE_SIZE = 20
local BODY_SIZE = 17
local BADGE_SIZE = 15
local SOURCE_SIZE = 14
local FADE_IN = 0.3
local HOLD = 10
local FADE_OUT = 0.5
local MIN_GAP = 4
local SLIDE = 40 -- 등장 시 오른쪽에서 들어오는 거리, 퇴장 시 나가는 거리(가상 좌표)
local PC_MARGIN = 16
local COMPACT_MARGIN = 12
local COMPACT_SIDE_PAD = 24 -- compact 폭 = min(380, 가상 폭 - 24)
local FALLBACK_VIEWPORT = Vector2.new(1280, 720)
local SOUND_VOLUME = 0.25
local STATE_DELAY = 4 -- 상태 트리거를 Tip 카드와 겹치지 않게 늦추는 시간(초)
local BOARD_DELAY = 20 -- 첫 탑승 뒤 중력 사실까지
local OXYGEN_LIMIT = 50
local SEEN_LIMIT = 3 -- 결과 화면에 보여 줄 최대 개수

local BODY_COLOR = Color3.fromRGB(225, 232, 245)
local NAVY_TEXT = Color3.fromRGB(18, 26, 48)
local SOURCE_TEXT = "NASA 공개 자료 기반"

local gui
local group
local titleLabel
local bodyLabel

local shown = {} -- { [key] = true } 큐에 넣은 사실
local queue = {} -- 사실 key 목록
local seen = {} -- 실제로 표시한 사실 제목(표시 순서)
local suppressed = true
local generation = 0 -- reset이나 억제 때 현재 카드와 예약된 push를 끊기 위한 값
local closeRequested = false
local lastEnd = -math.huge

local prevPhase = nil
local prevPanels = nil
local prevTrips = nil
local prevStatus = {}
local boarded = false
local oxygenShown = false
local currentSite = nil

local function siteText(fact)
    local name = currentSite or "착륙지"
    return (string.gsub(fact.body, "{site}", function()
        return name
    end))
end

function FactUI.push(key)
    if suppressed or shown[key] then
        return
    end
    local fact = Facts.byKey[key]
    if not fact or fact.trigger == "result" then
        return
    end
    shown[key] = true
    table.insert(queue, key)
end

-- 지금 세대가 유지되는 동안에만 delaySeconds 뒤에 push한다(재시작이나 결과 화면이면 버린다)
local function pushLater(key, delaySeconds)
    local myGeneration = generation
    task.delay(delaySeconds, function()
        if generation == myGeneration then
            FactUI.push(key)
        end
    end)
end

local function clearQueue()
    queue = {}
    generation += 1
end

function FactUI.reset()
    shown = {}
    seen = {}
    prevPanels = nil
    prevTrips = nil
    prevStatus = {}
    boarded = false
    oxygenShown = false
    clearQueue()
end

-- 결과, 선택, 착륙 화면에서는 표시하지 않고 큐만 비운다
function FactUI.setSuppressed(value)
    if value == suppressed then
        return
    end
    suppressed = value
    if value then
        clearQueue()
    end
end

-- 이번 세션에 실제로 표시한 사실 제목, 최근 것부터 최대 limit개
function FactUI.seenTitles(limit)
    local count = limit or SEEN_LIMIT
    local result = {}
    for index = #seen, math.max(1, #seen - count + 1), -1 do
        table.insert(result, seen[index])
    end
    return result
end

-- 결과 화면용 한 문장 (본 사실이 하나도 없을 때)
function FactUI.resultText(won)
    local fact = Facts.byKey[won and "result_win" or "result_lose"]
    return fact and fact.body or ""
end

-- 대기 단계 포함 취소 가능한 대기. 세대가 바뀌거나 닫기를 누르면 false
local function waitFor(seconds, myGeneration)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if generation ~= myGeneration or closeRequested then
            return false
        end
        task.wait(0.1)
    end
    return generation == myGeneration and not closeRequested
end

-- 카드 폭과 오른쪽 여백(가상 좌표). compact 여부는 표시할 때마다 읽는다.
local function cardLayout()
    local viewport = gui.AbsoluteSize
    if viewport.X <= 0 or viewport.Y <= 0 then
        viewport = FALLBACK_VIEWPORT
    end
    local virtualWidth = viewport.X / Layout.scale()
    if Layout.isCompact() then
        return math.min(CARD_WIDTH, virtualWidth - COMPACT_SIDE_PAD), COMPACT_MARGIN
    end
    return math.min(CARD_WIDTH, virtualWidth - PC_MARGIN * 2), PC_MARGIN
end

local function cardPosition(right, dx)
    return UDim2.new(1, -right + dx, 0.5, 0)
end

local function showCard(fact, myGeneration)
    titleLabel.Text = fact.title
    bodyLabel.Text = siteText(fact)
    closeRequested = false
    local width, right = cardLayout()
    group.Size = UDim2.fromOffset(width, 0)
    group.GroupTransparency = 1
    group.Position = cardPosition(right, SLIDE)
    local info = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(group, info, { GroupTransparency = 0 }):Play()
    TweenService:Create(group, info, { Position = cardPosition(right, 0) }):Play()
    group.Visible = true
    table.insert(seen, fact.title)

    local completed = waitFor(FADE_IN + HOLD, myGeneration)
    local fade = if completed then FADE_OUT else 0.2
    local outInfo = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(group, outInfo, { GroupTransparency = 1 }):Play()
    TweenService:Create(group, outInfo, { Position = cardPosition(right, SLIDE) }):Play()
    task.wait(fade)
    group.Visible = false
end

local function worker()
    while true do
        task.wait(0.25)
        if not suppressed and #queue > 0 and os.clock() - lastEnd >= MIN_GAP then
            local key = table.remove(queue, 1)
            local fact = Facts.byKey[key]
            if fact then
                SoundFX.playVolume("mission_advance", SOUND_VOLUME)
                showCard(fact, generation)
                lastEnd = os.clock()
            end
        end
    end
end

function FactUI.init(_ctx)
    gui = UI.gui("Fact", 13)
    local root = Layout.root(gui)

    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        Preset = "heading",
        TextSize = TITLE_SIZE,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    bodyLabel = UI.create("TextLabel", {
        Name = "Body",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = BODY_COLOR,
        Preset = "body",
        TextSize = BODY_SIZE,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local source = UI.create("TextLabel", {
        Name = "Source",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = SOURCE_TEXT,
        TextColor3 = Colors.textDim,
        Preset = "caption",
        TextSize = SOURCE_SIZE,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local badge = UI.create("TextLabel", {
        Name = "Badge",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 0,
        BackgroundColor3 = Colors.text,
        Text = "알고 있나요?",
        TextColor3 = NAVY_TEXT,
        Preset = "badge",
        TextSize = BADGE_SIZE,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }) })
    local closeButton = UI.create("TextButton", {
        Name = "Close",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(36, 36),
        BackgroundColor3 = Colors.panelLight,
        Text = "X",
        TextColor3 = Colors.text,
        TextSize = 16,
    }, { UI.roundCorner() })
    local header = UI.create("Frame", {
        Name = "Header",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
    }, { badge, closeButton })

    local card = UI.create("Frame", {
        Name = "Card",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
    }, {
        UI.corner(12),
        UI.stroke(Colors.panelLight, 2),
        UI.padding(14),
        UI.list(Enum.FillDirection.Vertical, 6),
        header,
        titleLabel,
        bodyLabel,
        source,
    })

    group = UI.create("CanvasGroup", {
        Name = "Group",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = cardPosition(PC_MARGIN, 0),
        Size = UDim2.fromOffset(CARD_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
        Parent = root,
    }, { card })

    closeButton.Activated:Connect(function()
        closeRequested = true
    end)

    -- 처음 DriverSeat에 앉고 20초 뒤 중력 사실
    RoverBoost.drivingChanged:Connect(function(driving)
        if driving and not boarded and not suppressed then
            boarded = true
            pushLater("gravity", BOARD_DELAY)
        end
    end)

    task.spawn(worker)
end

function FactUI.onState(state)
    local phase = state.phase
    if phase == "selecting" then
        FactUI.reset()
    end
    FactUI.setSuppressed(phase ~= "playing")

    if type(state.siteName) == "string" and state.siteName ~= "" then
        currentSite = state.siteName
    end
    if phase == "playing" and prevPhase ~= "playing" then
        pushLater("landing_site", STATE_DELAY)
    end
    prevPhase = phase
    if phase ~= "playing" then
        return
    end

    local panels = state.panelsInstalled
    if type(panels) == "number" then
        if prevPanels == 0 and panels >= 1 then
            pushLater("first_panel", STATE_DELAY)
        end
        prevPanels = panels
    end

    local trips = state.waterTrips
    if type(trips) == "number" then
        if prevTrips == 0 and trips >= 1 then
            pushLater("first_water", STATE_DELAY)
        end
        prevTrips = trips
    end

    for _, id in ipairs({ "A", "B", "C" }) do
        local module = state.modules and state.modules[id]
        if module then
            if module.status == "active" and prevStatus[id] ~= "active" then
                pushLater("module_" .. id, STATE_DELAY)
            end
            prevStatus[id] = module.status
        end
    end
end

function FactUI.onOxygen(oxygen, _max, _inside)
    if not oxygenShown and not suppressed and oxygen < OXYGEN_LIMIT then
        oxygenShown = true
        pushLater("oxygen_low", STATE_DELAY)
    end
end

return FactUI
