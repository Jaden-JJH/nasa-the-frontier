--!nonstrict
-- v2 HUD (CONTRACT_V2 2.3, V2_PLAN 15.2 ~ 15.9). 루나 소프트 디자인.
-- - 왼쪽 위: 자원 3개 칩(아이콘 + 숫자 + 상한 100 막대, 20 미만이면 "부족!" 표시), 그 아래 기지 정지 표시
-- - 가운데 위: "Day x of 60"과 남은 일수, 미션 문구(서버 Msg), 우주 기상 배너(사건 이름, 문구, NASA DONKI 날짜 출처, Q36)
-- - 오른쪽 위: 로버 상태 칩(자율주행, 고장, 회수, 폭풍 대기), 배터리 칩(로버가 보이면 늘: 퍼센트와 막대, 충전 중이면
--   번개 아이콘이 깜빡임), 그 아래 충전 상태 알약(충전 중, 가득 참, 충전이 안 되는 이유: 기지 에너지가
--   MANUAL_DRIVE.chargeKeepEnergy 이하, 주차판 밖, 누가 타고 있음). 판정은 ClientMath.roverChargeView
-- - 가운데 위 마지막: 멀티 역할 미션 카드(C4, 점수와 무관). 미션 문구 바로 아래 같은 열이라 겹치지 않는다.
--   아이콘, 배지 이름, 진행 n / goal, 끝나면 체크와 "완료!" + 잠깐 커지는 효과. compact는 한 줄(설명 숨김)
-- 숫자는 화면용으로 내림(ClientMath.wholeNumber). 문구는 모두 Localizer(UI.msg)로 그린다.
-- compact(Layout.isCompact)는 칩과 글자를 줄이고 남은 일수 줄을 숨긴다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))
local Msg = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Msg"))

local TweenService = game:GetService("TweenService")

local Icons = require(script.Parent.Icons)
local Layout = require(script.Parent.Layout)
local RoverBoost = require(script.Parent.RoverBoost)
local UI = require(script.Parent.UI)
local L = UI.Luna

local HUDV2 = {}

local RESOURCES = { "energy", "water", "food" }
local LOW_THRESHOLD = MissionConfig.SCORE.lowThreshold
local CHARGE_KEEP = MissionConfig.MANUAL_DRIVE.chargeKeepEnergy
local BATTERY_LOW_RATIO = 0.2
local PULSE_SECONDS = 0.6
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
local chargeIcon
local chargePulse = nil
local chargeTag
local chargeTagLabel
local roleCard
local roleTitle
local roleIconSlot
local roleBadge
local roleProgress
local roleDone
local roleDesc
local roleScale
local roleStroke
local roleShown = nil -- { id, done } 지난번 그린 역할 미션 (끝나는 순간 효과용)

local lastState = nil
local endedBanner = nil -- { kind, sourceDate, untilTime }

-- 충전 상태 알약 색 (모드, 이유)
local function tagColor(view)
    if view.mode == "charging" then
        return L.gold
    elseif view.mode == "full" then
        return L.mint
    elseif view.reason == "energy" then
        return L.red
    end
    return L.orange
end

local function setChargePulse(on)
    if on then
        chargeIcon.Visible = true
        if not chargePulse then
            chargePulse = TweenService:Create(
                chargeIcon,
                TweenInfo.new(
                    PULSE_SECONDS,
                    Enum.EasingStyle.Sine,
                    Enum.EasingDirection.InOut,
                    -1,
                    true
                ),
                { Size = UDim2.fromOffset(12, 12) }
            )
            chargePulse:Play()
        end
    else
        chargeIcon.Visible = false
        if chargePulse then
            chargePulse:Cancel()
            chargePulse = nil
            chargeIcon.Size = UDim2.fromOffset(18, 18)
        end
    end
end

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

    -- 역할 미션 카드 (멀티)
    roleTitle = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 16),
        FontFace = UI.MonoBold,
        TextSize = 13,
        TextColor3 = L.gold,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(roleTitle, "rolemission.title")
    roleIconSlot = UI.create("Frame", {
        Name = "IconSlot",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(20, 20),
        BackgroundTransparency = 1,
    })
    roleBadge = UI.create("TextLabel", {
        Name = "Badge",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 16,
        TextColor3 = L.white,
    })
    roleProgress = UI.create("TextLabel", {
        Name = "Progress",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.MonoBold,
        TextSize = 15,
        TextColor3 = L.gold,
    })
    local doneLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 13,
        TextColor3 = L.ink,
    })
    UI.msg(doneLabel, "rolemission.done")
    local check = UI.checkMark(L.ink, { LayoutOrder = 1 })
    roleDone = UI.create("Frame", {
        Name = "Done",
        LayoutOrder = 4,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.mint,
        Visible = false,
    }, {
        UI.roundCorner(),
        UI.padding({ 0, 0, 6, 8 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 2),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        check,
        doneLabel,
    })
    local roleRow = UI.create("Frame", {
        Name = "Row",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        roleIconSlot,
        roleBadge,
        roleProgress,
        roleDone,
    })
    roleDesc = UI.create("TextLabel", {
        Name = "Desc",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = 14,
        TextColor3 = L.body,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    roleScale = UI.create("UIScale", { Scale = 1 })
    roleCard = UI.lunaPanel({
        Name = "RoleMission",
        LayoutOrder = 4,
        Size = UDim2.fromOffset(s.missionW, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.25,
        Visible = false,
    }, {
        roleScale,
        UI.padding({ 6, 8, 14, 14 }),
        UI.list(Enum.FillDirection.Vertical, 2),
        roleTitle,
        roleRow,
        roleDesc,
    }, 14)
    roleStroke = roleCard:FindFirstChildOfClass("UIStroke")

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
        roleCard,
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
    -- 충전 중 번개 (막대 오른쪽, 크기가 오르내린다). 18 x 18 칸 가운데에 둔다
    chargeIcon = Icons.resource("energy", 18)
    chargeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    chargeIcon.Position = UDim2.fromScale(0.5, 0.5)
    chargeIcon.Visible = false
    local chargeSlot = UI.create("Frame", {
        Name = "ChargeSlot",
        LayoutOrder = 4,
        Size = UDim2.fromOffset(18, 18),
        BackgroundTransparency = 1,
    }, { chargeIcon })
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
        chargeSlot,
    }, 17)

    chargeTagLabel = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 14,
        TextColor3 = L.inkDeep,
    })
    chargeTag = UI.create("Frame", {
        Name = "ChargeTag",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.gold,
        Visible = false,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }), chargeTagLabel })

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
        chargeTag,
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
    roleCard.Size = UDim2.fromOffset(s.missionW, 0)
    -- compact는 역할 미션을 한 줄로 (머리글과 설명 숨김)
    roleTitle.Visible = not Layout.isCompact()
    roleDesc.Visible = not Layout.isCompact()
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
    -- 배터리 칩: 로버가 보이면(주차, 운전) 늘 보인다. 자율주행과 고장은 위 칩이 말한다
    if type(rover) ~= "table" then
        batteryChip.Visible = false
        chargeTag.Visible = false
        setChargePulse(false)
        return
    end
    local resources = if type(state.resources) == "table" then state.resources else {}
    local view = ClientMath.roverChargeView({
        status = rover.state,
        atBase = rover.atBase,
        charging = rover.charging,
        battery = rover.battery,
        batteryMax = rover.batteryMax,
        percent = rover.batteryPercent,
        blocked = rover.chargeBlocked,
        serverReasons = type(rover.batteryPercent) == "number",
        energy = resources.energy,
        keep = CHARGE_KEEP,
        localDriving = RoverBoost.isDriving(),
    })
    local visible = view.mode ~= "hidden"
    batteryChip.Visible = visible
    if not visible then
        chargeTag.Visible = false
        setChargePulse(false)
        return
    end
    UI.msg(batteryLabel, ClientMath.batteryMsg(view.percent))
    local ratio = view.percent / 100
    batteryFill.Size = UDim2.fromScale(ratio, 1)
    batteryFill.BackgroundColor3 = if view.mode == "charging"
        then L.gold
        elseif ratio < BATTERY_LOW_RATIO then L.red
        else L.mint
    setChargePulse(view.mode == "charging")
    local label = ClientMath.chargeLabel(view, CHARGE_KEEP)
    chargeTag.Visible = label ~= nil
    if label then
        chargeTag.BackgroundColor3 = tagColor(view)
        UI.msg(chargeTagLabel, label)
    end
end

local ROLE_ICONS = {
    water = function(size)
        return Icons.resource("water", size)
    end,
    panels = function(size)
        return Icons.resource("energy", size)
    end,
    guide = function(size)
        return Icons.pin(size, L.mint)
    end,
    scout = function(size)
        return Icons.base(size, L.sky)
    end,
}

-- 끝나는 순간 카드가 잠깐 커지고 테두리가 민트로 빛난다
local function playRoleDoneEffect()
    roleScale.Scale = 1
    local grow = TweenService:Create(
        roleScale,
        TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { Scale = 1.08 }
    )
    grow.Completed:Once(function()
        TweenService:Create(roleScale, TweenInfo.new(0.25, Enum.EasingStyle.Quad), { Scale = 1 })
            :Play()
    end)
    grow:Play()
    if roleStroke then
        roleStroke.Color = L.mint
        roleStroke.Transparency = 0
        roleStroke.Thickness = 2
        TweenService:Create(
            roleStroke,
            TweenInfo.new(1.5, Enum.EasingStyle.Quad),
            { Transparency = UI.LUNA_STROKE_TRANSPARENCY, Thickness = 1 }
        ):Play()
    end
end

local function refreshRole(state)
    local mission = ClientMath.roleMissionOf(state, Players.LocalPlayer.UserId)
    roleCard.Visible = mission ~= nil
    if not mission then
        roleShown = nil
        return
    end
    local keys = ClientMath.ROLE_MISSION_KEYS[mission.id]
    if not roleShown or roleShown.id ~= mission.id then
        roleIconSlot:ClearAllChildren()
        ROLE_ICONS[mission.id](20).Parent = roleIconSlot
    end
    UI.msg(roleBadge, keys.badge)
    UI.msg(roleDesc, keys.desc)
    UI.msg(
        roleProgress,
        { key = "fmt.fraction", args = { value = mission.progress, max = mission.goal } }
    )
    roleProgress.TextColor3 = if mission.done then L.mint else L.gold
    roleDone.Visible = mission.done
    if mission.done and roleShown and roleShown.id == mission.id and not roleShown.done then
        playRoleDoneEffect()
    end
    roleShown = { id = mission.id, done = mission.done }
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
    refreshRole(state)
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
