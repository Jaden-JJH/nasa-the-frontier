--!nonstrict
-- 타이틀 화면. 시작 버튼은 로컬에서만 화면을 숨긴다.
-- 명예의 전당은 결과 화면에서만 보인다(2026-10-19 17차, 사용자 결정). 여기는 제목 묶음만 가운데 둔다.
-- compact(Layout.isCompact)에서는 글자와 버튼을 줄인다.

local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local Colors = UI.Colors

local TitleUI = {}

local CENTER_MAX_WIDTH = 700
local COMPACT_SIDE_GAP = 16

local gui
local onStart
local root
local center
local centerList
local titleLabel
local subtitleLabel
local startButton

local function viewportSize()
    local camera = workspace.CurrentCamera
    local size = if camera then camera.ViewportSize else Vector2.new(1280, 720)
    if size.Y < 200 then
        return Vector2.new(1280, 720)
    end
    return size
end

-- 제목 묶음은 항상 가운데. compact는 글자와 버튼을 줄인다
local function applyLayout()
    if not root then
        return
    end
    local viewport = viewportSize()
    center.AnchorPoint = Vector2.new(0.5, 0.5)
    center.Position = UDim2.fromScale(0.5, 0.5)
    if Layout.isCompact() then
        center.Size =
            UDim2.fromOffset(math.min(CENTER_MAX_WIDTH, viewport.X - COMPACT_SIDE_GAP * 2), 0)
        centerList.Padding = UDim.new(0, 8)
        titleLabel.TextSize = 44
        titleLabel.Size = UDim2.new(1, 0, 0, 50)
        subtitleLabel.TextSize = 16
        startButton.Size = UDim2.fromOffset(200, 46)
    else
        center.Size = UDim2.fromOffset(CENTER_MAX_WIDTH, 0)
        centerList.Padding = UDim.new(0, 18)
        titleLabel.TextSize = 72
        titleLabel.Size = UDim2.new(1, 0, 0, 84)
        subtitleLabel.TextSize = 22
        startButton.Size = UDim2.fromOffset(240, 56)
    end
end

function TitleUI.init(ctx)
    onStart = ctx.onStart
    gui = UI.gui("Title", 100)
    gui.Enabled = false

    startButton = UI.create("TextButton", {
        Name = "StartButton",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(240, 56),
        BackgroundColor3 = Colors.accent,
        Text = "시작",
        Preset = "heading",
        TextSize = 26,
    }, { UI.corner(10) })

    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 84),
        Text = "The Frontier",
        Preset = "title",
        TextSize = 72,
    })
    subtitleLabel = UI.create("TextLabel", {
        Name = "Subtitle",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "3개월 안에 거주, 식량, 연구 시설을 완성해 달 기지를 세우세요",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextSize = 22,
        TextWrapped = true,
    })
    centerList = UI.list(Enum.FillDirection.Vertical, 18, Enum.HorizontalAlignment.Center)
    center = UI.create("Frame", {
        Name = "Center",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(CENTER_MAX_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        centerList,
        titleLabel,
        subtitleLabel,
        startButton,
    })

    root = UI.create("Frame", {
        Name = "Root",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Colors.bg,
        Parent = gui,
    }, {
        UI.create("UIGradient", {
            Color = ColorSequence.new(Color3.fromRGB(14, 20, 44), Color3.fromRGB(4, 6, 14)),
            Rotation = 90,
        }),
        center,
    })

    startButton.Activated:Connect(function()
        if onStart then
            onStart()
        end
    end)

    applyLayout()
    Layout.changed:Connect(applyLayout)
    local camera = workspace.CurrentCamera
    if camera then
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
    end
end

function TitleUI.setVisible(visible)
    gui.Enabled = visible
    if visible then
        applyLayout()
    end
end

return TitleUI
