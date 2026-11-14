--!nonstrict
-- "알고 있나요?" 교육 사실 카드 (v2, 문구는 fact.<id>.title / fact.<id>.body 키, docs/content/FACTS_V2.md).
-- 화면 오른쪽 가장자리 세로 중앙에 슬라이드 인한다(v1 15차 자리와 모양 유지, 루나 색).
-- 한 번에 하나, 대기열 순차 표시, 표시 사이 최소 4초, 판마다 각 카드 1회(selecting이면 초기화). 닫기 버튼으로 바로 접는다.
-- 긴 카드(sep, geomagnetic, rover_driving)는 조금 더 오래 보여 준다(리드 결정, 약 14초).
-- 트리거는 FACTS_V2 1절 표(리드 결정: artemis는 첫 착륙 날 1회, 결과 화면에는 넣지 않는다).
-- 상태 트리거는 Tip 카드와 겹치지 않게 STATE_DELAY초 늦춰서 큐에 넣는다.

local TweenService = game:GetService("TweenService")

local Layout = require(script.Parent.Layout)
local RoverBoost = require(script.Parent.RoverBoost)
local SoundFX = require(script.Parent.SoundFX)
local UI = require(script.Parent.UI)
local L = UI.Luna

local FactUI = {}

local CARD_WIDTH = 380 -- 가상 좌표(배율 적용 전)
local TITLE_SIZE = 20
local BODY_SIZE = 16
local BADGE_SIZE = 14
local SOURCE_SIZE = 13
local FADE_IN = 0.3
local HOLD = 10
local HOLD_LONG = 14
local FADE_OUT = 0.5
local MIN_GAP = 4
local SLIDE = 40
local PC_MARGIN = 16
local COMPACT_MARGIN = 12
local COMPACT_SIDE_PAD = 24
local FALLBACK_VIEWPORT = Vector2.new(1280, 720)
local SOUND_VOLUME = 0.25
local STATE_DELAY = 4
local LANDED_DELAY = 4 -- 플레이 시작 뒤 첫 카드
local ARTEMIS_DELAY = 30 -- 첫 카드 뒤 아르테미스 카드 (첫 착륙 날, 리드 결정)
local BOARD_DELAY = 20 -- 첫 탑승 뒤 중력 카드
local OUTSIDE_DELAY = 15 -- 탑승 전 첫 야외 이동 뒤 중력 카드 (멀티는 걸어서 먼저 나가기도 한다)

-- 리터럴 키 표 (I18N_PLAN 4.2)
local FACTS = {
    south_pole = { title = "fact.south_pole.title", body = "fact.south_pole.body" },
    shadowed_ice = { title = "fact.shadowed_ice.title", body = "fact.shadowed_ice.body" },
    lcross = { title = "fact.lcross.title", body = "fact.lcross.body" },
    isru = { title = "fact.isru.title", body = "fact.isru.body" },
    lunar_day = { title = "fact.lunar_day.title", body = "fact.lunar_day.body" },
    space_garden = { title = "fact.space_garden.title", body = "fact.space_garden.body" },
    grow_lights = { title = "fact.grow_lights.title", body = "fact.grow_lights.body" },
    hydroponics = { title = "fact.hydroponics.title", body = "fact.hydroponics.body" },
    plant_water = { title = "fact.plant_water.title", body = "fact.plant_water.body" },
    sep = { title = "fact.sep.title", body = "fact.sep.body", long = true },
    sep_shelter = { title = "fact.sep_shelter.title", body = "fact.sep_shelter.body" },
    geomagnetic = { title = "fact.geomagnetic.title", body = "fact.geomagnetic.body", long = true },
    rover_driving = {
        title = "fact.rover_driving.title",
        body = "fact.rover_driving.body",
        long = true,
    },
    gravity = { title = "fact.gravity.title", body = "fact.gravity.body" },
    artemis = { title = "fact.artemis.title", body = "fact.artemis.body" },
    mission_control = { title = "fact.mission_control.title", body = "fact.mission_control.body" },
    donki = { title = "fact.donki.title", body = "fact.donki.body" },
}

-- 업그레이드 완공 -> 카드
local BUILD_FACTS = { led = "grow_lights", hydroponics = "hydroponics", nutrient = "plant_water" }

local gui
local group
local titleLabel
local bodyLabel

local shown = {} -- { [id] = true } 큐에 넣은 카드
local queue = {}
local suppressed = true
local enabled = true
local generation = 0
local closeRequested = false
local lastEnd = -math.huge
local prev = {}
local boarded = false

function FactUI.push(id)
    if suppressed or shown[id] or not FACTS[id] then
        return
    end
    shown[id] = true
    table.insert(queue, id)
end

local function pushLater(id, delaySeconds)
    local myGeneration = generation
    task.delay(delaySeconds, function()
        if generation == myGeneration then
            FactUI.push(id)
        end
    end)
end

-- 같은 카드의 지연 예약을 판마다 한 번만 건다 (StateUpdate마다 예약이 쌓이지 않게)
local function pushOnceLater(id, delaySeconds)
    if prev["later_" .. id] then
        return
    end
    prev["later_" .. id] = true
    pushLater(id, delaySeconds)
end

local function clearQueue()
    queue = {}
    generation += 1
end

function FactUI.reset()
    shown = {}
    prev = {}
    boarded = false
    clearQueue()
end

function FactUI.setSuppressed(value)
    if value == suppressed then
        return
    end
    suppressed = value
    if value then
        clearQueue()
    end
end

function FactUI.setEnabled(value)
    if value == enabled then
        return
    end
    enabled = value
    if not value then
        generation += 1
    end
end

local function waitFor(seconds, myGeneration)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if generation ~= myGeneration or closeRequested then
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
    local virtualWidth = viewport.X / Layout.scale()
    if Layout.isCompact() then
        return math.min(CARD_WIDTH, virtualWidth - COMPACT_SIDE_PAD), COMPACT_MARGIN
    end
    return math.min(CARD_WIDTH, virtualWidth - PC_MARGIN * 2), PC_MARGIN
end

local function cardPosition(right, dx)
    return UDim2.new(1, -right + dx, 0.5, 0)
end

local function showCard(id, myGeneration)
    local fact = FACTS[id]
    UI.msg(titleLabel, fact.title)
    UI.msg(bodyLabel, fact.body)
    closeRequested = false
    local width, right = cardLayout()
    group.Size = UDim2.fromOffset(width, 0)
    group.GroupTransparency = 1
    group.Position = cardPosition(right, SLIDE)
    local info = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(group, info, { GroupTransparency = 0 }):Play()
    TweenService:Create(group, info, { Position = cardPosition(right, 0) }):Play()
    group.Visible = true

    local completed = waitFor(FADE_IN + (if fact.long then HOLD_LONG else HOLD), myGeneration)
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
        if not suppressed and enabled and #queue > 0 and os.clock() - lastEnd >= MIN_GAP then
            local id = table.remove(queue, 1)
            SoundFX.playVolume("mission_advance", SOUND_VOLUME)
            showCard(id, generation)
            lastEnd = os.clock()
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
        FontFace = UI.RoundHeavy,
        TextSize = TITLE_SIZE,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    bodyLabel = UI.create("TextLabel", {
        Name = "Body",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = BODY_SIZE,
        TextColor3 = L.body,
        TextWrapped = true,
        LineHeight = 1.1,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local source = UI.create("TextLabel", {
        Name = "Source",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Mono,
        TextSize = SOURCE_SIZE,
        TextColor3 = L.dim,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(source, "fact.source")
    local badge = UI.create("TextLabel", {
        Name = "Badge",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 0,
        BackgroundColor3 = L.sky,
        FontFace = UI.RoundHeavy,
        TextColor3 = L.inkDeep,
        TextSize = BADGE_SIZE,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }) })
    UI.msg(badge, "fact.badge")
    local closeButton = UI.create("TextButton", {
        Name = "Close",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(32, 32),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.86,
        AutoButtonColor = false,
        Text = "",
    }, {
        UI.roundCorner(),
        -- X 표시 (막대 두 개)
        UI.create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(14, 2.5),
            Rotation = 45,
            BackgroundColor3 = L.white,
        }),
        UI.create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(14, 2.5),
            Rotation = -45,
            BackgroundColor3 = L.white,
        }),
    })
    local header = UI.create("Frame", {
        Name = "Header",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundTransparency = 1,
    }, { badge, closeButton })

    local card = UI.create("Frame", {
        Name = "Card",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.05,
    }, {
        UI.corner(16),
        UI.stroke(L.sky, 1.5, 0.4),
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

    RoverBoost.drivingChanged:Connect(function(driving)
        if driving and not boarded and not suppressed then
            boarded = true
            pushLater("rover_driving", 2)
            pushLater("gravity", BOARD_DELAY)
        end
    end)

    task.spawn(worker)
end

local function status(state, id)
    local f = (state.facilities or {})[id]
    return type(f) == "table" and f.status or nil
end

function FactUI.onState(state)
    local phase = state.phase
    if phase == "selecting" then
        FactUI.reset()
    end
    FactUI.setSuppressed(phase ~= "playing")
    if phase ~= "playing" then
        return
    end

    if not prev.started then
        prev.started = true
        pushOnceLater("south_pole", LANDED_DELAY)
        pushOnceLater("artemis", LANDED_DELAY + ARTEMIS_DELAY)
    end

    local panels = type(state.panels) == "table" and state.panels.installed or 0
    if prev.panels ~= nil and panels > prev.panels then
        pushOnceLater("lunar_day", STATE_DELAY)
    end
    prev.panels = panels

    local deliveries = state.deliveries or 0
    if prev.deliveries ~= nil and deliveries > prev.deliveries then
        pushOnceLater("isru", STATE_DELAY)
    end
    prev.deliveries = deliveries

    -- 첫 수확: 재배 공간이 가동 중이고 다음 수확까지 남은 일수가 다시 늘어나면 방금 수확했다
    local farm = (state.facilities or {}).farm
    local nextHarvest = type(farm) == "table" and farm.status == "active" and farm.nextHarvestIn
        or nil
    if
        type(nextHarvest) == "number"
        and type(prev.nextHarvest) == "number"
        and nextHarvest > prev.nextHarvest
    then
        pushOnceLater("space_garden", STATE_DELAY)
    end
    prev.nextHarvest = nextHarvest

    for facilityId, factId in pairs(BUILD_FACTS) do
        local now = status(state, facilityId)
        local key = "status_" .. facilityId
        if now == "active" and prev[key] == "building" then
            pushOnceLater(factId, STATE_DELAY)
        end
        prev[key] = now
    end

    local rover = state.rover or {}
    local fsd = rover.fsd
    if rover.state == "fsd" and type(fsd) == "table" and not fsd.recovering then
        pushOnceLater("rover_driving", STATE_DELAY)
        if fsd.phase == "return" then
            FactUI.push("lcross")
        end
    end
    if type(rover.tank) == "number" and rover.tank > 0 then
        FactUI.push("lcross")
    end

    local weather = state.weather
    if type(weather) == "table" then
        if weather.kind == "SEP" and weather.stage == "warning" then
            FactUI.push("sep")
        elseif weather.kind == "SEP" and weather.stage == "active" then
            FactUI.push("sep")
            FactUI.push("sep_shelter")
            pushOnceLater("donki", STATE_DELAY)
        elseif weather.kind == "GST" then
            FactUI.push("geomagnetic")
            pushOnceLater("mission_control", STATE_DELAY)
            pushOnceLater("donki", STATE_DELAY)
        end
    end
end

function FactUI.onOxygen(_oxygen, _max, zone)
    if zone == "outside" and not prev.wentOutside and not suppressed then
        prev.wentOutside = true
        pushOnceLater("gravity", OUTSIDE_DELAY)
    end
end

-- 콘솔 지도를 처음 열면 영구 음영 지역 카드
function FactUI.onMapOpened()
    FactUI.push("shadowed_ice")
end

-- 관제사가 핀을 처음 찍으면 관제센터 카드
function FactUI.onPin(siteIndex)
    if siteIndex ~= nil then
        FactUI.push("mission_control")
    end
end

-- SpaceWeather 경보(15초 전)
function FactUI.onSpaceWeather(payload)
    if type(payload) == "table" and payload.kind == "SEP" and payload.stage == "warning" then
        FactUI.push("sep")
    end
end

return FactUI
