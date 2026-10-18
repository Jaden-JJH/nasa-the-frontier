--!nonstrict
-- 클라이언트 2D 효과음. 카탈로그는 Shared.SoundIds이고 id가 0이면 Sound를 만들지 않는다.
-- SoundService 전체 볼륨은 건드리지 않고, 기본 캐릭터 발소리와 점프 소리도 그대로 둔다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local SoundIds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundIds"))

local SoundFX = {}

local LOW_OXYGEN = 20
local BREATH_FADE = 0.6
local SELF_BOOST = 1.25 -- 자기 로버 승하차는 서버 3D 소리보다 조금 크게

local player = Players.LocalPlayer
local folder
local breathSound = nil -- 호흡 루프 Sound
local clickConnected = {} -- { [GuiButton] = true }

local playing = false
local oxygen, oxygenMax, inside = nil, nil, true
local lowFired = false
local seated = false
local lastStage = nil
local breathStopThread = nil

local function makeSound(key, volumeScale)
    local spec = SoundIds[key]
    if not spec or spec.id == 0 then
        return nil
    end
    local sound = Instance.new("Sound")
    sound.Name = key
    sound.SoundId = "rbxassetid://" .. tostring(spec.id)
    sound.Volume = math.clamp(spec.volume * (volumeScale or 1), 0, 1)
    sound.Looped = spec.loop
    if spec.pitchJitter > 0 then
        sound.PlaybackSpeed = 1 + (math.random() * 2 - 1) * spec.pitchJitter
    end
    sound.Parent = folder
    return sound
end

function SoundFX.play(key, volumeScale)
    local sound = makeSound(key, volumeScale)
    if not sound then
        return
    end
    sound.Ended:Once(function()
        sound:Destroy()
    end)
    sound:Play()
end

-- 카탈로그 볼륨 대신 지정한 절대 볼륨(0..1)으로 재생
function SoundFX.playVolume(key, volume)
    local spec = SoundIds[key]
    if not spec or spec.id == 0 then
        return
    end
    SoundFX.play(key, volume / math.max(spec.volume, 0.01))
end

-- 산소 호흡 루프: 실외에서만, 산소가 낮을수록 크게
local function applyBreath()
    local target = 0
    if playing and not inside and not seated and oxygen and oxygenMax and oxygenMax > 0 then
        target = 0.15 + (1 - math.clamp(oxygen / oxygenMax, 0, 1)) * 0.35
    end

    local sound = breathSound
    if target > 0 then
        if breathStopThread then
            task.cancel(breathStopThread)
            breathStopThread = nil
        end
        if not sound then
            sound = makeSound("oxygen_breath_loop")
            if not sound then
                return
            end
            sound.Volume = 0
            breathSound = sound
        end
        if not sound.IsPlaying then
            sound:Play()
        end
        TweenService:Create(sound, TweenInfo.new(BREATH_FADE), { Volume = target }):Play()
    elseif sound and sound.IsPlaying and not breathStopThread then
        TweenService:Create(sound, TweenInfo.new(BREATH_FADE), { Volume = 0 }):Play()
        breathStopThread = task.delay(BREATH_FADE, function()
            breathStopThread = nil
            if sound.Parent then
                sound:Stop()
            end
        end)
    end
end

local function connectButton(button)
    if clickConnected[button] or button.Name == "TouchArea" then
        return
    end
    clickConnected[button] = true
    button.Activated:Connect(function()
        SoundFX.play("ui_click")
    end)
    button.Destroying:Once(function()
        clickConnected[button] = nil
    end)
end

local function watchCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not humanoid then
        return
    end
    local function isDriverSeat(seat)
        return seat ~= nil and seat:IsA("VehicleSeat") and seat.Name == "DriverSeat"
    end
    local wasDriving = isDriverSeat(humanoid.SeatPart)
    seated = humanoid.SeatPart ~= nil
    humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
        seated = humanoid.SeatPart ~= nil
        local driving = isDriverSeat(humanoid.SeatPart)
        if driving and not wasDriving then
            SoundFX.play("rover_board", SELF_BOOST)
        elseif wasDriving and not driving then
            SoundFX.play("rover_exit", SELF_BOOST)
        end
        wasDriving = driving
        applyBreath()
    end)
end

function SoundFX.init(_ctx)
    folder = Instance.new("Folder")
    folder.Name = "SoundFX"
    folder.Parent = SoundService

    -- 모든 버튼 클릭음
    local playerGui = player:WaitForChild("PlayerGui")
    for _, descendant in ipairs(playerGui:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            connectButton(descendant)
        end
    end
    playerGui.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("GuiButton") then
            connectButton(descendant)
        end
    end)

    if player.Character then
        task.spawn(watchCharacter, player.Character)
    end
    player.CharacterAdded:Connect(watchCharacter)
end

-- StateUpdate: 미션 전진음과 호흡 루프의 playing 여부
function SoundFX.onState(state)
    playing = state.phase == "playing"
    local stage = state.missionStage
    if stage ~= nil and lastStage ~= nil and stage ~= lastStage then
        SoundFX.play("mission_advance")
    end
    if stage ~= nil then
        lastStage = stage
    end
    if state.phase == "selecting" then
        lastStage = nil
    end
    applyBreath()
end

function SoundFX.onOxygen(value, max, isInside)
    oxygen, oxygenMax, inside = value, max, isInside
    if value <= LOW_OXYGEN then
        if not lowFired then
            lowFired = true
            SoundFX.play("oxygen_low_beep")
        end
    else
        lowFired = false
    end
    applyBreath()
end

function SoundFX.onNotify(_text, kind)
    if kind == "warn" then
        SoundFX.play("notify_warn")
    elseif kind == "good" then
        SoundFX.play("notify_good")
    end
end

function SoundFX.onGameOver(result)
    playing = false
    applyBreath()
    SoundFX.play(if result.won then "win" else "lose")
end

return SoundFX
