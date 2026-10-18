--!nonstrict
-- 상황별 일회성 Tip 카드. 토스트(우상단, 사건 알림)와 미션 문구(상단 중앙, 목표)와 달리
-- 우측 하단에 뜬다(14차, 사용자 지시). 아래에서 올라오며 나타나고 여러 줄은 위로 자란다.
-- PC: 오른쪽 16, 아래 16, 폭 360(가상 좌표, Layout 배율로 함께 커진다. 1080p는 1.25배).
-- 터치/낮은 화면(compact): 오른쪽 12px, 아래 190px(부스터와 점프 버튼 위, 실제 px 기준).
-- 한 번에 하나, 대기열 순차 표시, 표시 사이 최소 3초 간격, 세션당 각 Tip 1회(재시작하면 초기화).
-- 문구는 Config.TIPS. 트리거는 전부 클라이언트 측(StateUpdate, OxygenUpdate, 탑승 이벤트).

local TweenService = game:GetService("TweenService")

local RoverBoost = require(script.Parent.RoverBoost)
local SoundFX = require(script.Parent.SoundFX)
local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)

local TipUI = {}

local CARD_WIDTH = 360 -- 가상 좌표(배율 적용 전)
local BODY_TEXT_SIZE = 18 -- 본문. 1080p에서 22.5px
local BADGE_TEXT_SIZE = 15
local FADE_IN = 0.3
local HOLD = 6
local FADE_OUT = 0.5
local MIN_GAP = 3
local RISE = 24 -- 등장 시 아래에서 올라오는 거리(px)
local SINK = 12 -- 퇴장 시 아래로 가라앉는 거리(px)
local PC_MARGIN = 16 -- PC: 오른쪽, 아래 여백
local COMPACT_RIGHT = 12 -- 실제 px (부스터 버튼은 배율을 안 쓰므로 px로 맞춘다)
local COMPACT_BOTTOM = 190 -- 실제 px. 부스터 버튼(하단 110~174) 위 + 여유. 점프 버튼도 이 아래에 있다
local COMPACT_SIDE_PAD = 24 -- 실제 px. compact 폭 = min(360, 뷰포트 폭 - 24)
local FALLBACK_VIEWPORT = Vector2.new(1280, 720)
local TIP_SOUND_VOLUME = 0.3

local CREAM = Color3.fromRGB(245, 240, 225)
local INK = Color3.fromRGB(40, 36, 28)
local AMBER = Color3.fromRGB(255, 200, 40)
local BASE_GRAY = Color3.fromRGB(120, 110, 90)

local config
local gui
local tipRoot
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

-- 카드 폭과 우하단 여백(가상 좌표). 카드는 Layout 루트 안에 있어 배율만큼 커지므로
-- 실제 px로 정한 compact 여백은 배율로 나눠 넣는다. compact 여부는 표시할 때마다 읽는다.
local function cardLayout()
    local viewport = gui.AbsoluteSize
    if viewport.X <= 0 or viewport.Y <= 0 then
        viewport = FALLBACK_VIEWPORT
    end
    local scale = Layout.scale()
    local virtualWidth = viewport.X / scale
    if Layout.isCompact() then
        return math.min(CARD_WIDTH, virtualWidth - COMPACT_SIDE_PAD / scale),
            COMPACT_RIGHT / scale,
            COMPACT_BOTTOM / scale
    end
    return math.min(CARD_WIDTH, virtualWidth - PC_MARGIN * 2), PC_MARGIN, PC_MARGIN
end

local function cardPosition(right, bottom, dy)
    return UDim2.new(1, -right, 1, -bottom + dy)
end

local function showCard(text, myGeneration)
    textLabel.Text = text
    local width, right, bottom = cardLayout()
    group.Size = UDim2.fromOffset(width, 0)
    group.GroupTransparency = 1
    group.Position = cardPosition(right, bottom, RISE)
    local info = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(group, info, { GroupTransparency = 0 }):Play()
    TweenService:Create(group, info, { Position = cardPosition(right, bottom, 0) }):Play()
    group.Visible = true

    local completed = waitFor(FADE_IN + HOLD, myGeneration)
    local fade = if completed then FADE_OUT else 0.2
    local outInfo = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    local out = TweenService:Create(group, outInfo, { GroupTransparency = 1 })
    TweenService:Create(group, outInfo, { Position = cardPosition(right, bottom, SINK) }):Play()
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
    tipRoot = Layout.root(gui)

    textLabel = UI.create("TextLabel", {
        Name = "Text",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = INK,
        Preset = "body",
        TextSize = BODY_TEXT_SIZE,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local badge = UI.create("TextLabel", {
        Name = "TipBadge",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(46, 22),
        BackgroundTransparency = 0,
        BackgroundColor3 = AMBER,
        Text = "TIP",
        TextColor3 = INK,
        Preset = "caption",
        TextSize = BADGE_TEXT_SIZE,
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
        -- 아래 끝 기준: 문구가 여러 줄이 되어도 위로만 자란다
        AnchorPoint = Vector2.new(1, 1),
        Position = cardPosition(PC_MARGIN, PC_MARGIN, 0),
        Size = UDim2.fromOffset(CARD_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
        Parent = tipRoot,
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
