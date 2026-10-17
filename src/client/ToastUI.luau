--!nonstrict
-- 토스트 메시지. 우상단(패널 아래)에 최대 3개 쌓고 3초 뒤 서서히 사라진다.

local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)

local ToastUI = {}

local MAX_TOASTS = 3
local SHOW_SECONDS = 3
local FADE_SECONDS = 0.4

local KIND_COLORS = {
    info = Color3.fromRGB(52, 60, 84),
    warn = Color3.fromRGB(150, 45, 52),
    good = Color3.fromRGB(34, 112, 66),
}

local container
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
    -- HUD 우상단 패널(높이 약 74) 바로 아래
    container = UI.create("Frame", {
        Name = "Stack",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 100),
        Size = UDim2.fromOffset(300, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = gui,
    }, { UI.list(Enum.FillDirection.Vertical, 6) })
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
    while #active > MAX_TOASTS do
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
