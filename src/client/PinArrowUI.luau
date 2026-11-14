--!nonstrict
-- 관제사 핀 화살표 A안 (V2_PLAN 15.3, 목업 https://claude.ai/artifact/D6knXD7jorqgZ2TmyALxAy).
-- 관제사가 콘솔 지도에서 얼음 후보지에 핀을 찍으면(PinUpdate) 탐사대원 화면에:
-- - 목표가 화면 밖(또는 카메라 뒤)이면 화면 가장자리에 그쪽을 가리키는 민트 화살표와 "얼음 3  120 m"
-- - 화면 안이면 그 자리 위에 민트 마름모(흰 테두리)와 같은 라벨
-- 거리는 내 캐릭터에서 목표까지 수평 거리를 미터로(MissionConfig.metersPerStud, 서버 토스트와 같은 환산). 위치 계산은 ClientMath.edgeArrow.
-- 보일지는 Main.client가 정한다(멀티, 플레이 중, 관제사가 아닌 역할, 핀 있음, GST 아님, 콘솔 닫힘).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local Icons = require(script.Parent.Icons)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local WorldPoints = require(script.Parent.WorldPoints)
local L = UI.Luna

local PinArrowUI = {}

local EDGE_MARGIN = 56 -- px. 화살표가 화면 가장자리에서 들어오는 거리
local ARROW_SIZE = 44
local DIAMOND_SIZE = 22
local TARGET_HEIGHT = 6 -- studs. 목표 지점 위로 띄우는 높이
local LABEL_HEIGHT = 24

local gui
local arrowHolder
local arrowIcon
local arrowLabel
local diamondHolder
local diamondLabel
local active = false
local conn = nil

local function makeLabel(name)
    return UI.create("TextLabel", {
        Name = name,
        Size = UDim2.fromOffset(0, LABEL_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = Color3.fromRGB(10, 14, 40),
        BackgroundTransparency = 0.25,
        FontFace = UI.MonoBold,
        TextSize = 15,
        TextColor3 = L.white,
    }, { UI.corner(8), UI.padding({ 0, 0, 10, 10 }) })
end

local function targetPosition()
    local index = Session.pinSite
    if not index then
        return nil
    end
    local markerName = nil
    for _, site in ipairs(Session.state and Session.state.ice or {}) do
        if site.index == index then
            markerName = site.markerName
        end
    end
    return WorldPoints.iceSite(index, markerName, Session.missionId())
end

local function hideAll()
    arrowHolder.Visible = false
    diamondHolder.Visible = false
end

local function update()
    local camera = workspace.CurrentCamera
    local target, hasHeight = targetPosition()
    if not camera or not target then
        hideAll()
        return
    end
    local me = WorldPoints.character(Players.LocalPlayer) or camera.CFrame.Position
    if not hasHeight then
        -- 먼 얼음 후보지는 스트리밍 전이라 서버 좌표(X, Z)만 있다. 높이는 내 높이로 둔다
        target = Vector3.new(target.X, me.Y, target.Z)
    end
    local meters =
        ClientMath.toMeters(ClientMath.horizontalDistance(me, target), MissionConfig.metersPerStud)
    local label = {
        key = "map.pin.label",
        args = { site = { key = "map.ice.label", args = { n = Session.pinSite } }, meters = meters },
    }
    local point = camera:WorldToViewportPoint(target + Vector3.new(0, TARGET_HEIGHT, 0))
    local viewport = camera.ViewportSize
    local arrow =
        ClientMath.edgeArrow(point.X, point.Y, point.Z > 0, viewport.X, viewport.Y, EDGE_MARGIN)
    if arrow.onScreen then
        arrowHolder.Visible = false
        diamondHolder.Visible = true
        diamondHolder.Position = UDim2.fromOffset(arrow.x, arrow.y)
        UI.msg(diamondLabel, label)
    else
        diamondHolder.Visible = false
        arrowHolder.Visible = true
        arrowHolder.Position = UDim2.fromOffset(arrow.x, arrow.y)
        arrowIcon.Rotation = arrow.angle
        UI.msg(arrowLabel, label)
        -- 라벨은 화살표 안쪽(화면 중심 쪽)에 둔다. 아래 가장자리면 위로, 아니면 아래로
        local below = arrow.y < viewport.Y / 2 + 1
        arrowLabel.AnchorPoint = if below then Vector2.new(0.5, 0) else Vector2.new(0.5, 1)
        arrowLabel.Position = if below then UDim2.new(0.5, 0, 1, 2) else UDim2.new(0.5, 0, 0, -2)
    end
end

function PinArrowUI.init(_ctx)
    gui = UI.gui("PinArrow", 12)
    gui.Enabled = false

    arrowIcon = Icons.arrow(ARROW_SIZE)
    arrowIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    arrowIcon.Position = UDim2.fromScale(0.5, 0.5)
    arrowLabel = makeLabel("Label")
    arrowHolder = UI.create("Frame", {
        Name = "EdgeArrow",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = gui,
    }, { arrowIcon, arrowLabel })

    local diamond = UI.create("Frame", {
        Name = "Diamond",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 1),
        Size = UDim2.fromOffset(DIAMOND_SIZE, DIAMOND_SIZE),
        Rotation = 45,
        BackgroundColor3 = L.mint,
    }, { UI.create("UIStroke", { Color = L.white, Thickness = 3 }) })
    diamondLabel = makeLabel("Label")
    diamondLabel.AnchorPoint = Vector2.new(0.5, 1)
    diamondLabel.Position = UDim2.new(0.5, 0, 1, -DIAMOND_SIZE)
    diamondHolder = UI.create("Frame", {
        Name = "Diamond",
        AnchorPoint = Vector2.new(0.5, 1),
        Size = UDim2.fromOffset(DIAMOND_SIZE * 2, DIAMOND_SIZE * 2),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = gui,
    }, { diamond, diamondLabel })
end

function PinArrowUI.setActive(value)
    if value == active then
        return
    end
    active = value
    gui.Enabled = value
    if value then
        conn = RunService.RenderStepped:Connect(update)
        update()
    else
        if conn then
            conn:Disconnect()
            conn = nil
        end
        hideAll()
    end
end

return PinArrowUI
