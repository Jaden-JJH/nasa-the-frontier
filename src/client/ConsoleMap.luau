--!nonstrict
-- 착륙선 콘솔 지도 (CONTRACT_V2 2.3 ConsoleUI, V2_PLAN 15.3 ~ 15.5, 핀 목업 관제사 화면).
-- 월드 XZ를 지도 픽셀로 옮겨(ClientMath, 위 = -Z) 그린다: 기지, 얼음 후보지 5곳(번호, 쿨타임, 파이프), 관제사 핀,
-- 로버(주차, 직접 운전, 자율주행 이동, 고장 위치), 대원 위치. 얼음 후보지를 누르면 onSiteClicked(siteIndex).
-- GST(지자기 폭풍) 중에는 지도가 지직거리고 아이콘이 멈춘다(마지막 위치 유지, Q8 "통신 끊김").
-- 자율주행 아이콘은 하루 단위 진행(progress)을 왕복 일수로 나눠 그날 안에서 부드럽게 움직인다.
-- 한 화면에 하나만 있으므로 단일 모듈이다. 갱신은 ConsoleUI가 보일 때만 tick()으로 부른다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Icons = require(script.Parent.Icons)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local WorldPoints = require(script.Parent.WorldPoints)
local L = UI.Luna

local ConsoleMap = {}

local BOUNDS_PADDING = 40 -- studs
local MIN_SPAN = 200 -- studs
local INSET = 34 -- 지도 가장자리 여백(px, 라벨 자리)
local SITE_SIZE = 20
local SITE_SELECTED = 26
local ROVER_SIZE = 22
local CREW_SIZE = 12
local STATIC_STRIPES = 24
local STATIC_STEP = 0.12 -- 초

local SITE_READY = Color3.fromRGB(185, 167, 255) -- 목업 #b9a7ff
local SITE_COOLDOWN = Color3.fromRGB(109, 115, 152) -- 목업 #6d7398
local MAP_BG = Color3.fromRGB(11, 15, 38) -- 목업 #0b0f26

local frame
local canvas
local baseIcon
local roverIcon
local pinIcon
local offlineOverlay
local offlineStripes = {}
local sites = {} -- [index] = { button, circle, stroke, label, status }
local crewDots = {} -- [Player] = Frame
local onSiteClicked = nil

local fit = nil
local worldSites = {} -- [index] = Vector3
local selectedSite = nil
local lastBrokenFraction = 1
local trip = { progress = nil, changedAt = 0, site = nil }
local offline = false
local staticClock = 0

local function project(pos)
    if not fit or not pos then
        return nil
    end
    local x, y = ClientMath.project(fit, pos.X, pos.Z)
    x, y = ClientMath.clampToMap(fit, x, y, 6)
    return UDim2.fromOffset(INSET + x, INSET + y)
end

-- 지도 크기(가상 좌표). setSize로 정한 오프셋을 그대로 쓴다
local function mapSize()
    return frame.Size.X.Offset, frame.Size.Y.Offset
end

-- 지도 경계를 기지 표시와 얼음 후보지 위치로 다시 잡는다
local function rebuildFit(state)
    local missionId = state and state.missionId or "C"
    local points = {}
    for _, name in ipairs(WorldPoints.BASE_MARKERS) do
        local pos = WorldPoints.marker(name, missionId)
        if pos then
            table.insert(points, pos)
        end
    end
    worldSites = {}
    for _, site in ipairs(state and state.ice or {}) do
        local pos = WorldPoints.iceSite(site.index, site.markerName, missionId)
        if pos then
            worldSites[site.index] = pos
            table.insert(points, pos)
        end
    end
    local width, height = mapSize()
    local bounds = ClientMath.bounds(points, BOUNDS_PADDING, MIN_SPAN)
    fit = ClientMath.fitMap(bounds, width - INSET * 2, height - INSET * 2)
end

local function makeSite(index)
    local stroke = UI.stroke(L.white, 1.5, 0)
    local circle = UI.create("Frame", {
        Name = "Circle",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(SITE_SIZE, SITE_SIZE),
        BackgroundColor3 = SITE_READY,
    }, { UI.roundCorner(), stroke })
    local label = UI.create("TextLabel", {
        Name = "Label",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 0, 2),
        Size = UDim2.fromOffset(0, 16),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.MonoBold,
        TextSize = 13,
        TextColor3 = L.white,
    }, { UI.worldStroke() })
    UI.msg(label, { key = "map.ice.label", args = { n = index } })
    local status = UI.create("TextLabel", {
        Name = "Status",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 1, -2),
        Size = UDim2.fromOffset(0, 14),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Mono,
        TextSize = 12,
        TextColor3 = L.dim,
    }, { UI.worldStroke() })
    local button = UI.create("TextButton", {
        Name = "Site" .. index,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(40, 40),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        ZIndex = 4,
        Parent = canvas,
    }, { circle, label, status })
    button.Activated:Connect(function()
        if onSiteClicked then
            onSiteClicked(index)
        end
    end)
    sites[index] =
        { button = button, circle = circle, stroke = stroke, label = label, status = status }
    return sites[index]
end

local function refreshSites(state)
    local seen = {}
    for _, site in ipairs(state and state.ice or {}) do
        local index = site.index
        seen[index] = true
        local view = sites[index] or makeSite(index)
        local pos = project(worldSites[index])
        view.button.Visible = pos ~= nil
        if pos then
            view.button.Position = pos
        end
        local selected = index == selectedSite
        local pinned = index == Session.pinSite
        local size = if selected then SITE_SELECTED else SITE_SIZE
        view.circle.Size = UDim2.fromOffset(size, size)
        local cooldown = type(site.cooldownDaysLeft) == "number" and site.cooldownDaysLeft or 0
        if site.pipe then
            view.circle.BackgroundColor3 = L.sky
            UI.msg(view.status, "map.ice.piped")
        elseif cooldown > 0 then
            view.circle.BackgroundColor3 = SITE_COOLDOWN
            UI.msg(view.status, { key = "map.ice.cooldown", args = { count = cooldown } })
        else
            view.circle.BackgroundColor3 = SITE_READY
            UI.msg(view.status, "map.ice.ready")
        end
        view.stroke.Color = if pinned or selected then L.mint else L.white
        view.stroke.Thickness = if selected then 3 elseif pinned then 2.5 else 1.5
        view.button.ZIndex = if selected then 6 else 4
    end
    for index, view in pairs(sites) do
        if not seen[index] then
            view.button.Visible = false
        end
    end
end

local function refreshPin()
    local index = Session.pinSite
    local pos = index and project(worldSites[index])
    pinIcon.Visible = pos ~= nil and not offline
    if pos then
        pinIcon.Position = pos + UDim2.fromOffset(0, -30)
    end
end

-- 자율주행 진행 비율을 그날 안에서 부드럽게. progress는 하루 단위로만 바뀌므로
-- 왕복 일수로 하루 몫을 구하고, 오늘 지난 비율(state.dayEndsAt 기준, 없으면 progress가 바뀐 뒤 흐른 시간)만큼 더한다
local function smoothProgress(state, fsd)
    local now = os.clock()
    if trip.progress ~= fsd.progress or trip.site ~= fsd.siteIndex then
        trip.progress = fsd.progress
        trip.site = fsd.siteIndex
        trip.changedAt = now
    end
    if fsd.stoppedBy or fsd.recovering then
        return fsd.progress
    end
    local days = nil
    for _, site in ipairs(state.ice or {}) do
        if site.index == fsd.siteIndex then
            days = if fsd.rush and type(site.rushDays) == "number"
                then site.rushDays
                else site.fsdDays
        end
    end
    if type(days) ~= "number" or days <= 0 then
        return fsd.progress
    end
    local daySeconds = MissionConfig.DAY_SECONDS
    local dayFraction
    if type(state.dayEndsAt) == "number" then
        dayFraction = 1 - (state.dayEndsAt - workspace:GetServerTimeNow()) / daySeconds
    else
        dayFraction = (now - trip.changedAt) / daySeconds
    end
    return math.min(fsd.progress + math.clamp(dayFraction, 0, 1) / days, 1)
end

local function roverWorldPosition(state)
    local rover = state.rover
    local missionId = state.missionId or "C"
    local exit = WorldPoints.marker("BaseExit", missionId)
        or WorldPoints.marker("Lander", missionId)
    if type(rover) ~= "table" then
        return nil
    end
    if rover.state == "fsd" and type(rover.fsd) == "table" and exit then
        local site = worldSites[rover.fsd.siteIndex]
        if site then
            local fraction
            if rover.fsd.recovering then
                fraction = lastBrokenFraction * (1 - math.clamp(rover.fsd.progress or 0, 0, 1))
            else
                fraction = ClientMath.roundTripFraction(smoothProgress(state, rover.fsd))
            end
            local p = ClientMath.tripPoint(exit, site, fraction)
            return Vector3.new(p.X, 0, p.Z)
        end
    elseif rover.state == "broken" and type(rover.broken) == "table" then
        -- 서버가 고장 자리에 로버를 다시 보이게 하고 rover.x, z를 보낸다. 수동 고장(manual)도 그 자리
        local site = worldSites[rover.broken.siteIndex]
        if type(rover.broken.position) == "number" then
            lastBrokenFraction = ClientMath.roundTripFraction(rover.broken.position)
        end
        local shown = WorldPoints.rover()
        if shown then
            return shown
        elseif site and exit and not rover.broken.manual then
            local p = ClientMath.tripPoint(exit, site, lastBrokenFraction)
            return Vector3.new(p.X, 0, p.Z)
        end
    end
    local pos = WorldPoints.rover()
    return pos or WorldPoints.marker("RoverPark", missionId)
end

local function refreshCrew()
    local present = {}
    for _, player in ipairs(Players:GetPlayers()) do
        present[player] = true
        local dot = crewDots[player]
        if not dot then
            local me = player == Players.LocalPlayer
            dot = UI.create("Frame", {
                Name = "Crew_" .. player.UserId,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Size = UDim2.fromOffset(CREW_SIZE, CREW_SIZE),
                BackgroundColor3 = if me then L.mint else L.white,
                ZIndex = 7,
                Parent = canvas,
            }, { UI.roundCorner(), UI.stroke(MAP_BG, 2, 0) })
            crewDots[player] = dot
        end
        local pos = project(WorldPoints.character(player))
        dot.Visible = pos ~= nil
        if pos then
            dot.Position = pos
        end
    end
    for player, dot in pairs(crewDots) do
        if not present[player] then
            dot:Destroy()
            crewDots[player] = nil
        end
    end
end

local function animateStatic()
    staticClock += 1
    for i, stripe in ipairs(offlineStripes) do
        stripe.BackgroundTransparency = if (i + staticClock) % 2 == 0 then 0.82 else 0.92
    end
end

function ConsoleMap.init(parent, clicked)
    onSiteClicked = clicked
    canvas = UI.create("Frame", {
        Name = "Canvas",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    })
    -- 장식 링 (목업 관제사 지도)
    for i, ratio in ipairs({ 0.36, 0.62, 0.86 }) do
        UI.create("Frame", {
            Name = "Ring" .. i,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(ratio, ratio),
            SizeConstraint = Enum.SizeConstraint.RelativeYY,
            BackgroundTransparency = 1,
            ZIndex = 1,
            Parent = canvas,
        }, { UI.roundCorner(), UI.stroke(L.white, 1, 0.92) })
    end
    baseIcon = Icons.base(26)
    baseIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    baseIcon.ZIndex = 3
    baseIcon.Parent = canvas
    local baseLabel = UI.create("TextLabel", {
        Name = "BaseLabel",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 1, 2),
        Size = UDim2.fromOffset(0, 14),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Mono,
        TextSize = 12,
        TextColor3 = L.dim,
        Parent = baseIcon,
    }, { UI.worldStroke() })
    UI.msg(baseLabel, "map.legend.base")
    roverIcon = Icons.rover(ROVER_SIZE)
    roverIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    roverIcon.ZIndex = 8
    roverIcon.Parent = canvas
    pinIcon = Icons.pin(26)
    pinIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    pinIcon.ZIndex = 9
    pinIcon.Visible = false
    pinIcon.Parent = canvas

    local stripeHolder = UI.create("Frame", {
        Name = "Stripes",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    })
    for i = 1, STATIC_STRIPES do
        offlineStripes[i] = UI.create("Frame", {
            Name = "Stripe" .. i,
            Position = UDim2.fromScale(0, (i - 1) / STATIC_STRIPES),
            Size = UDim2.fromScale(1, 0.5 / STATIC_STRIPES),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.9,
            Parent = stripeHolder,
        })
    end
    local offlineTitle = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.MonoBold,
        TextSize = 22,
        TextColor3 = L.red,
        TextWrapped = true,
    })
    UI.msg(offlineTitle, "map.signal_lost")
    local offlineDetail = UI.create("TextLabel", {
        Name = "Detail",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.white,
        TextWrapped = true,
    })
    UI.msg(offlineDetail, "toast.map.offline_gst")
    offlineOverlay = UI.create("Frame", {
        Name = "Offline",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(30, 10, 20),
        BackgroundTransparency = 0.35,
        ZIndex = 20,
        Visible = false,
    }, {
        stripeHolder,
        UI.create("Frame", {
            Name = "Text",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(0.8, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Color3.fromRGB(40, 8, 8),
            BackgroundTransparency = 0.25,
        }, {
            UI.corner(12),
            UI.stroke(L.red, 1.5, 0),
            UI.padding(14),
            UI.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center),
            offlineTitle,
            offlineDetail,
        }),
    })

    frame = UI.create("Frame", {
        Name = "ConsoleMap",
        Size = UDim2.fromOffset(600, 460),
        BackgroundColor3 = MAP_BG,
        ClipsDescendants = true,
        Parent = parent,
    }, {
        UI.corner(14),
        UI.stroke(L.white, 1, UI.LUNA_STROKE_TRANSPARENCY),
        canvas,
        offlineOverlay,
    })
    return frame
end

function ConsoleMap.setSize(width, height)
    frame.Size = UDim2.fromOffset(width, height)
end

function ConsoleMap.setSelected(index)
    selectedSite = index
    if Session.state then
        refreshSites(Session.state)
    end
end

-- 지도를 처음 보이거나 크기가 바뀌었을 때: 경계부터 다시 잡는다
function ConsoleMap.rebuild()
    local state = Session.state
    if not state then
        return
    end
    rebuildFit(state)
    ConsoleMap.refresh()
end

-- 상태가 바뀌었을 때: 지점 색, 쿨타임, 핀
function ConsoleMap.refresh()
    local state = Session.state
    if not state or not fit then
        return
    end
    offline = Session.isGst()
    offlineOverlay.Visible = offline
    local missionId = state.missionId or "C"
    local basePos = project(WorldPoints.marker("Lander", missionId))
    baseIcon.Visible = basePos ~= nil
    if basePos then
        baseIcon.Position = basePos
    end
    refreshSites(state)
    refreshPin()
end

-- 움직이는 것(로버, 대원). 보일 때만 몇 번씩 부른다. GST 중에는 멈춘다
function ConsoleMap.tick()
    local state = Session.state
    if not state or not fit then
        return
    end
    if offline then
        if os.clock() - (ConsoleMap._lastStatic or 0) >= STATIC_STEP then
            ConsoleMap._lastStatic = os.clock()
            animateStatic()
        end
        return
    end
    local pos = project(roverWorldPosition(state))
    roverIcon.Visible = pos ~= nil
    if pos then
        roverIcon.Position = pos
    end
    local rover = state.rover
    roverIcon.Rotation = 0
    if type(rover) == "table" and rover.state == "broken" then
        roverIcon.Rotation = 90 -- 고장: 옆으로 누운 아이콘
    end
    refreshCrew()
end

return ConsoleMap
