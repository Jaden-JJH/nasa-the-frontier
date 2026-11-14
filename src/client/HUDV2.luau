--!nonstrict
-- v2 HUD (CONTRACT_V2 2.3, V2_PLAN 15.2 ~ 15.9). 루나 소프트 디자인.
-- - 왼쪽 위: 자원 3개 칩(아이콘 + 숫자 + 상한 100 막대, 20 미만이면 "부족!" 표시), 그 아래 기지 정지 표시
-- - 가운데 위: "Day x of 60"과 남은 일수, 미션 문구(서버 Msg), 우주 기상 배너(사건 이름, 문구, NASA DONKI 날짜 출처, Q36)
-- - 오른쪽 위: 로버 상태 칩(자율주행, 고장, 회수, 폭풍 대기), 운전 중 배터리
-- 숫자는 화면용으로 내림(ClientMath.wholeNumber). 문구는 모두 Localizer(UI.msg)로 그린다.
-- compact(Layout.isCompact)는 칩과 글자를 줄이고 남은 일수 줄을 숨긴다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))
local Msg = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Msg"))

local Icons = require(script.Parent.Icons)
local Layout = require(script.Parent.Layout)
local RoverBoost = require(script.Parent.RoverBoost)
local UI = require(script.Parent.UI)
local L = UI.Luna

local HUDV2 = {}

local RESOURCES = { "energy", "water", "food" }
local LOW_THRESHOLD = MissionConfig.SCORE.lowThreshold
local DEFAULT_CAP = 100
local ENDED_BANNER_SECONDS = 6
local EDGE = 12

-- 리터럴 키 표 (I18N_PLAN 4.2: 동적 키는 표 조회로만)
local EVENT_NAMES = { SEP = "event.sep.name", GST = "event.gst.name" }
local WARNING_KEYS = { SEP = "banner.sep.warning", GST = "banner.gst.active" }
local ACTIVE_KEYS = { SEP = "banner.sep.active", GST = "banner.gst.active" }
local ENDED_KEYS = { SEP = "banner.sep.end", GST = "banner.gst.end" }
local STALL_KEYS = { energy = "hud.stalled.energy", water = "hud.stalled.water" }

local SIZES = {
    pc = {
        chipW = 132,
        chipH = 54,
        icon = 24,
        number = 26,
        dayText = 20,
        body = 16,
        missionW = 520,
    },
    compact = {
        chipW = 100,
        chipH = 42,
        icon = 18,
        number = 20,
        dayText = 16,
        body = 14,
        missionW = 340,
    },
}

local gui
local root
local resourceRow
local chips = {} -- [res] = { frame, number, fill, low }
local stalledChip
local stalledLabel
local center
local dayLabel
local daysLeftLabel
local missionPanel
local missionLabel
local weatherPanel
local weatherName
local weatherText
local weatherSource
local rightColumn
local roverChip
local roverLabel
local batteryChip
local batteryLabel
local batteryFill

local lastState = nil
local endedBanner = nil -- { kind, sourceDate, untilTime }

local function sizes()
    return if Layout.isCompact() then SIZES.compact else SIZES.pc
end

local function makeChip(res, order)
    local s = sizes()
    local number = UI.create("TextLabel", {
        Name = "Number",
        Position = UDim2.fromOffset(s.icon + 14, 4),
        Size = UDim2.new(1, -(s.icon + 18), 0, s.number + 4),
        FontFace = UI.RoundHeavy,
        TextSize = s.number,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "0",
    })
    local fill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = Icons.COLORS[res],
    }, { UI.corner(3) })
    local bar = UI.create("Frame", {
        Name = "Bar",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, s.icon + 14, 1, -8),
        Size = UDim2.new(1, -(s.icon + 22), 0, 5),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.85,
    }, { UI.corner(3), fill })
    local low = UI.create("TextLabel", {
        Name = "Low",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -6, 0, 5),
        Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.red,
        BackgroundTransparency = 0,
        FontFace = UI.RoundHeavy,
        TextSize = 12,
        TextColor3 = L.inkDeep,
        Visible = false,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 6, 6 }) })
    UI.msg(low, "hud.low")
    local icon = Icons.resource(res, s.icon)
    icon.AnchorPoint = Vector2.new(0, 0.5)
    icon.Position = UDim2.new(0, 10, 0.5, 0)
    local frame = UI.lunaPanel({
        Name = "Res_" .. res,
        LayoutOrder = order,
        Size = UDim2.fromOffset(s.chipW, s.chipH),
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.25,
    }, { icon, number, bar, low }, 14)
    chips[res] = { frame = frame, number = number, fill = fill, low = low, icon = icon, bar = bar }
    return frame
end

local function buildLeft()
    resourceRow = UI.create("Frame", {
        Name = "Resources",
        Position = UDim2.fromOffset(EDGE, 8),
        Size = UDim2.fromOffset(0, 0),
        AutomaticSize = Enum.AutomaticSize.XY,
        BackgroundTransparency = 1,
        Parent = root,
    }, { UI.list(Enum.FillDirection.Horizontal, 8) })
    for i, res in ipairs(RESOURCES) do
        makeChip(res, i).Parent = resourceRow
    end
    stalledLabel = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromOffset(0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 15,
        TextColor3 = L.inkDeep,
    })
    stalledChip = UI.create("Frame", {
        Name = "Stalled",
        Size = UDim2.fromOffset(0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.red,
        Visible = false,
        Parent = root,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 12, 12 }), stalledLabel })
end

local function buildCenter()
    local s = sizes()
    dayLabel = UI.create("TextLabel", {
        Name = "Day",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = s.dayText,
        TextColor3 = L.white,
    })
    daysLeftLabel = UI.create("TextLabel", {
        Name = "DaysLeft",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 14,
        TextColor3 = L.dim,
    })
    local dayRow = UI.lunaPanel({
        Name = "DayPanel",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 34),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.25,
    }, {
        UI.padding({ 0, 0, 16, 16 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 12),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        dayLabel,
        daysLeftLabel,
    }, 17)

    local missionTitle = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 16),
        FontFace = UI.MonoBold,
        TextSize = 13,
        TextColor3 = L.mint,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(missionTitle, "hud.mission.title")
    missionLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = s.body,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    missionPanel = UI.lunaPanel({
        Name = "Mission",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(s.missionW, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.25,
    }, {
        UI.padding({ 8, 10, 14, 14 }),
        UI.list(Enum.FillDirection.Vertical, 2),
        missionTitle,
        missionLabel,
    }, 14)

    weatherName = UI.create("TextLabel", {
        Name = "Name",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.RoundHeavy,
        TextSize = s.body + 2,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    weatherText = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = s.body,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    weatherSource = UI.create("TextLabel", {
        Name = "Source",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Mono,
        TextSize = 13,
        TextColor3 = L.soft,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    weatherPanel = UI.create("Frame", {
        Name = "Weather",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(s.missionW, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Color3.fromRGB(150, 45, 60),
        BackgroundTransparency = 0.1,
        Visible = false,
    }, {
        UI.corner(14),
        UI.stroke(L.red, 1.5, 0.2),
        UI.padding({ 8, 10, 14, 14 }),
        UI.list(Enum.FillDirection.Vertical, 2),
        weatherName,
        weatherText,
        weatherSource,
    })

    center = UI.create("Frame", {
        Name = "Center",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 8),
        Size = UDim2.fromOffset(s.missionW, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = root,
    }, {
        UI.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center),
        dayRow,
        missionPanel,
        weatherPanel,
    })
end

local function buildRight()
    roverLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 30),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 15,
        TextColor3 = L.white,
    })
    local roverIcon = Icons.rover(18)
    roverIcon.LayoutOrder = 1
    roverChip = UI.lunaPanel({
        Name = "Rover",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 34),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.25,
        Visible = false,
    }, {
        UI.padding({ 0, 0, 12, 14 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        roverIcon,
        roverLabel,
    }, 17)

    batteryLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 30),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 15,
        TextColor3 = L.white,
    })
    batteryFill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.mint,
    }, { UI.corner(3) })
    local batteryIcon = Icons.resource("battery", 20)
    batteryIcon.LayoutOrder = 1
    batteryChip = UI.lunaPanel({
        Name = "Battery",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 34),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.25,
        Visible = false,
    }, {
        UI.padding({ 0, 0, 12, 14 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        batteryIcon,
        batteryLabel,
        UI.create("Frame", {
            Name = "Bar",
            LayoutOrder = 3,
            Size = UDim2.fromOffset(60, 6),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.85,
        }, { UI.corner(3), batteryFill }),
    }, 17)

    rightColumn = UI.create("Frame", {
        Name = "Right",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -EDGE, 0, 8),
        Size = UDim2.fromOffset(0, 0),
        AutomaticSize = Enum.AutomaticSize.XY,
        BackgroundTransparency = 1,
        Parent = root,
    }, {
        UI.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right),
        roverChip,
        batteryChip,
    })
end

local function applyLayout()
    if not root then
        return
    end
    local s = sizes()
    for _, chip in pairs(chips) do
        chip.frame.Size = UDim2.fromOffset(s.chipW, s.chipH)
        chip.number.TextSize = s.number
        chip.number.Position = UDim2.fromOffset(s.icon + 14, 4)
        chip.icon.Size = UDim2.fromOffset(s.icon, s.icon)
    end
    dayLabel.TextSize = s.dayText
    daysLeftLabel.Visible = not Layout.isCompact()
    missionPanel.Size = UDim2.fromOffset(s.missionW, 0)
    weatherPanel.Size = UDim2.fromOffset(s.missionW, 0)
    center.Size = UDim2.fromOffset(s.missionW, 0)
    missionLabel.TextSize = s.body
    weatherText.TextSize = s.body
    -- compact는 가운데 묶음을 자원 줄 아래로 내려 겹치지 않게 한다
    local rowHeight = s.chipH + 8
    if Layout.isCompact() then
        center.AnchorPoint = Vector2.new(0, 0)
        center.Position = UDim2.fromOffset(EDGE, 8 + rowHeight + 4)
        stalledChip.Position = UDim2.fromOffset(EDGE + s.missionW + 8, 8 + rowHeight + 4)
    else
        center.AnchorPoint = Vector2.new(0.5, 0)
        center.Position = UDim2.new(0.5, 0, 0, 8)
        stalledChip.Position = UDim2.fromOffset(EDGE, 8 + rowHeight)
    end
end

local function weatherBanner(state)
    local now = os.clock()
    local weather = state and state.weather
    if weather and type(weather.kind) == "string" then
        local banner = if Msg.isMsg(weather.banner)
            then weather.banner
            elseif weather.stage == "warning" then {
                key = WARNING_KEYS[weather.kind] or "banner.sep.warning",
            }
            else { key = ACTIVE_KEYS[weather.kind] or "banner.sep.active" }
        return weather.kind, banner, weather.sourceDate
    end
    if endedBanner and now < endedBanner.untilTime then
        return endedBanner.kind,
            { key = ENDED_KEYS[endedBanner.kind] or "banner.sep.end" },
            endedBanner.sourceDate
    end
    return nil
end

local function refreshWeather(state)
    local kind, banner, sourceDate = weatherBanner(state)
    if not kind then
        weatherPanel.Visible = false
        return
    end
    weatherPanel.Visible = true
    weatherPanel.BackgroundColor3 = if kind == "GST"
        then Color3.fromRGB(70, 60, 150)
        else Color3.fromRGB(150, 45, 60)
    UI.msg(weatherName, EVENT_NAMES[kind] or "event.sep.name")
    UI.msg(weatherText, banner)
    if type(sourceDate) == "table" and sourceDate.year then
        weatherSource.Visible = true
        UI.msg(weatherSource, Msg.new("event.source", { date = Msg.date(sourceDate, "long") }))
    else
        weatherSource.Visible = false
    end
end

local function refreshRover(state)
    local rover = state.rover
    local key = nil
    if type(rover) == "table" then
        if rover.state == "broken" then
            key = "hud.rover.broken"
        elseif rover.state == "fsd" then
            local fsd = rover.fsd
            if type(fsd) == "table" and fsd.recovering then
                key = "hud.rover.recovering"
            elseif type(fsd) == "table" and fsd.stoppedBy then
                key = "hud.rover.stopped"
            else
                key = "hud.rover.out"
            end
        end
    end
    roverChip.Visible = key ~= nil
    if key then
        UI.msg(roverLabel, key)
    end
    local driving = RoverBoost.isDriving() and type(rover) == "table"
    batteryChip.Visible = driving
    if driving then
        UI.msg(
            batteryLabel,
            { key = "hud.battery.value", args = { n = ClientMath.wholeNumber(rover.battery) } }
        )
        local ratio = ClientMath.ratio(rover.battery, rover.batteryMax)
        batteryFill.Size = UDim2.fromScale(ratio, 1)
        batteryFill.BackgroundColor3 = if ratio < 0.2 then L.red else L.mint
    end
end

function HUDV2.init(_ctx)
    gui = UI.gui("HUDV2", 10, false)
    gui.Enabled = false
    root = Layout.root(gui)
    buildLeft()
    buildCenter()
    buildRight()
    applyLayout()
    Layout.changed:Connect(applyLayout)
    RoverBoost.drivingChanged:Connect(function()
        if lastState then
            refreshRover(lastState)
        end
    end)
end

function HUDV2.update(state)
    if type(state) ~= "table" then
        return
    end
    lastState = state
    local resources = state.resources or {}
    local cap = if type(state.cap) == "number" and state.cap > 0 then state.cap else DEFAULT_CAP
    local lowWarn = state.lowWarn or {}
    for _, res in ipairs(RESOURCES) do
        local chip = chips[res]
        local value = resources[res]
        UI.raw(chip.number, tostring(ClientMath.wholeNumber(value)))
        chip.fill.Size = UDim2.fromScale(ClientMath.ratio(value, cap), 1)
        local level = ClientMath.resourceLevel(value, LOW_THRESHOLD)
        local low = lowWarn[res] == true or level ~= "ok"
        -- compact는 칩이 좁아 "부족!" 글자 대신 테두리만 붉게 한다
        chip.low.Visible = low and not Layout.isCompact()
        chip.number.TextColor3 = if level == "zero" then L.red else L.white
        local stroke = chip.frame:FindFirstChildOfClass("UIStroke")
        if stroke then
            stroke.Color = if low then L.red else L.white
            stroke.Transparency = if low then 0 else UI.LUNA_STROKE_TRANSPARENCY
            stroke.Thickness = if low then 2 else 1
        end
    end

    if type(state.day) == "number" and type(state.totalDays) == "number" then
        UI.msg(dayLabel, { key = "hud.day", args = { day = state.day, total = state.totalDays } })
        UI.msg(daysLeftLabel, Msg.count("hud.days_left", math.max(0, state.totalDays - state.day)))
    end

    if Msg.isMsg(state.mission) then
        missionPanel.Visible = true
        UI.msg(missionLabel, state.mission)
    else
        missionPanel.Visible = false
    end

    stalledChip.Visible = state.stalled == true
    if state.stalled then
        UI.msg(stalledLabel, STALL_KEYS[state.stallReason] or "hud.stalled")
    end

    refreshWeather(state)
    refreshRover(state)
end

-- SpaceWeather(S->C) "ended" 단계: 끝났다는 배너를 잠깐 보여 준다
function HUDV2.onSpaceWeather(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.stage == "ended" then
        endedBanner = {
            kind = payload.kind,
            sourceDate = payload.sourceDate,
            untilTime = os.clock() + ENDED_BANNER_SECONDS,
        }
        refreshWeather(lastState)
        task.delay(ENDED_BANNER_SECONDS + 0.1, function()
            refreshWeather(lastState)
        end)
    end
end

function HUDV2.setVisible(visible)
    if gui then
        gui.Enabled = visible
    end
end

-- 토스트 위치 기준 (PC: 오른쪽 열, compact: 가운데 묶음)
function HUDV2.getRightColumn()
    return rightColumn
end

function HUDV2.getTopCenter()
    return center
end

function HUDV2.getRoot()
    return root
end

return HUDV2
