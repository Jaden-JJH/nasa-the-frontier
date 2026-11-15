--!nonstrict
-- 착륙선 콘솔 (CONTRACT_V2 2.3, V2_PLAN 15.4 Q28, 15.5 Q7 Q8 Q30 Q37, 15.6 Q33, 15.3 Q25).
-- 착륙선 안 콘솔 프롬프트를 누르면 열린다(Attribute OpenUI == "console" 또는 ActionKey == prompt.act.open_console).
-- 프롬프트에서 CLOSE_DISTANCE stud 넘게 멀어지거나, 플레이가 끝나거나, 닫기 버튼을 누르면 닫힌다.
-- 탭 3개
-- - 지도: 콘솔 지도(ConsoleMap) + 오른쪽 패널. 고른 얼음 후보지의 상태와 거리,
--   솔로는 로버 파견(왕복 약 N일, 에너지, 가져오는 물, 위험도, 서둘러 가기, DispatchRover),
--   멀티 관제사는 핀 찍기/지우기(SetPin), 파이프 해금 뒤에는 파이프 지점 고르기(SetPipeSite).
--   파이프 지점은 역할과 무관하게 누구나 고른다(CONTRACT_V2 9.1 7번): 지도를 못 쓰는 대원에게는 지도 대신
--   얼음 후보지 목록(PipeList)을 보이고, 고르면 오른쪽에 "여기에 물 파이프 연결" 버튼이 나온다.
--   아래에 로버 상태와 고장 때 원격 회수(RemoteRecoverRover). 멀티에서 관제사가 아니면 전체 지도는 잠긴다(Q25).
--   GST 중에는 지도가 지직거리고 파견, 핀, 파이프 버튼이 꺼진다.
-- - 기지: 시설 목록(상태, 하루 유지비, 멈추기/다시 켜기 SetFacilityPaused, Q33)과 태양광 패널 수.
-- - 대원: 역할 목록과 역할 바꾸기(ChooseRole). 솔로는 "모든 역할" 한 줄.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))
local Msg = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Msg"))

local ConsoleMap = require(script.Parent.ConsoleMap)
local FactUI = require(script.Parent.FactUI)
local Icons = require(script.Parent.Icons)
local Layout = require(script.Parent.Layout)
local Net = require(script.Parent.Net)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local WorldPoints = require(script.Parent.WorldPoints)
local L = UI.Luna

local ConsoleUI = {}

local PANEL_MAX = Vector2.new(1080, 640)
local SCREEN_GAP = 24
local HEADER_HEIGHT = 52
local PANEL_PAD = 18
local SIDE_WIDTH = 340
local CONTENT_GAP = 16
local CLOSE_DISTANCE = 25 -- studs (서버 "콘솔 근처" 검증 거리보다 작게)
local TICK_SECONDS = 0.2
local OPEN_UI_VALUE = "console"
local OPEN_ACTION_KEY = "prompt.act.open_console"

-- 리터럴 키 표 (I18N_PLAN 4.2)
local TAB_KEYS = { map = "map.tab.map", base = "map.tab.base", crew = "map.tab.crew" }
local TAB_ORDER = { "map", "base", "crew" }
local RISK_KEYS = {
    low = "map.risk.low",
    mid = "map.risk.mid",
    high = "map.risk.high",
    extreme = "map.risk.extreme",
}
local RISK_COLORS = {
    low = L.mint,
    mid = L.gold,
    high = L.orange,
    extreme = L.red,
}
local FACILITY_NAMES = {
    airlock = "facility.airlock.name",
    farm = "facility.farm.name",
    led = "facility.led.name",
    nutrient = "facility.nutrient.name",
    pipe = "facility.pipe.name",
    hydroponics = "facility.hydroponics.name",
    tower = "facility.tower.name",
    powerline = "facility.powerline.name",
}
local STATUS_KEYS = {
    locked = "map.fac.status.locked",
    available = "map.fac.status.available",
    active = "map.fac.status.active",
    paused = "map.fac.status.paused",
    idle = "map.fac.status.idle",
}
local STATUS_COLORS = {
    locked = L.faint,
    available = L.sky,
    building = L.gold,
    inspecting = L.gold,
    active = L.mint,
    paused = L.orange,
    idle = L.gold,
}
local STALL_KEYS = { energy = "hud.stalled.energy", water = "hud.stalled.water" }
local ROVER_KEYS = {
    parked = "map.rover.parked",
    driving = "map.rover.driving",
    broken = "map.rover.broken",
}

local gui
local root
local panel
local tabButtons = {}
local pages = {}
local currentTab = "map"
local mapHolder
local lockedNote
local pipeList -- 지도를 못 쓰는 대원용 파이프 지점 목록 패널
local pipeListRows -- 목록 버튼을 담는 프레임
local pipeListSig = "" -- 목록이 바뀌었을 때만 버튼을 다시 만든다
local sideScroll
local baseScroll
local crewScroll
local side = {} -- 오른쪽 패널 부품
local facilityRows = {} -- [id] = row
local panelsRow = nil -- 기지 탭 태양광 패널 줄 { frame, value }
local crewRows = {} -- [Player] = row
local switchPanel = nil -- 대원 탭 역할 바꾸기 묶음 { frame, buttons }

local anchor = nil -- 연 콘솔 프롬프트의 부모
local openFlag = false
local selectedSite = nil
local rush = false
local tickConn = nil
local tickClock = 0
local mapFactShown = false

-- 공용 부품 ------------------------------------------------------------------

local function textLabel(props)
    local merged = {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = 15,
        TextColor3 = L.body,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    }
    for key, value in pairs(props or {}) do
        merged[key] = value
    end
    return UI.create("TextLabel", merged)
end

local function section(name, order)
    return UI.lunaPanel({
        Name = name,
        LayoutOrder = order,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 0.92,
    }, { UI.padding(14), UI.list(Enum.FillDirection.Vertical, 8) }, 14)
end

local function row(name, order)
    return UI.create("Frame", {
        Name = name,
        LayoutOrder = order,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Wraps = true,
        }),
    })
end

local function pill(name, order, color)
    local label = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 13,
        TextColor3 = L.inkDeep,
    })
    local frame = UI.create("Frame", {
        Name = name,
        LayoutOrder = order,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = color or L.mint,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }), label })
    return frame, label
end

-- 아이콘 + 숫자 (자원 값)
local function amount(kind, order)
    local icon = Icons.resource(kind, 16)
    icon.LayoutOrder = 1
    local number = UI.create("TextLabel", {
        Name = "Number",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 16,
        TextColor3 = L.white,
    })
    local frame = UI.create("Frame", {
        Name = "Amount_" .. kind,
        LayoutOrder = order,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 4),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        icon,
        number,
    })
    return frame, number
end

local function scrollPage(name)
    return UI.create("ScrollingFrame", {
        Name = name,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 6,
        ScrollBarImageColor3 = L.dim,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, { UI.list(Enum.FillDirection.Vertical, 10), UI.padding({ 2, 8, 2, 10 }) })
end

-- 상태 도우미 ------------------------------------------------------------------

local function iceEntry(state, index)
    for _, site in ipairs(state and state.ice or {}) do
        if site.index == index then
            return site
        end
    end
    return nil
end

local function tripValues(site)
    local days, energy, risk = site.fsdDays or 1, site.fsdEnergy or 0, site.risk or "low"
    if rush then
        if type(site.rushDays) == "number" and type(site.rushEnergy) == "number" then
            return site.rushDays, site.rushEnergy, site.rushRisk or risk
        end
        return ClientMath.rushPreview(days, energy, risk, Session.missionDef().rover)
    end
    return days, energy, risk
end

-- 파견을 막는 이유 (Msg 또는 nil). 서버가 같은 경우에 보내는 토스트 문구 키를 그대로 쓴다
local function dispatchBlock(state, site, energyCost)
    if Session.isMulti() then
        return { key = "toast.rover.solo_only" }
    end
    local rover = state.rover or {}
    if rover.state == "broken" then
        return { key = "map.trip.blocked.broken" }
    elseif rover.state ~= nil and rover.state ~= "parked" then
        return { key = "toast.rover.busy" }
    end
    if Session.isGst() then
        return { key = "map.signal_lost" }
    elseif Session.isSep() then
        return { key = "toast.rover.sep_hold" }
    end
    if site.pipe then
        return {
            key = "toast.rover.site_piped",
            args = { site = ClientMath.iceLabel(site) },
        }
    end
    local cooldown = site.cooldownDaysLeft or 0
    if cooldown > 0 then
        return Msg.count("map.ice.cooldown", cooldown)
    end
    local energy = state.resources and state.resources.energy or 0
    if energy < energyCost then
        return { key = "toast.rover.need_energy", args = { energy = energyCost } }
    end
    return nil
end

-- 지도 탭 오른쪽 패널 ----------------------------------------------------------

local function buildSide()
    -- 고른 지점
    local siteSection = section("Site", 1)
    side.siteSection = siteSection
    side.siteTitle = textLabel({
        Name = "Title",
        LayoutOrder = 1,
        FontFace = UI.RoundHeavy,
        TextSize = 22,
        TextColor3 = L.white,
    })
    side.siteTitle.Parent = siteSection
    local statusRow = row("StatusRow", 2)
    statusRow.Parent = siteSection
    side.siteStatus, side.siteStatusLabel = pill("Status", 1, L.mint)
    side.siteStatus.Parent = statusRow
    side.siteDistance = UI.create("TextLabel", {
        Name = "Distance",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Mono,
        TextSize = 14,
        TextColor3 = L.dim,
        Parent = statusRow,
    })
    side.pickHint = textLabel({ Name = "PickHint", LayoutOrder = 3, TextColor3 = L.dim })
    side.pickHint.Parent = siteSection

    -- 로버 파견 (솔로)
    local trip = UI.create("Frame", {
        Name = "Trip",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = siteSection,
    }, { UI.list(Enum.FillDirection.Vertical, 8) })
    side.trip = trip
    local tripTitle = textLabel({
        Name = "Title",
        LayoutOrder = 1,
        FontFace = UI.MonoBold,
        TextSize = 13,
        TextColor3 = L.mint,
    })
    UI.msg(tripTitle, "map.trip.title")
    tripTitle.Parent = trip
    side.tripDays = textLabel({
        Name = "Days",
        LayoutOrder = 2,
        FontFace = UI.RoundHeavy,
        TextSize = 18,
        TextColor3 = L.white,
    })
    side.tripDays.Parent = trip
    local costRow = row("Cost", 3)
    costRow.Parent = trip
    local costLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 14,
        TextColor3 = L.dim,
        Parent = costRow,
    })
    UI.msg(costLabel, "map.trip.cost")
    local costAmount
    costAmount, side.tripEnergy = amount("energy", 2)
    costAmount.Parent = costRow
    local waterLabel = UI.create("TextLabel", {
        Name = "WaterLabel",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 14,
        TextColor3 = L.dim,
        Parent = costRow,
    })
    UI.msg(waterLabel, "map.trip.water")
    local waterAmount
    waterAmount, side.tripWater = amount("water", 4)
    waterAmount.Parent = costRow
    local riskRow = row("Risk", 4)
    riskRow.Parent = trip
    local riskLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 14,
        TextColor3 = L.dim,
        Parent = riskRow,
    })
    UI.msg(riskLabel, "map.trip.risk")
    side.tripRisk, side.tripRiskLabel = pill("RiskPill", 2, L.mint)
    side.tripRisk.Parent = riskRow

    -- 서둘러 가기 체크박스
    local mark = UI.checkMark(L.ink, {
        Name = "Mark",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Visible = false,
    })
    local box = UI.create("Frame", {
        Name = "Box",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(20, 20),
        BackgroundColor3 = L.gold,
        BackgroundTransparency = 1,
    }, { UI.corner(5), UI.stroke(L.gold, 1.5, 0), mark })
    local rushLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 15,
        TextColor3 = L.white,
    })
    UI.msg(rushLabel, "map.trip.rush")
    side.rushButton = UI.create("TextButton", {
        Name = "Rush",
        LayoutOrder = 5,
        Size = UDim2.fromOffset(0, 28),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        Parent = trip,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        box,
        rushLabel,
    })
    side.rushBox, side.rushMark = box, mark
    local rushHint =
        textLabel({ Name = "RushHint", LayoutOrder = 6, TextSize = 13, TextColor3 = L.dim })
    UI.msg(rushHint, "map.trip.rush_hint")
    rushHint.Parent = trip
    side.blocked = textLabel({
        Name = "Blocked",
        LayoutOrder = 7,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.orange,
    })
    side.blocked.Parent = trip
    side.send =
        UI.lunaButton({ Name = "Send", LayoutOrder = 8, Size = UDim2.new(1, 0, 0, 46) }, true)
    UI.msg(side.send, "map.trip.send")
    side.send.Parent = trip

    -- 관제사 핀 (멀티)
    local pinBox = UI.create("Frame", {
        Name = "Pin",
        LayoutOrder = 5,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = siteSection,
    }, { UI.list(Enum.FillDirection.Vertical, 8) })
    side.pinBox = pinBox
    -- 관제사 역할 미션(길잡이) 진행: 배지 이름 + n / goal 또는 완료 (C4, 멀티만)
    side.guideBadge = UI.create("TextLabel", {
        Name = "Badge",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 15,
        TextColor3 = L.gold,
    })
    UI.msg(side.guideBadge, "rolemission.guide.badge")
    side.guideProgress = UI.create("TextLabel", {
        Name = "Progress",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.MonoBold,
        TextSize = 15,
        TextColor3 = L.white,
    })
    side.guideRow = UI.create("Frame", {
        Name = "Guide",
        LayoutOrder = 0,
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = pinBox,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        side.guideBadge,
        side.guideProgress,
    })
    side.pinHint = textLabel({ Name = "Hint", LayoutOrder = 1, TextColor3 = L.dim })
    UI.msg(side.pinHint, "map.pin.hint")
    side.pinHint.Parent = pinBox
    side.pinSet =
        UI.lunaButton({ Name = "PinSet", LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 44) }, true)
    UI.msg(side.pinSet, "map.pin.set")
    side.pinSet.Parent = pinBox
    side.pinClear =
        UI.lunaButton({ Name = "PinClear", LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 40) }, false)
    UI.msg(side.pinClear, "map.pin.clear")
    side.pinClear.Parent = pinBox

    -- 파이프 지점 고르기
    local pipeBox = UI.create("Frame", {
        Name = "Pipe",
        LayoutOrder = 6,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = siteSection,
    }, { UI.list(Enum.FillDirection.Vertical, 8) })
    side.pipeBox = pipeBox
    side.pipeHint =
        textLabel({ Name = "Hint", LayoutOrder = 1, Font = UI.FontBold, TextColor3 = L.sky })
    side.pipeHint.Parent = pipeBox
    side.pipeButton = UI.lunaButton(
        { Name = "PipeConnect", LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 44) },
        false
    )
    UI.msg(side.pipeButton, "map.pipe.connect")
    side.pipeButton.Parent = pipeBox

    -- 로버
    local roverSection = section("Rover", 2)
    side.roverSection = roverSection
    local roverTitle = textLabel({
        Name = "Title",
        LayoutOrder = 1,
        FontFace = UI.MonoBold,
        TextSize = 13,
        TextColor3 = L.mint,
    })
    UI.msg(roverTitle, "map.legend.rover")
    roverTitle.Parent = roverSection
    local roverRow = row("StateRow", 2)
    roverRow.Parent = roverSection
    side.roverState, side.roverStateLabel = pill("State", 1, L.mint)
    side.roverState.Parent = roverRow
    side.roverDamage = UI.create("TextLabel", {
        Name = "Damage",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Mono,
        TextSize = 13,
        TextColor3 = L.dim,
        Parent = roverRow,
    })
    side.recoverHint = textLabel({ Name = "RecoverHint", LayoutOrder = 3, TextColor3 = L.body })
    side.recoverHint.Parent = roverSection
    side.recover =
        UI.lunaButton({ Name = "Recover", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 44) }, false)
    UI.scaledText(side.recover, 16, 11)
    side.recover.Parent = roverSection

    siteSection.Parent = sideScroll
    roverSection.Parent = sideScroll

    -- 버튼 동작
    side.rushButton.Activated:Connect(function()
        rush = not rush
        ConsoleUI.refresh()
    end)
    side.send.Activated:Connect(function()
        if side.send.Active and selectedSite then
            Net.fire("DispatchRover", selectedSite, rush)
        end
    end)
    side.pinSet.Activated:Connect(function()
        if side.pinSet.Active and selectedSite then
            Net.fire("SetPin", selectedSite)
        end
    end)
    side.pinClear.Activated:Connect(function()
        if side.pinClear.Active then
            Net.fire("SetPin", nil)
        end
    end)
    side.pipeButton.Activated:Connect(function()
        if side.pipeButton.Active and selectedSite then
            Net.fire("SetPipeSite", selectedSite)
        end
    end)
    side.recover.Activated:Connect(function()
        if side.recover.Active then
            Net.fire("RemoteRecoverRover")
        end
    end)
end

-- 관제사 길잡이 미션 진행 (핀 상자 맨 위)
local function refreshGuide(state)
    local mission = ClientMath.roleMissionOf(state, Players.LocalPlayer.UserId)
    local show = mission ~= nil and mission.id == "guide"
    side.guideRow.Visible = show
    if not show then
        return
    end
    if mission.done then
        UI.msg(side.guideProgress, "rolemission.done")
        side.guideProgress.TextColor3 = L.mint
    else
        UI.msg(
            side.guideProgress,
            { key = "fmt.fraction", args = { value = mission.progress, max = mission.goal } }
        )
        side.guideProgress.TextColor3 = L.white
    end
end

local function refreshSite(state)
    refreshGuide(state)
    local site = selectedSite and iceEntry(state, selectedSite)
    local canMap = Session.canUseMap()
    local gst = Session.isGst()
    local pipeOpen = ClientMath.pipePickOpen(state)
    -- 지도를 못 쓰는 대원도 파이프 지점은 고른다 (고른 직후 "연결됨" 안내도 보이게)
    side.siteSection.Visible = canMap
        or pipeOpen
        or (selectedSite ~= nil and state.pipeSite == selectedSite)
    if not site then
        UI.msg(side.siteTitle, "map.tab.map")
        side.siteStatus.Visible = false
        side.siteDistance.Visible = false
        side.pickHint.Visible = true
        UI.msg(side.pickHint, if pipeOpen then "toast.pipe.pick_site" else "toast.rover.pick_site")
        side.trip.Visible = false
        side.pinBox.Visible = Session.myRole() == "controller"
        side.pinSet.Visible = false
        side.pinClear.Visible = Session.pinSite ~= nil
        UI.setButtonEnabled(side.pinClear, not gst, false)
        side.pipeBox.Visible = false
        return
    end
    side.pickHint.Visible = false
    UI.msg(side.siteTitle, ClientMath.iceLabel(site))
    side.siteStatus.Visible = true
    local cooldown = site.cooldownDaysLeft or 0
    if site.pipe then
        UI.msg(side.siteStatusLabel, "map.ice.piped")
        side.siteStatus.BackgroundColor3 = L.sky
    elseif cooldown > 0 then
        UI.msg(side.siteStatusLabel, Msg.count("map.ice.cooldown", cooldown))
        side.siteStatus.BackgroundColor3 = L.faint
    else
        UI.msg(side.siteStatusLabel, "map.ice.ready")
        side.siteStatus.BackgroundColor3 = L.mint
    end
    -- 거리: 서버 값(BaseExit 기준 실측, 규칙과 같은 값), 없으면 월드에서 잰다 (1 stud = 1 m로 표시, 핀 목업과 같음)
    local meters = if type(site.distance) == "number" then site.distance else nil
    if not meters then
        local missionId = state.missionId or "C"
        local from = WorldPoints.marker("BaseExit", missionId)
            or WorldPoints.marker("Lander", missionId)
        local to = WorldPoints.iceSite(site.index, site.markerName, missionId)
        if from and to then
            meters = ClientMath.horizontalDistance(from, to)
        end
    end
    side.siteDistance.Visible = meters ~= nil
    if meters then
        local rounded = ClientMath.toMeters(meters, MissionConfig.metersPerStud)
        UI.msg(side.siteDistance, { key = "map.ice.distance", args = { n = rounded } })
    end

    -- 솔로 파견
    local solo = not Session.isMulti()
    side.trip.Visible = solo
    if solo then
        local days, energy, risk = tripValues(site)
        UI.msg(side.tripDays, Msg.count("map.trip.days", days))
        UI.raw(side.tripEnergy, tostring(energy))
        UI.raw(side.tripWater, tostring(Session.missionDef().ice.amountPerTrip))
        UI.msg(side.tripRiskLabel, RISK_KEYS[risk] or "map.risk.low")
        side.tripRisk.BackgroundColor3 = RISK_COLORS[risk] or L.mint
        side.rushBox.BackgroundTransparency = if rush then 0 else 1
        side.rushMark.Visible = rush
        local block = dispatchBlock(state, site, energy)
        side.blocked.Visible = block ~= nil
        if block then
            UI.msg(side.blocked, block)
        end
        UI.setButtonEnabled(side.send, block == nil, true)
    end

    -- 관제사 핀
    local controller = Session.myRole() == "controller"
    side.pinBox.Visible = controller
    if controller then
        local pinnedHere = Session.pinSite == site.index
        side.pinSet.Visible = not pinnedHere
        side.pinClear.Visible = Session.pinSite ~= nil
        UI.setButtonEnabled(side.pinSet, not gst, true)
        UI.setButtonEnabled(side.pinClear, not gst, false)
    end

    -- 파이프 지점
    local chosenHere = state.pipeSite == site.index
    side.pipeBox.Visible = pipeOpen or chosenHere
    if chosenHere then
        UI.msg(side.pipeHint, {
            key = "toast.pipe.site_set",
            args = { site = ClientMath.iceLabel(site) },
        })
        side.pipeButton.Visible = false
    elseif pipeOpen then
        UI.msg(side.pipeHint, "toast.pipe.pick_site")
        side.pipeButton.Visible = true
        UI.setButtonEnabled(side.pipeButton, not gst and not site.pipe, false)
    end
end

local function refreshRover(state)
    local rover = state.rover or {}
    local key
    local color = L.mint
    if rover.state == "fsd" then
        local fsd = rover.fsd or {}
        if fsd.recovering then
            key = "map.rover.recovering"
        elseif fsd.stoppedBy then
            key = "map.rover.stopped"
        elseif fsd.phase == "return" then
            key = "map.rover.back"
        else
            key = "map.rover.out"
        end
        color = if fsd.stoppedBy then L.orange else L.sky
    else
        key = ROVER_KEYS[rover.state] or "map.rover.parked"
        if rover.state == "broken" then
            color = L.red
        elseif rover.state == "driving" then
            color = L.gold
        end
    end
    UI.msg(side.roverStateLabel, key)
    side.roverState.BackgroundColor3 = color
    local maxDamage = rover.maxDamage or Session.missionDef().rover.maxDamage or 3
    UI.msg(
        side.roverDamage,
        { key = "map.rover.damage", args = { n = rover.damage or 0, max = maxDamage } }
    )

    local broken = rover.state == "broken"
    side.recoverHint.Visible = broken
    side.recover.Visible = broken
    if broken then
        local info = rover.broken
        local walkable = type(info) == "table" and info.walkable == true
        UI.msg(
            side.recoverHint,
            if walkable then "map.recover.walk_hint" else "map.recover.far_hint"
        )
        UI.msg(
            side.recover,
            Msg.count("map.recover.button", Session.missionDef().rover.remoteRecoverDays or 1)
        )
        UI.setButtonEnabled(side.recover, not Session.isGst(), false)
    end
end

-- 기지 탭 ------------------------------------------------------------------------

local function facilityIds(state)
    local def = Session.missionDef()
    local ids = {}
    for _, defId in ipairs(def.facilityOrder or {}) do
        local facilityDef = def.facilities[defId]
        if facilityDef and facilityDef.multi then
            local found = {}
            for id in pairs(state.facilities or {}) do
                if id == defId or string.match(id, "^" .. defId .. "%d+$") then
                    table.insert(found, id)
                end
            end
            table.sort(found)
            if #found == 0 then
                table.insert(found, defId)
            end
            for _, id in ipairs(found) do
                table.insert(ids, { id = id, defId = defId })
            end
        else
            table.insert(ids, { id = defId, defId = defId })
        end
    end
    return ids
end

local function makeFacilityRow(order)
    local name = textLabel({
        Name = "Name",
        LayoutOrder = 1,
        Size = UDim2.new(1, -150, 0, 0),
        FontFace = UI.RoundHeavy,
        TextSize = 17,
        TextColor3 = L.white,
    })
    local statusPill, statusLabel = pill("Status", 1, L.mint)
    local detail =
        textLabel({ Name = "Detail", LayoutOrder = 3, TextSize = 13, TextColor3 = L.dim })
    local upkeepRow = row("Upkeep", 4)
    local upkeepLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 13,
        TextColor3 = L.dim,
        Parent = upkeepRow,
    })
    UI.msg(upkeepLabel, "map.fac.upkeep")
    local energyAmount, energyNumber = amount("energy", 2)
    energyAmount.Parent = upkeepRow
    local waterAmount, waterNumber = amount("water", 3)
    waterAmount.Parent = upkeepRow
    local free = UI.create("TextLabel", {
        Name = "Free",
        LayoutOrder = 4,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 14,
        TextColor3 = L.mint,
        Parent = upkeepRow,
    })
    UI.msg(free, "map.fac.free")
    local button = UI.lunaButton({
        Name = "Toggle",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(130, 36),
        TextSize = 15,
    }, false)
    UI.scaledText(button, 15, 10)
    local top = UI.create("Frame", {
        Name = "Top",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { name, button })
    local statusRow = row("StatusRow", 2)
    statusPill.Parent = statusRow
    local frame = UI.lunaPanel({
        Name = "Facility" .. order,
        LayoutOrder = order,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 0.92,
    }, {
        UI.padding(12),
        UI.list(Enum.FillDirection.Vertical, 6),
        top,
        statusRow,
        detail,
        upkeepRow,
    }, 14)
    local r = {
        frame = frame,
        name = name,
        statusPill = statusPill,
        statusLabel = statusLabel,
        detail = detail,
        energyAmount = energyAmount,
        energyNumber = energyNumber,
        waterAmount = waterAmount,
        waterNumber = waterNumber,
        free = free,
        button = button,
        id = nil,
        paused = false,
    }
    button.Activated:Connect(function()
        if button.Active and r.id then
            Net.fire("SetFacilityPaused", r.id, not r.paused)
        end
    end)
    return r
end

local function refreshBase(state)
    local def = Session.missionDef()
    local order = 1
    -- 태양광 패널 줄
    if not panelsRow then
        local panelRow = UI.lunaPanel({
            Name = "Panels",
            LayoutOrder = 1,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 0.92,
        }, { UI.padding(12), UI.list(Enum.FillDirection.Horizontal, 10) }, 14)
        local label = UI.create("TextLabel", {
            Name = "Label",
            LayoutOrder = 1,
            Size = UDim2.fromOffset(0, 22),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.RoundHeavy,
            TextSize = 17,
            TextColor3 = L.white,
            Parent = panelRow,
        })
        UI.msg(label, "map.fac.panels")
        local value = UI.create("TextLabel", {
            Name = "Value",
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, 22),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.MonoBold,
            TextSize = 16,
            TextColor3 = L.gold,
            Parent = panelRow,
        })
        local hint =
            textLabel({ Name = "PauseHint", LayoutOrder = 0, TextSize = 14, TextColor3 = L.dim })
        UI.msg(hint, "map.fac.pause_hint")
        hint.Parent = baseScroll
        panelRow.Parent = baseScroll
        panelsRow = { frame = panelRow, value = value }
    end
    local panels = state.panels or {}
    UI.msg(
        panelsRow.value,
        { key = "fmt.fraction", args = { value = panels.installed or 0, max = panels.total or 0 } }
    )

    local used = {}
    for _, item in ipairs(facilityIds(state)) do
        order += 1
        used[item.id] = true
        local r = facilityRows[item.id]
        if not r then
            r = makeFacilityRow(order)
            r.frame.Parent = baseScroll
            facilityRows[item.id] = r
        end
        r.frame.LayoutOrder = order
        r.id = item.id
        local facilityDef = def.facilities[item.defId] or {}
        UI.msg(r.name, FACILITY_NAMES[item.defId] or "facility.farm.name")

        local status, daysLeft, detailMsg, stalled
        if item.defId == "airlock" then
            local airlock = state.airlock or {}
            status = airlock.status or "idle"
            daysLeft = airlock.daysLeft or 0
            stalled = airlock.stalled == true
        else
            local f = (state.facilities or {})[item.id] or {}
            status = f.status or "locked"
            daysLeft = f.daysLeft or 0
            stalled = f.stalled == true
            if status == "locked" and Msg.isMsg(f.unlockMsg) then
                detailMsg = f.unlockMsg
            elseif status == "active" and type(f.nextHarvestIn) == "number" then
                detailMsg = Msg.count("map.fac.harvest", f.nextHarvestIn)
            end
        end
        if status == "building" then
            UI.msg(r.statusLabel, Msg.count("map.fac.status.building", daysLeft))
        elseif status == "inspecting" then
            UI.msg(r.statusLabel, Msg.count("map.fac.status.inspecting", daysLeft))
        else
            UI.msg(r.statusLabel, STATUS_KEYS[status] or "map.fac.status.locked")
        end
        r.statusPill.BackgroundColor3 = STATUS_COLORS[status] or L.faint
        -- 자원이 모자라 규칙이 멈춘 시설 (facilities[id].stalled, 덜 중요한 시설부터 멈춤)
        if stalled then
            r.statusPill.BackgroundColor3 = L.red
            detailMsg = { key = STALL_KEYS[state.stallReason] or "hud.stalled" }
        end
        r.detail.Visible = detailMsg ~= nil
        if detailMsg then
            UI.msg(r.detail, detailMsg)
        end

        -- 서버가 보낸 지금 유지비(LED 전력, 영양분 절약 반영)가 있으면 그것, 없으면 MissionConfig 정의 값
        local facilityState = (state.facilities or {})[item.id]
        local upkeep = if type(facilityState) == "table"
                and type(facilityState.upkeep) == "table"
            then facilityState.upkeep
            else facilityDef.upkeep or {}
        local e, w = upkeep.energy or 0, upkeep.water or 0
        r.energyAmount.Visible = e > 0
        r.waterAmount.Visible = w > 0
        r.free.Visible = e <= 0 and w <= 0
        UI.raw(r.energyNumber, tostring(e))
        UI.raw(r.waterNumber, tostring(w))

        local canToggle = facilityDef.canPause ~= false
            and (status == "active" or status == "paused")
        r.paused = status == "paused"
        r.button.Visible = canToggle
        if canToggle then
            UI.msg(r.button, if r.paused then "map.fac.resume" else "map.fac.pause")
            UI.setButtonEnabled(r.button, true, r.paused)
        end
    end
    for id, r in pairs(facilityRows) do
        if not used[id] then
            r.frame:Destroy()
            facilityRows[id] = nil
        end
    end
end

-- 대원 탭 ------------------------------------------------------------------------

local function refreshCrew()
    local multi = Session.isMulti()
    local present = {}
    local counts = ClientMath.roleCounts(Session.roles)
    local myRole = Session.myRole()
    for index, player in ipairs(Players:GetPlayers()) do
        present[player] = true
        local r = crewRows[player]
        if not r then
            local name = UI.create("TextLabel", {
                Name = "Name",
                LayoutOrder = 1,
                Size = UDim2.fromOffset(0, 24),
                AutomaticSize = Enum.AutomaticSize.X,
                FontFace = UI.RoundHeavy,
                TextSize = 17,
                TextColor3 = L.white,
            })
            local you = UI.create("TextLabel", {
                Name = "You",
                LayoutOrder = 2,
                Size = UDim2.fromOffset(0, 24),
                AutomaticSize = Enum.AutomaticSize.X,
                Font = UI.Font,
                TextSize = 14,
                TextColor3 = L.mint,
            })
            UI.msg(you, "map.crew.you")
            local rolePill, roleLabel = pill("Role", 3, L.gold)
            local top = row("Top", 1)
            name.Parent = top
            you.Parent = top
            rolePill.Parent = top
            local duty =
                textLabel({ Name = "Duty", LayoutOrder = 2, TextSize = 14, TextColor3 = L.dim })
            local frame = UI.lunaPanel({
                Name = "Crew_" .. player.UserId,
                Size = UDim2.fromScale(1, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 0.92,
                Parent = crewScroll,
            }, { UI.padding(12), UI.list(Enum.FillDirection.Vertical, 6), top, duty }, 14)
            r = {
                frame = frame,
                name = name,
                you = you,
                rolePill = rolePill,
                roleLabel = roleLabel,
                duty = duty,
            }
            crewRows[player] = r
        end
        r.frame.LayoutOrder = 10 + index
        UI.raw(r.name, player.DisplayName)
        r.you.Visible = player == Players.LocalPlayer
        local role = Session.roleOf(player.UserId)
        r.rolePill.Visible = role ~= nil
        r.duty.Visible = role ~= nil
        if role then
            UI.msg(r.roleLabel, Session.ROLE_NAMES[role] or "role.solo.name")
            UI.msg(r.duty, Session.ROLE_DUTIES[role] or "role.solo.duty")
        end
    end
    for player, r in pairs(crewRows) do
        if not present[player] then
            r.frame:Destroy()
            crewRows[player] = nil
        end
    end

    -- 역할 바꾸기 버튼 (멀티)
    if not switchPanel then
        local title = textLabel({
            Name = "Title",
            LayoutOrder = 1,
            FontFace = UI.MonoBold,
            TextSize = 13,
            TextColor3 = L.mint,
        })
        UI.msg(title, "map.crew.title")
        local buttons = row("Buttons", 2)
        local roleButtons = {}
        for i, role in ipairs(Session.ROLE_ORDER) do
            local button = UI.lunaButton({
                Name = "Switch_" .. role,
                LayoutOrder = i,
                Size = UDim2.fromOffset(0, 40),
                AutomaticSize = Enum.AutomaticSize.X,
                TextSize = 15,
                Parent = buttons,
            }, false)
            button.Activated:Connect(function()
                if button.Active then
                    Net.fire("ChooseRole", role)
                end
            end)
            roleButtons[role] = button
        end
        local frame = UI.lunaPanel({
            Name = "Switch",
            LayoutOrder = 1,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 0.88,
            Parent = crewScroll,
        }, { UI.padding(12), UI.list(Enum.FillDirection.Vertical, 8), title, buttons }, 14)
        switchPanel = { frame = frame, buttons = roleButtons }
    end
    local switch = switchPanel
    switch.frame.Visible = multi
    for role, button in pairs(switch.buttons) do
        local count = counts[role] or 0
        local max = Session.roleCapacity(role)
        button.Visible = max > 0 or myRole == role
        local mine = myRole == role
        UI.msg(button, {
            key = "map.crew.slot",
            args = { role = { key = Session.ROLE_NAMES[role] }, value = count, max = max },
        })
        UI.setButtonEnabled(button, not mine and count < max, false)
        if mine then
            button.BackgroundTransparency = 0.6
            button.BackgroundColor3 = L.mint
            button.TextColor3 = L.inkDeep
        end
    end
end

-- 탭과 배치 ----------------------------------------------------------------------

local function setTab(tab)
    currentTab = tab
    for name, page in pairs(pages) do
        page.Visible = name == tab
    end
    for name, button in pairs(tabButtons) do
        local selected = name == tab
        button.BackgroundColor3 = if selected then L.mint else L.white
        button.BackgroundTransparency = if selected then 0 else 0.88
        button.TextColor3 = if selected then L.ink else L.white
    end
    if tab == "map" then
        ConsoleMap.rebuild()
        if openFlag and Session.canUseMap() and not mapFactShown then
            mapFactShown = true
            FactUI.onMapOpened()
        end
    end
end

local function fit()
    if not panel then
        return
    end
    local scale = Layout.scale()
    local abs = gui.AbsoluteSize
    if abs.X <= 0 or abs.Y <= 0 then
        abs = Vector2.new(1280, 720) * scale
    end
    local space = abs / scale
    local width = math.min(PANEL_MAX.X, space.X - SCREEN_GAP)
    local height = math.min(PANEL_MAX.Y, space.Y - SCREEN_GAP)
    panel.Size = UDim2.fromOffset(width, height)
    local contentHeight = height - HEADER_HEIGHT - PANEL_PAD * 2
    local sideWidth = math.min(SIDE_WIDTH, math.floor(width * 0.4))
    local mapWidth = width - PANEL_PAD * 2 - sideWidth - CONTENT_GAP
    ConsoleMap.setSize(mapWidth, contentHeight)
    lockedNote.Size = UDim2.fromOffset(mapWidth, contentHeight)
    pipeList.Size = UDim2.fromOffset(mapWidth, contentHeight)
    sideScroll.Size = UDim2.fromOffset(sideWidth, contentHeight)
    sideScroll.Position = UDim2.fromOffset(mapWidth + CONTENT_GAP, 0)
    if openFlag and currentTab == "map" then
        ConsoleMap.rebuild()
    end
end

local function onTick(dt)
    tickClock += dt
    if tickClock < TICK_SECONDS then
        return
    end
    tickClock = 0
    -- 콘솔에서 멀어지면 닫는다
    local me = WorldPoints.character(Players.LocalPlayer)
    local at = anchor and WorldPoints.positionOf(anchor)
    if not anchor or not anchor.Parent or (me and at and (me - at).Magnitude > CLOSE_DISTANCE) then
        ConsoleUI.close()
        return
    end
    if currentTab == "map" then
        ConsoleMap.tick()
    end
end

-- 파이프 지점 목록 (지도를 못 쓰는 대원). 후보지가 바뀌면 버튼을 다시 만들고, 고른 줄은 민트로
local function refreshPipeList(state)
    local list = ClientMath.pipePickSites(state)
    local parts = {}
    for _, site in ipairs(list) do
        table.insert(parts, tostring(site.index) .. ":" .. tostring(site.distance))
    end
    local sig = table.concat(parts, ",")
    if sig ~= pipeListSig then
        pipeListSig = sig
        for _, child in ipairs(pipeListRows:GetChildren()) do
            if child:IsA("GuiButton") then
                child:Destroy()
            end
        end
        for order, site in ipairs(list) do
            local button = UI.lunaButton({
                Name = "Site" .. site.index,
                LayoutOrder = order,
                Size = UDim2.new(1, 0, 0, 44),
            }, false)
            button:SetAttribute("SiteIndex", site.index)
            local label = ClientMath.iceLabel(site)
            if type(site.distance) == "number" then
                label = {
                    key = "fmt.list.start",
                    args = {
                        a = label,
                        b = {
                            key = "map.ice.distance",
                            args = {
                                n = ClientMath.toMeters(site.distance, MissionConfig.metersPerStud),
                            },
                        },
                    },
                }
            end
            UI.msg(button, label)
            button.Activated:Connect(function()
                selectedSite = site.index
                ConsoleUI.refresh()
            end)
            button.Parent = pipeListRows
        end
    end
    for _, child in ipairs(pipeListRows:GetChildren()) do
        if child:IsA("GuiButton") then
            local chosen = child:GetAttribute("SiteIndex") == selectedSite
            UI.setButtonEnabled(child, true, chosen)
        end
    end
end

-- 상태나 역할이 바뀌면 보이는 탭을 다시 그린다
function ConsoleUI.refresh()
    local state = Session.state
    if not openFlag or not state then
        return
    end
    local canMap = Session.canUseMap()
    local listOpen = not canMap and ClientMath.pipePickOpen(state)
    mapHolder.Visible = canMap
    lockedNote.Visible = not canMap and not listOpen
    pipeList.Visible = listOpen
    if listOpen then
        refreshPipeList(state)
    end
    ConsoleMap.setSelected(selectedSite)
    ConsoleMap.refresh()
    refreshSite(state)
    refreshRover(state)
    refreshBase(state)
    refreshCrew()
end

function ConsoleUI.open(promptParent)
    if Session.phase() ~= "playing" then
        return
    end
    anchor = promptParent
    if openFlag then
        return
    end
    openFlag = true
    gui.Enabled = true
    fit()
    local pickPipe = ClientMath.pipePickOpen(Session.state)
    setTab(if Session.canUseMap() or pickPipe then "map" else "base")
    ConsoleUI.refresh()
    tickConn = RunService.Heartbeat:Connect(onTick)
end

function ConsoleUI.close()
    if not openFlag then
        return
    end
    openFlag = false
    gui.Enabled = false
    anchor = nil
    if tickConn then
        tickConn:Disconnect()
        tickConn = nil
    end
end

function ConsoleUI.isOpen()
    return openFlag
end

-- 이 프롬프트가 콘솔을 여는지 (서버 Attribute OpenUI 또는 ActionKey)
function ConsoleUI.isConsolePrompt(prompt)
    return prompt:GetAttribute("OpenUI") == OPEN_UI_VALUE
        or prompt:GetAttribute("ActionKey") == OPEN_ACTION_KEY
end

function ConsoleUI.init(_ctx)
    gui = UI.gui("Console", 60)
    gui.Enabled = false
    root = Layout.root(gui)
    UI.create("Frame", {
        Name = "Dim",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.inkDeep,
        BackgroundTransparency = 0.45,
        Active = true,
        Parent = root,
    })

    local title = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 36),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 24,
        TextColor3 = L.white,
    })
    UI.msg(title, "map.console.title")
    local tabs = UI.create("Frame", {
        Name = "Tabs",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 36),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
    })
    for i, name in ipairs(TAB_ORDER) do
        local button = UI.lunaButton({
            Name = "Tab_" .. name,
            LayoutOrder = i,
            Size = UDim2.fromOffset(0, 34),
            AutomaticSize = Enum.AutomaticSize.X,
            TextSize = 15,
            Parent = tabs,
        }, false)
        UI.msg(button, TAB_KEYS[name])
        button.Activated:Connect(function()
            setTab(name)
            ConsoleUI.refresh()
        end)
        tabButtons[name] = button
    end
    local close = UI.lunaButton({
        Name = "Close",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(0, 36),
        AutomaticSize = Enum.AutomaticSize.X,
        TextSize = 15,
    }, false)
    UI.msg(close, "map.close")
    close.Activated:Connect(function()
        ConsoleUI.close()
    end)
    local header = UI.create("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
        BackgroundTransparency = 1,
    }, {
        UI.create("Frame", {
            Name = "Left",
            Size = UDim2.new(1, -120, 1, 0),
            BackgroundTransparency = 1,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, 18),
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Center,
            }),
            title,
            tabs,
        }),
        close,
    })

    -- 지도 페이지
    local mapPage = UI.create("Frame", {
        Name = "MapPage",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    })
    mapHolder = UI.create("Frame", {
        Name = "MapHolder",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Parent = mapPage,
    })
    ConsoleMap.init(mapHolder, function(index)
        selectedSite = index
        ConsoleUI.refresh()
    end)
    local lockedText = textLabel({
        Name = "Text",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(0.8, 0),
        FontFace = UI.RoundBold,
        TextSize = 18,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Center,
    })
    UI.msg(lockedText, "toast.map.controller_only")
    lockedNote = UI.lunaPanel({
        Name = "Locked",
        Size = UDim2.fromOffset(600, 460),
        BackgroundTransparency = 0.92,
        Visible = false,
        Parent = mapPage,
    }, { lockedText }, 14)
    -- 지도를 못 쓰는 대원용 파이프 지점 목록 (지도 그림 없이)
    local listHint = textLabel({
        Name = "Hint",
        LayoutOrder = 1,
        FontFace = UI.RoundBold,
        TextSize = 18,
        TextColor3 = L.sky,
    })
    UI.msg(listHint, "toast.pipe.pick_site")
    pipeListRows = UI.create("Frame", {
        Name = "Rows",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 8) })
    pipeList = UI.lunaPanel({
        Name = "PipeList",
        Size = UDim2.fromOffset(600, 460),
        BackgroundTransparency = 0.92,
        Visible = false,
        Parent = mapPage,
    }, {
        UI.padding(16),
        UI.list(Enum.FillDirection.Vertical, 12),
        listHint,
        pipeListRows,
    }, 14)
    sideScroll = scrollPage("Side")
    sideScroll.Parent = mapPage
    buildSide()

    baseScroll = scrollPage("BasePage")
    crewScroll = scrollPage("CrewPage")
    pages = { map = mapPage, base = baseScroll, crew = crewScroll }

    local content = UI.create("Frame", {
        Name = "Content",
        Position = UDim2.fromOffset(0, HEADER_HEIGHT),
        Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT),
        BackgroundTransparency = 1,
    }, { mapPage, baseScroll, crewScroll })

    panel = UI.lunaPanel({
        Name = "Panel",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PANEL_MAX.X, PANEL_MAX.Y),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.02,
        Parent = root,
    }, {
        UI.lunaGradient(),
        UI.padding(PANEL_PAD),
        header,
        content,
    }, 22)
    panel.Active = true

    setTab("map")
    fit()
    Layout.changed:Connect(fit)
    gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    Session.changed:Connect(function()
        if Session.phase() == "selecting" then
            mapFactShown = false -- 새 판에서 다시 지도 사실 카드
            selectedSite = nil
            rush = false
        end
        if openFlag then
            if Session.phase() ~= "playing" then
                ConsoleUI.close()
                return
            end
            ConsoleUI.refresh()
        end
    end)
end

return ConsoleUI
