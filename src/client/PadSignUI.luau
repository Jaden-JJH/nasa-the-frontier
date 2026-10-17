--!nonstrict
-- 모듈 패드 표지판. Workspace.Base.ModulePads 아래 각 패드 모델의 Pad 파트 위에 BillboardGui로 그린다.
-- 이름, 상태 배지, 건설 중 진행바, 건설 가능일 때 비용 한 줄을 보여 준다.
-- 표지판은 앵커 위쪽으로 뻗고 PromptUI 패널은 아래쪽으로 뻗어 서로 겹치지 않는다.

local Players = game:GetService("Players")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local PadSignUI = {}

local SIGN_WIDTH = 210
local MAX_DISTANCE = 120
local ANCHOR_GAP = 4

local STATUS_STYLE = {
    locked = { text = "잠김", color = Colors.neutral },
    available = { text = "건설 가능", color = Colors.good },
    building = { text = "건설 중", color = Colors.energy },
    active = { text = "가동 중", color = Colors.water },
}

local RESOURCE_SHORT = { energy = "E", water = "W", food = "F" }
local RESOURCE_ORDER = { "energy", "water", "food" }

local config
local signs = {} -- { [moduleId] = sign }
local lastState = nil
local rebuildQueued = false

local function costText(moduleId)
    local cost = config.MODULES[moduleId].cost
    local parts = {}
    for _, key in ipairs(RESOURCE_ORDER) do
        if cost[key] and cost[key] > 0 then
            table.insert(parts, string.format("%d %s", cost[key], RESOURCE_SHORT[key]))
        end
    end
    return table.concat(parts, ", ")
end

local function makeSign(moduleId, pad)
    local moduleConfig = config.MODULES[moduleId]

    local badgeLabel = UI.create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Preset = "badge",
        Text = "",
    })
    local badge = UI.create("Frame", {
        Name = "Badge",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(110, 26),
        BackgroundColor3 = Colors.neutral,
    }, { UI.roundCorner(), badgeLabel })

    local bar = UI.progressBar(Colors.energy, 6)
    bar.root.LayoutOrder = 3
    local daysLabel = UI.create("TextLabel", {
        Name = "Days",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 18),
        Preset = "caption",
        Text = "",
        TextColor3 = Colors.energy,
    }, { UI.worldStroke() })
    local costLabel = UI.create("TextLabel", {
        Name = "Cost",
        LayoutOrder = 5,
        Size = UDim2.new(1, 0, 0, 18),
        Preset = "caption",
        Text = costText(moduleId),
        TextColor3 = Colors.textDim,
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
            Text = moduleConfig.displayName or moduleConfig.name,
        }, { UI.worldStroke() }),
        badge,
        bar.root,
        daysLabel,
        costLabel,
    })

    local gui = UI.create("BillboardGui", {
        Name = "PadSign" .. moduleId,
        Adornee = pad,
        AlwaysOnTop = true,
        LightInfluence = 0,
        ResetOnSpawn = false,
        MaxDistance = MAX_DISTANCE,
        Size = UDim2.fromOffset(SIGN_WIDTH + 20, 400),
        StudsOffsetWorldSpace = Vector3.new(0, pad.Size.Y / 2 + UI.WORLD_ANCHOR_OFFSET, 0),
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
    }, { panel })

    return {
        gui = gui,
        badge = badge,
        badgeLabel = badgeLabel,
        bar = bar,
        daysLabel = daysLabel,
        costLabel = costLabel,
    }
end

local function applyState(sign, moduleId)
    local moduleState = lastState and lastState.modules and lastState.modules[moduleId]
    local status = moduleState and moduleState.status or "locked"
    local style = STATUS_STYLE[status] or STATUS_STYLE.locked

    sign.badge.BackgroundColor3 = style.color
    sign.badgeLabel.Text = style.text
    -- 밝은 배지(노랑, 초록)는 어두운 글자, 어두운 배지는 흰 글자
    local darkText = status == "building" or status == "available"
    sign.badgeLabel.TextColor3 = if darkText then Colors.bg else Colors.text

    local building = status == "building"
    sign.bar.root.Visible = building
    sign.daysLabel.Visible = building
    if building then
        sign.bar.setRatio(moduleState.progress)
        sign.daysLabel.Text = string.format("%d일 남음", moduleState.daysLeft)
    end
    sign.costLabel.Visible = status == "available"
end

local function clearSigns()
    for _, sign in pairs(signs) do
        sign.gui:Destroy()
    end
    signs = {}
end

local function rebuild()
    clearSigns()
    local base = workspace:FindFirstChild("Base")
    local pads = base and base:FindFirstChild("ModulePads")
    if not pads then
        return
    end
    for _, padModel in ipairs(pads:GetChildren()) do
        local moduleId = padModel:GetAttribute("ModuleId")
        local pad = padModel:FindFirstChild("Pad")
        if moduleId and config.MODULES[moduleId] and pad and pad:IsA("BasePart") then
            local sign = makeSign(moduleId, pad)
            signs[moduleId] = sign
            applyState(sign, moduleId)
        end
    end
end

-- Base 복제 직후 하위가 모두 붙은 뒤 한 번만 다시 만든다
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
        if descendant.Name == "ModulePads" or descendant.Name == "Pad" then
            queueRebuild()
        end
    end)
end

function PadSignUI.init(ctx)
    config = ctx.Config

    workspace.ChildAdded:Connect(function(child)
        if child.Name == "Base" then
            watchBase(child)
            queueRebuild()
        end
    end)
    workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Base" then
            clearSigns()
        end
    end)

    local existing = workspace:FindFirstChild("Base")
    if existing then
        watchBase(existing)
    end
    rebuild()
end

function PadSignUI.update(state)
    lastState = state
    for moduleId, sign in pairs(signs) do
        applyState(sign, moduleId)
    end
end

return PadSignUI
