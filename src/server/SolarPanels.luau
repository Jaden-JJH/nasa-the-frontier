--!strict
-- 태양광 패널 설치: Base.SolarField.InstallPad 프롬프트, 하루 설치 제한, 슬롯에 패널 복제 (CONTRACT 3절)

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

local function spawnPanel(index: number)
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
end

-- 프롬프트 문구와 활성 상태를 현재 상태에 맞춘다
function SolarPanels.refresh()
    local current = prompt
    if not current then
        return
    end
    local s = ResourceState.get()
    local texts = Config.PROMPT_TEXTS
    current.Enabled = s.phase == "playing" and s.panelsInstalled < s.panelsTotal
    current.ActionText = if s.panelsInstalledToday >= s.panelsPerDay
        then texts.installTomorrow
        else texts.installPanel
    current.ObjectText = string.format(texts.solarObject, s.panelsInstalled, s.panelsTotal)
end

local function onTriggered(player: Player)
    local ok, newState, message = Simulation.installPanel(ResourceState.get(), Config)
    if not ok then
        ResourceState.notify(player, message, "warn")
        return
    end
    ResourceState.set(newState)
    spawnPanel(newState.panelsInstalled)
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
        actionText = Config.PROMPT_TEXTS.installPanel,
        holdDuration = Config.PANEL_INSTALL_HOLD,
        enabled = false,
    })
    prompt = newPrompt
    table.insert(connections, newPrompt.Triggered:Connect(onTriggered))
    SolarPanels.refresh()
end

function SolarPanels.detach()
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
