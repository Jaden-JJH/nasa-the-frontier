--!nonstrict
-- 결과 화면 (승리와 실패 공용). 재도전 버튼은 RequestRestart를 보낸다.

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local ResultUI = {}

local gui
local restartRemote
local titleLabel
local reasonLabel
local values = {}
local restartButton
local visible = false

local function makeRow(parent, order, labelText)
    local value = UI.create("TextLabel", {
        Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromScale(0.5, 1),
        Font = UI.FontBold,
        Text = "-",
        TextSize = 18,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    UI.create("Frame", {
        Name = labelText,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
        Parent = parent,
    }, {
        UI.create("TextLabel", {
            Size = UDim2.fromScale(0.5, 1),
            Text = labelText,
            TextColor3 = Colors.textDim,
            TextSize = 17,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        value,
    })
    return value
end

function ResultUI.init(ctx)
    restartRemote = ctx.remotes.RequestRestart
    gui = UI.gui("Result", 80)
    gui.Enabled = false

    titleLabel = UI.create("TextLabel", {
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 56),
        Font = UI.FontBold,
        Text = "",
        TextSize = 44,
    })
    reasonLabel = UI.create("TextLabel", {
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        TextSize = 18,
        TextWrapped = true,
    })
    local summary = UI.create("Frame", {
        Name = "Summary",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.bg,
    }, { UI.corner(10), UI.padding(14), UI.list(Enum.FillDirection.Vertical, 4) })
    values.day = makeRow(summary, 1, "소요 일수")
    values.trips = makeRow(summary, 2, "물 원정 횟수")
    values.deaths = makeRow(summary, 3, "산소 고갈 횟수")
    values.site = makeRow(summary, 4, "착륙지")

    restartButton = UI.create("TextButton", {
        Name = "RestartButton",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = Colors.accent,
        Text = "재도전",
        TextSize = 22,
    }, { UI.corner(10) })

    UI.create("Frame", {
        Name = "Dim",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.35,
        Parent = gui,
    }, {
        UI.create("Frame", {
            Name = "Card",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(460, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Colors.panel,
        }, {
            UI.corner(14),
            UI.stroke(Colors.panelLight, 2),
            UI.padding(22),
            UI.list(Enum.FillDirection.Vertical, 14),
            titleLabel,
            reasonLabel,
            summary,
            restartButton,
        }),
    })

    restartButton.Activated:Connect(function()
        restartButton.Active = false
        restartButton.BackgroundColor3 = Colors.disabled
        restartButton.Text = "다시 준비 중..."
        restartRemote:FireServer()
    end)
end

-- GameOver 페이로드(GameOverInfo)로 표시
function ResultUI.show(result)
    titleLabel.Text = result.won and "임무 성공" or "임무 실패"
    titleLabel.TextColor3 = result.won and Colors.good or Colors.bad
    reasonLabel.Text = result.reason or ""
    reasonLabel.Visible = (result.reason or "") ~= ""
    values.day.Text = string.format("%d일", result.day)
    values.trips.Text = string.format("%d회", result.waterTrips)
    values.deaths.Text = string.format("%d회", result.oxygenDeaths)
    values.site.Text = result.siteName or "-"

    if not visible then
        restartButton.Active = true
        restartButton.BackgroundColor3 = Colors.accent
        restartButton.Text = "재도전"
    end
    visible = true
    gui.Enabled = true
end

-- 늦게 들어온 플레이어용 대체 표시 (GameOver를 놓친 경우)
function ResultUI.showFromState(state)
    ResultUI.show({
        won = state.phase == "won",
        reason = "",
        day = state.day,
        waterTrips = state.waterTrips,
        oxygenDeaths = state.oxygenDeaths,
        siteName = state.siteName or "-",
    })
end

function ResultUI.hide()
    visible = false
    gui.Enabled = false
end

function ResultUI.isVisible()
    return visible
end

return ResultUI
