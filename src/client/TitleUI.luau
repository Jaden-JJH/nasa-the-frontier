--!nonstrict
-- 타이틀 화면. 시작 버튼은 로컬에서만 화면을 숨긴다.

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local TitleUI = {}

local gui
local onStart

function TitleUI.init(ctx)
    onStart = ctx.onStart
    gui = UI.gui("Title", 100)
    gui.Enabled = false

    local startButton = UI.create("TextButton", {
        Name = "StartButton",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(240, 56),
        BackgroundColor3 = Colors.accent,
        Text = "시작",
        TextSize = 26,
    }, { UI.corner(10) })

    UI.create("Frame", {
        Name = "Root",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Colors.bg,
        Parent = gui,
    }, {
        UI.create("UIGradient", {
            Color = ColorSequence.new(Color3.fromRGB(14, 20, 44), Color3.fromRGB(4, 6, 14)),
            Rotation = 90,
        }),
        UI.create("Frame", {
            Name = "Center",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(700, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
        }, {
            UI.list(Enum.FillDirection.Vertical, 18, Enum.HorizontalAlignment.Center),
            UI.create("TextLabel", {
                Name = "Title",
                LayoutOrder = 1,
                Size = UDim2.new(1, 0, 0, 84),
                Font = UI.FontBold,
                Text = "The Frontier",
                TextSize = 72,
            }),
            UI.create("TextLabel", {
                Name = "Subtitle",
                LayoutOrder = 2,
                Size = UDim2.new(1, 0, 0, 36),
                Text = string.format(
                    "달 기지를 건설하고 %d일을 살아남으세요",
                    ctx.Config.TOTAL_DAYS
                ),
                TextColor3 = Colors.textDim,
                TextSize = 22,
            }),
            startButton,
        }),
    })

    startButton.Activated:Connect(function()
        if onStart then
            onStart()
        end
    end)
end

function TitleUI.setVisible(visible)
    gui.Enabled = visible
end

return TitleUI
