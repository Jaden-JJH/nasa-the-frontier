--!nonstrict
-- 결과 화면 (승리와 실패 공용). 재도전 버튼은 RequestRestart를 보낸다.

local Players = game:GetService("Players")

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
local noteLabel
local restartPressed = false
local restartAvailableAt = nil -- workspace:GetServerTimeNow() 기준, nil이면 즉시 가능
local chooserUserId = nil -- nil이면 누구나 (기존 동작)

local function makeRow(parent, order, labelText)
    local value = UI.create("TextLabel", {
        Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromScale(0.5, 1),
        Text = "-",
        Preset = "heading",
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
            Preset = "body",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        value,
    })
    return value
end

-- 재도전 버튼 상태: 권한자 아님(숨김), 카운트다운(비활성), 가능, 이미 눌림
local function updateRestartButton()
    local localId = Players.LocalPlayer.UserId
    if chooserUserId ~= nil and chooserUserId ~= localId then
        local chooser = Players:GetPlayerByUserId(chooserUserId)
        noteLabel.Text = if chooser
            then string.format(
                "선택 권한자(%s)가 재도전을 결정합니다",
                chooser.DisplayName
            )
            else "선택 권한자가 재도전을 결정합니다"
        noteLabel.Visible = true
        restartButton.Visible = false
        return
    end
    noteLabel.Visible = false
    restartButton.Visible = true
    if restartPressed then
        return
    end
    local remaining = if restartAvailableAt
        then restartAvailableAt - workspace:GetServerTimeNow()
        else 0
    if remaining > 0 then
        restartButton.Active = false
        restartButton.BackgroundColor3 = Colors.disabled
        restartButton.Text = string.format("재도전 %d초 후", math.ceil(remaining))
    else
        restartButton.Active = true
        restartButton.BackgroundColor3 = Colors.accent
        restartButton.Text = "재도전"
    end
end

function ResultUI.init(ctx)
    restartRemote = ctx.remotes.RequestRestart
    gui = UI.gui("Result", 80)
    gui.Enabled = false

    titleLabel = UI.create("TextLabel", {
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 56),
        Text = "",
        Preset = "title",
        TextSize = 44,
    })
    reasonLabel = UI.create("TextLabel", {
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "body",
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
        Preset = "heading",
    }, { UI.corner(10) })

    noteLabel = UI.create("TextLabel", {
        Name = "RestartNote",
        LayoutOrder = 5,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextWrapped = true,
        Visible = false,
    })

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
            noteLabel,
        }),
    })

    restartButton.Activated:Connect(function()
        if not restartButton.Active then
            return
        end
        restartPressed = true
        restartButton.Active = false
        restartButton.BackgroundColor3 = Colors.disabled
        restartButton.Text = "다시 준비 중..."
        restartRemote:FireServer()
    end)

    -- 카운트다운 갱신
    task.spawn(function()
        while true do
            if visible then
                updateRestartButton()
            end
            task.wait(0.25)
        end
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

    restartAvailableAt = result.restartAvailableAt
    chooserUserId = result.chooserUserId
    if not visible then
        restartPressed = false
    end
    visible = true
    gui.Enabled = true
    updateRestartButton()
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
    restartPressed = false
    gui.Enabled = false
end

function ResultUI.isVisible()
    return visible
end

return ResultUI
