--!nonstrict
-- 토스트 메시지 (v2). 서버 Notify(msg: Msg, kind)를 지금 언어로 한 번 그린다(3초라 다시 그리지 않는다, I18N_PLAN 4.6).
-- PC는 HUD 오른쪽 열 아래, compact는 가운데 묶음 아래에 최대 3개(compact 2개) 쌓고 서서히 사라진다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Msg = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Msg"))

local HUDV2 = require(script.Parent.HUDV2)
local Layout = require(script.Parent.Layout)
local Localizer = require(script.Parent.Localizer)
local UI = require(script.Parent.UI)
local L = UI.Luna

local ToastUI = {}

local MAX_TOASTS = 3
local MAX_TOASTS_COMPACT = 2
local SHOW_SECONDS = 3.5
local FADE_SECONDS = 0.4
local WIDTH = 320
local WIDTH_COMPACT = 280
local GAP = 8
local REPOSITION_SECONDS = 0.2

local KIND_COLORS = {
    info = Color3.fromRGB(40, 48, 100),
    warn = Color3.fromRGB(150, 45, 60),
    good = Color3.fromRGB(30, 110, 85),
}
local KIND_STROKES = { info = L.sky, warn = L.red, good = L.mint }

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

local function reposition()
    compactLayout = Layout.isCompact()
    container.AnchorPoint = if compactLayout then Vector2.new(0, 0) else Vector2.new(1, 0)
    container.Size = UDim2.fromOffset(if compactLayout then WIDTH_COMPACT else WIDTH, 0)
    local target = if compactLayout then HUDV2.getTopCenter() else HUDV2.getRightColumn()
    if target and target.AbsoluteSize.Y > 0 then
        local y = Layout.below(toastRoot, target, GAP)
        -- compact는 가운데 묶음(자원 칩 아래로 내려가 있다) 바로 아래 왼쪽
        container.Position = if compactLayout
            then UDim2.fromOffset(12, y)
            else UDim2.new(1, -12, 0, y)
    else
        container.Position = if compactLayout
            then UDim2.fromOffset(12, 110)
            else UDim2.new(1, -12, 0, 60)
    end
end

function ToastUI.init(_ctx)
    local gui = UI.gui("Toasts", 120, false) -- 결과 화면(110)과 콘솔 위에도 보이게
    toastRoot = Layout.root(gui)
    container = UI.create("Frame", {
        Name = "Stack",
        Size = UDim2.fromOffset(WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = toastRoot,
    }, { UI.list(Enum.FillDirection.Vertical, 6) })
    reposition()
    -- 기준 프레임 크기가 바뀌어도(로버 칩, 배터리 칩, 우주 기상 배너) 따라가도록 주기적으로 갱신
    task.spawn(function()
        while true do
            reposition()
            task.wait(REPOSITION_SECONDS)
        end
    end)
end

-- msg: Msg 또는 키 문자열. kind: "info" | "warn" | "good"
function ToastUI.push(msg, kind)
    local text
    if Msg.isMsg(msg) or type(msg) == "string" then
        text = Localizer.text(msg)
    else
        return
    end
    if text == "" then
        return
    end
    order += 1
    local toast = UI.create("CanvasGroup", {
        Name = "Toast",
        LayoutOrder = order,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = KIND_COLORS[kind] or KIND_COLORS.info,
        BackgroundTransparency = 0.05,
        Parent = container,
    }, {
        UI.corner(12),
        UI.stroke(KIND_STROKES[kind] or KIND_STROKES.info, 1.5, 0.3),
        UI.padding({ 8, 9, 12, 12 }),
        UI.create("TextLabel", {
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Text = text,
            Font = UI.FontBold,
            TextSize = if compactLayout then 14 else 15,
            TextColor3 = L.white,
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
