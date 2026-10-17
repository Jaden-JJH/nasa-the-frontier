--!nonstrict
-- 게임 중 HUD. StateUpdate 한 번에 모든 표시를 갱신한다.
-- 배치(1280x720 기준): 좌상단 자원, 상단 중앙 Day와 미션, 우상단 패널과 로버,
-- 우측 모듈 3개(y=300부터, 토스트 영역 아래), 우하단 속도 버튼.

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local HUD = {}

local config
local setSpeedRemote
local gui
local refs = {}
local currentSpeed = 1

local STATUS_TEXT = {
    locked = "잠김",
    available = "건설 가능",
    active = "가동 중",
}

local function roundInt(value)
    return math.floor(value + 0.5)
end

-- 자원 한 줄: 색 사각형, 이름, 값, 하루 순증감
local function makeResourceRow(parent, order, name, color)
    local value = UI.create("TextLabel", {
        Name = "Value",
        Position = UDim2.fromOffset(92, 0),
        Size = UDim2.new(0, 54, 1, 0),
        Text = "0",
        Preset = "heading",
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    local net = UI.create("TextLabel", {
        Name = "Net",
        Position = UDim2.fromOffset(150, 0),
        Size = UDim2.new(1, -150, 1, 0),
        Text = "0/일",
        TextColor3 = Colors.neutral,
        Preset = "caption",
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    UI.create("Frame", {
        Name = name .. "Row",
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        Parent = parent,
    }, {
        UI.create("Frame", {
            Name = "Swatch",
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.fromScale(0, 0.5),
            Size = UDim2.fromOffset(14, 14),
            BackgroundColor3 = color,
        }, { UI.corner(3) }),
        UI.create("TextLabel", {
            Name = "Label",
            Position = UDim2.fromOffset(22, 0),
            Size = UDim2.new(0, 66, 1, 0),
            Text = name,
            Preset = "body",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        value,
        net,
    })
    return { value = value, net = net }
end

local function setNet(label, net)
    local n = roundInt(net or 0)
    if n > 0 then
        label.Text = string.format("+%d/일", n)
        label.TextColor3 = Colors.good
    elseif n < 0 then
        label.Text = string.format("%d/일", n)
        label.TextColor3 = Colors.bad
    else
        label.Text = "0/일"
        label.TextColor3 = Colors.neutral
    end
end

-- 라벨과 값이 좌우로 나뉘는 한 줄
local function makeInfoRow(parent, order, labelText)
    local value = UI.create("TextLabel", {
        Name = "Value",
        Position = UDim2.fromScale(0.38, 0),
        Size = UDim2.fromScale(0.62, 1),
        Text = "-",
        Preset = "badge",
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    UI.create("Frame", {
        Name = labelText,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Parent = parent,
    }, {
        UI.create("TextLabel", {
            Position = UDim2.fromScale(0, 0),
            Size = UDim2.fromScale(0.38, 1),
            Text = labelText,
            TextColor3 = Colors.textDim,
            Preset = "caption",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        value,
    })
    return value
end

local function makeModuleRow(parent, order, moduleId)
    local title = config.MODULES[moduleId].name
    local status = UI.create("TextLabel", {
        Name = "Status",
        Position = UDim2.fromOffset(0, 22),
        Size = UDim2.new(1, 0, 0, 18),
        Text = "잠김",
        TextColor3 = Colors.neutral,
        Preset = "caption",
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local bar = UI.progressBar(Colors.energy, 6)
    bar.root.Position = UDim2.fromOffset(0, 44)
    bar.root.Visible = false
    UI.create("Frame", {
        Name = "Module" .. moduleId,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundTransparency = 1,
        Parent = parent,
    }, {
        UI.create("TextLabel", {
            Name = "Title",
            Size = UDim2.new(1, 0, 0, 22),
            Text = moduleId .. " " .. title,
            Preset = "badge",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        status,
        bar.root,
    })
    return { status = status, bar = bar }
end

function HUD.init(ctx)
    config = ctx.Config
    setSpeedRemote = ctx.remotes.SetSpeed
    gui = UI.gui("HUD", 10, false)
    gui.Enabled = false

    -- 좌상단: 자원
    local resources = UI.create("Frame", {
        Name = "Resources",
        Position = UDim2.fromOffset(12, 12),
        Size = UDim2.fromOffset(236, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
        Parent = gui,
    }, { UI.corner(10), UI.padding(10), UI.list(Enum.FillDirection.Vertical, 4) })
    refs.energy = makeResourceRow(resources, 1, "Energy", Colors.energy)
    refs.water = makeResourceRow(resources, 2, "Water", Colors.water)
    refs.food = makeResourceRow(resources, 3, "Food", Colors.food)

    -- 상단 중앙: 부족 경고 배너, Day, 미션 텍스트
    refs.bannerText = UI.create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Text = "",
        Preset = "heading",
    })
    refs.banner = UI.create("Frame", {
        Name = "ShortageBanner",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Colors.bad,
        Visible = false,
    }, { UI.corner(8), refs.bannerText })
    refs.day = UI.create("TextLabel", {
        Name = "Day",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 32),
        Text = "Day 0 / " .. config.TOTAL_DAYS,
        Preset = "heading",
        TextSize = 28,
    })
    refs.mission = UI.create("TextLabel", {
        Name = "Mission",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextWrapped = true,
    })
    UI.create("Frame", {
        Name = "TopCenter",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 10),
        Size = UDim2.fromOffset(460, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = gui,
    }, {
        UI.list(Enum.FillDirection.Vertical, 6),
        refs.banner,
        UI.create("Frame", {
            Name = "DayPanel",
            LayoutOrder = 2,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Colors.panel,
            BackgroundTransparency = 0.12,
        }, {
            UI.corner(10),
            UI.padding({ 6, 8, 12, 12 }),
            UI.list(Enum.FillDirection.Vertical, 2),
            refs.day,
            refs.mission,
        }),
    })

    -- 우상단: 패널과 로버 탱크
    local topRight = UI.create("Frame", {
        Name = "TopRight",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 12),
        Size = UDim2.fromOffset(260, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
        Parent = gui,
    }, { UI.corner(10), UI.padding(10), UI.list(Enum.FillDirection.Vertical, 2) })
    refs.panels = makeInfoRow(topRight, 1, "패널")
    refs.tank = makeInfoRow(topRight, 2, "로버 탱크")

    -- 우측: 모듈 3개 (y=300, 토스트 영역을 피한다)
    local modulesPanel = UI.create("Frame", {
        Name = "Modules",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 300),
        Size = UDim2.fromOffset(260, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
        Parent = gui,
    }, { UI.corner(10), UI.padding(10), UI.list(Enum.FillDirection.Vertical, 6) })
    refs.modules = {}
    for index, moduleId in ipairs(config.MODULE_ORDER) do
        refs.modules[moduleId] = makeModuleRow(modulesPanel, index, moduleId)
    end

    -- 우하단: 속도 토글
    refs.speed = UI.create("TextButton", {
        Name = "SpeedButton",
        -- 모바일은 상단 중앙 Day 패널(폭 460) 오른쪽 옆, PC는 우하단
        AnchorPoint = if UI.isTouchOnly() then Vector2.new(0, 0) else Vector2.new(1, 1),
        Position = if UI.isTouchOnly()
            then UDim2.new(0.5, 238, 0, 10)
            else UDim2.new(1, -12, 1, -12),
        Size = UDim2.fromOffset(72, 44),
        BackgroundColor3 = Colors.panelLight,
        Text = "1x",
        Preset = "heading",
        Parent = gui,
    }, { UI.corner(10), UI.stroke(Colors.accent, 1) })
    refs.speed.Activated:Connect(function()
        local speeds = config.SPEEDS
        local nextSpeed = speeds[1]
        for index, speed in ipairs(speeds) do
            if speed == currentSpeed then
                nextSpeed = speeds[index % #speeds + 1]
                break
            end
        end
        setSpeedRemote:FireServer(nextSpeed)
    end)
end

local function updateModule(row, moduleState)
    local status = moduleState.status
    if status == "building" then
        row.status.Text = string.format("건설 중 %d일 남음", moduleState.daysLeft)
        row.status.TextColor3 = Colors.energy
        row.bar.root.Visible = true
        row.bar.setRatio(moduleState.progress)
    else
        row.status.Text = STATUS_TEXT[status] or ""
        if status == "active" or status == "available" then
            row.status.TextColor3 = Colors.good
        else
            row.status.TextColor3 = Colors.neutral
        end
        row.bar.root.Visible = false
    end
end

function HUD.update(state)
    refs.energy.value.Text = tostring(math.floor(state.energy))
    refs.water.value.Text = tostring(math.floor(state.water))
    refs.food.value.Text = tostring(math.floor(state.food))
    setNet(refs.energy.net, state.netEnergy)
    setNet(refs.water.net, state.netWater)
    setNet(refs.food.net, state.netFood)

    refs.day.Text = string.format("Day %d / %d", state.day, state.totalDays)
    refs.mission.Text = state.missionText or ""

    refs.panels.Text = string.format(
        "%d/%d (오늘 %d/%d)",
        state.panelsInstalled,
        state.panelsTotal,
        state.panelsInstalledToday,
        state.panelsPerDay
    )
    refs.tank.Text =
        string.format("%d/%d", roundInt(state.rover.tank), roundInt(state.rover.tankMax))

    for moduleId, row in pairs(refs.modules) do
        local moduleState = state.modules[moduleId]
        if moduleState then
            updateModule(row, moduleState)
        end
    end

    currentSpeed = state.speed
    refs.speed.Text = string.format("%dx", state.speed)

    if state.shortageDays > 0 then
        refs.banner.Visible = true
        refs.bannerText.Text = string.format(
            "자원 부족 %d일째. %d일이면 임무 실패",
            state.shortageDays,
            config.SHORTAGE_DAYS_TO_LOSE
        )
    else
        refs.banner.Visible = false
    end
end

function HUD.setVisible(visible)
    gui.Enabled = visible
end

return HUD
