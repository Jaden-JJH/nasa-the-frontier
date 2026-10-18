--!nonstrict
-- 게임 중 HUD. StateUpdate 한 번에 모든 표시를 갱신한다.
-- 배치(1280x720 기준): 좌상단 자원, 상단 중앙 Day와 미션, 우상단 패널과 로버,
-- 우측 모듈 3개(y=300부터, 토스트 영역 아래), 우하단 속도 버튼.

local TweenService = game:GetService("TweenService")

local Layout = require(script.Parent.Layout)
local RoverBoost = require(script.Parent.RoverBoost)
local UI = require(script.Parent.UI)
local Colors = UI.Colors

local HUD = {}

local config
local setSpeedRemote
local gui
local hudRoot
local refs = {}
local currentSpeed = 1
local batteryTweens = nil
local batteryMode = nil -- "low" | "charging" | nil
local boostOverheated = false -- 과열 이후 쿨다운 중
local lastRover = nil
local boostPulse = nil -- 부스트 중 게이지 밝기 맥동 Tween
local boostFlashUntil = 0
local updateBoost -- 앞서 선언(쿨다운 반짝임이 다시 호출)
local BOOST_COLOR = Color3.fromRGB(255, 150, 50)
local BOOST_DIM = Color3.fromRGB(170, 100, 40)

local STATUS_CHIP = { locked = "잠김", available = "가능", active = "가동" }

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
        Position = UDim2.fromOffset(88, 0),
        Size = UDim2.new(0, 100, 1, 0),
        Text = "0",
        Preset = "heading",
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    local net = UI.create("TextLabel", {
        Name = "Net",
        Position = UDim2.fromOffset(250, 0),
        Size = UDim2.new(1, -250, 1, 0),
        Text = "0/일",
        TextColor3 = Colors.neutral,
        Preset = "caption",
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    local days = UI.create("TextLabel", {
        Name = "DaysLeft",
        Position = UDim2.fromOffset(194, 0),
        Size = UDim2.new(0, 52, 1, 0),
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "caption",
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
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
        days,
        net,
    })
    return { value = value, net = net, days = days }
end

-- 남은 일수 표시 (nil이거나 999 이상이면 숨김, 3일 이하는 빨강)
local function setDaysLeft(label, days)
    if type(days) ~= "number" or days >= 999 then
        label.Visible = false
        return
    end
    local n = math.max(0, math.floor(days))
    label.Visible = true
    label.Text = string.format("%d일분", n)
    label.TextColor3 = if n <= 3 then Colors.bad else Colors.textDim
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
    hudRoot = Layout.root(gui)

    -- 좌측 열: 자원 패널 아래에 모듈 패널 (PC)
    local leftColumn = UI.create("Frame", {
        Name = "LeftColumn",
        Position = UDim2.fromOffset(12, 12),
        Size = UDim2.fromOffset(330, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = hudRoot,
    }, { UI.list(Enum.FillDirection.Vertical, 8) })

    -- 자원
    local resources = UI.create("Frame", {
        Name = "Resources",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
        Parent = leftColumn,
    }, { UI.corner(10), UI.padding(10), UI.list(Enum.FillDirection.Vertical, 4) })
    refs.resources = resources
    refs.energy = makeResourceRow(resources, 1, "Energy", Colors.energy)
    refs.water = makeResourceRow(resources, 2, "Water", Colors.water)
    refs.food = makeResourceRow(resources, 3, "Food", Colors.food)

    -- 상단 중앙: 부족 경고 배너, Day, 미션 텍스트
    refs.bannerText = UI.create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Text = "",
        Preset = "heading",
        TextWrapped = true,
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
    refs.site = UI.create("TextLabel", {
        Name = "SiteName",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 18),
        Preset = "caption",
        Text = "",
        TextColor3 = Colors.textDim,
        Visible = false,
    })
    refs.mission = UI.create("TextLabel", {
        Name = "Mission",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextWrapped = true,
    })
    local topCenter = UI.create("Frame", {
        Name = "TopCenter",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 10),
        Size = UDim2.fromOffset(460, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = hudRoot,
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
            refs.site,
            refs.mission,
        }),
    })

    -- 우측 열: 패널, 로버, 배터리, 부스트 (배속 버튼이 있으면 그 아래)
    local rightColumn = UI.create("Frame", {
        Name = "RightColumn",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 12),
        Size = UDim2.fromOffset(260, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = hudRoot,
    }, { UI.list(Enum.FillDirection.Vertical, 8) })
    refs.rightColumn = rightColumn
    refs.topCenter = topCenter
    local topRight = UI.create("Frame", {
        Name = "TopRight",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
        Parent = rightColumn,
    }, { UI.corner(10), UI.padding(10), UI.list(Enum.FillDirection.Vertical, 2) })
    refs.panels = makeInfoRow(topRight, 1, "패널")
    refs.tank = makeInfoRow(topRight, 2, "로버 탱크")
    refs.batteryText = makeInfoRow(topRight, 3, "배터리")
    refs.batteryBar = UI.progressBar(Colors.energy, 8)
    refs.batteryBar.root.AnchorPoint = Vector2.new(0, 0.5)
    refs.batteryBar.root.Position = UDim2.fromScale(0, 0.5)
    refs.batteryBar.root.Size = UDim2.new(1, -78, 0, 8)
    refs.batteryBadgeText = UI.create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Text = "",
        TextColor3 = Colors.bg,
        Preset = "badge",
        TextSize = 14,
    })
    refs.batteryBadge = UI.create("Frame", {
        Name = "BatteryBadge",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(72, 18),
        BackgroundColor3 = Colors.water,
        Visible = false,
    }, { UI.corner(6), refs.batteryBadgeText })
    refs.batteryRow = UI.create("Frame", {
        Name = "BatteryBarRow",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Parent = topRight,
    }, { refs.batteryBar.root, refs.batteryBadge })
    refs.batteryText.Parent.Visible = false
    refs.batteryRow.Visible = false
    -- 부스트 게이지 (로버 탑승 중에만)
    refs.boostBar = UI.progressBar(BOOST_COLOR, 8)
    refs.boostBar.root.AnchorPoint = Vector2.new(0, 0.5)
    refs.boostBar.root.Position = UDim2.fromScale(0, 0.5)
    refs.boostBar.root.Size = UDim2.new(1, -78, 0, 8)
    refs.boostState = UI.create("TextLabel", {
        Name = "BoostState",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(72, 18),
        Text = "",
        Preset = "badge",
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    refs.boostRow = UI.create("Frame", {
        Name = "BoostRow",
        LayoutOrder = 5,
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = topRight,
    }, { refs.boostBar.root, refs.boostState })
    refs.boostCaption = UI.create("TextLabel", {
        Name = "BoostCaption",
        LayoutOrder = 6,
        Size = UDim2.new(1, 0, 0, 16),
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "caption",
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
        Parent = topRight,
    })
    refs.roverBadge = makeInfoRow(topRight, 7, "로버 상태")
    refs.roverBadge.Parent.Visible = false

    -- 좌측 열: 모듈 3개 (PC). compact에서는 숨기고 상단 중앙의 A/B/C 칩 한 줄로 대신한다.
    local modulesPanel = UI.create("Frame", {
        Name = "Modules",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
        Parent = leftColumn,
    }, { UI.corner(10), UI.padding(10), UI.list(Enum.FillDirection.Vertical, 6) })
    refs.modulesPanel = modulesPanel
    refs.chipRow = UI.create("Frame", {
        Name = "ModuleChips",
        LayoutOrder = 3,
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = topCenter,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
    refs.modules = {}
    for index, moduleId in ipairs(config.MODULE_ORDER) do
        local row = makeModuleRow(modulesPanel, index, moduleId)
        local chipLabel = UI.create("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            Text = moduleId,
            Preset = "badge",
            TextSize = 14,
        })
        row.chip = UI.create("Frame", {
            Name = "Chip" .. moduleId,
            LayoutOrder = index,
            Size = UDim2.fromOffset(92, 28),
            BackgroundColor3 = Colors.neutral,
            Parent = refs.chipRow,
        }, { UI.corner(8), chipLabel })
        row.chipLabel = chipLabel
        refs.modules[moduleId] = row
    end

    -- 우하단: 속도 토글
    -- 배속이 1개뿐이면 버튼을 만들지 않는다
    if #config.SPEEDS > 1 then
        refs.speed = UI.create("TextButton", {
            Name = "SpeedButton",
            -- 우측 열의 패널 아래
            LayoutOrder = 2,
            Size = UDim2.new(1, 0, 0, 40),
            BackgroundColor3 = Colors.panelLight,
            Text = "1x",
            Preset = "heading",
            Parent = rightColumn,
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

    -- compact(터치 전용 또는 낮은 화면)이면 모듈 패널을 칩 한 줄로 접고 Day 패널 폭을 줄인다
    local function applyLayout()
        local compact = Layout.isCompact()
        refs.modulesPanel.Visible = not compact
        refs.chipRow.Visible = compact
        refs.topCenter.Size = UDim2.fromOffset(if compact then 320 else 460, 0)
    end
    applyLayout()
    Layout.changed:Connect(applyLayout)
end

-- 다른 모듈이 배치 기준으로 쓰는 프레임
function HUD.getRightColumn()
    return refs.rightColumn
end

function HUD.getTopCenter()
    return refs.topCenter
end

function HUD.getResources()
    return refs.resources
end

-- compact용 칩: 문구와 색
local CHIP_STYLE = {
    locked = { bg = Colors.neutral, fg = Colors.bg },
    available = { bg = Colors.panelLight, fg = Colors.good },
    building = { bg = Colors.energy, fg = Colors.bg },
    active = { bg = Colors.good, fg = Colors.bg },
}

local function updateChip(row, moduleId, moduleState)
    local status = moduleState.status
    local suffix = STATUS_CHIP[status] or ""
    if status == "building" then
        suffix = string.format("%d일", moduleState.daysLeft)
    end
    local style = CHIP_STYLE[status] or CHIP_STYLE.locked
    row.chipLabel.Text = moduleId .. " " .. suffix
    row.chipLabel.TextColor3 = style.fg
    row.chip.BackgroundColor3 = style.bg
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

-- 배터리 25% 이하 경고: 바와 글자를 천천히 깜빡인다
-- 충전 중에는 바만 은은하게 맥동한다
local function setBatteryBlink(mode)
    if mode == batteryMode then
        return
    end
    batteryMode = mode
    if batteryTweens then
        for _, tween in ipairs(batteryTweens) do
            tween:Cancel()
        end
        batteryTweens = nil
        refs.batteryBar.fill.BackgroundTransparency = 0
        refs.batteryText.TextTransparency = 0
    end
    if mode == "low" then
        local info = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
        batteryTweens = {
            TweenService:Create(refs.batteryBar.fill, info, { BackgroundTransparency = 0.7 }),
            TweenService:Create(refs.batteryText, info, { TextTransparency = 0.6 }),
        }
    elseif mode == "charging" then
        local info = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
        batteryTweens = {
            TweenService:Create(refs.batteryBar.fill, info, { BackgroundTransparency = 0.45 }),
        }
    end
    for _, tween in ipairs(batteryTweens or {}) do
        tween:Play()
    end
end

local function updateBattery(rover)
    local battery, batteryMax = rover.battery, rover.batteryMax
    local valid = type(battery) == "number" and type(batteryMax) == "number" and batteryMax > 0
    refs.batteryText.Parent.Visible = valid
    refs.batteryRow.Visible = valid
    if not valid then
        setBatteryBlink(nil)
        return
    end
    local ratio = battery / batteryMax
    local low = ratio <= 0.25
    refs.batteryText.Text = string.format("%d / %d", roundInt(battery), roundInt(batteryMax))
    refs.batteryText.TextColor3 = if low then Colors.bad else Colors.text
    refs.batteryBar.fill.BackgroundColor3 = if low then Colors.bad else Colors.energy
    refs.batteryBar.setRatio(ratio)
    setBatteryBlink(if low then "low" elseif rover.charging then "charging" else nil)

    if battery <= 0 then
        refs.batteryBadge.Visible = true
        refs.batteryBadge.BackgroundColor3 = Colors.bad
        refs.batteryBadgeText.TextColor3 = Colors.text
        refs.batteryBadgeText.Text = "방전"
    elseif rover.charging then
        refs.batteryBadge.Visible = true
        refs.batteryBadge.BackgroundColor3 = Colors.water
        refs.batteryBadgeText.TextColor3 = Colors.bg
        refs.batteryBadgeText.Text = "충전 중"
    else
        refs.batteryBadge.Visible = false
    end
end

local function stopBoostPulse()
    if boostPulse then
        boostPulse:Cancel()
        boostPulse = nil
        refs.boostBar.fill.BackgroundTransparency = 0
    end
end

local function startBoostPulse()
    if boostPulse then
        return
    end
    boostPulse = TweenService:Create(
        refs.boostBar.fill,
        TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { BackgroundTransparency = 0.4 }
    )
    boostPulse:Play()
end

-- 과열 순간 게이지를 좌우로 2px 3회 흔든다
local function shakeBoost()
    local bar, label = refs.boostBar.root, refs.boostState
    task.spawn(function()
        for _ = 1, 3 do
            for _, dx in ipairs({ 2, -2 }) do
                bar.Position = UDim2.new(0, dx, 0.5, 0)
                label.Position = UDim2.new(1, dx, 0.5, 0)
                task.wait(0.03)
            end
        end
        bar.Position = UDim2.fromScale(0, 0.5)
        label.Position = UDim2.fromScale(1, 0.5)
    end)
end

-- 쿨다운 완료 순간 게이지 바탕과 글자를 0.3초 초록으로 반짝인다
local function flashBoostReady()
    boostFlashUntil = os.clock() + 0.3
    task.delay(0.3, function()
        if lastRover then
            updateBoost(lastRover)
        end
    end)
end

-- 부스트 게이지: boostHeat 0..1, 탑승 중이고 필드가 있을 때만 보인다
function updateBoost(rover)
    local heat = rover and rover.boostHeat
    local show = RoverBoost.isDriving() and type(heat) == "number"
    refs.boostRow.Visible = show
    refs.boostCaption.Visible = show
    if not show then
        boostOverheated = false
        stopBoostPulse()
        return
    end
    local wasOverheated = boostOverheated
    if heat >= 0.98 then
        boostOverheated = true
        if not wasOverheated then
            shakeBoost()
        end
    elseif heat <= 0.02 then
        boostOverheated = false
        if wasOverheated then
            flashBoostReady()
        end
    end
    refs.boostBar.setRatio(heat)
    local flashing = os.clock() < boostFlashUntil
    refs.boostBar.root.BackgroundColor3 = if flashing then Colors.good else Colors.bg
    if flashing then
        stopBoostPulse()
        refs.boostBar.fill.BackgroundColor3 = Colors.good
        refs.boostState.Text = "준비 완료"
        refs.boostState.TextColor3 = Colors.good
    elseif heat >= 0.98 then
        stopBoostPulse()
        refs.boostBar.fill.BackgroundColor3 = Colors.bad
        refs.boostState.Text = "과열"
        refs.boostState.TextColor3 = Colors.bad
    elseif boostOverheated then
        stopBoostPulse()
        refs.boostBar.fill.BackgroundColor3 = Colors.neutral
        refs.boostState.Text = "쿨다운"
        refs.boostState.TextColor3 = Colors.neutral
    else
        local boosting = rover.boosting == true
        refs.boostBar.fill.BackgroundColor3 = if boosting then BOOST_COLOR else BOOST_DIM
        refs.boostState.Text = if boosting then "부스트" else ""
        refs.boostState.TextColor3 = BOOST_COLOR
        if boosting then
            startBoostPulse()
        else
            stopBoostPulse()
        end
    end
    refs.boostCaption.Text = if UI.isTouchOnly()
        then "부스터 버튼 (배터리 3배)"
        else "Shift 부스터 (배터리 3배)"
    local battery, batteryMax = rover.battery, rover.batteryMax
    local lowBattery = type(battery) == "number"
        and type(batteryMax) == "number"
        and batteryMax > 0
        and battery / batteryMax <= 0.2
    refs.boostCaption.TextTransparency = if lowBattery then 0.6 else 0
end

function HUD.update(state)
    refs.energy.value.Text = tostring(math.floor(state.energy))
    refs.water.value.Text = tostring(math.floor(state.water))
    refs.food.value.Text = tostring(math.floor(state.food))
    -- 에너지: 상한이 있으면 "50 / 150", 95% 이상이면 노랑(넘치는 전력은 버려진다)
    local energy = math.floor(state.energy)
    local cap = state.energyCap
    if type(cap) == "number" and cap > 0 then
        refs.energy.value.Text = string.format("%d / %d", energy, math.floor(cap))
        refs.energy.value.TextColor3 = if state.energy >= cap * 0.95
            then Colors.energy
            else Colors.text
    else
        refs.energy.value.TextColor3 = Colors.text
    end
    setNet(refs.energy.net, state.netEnergy)
    setNet(refs.water.net, state.netWater)
    setNet(refs.food.net, state.netFood)
    setDaysLeft(refs.water.days, state.daysLeft and state.daysLeft.water)
    setDaysLeft(refs.food.days, state.daysLeft and state.daysLeft.food)

    refs.day.Text = string.format("Day %d / %d", state.day, state.totalDays)
    refs.mission.Text = state.missionText or ""
    refs.site.Text = state.siteName or ""
    refs.site.Visible = state.siteName ~= nil

    refs.panels.Text = string.format(
        "%d/%d (오늘 %d/%d)",
        state.panelsInstalled,
        state.panelsTotal,
        state.panelsInstalledToday,
        state.panelsPerDay
    )
    refs.tank.Text =
        string.format("%d/%d", roundInt(state.rover.tank), roundInt(state.rover.tankMax))

    updateBattery(state.rover)
    lastRover = state.rover
    updateBoost(state.rover)

    local damage = state.rover.damage
    local badge = refs.roverBadge
    if state.rover.broken then
        badge.Text = "고장"
        badge.TextColor3 = Colors.bad
        badge.Parent.Visible = true
    elseif type(damage) == "number" and damage > 0 then
        badge.Text = string.format("파손 %d/3", damage)
        badge.TextColor3 = Colors.energy
        badge.Parent.Visible = true
    else
        badge.Parent.Visible = false
    end

    for moduleId, row in pairs(refs.modules) do
        local moduleState = state.modules[moduleId]
        if moduleState then
            updateModule(row, moduleState)
            updateChip(row, moduleId, moduleState)
        end
    end

    currentSpeed = state.speed
    if refs.speed then
        refs.speed.Text = string.format("%dx", state.speed)
    end

    local stallReason = state.stallReason
    if state.shortageDays > 0 then
        refs.banner.Visible = true
        refs.banner.BackgroundColor3 = Colors.bad
        refs.bannerText.TextColor3 = Colors.text
        refs.bannerText.TextSize = 20
        refs.bannerText.Text = string.format(
            "자원 부족 %d일째. %d일이면 임무 실패",
            state.shortageDays,
            config.SHORTAGE_DAYS_TO_LOSE
        )
    elseif type(stallReason) == "string" and stallReason ~= "" then
        refs.banner.Visible = true
        refs.banner.BackgroundColor3 = Colors.energy
        refs.bannerText.TextColor3 = Colors.bg
        refs.bannerText.TextSize = 16
        refs.bannerText.Text = stallReason
    else
        refs.banner.Visible = false
    end
end

-- 탑승 여부가 바뀌면 다음 StateUpdate를 기다리지 않고 게이지를 갱신
RoverBoost.drivingChanged:Connect(function()
    if refs.boostRow then
        updateBoost(lastRover)
    end
end)

function HUD.setVisible(visible)
    gui.Enabled = visible
end

return HUD
