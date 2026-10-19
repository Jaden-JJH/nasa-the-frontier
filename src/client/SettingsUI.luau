--!nonstrict
-- 우측 하단 표시 설정 (17차, 사용자 지시). Tip 카드 바로 아래에 체크박스 2개를 한 줄로 둔다:
-- "Tip 표시", "알고 있나요? 표시". 끄면 TipUI, FactUI가 지금 카드를 접고 새 카드를 띄우지 않는다(큐와 본 기록은 유지).
-- 값은 클라이언트 세션 메모리에만 둔다(재시작해도 유지, 재접속하면 켜짐). 플레이 중에만 보인다(Main.client가 setVisible).
-- PC: 오른쪽 16, 아래 12(가상 좌표, Layout 배율을 따른다). compact: 오른쪽 12px, 아래 190px(실제 px, 점프 버튼 위).
-- Tip 카드는 이 패널 위에 뜬다(TipUI의 아래 여백 상수: PC 56, compact 230).

local FactUI = require(script.Parent.FactUI)
local Layout = require(script.Parent.Layout)
local TipUI = require(script.Parent.TipUI)
local UI = require(script.Parent.UI)
local Colors = UI.Colors

local SettingsUI = {}

local PANEL_HEIGHT = 32
local BOX_SIZE = 18
local BOX_STROKE = 1.5
local LABEL_SIZE = 15
local PC_RIGHT = 16
local PC_BOTTOM = 12
local COMPACT_RIGHT = 12 -- 실제 px
local COMPACT_BOTTOM = 190 -- 실제 px. 부스터 버튼(하단 110~174)과 점프 버튼 위

local ROWS = {
    { id = "tip", label = "Tip 표시", apply = TipUI.setEnabled },
    { id = "fact", label = "알고 있나요? 표시", apply = FactUI.setEnabled },
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
    local mark = UI.create("TextLabel", {
        Name = "Mark",
        Size = UDim2.fromScale(1, 1),
        Text = "v",
        TextColor3 = Colors.text,
        Font = UI.FontBold,
        TextSize = 15,
    })
    local box = UI.create("Frame", {
        Name = "Box",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(BOX_SIZE, BOX_SIZE),
        BackgroundColor3 = Colors.accent,
    }, {
        UI.corner(4),
        UI.stroke(Colors.text, BOX_STROKE),
        mark,
    })
    boxes[row.id] = { box = box, mark = mark }
    refreshBox(row.id)

    -- 가로 목록은 위에 붙으므로 체크박스는 높이 32 칸 안에서 세로 가운데에 둔다
    local holder = UI.create("Frame", {
        Name = "BoxHolder",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(BOX_SIZE, PANEL_HEIGHT),
        BackgroundTransparency = 1,
    }, { box })

    local button = UI.create("TextButton", {
        Name = "Toggle_" .. row.id,
        LayoutOrder = index,
        Size = UDim2.fromOffset(0, PANEL_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, {
        UI.list(Enum.FillDirection.Horizontal, 6),
        holder,
        UI.create("TextLabel", {
            Name = "Label",
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, PANEL_HEIGHT),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = row.label,
            TextColor3 = Colors.text,
            TextSize = LABEL_SIZE,
        }),
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

    panel = UI.create("Frame", {
        Name = "Panel",
        AnchorPoint = Vector2.new(1, 1),
        Size = UDim2.fromOffset(0, PANEL_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.35,
        Parent = root,
    }, {
        UI.corner(8),
        UI.padding({ 0, 0, 10, 10 }),
        UI.list(Enum.FillDirection.Horizontal, 14),
    })
    for index, row in ipairs(ROWS) do
        makeRow(index, row).Parent = panel
    end

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
