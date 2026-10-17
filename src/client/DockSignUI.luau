--!nonstrict
-- 충전 패드 표지판. Workspace.Base.ChargePad의 Attribute DockState와 state.rover.battery로 그린다.
-- empty는 표시하지 않고, docked, charging, full 세 상태를 PadSignUI와 같은 디자인으로 보여 준다.

local Players = game:GetService("Players")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local DockSignUI = {}

local SIGN_WIDTH = 210
local MAX_DISTANCE = 120
local ANCHOR_GAP = 4

local sign = nil
local lastState = nil
local rebuildQueued = false
local attrConn = nil

local function clearSign()
    if attrConn then
        attrConn:Disconnect()
        attrConn = nil
    end
    if sign then
        sign.gui:Destroy()
        sign = nil
    end
end

local function makeSign(pad)
    local badgeLabel = UI.create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Preset = "badge",
        Text = "",
    })
    local badge = UI.create("Frame", {
        Name = "Badge",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(110, 26),
        BackgroundColor3 = Colors.water,
    }, { UI.roundCorner(), badgeLabel })
    local bar = UI.progressBar(Colors.energy, 6)
    bar.root.LayoutOrder = 3
    local valueLabel = UI.create("TextLabel", {
        Name = "Value",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 18),
        Preset = "caption",
        Text = "",
        TextColor3 = Colors.energy,
    }, { UI.worldStroke() })
    local noteLabel = UI.create("TextLabel", {
        Name = "Note",
        LayoutOrder = 5,
        Size = UDim2.new(1, 0, 0, 36),
        Preset = "caption",
        Text = "",
        TextColor3 = Colors.textDim,
        TextWrapped = true,
    }, { UI.worldStroke() })

    local panel = UI.create("Frame", {
        Name = "Panel",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 0.5, -ANCHOR_GAP),
        Size = UDim2.fromOffset(SIGN_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
    }, {
        UI.corner(12),
        UI.stroke(Colors.panelLight, 1.5),
        UI.padding(10),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            Padding = UDim.new(0, 6),
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        UI.create("TextLabel", {
            Name = "Name",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 26),
            Preset = "heading",
            Text = "충전 도크",
        }, { UI.worldStroke() }),
        badge,
        bar.root,
        valueLabel,
        noteLabel,
    })

    local gui = UI.create("BillboardGui", {
        Name = "DockSign",
        Adornee = pad,
        AlwaysOnTop = true,
        LightInfluence = 0,
        ResetOnSpawn = false,
        MaxDistance = MAX_DISTANCE,
        Enabled = false,
        Size = UDim2.fromOffset(SIGN_WIDTH + 20, 400),
        StudsOffsetWorldSpace = Vector3.new(0, pad.Size.Y / 2 + UI.WORLD_ANCHOR_OFFSET, 0),
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
    }, { panel })

    return {
        gui = gui,
        pad = pad,
        badge = badge,
        badgeLabel = badgeLabel,
        bar = bar,
        valueLabel = valueLabel,
        noteLabel = noteLabel,
    }
end

local function apply()
    if not sign then
        return
    end
    local dockState = sign.pad:GetAttribute("DockState")
    if dockState ~= "docked" and dockState ~= "charging" and dockState ~= "full" then
        sign.gui.Enabled = false
        return
    end
    sign.gui.Enabled = true

    local rover = lastState and lastState.rover
    local battery = rover and rover.battery
    local batteryMax = rover and rover.batteryMax
    local hasBattery = type(battery) == "number" and type(batteryMax) == "number" and batteryMax > 0

    local badgeColor, badgeText, darkText, note = Colors.water, "", true, ""
    local showBar = false
    if dockState == "docked" then
        badgeText = "도킹됨"
        note = "하차하면 충전이 시작됩니다"
    elseif dockState == "charging" then
        badgeColor, badgeText = Colors.energy, "충전 중"
        showBar = hasBattery
    else
        badgeColor, badgeText = Colors.good, "충전 완료"
    end

    sign.badge.BackgroundColor3 = badgeColor
    sign.badgeLabel.Text = badgeText
    sign.badgeLabel.TextColor3 = if darkText then Colors.bg else Colors.text
    sign.bar.root.Visible = showBar
    sign.valueLabel.Visible = showBar
    if showBar then
        sign.bar.setRatio(battery / batteryMax)
        sign.valueLabel.Text =
            string.format("%d / %d", math.floor(battery + 0.5), math.floor(batteryMax + 0.5))
    end
    sign.noteLabel.Visible = note ~= ""
    sign.noteLabel.Text = note
end

local function rebuild()
    clearSign()
    local base = workspace:FindFirstChild("Base")
    local pad = base and base:FindFirstChild("ChargePad")
    if not (pad and pad:IsA("BasePart")) then
        return
    end
    sign = makeSign(pad)
    attrConn = pad:GetAttributeChangedSignal("DockState"):Connect(apply)
    apply()
end

local function queueRebuild()
    if rebuildQueued then
        return
    end
    rebuildQueued = true
    task.defer(function()
        rebuildQueued = false
        rebuild()
    end)
end

local function watchBase(base)
    base.DescendantAdded:Connect(function(descendant)
        if descendant.Name == "ChargePad" then
            queueRebuild()
        end
    end)
end

function DockSignUI.init(_ctx)
    workspace.ChildAdded:Connect(function(child)
        if child.Name == "Base" then
            watchBase(child)
            queueRebuild()
        end
    end)
    workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Base" then
            clearSign()
        end
    end)
    local existing = workspace:FindFirstChild("Base")
    if existing then
        watchBase(existing)
    end
    rebuild()
end

function DockSignUI.update(state)
    lastState = state
    apply()
end

return DockSignUI
