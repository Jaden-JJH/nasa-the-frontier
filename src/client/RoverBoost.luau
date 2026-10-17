--!nonstrict
-- 로버 부스터 입력. DriverSeat에 앉아 있을 때만 동작한다.
-- 키보드 LeftShift, 게임패드 ButtonX, 터치는 "부스터" 홀드 버튼. 누름과 뗌에 RoverBoost(true/false)를 보낸다.
-- RoverBoost Remote는 서버가 만들기 전일 수 있으므로 늦게 찾고, 없으면 조용히 아무것도 보내지 않는다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local RoverBoost = {}

local player = Players.LocalPlayer
local remote = nil
local driving = false
local held = false -- 현재 서버에 true를 보낸 상태
local touchButton
local changed = Instance.new("BindableEvent")
RoverBoost.drivingChanged = changed.Event

local function send(on)
    if held == on then
        return
    end
    held = on
    if remote then
        remote:FireServer(on)
    end
end

local function isDriverSeat(seat)
    return seat ~= nil and seat:IsA("VehicleSeat") and seat.Name == "DriverSeat"
end

local function setDriving(value)
    if driving == value then
        return
    end
    driving = value
    if not value then
        send(false) -- 하차하면 false 1회
    end
    if touchButton then
        touchButton.Visible = value
    end
    changed:Fire(value)
end

local function watchCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not humanoid then
        return
    end
    setDriving(isDriverSeat(humanoid.SeatPart))
    humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
        setDriving(isDriverSeat(humanoid.SeatPart))
    end)
    humanoid.Died:Connect(function()
        setDriving(false)
    end)
end

function RoverBoost.isDriving()
    return driving
end

function RoverBoost.init(_ctx)
    task.spawn(function()
        local folder = ReplicatedStorage:WaitForChild("Remotes", 30)
        remote = folder and folder:WaitForChild("RoverBoost", 30)
    end)

    UserInputService.InputBegan:Connect(function(input)
        if not driving then
            return
        end
        if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonX then
            send(true)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonX then
            send(false)
        end
    end)

    -- 터치 기기 전용 홀드 버튼: 레이더 오른쪽 옆
    if UI.isTouchOnly() then
        local gui = UI.gui("RoverBoost", 13)
        touchButton = UI.create("TextButton", {
            Name = "BoostButton",
            Position = UDim2.fromOffset(12 + 180 + 10, 128 + 26),
            Size = UDim2.fromOffset(96, 56),
            BackgroundColor3 = Colors.oxygen,
            TextColor3 = Colors.bg,
            Text = "부스터",
            Preset = "heading",
            Visible = false,
            Parent = gui,
        }, { UI.corner(10) })
        touchButton.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then
                send(true)
            end
        end)
        touchButton.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then
                send(false)
            end
        end)
    end

    if player.Character then
        task.spawn(watchCharacter, player.Character)
    end
    player.CharacterAdded:Connect(watchCharacter)
end

return RoverBoost
