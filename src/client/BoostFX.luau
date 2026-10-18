--!nonstrict
-- 부스터 체감 효과(운전자 본인): 카메라 FOV 확대, 화면 가장자리 하늘색 비네트, 과열 순간 빨간 플래시.
-- state.rover.boosting과 boostHeat가 nil이면 아무것도 하지 않는다.

local RoverBoost = require(script.Parent.RoverBoost)
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local BoostFX = {}

local FOV_BOOST = 12
local FOV_IN = 0.25
local FOV_OUT = 0.4
local VIGNETTE_TRANSPARENCY = 0.75
local VIGNETTE_FADE = 0.2
local EDGE_SIZE = 110

local baseFov = 70
local fovApplied = false
local fovTween = nil
local boosting = false
local lastHeat = 0
local edges = {}
local flash

local function setFov(target, seconds)
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    if fovTween then
        fovTween:Cancel()
        fovTween = nil
    end
    if seconds <= 0 then
        camera.FieldOfView = target
        return
    end
    fovTween = TweenService:Create(
        camera,
        TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { FieldOfView = target }
    )
    fovTween:Play()
end

local function setVignette(on)
    for _, edge in ipairs(edges) do
        TweenService:Create(
            edge,
            TweenInfo.new(VIGNETTE_FADE),
            { BackgroundTransparency = if on then VIGNETTE_TRANSPARENCY else 1 }
        ):Play()
    end
end

local function redFlash()
    flash.BackgroundTransparency = 0.6
    TweenService
        :Create(flash, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 })
        :Play()
end

local function setBoosting(value)
    if value == boosting then
        return
    end
    boosting = value
    setVignette(value)
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    if value then
        if not fovApplied then
            baseFov = camera.FieldOfView
            fovApplied = true
        end
        setFov(baseFov + FOV_BOOST, FOV_IN)
    elseif fovApplied then
        fovApplied = false
        setFov(baseFov, if RoverBoost.isDriving() then FOV_OUT else 0)
    end
end

local function makeEdge(name, anchor, position, size, rotation)
    return UI.create("Frame", {
        Name = name,
        AnchorPoint = anchor,
        Position = position,
        Size = size,
        BackgroundColor3 = Colors.water,
        BackgroundTransparency = 1,
        Interactable = false,
    }, {
        UI.create("UIGradient", {
            Rotation = rotation,
            Transparency = NumberSequence.new(0, 1),
        }),
    })
end

function BoostFX.init(_ctx)
    local gui = UI.gui("BoostFX", 9)
    edges = {
        makeEdge(
            "Top",
            Vector2.new(0, 0),
            UDim2.fromScale(0, 0),
            UDim2.new(1, 0, 0, EDGE_SIZE),
            90
        ),
        makeEdge(
            "Bottom",
            Vector2.new(0, 1),
            UDim2.fromScale(0, 1),
            UDim2.new(1, 0, 0, EDGE_SIZE),
            -90
        ),
        makeEdge(
            "Left",
            Vector2.new(0, 0),
            UDim2.fromScale(0, 0),
            UDim2.new(0, EDGE_SIZE, 1, 0),
            0
        ),
        makeEdge(
            "Right",
            Vector2.new(1, 0),
            UDim2.fromScale(1, 0),
            UDim2.new(0, EDGE_SIZE, 1, 0),
            180
        ),
    }
    for _, edge in ipairs(edges) do
        edge.Parent = gui
    end
    flash = UI.create("Frame", {
        Name = "OverheatFlash",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Colors.bad,
        BackgroundTransparency = 1,
        Interactable = false,
        Parent = gui,
    })

    -- 하차 시 즉시 복귀
    RoverBoost.drivingChanged:Connect(function(driving)
        if not driving then
            setBoosting(false)
        end
    end)
end

function BoostFX.update(state)
    local rover = state and state.rover
    local heat = rover and rover.boostHeat
    if type(heat) ~= "number" then
        setBoosting(false)
        return
    end
    setBoosting(RoverBoost.isDriving() and rover.boosting == true)
    -- 과열로 막히는 순간 빨간 플래시
    if RoverBoost.isDriving() and heat >= 0.98 and lastHeat < 0.98 then
        redFlash()
    end
    lastHeat = heat
end

return BoostFX
