--!nonstrict
-- 대피처 실내 방 로컬 숨김 (2026-11-15 Studio: 에어록 실내 방이 바깥에서 큰 회색 상자로 보여 캡슐 에셋을 덮었다).
-- 서버 MissionWorld가 만든 실내 방 모델(태그 "ShelterInterior")을 카메라가 그 방 안(상자 + MARGIN)에 있을 때만 보이고,
-- 밖이면 모든 파트의 LocalTransparencyModifier를 1로 둔다. 충돌은 그대로라 카메라(Popper)는 벽 앞으로 당겨져 방 안으로 들어온다.
-- 에셋 모듈은 반지름 약 5인 원통이라 바닥이 기초 판인 방이 다 들어가지 못하므로, 바깥 모습은 이 숨김이 지킨다.
-- 방 상자는 모델 GetBoundingBox(벽과 천장 바깥 면), 판정은 ClientMath.insideBox. StreamingEnabled라 모델이 없을 수 있다.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))

local InteriorView = {}

local TAG = "ShelterInterior" -- MissionWorld.CONFIG.interior.tag
local MARGIN = 0.3 -- stud, 벽 두께 언저리에서 깜빡이지 않게
local CHECK_SECONDS = 0.1

local clock = 0

-- 매번 모든 파트에 쓴다 (스트리밍으로 나중에 들어온 파트도 맞춘다. 방 하나에 파트 10개 정도)
local function apply(model, visible)
    local value = if visible then 0 else 1
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            d.LocalTransparencyModifier = value
        elseif d:IsA("Light") then
            d.Enabled = visible
        end
    end
end

local function cameraInside(model, camPos)
    local ok, cf, size = pcall(function()
        return model:GetBoundingBox()
    end)
    if not ok or not cf then
        return false
    end
    return ClientMath.insideBox(cf:PointToObjectSpace(camPos), size, MARGIN)
end

local function step(dt)
    clock += dt
    if clock < CHECK_SECONDS then
        return
    end
    clock = 0
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end
    local camPos = camera.CFrame.Position
    for _, model in ipairs(CollectionService:GetTagged(TAG)) do
        if model:IsA("Model") and model:IsDescendantOf(workspace) then
            apply(model, cameraInside(model, camPos))
        end
    end
end

function InteriorView.init()
    -- 새로 들어온 방은 바로 숨긴다 (다음 검사 전 한 프레임 비치지 않게)
    CollectionService:GetInstanceAddedSignal(TAG):Connect(function(model)
        if model:IsA("Model") then
            task.defer(apply, model, false)
        end
    end)
    RunService.RenderStepped:Connect(step)
end

return InteriorView
