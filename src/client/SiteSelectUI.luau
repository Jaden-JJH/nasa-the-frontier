--!nonstrict
-- 착륙지 선택 화면. 카드 4장, 권한자만 버튼 활성, 남은 시간 표시.

local Players = game:GetService("Players")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local SiteSelectUI = {}

local gui
local selectRemote
local chooserLabel
local countdownLabel
local cardsFrame
local MIN_HEIGHT_FOR_FULL_SCALE = 600
local CONTENT_HEIGHT = 520 -- 헤더와 카드 포함 대략 높이
local MIN_SCALE = 0.6
local contentScale
local contentFrame

local currentInfo = nil
local canChoose = false
local chosenId = nil
local cards = {} -- { [siteId] = { frame, button } }

local HAZARD_COLORS = {
    ["낮음"] = Colors.good,
    ["중간"] = Colors.energy,
    ["높음"] = Colors.bad,
}

local function infoLine(text, order)
    return UI.create("TextLabel", {
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 22),
        Text = text,
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextXAlignment = Enum.TextXAlignment.Left,
    })
end

-- 버튼 문구와 활성 상태를 현재 상황에 맞춰 갱신
local function refreshButtons()
    for siteId, card in pairs(cards) do
        local button = card.button
        local enabled = canChoose and chosenId == nil
        button.Active = enabled
        button.AutoButtonColor = enabled
        button.BackgroundColor3 = enabled and Colors.accent or Colors.disabled
        if chosenId == siteId then
            button.Text = "선택됨"
        elseif canChoose and chosenId == nil then
            button.Text = "여기에 착륙"
        else
            button.Text = "대기 중"
        end
    end
end

local function clearCards()
    for _, card in pairs(cards) do
        card.frame:Destroy()
    end
    cards = {}
end

local function buildCard(site, isDefault)
    local sunPercent = math.floor(site.sunlight * 100 + 0.5)
    local bar = UI.progressBar(Colors.energy, 8)
    bar.setRatio(site.sunlight)
    bar.root.LayoutOrder = 3

    local button = UI.create("TextButton", {
        Name = "SelectButton",
        LayoutOrder = 7,
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = Colors.disabled,
        Text = "대기 중",
        Preset = "heading",
    }, { UI.corner(8) })

    local frame = UI.create("Frame", {
        Name = "Card" .. site.id,
        LayoutOrder = site.id,
        BackgroundColor3 = Colors.panel,
        Parent = cardsFrame,
    }, {
        UI.corner(12),
        UI.stroke(isDefault and Colors.accent or Colors.panelLight, 2),
        UI.padding(14),
        UI.list(Enum.FillDirection.Vertical, 8),
        UI.create("TextLabel", {
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 28),
            Text = isDefault and (site.name .. " (기본)") or site.name,
            Preset = "heading",
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }),
        UI.create("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.new(1, 0, 0, 22),
            Text = "일조율 " .. sunPercent .. "%",
            TextColor3 = Colors.energy,
            Preset = "body",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        bar.root,
        infoLine("얼음 거리: " .. site.iceDistanceLabel, 4),
        UI.create("TextLabel", {
            LayoutOrder = 5,
            Size = UDim2.new(1, 0, 0, 22),
            Text = "지형 위험: " .. site.hazardLabel,
            TextColor3 = HAZARD_COLORS[site.hazardLabel] or Colors.textDim,
            Preset = "body",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        UI.create("TextLabel", {
            LayoutOrder = 6,
            Size = UDim2.new(1, 0, 0, 72),
            Text = site.description,
            TextColor3 = Colors.text,
            Preset = "caption",
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
        }),
        button,
    })

    button.Activated:Connect(function()
        if not canChoose or chosenId ~= nil then
            return
        end
        chosenId = site.id
        selectRemote:FireServer(site.id)
        refreshButtons()
    end)

    cards[site.id] = { frame = frame, button = button }
end

local function updateCountdown()
    if not currentInfo then
        return
    end
    local remaining =
        math.max(0, math.ceil(currentInfo.deadlineUnix - workspace:GetServerTimeNow()))
    countdownLabel.Text = string.format("자동 선택까지 %d초", remaining)
end

local function applyScale()
    local camera = workspace.CurrentCamera
    local height = camera and camera.ViewportSize.Y or 720
    local scale = 1
    if height < MIN_HEIGHT_FOR_FULL_SCALE then
        scale = math.clamp(height / CONTENT_HEIGHT, MIN_SCALE, 1)
    end
    contentScale.Scale = scale
    -- UIScale이 폭도 줄이므로 보정해서 화면 폭의 94%를 유지
    contentFrame.Size = UDim2.fromScale(0.94 / scale, 0)
end

function SiteSelectUI.init(ctx)
    selectRemote = ctx.remotes.SelectSite
    gui = UI.gui("SiteSelect", 50)
    gui.Enabled = false

    contentScale = UI.create("UIScale")
    chooserLabel = UI.create("TextLabel", {
        Name = "Chooser",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 26),
        Text = "",
        Preset = "body",
        TextColor3 = Colors.water,
    })
    countdownLabel = UI.create("TextLabel", {
        Name = "Countdown",
        LayoutOrder = 3,
        Size = UDim2.new(1, 0, 0, 26),
        Text = "",
        Preset = "body",
        TextColor3 = Colors.textDim,
    })
    cardsFrame = UI.create("Frame", {
        Name = "Cards",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 330),
        BackgroundTransparency = 1,
    }, {
        UI.create("UIGridLayout", {
            CellSize = UDim2.fromScale(0.24, 1),
            CellPadding = UDim2.fromScale(0.0133, 0),
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })

    contentFrame = UI.create("Frame", {
        Name = "Content",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(0.94, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        contentScale,
        UI.list(Enum.FillDirection.Vertical, 14),
        UI.create("TextLabel", {
            Name = "Header",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 44),
            Text = "착륙지 선택",
            Preset = "title",
        }),
        chooserLabel,
        countdownLabel,
        cardsFrame,
    })
    UI.create("Frame", {
        Name = "Root",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Colors.bg,
        Parent = gui,
    }, { contentFrame })

    -- 낮은 뷰포트(모바일 가로)에서는 전체를 축소해 버튼이 항상 보이게 한다
    local camera = workspace.CurrentCamera
    if camera then
        applyScale()
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
    end

    -- 남은 시간 갱신 (화면이 보일 때만)
    task.spawn(function()
        while true do
            task.wait(0.25)
            if gui.Enabled then
                updateCountdown()
            end
        end
    end)
end

-- SiteSelectionOpen 수신 시 호출. 카드를 새로 만든다.
function SiteSelectUI.open(info)
    currentInfo = info
    chosenId = nil
    canChoose = Players.LocalPlayer.UserId == info.chooserUserId

    clearCards()
    for _, site in ipairs(info.sites) do
        buildCard(site, site.id == info.defaultSiteId)
    end

    if canChoose then
        chooserLabel.Text = "착륙지를 선택하세요"
    else
        chooserLabel.Text = "선택 중: " .. info.chooserName
    end
    refreshButtons()
    updateCountdown()
end

function SiteSelectUI.setVisible(visible)
    gui.Enabled = visible
end

return SiteSelectUI
