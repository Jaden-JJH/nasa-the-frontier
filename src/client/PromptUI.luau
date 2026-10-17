--!nonstrict
-- 커스텀 ProximityPrompt UI. 서버가 Style = Custom으로 둔 프롬프트를 HUD와 같은 디자인으로 그린다.
-- 패널은 앵커 아래쪽으로 뻗는다 (모듈 표지판은 앵커 위쪽으로 뻗어 서로 겹치지 않음).

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local PromptUI = {}

local PANEL_WIDTH = 220
local PANEL_HEIGHT = 72
local BAR_HEIGHT = 6
local FADE_SECONDS = 0.15
local ANCHOR_GAP = 4

local active = {} -- { [ProximityPrompt] = entry }

local function getKeyText(prompt, inputType)
    if inputType == Enum.ProximityPromptInputType.Touch then
        return "탭"
    elseif inputType == Enum.ProximityPromptInputType.Gamepad then
        return "A"
    end
    local text = UserInputService:GetStringForKeyCode(prompt.KeyboardKeyCode)
    if text == "" then
        text = prompt.KeyboardKeyCode.Name
    end
    return text
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

local function refreshTexts(prompt, entry)
    local objectText = prompt.ObjectText
    entry.object.Text = objectText
    entry.object.Visible = objectText ~= ""
    entry.action.Text = prompt.ActionText
end

local function destroyEntry(prompt, entry)
    active[prompt] = nil
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
        Preset = "heading",
        Text = getKeyText(prompt, inputType),
    })
    local objectLabel = UI.create("TextLabel", {
        Name = "ObjectText",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 18),
        Preset = "caption",
        Text = "",
        TextColor3 = Colors.textDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, { UI.worldStroke() })
    local actionLabel = UI.create("TextLabel", {
        Name = "ActionText",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 26),
        Preset = "heading",
        Text = "",
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, { UI.worldStroke() })

    local panel = UI.create("Frame", {
        Name = "Panel",
        Size = UDim2.new(1, 0, 0, PANEL_HEIGHT),
        BackgroundColor3 = Colors.panel,
        BackgroundTransparency = 0.12,
    }, {
        UI.corner(12),
        UI.stroke(Colors.panelLight, 1.5),
        UI.create("Frame", {
            Name = "KeyIcon",
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 14, 0.5, 0),
            Size = UDim2.fromOffset(44, 44),
            BackgroundColor3 = Colors.panelLight,
        }, { UI.corner(8), UI.stroke(Colors.textDim, 1.5, 0.3), keyLabel }),
        UI.create("Frame", {
            Name = "Texts",
            Position = UDim2.fromOffset(70, 0),
            Size = UDim2.new(1, -82, 1, 0),
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
    local holdBar = UI.progressBar(Colors.energy, BAR_HEIGHT)
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
        Size = UDim2.fromOffset(PANEL_WIDTH + 20, (PANEL_HEIGHT + 20) * 2),
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
        holdBar = holdBar,
        holdTween = nil,
        conns = {},
    }
    active[prompt] = entry
    refreshTexts(prompt, entry)

    table.insert(
        entry.conns,
        prompt:GetPropertyChangedSignal("ActionText"):Connect(function()
            refreshTexts(prompt, entry)
        end)
    )
    table.insert(
        entry.conns,
        prompt:GetPropertyChangedSignal("ObjectText"):Connect(function()
            refreshTexts(prompt, entry)
        end)
    )
    table.insert(
        entry.conns,
        prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
            holdBar.root.Visible = prompt.HoldDuration > 0
        end)
    )

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
        table.insert(
            entry.conns,
            button.InputBegan:Connect(function(input)
                if
                    input.UserInputType == Enum.UserInputType.Touch
                    or input.UserInputType == Enum.UserInputType.MouseButton1
                then
                    prompt:InputHoldBegin()
                end
            end)
        )
        table.insert(
            entry.conns,
            button.InputEnded:Connect(function(input)
                if
                    input.UserInputType == Enum.UserInputType.Touch
                    or input.UserInputType == Enum.UserInputType.MouseButton1
                then
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
