--!strict
-- 태양광 패널 설치: Base.SolarField.InstallPad 프롬프트, 하루 설치 제한, 슬롯에 패널 복제 (CONTRACT 3절)
-- 설치 연출 (2026-10-18): 홀드가 끝나면 패널이 슬롯 아래 PANEL_SINK_DEPTH에서 접힌 채(PANEL_FOLD_ANGLE)
-- 나타나 PANEL_UNFOLD_SECONDS 동안 올라오며 펼쳐진다 (ANIMATION_HZ로 PivotTo 보간).
-- 그동안 설치 프롬프트는 꺼지고 ActionText는 "설치 중"이다. 자원 반영은 홀드가 끝난 순간 바로 한다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)

local SolarPanels = {}

local prompt: ProximityPrompt? = nil
local slots: { BasePart } = {}
local panelsFolder: Folder? = nil
local connections: { RBXScriptConnection } = {}
local unfolding = 0 -- 펼치는 중인 패널 수 (0보다 크면 프롬프트를 끈다)
local generation = 0 -- detach마다 증가. 이전 기지의 연출 루프가 새 기지 상태를 건드리지 않게

-- Slots 폴더의 Slot1..SlotN을 번호 순서로 모은다
local function collectSlots(field: Instance): { BasePart }
    local result: { { index: number, part: BasePart } } = {}
    local folder = field:FindFirstChild("Slots")
    if folder then
        for _, child in folder:GetChildren() do
            local index = tonumber(string.match(child.Name, "^Slot(%d+)$"))
            if index and child:IsA("BasePart") then
                table.insert(result, { index = index, part = child })
            end
        end
    end
    table.sort(result, function(a, b)
        return a.index < b.index
    end)
    local parts: { BasePart } = {}
    for _, entry in result do
        table.insert(parts, entry.part)
    end
    return parts
end

-- 모델이나 파트를 슬롯 윗면에 올린다
local function placeOnTop(item: Instance, slot: BasePart)
    local slotTop = slot.CFrame * CFrame.new(0, slot.Size.Y / 2, 0)
    if item:IsA("Model") then
        local boxCFrame, boxSize = item:GetBoundingBox()
        local pivotInBox = boxCFrame:ToObjectSpace(item:GetPivot())
        item:PivotTo(slotTop * CFrame.new(0, boxSize.Y / 2, 0) * pivotInBox)
    elseif item:IsA("BasePart") then
        item.CFrame = slotTop * CFrame.new(0, item.Size.Y / 2, 0)
    end
end

local function pivotOf(item: Instance): CFrame
    if item:IsA("Model") then
        return item:GetPivot()
    elseif item:IsA("BasePart") then
        return item.CFrame
    end
    return CFrame.identity
end

local function setPivot(item: Instance, cframe: CFrame)
    if item:IsA("Model") then
        item:PivotTo(cframe)
    elseif item:IsA("BasePart") then
        item.CFrame = cframe
    end
end

-- 펼침 시작 자세: 최종 자세에서 슬롯 기준으로 PANEL_SINK_DEPTH 아래, 슬롯 x축으로 PANEL_FOLD_ANGLE 접힘
function SolarPanels.unfoldStart(final: CFrame, slot: BasePart): CFrame
    local slotTop = slot.CFrame * CFrame.new(0, slot.Size.Y / 2, 0)
    local sunk = slotTop * CFrame.new(0, -Config.PANEL_SINK_DEPTH, 0)
    local fold = CFrame.Angles(math.rad(Config.PANEL_FOLD_ANGLE), 0, 0)
    return sunk * fold * slotTop:ToObjectSpace(final)
end

-- 패널 하나를 시작 자세에서 최종 자세로 보간한다. 끝나면 프롬프트를 다시 켠다
local function animateUnfold(panel: Instance, slot: BasePart, final: CFrame)
    local start = SolarPanels.unfoldStart(final, slot)
    setPivot(panel, start)
    unfolding += 1
    SolarPanels.refresh()
    local myGeneration = generation
    task.spawn(function()
        local steps = math.max(1, math.ceil(Config.PANEL_UNFOLD_SECONDS * Config.ANIMATION_HZ))
        for step = 1, steps do
            task.wait(Config.PANEL_UNFOLD_SECONDS / steps)
            if myGeneration ~= generation or panel.Parent == nil then
                return
            end
            local alpha = step / steps
            local eased = 1 - (1 - alpha) * (1 - alpha) -- 끝에서 부드럽게 멈춘다
            setPivot(panel, start:Lerp(final, eased))
        end
        setPivot(panel, final)
        unfolding = math.max(0, unfolding - 1)
        SolarPanels.refresh()
    end)
end

local function spawnPanel(index: number, animate: boolean?)
    local slot = slots[index]
    local template = ServerStorage:FindFirstChild("PanelTemplate")
    local folder = panelsFolder
    if not slot or not template or not folder then
        return
    end
    local panel = template:Clone()
    panel.Name = "Panel" .. index
    for _, descendant in panel:GetDescendants() do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
        end
    end
    if panel:IsA("BasePart") then
        panel.Anchored = true
    end
    placeOnTop(panel, slot)
    panel.Parent = folder
    if animate then
        animateUnfold(panel, slot, pivotOf(panel))
    end
end

-- 펼치는 중인지 (테스트용)
function SolarPanels.isUnfolding(): boolean
    return unfolding > 0
end

-- 프롬프트 문구와 활성 상태를 현재 상태에 맞춘다
function SolarPanels.refresh()
    local current = prompt
    if not current then
        return
    end
    local s = ResourceState.get()
    local texts = Config.PROMPT_TEXTS
    current.ObjectText = texts.solarObject
    if unfolding > 0 then
        current.Enabled = false
        current.ActionText = texts.installing
        return
    end
    current.Enabled = s.phase == "playing" and s.panelsInstalled < s.panelsTotal
    local template = if s.panelsInstalledToday >= s.panelsPerDay
        then texts.installTomorrow
        else texts.installPanel
    current.ActionText = string.format(template, s.panelsInstalledToday, s.panelsPerDay)
end

local function onTriggered(player: Player)
    if unfolding > 0 then
        return
    end
    local ok, newState, message = Simulation.installPanel(ResourceState.get(), Config)
    if not ok then
        ResourceState.notify(player, message, "warn")
        return
    end
    ResourceState.set(newState)
    spawnPanel(newState.panelsInstalled, true)
    ResourceState.notify(player, message, "good")
    SolarPanels.refresh()
    ResourceState.publish()
end

-- 새 기지에 연결
function SolarPanels.attach(base: Model)
    SolarPanels.detach()
    local field = ServerUtil.findModel(base, "SolarField")
    local installPad = ServerUtil.findPart(field, "InstallPad")
    if not field or not installPad then
        warn("[SolarPanels] Base.SolarField.InstallPad를 찾지 못했습니다")
        return
    end
    slots = collectSlots(field)
    if #slots < Config.PANELS_TOTAL then
        warn(
            string.format(
                "[SolarPanels] 슬롯 %d개 < 패널 %d장. 남는 패널은 화면에 보이지 않습니다",
                #slots,
                Config.PANELS_TOTAL
            )
        )
    end
    local folder = Instance.new("Folder")
    folder.Name = "Panels"
    folder.Parent = field
    panelsFolder = folder

    -- 재시작 없이 다시 연결되는 경우를 위해 이미 설치된 수만큼 복원
    for index = 1, ResourceState.get().panelsInstalled do
        spawnPanel(index)
    end

    local newPrompt = ServerUtil.makePrompt(installPad, {
        actionText = string.format(Config.PROMPT_TEXTS.installPanel, 0, Config.PANELS_PER_DAY),
        objectText = Config.PROMPT_TEXTS.solarObject,
        holdDuration = Config.PANEL_INSTALL_HOLD,
        enabled = false,
    })
    prompt = newPrompt
    table.insert(connections, newPrompt.Triggered:Connect(onTriggered))
    SolarPanels.refresh()
end

function SolarPanels.detach()
    generation += 1
    unfolding = 0
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    if prompt then
        prompt:Destroy()
        prompt = nil
    end
    if panelsFolder then
        panelsFolder:Destroy()
        panelsFolder = nil
    end
    table.clear(slots)
end

return SolarPanels
