--!nonstrict
-- 얼음 레이더. 로버 DriverSeat에 앉아 있을 때만 보인다.
-- 로버의 앞쪽이 레이더 위쪽. 중심이 로버, 가장자리가 Config.RADAR_RANGE.
-- 비프음은 에셋 id 없이 만들 수 없어서 넣지 않았다.

local Players = game:GetService("Players")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local RadarUI = {}

local RADAR_SIZE = 180
local DOT_MARGIN = 8
local TICK_SECONDS = 0.1
local DOT_FAR_SIZE = 6
local DOT_NEAR_MIN = 10
local DOT_NEAR_MAX = 28
local AMOUNT_RANGE = 60 -- 이 거리 안이면 매장량 숫자를 표시
local HARD_COLOR = Color3.fromRGB(255, 150, 50)

local player = Players.LocalPlayer
local config
local gui
local dotsFrame
local distanceLabel
local enabled = false
local dots = {} -- { [BasePart] = Frame }

local function getDriverSeat()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local seat = humanoid and humanoid.SeatPart
    if seat and seat:IsA("VehicleSeat") and seat.Name == "DriverSeat" then
        return seat
    end
    return nil
end

local function getDot(part)
    local dot = dots[part]
    if dot then
        return dot
    end
    dot = UI.create("Frame", {
        Name = "IceDot",
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Colors.water,
        Parent = dotsFrame,
    }, {
        UI.roundCorner(),
        UI.create("TextLabel", {
            Name = "Amount",
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(1, 2, 0.5, 0),
            Size = UDim2.fromOffset(32, 12),
            Text = "",
            TextColor3 = Colors.text,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            Visible = false,
        }),
        UI.create("TextLabel", {
            Name = "Mark",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(12, 12),
            Text = "x",
            TextColor3 = Colors.neutral,
            TextSize = 12,
            Visible = false,
        }),
    })
    dots[part] = dot
    return dot
end

local function step()
    local seat = if enabled then getDriverSeat() else nil
    gui.Enabled = seat ~= nil
    if not seat then
        return
    end

    local iceFolder = workspace:FindFirstChild("IceSites")
    local range = config.RADAR_RANGE
    local rimRadius = RADAR_SIZE / 2 - DOT_MARGIN

    -- 로버 앞쪽(수평)과 오른쪽 벡터
    local look = seat.CFrame.LookVector
    local forward = Vector3.new(look.X, 0, look.Z)
    if forward.Magnitude < 0.001 then
        forward = Vector3.new(0, 0, -1)
    end
    forward = forward.Unit
    local right = forward:Cross(Vector3.yAxis)

    local seen = {}
    local nearest = math.huge
    local nearestDeposit = nil
    local hasSites = false
    if iceFolder then
        for _, part in ipairs(iceFolder:GetChildren()) do
            if part:IsA("BasePart") then
                hasSites = true
                seen[part] = true
                local offset = part.Position - seat.Position
                local ahead = offset:Dot(forward)
                local side = offset:Dot(right)
                local distance = math.sqrt(ahead * ahead + side * side)

                -- Deposit Attribute가 없으면 기존처럼 남은 지점으로 취급
                local deposit = part:GetAttribute("Deposit")
                local depleted = type(deposit) == "number" and deposit <= 0
                if not depleted and distance < nearest then
                    nearest = distance
                    nearestDeposit = if type(deposit) == "number" then deposit else nil
                end

                local inRange = distance <= range
                local ratio = math.min(distance / range, 1)
                local dirX, dirY = 0, 0
                if distance > 0.001 then
                    dirX, dirY = side / distance, -ahead / distance -- 화면 y는 아래가 +
                end

                local dot = getDot(part)
                local amountLabel = dot.Amount
                dot.Mark.Visible = depleted
                amountLabel.Visible = false
                local size
                if depleted then
                    -- 고갈: 작은 회색 x
                    size = 12
                    dot.BackgroundTransparency = 1
                elseif inRange then
                    size = DOT_NEAR_MIN + (1 - ratio) * (DOT_NEAR_MAX - DOT_NEAR_MIN)
                    dot.BackgroundTransparency = 0
                    dot.BackgroundColor3 = if part:GetAttribute("Difficulty") == "hard"
                        then HARD_COLOR
                        else Colors.water
                else
                    size = DOT_FAR_SIZE
                    dot.BackgroundTransparency = 0.6
                    dot.BackgroundColor3 = Colors.neutral
                end
                if not depleted and type(deposit) == "number" and distance <= AMOUNT_RANGE then
                    amountLabel.Visible = true
                    amountLabel.Text = tostring(math.floor(deposit + 0.5))
                end
                dot.Size = UDim2.fromOffset(size, size)
                dot.Position =
                    UDim2.new(0.5, dirX * ratio * rimRadius, 0.5, dirY * ratio * rimRadius)
            end
        end
    end

    for part, dot in pairs(dots) do
        if not seen[part] then
            dot:Destroy()
            dots[part] = nil
        end
    end

    if nearest == math.huge then
        distanceLabel.Text = if hasSites
            then "남은 얼음 지점 없음"
            else "얼음 지점 탐색 중"
    elseif nearestDeposit then
        distanceLabel.Text = string.format(
            "가장 가까운 얼음 %d studs, 매장량 %d",
            math.floor(nearest + 0.5),
            math.floor(nearestDeposit + 0.5)
        )
    else
        distanceLabel.Text =
            string.format("가장 가까운 얼음 %d studs", math.floor(nearest + 0.5))
    end
end

function RadarUI.init(ctx)
    config = ctx.Config
    gui = UI.gui("Radar", 12)
    gui.Enabled = false

    dotsFrame = UI.create("Frame", {
        Name = "Dots",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    })
    distanceLabel = UI.create("TextLabel", {
        Name = "Distance",
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, 22),
        Text = "",
        TextColor3 = Colors.water,
        Preset = "caption",
    })

    UI.create("Frame", {
        Name = "RadarRoot",
        AnchorPoint = if UI.isTouchOnly() then Vector2.new(0, 0) else Vector2.new(0, 1),
        -- 모바일은 좌상단 자원 패널(약 y 12~120) 아래, PC는 좌하단
        Position = if UI.isTouchOnly() then UDim2.fromOffset(12, 128) else UDim2.new(0, 16, 1, -16),
        Size = UDim2.fromOffset(RADAR_SIZE, RADAR_SIZE + 26),
        BackgroundTransparency = 1,
        Parent = gui,
    }, {
        distanceLabel,
        UI.create("Frame", {
            Name = "Circle",
            Position = UDim2.fromOffset(0, 26),
            Size = UDim2.fromOffset(RADAR_SIZE, RADAR_SIZE),
            BackgroundColor3 = Colors.bg,
            BackgroundTransparency = 0.15,
        }, {
            UI.roundCorner(),
            UI.stroke(Colors.water, 2, 0.3),
            -- 절반 거리 링
            UI.create("Frame", {
                Name = "HalfRing",
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromScale(0.5, 0.5),
                BackgroundTransparency = 1,
            }, { UI.roundCorner(), UI.stroke(Colors.panelLight, 1, 0.2) }),
            UI.create("TextLabel", {
                Name = "ForwardMark",
                AnchorPoint = Vector2.new(0.5, 0),
                Position = UDim2.new(0.5, 0, 0, 2),
                Size = UDim2.fromOffset(24, 14),
                Text = "앞",
                TextColor3 = Colors.textDim,
                Preset = "caption",
            }),
            dotsFrame,
            -- 중심 점 (로버)
            UI.create("Frame", {
                Name = "CenterDot",
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromOffset(8, 8),
                BackgroundColor3 = Colors.text,
                ZIndex = 3,
            }, { UI.roundCorner() }),
        }),
    })

    task.spawn(function()
        while true do
            task.wait(TICK_SECONDS)
            local ok, err = pcall(step)
            if not ok then
                warn("[RadarUI] " .. tostring(err))
            end
        end
    end)
end

-- Main이 phase에 따라 켜고 끈다. 실제 표시는 DriverSeat 착석 여부로 결정.
function RadarUI.setEnabled(value)
    enabled = value
    if not value then
        gui.Enabled = false
    end
end

return RadarUI
