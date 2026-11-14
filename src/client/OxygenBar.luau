--!nonstrict
-- 산소 바 (v2, 하단 중앙). OxygenUpdate(oxygen, max, zone)의 zone: "outside" | "shelter" | "refill" (CONTRACT_V2 4.1).
-- 실내(shelter, refill)이면 흐리게 하고 태그를 단다. 밖에서 경고 수치 이하이면 깜빡이고 "들어가요" 안내를 띄운다.

local TweenService = game:GetService("TweenService")

local ClientMath =
    require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ClientMath"))
local Icons = require(script.Parent.Icons)
local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local L = UI.Luna

local OxygenBar = {}

local WARN_BELOW = 20 -- 화면 경고 기준 (Config에 없는 표시용 상수, v1과 같음)
local WIDTH = 340
local HEIGHT = 30
local BOTTOM = 18

local ZONE_TAGS = { shelter = "hud.oxygen.shelter", refill = "hud.oxygen.refill" }

local gui
local group
local fill
local label
local tag
local tagLabel
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
        BackgroundColor3 = Icons.COLORS.oxygen,
    })
    label = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromScale(1, 1),
        FontFace = UI.RoundHeavy,
        TextSize = 16,
        TextColor3 = L.white,
        ZIndex = 2,
    }, { UI.worldStroke() })
    local icon = Icons.resource("oxygen", 18, L.white)
    icon.AnchorPoint = Vector2.new(0, 0.5)
    icon.Position = UDim2.new(0, 8, 0.5, 0)
    icon.ZIndex = 3
    group = UI.create("CanvasGroup", {
        Name = "Bar",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -BOTTOM),
        Size = UDim2.fromOffset(WIDTH, HEIGHT),
        BackgroundColor3 = L.bgTop,
        Parent = oxygenRoot,
    }, { UI.roundCorner(), fill, label, icon })
    tagLabel = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromOffset(0, 22),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 13,
        TextColor3 = L.inkDeep,
    })
    tag = UI.create("Frame", {
        Name = "ZoneTag",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(0.5, WIDTH / 2, 1, -(BOTTOM + HEIGHT + 6)),
        Size = UDim2.fromOffset(0, 22),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.mint,
        Visible = false,
        Parent = oxygenRoot,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }), tagLabel })
    hintLabel = UI.create("TextLabel", {
        Name = "Hint",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -(BOTTOM + HEIGHT + 6)),
        Size = UDim2.fromOffset(520, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = 16,
        TextWrapped = true,
        TextColor3 = L.orange,
        Visible = false,
        Parent = oxygenRoot,
    }, { UI.worldStroke() })
    UI.msg(hintLabel, "toast.oxygen.low")
end

-- zone: "outside" | "shelter" | "refill" (v1 호환으로 boolean이면 true = 실내)
function OxygenBar.update(oxygen, max, zone)
    if type(zone) == "boolean" then
        zone = if zone then "shelter" else "outside"
    end
    local inside = zone == "shelter" or zone == "refill"
    fill.Size = UDim2.fromScale(ClientMath.ratio(oxygen, max), 1)
    UI.msg(label, { key = "hud.oxygen.value", args = { n = ClientMath.wholeNumber(oxygen) } })
    local tagKey = ZONE_TAGS[zone]
    tag.Visible = tagKey ~= nil
    if tagKey then
        UI.msg(tagLabel, tagKey)
        tag.BackgroundColor3 = if zone == "refill" then L.mint else L.sky
    end
    local low = type(oxygen) == "number" and oxygen <= WARN_BELOW
    hintLabel.Visible = not inside and low
    group.GroupTransparency = if inside then 0.45 else 0
    setFlashing(low and not inside)
end

function OxygenBar.setVisible(visible)
    gui.Enabled = visible
end

return OxygenBar
