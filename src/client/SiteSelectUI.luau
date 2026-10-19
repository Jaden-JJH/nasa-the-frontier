--!nonstrict
-- 착륙지 선택 화면 C안 지도형 (2026-10-19 18차, 사용자 결정. 목업 C_SiteSelect.dc.html 1280x720 수치를 옮기고
-- 배경과 패널은 타이틀, 결과 화면과 같은 루나 그라데이션과 흰색 반투명 패널로 맞췄다).
-- 왼쪽 660px 지도(위도 링 85/87/89 S, 크레이터 음영, 번호 핀 4개, 남극점 S, 범례), 오른쪽 상세 패널과 4행 전환 목록.
-- 2단계 선택: 핀이나 목록 행을 누르면 그 후보지가 상세 패널에 뜨고(미리보기, 누구나 가능),
-- "여기에 착륙" 버튼이 확정이다(선택 권한자만, SelectSite 송신). 다른 사람은 버튼이 "대기 중"으로 잠긴다.
-- 자동 선택 카운트다운은 info.deadlineUnix(서버 시각) 기준. 데이터는 info.sites와 Config(DEV_MAP, ROVER, SITE_MAP).
-- compact(Layout.isCompact)는 지도를 숨기고 머리, 상세 패널, 목록을 세로로 쌓아 실제 px 공간에서 스크롤한다.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local L = UI.Luna

local SiteSelectUI = {}

-- 목업 기준 수치 (가상 좌표, 1280x720, 패딩 36/56/32)
local CANVAS_HEIGHT = 720
local PAD_TOP = 36
local PAD_BOTTOM = 32
local PAD_MIN = 20 -- Roblox 상단 바 때문에 위가 밀리면 아래 패딩을 여기까지 줄인다
local TOPBAR_GAP = 6
local CONTENT_WIDTH = 1168
local HEADER_HEIGHT = 68
local HEADER_GAP = 20
local MAP_WIDTH = 660
local MAP_CANVAS = Vector2.new(660, 564) -- 지도 그림 좌표계 (SITE_MAP 비율의 기준)
local BODY_GAP = 28
local SIDE_GAP = 14
local LIST_ROW_HEIGHT = 44
local WIDE_MIN_WIDTH = CONTENT_WIDTH + 32 -- 가상 폭이 이보다 좁으면 지도를 숨기고 세로로 쌓는다
local STACK_MAX_WIDTH = 640
local STACK_PAD = 16
local RING_RADII =
    { { lat = 85, radius = 250 }, { lat = 87, radius = 170 }, { lat = 89, radius = 90 } }
local CRATERS = { -- 지도 그림 안 좌상단, 크기, 투명도 (목업 rgba(60,70,120,a))
    { 290, 236, 80, 68, 0.45 },
    { 150, 350, 120, 96, 0.55 },
    { 430, 120, 96, 80, 0.55 },
    { 470, 330, 150, 120, 0.55 },
    { 110, 140, 70, 56, 0.65 },
}
local PIN_SMALL = 34
local PIN_BIG = 44
local PIN_GLOW = 62 -- 44 + 테두리 3 x 2 + 빛 6 x 2 (목업 box-shadow 6px)
local LAND_HOVER_TRANSPARENCY = 0.12

local gui
local config
local selectRemote
local body
local root
local scroll
local stage
local header
local titleLabel
local subtitleLabel
local statusBlock
local statusList
local avatar
local avatarInitial
local chooserText
local countdownFill
local countdownNumber
local mapPanel
local mapCanvas
local side
local detail
local indexLabel
local nameLabel
local recommend
local descLabel
local sunFill
local sunPercent
local iceValue
local iceTrip
local hazardValue
local landButton
local listPanel
local listLayout

local currentInfo = nil
local canChoose = false
local chosenId = nil
local previewId = nil
local landHover = false
local pins = {} -- [siteId] = { holder, glow, circle, stroke, number, label }
local rows = {} -- [siteId] = { button, bar, number, name, sun, tag, separator, hover }
local siteList = {} -- info.sites 순서

-- RichText에 넣는 이름의 특수문자 처리
local function escape(text)
    return (
        tostring(text)
            :gsub("&", "&amp;")
            :gsub("<", "&lt;")
            :gsub(">", "&gt;")
            :gsub('"', "&quot;")
            :gsub("'", "&apos;")
    )
end

local function hex(color)
    return string.format(
        "#%02x%02x%02x",
        math.floor(color.R * 255 + 0.5),
        math.floor(color.G * 255 + 0.5),
        math.floor(color.B * 255 + 0.5)
    )
end

local function firstChar(text)
    local ok, cut = pcall(utf8.offset, text, 2)
    if ok and cut then
        return string.sub(text, 1, cut - 1)
    end
    return string.sub(text, 1, 1)
end

local function siteById(id)
    for _, site in ipairs(siteList) do
        if site.id == id then
            return site
        end
    end
    return nil
end

local function siteIndex(id)
    for i, site in ipairs(siteList) do
        if site.id == id then
            return i
        end
    end
    return 0
end

-- 로버 왕복 시간 "약 n분 m초" (거리 x 2 / ROVER.maxSpeed). 0인 단위는 생략, 둘 다 0이면 nil
local function roundTripText(distance)
    local t = config.TEXTS
    local speed = config.ROVER.maxSpeed
    if type(distance) ~= "number" or type(speed) ~= "number" or speed <= 0 then
        return nil
    end
    local seconds = math.floor(distance * 2 / speed + 0.5)
    local parts = {}
    if seconds // 60 > 0 then
        table.insert(parts, string.format(t.siteMinutes, seconds // 60))
    end
    if seconds % 60 > 0 then
        table.insert(parts, string.format(t.siteSeconds, seconds % 60))
    end
    if #parts == 0 then
        return nil
    end
    return string.format(t.siteRoundTrip, table.concat(parts, " "))
end

-- 상세 패널, 핀, 목록, 착륙 버튼을 지금 미리보기와 권한에 맞춘다
local function refresh()
    local t = config.TEXTS
    local site = siteById(previewId)
    if site then
        local distance = config.DEV_MAP.iceDistanceBySite[site.id]
        indexLabel.Text = string.format(t.siteIndex, siteIndex(site.id), #siteList)
        nameLabel.Text = site.name
        recommend.Visible = currentInfo ~= nil and site.id == currentInfo.defaultSiteId
        descLabel.Text = site.description
        sunFill.Size = UDim2.fromScale(math.clamp(site.sunlight, 0, 1), 1)
        sunPercent.Text = string.format(t.sitePercent, math.floor(site.sunlight * 100 + 0.5))
        local studs = if type(distance) == "number"
            then string.format(
                '  <font color="%s" family="rbxasset://fonts/families/Nunito.json" weight="heavy">%s</font>',
                hex(L.dim),
                string.format(t.siteStuds, distance)
            )
            else ""
        iceValue.Text = escape(site.iceDistanceLabel) .. studs
        iceTrip.Text = roundTripText(distance) or ""
        local detailText = t.siteHazardDetail[site.hazardLabel]
        local hazardColor = if site.hazardLabel == "높음" then L.red else L.white
        hazardValue.Text = string.format(
            '<font color="%s">%s</font>',
            hex(hazardColor),
            escape(site.hazardLabel)
        ) .. (if detailText
            then string.format(
                '  <font color="%s" weight="regular">%s</font>',
                hex(L.dim),
                escape(detailText)
            )
            else "")
    end

    for id, pin in pairs(pins) do
        local selected = id == previewId
        local size = if selected then PIN_BIG else PIN_SMALL
        pin.glow.Visible = selected
        pin.circle.Size = UDim2.fromOffset(size, size)
        pin.circle.BackgroundColor3 = if selected then L.mint else L.pin
        pin.stroke.Color = if selected then L.white else L.label
        pin.stroke.Thickness = if selected then 3 else 2
        pin.number.TextSize = if selected then 17 else 14
        pin.number.TextColor3 = if selected then L.inkDeep else L.white
        pin.label.Position = UDim2.new(pin.ratio.X, 0, pin.ratio.Y, size / 2 + 8)
        pin.label.Font = UI.FontBold
        pin.label.TextColor3 = if selected then L.white else L.label
        pin.label.ZIndex = if selected then 6 else 5
        pin.holder.ZIndex = if selected then 6 else 5
    end

    for id, row in pairs(rows) do
        local selected = id == previewId
        row.button.BackgroundColor3 = if selected then L.mint else L.white
        row.button.BackgroundTransparency = if selected then 0.88 elseif row.hover then 0.95 else 1
        row.bar.Visible = selected
        row.number.FontFace = if selected then UI.RoundHeavy else UI.RoundBold
        row.number.TextColor3 = if selected then L.mint else L.faint
        row.name.TextColor3 = if selected then L.white else L.label
        row.tag.TextColor3 = if row.rough then L.red elseif selected then L.soft else L.dim
    end

    -- 착륙 버튼: 확정 뒤 잠김, 권한자만 활성, 나머지는 대기 중
    local enabled = canChoose and chosenId == nil and site ~= nil
    landButton.Active = enabled
    if chosenId ~= nil then
        landButton.Text = t.siteChosen
    elseif canChoose then
        landButton.Text = t.siteLand
    else
        landButton.Text = t.siteWaiting
    end
    if enabled then
        landButton.BackgroundColor3 = L.mint
        landButton.BackgroundTransparency = if landHover then LAND_HOVER_TRANSPARENCY else 0
        landButton.TextColor3 = L.inkDeep
    else
        landButton.BackgroundColor3 = L.white
        landButton.BackgroundTransparency = 0.86
        landButton.TextColor3 = L.dim
    end
end

local function setPreview(id)
    if siteById(id) == nil then
        return
    end
    previewId = id
    refresh()
end

-- 지도 위 번호 핀 (원 + 번호, 아래 이름). 핀과 이름 모두 누르면 미리보기
local function buildPin(site)
    local spot = config.SITE_MAP.pins[site.id]
    if not spot then
        return
    end
    local ratio = Vector2.new(spot.x, spot.y)
    local glow = UI.create("Frame", {
        Name = "Glow",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PIN_GLOW, PIN_GLOW),
        BackgroundColor3 = L.mint,
        BackgroundTransparency = 0.75,
        Visible = false,
    }, { UI.roundCorner() })
    local stroke = UI.stroke(L.label, 2, 0)
    local number = UI.create("TextLabel", {
        Name = "Number",
        Size = UDim2.fromScale(1, 1),
        Text = tostring(site.id),
        FontFace = UI.RoundHeavy,
        TextSize = 14,
        TextColor3 = L.white,
    })
    local circle = UI.create("Frame", {
        Name = "Circle",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PIN_SMALL, PIN_SMALL),
        BackgroundColor3 = L.pin,
    }, { UI.roundCorner(), stroke, number })
    local holder = UI.create("TextButton", {
        Name = "Pin" .. site.id,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(ratio.X, ratio.Y),
        Size = UDim2.fromOffset(PIN_GLOW, PIN_GLOW),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        ZIndex = 5,
        Parent = mapCanvas,
    }, { glow, circle })
    local label = UI.create("TextButton", {
        Name = "PinLabel" .. site.id,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(ratio.X, 0, ratio.Y, PIN_SMALL / 2 + 8),
        Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = site.name,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.label,
        ZIndex = 5,
        Parent = mapCanvas,
    })
    holder.Activated:Connect(function()
        setPreview(site.id)
    end)
    label.Activated:Connect(function()
        setPreview(site.id)
    end)
    pins[site.id] = {
        holder = holder,
        glow = glow,
        circle = circle,
        stroke = stroke,
        number = number,
        label = label,
        ratio = ratio,
    }
end

-- 아래 전환 목록 한 행: 번호, 이름, 일조율, 얼음 거리(험한 지형이면 "지형 험함")
local function buildRow(site, order, last)
    local t = config.TEXTS
    local rough = site.hazardLabel == "높음"
    local function cell(name, position, size, props)
        local merged = {
            Name = name,
            Position = position,
            Size = size,
            Text = "",
            TextSize = 15,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }
        for key, value in pairs(props) do
            merged[key] = value
        end
        return UI.create("TextLabel", merged)
    end
    local row = { rough = rough, hover = false }
    row.bar = UI.create("Frame", {
        Name = "Bar",
        Size = UDim2.new(0, 4, 1, 0),
        BackgroundColor3 = L.mint,
        Visible = false,
    })
    row.number = cell("Number", UDim2.fromOffset(18, 0), UDim2.new(0, 36, 1, 0), {
        Text = tostring(site.id),
        FontFace = UI.RoundBold,
    })
    row.name = cell("Name", UDim2.fromOffset(64, 0), UDim2.new(1, -276, 1, 0), {
        Text = site.name,
        Font = UI.FontBold,
    })
    row.sun = cell("Sun", UDim2.new(1, -202, 0, 0), UDim2.new(0, 64, 1, 0), {
        Text = string.format(t.sitePercent, math.floor(site.sunlight * 100 + 0.5)),
        FontFace = UI.RoundHeavy,
        TextColor3 = L.gold,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    row.tag = cell("Tag", UDim2.new(1, -128, 0, 0), UDim2.new(0, 110, 1, 0), {
        Text = if rough
            then t.siteListRough
            else string.format(t.siteListIce, site.iceDistanceLabel),
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    row.button = UI.create("TextButton", {
        Name = "Row" .. site.id,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, LIST_ROW_HEIGHT),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        Parent = listPanel,
    }, { row.bar, row.number, row.name, row.sun, row.tag })
    if not last then
        UI.create("Frame", {
            Name = "Separator",
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.fromScale(0, 1),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.94,
            Parent = row.button,
        })
    end
    row.button.Activated:Connect(function()
        setPreview(site.id)
    end)
    row.button.MouseEnter:Connect(function()
        row.hover = true
        refresh()
    end)
    row.button.MouseLeave:Connect(function()
        row.hover = false
        refresh()
    end)
    rows[site.id] = row
end

local function clearSites()
    for _, pin in pairs(pins) do
        pin.holder:Destroy()
        pin.label:Destroy()
    end
    for _, row in pairs(rows) do
        row.button:Destroy()
    end
    pins = {}
    rows = {}
end

local function updateCountdown()
    if not currentInfo then
        return
    end
    local left = currentInfo.deadlineUnix - workspace:GetServerTimeNow()
    countdownNumber.Text = tostring(math.max(0, math.ceil(left)))
    local total = config.SITE_SELECT_TIMEOUT
    local ratio = if total > 0 then math.clamp(left / total, 0, 1) else 0
    countdownFill.Size = UDim2.fromScale(ratio, 1)
end

-- 배치: PC는 머리 + 지도 + 오른쪽 열, 좁거나 compact면 지도 없이 세로로 쌓는다
local function fit()
    if not stage then
        return
    end
    local compact = Layout.isCompact()
    local unit = if compact then 1 else Layout.scale()
    scroll.Parent = if compact then body else root
    local abs = body.AbsoluteSize
    if abs.X <= 0 or abs.Y <= 0 then
        abs = Vector2.new(1280, 720) * unit
    end
    local space = abs / unit
    local stacked = compact or space.X < WIDE_MIN_WIDTH
    local insetTop = GuiService:GetGuiInset().Y / unit + TOPBAR_GAP
    local detailHeight = detail.AbsoluteSize.Y / unit
    local rowsHeight = listLayout.AbsoluteContentSize.Y / unit
    local canvasHeight

    titleLabel.TextSize = if compact then 24 else 36
    subtitleLabel.Visible = not compact
    mapPanel.Visible = not stacked

    if stacked then
        local width = math.min(STACK_MAX_WIDTH, space.X - STACK_PAD * 2)
        local top = math.max(STACK_PAD, insetTop)
        local titleHeight = if compact then 30 else 40
        titleLabel.Size = UDim2.new(1, 0, 0, titleHeight)
        subtitleLabel.Position = UDim2.fromOffset(0, titleHeight + 4)
        subtitleLabel.Size = UDim2.fromScale(1, 0)
        subtitleLabel.AutomaticSize = Enum.AutomaticSize.Y
        subtitleLabel.TextWrapped = true
        local subtitleHeight = if compact then 0 else subtitleLabel.AbsoluteSize.Y / unit + 4
        statusBlock.AnchorPoint = Vector2.new(0, 0)
        statusBlock.Position = UDim2.fromOffset(0, titleHeight + subtitleHeight + 8)
        statusList.HorizontalAlignment = Enum.HorizontalAlignment.Left
        local headerHeight = titleHeight + subtitleHeight + 8 + statusBlock.AbsoluteSize.Y / unit
        header.Position = UDim2.fromOffset(0, 0)
        header.Size = UDim2.fromOffset(width, headerHeight)
        side.Position = UDim2.fromOffset(0, headerHeight + 16)
        side.Size = UDim2.fromOffset(width, detailHeight + SIDE_GAP + rowsHeight)
        listPanel.Position = UDim2.fromOffset(0, detailHeight + SIDE_GAP)
        listPanel.Size = UDim2.new(1, 0, 0, rowsHeight)
        local stageHeight = headerHeight + 16 + detailHeight + SIDE_GAP + rowsHeight
        stage.Position = UDim2.fromOffset(math.floor((space.X - width) / 2), top)
        stage.Size = UDim2.fromOffset(width, stageHeight)
        canvasHeight = top + stageHeight + STACK_PAD
    else
        local idealTop = (space.Y - CANVAS_HEIGHT) / 2 + PAD_TOP
        local top = math.max(idealTop, insetTop)
        local push = top - idealTop
        local bottom = math.max(PAD_MIN, (space.Y - CANVAS_HEIGHT) / 2 + PAD_BOTTOM - push)
        local bodyHeight = math.max(
            space.Y - top - bottom - HEADER_HEIGHT - HEADER_GAP,
            detailHeight + SIDE_GAP + rowsHeight
        )
        titleLabel.Size = UDim2.new(1, -380, 0, 40)
        subtitleLabel.Position = UDim2.fromOffset(0, 46)
        subtitleLabel.Size = UDim2.new(1, -380, 0, 20)
        subtitleLabel.AutomaticSize = Enum.AutomaticSize.None
        subtitleLabel.TextWrapped = false
        statusBlock.AnchorPoint = Vector2.new(1, 1)
        statusBlock.Position = UDim2.fromScale(1, 1)
        statusList.HorizontalAlignment = Enum.HorizontalAlignment.Right
        header.Position = UDim2.fromOffset(0, 0)
        header.Size = UDim2.fromOffset(CONTENT_WIDTH, HEADER_HEIGHT)
        local bodyTop = HEADER_HEIGHT + HEADER_GAP
        mapPanel.Position = UDim2.fromOffset(0, bodyTop)
        mapPanel.Size = UDim2.fromOffset(MAP_WIDTH, bodyHeight)
        side.Position = UDim2.fromOffset(MAP_WIDTH + BODY_GAP, bodyTop)
        side.Size = UDim2.fromOffset(CONTENT_WIDTH - MAP_WIDTH - BODY_GAP, bodyHeight)
        listPanel.Position = UDim2.fromOffset(0, detailHeight + SIDE_GAP)
        listPanel.Size = UDim2.new(1, 0, 0, bodyHeight - detailHeight - SIDE_GAP)
        stage.Position = UDim2.fromOffset(math.floor((space.X - CONTENT_WIDTH) / 2), top)
        stage.Size = UDim2.fromOffset(CONTENT_WIDTH, bodyTop + bodyHeight)
        canvasHeight = top + bodyTop + bodyHeight + bottom
    end
    scroll.CanvasSize = UDim2.fromOffset(0, math.ceil(canvasHeight))
end

-- 머리: 제목과 부제(왼쪽), 고르는 사람과 자동 선택 카운트다운(오른쪽)
local function buildHeader(t)
    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        Size = UDim2.new(1, -380, 0, 40),
        Text = t.siteTitle,
        Font = UI.FontBold,
        TextSize = 36,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    subtitleLabel = UI.create("TextLabel", {
        Name = "Subtitle",
        Position = UDim2.fromOffset(0, 46),
        Size = UDim2.new(1, -380, 0, 20),
        Text = t.siteSubtitle,
        TextSize = 15,
        TextColor3 = L.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    avatarInitial = UI.create("TextLabel", {
        Name = "Initial",
        Size = UDim2.fromScale(1, 1),
        Text = "",
        FontFace = UI.RoundHeavy,
        TextSize = 14,
        TextColor3 = L.inkDeep,
    })
    avatar = UI.dot(26, L.sky, { Name = "Avatar", LayoutOrder = 1 })
    avatarInitial.Parent = avatar
    chooserText = UI.create("TextLabel", {
        Name = "Chooser",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = "",
        RichText = true,
        TextSize = 15,
        TextColor3 = L.label,
    })
    local chooserRow = UI.create("Frame", {
        Name = "ChooserRow",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        avatar,
        chooserText,
    })
    countdownFill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.mint,
    }, { UI.corner(2) })
    countdownNumber = UI.create("TextLabel", {
        Name = "Number",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = "",
        FontFace = UI.RoundHeavy,
        TextSize = 18,
        TextColor3 = L.white,
    })
    local function small(order, text)
        return UI.create("TextLabel", {
            LayoutOrder = order,
            Size = UDim2.fromOffset(0, 24),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = text,
            TextSize = 14,
            TextColor3 = L.dim,
        })
    end
    local countdownRow = UI.create("Frame", {
        Name = "CountdownRow",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        small(1, t.siteAutoPick),
        UI.create("Frame", {
            Name = "Bar",
            LayoutOrder = 2,
            Size = UDim2.fromOffset(140, 4),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.88,
        }, { UI.corner(2), countdownFill }),
        countdownNumber,
        small(4, t.siteSecondsUnit),
    })
    statusList = UI.create("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
    })
    statusBlock = UI.create("Frame", {
        Name = "Status",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromScale(1, 1),
        Size = UDim2.fromOffset(360, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { statusList, chooserRow, countdownRow })
    header = UI.create("Frame", {
        Name = "Header",
        Size = UDim2.fromOffset(CONTENT_WIDTH, HEADER_HEIGHT),
        BackgroundTransparency = 1,
    }, { titleLabel, subtitleLabel, statusBlock })
    return header
end

-- 지도: 위도 링(실선), 크레이터 음영, 남극점, 범례. 핀은 open에서 만든다
local function buildMap(t)
    local center = Vector2.new(
        config.SITE_MAP.center.x * MAP_CANVAS.X,
        config.SITE_MAP.center.y * MAP_CANVAS.Y
    )
    mapCanvas = UI.create("Frame", {
        Name = "Canvas",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(MAP_CANVAS.X, MAP_CANVAS.Y),
        BackgroundTransparency = 1,
    })
    for _, crater in ipairs(CRATERS) do
        UI.create("Frame", {
            Name = "Crater",
            Position = UDim2.fromOffset(crater[1], crater[2]),
            Size = UDim2.fromOffset(crater[3], crater[4]),
            BackgroundColor3 = L.crater,
            BackgroundTransparency = crater[5],
            ZIndex = 1,
            Parent = mapCanvas,
        }, { UI.roundCorner() })
    end
    for _, ring in ipairs(RING_RADII) do
        UI.create("Frame", {
            Name = "Ring" .. ring.lat,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(center.X, center.Y),
            Size = UDim2.fromOffset(ring.radius * 2, ring.radius * 2),
            BackgroundTransparency = 1,
            ZIndex = 2,
            Parent = mapCanvas,
        }, { UI.roundCorner(), UI.stroke(L.dim, 1.5, 0.65) })
        UI.create("TextLabel", {
            Name = "Lat" .. ring.lat,
            Position = UDim2.fromOffset(center.X + ring.radius + 4, center.Y - 10),
            Size = UDim2.fromOffset(40, 18),
            Text = string.format(t.siteLatitude, ring.lat),
            FontFace = UI.RoundBold,
            TextSize = 14,
            TextColor3 = L.faint,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 3,
            Parent = mapCanvas,
        })
    end
    UI.dot(8, L.white, {
        Name = "Pole",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromOffset(center.X, center.Y),
        ZIndex = 3,
        Parent = mapCanvas,
    })
    UI.create("TextLabel", {
        Name = "PoleLabel",
        Position = UDim2.fromOffset(center.X + 8, center.Y - 14),
        Size = UDim2.fromOffset(14, 18),
        Text = "S",
        FontFace = UI.RoundHeavy,
        TextSize = 14,
        TextColor3 = L.white,
        ZIndex = 3,
        Parent = mapCanvas,
    })

    local function legendItem(order, swatch, text)
        swatch.LayoutOrder = 1
        return UI.create("Frame", {
            Name = "Legend" .. order,
            LayoutOrder = order,
            Size = UDim2.fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, 6),
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Center,
            }),
            swatch,
            UI.create("TextLabel", {
                LayoutOrder = 2,
                Size = UDim2.fromOffset(0, 18),
                AutomaticSize = Enum.AutomaticSize.X,
                Text = text,
                TextSize = 14,
                TextColor3 = L.faint,
            }),
        })
    end
    local legend = UI.create("Frame", {
        Name = "Legend",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 20, 1, -16),
        Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        ZIndex = 7,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 18),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        legendItem(
            1,
            UI.create("Frame", {
                Size = UDim2.fromOffset(14, 10),
                BackgroundColor3 = L.crater,
                BackgroundTransparency = 0.4,
            }, { UI.roundCorner() }),
            t.siteLegendCrater
        ),
        legendItem(
            2,
            UI.create("Frame", {
                Size = UDim2.fromOffset(14, 2),
                BackgroundColor3 = L.dim,
                BackgroundTransparency = 0.5,
            }),
            t.siteLegendLatitude
        ),
        legendItem(3, UI.dot(10, L.mint), t.siteLegendSelected),
    })

    -- "지구 방향" 위쪽 화살표 (막대 3개)
    local function bar(x, y, width, height, rotation)
        return UI.create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(width, height),
            Rotation = rotation,
            BackgroundColor3 = L.faint,
        }, { UI.roundCorner() })
    end
    local earth = UI.create("Frame", {
        Name = "Earth",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -20, 0, 16),
        Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        ZIndex = 7,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        UI.create("Frame", {
            LayoutOrder = 1,
            Size = UDim2.fromOffset(16, 16),
            BackgroundTransparency = 1,
        }, {
            bar(8, 9, 2.5, 13, 0),
            bar(5, 5.5, 2.5, 8, 45),
            bar(11, 5.5, 2.5, 8, -45),
        }),
        UI.create("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = t.siteEarth,
            Font = UI.FontBold,
            TextSize = 14,
            TextColor3 = L.faint,
        }),
    })

    mapPanel = UI.lunaPanel({
        Name = "Map",
        Size = UDim2.fromOffset(MAP_WIDTH, 548),
        BackgroundTransparency = 0.92, -- rgba(255,255,255,0.08)
        ClipsDescendants = true,
    }, {
        mapCanvas,
        UI.create("TextLabel", {
            Name = "MapTitle",
            Position = UDim2.fromOffset(20, 16),
            Size = UDim2.fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = t.siteMapTitle,
            Font = UI.FontBold,
            TextSize = 14,
            TextColor3 = L.faint,
            ZIndex = 7,
        }),
        earth,
        legend,
    }, 20, false)
    return mapPanel
end

-- 상세 행: 아이콘 자리(색 도형) + 라벨 70 + 내용
local function statRow(order, icon, labelText, content)
    icon.AnchorPoint = Vector2.new(0.5, 0.5)
    icon.Position = UDim2.fromOffset(10, 11)
    local row = UI.create("Frame", {
        Name = "Stat" .. order,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 22),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        icon,
        UI.create("TextLabel", {
            Name = "Label",
            Position = UDim2.fromOffset(32, 0),
            Size = UDim2.fromOffset(70, 22),
            Text = labelText,
            TextSize = 14,
            TextColor3 = L.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
    })
    for _, child in ipairs(content) do
        child.Parent = row
    end
    return row
end

local function buildDetail(t)
    indexLabel = UI.create("TextLabel", {
        Name = "Index",
        Size = UDim2.new(1, 0, 0, 17),
        Text = "",
        FontFace = UI.RoundBold,
        TextSize = 14,
        TextColor3 = L.mint,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    nameLabel = UI.create("TextLabel", {
        Name = "Name",
        Position = UDim2.fromOffset(0, 21),
        Size = UDim2.new(1, -150, 0, 33),
        Text = "",
        FontFace = UI.RoundHeavy,
        TextSize = 30,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    recommend = UI.create("Frame", {
        Name = "Recommend",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 6),
        Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Visible = false,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        UI.checkMark(L.mint, { LayoutOrder = 1 }),
        UI.create("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = t.siteRecommended,
            Font = UI.FontBold,
            TextSize = 14,
            TextColor3 = L.mint,
        }),
    })
    local topRow = UI.create("Frame", {
        Name = "Top",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundTransparency = 1,
    }, { indexLabel, nameLabel, recommend })
    descLabel = UI.create("TextLabel", {
        Name = "Description",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextSize = 15,
        LineHeight = 1.35,
        TextColor3 = L.soft,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })

    sunFill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = L.gold,
    }, { UI.corner(4) })
    sunPercent = UI.create("TextLabel", {
        Name = "Percent",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(52, 22),
        Text = "",
        FontFace = UI.RoundHeavy,
        TextSize = 18,
        TextColor3 = L.gold,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    local sunBar = UI.create("Frame", {
        Name = "Bar",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromOffset(114, 11),
        Size = UDim2.new(1, -114 - 64, 0, 8),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.9,
    }, { UI.corner(4), sunFill })
    iceTrip = UI.create("TextLabel", {
        Name = "Trip",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(150, 22),
        Text = "",
        TextSize = 14,
        TextColor3 = L.dim,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    iceValue = UI.create("TextLabel", {
        Name = "Value",
        Position = UDim2.fromOffset(114, 0),
        Size = UDim2.new(1, -114 - 158, 0, 22),
        Text = "",
        RichText = true,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    hazardValue = UI.create("TextLabel", {
        Name = "Value",
        Position = UDim2.fromOffset(114, 0),
        Size = UDim2.new(1, -114, 0, 22),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        RichText = true,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local hazardIcon = UI.create("Frame", {
        Size = UDim2.fromOffset(11, 11),
        Rotation = 45,
        BackgroundColor3 = L.orange,
    }, { UI.corner(2) })
    local stats = UI.create("Frame", {
        Name = "Stats",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.padding({ 4, 0, 0, 0 }),
        UI.list(Enum.FillDirection.Vertical, 12),
        statRow(1, UI.dot(14, L.gold, nil, true), t.siteSunLabel, { sunBar, sunPercent }),
        statRow(2, UI.dot(12, L.sky), t.siteIceLabel, { iceValue, iceTrip }),
        statRow(3, hazardIcon, t.siteHazardLabel, { hazardValue }),
    })

    landButton = UI.create("TextButton", {
        Name = "LandButton",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundColor3 = L.mint,
        AutoButtonColor = false,
        Text = t.siteWaiting,
        Font = UI.FontBold,
        TextSize = 18,
        TextColor3 = L.inkDeep,
    }, { UI.corner(14) })
    landButton.MouseEnter:Connect(function()
        landHover = true
        refresh()
    end)
    landButton.MouseLeave:Connect(function()
        landHover = false
        refresh()
    end)
    landButton.Activated:Connect(function()
        if not canChoose or chosenId ~= nil or siteById(previewId) == nil then
            return
        end
        chosenId = previewId
        selectRemote:FireServer(previewId)
        refresh()
    end)

    detail = UI.lunaPanel({
        Name = "Detail",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 0.88, -- rgba(255,255,255,0.12)
    }, {
        UI.padding({ 22, 22, 24, 24 }),
        UI.list(Enum.FillDirection.Vertical, 14),
        topRow,
        descLabel,
        stats,
        landButton,
    }, 20, false)
    return detail
end

function SiteSelectUI.init(ctx)
    config = ctx.Config
    local t = config.TEXTS
    selectRemote = ctx.remotes.SelectSite
    gui = UI.gui("SiteSelect", 50)
    gui.Enabled = false

    listLayout = UI.list(Enum.FillDirection.Vertical, 0)
    listPanel = UI.lunaPanel({
        Name = "List",
        Size = UDim2.new(1, 0, 0, LIST_ROW_HEIGHT * 4),
        BackgroundTransparency = 0.92,
        ClipsDescendants = true,
    }, { listLayout }, 16, false)
    side = UI.create("Frame", {
        Name = "Side",
        BackgroundTransparency = 1,
    }, { buildDetail(t), listPanel })

    stage = UI.create("Frame", {
        Name = "Stage",
        Size = UDim2.fromOffset(CONTENT_WIDTH, CANVAS_HEIGHT),
        BackgroundTransparency = 1,
    }, { buildHeader(t), buildMap(t), side })
    scroll = UI.create("ScrollingFrame", {
        Name = "Scroll",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 3,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.fromOffset(0, 0),
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = L.label,
        ScrollBarImageTransparency = 0.4,
    }, { stage })

    body = UI.create("Frame", {
        Name = "Body",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.white,
        Parent = gui,
    }, { UI.lunaGradient() })
    root = Layout.root(gui)
    root.Parent = body
    scroll.Parent = root

    detail:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
    statusBlock:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    subtitleLabel:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    body:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    Layout.changed:Connect(fit)
    fit()

    -- 남은 시간 갱신 (화면이 보일 때만)
    task.spawn(function()
        while true do
            task.wait(0.25)
            if gui.Enabled then
                updateCountdown()
            end
        end
    end)
end

-- SiteSelectionOpen 수신 시 호출. 핀과 목록을 새로 만들고 기본 후보지를 미리보기로 띄운다
function SiteSelectUI.open(info)
    local t = config.TEXTS
    currentInfo = info
    chosenId = nil
    canChoose = Players.LocalPlayer.UserId == info.chooserUserId
    siteList = info.sites or {}

    clearSites()
    for i, site in ipairs(siteList) do
        buildPin(site)
        buildRow(site, i, i == #siteList)
    end
    previewId = if siteById(info.defaultSiteId)
        then info.defaultSiteId
        else (siteList[1] and siteList[1].id)

    local name = info.chooserName or ""
    avatarInitial.Text = if name ~= "" then firstChar(name) else "?"
    chooserText.Text = if canChoose
        then t.siteChooserMe
        else string.format(escape(t.siteChooserOther), "<b>" .. escape(name) .. "</b>")
    refresh()
    updateCountdown()
    fit()
end

function SiteSelectUI.setVisible(visible)
    gui.Enabled = visible
    if visible then
        fit()
    end
end

return SiteSelectUI
