--!nonstrict
-- 토스트 메시지. 우상단(패널 아래)에 최대 3개 쌓고 3초 뒤 서서히 사라진다.

local TweenService = game:GetService("TweenService")

local HUD = require(script.Parent.HUD)
local Layout = require(script.Parent.Layout)
local UI = require(script.Parent.UI)

local ToastUI = {}

local MAX_TOASTS = 3
local MAX_TOASTS_COMPACT = 2
local SHOW_SECONDS = 3
local FADE_SECONDS = 0.4

local KIND_COLORS = {
    info = Color3.fromRGB(52, 60, 84),
    warn = Color3.fromRGB(150, 45, 52),
    good = Color3.fromRGB(34, 112, 66),
}

local container
local toastRoot
local compactLayout = false
local active = {} -- 오래된 순서
local order = 0

local function remove(toast)
    local index = table.find(active, toast)
    if index then
        table.remove(active, index)
    end
    toast:Destroy()
end

function ToastUI.init(_ctx)
    local gui = UI.gui("Toasts", 100, false)
    toastRoot = Layout.root(gui)
    compactLayout = Layout.isCompact()
    -- PC: HUD 우측 열(패널, 로버, 배터리, 부스트) 실제 하단 + 8.
    -- compact: 우측에 부스터와 점프 버튼이 있으므로 상단 중앙(Day 패널과 모듈 칩) 아래.
    container = UI.create("Frame", {
        Name = "Stack",
        AnchorPoint = if compactLayout then Vector2.new(0.5, 0) else Vector2.new(1, 0),
        Position = if compactLayout then UDim2.new(0.5, 0, 0, 100) else UDim2.new(1, -12, 0, 100),
        Size = UDim2.fromOffset(if compactLayout then 260 else 300, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = toastRoot,
    }, { UI.list(Enum.FillDirection.Vertical, 6) })

    -- 기준 프레임 크기가 바뀌어도(배터리 줄, 부스트 게이지 등장) 따라가도록 주기적으로 갱신
    task.spawn(function()
        while true do
            -- 뷰포트가 바뀔 수 있으므로 매번 판정한다 (init 시점에는 아직 작게 보일 수 있다)
            compactLayout = Layout.isCompact()
            container.AnchorPoint = if compactLayout then Vector2.new(0.5, 0) else Vector2.new(1, 0)
            container.Size = UDim2.fromOffset(if compactLayout then 260 else 300, 0)
            local target = if compactLayout then HUD.getTopCenter() else HUD.getRightColumn()
            if target then
                local y = Layout.below(toastRoot, target, 8)
                container.Position = if compactLayout
                    then UDim2.new(0.5, 0, 0, y)
                    else UDim2.new(1, -12, 0, y)
            end
            task.wait(0.2)
        end
    end)
end

function ToastUI.push(text, kind)
    order += 1
    local toast = UI.create("CanvasGroup", {
        Name = "Toast",
        LayoutOrder = order,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = KIND_COLORS[kind] or KIND_COLORS.info,
        Parent = container,
    }, {
        UI.corner(8),
        UI.padding({ 8, 8, 12, 12 }),
        UI.create("TextLabel", {
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Text = text,
            Preset = "caption",
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
    })

    table.insert(active, toast)
    while #active > (if compactLayout then MAX_TOASTS_COMPACT else MAX_TOASTS) do
        remove(active[1])
    end

    task.delay(SHOW_SECONDS, function()
        if not toast.Parent then
            return
        end
        local tween =
            TweenService:Create(toast, TweenInfo.new(FADE_SECONDS), { GroupTransparency = 1 })
        tween.Completed:Once(function()
            if toast.Parent then
                remove(toast)
            end
        end)
        tween:Play()
    end)
end

return ToastUI
