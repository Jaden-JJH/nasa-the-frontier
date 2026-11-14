--!nonstrict
-- 로버 충전 표지 (2026-11-15 플레이테스트: 충전이 보이지 않는다). 기지에 세운 로버 섀시 위에 작은 BillboardGui를 띄운다.
-- 첫 줄: 배터리 아이콘, 막대, 퍼센트. 둘째 줄: 충전 중, 가득 참, 또는 충전이 안 되는 이유
-- (기지 에너지가 MANUAL_DRIVE.chargeKeepEnergy 이하면 "기지 에너지가 20 이하이면 충전이 멈춰요"로 풀어 쓴다).
-- 값은 섀시(MissionRuntime.Rover의 PrimaryPart "Chassis") Attribute Charging, BatteryPercent, ChargeBlocked를 먼저 쓰고
-- (StateUpdate보다 자주 바뀐다), 없으면 StateUpdate rover(charging, battery, batteryMax, atBase, chargeBlocked)를 쓴다.
-- 판정은 ClientMath.roverChargeView. MaxDistance(60 stud) 안에서만 보인다.
-- 플레이 중이고, 로버가 기지에 있고(rover.atBase), 자율주행과 고장이 아니고, 내가 운전석이 아닐 때만 켠다.
-- StreamingEnabled라 로버 모델이 없을 수 있다. 그러면 아무것도 하지 않는다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Icons = require(script.Parent.Icons)
local RoverBoost = require(script.Parent.RoverBoost)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local WorldPoints = require(script.Parent.WorldPoints)
local L = UI.Luna

local RoverChargeSign = {}

local CHARGE_KEEP = MissionConfig.MANUAL_DRIVE.chargeKeepEnergy
local MAX_DISTANCE = 60 -- stud
local WIDTH = 210
local HEIGHT = 70
local BAR_WIDTH = 110
local ABOVE = 2.5 -- 로버 모델 윗면에서 더 띄우는 높이 (stud)
local SCAN_SECONDS = 0.5 -- 로버 모델을 다시 찾는 간격
local LOW_RATIO = 0.2
local ATTRIBUTES = { "Charging", "BatteryPercent", "ChargeBlocked" }

local gui
local fill
local percentLabel
local stateLabel
local chassis = nil
local chassisConns = {}
local lastState = nil

local function fillColor(view)
    if view.mode == "charging" then
        return L.gold
    elseif view.mode == "full" then
        return L.mint
    elseif view.percent / 100 < LOW_RATIO or view.reason == "energy" then
        return L.red
    end
    return L.orange
end

local function textColor(view)
    if view.mode == "charging" then
        return L.gold
    elseif view.mode == "full" then
        return L.mint
    elseif view.reason == "energy" then
        return L.red
    end
    return L.orange
end

-- 섀시 Attribute (없거나 형식이 틀리면 nil)
local function attribute(name, kind)
    local part = chassis
    if not part or not part.Parent then
        return nil
    end
    local value = part:GetAttribute(name)
    if type(value) ~= kind then
        return nil
    end
    if kind == "string" and value == "" then
        return nil
    end
    return value
end

local function refresh()
    if not gui then
        return
    end
    local state = lastState or Session.state
    local rover = type(state) == "table" and state.rover or nil
    local playing = type(state) == "table" and state.phase == "playing"
    if not playing or type(rover) ~= "table" or not chassis or not chassis.Parent then
        gui.Enabled = false
        return
    end
    local charging = attribute("Charging", "boolean")
    if charging == nil then
        charging = rover.charging
    end
    local resources = type(state.resources) == "table" and state.resources or {}
    local view = ClientMath.roverChargeView({
        status = rover.state,
        atBase = rover.atBase,
        charging = charging,
        battery = rover.battery,
        batteryMax = rover.batteryMax,
        percent = attribute("BatteryPercent", "number") or rover.batteryPercent,
        blocked = attribute("ChargeBlocked", "string") or rover.chargeBlocked,
        serverReasons = type(rover.batteryPercent) == "number"
            or attribute("BatteryPercent", "number") ~= nil,
        energy = resources.energy,
        keep = CHARGE_KEEP,
        localDriving = RoverBoost.isDriving(),
    })
    local label = ClientMath.chargeLabel(view, CHARGE_KEEP, true)
    if label == nil then
        -- 숨김, 운전 중, 기지 밖
        gui.Enabled = false
        return
    end
    gui.Enabled = true
    fill.Size = UDim2.fromScale(view.percent / 100, 1)
    fill.BackgroundColor3 = fillColor(view)
    UI.msg(percentLabel, { key = "unit.percent", args = { n = view.percent } })
    UI.msg(stateLabel, label)
    stateLabel.TextColor3 = textColor(view)
end

-- 로버 모델 윗면 위에 오도록 섀시 기준 높이를 맞춘다
local function placeAbove(model, part)
    local ok, cf, size = pcall(function()
        return model:GetBoundingBox()
    end)
    local top = if ok and cf then cf.Position.Y + size.Y / 2 else part.Position.Y + part.Size.Y / 2
    gui.StudsOffsetWorldSpace = Vector3.new(0, math.max(top - part.Position.Y, 0) + ABOVE, 0)
end

local function setChassis(model)
    local part = nil
    if model then
        part = model.PrimaryPart or model:FindFirstChild("Chassis")
        if part and not part:IsA("BasePart") then
            part = nil
        end
    end
    if part == chassis then
        if part and model then
            placeAbove(model, part)
        end
        return
    end
    for _, conn in ipairs(chassisConns) do
        conn:Disconnect()
    end
    chassisConns = {}
    chassis = part
    gui.Adornee = part
    if part then
        placeAbove(model, part)
        for _, name in ipairs(ATTRIBUTES) do
            table.insert(chassisConns, part:GetAttributeChangedSignal(name):Connect(refresh))
        end
    end
    refresh()
end

function RoverChargeSign.init(_ctx)
    local bar = UI.create("Frame", {
        Name = "Bar",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(BAR_WIDTH, 10),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.8,
    }, { UI.corner(4) })
    fill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = L.mint,
        Parent = bar,
    }, { UI.corner(4) })
    percentLabel = UI.create("TextLabel", {
        Name = "Percent",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(44, 22),
        FontFace = UI.RoundHeavy,
        TextSize = 17,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, { UI.worldStroke() })
    local icon = Icons.resource("battery", 20)
    icon.LayoutOrder = 1
    local top = UI.create("Frame", {
        Name = "Top",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
        }),
        icon,
        bar,
        percentLabel,
    })
    stateLabel = UI.create("TextLabel", {
        Name = "State",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 30),
        Font = UI.FontBold,
        TextColor3 = L.gold,
        TextWrapped = true,
    }, { UI.worldStroke() })
    UI.scaledText(stateLabel, 14, 9)

    local panel = UI.create("Frame", {
        Name = "Panel",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.15,
    }, {
        UI.corner(12),
        UI.stroke(L.white, 1.5, UI.LUNA_STROKE_TRANSPARENCY),
        UI.padding({ 6, 6, 10, 10 }),
        UI.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center),
        top,
        stateLabel,
    })
    gui = UI.create("BillboardGui", {
        Name = "RoverChargeSign",
        AlwaysOnTop = true,
        LightInfluence = 0,
        ResetOnSpawn = false,
        MaxDistance = MAX_DISTANCE,
        Size = UDim2.fromOffset(WIDTH, HEIGHT),
        StudsOffsetWorldSpace = Vector3.new(0, 6, 0),
        Enabled = false,
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
    }, { panel })

    RoverBoost.drivingChanged:Connect(refresh)
    task.spawn(function()
        while true do
            local ok, err = pcall(function()
                setChassis(WorldPoints.roverModel())
            end)
            if not ok then
                warn("[RoverChargeSign] " .. tostring(err))
            end
            task.wait(SCAN_SECONDS)
        end
    end)
end

function RoverChargeSign.update(state)
    if type(state) ~= "table" then
        return
    end
    lastState = state
    refresh()
end

return RoverChargeSign
