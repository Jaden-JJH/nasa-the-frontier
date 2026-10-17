--!nonstrict
-- 로버 탑승 안내: 로버 12 studs 안에 처음 들어왔고 아직 탑승한 적이 없으면 토스트를 한 번만 띄운다.

local Players = game:GetService("Players")

local ToastUI = require(script.Parent.ToastUI)

local RoverHint = {}

local HINT_DISTANCE = 12
local CHECK_SECONDS = 0.5

local player = Players.LocalPlayer
local playing = false
local hinted = false
local hasRidden = false

local function step()
    if hinted or hasRidden or not playing then
        return
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then
        return
    end

    local seat = humanoid.SeatPart
    if seat and seat:IsA("VehicleSeat") and seat.Name == "DriverSeat" then
        hasRidden = true
        return
    end

    local base = workspace:FindFirstChild("Base")
    local rover = base and base:FindFirstChild("Rover")
    if not rover then
        return
    end
    local distance = (rover:GetPivot().Position - root.Position).Magnitude
    if distance <= HINT_DISTANCE then
        hinted = true
        ToastUI.push("E 키로 로버에 탑승하세요", "info")
    end
end

function RoverHint.init(_ctx)
    task.spawn(function()
        while true do
            task.wait(CHECK_SECONDS)
            local ok, err = pcall(step)
            if not ok then
                warn("[RoverHint] " .. tostring(err))
            end
        end
    end)
end

function RoverHint.onState(state)
    playing = state.phase == "playing"
end

return RoverHint
