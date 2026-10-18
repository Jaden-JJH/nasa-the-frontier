--!nonstrict
-- 타이틀 화면. 시작 버튼은 로컬에서만 화면을 숨긴다.
-- 16차(2026-10-19): 오른쪽에 "명예의 전당" 패널(승리 기록 상위 RECORDS.showTop개, Records 수신 때 갱신).
-- compact(Layout.isCompact)에서는 패널을 시작 버튼 아래로 내려 제목과 겹치지 않게 한다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)
local Ranking = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Ranking"))
local Colors = UI.Colors

local TitleUI = {}

local PANEL_WIDTH = 340
local PANEL_MARGIN = 24
local CENTER_MAX_WIDTH = 700
local COMPACT_SIDE_GAP = 16

local gui
local onStart
local config
local root
local center
local centerList
local titleLabel
local subtitleLabel
local startButton
local panel
local panelLines = {}
local panelStatus
local latestRecords = nil

local function viewportSize()
    local camera = workspace.CurrentCamera
    local size = if camera then camera.ViewportSize else Vector2.new(1280, 720)
    if size.Y < 200 then
        return Vector2.new(1280, 720)
    end
    return size
end

-- 명예의 전당 글자 갱신
local function updatePanel()
    if not panel then
        return
    end
    local t = config.TEXTS
    local payload = latestRecords
    local entries = payload and payload.entries or {}
    local status = payload and payload.status or "loading"
    for i, label in ipairs(panelLines) do
        local entry = entries[i]
        if entry then
            label.Text = Ranking.formatLine(entry, i, config)
            label.TextColor3 = if i == 1 then Colors.energy else Colors.text
            label.Visible = true
        elseif i == 1 then
            label.Text = if status == "loading" then t.recordsLoading else t.recordsEmpty
            label.TextColor3 = Colors.textDim
            label.Visible = true
        else
            label.Visible = false
        end
    end
    panelStatus.Text = t.recordsOffline
    panelStatus.Visible = status == "offline"
end

-- 넓은 화면: 패널은 오른쪽, 제목 묶음은 남은 왼쪽 영역 가운데. compact: 패널을 제목 묶음 맨 아래로
local function applyLayout()
    if not root then
        return
    end
    local viewport = viewportSize()
    local compact = Layout.isCompact()
    if compact then
        local width = math.min(CENTER_MAX_WIDTH, viewport.X - COMPACT_SIDE_GAP * 2)
        center.AnchorPoint = Vector2.new(0.5, 0.5)
        center.Position = UDim2.fromScale(0.5, 0.5)
        center.Size = UDim2.fromOffset(width, 0)
        centerList.Padding = UDim.new(0, 8)
        titleLabel.TextSize = 44
        titleLabel.Size = UDim2.new(1, 0, 0, 50)
        subtitleLabel.TextSize = 16
        startButton.Size = UDim2.fromOffset(200, 46)
        panel.AnchorPoint = Vector2.new(0, 0)
        panel.Position = UDim2.fromOffset(0, 0)
        panel.Size = UDim2.fromOffset(math.min(440, width), 0)
        panel.LayoutOrder = 4
        panel.Parent = center
    else
        local regionWidth = viewport.X - PANEL_WIDTH - PANEL_MARGIN * 2
        local width = math.min(CENTER_MAX_WIDTH, regionWidth - PANEL_MARGIN)
        center.AnchorPoint = Vector2.new(0.5, 0.5)
        center.Position = UDim2.new(0, regionWidth / 2, 0.5, 0)
        center.Size = UDim2.fromOffset(width, 0)
        centerList.Padding = UDim.new(0, 18)
        titleLabel.TextSize = 72
        titleLabel.Size = UDim2.new(1, 0, 0, 84)
        subtitleLabel.TextSize = 22
        startButton.Size = UDim2.fromOffset(240, 56)
        panel.AnchorPoint = Vector2.new(1, 0.5)
        panel.Position = UDim2.new(1, -PANEL_MARGIN, 0.5, 0)
        panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
        panel.Parent = root
    end
end

function TitleUI.init(ctx)
    onStart = ctx.onStart
    config = ctx.Config
    gui = UI.gui("Title", 100)
    gui.Enabled = false

    startButton = UI.create("TextButton", {
        Name = "StartButton",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(240, 56),
        BackgroundColor3 = Colors.accent,
        Text = "시작",
        Preset = "heading",
        TextSize = 26,
    }, { UI.corner(10) })

    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 84),
        Text = "The Frontier",
        Preset = "title",
        TextSize = 72,
    })
    subtitleLabel = UI.create("TextLabel", {
        Name = "Subtitle",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "3개월 안에 거주, 식량, 연구 시설을 완성해 달 기지를 세우세요",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextSize = 22,
        TextWrapped = true,
    })
    centerList = UI.list(Enum.FillDirection.Vertical, 18, Enum.HorizontalAlignment.Center)
    center = UI.create("Frame", {
        Name = "Center",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(CENTER_MAX_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        centerList,
        titleLabel,
        subtitleLabel,
        startButton,
    })

    -- 명예의 전당 패널
    panel = UI.create("Frame", {
        Name = "HallOfFame",
        Size = UDim2.fromOffset(PANEL_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.1,
    }, {
        UI.corner(12),
        UI.stroke(Colors.energy, 1.5, 0.3),
        UI.padding(14),
        UI.list(Enum.FillDirection.Vertical, 6),
        UI.create("TextLabel", {
            Name = "PanelTitle",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 24),
            Text = config.TEXTS.recordsTitle,
            Font = UI.FontBold,
            TextSize = 20,
            TextColor3 = Colors.energy,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
    })
    panelLines = {}
    for i = 1, config.RECORDS.showTop do
        local line = UI.create("TextLabel", {
            Name = "Line" .. i,
            LayoutOrder = 1 + i,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Text = "",
            TextSize = 15,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = panel,
        })
        table.insert(panelLines, line)
    end
    panelStatus = UI.create("TextLabel", {
        Name = "Status",
        LayoutOrder = 2 + config.RECORDS.showTop,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        TextSize = 14,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
        Parent = panel,
    })

    root = UI.create("Frame", {
        Name = "Root",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Colors.bg,
        Parent = gui,
    }, {
        UI.create("UIGradient", {
            Color = ColorSequence.new(Color3.fromRGB(14, 20, 44), Color3.fromRGB(4, 6, 14)),
            Rotation = 90,
        }),
        center,
    })

    startButton.Activated:Connect(function()
        if onStart then
            onStart()
        end
    end)

    applyLayout()
    updatePanel()
    Layout.changed:Connect(applyLayout)
    local camera = workspace.CurrentCamera
    if camera then
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
    end
end

-- Records 수신 (입장 시, 로드 완료, 새 기록 반영 뒤)
function TitleUI.setRecords(payload)
    if type(payload) ~= "table" or type(payload.entries) ~= "table" then
        return
    end
    latestRecords = payload
    updatePanel()
end

function TitleUI.setVisible(visible)
    gui.Enabled = visible
    if visible then
        applyLayout()
    end
end

return TitleUI
