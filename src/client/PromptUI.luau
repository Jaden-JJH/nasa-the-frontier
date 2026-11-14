--!nonstrict
-- 커스텀 ProximityPrompt UI (v2). 서버가 Style = Custom으로 둔 프롬프트를 루나 디자인으로 그린다.
-- 문구는 Attribute 키 프로토콜(CONTRACT_V2 3절)로 읽는다: ActionKey, ObjectKey, ActionArgs, ObjectArgs(JSON),
-- CooldownUntil(서버 시각). ActionText, ObjectText는 서버가 비워 둔다. Attribute가 없는 프롬프트(v1, 기본)는
-- ActionText, ObjectText를 그대로 보여 준다. 언어가 바뀌면 Localizer가 다시 그린다.
-- 패널은 앵커 아래쪽으로 뻗고, 같은 자리의 프롬프트는 아래로 쌓는다(최대 2개, 카메라에 가까운 것).
-- 키 상자: 키보드는 KeyCode 이름(E, R), 게임패드는 버튼 이름, 터치는 key.touch.tap.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)
local L = UI.Luna

local PromptUI = {}

local PANEL_WIDTH = 260
local PANEL_HEIGHT = 72
local KEY_BOX = 44
local TEXT_LEFT = 70
local BAR_HEIGHT = 6
local FADE_SECONDS = 0.15
local ANCHOR_GAP = 4
local STACK_STEP = 82 -- 같은 위치 프롬프트를 아래로 쌓는 픽셀 간격
local MAX_VISIBLE = 2
local COOLDOWN_TICK = 0.25

local active = {} -- { [ProximityPrompt] = entry }
local order = {} -- PromptShown 순서의 프롬프트 목록

-- 게임패드 버튼 이름 정리 (ButtonX -> X)
local function gamepadLabel(keyCode)
    local name = keyCode.Name
    return (string.gsub(name, "^Button", ""))
end

local function setKeyText(label, prompt, inputType)
    if inputType == Enum.ProximityPromptInputType.Touch then
        UI.msg(label, "key.touch.tap")
    elseif inputType == Enum.ProximityPromptInputType.Gamepad then
        UI.raw(label, gamepadLabel(prompt.GamepadKeyCode))
    else
        -- 키보드 배열(한글 등)에 상관없이 키코드 이름을 그대로 표시한다 (예: "E", "R")
        UI.raw(label, prompt.KeyboardKeyCode.Name)
    end
end

local function getWorldPosition(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("BasePart") then
        return parent.Position
    elseif parent and parent:IsA("Attachment") then
        return parent.WorldPosition
    end
    return nil
end

-- JSON 문자열 Attribute를 표로 (없거나 깨지면 nil)
local function decodeArgs(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(value)
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- 표시 순서대로 슬롯을 배정한다. MAX_VISIBLE 초과 시 카메라에 가까운 것만 남긴다.
local function relayout()
    local list = {}
    for _, prompt in ipairs(order) do
        if active[prompt] then
            table.insert(list, prompt)
        end
    end
    if #list > MAX_VISIBLE then
        local camera = workspace.CurrentCamera
        local camPos = camera and camera.CFrame.Position
        local dist = {}
        for _, prompt in ipairs(list) do
            local pos = getWorldPosition(prompt)
            dist[prompt] = (camPos and pos) and (pos - camPos).Magnitude or math.huge
        end
        local ranked = table.clone(list)
        table.sort(ranked, function(a, b)
            return dist[a] < dist[b]
        end)
        local keep = {}
        for i = 1, MAX_VISIBLE do
            keep[ranked[i]] = true
        end
        local filtered = {}
        for _, prompt in ipairs(list) do
            active[prompt].gui.Enabled = keep[prompt] == true
            if keep[prompt] then
                table.insert(filtered, prompt)
            end
        end
        list = filtered
    else
        for _, prompt in ipairs(list) do
            active[prompt].gui.Enabled = true
        end
    end
    for slot, prompt in ipairs(list) do
        local entry = active[prompt]
        local target = UDim2.new(0.5, 0, 0.5, ANCHOR_GAP + (slot - 1) * STACK_STEP)
        if entry.slot == nil then
            entry.group.Position = target
        else
            TweenService
                :Create(
                    entry.group,
                    TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    { Position = target }
                )
                :Play()
        end
        entry.slot = slot
    end
end

-- 프롬프트 부모(Part 또는 Attachment)에 맞는 월드 오프셋
local function getAdornee(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("BasePart") then
        return parent, parent.Size.Y / 2 + UI.WORLD_ANCHOR_OFFSET
    elseif parent and parent:IsA("Attachment") then
        return parent, UI.WORLD_ANCHOR_OFFSET
    end
    return nil, 0
end

-- 쿨타임 남은 초 (없으면 0)
local function cooldownLeft(prompt)
    local untilTime = prompt:GetAttribute("CooldownUntil")
    if type(untilTime) ~= "number" then
        return 0
    end
    return math.max(0, math.ceil(untilTime - workspace:GetServerTimeNow()))
end

-- Attribute(또는 v1 글자)로 두 줄을 다시 그린다
local function refreshTexts(prompt, entry)
    local objectKey = prompt:GetAttribute("ObjectKey")
    if type(objectKey) == "string" and objectKey ~= "" then
        UI.msg(
            entry.object,
            { key = objectKey, args = decodeArgs(prompt:GetAttribute("ObjectArgs")) }
        )
        entry.object.Visible = true
    elseif prompt.ObjectText ~= "" then
        UI.raw(entry.object, prompt.ObjectText)
        entry.object.Visible = true
    else
        UI.raw(entry.object, "")
        entry.object.Visible = false
    end

    local left = cooldownLeft(prompt)
    local actionKey = prompt:GetAttribute("ActionKey")
    if left > 0 then
        UI.msg(entry.action, { key = "prompt.wait", args = { count = left } })
    elseif type(actionKey) == "string" and actionKey ~= "" then
        UI.msg(
            entry.action,
            { key = actionKey, args = decodeArgs(prompt:GetAttribute("ActionArgs")) }
        )
    else
        UI.raw(entry.action, prompt.ActionText)
    end
    entry.keyBox.BackgroundTransparency = if left > 0 then 0.9 else 0.8
end

local function destroyEntry(prompt, entry)
    active[prompt] = nil
    local idx = table.find(order, prompt)
    if idx then
        table.remove(order, idx)
    end
    relayout()
    entry.alive = false
    for _, conn in ipairs(entry.conns) do
        conn:Disconnect()
    end
    if entry.holdTween then
        entry.holdTween:Cancel()
    end
    local tween =
        TweenService:Create(entry.group, TweenInfo.new(FADE_SECONDS), { GroupTransparency = 1 })
    TweenService:Create(entry.scale, TweenInfo.new(FADE_SECONDS), { Scale = 0.9 }):Play()
    tween.Completed:Once(function()
        entry.gui:Destroy()
    end)
    tween:Play()
end

local function show(prompt, inputType)
    if active[prompt] then
        return
    end
    local adornee, extra = getAdornee(prompt)
    if not adornee then
        return
    end

    local keyLabel = UI.create("TextLabel", {
        Name = "KeyText",
        Size = UDim2.fromScale(1, 1),
        FontFace = UI.RoundHeavy,
        TextColor3 = L.white,
        Text = "",
    })
    UI.scaledText(keyLabel, 20, 10)
    setKeyText(keyLabel, prompt, inputType)
    local objectLabel = UI.create("TextLabel", {
        Name = "ObjectText",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 18),
        Font = UI.Font,
        TextColor3 = L.label,
        Text = "",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, { UI.worldStroke() })
    UI.scaledText(objectLabel, 15, 10)
    local actionLabel = UI.create("TextLabel", {
        Name = "ActionText",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 26),
        Font = UI.FontBold,
        TextColor3 = L.white,
        Text = "",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, { UI.worldStroke() })
    UI.scaledText(actionLabel, 20, 12)

    local keyBox = UI.create("Frame", {
        Name = "KeyIcon",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 14, 0.5, 0),
        Size = UDim2.fromOffset(KEY_BOX, KEY_BOX),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.8,
    }, { UI.corner(10), UI.stroke(L.mint, 1.5, 0.2), UI.padding(4), keyLabel })

    local panel = UI.create("Frame", {
        Name = "Panel",
        Size = UDim2.new(1, 0, 0, PANEL_HEIGHT),
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.12,
    }, {
        UI.corner(14),
        UI.stroke(L.white, 1.5, UI.LUNA_STROKE_TRANSPARENCY),
        keyBox,
        UI.create("Frame", {
            Name = "Texts",
            Position = UDim2.fromOffset(TEXT_LEFT, 0),
            Size = UDim2.new(1, -(TEXT_LEFT + 12), 1, 0),
            BackgroundTransparency = 1,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Vertical,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                SortOrder = Enum.SortOrder.LayoutOrder,
            }),
            objectLabel,
            actionLabel,
        }),
    })
    local holdBar = UI.progressBar(L.mint, BAR_HEIGHT)
    holdBar.root.Position = UDim2.fromOffset(0, PANEL_HEIGHT + 4)
    holdBar.root.Visible = prompt.HoldDuration > 0

    local scale = UI.create("UIScale", { Scale = 0.9 })
    local group = UI.create("CanvasGroup", {
        Name = "Group",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0.5, ANCHOR_GAP),
        Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT + 4 + BAR_HEIGHT),
        BackgroundTransparency = 1,
        GroupTransparency = 1,
    }, { scale, panel, holdBar.root })

    local gui = UI.create("BillboardGui", {
        Name = "PromptGui",
        Adornee = adornee,
        AlwaysOnTop = true,
        LightInfluence = 0,
        ResetOnSpawn = false,
        Size = UDim2.fromOffset(
            PANEL_WIDTH + 20,
            2 * (ANCHOR_GAP + (MAX_VISIBLE - 1) * STACK_STEP + PANEL_HEIGHT + 4 + BAR_HEIGHT + 20)
        ),
        StudsOffsetWorldSpace = Vector3.new(0, extra, 0),
        Active = true,
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
    }, { group })

    local entry = {
        gui = gui,
        group = group,
        scale = scale,
        object = objectLabel,
        action = actionLabel,
        keyBox = keyBox,
        holdBar = holdBar,
        holdTween = nil,
        slot = nil,
        conns = {},
        alive = true,
    }
    active[prompt] = entry
    table.insert(order, prompt)
    relayout()
    refreshTexts(prompt, entry)

    local function refresh()
        refreshTexts(prompt, entry)
    end
    for _, name in ipairs({ "ActionKey", "ObjectKey", "ActionArgs", "ObjectArgs", "CooldownUntil" }) do
        table.insert(entry.conns, prompt:GetAttributeChangedSignal(name):Connect(refresh))
    end
    -- PromptHidden 없이 지워지는 프롬프트(재시작 때 기지 다시 놓기)도 정리한다
    table.insert(
        entry.conns,
        prompt.Destroying:Connect(function()
            if active[prompt] == entry then
                destroyEntry(prompt, entry)
            end
        end)
    )
    table.insert(entry.conns, prompt:GetPropertyChangedSignal("ActionText"):Connect(refresh))
    table.insert(entry.conns, prompt:GetPropertyChangedSignal("ObjectText"):Connect(refresh))
    table.insert(
        entry.conns,
        prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
            holdBar.root.Visible = prompt.HoldDuration > 0
        end)
    )

    -- 쿨타임이 있으면 남은 초를 다시 그린다 (복제 없이 클라이언트가 센다)
    task.spawn(function()
        while entry.alive do
            if prompt:GetAttribute("CooldownUntil") ~= nil then
                refreshTexts(prompt, entry)
            end
            task.wait(COOLDOWN_TICK)
        end
    end)

    -- 터치는 패널을 직접 눌러 홀드한다
    if inputType == Enum.ProximityPromptInputType.Touch then
        local button = UI.create("TextButton", {
            Name = "TouchArea",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "",
            ZIndex = 5,
            Parent = panel,
        })
        local function isPress(input)
            return input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1
        end
        table.insert(
            entry.conns,
            button.InputBegan:Connect(function(input)
                if isPress(input) then
                    prompt:InputHoldBegin()
                end
            end)
        )
        table.insert(
            entry.conns,
            button.InputEnded:Connect(function(input)
                if isPress(input) then
                    prompt:InputHoldEnd()
                end
            end)
        )
    end

    local info = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(group, info, { GroupTransparency = 0 }):Play()
    TweenService:Create(scale, info, { Scale = 1 }):Play()
end

local function resetHold(entry)
    if entry.holdTween then
        entry.holdTween:Cancel()
        entry.holdTween = nil
    end
    entry.holdBar.setRatio(0)
end

function PromptUI.init(_ctx)
    ProximityPromptService.PromptShown:Connect(show)

    ProximityPromptService.PromptHidden:Connect(function(prompt)
        local entry = active[prompt]
        if entry then
            destroyEntry(prompt, entry)
        end
    end)

    ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
        local entry = active[prompt]
        if not entry or prompt.HoldDuration <= 0 then
            return
        end
        resetHold(entry)
        entry.holdTween = TweenService:Create(
            entry.holdBar.fill,
            TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear),
            { Size = UDim2.fromScale(1, 1) }
        )
        entry.holdTween:Play()
    end)

    ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
        local entry = active[prompt]
        if entry then
            resetHold(entry)
        end
    end)

    ProximityPromptService.PromptTriggered:Connect(function(prompt)
        local entry = active[prompt]
        if entry then
            resetHold(entry)
        end
    end)
end

return PromptUI
