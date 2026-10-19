--!nonstrict
-- 타이틀 화면 C안 "루나 소프트" (2026-10-19 18차, 사용자 결정. 목업 C_Title.dc.html 1280x720 수치를 옮김).
-- 배경 그라데이션은 화면 전체, 달과 크레이터와 지평선 장식, 아래 칩과 문구는 Layout 루트(가상 좌표, 화면 높이 배율) 안에 둔다.
-- 왼쪽 묶음(배지, "The Frontier", 부제, 시작 버튼)은 화면 세로 중앙 기준으로 목업 좌표(왼쪽 96, 위 150)를 지킨다.
-- compact(Layout.isCompact)에서는 왼쪽 묶음을 배율 없는 실제 px 공간으로 옮겨 글자와 버튼을 줄이고 아래 칩과 문구를 숨긴다.
-- 시작 버튼은 로컬에서만 화면을 숨긴다(onStart). 명예의 전당은 결과 화면에서만 보인다(17차).

local TweenService = game:GetService("TweenService")

local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local L = UI.Luna

local TitleUI = {}

-- 목업 기준 수치 (가상 좌표)
local CANVAS_CENTER_Y = 360
local BLOCK_LEFT = 96
local BLOCK_TOP = 150
local BLOCK_WIDTH = 620
local MOON_RIGHT = 120
local MOON_TOP = 90
local MOON_SIZE = 360
local HORIZON_SIZE = 2400 -- 아주 큰 원의 윗부분을 지평선으로 쓴다(목업 타원 대신)
local HORIZON_VISIBLE = 180 -- 화면 아래에서 보이는 높이
local BOTTOM_GAP = 56
local CHIPS_LEFT = 96
local CREW_RIGHT = 64
local COMPACT_LEFT = 32
local MOON_TEXT_GAP = 24 -- 달 장식과 글자 묶음 사이 최소 간격(실제 px)

-- 모드별 크기. pc는 가상 좌표(배율 적용), compact는 실제 px
local SIZES = {
    pc = {
        gap = 18,
        badgeHeight = 34,
        badgeText = 14,
        title = 100, -- 목업 104, Roblox TextSize 상한 100
        titleHeight = 196,
        subtitle = 24,
        subtitleHeight = 76,
        button = Vector2.new(300, 72),
        buttonText = 24,
        buttonTop = 10, -- 목업 margin-top
        width = BLOCK_WIDTH,
    },
    compact = {
        gap = 10,
        badgeHeight = 30,
        badgeText = 14,
        title = 48,
        titleHeight = 94,
        subtitle = 16,
        subtitleHeight = 46,
        button = Vector2.new(200, 52),
        buttonText = 18,
        buttonTop = 4,
        width = 420,
    },
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
local buttonHolder
local startButton
local startLabel
local moonGroup
local footer = {}
local shown = false
local sliding = false

local function currentSizes()
    return if Layout.isCompact() then SIZES.compact else SIZES.pc
end

-- 묶음 위치. 등장 연출은 SLIDE만큼 아래에서 올라온다
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
    subtitleLabel.Size = UDim2.new(1, 0, 0, s.subtitleHeight)
    buttonHolder.Size = UDim2.fromOffset(s.button.X, s.button.Y + s.buttonTop)
    startButton.Position = UDim2.fromOffset(0, s.buttonTop)
    startButton.Size = UDim2.fromOffset(s.button.X, s.button.Y)
    startLabel.TextSize = s.buttonText
    for _, item in ipairs(footer) do
        item.Visible = not compact
    end

    -- 좁은 화면에서 달 장식이 글자와 겹치면 숨긴다 (실제 px로 비교)
    local scale = Layout.scale()
    local screenWidth = backdrop.AbsoluteSize.X
    if screenWidth <= 0 then
        screenWidth = 1280 * scale
    end
    local moonLeft = screenWidth - (MOON_RIGHT + MOON_SIZE) * scale
    local textRight = if compact then COMPACT_LEFT + s.width else (BLOCK_LEFT + s.width) * scale
    moonGroup.Visible = moonLeft >= textRight + MOON_TEXT_GAP
end

-- 등장 연출: 왼쪽 묶음 0.4초 페이드 인 + 살짝 올라옴
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

-- 달 장식: 빛 번짐(큰 반투명 원), 회색 그라데이션 달, 크레이터 3개. 오른쪽 위 기준
local function buildMoon()
    local function crater(right, top, size, transparency)
        -- 목업 좌표는 화면 오른쪽 기준. 달 그룹(오른쪽 MOON_RIGHT, 위 MOON_TOP) 안 좌표로 바꾼다
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

-- 아래 칩: 색 점 + 문구 (아이콘 대신). 밝은 지평선 위에 걸쳐도 흰 글자가 읽히게 남색 반투명 바탕
local function chip(order, color, text, ring)
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
        UI.dot(if ring then 14 else 12, color, { LayoutOrder = 1 }, ring),
        UI.create("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, 44),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = text,
            Font = UI.FontBold,
            TextSize = 16,
            TextColor3 = L.white,
        }),
    })
end

-- 오른쪽 화살표 (막대 3개, 20x20)
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

function TitleUI.init(ctx)
    onStart = ctx.onStart
    local t = ctx.Config.TEXTS
    gui = UI.gui("Title", 100)
    gui.Enabled = false

    backdrop = UI.create("Frame", {
        Name = "Backdrop",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.white,
        Parent = gui,
    }, { UI.lunaGradient() })
    root = Layout.root(gui)
    root.Parent = backdrop
    buildMoon()

    -- 지평선: 화면 아래에 걸친 큰 원 (밝은 회색에서 아래로 어두워짐)
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

    -- 아래 칩 3개와 오른쪽 아래 문구 (PC만)
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
        chip(1, L.gold, t.titleChipEnergy, true),
        chip(2, L.sky, t.titleChipWater, false),
        chip(3, L.mint, t.titleChipFood, false),
    })
    local crew = UI.create("TextLabel", {
        Name = "Crew",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -CREW_RIGHT, 1, -BOTTOM_GAP),
        Size = UDim2.fromOffset(0, 44),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = t.titleCrew,
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
    footer = { chips, crew }

    -- 왼쪽 묶음
    badgeLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 2,
        Size = UDim2.fromScale(0, 1),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = t.titleBadge,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.body,
    })
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
        Text = t.titleName,
        FontFace = UI.RoundHeavy,
        TextSize = 100,
        LineHeight = 0.95,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    subtitleLabel = UI.create("TextLabel", {
        Name = "Subtitle",
        LayoutOrder = 3,
        Size = UDim2.new(1, 0, 0, 76),
        Text = t.titleSubtitle,
        TextSize = 24,
        LineHeight = 1.4,
        TextColor3 = L.soft,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    startLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.fromScale(0, 1),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = t.titleStart,
        Font = UI.FontBold,
        TextSize = 24,
        TextColor3 = L.ink,
    })
    startButton = UI.create("TextButton", {
        Name = "StartButton",
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
    buttonHolder = UI.create("Frame", {
        Name = "ButtonHolder",
        LayoutOrder = 4,
        Size = UDim2.fromOffset(300, 82),
        BackgroundTransparency = 1,
    }, { startButton })

    columnList = UI.list(Enum.FillDirection.Vertical, 18)
    column = UI.create("CanvasGroup", {
        Name = "Column",
        Size = UDim2.fromOffset(BLOCK_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 4,
        Parent = root,
    }, { columnList, badge, titleLabel, subtitleLabel, buttonHolder })

    startButton.Activated:Connect(function()
        if onStart then
            onStart()
        end
    end)

    applyLayout()
    Layout.changed:Connect(applyLayout)
    backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
end

function TitleUI.setVisible(visible)
    gui.Enabled = visible
    if visible then
        applyLayout()
        if not shown then
            playIntro()
        end
    end
    shown = visible
end

return TitleUI
