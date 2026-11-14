--!nonstrict
-- 커스텀 ProximityPrompt UI (v2). 서버가 Style = Custom으로 둔 프롬프트를 루나 디자인으로 그린다.
-- 문구는 Attribute 키 프로토콜(CONTRACT_V2 3절)로 읽는다: ActionKey, ObjectKey, ActionArgs, ObjectArgs(JSON),
-- CooldownUntil(서버 시각). ActionText, ObjectText는 서버가 비워 둔다. Attribute가 없는 프롬프트(v1, 기본)는
-- ActionText, ObjectText를 그대로 보여 준다. 언어가 바뀌면 Localizer가 다시 그린다.
-- 패널은 앵커 아래쪽으로 뻗고, 같은 자리의 프롬프트는 아래로 쌓는다(최대 2개, 카메라에 가까운 것).
-- 키 상자: 키보드는 KeyCode 이름(E, R), 게임패드는 버튼 이름, 터치는 key.touch.tap.
-- 건설비 줄(2026-11-15 플레이테스트): 서버 Attribute CostEnergy, CostWater(숫자), BuildDays(일), Affordable(bool),
-- LockMsg(JSON Msg)가 있으면 행동 줄 아래에 에너지, 물 아이콘과 숫자, 건설 일수를 보이고, 살 수 없으면 모자란 숫자를
-- 빨갛게(ClientMath.costShortfall), 잠김이면 그 사유를 한 줄 더 쓴다. 자원이 바뀌면(StateUpdate) 색을 다시 맞춘다.
-- 패널 높이는 줄 수에 따라 바뀌고, 쌓을 때는 위 패널의 실제 높이만큼 내린다.
-- 안전: 패널 만들기와 글자 갱신은 보호 호출이라 한 프롬프트의 오류가 다른 프롬프트나 페이드 인을 막지 않는다(오류는 warn).
-- 디버그(2026-11-15 C5): workspace Attribute DebugPrompts = true(서버에서 켜면 복제)이면 PromptShown/Hidden 수신,
-- 그리기 결과, 그리고 2초마다 내 캐릭터 16 stud 안의 MissionRuntime 프롬프트 상태(Enabled, 거리, 키, 그려졌는지)를 출력한다.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local Msg = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Msg"))

local Icons = require(script.Parent.Icons)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local L = UI.Luna

local PromptUI = {}

local PANEL_WIDTH = 260
local PANEL_HEIGHT = 72 -- 최소 높이 (물체, 행동 두 줄)
local KEY_BOX = 44
local TEXT_LEFT = 70
local TEXT_PAD = 8 -- 글자 묶음 위아래 여백
local OBJECT_ROW = 18
local ACTION_ROW = 26
local COST_ROW = 22
local COST_ICON = 16
local LOCK_ROW = 30 -- 잠김 사유 (두 줄까지, 넘치면 글자를 줄인다)
local BAR_GAP = 4
local BAR_HEIGHT = 6
local FADE_SECONDS = 0.15
local ANCHOR_GAP = 4
local MAX_PANEL_HEIGHT = PANEL_HEIGHT + COST_ROW + LOCK_ROW
local MAX_VISIBLE = 2
local COOLDOWN_TICK = 0.25
local COST_ATTRIBUTES = { "CostEnergy", "CostWater", "BuildDays", "Affordable", "LockMsg" }
local DEBUG_ATTRIBUTE = "DebugPrompts"
local DEBUG_SCAN_SECONDS = 2
local DEBUG_SCAN_RADIUS = 16

local active = {} -- { [ProximityPrompt] = entry }
local order = {} -- PromptShown 순서의 프롬프트 목록

local function debugOn()
    return workspace:GetAttribute(DEBUG_ATTRIBUTE) == true
end

local function debugLog(...)
    if debugOn() then
        print("[PromptUI]", ...)
    end
end

local function promptName(prompt)
    local ok, name = pcall(function()
        return prompt:GetFullName()
    end)
    return if ok then name else tostring(prompt)
end

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

-- JSON 문자열 Attribute를 Msg로 (형식이 틀리면 nil)
local function decodeMsg(value)
    local decoded = decodeArgs(value)
    if decoded and Msg.isMsg(decoded) then
        return decoded
    end
    return nil
end

-- 양수 숫자 Attribute (없거나 0 이하면 nil)
local function positive(prompt, name)
    local value = prompt:GetAttribute(name)
    if type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

-- 패널 하나가 차지하는 높이 (패널 + 홀드 바)
local function stackHeight(entry)
    return entry.height + BAR_GAP + BAR_HEIGHT
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
    local offset = ANCHOR_GAP
    for slot, prompt in ipairs(list) do
        local entry = active[prompt]
        local target = UDim2.new(0.5, 0, 0.5, offset)
        entry.offsetY = offset
        offset += stackHeight(entry)
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

    -- 건설비 줄과 잠김 사유
    local energy = positive(prompt, "CostEnergy")
    local water = positive(prompt, "CostWater")
    local days = positive(prompt, "BuildDays")
    local lock = decodeMsg(prompt:GetAttribute("LockMsg"))
    local state = Session.state
    local short = ClientMath.costShortfall(
        { energy = energy, water = water },
        state and state.resources,
        prompt:GetAttribute("Affordable"),
        lock ~= nil
    )
    local cost = entry.cost
    cost.energy.Visible = energy ~= nil
    cost.water.Visible = water ~= nil
    cost.days.Visible = days ~= nil
    if energy then
        UI.raw(cost.energyNumber, ClientMath.formatAmount(energy))
        cost.energyNumber.TextColor3 = if short.energy then L.red else L.white
    end
    if water then
        UI.raw(cost.waterNumber, ClientMath.formatAmount(water))
        cost.waterNumber.TextColor3 = if short.water then L.red else L.white
    end
    if days then
        UI.msg(cost.days, Msg.count("unit.day", ClientMath.wholeNumber(days)))
    end
    local hasCost = energy ~= nil or water ~= nil or days ~= nil
    cost.row.Visible = hasCost
    entry.lock.Visible = lock ~= nil
    if lock then
        UI.msg(entry.lock, lock)
    else
        UI.msg(entry.lock, nil)
    end

    -- 줄 수에 맞춘 패널 높이. 바뀌면 다시 쌓는다
    local textHeight = (if entry.object.Visible then OBJECT_ROW else 0)
        + ACTION_ROW
        + (if hasCost then COST_ROW else 0)
        + (if lock then LOCK_ROW else 0)
    local height = math.max(PANEL_HEIGHT, textHeight + 2 * TEXT_PAD)
    if height ~= entry.height then
        entry.height = height
        entry.panel.Size = UDim2.new(1, 0, 0, height)
        entry.holdBar.root.Position = UDim2.fromOffset(0, height + BAR_GAP)
        entry.group.Size = UDim2.fromOffset(PANEL_WIDTH, height + BAR_GAP + BAR_HEIGHT)
        if active[prompt] == entry then
            relayout()
        end
    end
end

-- 글자 갱신 보호 호출 (오류가 나도 패널은 보이고, 원인은 warn으로 남긴다)
local function safeRefresh(prompt, entry)
    local ok, err = pcall(refreshTexts, prompt, entry)
    if not ok then
        warn("[PromptUI] 글자 갱신 실패 " .. promptName(prompt) .. ": " .. tostring(err))
    end
end

-- 건설비 줄 (아이콘 + 숫자 묶음 둘, 일수). 글자는 refreshTexts가 채운다
local function makeCostRow()
    local function amount(kind, layoutOrder)
        local icon = Icons.resource(kind, COST_ICON)
        icon.LayoutOrder = 1
        local number = UI.create("TextLabel", {
            Name = "Number",
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, COST_ROW),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.RoundHeavy,
            TextSize = 16,
            TextColor3 = L.white,
            Text = "",
        }, { UI.worldStroke() })
        local holder = UI.create("Frame", {
            Name = "Cost_" .. kind,
            LayoutOrder = layoutOrder,
            Size = UDim2.fromOffset(0, COST_ROW),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            Visible = false,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, 3),
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Center,
            }),
            icon,
            number,
        })
        return holder, number
    end
    local energy, energyNumber = amount("energy", 1)
    local water, waterNumber = amount("water", 2)
    local days = UI.create("TextLabel", {
        Name = "Days",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, COST_ROW),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.label,
        Text = "",
        Visible = false,
    }, { UI.worldStroke() })
    local row = UI.create("Frame", {
        Name = "CostRow",
        LayoutOrder = 3,
        Size = UDim2.new(1, 0, 0, COST_ROW),
        BackgroundTransparency = 1,
        Visible = false,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        energy,
        water,
        days,
    })
    return {
        row = row,
        energy = energy,
        energyNumber = energyNumber,
        water = water,
        waterNumber = waterNumber,
        days = days,
    }
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
        debugLog("이미 그림", promptName(prompt))
        return
    end
    local adornee, extra = getAdornee(prompt)
    if not adornee then
        debugLog("부모가 Part나 Attachment가 아님", promptName(prompt))
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
        Size = UDim2.new(1, 0, 0, OBJECT_ROW),
        Font = UI.Font,
        TextColor3 = L.label,
        Text = "",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, { UI.worldStroke() })
    UI.scaledText(objectLabel, 15, 10)
    local actionLabel = UI.create("TextLabel", {
        Name = "ActionText",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, ACTION_ROW),
        Font = UI.FontBold,
        TextColor3 = L.white,
        Text = "",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, { UI.worldStroke() })
    UI.scaledText(actionLabel, 20, 12)
    local cost = makeCostRow()
    local lockLabel = UI.create("TextLabel", {
        Name = "LockText",
        LayoutOrder = 4,
        Size = UDim2.new(1, 0, 0, LOCK_ROW),
        Font = UI.FontBold,
        TextColor3 = L.orange,
        Text = "",
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
    }, { UI.worldStroke() })
    UI.scaledText(lockLabel, 13, 9)

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
            cost.row,
            lockLabel,
        }),
    })
    local holdBar = UI.progressBar(L.mint, BAR_HEIGHT)
    holdBar.root.Position = UDim2.fromOffset(0, PANEL_HEIGHT + BAR_GAP)
    holdBar.root.Visible = prompt.HoldDuration > 0

    local scale = UI.create("UIScale", { Scale = 0.9 })
    local group = UI.create("CanvasGroup", {
        Name = "Group",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0.5, ANCHOR_GAP),
        Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT + BAR_GAP + BAR_HEIGHT),
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
            2 * (ANCHOR_GAP + MAX_VISIBLE * (MAX_PANEL_HEIGHT + BAR_GAP + BAR_HEIGHT) + 20)
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
        cost = cost,
        lock = lockLabel,
        panel = panel,
        height = PANEL_HEIGHT,
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
    safeRefresh(prompt, entry)
    debugLog("그림", promptName(prompt), "->", gui:GetFullName())

    local function refresh()
        safeRefresh(prompt, entry)
    end
    for _, name in ipairs({ "ActionKey", "ObjectKey", "ActionArgs", "ObjectArgs", "CooldownUntil" }) do
        table.insert(entry.conns, prompt:GetAttributeChangedSignal(name):Connect(refresh))
    end
    for _, name in ipairs(COST_ATTRIBUTES) do
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
                safeRefresh(prompt, entry)
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

-- 디버그: 내 캐릭터 가까이의 MissionRuntime 프롬프트 상태 (Enabled인데 "shown"이 안 오면 엔진이 보이지 않기로 한 것)
local function debugScan()
    local character = Players.LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local runtime = workspace:FindFirstChild("MissionRuntime")
    local camera = workspace.CurrentCamera
    print(
        "[PromptUI] scan service.Enabled",
        ProximityPromptService.Enabled,
        "MaxPromptsVisible",
        ProximityPromptService.MaxPromptsVisible,
        "camera",
        camera and camera.CameraType.Name,
        "root",
        root and tostring(root.Position) or "없음",
        "그린 수",
        #order
    )
    if not root or not runtime then
        return
    end
    for _, prompt in ipairs(runtime:GetDescendants()) do
        if prompt:IsA("ProximityPrompt") then
            local pos = getWorldPosition(prompt)
            local dist = pos and (pos - root.Position).Magnitude
            if dist and dist <= DEBUG_SCAN_RADIUS then
                print(
                    "[PromptUI]  ",
                    promptName(prompt),
                    "Enabled",
                    prompt.Enabled,
                    "Style",
                    prompt.Style.Name,
                    string.format("dist %.1f / max %.1f", dist, prompt.MaxActivationDistance),
                    "key",
                    prompt.KeyboardKeyCode.Name,
                    "excl",
                    prompt.Exclusivity.Name,
                    "그려짐",
                    active[prompt] ~= nil
                )
            end
        end
    end
end

function PromptUI.init(_ctx)
    ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
        debugLog("shown 수신", promptName(prompt), inputType and inputType.Name)
        local ok, err = xpcall(show, debug.traceback, prompt, inputType)
        if not ok then
            warn("[PromptUI] 그리기 실패 " .. promptName(prompt) .. ": " .. tostring(err))
        end
    end)

    task.spawn(function()
        while true do
            task.wait(DEBUG_SCAN_SECONDS)
            if debugOn() then
                local ok, err = pcall(debugScan)
                if not ok then
                    warn("[PromptUI] 디버그 스캔 실패: " .. tostring(err))
                end
            end
        end
    end)

    -- 자원이 바뀌면 건설비 숫자 색을 다시 맞춘다
    Session.changed:Connect(function(what)
        if what ~= "state" then
            return
        end
        for prompt, entry in pairs(active) do
            if entry.alive and entry.cost.row.Visible then
                safeRefresh(prompt, entry)
            end
        end
    end)

    ProximityPromptService.PromptHidden:Connect(function(prompt)
        debugLog("hidden 수신", promptName(prompt))
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

-- 화면에 보이는 프롬프트 패널의 화면 사각형 { x0, y0, x1, y1 } (ScreenGui 좌표, 위쪽 inset 제외).
-- 건물 안내 카드가 프롬프트를 가리지 않게 쓴다 (BuildingInfoUI)
function PromptUI.screenRects()
    local rects = {}
    local camera = workspace.CurrentCamera
    if not camera then
        return rects
    end
    for _, entry in pairs(active) do
        local gui = entry.gui
        local adornee = gui and gui.Adornee
        if entry.alive and entry.slot and gui.Enabled and adornee then
            local base = if adornee:IsA("BasePart")
                then adornee.Position
                elseif adornee:IsA("Attachment") then adornee.WorldPosition
                else nil
            if base then
                local point, onScreen = camera:WorldToScreenPoint(base + gui.StudsOffsetWorldSpace)
                if onScreen then
                    local top = point.Y + (entry.offsetY or ANCHOR_GAP)
                    table.insert(rects, {
                        x0 = point.X - PANEL_WIDTH / 2,
                        y0 = top,
                        x1 = point.X + PANEL_WIDTH / 2,
                        y1 = top + stackHeight(entry),
                    })
                end
            end
        end
    end
    return rects
end

return PromptUI
