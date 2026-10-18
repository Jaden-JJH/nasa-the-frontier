--!nonstrict
-- 해상도 대응 공통 레이아웃. 화면 높이에 비례한 배율(0.7 ~ 1.25)을 계산하고,
-- 각 ScreenGui 안에 "가상 캔버스" 루트를 만들어 준다. 루트는 크기가 화면의 1/배율이고 UIScale이 배율이라
-- 화면 전체를 덮으며, 그 안의 오프셋 좌표는 배율만큼 커지거나 작아진다(UIScale의 위치 처리 방식에 의존하지 않는다).
-- 터치 전용 기기나 높이 600 미만이면 compact(압축 배치)로 본다.

local UI = require(script.Parent.UI)

local Layout = {}

local MIN_SCALE = 0.7
local MAX_SCALE = 1.25
local BASE_HEIGHT = 720
local COMPACT_HEIGHT = 600

local roots = {} -- { { frame, uiScale } }
local changed = Instance.new("BindableEvent")
Layout.changed = changed.Event

local cameraConn = nil

local function viewportSize()
    local camera = workspace.CurrentCamera
    return if camera then camera.ViewportSize else Vector2.new(1280, 720)
end

function Layout.scale()
    return math.clamp(viewportSize().Y / BASE_HEIGHT, MIN_SCALE, MAX_SCALE)
end

function Layout.isCompact()
    return viewportSize().Y < COMPACT_HEIGHT or UI.isTouchOnly()
end

local function applyAll()
    local scale = Layout.scale()
    for _, root in ipairs(roots) do
        root.uiScale.Scale = scale
        root.frame.Size = UDim2.fromScale(1 / scale, 1 / scale)
    end
    changed:Fire(scale, Layout.isCompact())
end

local function watchCamera()
    if cameraConn then
        cameraConn:Disconnect()
        cameraConn = nil
    end
    local camera = workspace.CurrentCamera
    if camera then
        cameraConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyAll)
    end
    applyAll()
end

local watching = false
local function ensureWatching()
    if watching then
        return
    end
    watching = true
    workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
    watchCamera()
end

-- ScreenGui 안에 스케일되는 루트 프레임을 만든다. 이 프레임의 자식으로 UI를 붙인다.
function Layout.root(gui)
    ensureWatching()
    local uiScale = UI.create("UIScale", { Scale = Layout.scale() })
    local scale = uiScale.Scale
    local frame = UI.create("Frame", {
        Name = "Root",
        Size = UDim2.fromScale(1 / scale, 1 / scale),
        BackgroundTransparency = 1,
        Parent = gui,
    }, { uiScale })
    table.insert(roots, { frame = frame, uiScale = uiScale })
    return frame
end

-- rootFrame 기준(가상 좌표)으로 target 프레임 하단 + gap의 y 오프셋. 두 프레임의 화면 좌표 차이로 계산한다.
function Layout.below(rootFrame, target, gap)
    return (target.AbsolutePosition.Y + target.AbsoluteSize.Y - rootFrame.AbsolutePosition.Y)
            / Layout.scale()
        + gap
end

return Layout
