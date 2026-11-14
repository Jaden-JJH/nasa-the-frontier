--!nonstrict
-- 착륙 연출: 착륙선 상공 200 studs에서 뒤쪽 25 studs, 위 10 studs 지점으로 내려온다.
-- v2: LandingSequence(missionId, landerCFrame, seconds?). seconds가 없으면 DEFAULT_SECONDS.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)

local LandingCamera = {}

local START_HEIGHT = 200 -- 시작 높이 (착륙선 위)
local START_BACK = 30 -- 시작 시 살짝 뒤쪽 (수직 시점 퇴화 방지)
local END_BACK = 25
local END_HEIGHT = 10
local BAR_HEIGHT_SCALE = 0.08
local INTRO_IMAGE_SECONDS = 1
local DEFAULT_SECONDS = 5 -- 서버가 연출 길이를 보내지 않을 때 (v1 Config.LANDING_SECONDS와 같은 값)

local player = Players.LocalPlayer
local introImageId = "" -- 조종석 정지 이미지 (지원 이미지가 오면 넣는다, 글자 없는 이미지)
local barsGui
local introImage -- 조종석 정지 이미지 (INTRO_IMAGE_ID가 있을 때만 사용)
local introGui
local activeToken = 0
local activeTween = nil
local activeValue = nil
local activeConn = nil
local running = false

local function restoreCamera()
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    camera.CameraType = Enum.CameraType.Custom
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        camera.CameraSubject = humanoid
    else
        -- 캐릭터가 아직 없으면 생길 때 한 번 맞춰 준다
        local conn
        conn = player.CharacterAdded:Connect(function(newCharacter)
            conn:Disconnect()
            local newHumanoid = newCharacter:WaitForChild("Humanoid", 5)
            if newHumanoid and not running then
                camera.CameraType = Enum.CameraType.Custom
                camera.CameraSubject = newHumanoid
            end
        end)
    end
end

local function cleanup()
    if activeConn then
        activeConn:Disconnect()
        activeConn = nil
    end
    if activeTween then
        activeTween:Cancel()
        activeTween = nil
    end
    if activeValue then
        activeValue:Destroy()
        activeValue = nil
    end
    barsGui.Enabled = false
    introGui.Enabled = false
end

-- 연출 중단 후 카메라 복구 (여러 번 불러도 안전)
function LandingCamera.stop()
    if not running then
        return
    end
    running = false
    activeToken += 1
    cleanup()
    restoreCamera()
end

function LandingCamera.play(_missionId, landerCFrame, seconds)
    local camera = workspace.CurrentCamera
    if not camera or typeof(landerCFrame) ~= "CFrame" then
        return
    end
    local duration = if type(seconds) == "number" and seconds > 0 then seconds else DEFAULT_SECONDS
    if running then
        activeToken += 1
        cleanup()
    end
    running = true
    activeToken += 1
    local token = activeToken

    local target = landerCFrame.Position
    local back = -landerCFrame.LookVector
    local startPos = target + Vector3.new(0, START_HEIGHT, 0) + back * START_BACK
    local endPos = target + back * END_BACK + Vector3.new(0, END_HEIGHT, 0)
    local startCFrame = CFrame.lookAt(startPos, target)
    local endCFrame = CFrame.lookAt(endPos, target)

    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = startCFrame
    barsGui.Enabled = true

    -- 시작 1초 동안 조종석 정지 이미지 (id가 비어 있으면 건너뜀)
    if introImage.Image ~= "" then
        introGui.Enabled = true
        task.delay(INTRO_IMAGE_SECONDS, function()
            if token == activeToken then
                introGui.Enabled = false
            end
        end)
    end

    local value = Instance.new("CFrameValue")
    value.Value = startCFrame
    activeValue = value
    activeConn = value.Changed:Connect(function(cf)
        camera.CFrame = cf
    end)

    local tween = TweenService:Create(
        value,
        TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
        { Value = endCFrame }
    )
    activeTween = tween
    tween.Completed:Connect(function()
        if token ~= activeToken then
            return
        end
        running = false
        cleanup()
        restoreCamera()
    end)
    tween:Play()
end

function LandingCamera.init(_ctx)
    -- 이미지는 검은 바보다 아래 순서
    introGui = UI.gui("LandingIntroImage", 89)
    introGui.Enabled = false
    introImage = UI.create("ImageLabel", {
        Name = "CockpitImage",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ScaleType = Enum.ScaleType.Crop,
        Image = introImageId,
        Parent = introGui,
    })

    barsGui = UI.gui("LandingBars", 90)
    barsGui.Enabled = false
    for _, top in ipairs({ true, false }) do
        UI.create("Frame", {
            Name = top and "TopBar" or "BottomBar",
            AnchorPoint = Vector2.new(0, top and 0 or 1),
            Position = UDim2.fromScale(0, top and 0 or 1),
            Size = UDim2.fromScale(1, BAR_HEIGHT_SCALE),
            BackgroundColor3 = Color3.new(0, 0, 0),
            Parent = barsGui,
        })
    end
end

return LandingCamera
