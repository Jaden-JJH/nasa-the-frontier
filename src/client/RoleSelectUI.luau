--!nonstrict
-- v2 멀티 시작 역할 선택 (CONTRACT_V2 4.1 RoleUpdate, V2_PLAN 15.3 Q25). 10초 동안 고르고, 안 고르면 서버가 자동 배정.
-- 가운데 패널에 역할 카드 3장(관제사, 탐사대원, 엔지니어): 이름, 한 줄 할 일, 인원(지금 / 최대), 고르기 버튼.
-- 누르면 ChooseRole(role). 인원 규칙은 서버가 검증하고 결과를 RoleUpdate로 다시 보낸다.
-- Session.rolesSelecting이 true이고 멀티일 때만 보인다(Main.client가 setVisible).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))

local Layout = require(script.Parent.Layout)
local Net = require(script.Parent.Net)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local L = UI.Luna

local RoleSelectUI = {}

local PANEL_WIDTH = 880
local CARD_WIDTH = 260
local ROLE_COLORS = { controller = L.gold, explorer = L.mint, engineer = L.sky }

local gui
local panel
local countdownLabel
local mineLabel
local cards = {} -- [role] = { frame, stroke, count, button }
local heartbeat = nil

local function refresh()
    local roles = Session.roles
    local counts = ClientMath.roleCounts(roles)
    local mine = roles[Players.LocalPlayer.UserId]
    for role, card in pairs(cards) do
        local count = counts[role] or 0
        local max = Session.roleCapacity(role)
        -- 자리가 없는 역할(2명일 때 엔지니어)은 카드를 숨긴다
        card.frame.Visible = max > 0 or mine == role
        UI.msg(card.count, { key = "fmt.fraction", args = { value = count, max = max } })
        local selected = mine == role
        card.stroke.Color = if selected then ROLE_COLORS[role] else L.white
        card.stroke.Transparency = if selected then 0 else UI.LUNA_STROKE_TRANSPARENCY
        card.stroke.Thickness = if selected then 3 else 1
        card.frame.BackgroundTransparency = if selected then 0.82 else 0.9
        local full = count >= max and not selected
        UI.setButtonEnabled(card.button, not selected and not full, true)
        if selected then
            UI.msg(
                card.button,
                { key = "role.pick.mine", args = { role = { key = Session.ROLE_NAMES[role] } } }
            )
        elseif full then
            UI.msg(card.button, "role.full")
        else
            UI.msg(card.button, "role.pick.choose")
        end
    end
    if mine and Session.ROLE_NAMES[mine] then
        mineLabel.Visible = true
        UI.msg(
            mineLabel,
            { key = "role.pick.mine", args = { role = { key = Session.ROLE_NAMES[mine] } } }
        )
    else
        mineLabel.Visible = false
    end
end

local function updateCountdown()
    local deadline = Session.roleDeadline
    countdownLabel.Visible = deadline ~= nil
    if deadline then
        UI.msg(countdownLabel, {
            key = "role.pick.auto",
            args = { count = ClientMath.secondsLeft(deadline, workspace:GetServerTimeNow()) },
        })
    end
end

local function buildCard(role, order)
    local icon = UI.create("Frame", {
        Name = "Icon",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(44, 44),
        BackgroundColor3 = ROLE_COLORS[role],
    }, { UI.roundCorner() })
    local name = UI.create("TextLabel", {
        Name = "Name",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.RoundHeavy,
        TextSize = 22,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(name, Session.ROLE_NAMES[role])
    local duty = UI.create("TextLabel", {
        Name = "Duty",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = 15,
        TextColor3 = L.body,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(duty, Session.ROLE_DUTIES[role])
    local count = UI.create("TextLabel", {
        Name = "Count",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 20),
        FontFace = UI.MonoBold,
        TextSize = 14,
        TextColor3 = L.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local button = UI.lunaButton({
        Name = "Choose",
        LayoutOrder = 5,
        Size = UDim2.new(1, 0, 0, 44),
        TextSize = 16,
    }, true)
    UI.scaledText(button, 16, 11)
    button.Activated:Connect(function()
        if button.Active then
            Net.fire("ChooseRole", role)
        end
    end)
    local frame = UI.lunaPanel({
        Name = "Card_" .. role,
        LayoutOrder = order,
        Size = UDim2.fromOffset(CARD_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
    }, {
        UI.padding(16),
        UI.list(Enum.FillDirection.Vertical, 10),
        icon,
        name,
        duty,
        count,
        button,
    })
    cards[role] = {
        frame = frame,
        stroke = frame:FindFirstChildOfClass("UIStroke"),
        count = count,
        button = button,
    }
    return frame
end

local function fit()
    if not panel then
        return
    end
    local scale = Layout.scale()
    local abs = gui.AbsoluteSize
    if abs.X <= 0 then
        abs = Vector2.new(1280, 720) * scale
    end
    local width = math.min(PANEL_WIDTH, abs.X / scale - 24)
    panel.Size = UDim2.fromOffset(width, 0)
end

function RoleSelectUI.init(_ctx)
    gui = UI.gui("RoleSelect", 96)
    gui.Enabled = false
    local root = Layout.root(gui)
    UI.create("Frame", {
        Name = "Dim",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.inkDeep,
        BackgroundTransparency = 0.35,
        Active = true,
        Parent = root,
    })
    local title = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.RoundHeavy,
        TextSize = 32,
        TextColor3 = L.white,
        TextWrapped = true,
    })
    UI.msg(title, "role.pick.title")
    countdownLabel = UI.create("TextLabel", {
        Name = "Countdown",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = 16,
        TextColor3 = L.gold,
        TextWrapped = true,
    })
    local cardRow = UI.create("Frame", {
        Name = "Cards",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            Padding = UDim.new(0, 16),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Wraps = true,
        }),
    })
    for i, role in ipairs(Session.ROLE_ORDER) do
        buildCard(role, i).Parent = cardRow
    end
    mineLabel = UI.create("TextLabel", {
        Name = "Mine",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = 17,
        TextColor3 = L.mint,
        TextWrapped = true,
        Visible = false,
    })
    panel = UI.lunaPanel({
        Name = "Panel",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PANEL_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.02,
        Parent = root,
    }, {
        UI.lunaGradient(),
        UI.padding(24),
        UI.list(Enum.FillDirection.Vertical, 14, Enum.HorizontalAlignment.Center),
        title,
        countdownLabel,
        cardRow,
        mineLabel,
    }, 24)
    refresh()
    fit()
    Layout.changed:Connect(fit)
    Session.changed:Connect(function(what)
        if what == "roles" then
            refresh()
        end
    end)
end

function RoleSelectUI.setVisible(visible)
    if not gui or gui.Enabled == visible then
        return
    end
    gui.Enabled = visible
    if visible then
        fit()
        refresh()
        heartbeat = RunService.Heartbeat:Connect(updateCountdown)
    elseif heartbeat then
        heartbeat:Disconnect()
        heartbeat = nil
    end
end

return RoleSelectUI
