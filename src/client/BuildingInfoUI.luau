--!nonstrict
-- 건물 안내 카드 (2026-11-15 플레이테스트 C3). 내 캐릭터가 기지 건물에서 SHOW_DISTANCE(14 stud) 안에 들어가면 가장 가까운
-- 건물 하나의 이름, 쉬운 설명(info.<id>.desc), 지금 상태(짓는 중 N일, 가동, 멈춤, 자원 부족 정지, 잠김과 해금 방법),
-- 하루 유지비를 보인다. 건물을 바꾸거나 멀어지면 서서히 사라지고 나타난다.
-- 건물: 착륙선, 에어록, 태양광 필드, 그린하우스(짓기 전에는 착공 자리)와 업그레이드 3종, 물탱크, 물 파이프(짓기 전에는
-- 착공 자리), 로버 주차장, 기지 출구.
-- 거리: MissionRuntime(Base, Facilities, InteractionPoints, CONTRACT_V2 7.5) 모델의 경계 상자까지 수평 거리(ClientMath.rectDistance).
-- StreamingEnabled라 건물이 클라이언트에 없을 수 있다. 그러면 StateUpdate mapPoints(표시 중심)에서 FALLBACK_HALF 반폭으로 잰다.
-- 상태 판정은 ClientMath.buildingInfo, 고르기는 ClientMath.pickNearest(HYSTERESIS로 두 건물 사이 깜빡임 방지).
-- 위치: PC는 왼쪽 아래(HUD, 프롬프트, 산소 바, Tip과 겹치지 않는 자리), compact는 오른쪽 위 HUD 열 아래.
-- Main.applyScreens가 setVisible로 플레이 중이고 콘솔, 결과, 역할 선택 화면이 닫혀 있을 때만 허용한다. 운전 중에도 숨긴다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))

local HUDV2 = require(script.Parent.HUDV2)
local Icons = require(script.Parent.Icons)
local Layout = require(script.Parent.Layout)
local PromptUI = require(script.Parent.PromptUI)
local RoverBoost = require(script.Parent.RoverBoost)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local WorldPoints = require(script.Parent.WorldPoints)
local L = UI.Luna

local BuildingInfoUI = {}

local SHOW_DISTANCE = 14 -- stud, 건물 경계 상자까지
local HYSTERESIS = 2
local SCAN_SECONDS = 1 -- 건물 경계 상자를 다시 읽는 간격 (짓는 연출로 바뀐다)
local TICK_SECONDS = 0.2
local FALLBACK_HALF = 6 -- 모델이 없을 때 표시 중심 둘레 반폭
local FADE_IN = 0.2
local FADE_OUT = 0.15
local PROMPT_MARGIN = 8 -- 프롬프트 패널과 이만큼 가까워도 카드를 숨긴다 (px)
local CHARGE_KEEP = MissionConfig.MANUAL_DRIVE.chargeKeepEnergy
local PC = { width = 290, margin = 16, name = 18, body = 14, small = 13 }
local COMPACT = { width = 240, margin = 12, name = 16, body = 13, small = 12 }

-- 리터럴 키 표 (I18N_PLAN 4.2)
local NAMES = {
    lander = "world.lander.name",
    airlock = "facility.airlock.name",
    solar = "world.solar_field.name",
    farm = "facility.farm.name",
    led = "facility.led.name",
    nutrient = "facility.nutrient.name",
    hydroponics = "facility.hydroponics.name",
    tank = "world.water_tank.name",
    pipe = "facility.pipe.name",
    roverpark = "world.rover_park.name",
    exit = "world.exit.name",
}
local DESCS = {
    lander = "info.lander.desc",
    airlock = "info.airlock.desc",
    solar = "info.solar_field.desc",
    farm = "info.farm.desc",
    led = "info.led.desc",
    nutrient = "info.nutrient.desc",
    hydroponics = "info.hydroponics.desc",
    tank = "info.water_tank.desc",
    pipe = "info.pipe.desc",
    roverpark = "info.rover_park.desc",
    exit = "info.exit.desc",
}
-- MissionRuntime.Base 모델 이름 -> 안내 id (MissionWorld.placeBase)
local BASE_MODELS = {
    LanderShelter = "lander",
    AirlockShelter = "airlock",
    SolarField = "solar",
    WaterTank = "tank",
    RoverPark = "roverpark",
    BaseExit = "exit",
}
-- 모델 전체 대신 이 자식의 경계 상자를 쓴다 (물탱크 모델은 하역 자리와 파이프 자리까지 품는다)
local BASE_PARTS = { WaterTank = "Visual" }
-- 따로 재는 상호작용 자리 (짓기 전 시설 자리). 건물 자체로 치지 않아서 표시 대체를 막지 않는다
local SPOT_MODELS = { FarmSite = "farm" } -- Base 아래 모델 (재배 공간 착공 자리)
local SPOT_PARTS = { PipeSpot = "pipe" } -- Base 모델 안 파트 (물탱크 뒤 파이프 착공 자리)
local UPGRADE_SPOT_PREFIX = "UpgradeSpot_"
-- 표시 이름 -> 안내 id. 그 건물 모델을 못 찾았으면(스트리밍, 짓기 전 그린하우스) Mission<id> 표시 파트의 상자,
-- 그것도 없으면 StateUpdate mapPoints 중심으로 잰다
local MAP_POINTS = {
    Lander = "lander",
    Airlock = "airlock",
    SolarField = "solar",
    FarmPad = "farm",
    WaterTank = "tank",
    RoverPark = "roverpark",
    BaseExit = "exit",
}
local TONE_COLORS = {
    neutral = L.label,
    locked = L.faint,
    available = L.sky,
    building = L.gold,
    inspecting = L.gold,
    idle = L.gold,
    active = L.mint,
    paused = L.orange,
    stalled = L.red,
}
local DETAIL_COLORS = { locked = L.orange, stalled = L.red, paused = L.orange }

local gui
local root
local group
local nameLabel
local descLabel
local statusPill
local statusLabel
local detailLabel
local upkeepRow
local upkeepEnergy
local upkeepEnergyNumber
local upkeepWater
local upkeepWaterNumber

local allowed = false
local boxes = {} -- { { id, cframe, halfX, halfZ } }
local currentId = nil -- 지금 카드에 그린 건물
local shown = false
local fadeToken = 0
local lastState = nil

local function sizes()
    return if Layout.isCompact() then COMPACT else PC
end

-- 경계 상자 (모델은 스트리밍된 파트만, 비면 nil)
local function boxOf(inst)
    if not inst or not inst.Parent then
        return nil
    end
    if inst:IsA("BasePart") then
        return inst.CFrame, inst.Size
    elseif inst:IsA("Model") then
        local ok, cf, size = pcall(function()
            return inst:GetBoundingBox()
        end)
        if ok and cf and size and size.Magnitude > 0.05 then
            return cf, size
        end
    end
    return nil
end

local function addBox(list, id, inst)
    local cf, size = boxOf(inst)
    if cf then
        table.insert(list, { id = id, cframe = cf, halfX = size.X / 2, halfZ = size.Z / 2 })
    end
end

local function hasFarm(state)
    local facilities = type(state) == "table" and state.facilities or nil
    local farm = type(facilities) == "table" and facilities.farm or nil
    return type(farm) == "table" and farm.status ~= "locked" and farm.status ~= "available"
end

-- MissionRuntime에서 건물 경계 상자를 모은다
local function scan()
    local list = {}
    local found = {}
    local runtime = WorldPoints.runtime()
    local base = runtime and runtime:FindFirstChild("Base")
    if base then
        for _, model in ipairs(base:GetChildren()) do
            local id = BASE_MODELS[model.Name]
            if id then
                local partName = BASE_PARTS[model.Name]
                local target = partName and model:FindFirstChild(partName) or model
                local before = #list
                addBox(list, id, target)
                found[id] = found[id] or #list > before
            end
            local spotModelId = SPOT_MODELS[model.Name]
            if spotModelId then
                addBox(list, spotModelId, model)
            end
            for spotName, spotId in pairs(SPOT_PARTS) do
                local spot = model:FindFirstChild(spotName)
                if spot then
                    addBox(list, spotId, spot)
                end
            end
        end
    end
    local facilities = runtime and runtime:FindFirstChild("Facilities")
    if facilities then
        for _, model in ipairs(facilities:GetChildren()) do
            local defId = model:GetAttribute("DefId")
            if type(defId) == "string" and NAMES[defId] then
                -- 파이프 모델은 얼음 지점까지 관로를 품으므로 물탱크 옆 연결관만 잰다
                local target = if defId == "pipe" then model:FindFirstChild("TankPipe") else model
                if target then
                    local before = #list
                    addBox(list, defId, target)
                    found[defId] = found[defId] or #list > before
                end
            end
        end
    end
    -- 업그레이드 착공 자리는 그린하우스를 착공한 뒤에만 (그 전에는 프롬프트도 꺼져 있다)
    local points = runtime and runtime:FindFirstChild("InteractionPoints")
    if points and hasFarm(lastState or Session.state) then
        for _, part in ipairs(points:GetChildren()) do
            local defId = string.match(part.Name, "^" .. UPGRADE_SPOT_PREFIX .. "(%a+)$")
            if defId and NAMES[defId] then
                addBox(list, defId, part)
            end
        end
    end
    -- 모델이 없는 건물은 표시 파트 상자, 그것도 없으면 표시 중심으로 대신 잰다
    local markers = WorldPoints.missionFolder(Session.missionId())
    for markerName, id in pairs(MAP_POINTS) do
        if not found[id] then
            local before = #list
            addBox(list, id, markers and markers:FindFirstChild(markerName))
            local position = if #list == before then WorldPoints.marker(markerName) else nil
            if position then
                table.insert(list, {
                    id = id,
                    cframe = CFrame.new(position),
                    halfX = FALLBACK_HALF,
                    halfZ = FALLBACK_HALF,
                })
            end
        end
    end
    boxes = list
end

local function distances(position)
    local out = {}
    for _, box in ipairs(boxes) do
        local localPos = box.cframe:PointToObjectSpace(position)
        local d = ClientMath.rectDistance(localPos.X, localPos.Z, box.halfX, box.halfZ)
        if out[box.id] == nil or d < out[box.id] then
            out[box.id] = d
        end
    end
    return out
end

-- 카드 글자를 지금 건물과 상태로 다시 그린다
local function render(id)
    local state = lastState or Session.state
    UI.msg(nameLabel, NAMES[id] or "world.placeholder.name")
    UI.msg(descLabel, DESCS[id])
    local info = ClientMath.buildingInfo(id, state, Session.missionDef(), {
        keep = CHARGE_KEEP,
        localDriving = RoverBoost.isDriving(),
    })
    statusPill.Visible = info.status ~= nil
    if info.status then
        UI.msg(statusLabel, info.status)
        statusPill.BackgroundColor3 = TONE_COLORS[info.tone] or TONE_COLORS.neutral
    end
    detailLabel.Visible = info.detail ~= nil
    if info.detail then
        UI.msg(detailLabel, info.detail)
        detailLabel.TextColor3 = DETAIL_COLORS[info.tone] or L.soft
    else
        UI.msg(detailLabel, nil)
    end
    local upkeep = info.upkeep
    upkeepRow.Visible = upkeep ~= nil
    if upkeep then
        upkeepEnergy.Visible = upkeep.energy > 0
        upkeepWater.Visible = upkeep.water > 0
        UI.raw(upkeepEnergyNumber, ClientMath.formatAmount(upkeep.energy))
        UI.raw(upkeepWaterNumber, ClientMath.formatAmount(upkeep.water))
    end
end

local function fadeTo(visible, id)
    fadeToken += 1
    local token = fadeToken
    if visible then
        local changing = shown and currentId ~= id
        currentId = id -- 고르기 이력 현상과 다음 tick 비교는 바로 새 건물로 한다
        local function fadeIn()
            if token ~= fadeToken then
                return
            end
            render(id)
            group.Visible = true
            TweenService:Create(group, TweenInfo.new(FADE_IN), { GroupTransparency = 0 }):Play()
        end
        if changing then
            -- 다른 건물: 잠깐 사라졌다가 새 글자로 나타난다
            local out =
                TweenService:Create(group, TweenInfo.new(FADE_OUT), { GroupTransparency = 1 })
            out.Completed:Once(fadeIn)
            out:Play()
        else
            fadeIn()
        end
        shown = true
    else
        shown = false
        local out = TweenService:Create(group, TweenInfo.new(FADE_OUT), { GroupTransparency = 1 })
        out.Completed:Once(function()
            if token == fadeToken then
                group.Visible = false
                currentId = nil
            end
        end)
        out:Play()
    end
end

local function applyLayout()
    if not group then
        return
    end
    local s = sizes()
    group.Size = UDim2.fromOffset(s.width, 0)
    nameLabel.TextSize = s.name
    descLabel.TextSize = s.body
    statusLabel.TextSize = s.small
    detailLabel.TextSize = s.small
    if Layout.isCompact() then
        -- 오른쪽 위 HUD 열(로버, 배터리 칩) 바로 아래. 왼쪽은 토스트와 미션 문구가 쓴다
        local column = HUDV2.getRightColumn()
        local y = if column and column.AbsoluteSize.Y > 0
            then Layout.below(root, column, 8)
            else s.margin
        group.AnchorPoint = Vector2.new(1, 0)
        group.Position = UDim2.new(1, -s.margin, 0, y)
    else
        group.AnchorPoint = Vector2.new(0, 1)
        group.Position = UDim2.new(0, s.margin, 1, -s.margin)
    end
end

-- 카드 자리가 화면의 프롬프트 패널과 겹치는지 (겹치면 잠깐 숨긴다, "프롬프트를 가리지 않는다")
local function coversPrompt()
    local size = group.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then
        return false
    end
    local pos = group.AbsolutePosition
    local card = { x0 = pos.X, y0 = pos.Y, x1 = pos.X + size.X, y1 = pos.Y + size.Y }
    for _, rect in ipairs(PromptUI.screenRects()) do
        if ClientMath.rectsOverlap(card, rect, PROMPT_MARGIN) then
            return true
        end
    end
    return false
end

local function tick()
    local want = nil
    local state = lastState or Session.state
    local playing = type(state) == "table" and state.phase == "playing"
    if allowed and playing and not RoverBoost.isDriving() then
        local position = WorldPoints.character(Players.LocalPlayer)
        if position then
            want = ClientMath.pickNearest(distances(position), SHOW_DISTANCE, currentId, HYSTERESIS)
        end
    end
    if want and coversPrompt() then
        want = nil
    end
    if want then
        if not shown or want ~= currentId then
            fadeTo(true, want)
        end
        if Layout.isCompact() then
            applyLayout() -- HUD 열 높이가 바뀌면 따라간다
        end
    elseif shown then
        fadeTo(false)
    end
end

function BuildingInfoUI.init(_ctx)
    gui = UI.gui("BuildingInfo", 12, false) -- Tip(14), 사실 카드(13)보다 아래
    root = Layout.root(gui)

    nameLabel = UI.create("TextLabel", {
        Name = "Name",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.RoundHeavy,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    descLabel = UI.create("TextLabel", {
        Name = "Desc",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextColor3 = L.body,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    statusLabel = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromOffset(0, 22),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextColor3 = L.inkDeep,
    })
    statusPill = UI.create("Frame", {
        Name = "Status",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, 22),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.mint,
        Visible = false,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }), statusLabel })
    detailLabel = UI.create("TextLabel", {
        Name = "Detail",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextColor3 = L.soft,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
    })

    local function amount(kind, order)
        local icon = Icons.resource(kind, 16)
        icon.LayoutOrder = 1
        local number = UI.create("TextLabel", {
            Name = "Number",
            LayoutOrder = 2,
            Size = UDim2.fromOffset(0, 20),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.RoundHeavy,
            TextSize = 15,
            TextColor3 = L.white,
        })
        local holder = UI.create("Frame", {
            Name = "Upkeep_" .. kind,
            LayoutOrder = order,
            Size = UDim2.fromOffset(0, 20),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, 3),
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Center,
            }),
            icon,
            number,
        })
        return holder, number
    end
    local upkeepLabel = UI.create("TextLabel", {
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 13,
        TextColor3 = L.dim,
    })
    UI.msg(upkeepLabel, "map.fac.upkeep")
    upkeepEnergy, upkeepEnergyNumber = amount("energy", 2)
    upkeepWater, upkeepWaterNumber = amount("water", 3)
    upkeepRow = UI.create("Frame", {
        Name = "Upkeep",
        LayoutOrder = 5,
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Visible = false,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        upkeepLabel,
        upkeepEnergy,
        upkeepWater,
    })

    local card = UI.create("Frame", {
        Name = "Card",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = L.bgTop,
        BackgroundTransparency = 0.12,
    }, {
        UI.corner(14),
        UI.stroke(L.white, 1.5, UI.LUNA_STROKE_TRANSPARENCY),
        UI.padding({ 10, 12, 14, 14 }),
        UI.list(Enum.FillDirection.Vertical, 5),
        nameLabel,
        descLabel,
        statusPill,
        detailLabel,
        upkeepRow,
    })
    group = UI.create("CanvasGroup", {
        Name = "Group",
        Size = UDim2.fromOffset(PC.width, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
        Parent = root,
    }, { card })

    applyLayout()
    Layout.changed:Connect(applyLayout)

    task.spawn(function()
        local lastScan = -math.huge
        while true do
            local ok, err = pcall(function()
                if os.clock() - lastScan >= SCAN_SECONDS then
                    lastScan = os.clock()
                    scan()
                end
                tick()
            end)
            if not ok then
                warn("[BuildingInfoUI] " .. tostring(err))
            end
            task.wait(TICK_SECONDS)
        end
    end)
end

-- StateUpdate: 지금 카드의 상태 줄을 다시 그린다 (같은 Msg면 Localizer가 건너뛴다)
function BuildingInfoUI.update(state)
    if type(state) ~= "table" then
        return
    end
    lastState = state
    if shown and currentId then
        render(currentId)
    end
end

-- 화면 허용 (Main.applyScreens: 플레이 중이고 콘솔, 결과, 역할 선택이 닫혀 있을 때)
function BuildingInfoUI.setVisible(visible)
    allowed = visible == true
    if not allowed and shown then
        fadeTo(false)
    end
end

return BuildingInfoUI
