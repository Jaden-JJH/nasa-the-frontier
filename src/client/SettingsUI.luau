--!nonstrict
-- 우측 하단 표시 설정 (v2). 체크박스 2개(Tip, 사실 카드)와 EN | KR 언어 토글(I18N_PLAN 1절: 게임 안 전환)을 한 줄로 둔다.
-- 끄면 TipUI, FactUI가 지금 카드를 접고 새 카드를 띄우지 않는다(큐와 본 기록은 유지). 값은 세션 메모리에만 둔다.
-- 플레이 중에만 보인다(Main.client가 setVisible).
-- PC: 오른쪽 16, 아래 12(가상 좌표). compact: 오른쪽 12px, 아래 190px(실제 px, 점프 버튼 위).
-- Tip 카드는 이 패널 위에 뜬다(TipUI의 아래 여백 상수: PC 56, compact 230).

local FactUI = require(script.Parent.FactUI)
local LanguageToggle = require(script.Parent.LanguageToggle)
local Layout = require(script.Parent.Layout)
local TipUI = require(script.Parent.TipUI)
local UI = require(script.Parent.UI)
local L = UI.Luna

local SettingsUI = {}

local PANEL_HEIGHT = 36
local BOX_SIZE = 18
local LABEL_SIZE = 15
local PC_RIGHT = 16
local PC_BOTTOM = 12
local COMPACT_RIGHT = 12 -- 실제 px
local COMPACT_BOTTOM = 190 -- 실제 px. 부스터 버튼(하단 110~174)과 점프 버튼 위

local ROWS = {
    { id = "tip", labelKey = "settings.show_tips", apply = TipUI.setEnabled },
    { id = "fact", labelKey = "settings.show_facts", apply = FactUI.setEnabled },
}

local gui
local panel
local enabled = { tip = true, fact = true }
local boxes = {} -- { [id] = { box, mark } }

local function refreshBox(id)
    local parts = boxes[id]
    if not parts then
        return
    end
    local on = enabled[id]
    parts.box.BackgroundTransparency = if on then 0 else 1
    parts.mark.Visible = on
end

local function applyPosition()
    if not panel then
        return
    end
    if Layout.isCompact() then
        local scale = Layout.scale()
        panel.Position = UDim2.new(1, -COMPACT_RIGHT / scale, 1, -COMPACT_BOTTOM / scale)
    else
        panel.Position = UDim2.new(1, -PC_RIGHT, 1, -PC_BOTTOM)
    end
end

local function makeRow(index, row)
    local mark = UI.checkMark(L.ink, {
        Name = "Mark",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
    })
    local box = UI.create("Frame", {
        Name = "Box",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(BOX_SIZE, BOX_SIZE),
        BackgroundColor3 = L.mint,
    }, {
        UI.corner(5),
        UI.stroke(L.mint, 1.5),
        mark,
    })
    boxes[row.id] = { box = box, mark = mark }
    refreshBox(row.id)

    local holder = UI.create("Frame", {
        Name = "BoxHolder",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(BOX_SIZE, PANEL_HEIGHT),
        BackgroundTransparency = 1,
    }, { box })
    local label = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, PANEL_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextColor3 = L.white,
        TextSize = LABEL_SIZE,
    })
    UI.msg(label, row.labelKey)

    local button = UI.create("TextButton", {
        Name = "Toggle_" .. row.id,
        LayoutOrder = index,
        Size = UDim2.fromOffset(0, PANEL_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        holder,
        label,
    })

    button.Activated:Connect(function()
        enabled[row.id] = not enabled[row.id]
        refreshBox(row.id)
        row.apply(enabled[row.id])
    end)
    return button
end

function SettingsUI.init(_ctx)
    gui = UI.gui("Settings", 15)
    gui.Enabled = false
    local root = Layout.root(gui)

    panel = UI.lunaPanel({
        Name = "Panel",
        AnchorPoint = Vector2.new(1, 1),
        Size = UDim2.fromOffset(0, PANEL_HEIGHT + 8),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.3,
        Parent = root,
    }, {
        UI.padding({ 4, 4, 12, 8 }),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 14),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
    }, 18)
    for index, row in ipairs(ROWS) do
        makeRow(index, row).Parent = panel
    end
    local toggle = LanguageToggle.create(panel)
    toggle.LayoutOrder = #ROWS + 1

    applyPosition()
    Layout.changed:Connect(applyPosition)
end

function SettingsUI.setVisible(visible)
    if gui then
        gui.Enabled = visible
    end
end

-- 현재 설정 (true = 표시)
function SettingsUI.isEnabled(id)
    return enabled[id] == true
end

return SettingsUI
