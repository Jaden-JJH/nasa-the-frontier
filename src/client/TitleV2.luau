--!nonstrict
-- v2 타이틀 화면 (v1 TitleUI C안 "루나 소프트" 디자인을 그대로 옮기고 문구를 키로 바꿨다).
-- 왼쪽 묶음: 배지, 제목, 부제, 시작 버튼, "About the data" 버튼. 오른쪽 위: EN | KR 언어 토글(I18N_PLAN 1절).
-- 아래 칩 3개(에너지, 물, 식량)와 오른쪽 아래 인원 문구는 PC만.
-- "About the data" 패널(Q36): NASA DONKI, 과거 기록 재생(실시간 아님), 착륙지, 얼음 후보지 좌표 근거, 지형, 사실 카드 출처.
-- 시작 버튼은 로컬에서만 화면을 숨긴다(onStart). compact는 왼쪽 묶음을 실제 px 공간으로 옮겨 줄인다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Icons = require(script.Parent.Icons)
local LanguageToggle = require(script.Parent.LanguageToggle)
local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local L = UI.Luna

local TitleV2 = {}

-- 목업 기준 수치 (가상 좌표)
local CANVAS_CENTER_Y = 360
local BLOCK_LEFT = 96
local BLOCK_TOP = 130
local BLOCK_WIDTH = 620
local MOON_RIGHT = 120
local MOON_TOP = 90
local MOON_SIZE = 360
local HORIZON_SIZE = 2400
local HORIZON_VISIBLE = 180
local BOTTOM_GAP = 56
local CHIPS_LEFT = 96
local CREW_RIGHT = 64
local COMPACT_LEFT = 32
local MOON_TEXT_GAP = 24
local TOGGLE_MARGIN = 20
local ABOUT_WIDTH = 640
local ABOUT_MAX_HEIGHT = 560

local SIZES = {
    pc = {
        gap = 18,
        badgeHeight = 34,
        badgeText = 14,
        title = 100,
        titleHeight = 196,
        subtitle = 24,
        button = Vector2.new(300, 72),
        buttonText = 24,
        width = BLOCK_WIDTH,
    },
    compact = {
        gap = 10,
        badgeHeight = 30,
        badgeText = 14,
        title = 48,
        titleHeight = 94,
        subtitle = 16,
        button = Vector2.new(200, 52),
        buttonText = 18,
        width = 420,
    },
}

-- About 패널 문단 (리터럴 키 표, 순서대로)
local ABOUT_LINES = {
    "title.about.donki",
    "title.about.donki_name",
    "title.about.replay",
    "title.about.sites",
    "title.about.ice",
    "title.about.terrain",
    "title.about.facts",
}

local FADE_SECONDS = 0.4
local SLIDE = 16
local BUTTON_HOVER_TRANSPARENCY = 0.12

local gui
local onStart
local backdrop
local root
local column
local columnList
local badge
local badgeLabel
local titleLabel
local subtitleLabel
local startButton
local startLabel
local aboutButton
local moonGroup
local toggle
local aboutOverlay
local aboutGui
local aboutPanel
local footer = {}
local shown = false
local sliding = false

local function currentSizes()
    return if Layout.isCompact() then SIZES.compact else SIZES.pc
end

local function columnPosition(compact, dy)
    if compact then
        return UDim2.new(0, COMPACT_LEFT, 0.5, dy)
    end
    return UDim2.new(0, BLOCK_LEFT, 0.5, BLOCK_TOP - CANVAS_CENTER_Y + dy)
end

local function applyLayout()
    if not root then
        return
    end
    local compact = Layout.isCompact()
    local s = currentSizes()

    column.Parent = if compact then backdrop else root
    column.AnchorPoint = if compact then Vector2.new(0, 0.5) else Vector2.new(0, 0)
    column.Size = UDim2.fromOffset(s.width, 0)
    if not sliding then
        column.Position = columnPosition(compact, 0)
    end
    columnList.Padding = UDim.new(0, s.gap)
    badge.Size = UDim2.fromOffset(0, s.badgeHeight)
    badgeLabel.TextSize = s.badgeText
    titleLabel.TextSize = s.title
    titleLabel.Size = UDim2.new(1, 0, 0, s.titleHeight)
    subtitleLabel.TextSize = s.subtitle
    startButton.Size = UDim2.fromOffset(s.button.X, s.button.Y)
    startLabel.TextSize = s.buttonText
    aboutButton.Size = UDim2.fromOffset(0, if compact then 36 else 44)
    aboutButton.TextSize = if compact then 15 else 17
    for _, item in ipairs(footer) do
        item.Visible = not compact
    end

    local scale = Layout.scale()
    local screenWidth = backdrop.AbsoluteSize.X
    if screenWidth <= 0 then
        screenWidth = 1280 * scale
    end
    local moonLeft = screenWidth - (MOON_RIGHT + MOON_SIZE) * scale
    local textRight = if compact then COMPACT_LEFT + s.width else (BLOCK_LEFT + s.width) * scale
    moonGroup.Visible = moonLeft >= textRight + MOON_TEXT_GAP

    if aboutPanel then
        local viewport = backdrop.AbsoluteSize / scale
        local width = math.min(ABOUT_WIDTH, math.max(280, viewport.X - 32))
        local height = math.min(ABOUT_MAX_HEIGHT, math.max(240, viewport.Y - 48))
        aboutPanel.Size = UDim2.fromOffset(width, height)
    end
end

local function playIntro()
    local compact = Layout.isCompact()
    sliding = true
    column.GroupTransparency = 1
    column.Position = columnPosition(compact, SLIDE)
    local info = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(column, info, { GroupTransparency = 0 }):Play()
    local slide = TweenService:Create(column, info, { Position = columnPosition(compact, 0) })
    slide.Completed:Connect(function()
        sliding = false
        applyLayout()
    end)
    slide:Play()
end

local function buildMoon()
    local function crater(right, top, size, transparency)
        local x = MOON_SIZE - (right - MOON_RIGHT) - size
        local y = top - MOON_TOP
        return UI.create("Frame", {
            Name = "Crater",
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(size, size),
            BackgroundColor3 = Color3.fromRGB(120, 130, 160),
            BackgroundTransparency = transparency,
            ZIndex = 3,
        }, { UI.roundCorner() })
    end
    moonGroup = UI.create("Frame", {
        Name = "Moon",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -MOON_RIGHT, 0, MOON_TOP),
        Size = UDim2.fromOffset(MOON_SIZE, MOON_SIZE),
        BackgroundTransparency = 1,
        Parent = root,
    }, {
        UI.create("Frame", {
            Name = "Glow",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(MOON_SIZE + 120, MOON_SIZE + 120),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.93,
            ZIndex = 1,
        }, { UI.roundCorner() }),
        UI.create("Frame", {
            Name = "Body",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = L.white,
            ZIndex = 2,
        }, {
            UI.roundCorner(),
            UI.create("UIGradient", {
                Rotation = 50,
                Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
                    ColorSequenceKeypoint.new(0.35, Color3.fromRGB(230, 233, 242)),
                    ColorSequenceKeypoint.new(0.7, Color3.fromRGB(174, 182, 204)),
                    ColorSequenceKeypoint.new(1, Color3.fromRGB(125, 135, 166)),
                }),
            }),
        }),
        crater(230, 170, 56, 0.65),
        crater(330, 300, 34, 0.7),
        crater(180, 330, 80, 0.72),
    })
end

-- 아래 칩: 자원 아이콘 + 문구
local function chip(order, kind, key)
    local icon = Icons.resource(kind, 18)
    icon.LayoutOrder = 1
    local label = UI.create("TextLabel", {
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 44),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 16,
        TextColor3 = L.white,
    })
    UI.msg(label, key)
    return UI.create("Frame", {
        Name = "Chip" .. order,
        LayoutOrder = order,
        Size = UDim2.fromOffset(0, 44),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.35,
    }, {
        UI.corner(16),
        UI.padding({ 0, 0, 18, 18 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        icon,
        label,
    })
end

local function arrow(color)
    local function bar(x, y, width, rotation)
        return UI.create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(width, 3),
            Rotation = rotation,
            BackgroundColor3 = color,
        }, { UI.roundCorner() })
    end
    return UI.create("Frame", {
        Name = "Arrow",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(20, 20),
        BackgroundTransparency = 1,
    }, {
        bar(10, 10, 15, 0),
        bar(13.5, 6.5, 9, 45),
        bar(13.5, 13.5, 9, -45),
    })
end

local function setAboutVisible(visible)
    if aboutGui then
        aboutGui.Enabled = visible
        if visible then
            applyLayout()
        end
    end
end

local function buildAbout()
    -- 타이틀 위에 따로 뜨는 화면 (compact에서 제목 묶음이 backdrop로 옮겨 가도 가리지 않게)
    aboutGui = UI.gui("TitleAbout", 101)
    aboutGui.Enabled = false
    local title = UI.create("TextLabel", {
        Name = "Title",
        Position = UDim2.fromOffset(24, 20),
        Size = UDim2.new(1, -120, 0, 32),
        FontFace = UI.RoundHeavy,
        TextSize = 26,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.scaledText(title, 26, 16)
    UI.msg(title, "title.about.title")
    local close = UI.lunaButton({
        Name = "Close",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -20, 0, 18),
        Size = UDim2.fromOffset(0, 36),
        AutomaticSize = Enum.AutomaticSize.X,
        TextSize = 16,
    }, false)
    UI.msg(close, "title.about.close")
    close.Activated:Connect(function()
        setAboutVisible(false)
    end)
    local scroll = UI.create("ScrollingFrame", {
        Name = "Lines",
        Position = UDim2.fromOffset(24, 66),
        Size = UDim2.new(1, -36, 1, -86),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 6,
        ScrollBarImageColor3 = L.dim,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, { UI.list(Enum.FillDirection.Vertical, 12), UI.padding({ 0, 8, 0, 14 }) })
    local dots = { L.gold, L.sky, L.mint }
    for i, key in ipairs(ABOUT_LINES) do
        local text = UI.create("TextLabel", {
            Name = "Text",
            Position = UDim2.fromOffset(22, 0),
            Size = UDim2.new(1, -22, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Font = UI.Font,
            TextSize = 17,
            TextColor3 = L.body,
            TextWrapped = true,
            LineHeight = 1.15,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
        UI.msg(text, key)
        UI.create("Frame", {
            Name = "Line" .. i,
            LayoutOrder = i,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Parent = scroll,
        }, {
            UI.dot(10, dots[(i - 1) % #dots + 1], { Position = UDim2.fromOffset(0, 6) }),
            text,
        })
    end
    aboutPanel = UI.lunaPanel({
        Name = "AboutPanel",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(ABOUT_WIDTH, ABOUT_MAX_HEIGHT),
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.04,
    }, { title, close, scroll }, 22)
    aboutOverlay = UI.create("TextButton", {
        Name = "AboutOverlay",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.45,
        AutoButtonColor = false,
        Text = "",
        Parent = Layout.root(aboutGui),
    }, { aboutPanel })
    -- 패널 바깥(어두운 바탕)을 누르면 닫는다
    aboutOverlay.Activated:Connect(function()
        setAboutVisible(false)
    end)
    aboutPanel.Active = true -- 패널 안을 눌러도 바깥 닫기 버튼으로 새지 않게
end

function TitleV2.init(ctx)
    onStart = ctx.onStart
    gui = UI.gui("TitleV2", 100)
    gui.Enabled = false

    backdrop = UI.create("Frame", {
        Name = "Backdrop",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.white,
        Active = true, -- 빈 곳을 눌러도 카메라와 썸스틱으로 새지 않게
        Parent = gui,
    }, { UI.lunaGradient() })
    root = Layout.root(gui)
    root.Parent = backdrop
    buildMoon()

    UI.create("Frame", {
        Name = "Horizon",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 1, -HORIZON_VISIBLE),
        Size = UDim2.fromOffset(HORIZON_SIZE, HORIZON_SIZE),
        BackgroundColor3 = L.white,
        Parent = root,
    }, {
        UI.roundCorner(),
        UI.create("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(217, 221, 232)),
                ColorSequenceKeypoint.new(0.04, Color3.fromRGB(169, 177, 198)),
                ColorSequenceKeypoint.new(0.1, Color3.fromRGB(108, 117, 145)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(108, 117, 145)),
            }),
        }),
    })

    local chips = UI.create("Frame", {
        Name = "Chips",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, CHIPS_LEFT, 1, -BOTTOM_GAP),
        Size = UDim2.fromOffset(0, 44),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        ZIndex = 2,
        Parent = root,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 14),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        chip(1, "energy", "title.chip.energy"),
        chip(2, "water", "title.chip.water"),
        chip(3, "food", "title.chip.food"),
    })
    local crew = UI.create("TextLabel", {
        Name = "Crew",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -CREW_RIGHT, 1, -BOTTOM_GAP),
        Size = UDim2.fromOffset(0, 44),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.label,
        ZIndex = 2,
        Parent = root,
    }, {
        UI.create("UIStroke", {
            Color = L.bgTop,
            Thickness = 1.5,
            Transparency = 0.3,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
        }),
    })
    UI.msg(crew, "title.crew")
    footer = { chips, crew }

    badgeLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 2,
        Size = UDim2.fromScale(0, 1),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.body,
    })
    UI.msg(badgeLabel, "title.badge")
    badge = UI.create("Frame", {
        Name = "Badge",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 34),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.86,
    }, {
        UI.roundCorner(),
        UI.padding({ 0, 0, 16, 16 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        UI.dot(12, L.gold, { LayoutOrder = 1 }, true),
        badgeLabel,
    })
    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 196),
        FontFace = UI.RoundHeavy,
        TextSize = 100,
        LineHeight = 0.95,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(titleLabel, "title.name")
    subtitleLabel = UI.create("TextLabel", {
        Name = "Subtitle",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextSize = 24,
        LineHeight = 1.3,
        TextColor3 = L.soft,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(subtitleLabel, { key = "title.subtitle", args = { days = MissionConfig.TOTAL_DAYS } })
    startLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.fromScale(0, 1),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 24,
        TextColor3 = L.ink,
    })
    UI.msg(startLabel, "title.start")
    startButton = UI.create("TextButton", {
        Name = "StartButton",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(300, 72),
        BackgroundColor3 = L.mint,
        AutoButtonColor = false,
        Text = "",
    }, {
        UI.roundCorner(),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 12),
            SortOrder = Enum.SortOrder.LayoutOrder,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        startLabel,
        arrow(L.ink),
    })
    UI.hoverTransparency(startButton, 0, BUTTON_HOVER_TRANSPARENCY)
    aboutButton = UI.lunaButton({
        Name = "AboutButton",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 44),
        AutomaticSize = Enum.AutomaticSize.X,
        TextSize = 17,
    }, false)
    UI.msg(aboutButton, "title.about.button")
    local buttons = UI.create("Frame", {
        Name = "Buttons",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 16),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Wraps = true,
        }),
        startButton,
        aboutButton,
    })

    columnList = UI.list(Enum.FillDirection.Vertical, 18)
    column = UI.create("CanvasGroup", {
        Name = "Column",
        Size = UDim2.fromOffset(BLOCK_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 4,
        Parent = root,
    }, { columnList, badge, titleLabel, subtitleLabel, buttons })

    -- 언어 토글: 오른쪽 위 (Roblox 상단 바 아래)
    toggle = LanguageToggle.create(backdrop)
    toggle.AnchorPoint = Vector2.new(1, 0)
    toggle.Position = UDim2.new(1, -TOGGLE_MARGIN, 0, UI.topInset() + 10)
    toggle.ZIndex = 10

    buildAbout()

    startButton.Activated:Connect(function()
        setAboutVisible(false)
        if onStart then
            onStart()
        end
    end)
    aboutButton.Activated:Connect(function()
        setAboutVisible(true)
    end)

    applyLayout()
    Layout.changed:Connect(applyLayout)
    backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
end

function TitleV2.setVisible(visible)
    gui.Enabled = visible
    if visible then
        applyLayout()
        if not shown then
            playIntro()
        end
    else
        setAboutVisible(false)
    end
    shown = visible
end

function TitleV2.isVisible()
    return gui ~= nil and gui.Enabled
end

return TitleV2
