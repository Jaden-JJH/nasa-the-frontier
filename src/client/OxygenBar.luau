--!nonstrict
-- 산소 바 (하단 중앙). 실내이면 흐리게, 경고 수치 아래이면 깜빡인다.

local TweenService = game:GetService("TweenService")

local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local Colors = UI.Colors

local OxygenBar = {}

local WARN_BELOW = 20 -- UI 경고 기준 (Config에 없는 표시용 상수)

local gui
local group
local fill
local label
local insideTag
local hintLabel
local flashTween = nil

local function setFlashing(flashing)
    if flashing then
        if flashTween then
            return
        end
        flashTween = TweenService:Create(
            fill,
            TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
            { BackgroundTransparency = 0.8 }
        )
        flashTween:Play()
    elseif flashTween then
        flashTween:Cancel()
        flashTween = nil
        fill.BackgroundTransparency = 0
    end
end

function OxygenBar.init(_ctx)
    gui = UI.gui("Oxygen", 11)
    local oxygenRoot = Layout.root(gui)
    gui.Enabled = false

    fill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Colors.oxygen,
    })
    label = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromScale(1, 1),
        Text = "산소 0",
        Preset = "badge",
        ZIndex = 2,
    })
    group = UI.create("CanvasGroup", {
        Name = "Bar",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -18),
        Size = UDim2.fromOffset(340, 30),
        BackgroundColor3 = Colors.panel,
        Parent = oxygenRoot,
    }, { UI.corner(8), fill, label })
    insideTag = UI.create("TextLabel", {
        Name = "InsideTag",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(0.5, 170, 1, -54),
        Size = UDim2.fromOffset(68, 22),
        BackgroundTransparency = 0,
        BackgroundColor3 = Colors.good, -- 하늘색은 물 전용이라 안전(초록)으로 구분
        TextColor3 = Colors.bg,
        Text = "에어락",
        Preset = "badge",
        Visible = false,
        Parent = oxygenRoot,
    }, { UI.corner(6) })
    hintLabel = UI.create("TextLabel", {
        Name = "AirlockHint",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.fromScale(0.5, 1),
        Size = UDim2.fromOffset(480, 18),
        Preset = "caption",
        TextWrapped = true,
        Text = "가까운 에어락 문을 E로 열고 안으로 들어가세요",
        TextColor3 = Colors.oxygen,
        Visible = false,
        Parent = oxygenRoot,
    })
end

function OxygenBar.update(oxygen, max, inside)
    local ratio = if max > 0 then math.clamp(oxygen / max, 0, 1) else 0
    fill.Size = UDim2.fromScale(ratio, 1)
    label.Text = string.format("산소 %d", math.floor(oxygen + 0.5))
    insideTag.Visible = inside
    hintLabel.Visible = not inside and oxygen <= WARN_BELOW
    group.GroupTransparency = if inside then 0.5 else 0
    setFlashing(oxygen <= WARN_BELOW)
end

function OxygenBar.setVisible(visible)
    gui.Enabled = visible
end

return OxygenBar
