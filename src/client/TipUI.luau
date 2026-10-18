--!nonstrict
-- 상황별 일회성 Tip 카드. 토스트(우상단, 사건 알림)와 미션 문구(상단 중앙, 목표)와 달리
-- 하단 중앙 산소 바 바로 위에 뜬다(시야 중앙과 월드 프롬프트를 가리지 않게). 아래에서 올라오며 나타난다.
-- 좌하단(PC)/좌상단(터치) 레이더와 터치 점프 버튼을 피하도록 폭과 가로 위치를 화면 크기로 정한다.
-- 한 번에 하나, 대기열 순차 표시, 표시 사이 최소 3초 간격, 세션당 각 Tip 1회(재시작하면 초기화).
-- 문구는 Config.TIPS. 트리거는 전부 클라이언트 측(StateUpdate, OxygenUpdate, 탑승 이벤트).

local TweenService = game:GetService("TweenService")

local RoverBoost = require(script.Parent.RoverBoost)
local SoundFX = require(script.Parent.SoundFX)
local UI = require(script.Parent.UI)

local TipUI = {}

local CARD_MAX_WIDTH = 560
local FADE_IN = 0.3
local HOLD = 6
local FADE_OUT = 0.5
local MIN_GAP = 3
local RISE = 24 -- 등장 시 아래에서 올라오는 거리(px)
local SINK = 12 -- 퇴장 시 아래로 가라앉는 거리(px)
-- 카드 아래 끝 = 화면 하단에서 84px. 산소 바(하단 18~48), 에어락 태그(54~76) 위 8px 여유.
-- 에어락 안내 문구는 산소 바 아래(하단 0~18)라 겹치지 않는다.
local BOTTOM_GAP = 84
-- 레이더 오른쪽 끝(PC 좌하단 x 16~236, 터치 좌상단 x 12~232, 캡션 포함) + 12px
local LEFT_BOUND = 248
local RIGHT_RESERVE_PC = 12 -- PC 우하단 배속 버튼은 카드보다 아래(하단 12~56)라 가로 여유만 둔다
local RIGHT_RESERVE_TOUCH = 120 -- 터치 점프 버튼(약 x W-95~W-25, 하단 20~90)
local FALLBACK_VIEWPORT = Vector2.new(1280, 720)
local TIP_SOUND_VOLUME = 0.3

local CREAM = Color3.fromRGB(245, 240, 225)
local INK = Color3.fromRGB(40, 36, 28)
local AMBER = Color3.fromRGB(255, 200, 40)
local BASE_GRAY = Color3.fromRGB(120, 110, 90)

local config
local gui
local group
local textLabel
local card

local shown = {} -- { [key] = true } 큐에 넣은 Tip
local queue = {}
local suppressed = true
local generation = 0 -- reset이나 억제 때 현재 카드를 끊기 위한 값
local lastEnd = -math.huge

local prevPhase = nil
local prevPanels = nil
local atBoard = false

local function tipText(key)
    local template = config.TIPS and config.TIPS[key]
    if not template then
        return nil
    end
    local roverConfig = config.ROVER or {}
    if key == "boost" then
        return string.format(template, roverConfig.boostDrainMultiplier or 3)
    elseif key == "panelLimit" then
        return string.format(template, config.PANELS_PER_DAY or 3)
    elseif key == "damage" then
        local damageConfig = config.ROVER_DAMAGE or {}
        return string.format(
            template,
            damageConfig.repairKey or "R",
            damageConfig.repairHold or 4,
            damageConfig.repairEnergy or 10
        )
    end
    return template
end

function TipUI.push(key)
    if suppressed or shown[key] then
        return
    end
    local text = tipText(key)
    if not text then
        return
    end
    shown[key] = true
    table.insert(queue, text)
end

local function clearQueue()
    queue = {}
    generation += 1
end

function TipUI.reset()
    shown = {}
    prevPanels = nil
    atBoard = false
    clearQueue()
end

-- 결과, 선택, 착륙 화면에서는 표시하지 않고 큐만 비운다
function TipUI.setSuppressed(value)
    if value == suppressed then
        return
    end
    suppressed = value
    if value then
        clearQueue()
    end
end

-- 대기 단계 포함 취소 가능한 대기
local function waitFor(seconds, myGeneration)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if generation ~= myGeneration then
            return false
        end
        task.wait(0.1)
    end
    return generation == myGeneration
end

-- 카드 폭과 가로 중심(px). 가운데에 두되 레이더와 겹치면 오른쪽으로 비키고, 그래도 좁으면 폭을 줄인다.
-- 예: 1920x1080 -> 폭 560, x 680~1240 / 1280x720 -> x 360~920 / 844x390 터치 -> 폭 476, x 248~724
local function cardLayout()
    local viewport = gui.AbsoluteSize
    if viewport.X <= 0 or viewport.Y <= 0 then
        viewport = FALLBACK_VIEWPORT
    end
    local rightReserve = if UI.isTouchOnly() then RIGHT_RESERVE_TOUCH else RIGHT_RESERVE_PC
    local width = math.min(CARD_MAX_WIDTH, viewport.X - LEFT_BOUND - rightReserve)
    local centerX = math.max(viewport.X / 2, LEFT_BOUND + width / 2)
    return width, centerX
end

local function cardPosition(centerX, dy)
    return UDim2.new(0, centerX, 1, -BOTTOM_GAP + dy)
end

local function showCard(text, myGeneration)
    textLabel.Text = text
    local width, centerX = cardLayout()
    group.Size = UDim2.fromOffset(width, 0)
    group.GroupTransparency = 1
    group.Position = cardPosition(centerX, RISE)
    local info = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(group, info, { GroupTransparency = 0 }):Play()
    TweenService:Create(group, info, { Position = cardPosition(centerX, 0) }):Play()
    group.Visible = true

    local completed = waitFor(FADE_IN + HOLD, myGeneration)
    local fade = if completed then FADE_OUT else 0.2
    local outInfo = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    local out = TweenService:Create(group, outInfo, { GroupTransparency = 1 })
    TweenService:Create(group, outInfo, { Position = cardPosition(centerX, SINK) }):Play()
    out:Play()
    task.wait(fade)
    if generation == myGeneration or not completed then
        group.Visible = false
    end
end

local function worker()
    while true do
        task.wait(0.25)
        if not suppressed and #queue > 0 and os.clock() - lastEnd >= MIN_GAP then
            local text = table.remove(queue, 1)
            local myGeneration = generation
            SoundFX.playVolume("mission_advance", TIP_SOUND_VOLUME)
            showCard(text, myGeneration)
            lastEnd = os.clock()
        end
    end
end

local function makeBulb()
    return UI.create("Frame", {
        Name = "Bulb",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(32, 40),
        BackgroundTransparency = 1,
    }, {
        UI.create("Frame", {
            Name = "Glass",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 2),
            Size = UDim2.fromOffset(24, 24),
            BackgroundColor3 = AMBER,
        }, { UI.roundCorner() }),
        UI.create("Frame", {
            Name = "BaseUpper",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 28),
            Size = UDim2.fromOffset(14, 4),
            BackgroundColor3 = BASE_GRAY,
        }, { UI.corner(2) }),
        UI.create("Frame", {
            Name = "BaseLower",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, 34),
            Size = UDim2.fromOffset(10, 4),
            BackgroundColor3 = BASE_GRAY,
        }, { UI.corner(2) }),
    })
end

function TipUI.init(ctx)
    config = ctx.Config
    gui = UI.gui("Tip", 14)

    textLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = INK,
        Preset = "body",
        TextSize = 16,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local badge = UI.create("TextLabel", {
        Name = "TipBadge",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(38, 16),
        BackgroundTransparency = 0,
        BackgroundColor3 = AMBER,
        Text = "TIP",
        TextColor3 = INK,
        Preset = "caption",
        TextSize = 12,
        Font = UI.FontBold,
    }, { UI.roundCorner() })

    card = UI.create("Frame", {
        Name = "Card",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = CREAM,
    }, {
        UI.corner(12),
        UI.stroke(AMBER, 1.5),
        UI.padding(14),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 12),
            VerticalAlignment = Enum.VerticalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        makeBulb(),
        UI.create("Frame", {
            Name = "Body",
            LayoutOrder = 2,
            Size = UDim2.new(1, -44, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Vertical,
                Padding = UDim.new(0, 4),
                SortOrder = Enum.SortOrder.LayoutOrder,
            }),
            badge,
            textLabel,
        }),
    })

    group = UI.create("CanvasGroup", {
        Name = "Group",
        -- 아래 끝 기준: 문구가 3줄로 늘어나도 위로만 자라 산소 바를 덮지 않는다
        AnchorPoint = Vector2.new(0.5, 1),
        Position = cardPosition(640, 0),
        Size = UDim2.fromOffset(CARD_MAX_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
        Parent = gui,
    }, {
        card,
    })

    -- 처음 DriverSeat에 앉으면 레이더 Tip을 먼저, 3초 뒤 부스터 Tip
    RoverBoost.drivingChanged:Connect(function(driving)
        if driving and not atBoard and not suppressed then
            atBoard = true
            TipUI.push("radar")
            task.delay(3, function()
                TipUI.push("boost")
            end)
        end
    end)

    task.spawn(worker)
end

function TipUI.onState(state)
    local phase = state.phase
    if phase == "selecting" then
        TipUI.reset()
    end
    TipUI.setSuppressed(phase ~= "playing")

    if phase == "playing" and prevPhase ~= "playing" then
        task.delay(2, function()
            TipUI.push("start")
        end)
    end
    prevPhase = phase
    if phase ~= "playing" then
        return
    end

    local panels = state.panelsInstalled
    if type(panels) == "number" then
        if prevPanels == 0 and panels >= 1 then
            TipUI.push("panelLimit")
        end
        prevPanels = panels
    end

    local moduleB = state.modules and state.modules.B
    local waterDays = state.daysLeft and state.daysLeft.water
    if
        moduleB
        and moduleB.status == "active"
        and type(waterDays) == "number"
        and waterDays <= 5
    then
        TipUI.push("farmWater")
    end

    local rover = state.rover
    if rover and type(rover.damage) == "number" and rover.damage >= 1 then
        TipUI.push("damage")
    end

    local cap = state.energyCap
    if type(cap) == "number" and cap > 0 and state.energy >= cap * 0.95 then
        TipUI.push("energyCap")
    end
end

function TipUI.onOxygen(oxygen, _max, inside)
    if not inside and oxygen < 50 then
        TipUI.push("airlock")
    end
end

return TipUI
