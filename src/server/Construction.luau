--!strict
-- 모듈 건설: PadA/B/C 프롬프트, 비용 검증, 건설 진행, 고스트/완성 모델 전환, 선행 조건 (CONTRACT 3절)
-- Ghost와 Built는 해당 상태가 아닐 때 Parent를 nil로 빼 둔다 (CONTRACT 4절 "Parent를 빼두거나 투명")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local KitImports = require(script.Parent.KitImports)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)

type GameState = Simulation.GameState

type PadEntry = {
    id: string,
    model: Model,
    pad: BasePart,
    ghost: Instance?,
    built: Instance?,
    prompt: ProximityPrompt,
    label: TextLabel,
    gui: BillboardGui,
}

local Construction = {}

local entries: { [string]: PadEntry } = {}
local connections: { RBXScriptConnection } = {}
local currentBase: Model? = nil

local LABEL_BACKGROUND = Color3.fromRGB(16, 22, 40)
local LABEL_TEXT = Color3.fromRGB(255, 255, 255)
local LABEL_BACKGROUND_TRANSPARENCY = 0.25

local function makeLabel(pad: BasePart): (BillboardGui, TextLabel)
    local layout = Config.WORLD_LABEL
    local gui = Instance.new("BillboardGui")
    gui.Name = "StatusLabel"
    gui.Size = UDim2.fromOffset(layout.width, layout.height)
    gui.StudsOffset = Vector3.new(0, layout.offsetY, 0)
    gui.MaxDistance = layout.maxDistance
    gui.AlwaysOnTop = false
    gui.Parent = pad

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundColor3 = LABEL_BACKGROUND
    label.BackgroundTransparency = LABEL_BACKGROUND_TRANSPARENCY
    label.TextColor3 = LABEL_TEXT
    label.Font = Enum.Font.GothamMedium
    label.TextSize = layout.textSize
    label.TextWrapped = true
    label.Text = ""
    label.Parent = gui
    return gui, label
end

local function labelText(id: string, state: GameState): string
    local def = Config.MODULES[id]
    local m = state.modules[id]
    local t = Config.TEXTS
    if m.status == "building" then
        return string.format(t.labelBuilding, def.displayName, m.daysLeft)
    elseif m.status == "active" then
        return string.format(t.labelActive, def.displayName)
    elseif m.status == "available" then
        return string.format(t.labelAvailable, def.displayName)
    end
    return string.format(t.labelLocked, def.displayName)
end

-- 상태에 맞춰 고스트, 완성 모델, 프롬프트, 표시판을 맞춘다
local function applyVisuals(entry: PadEntry, state: GameState)
    local m = state.modules[entry.id]
    if not m then
        return
    end
    if entry.ghost then
        entry.ghost.Parent = if m.status == "building" then entry.model else nil
    end
    if entry.built then
        entry.built.Parent = if m.status == "active" then entry.model else nil
    end
    entry.prompt.Enabled = m.status == "available" and state.phase == "playing"
    entry.label.Text = labelText(entry.id, state)
end

-- prev와 new를 비교해 화면을 맞추고 상태 전환 알림을 보낸다. prev가 nil이면 알림 없이 맞추기만 한다
function Construction.sync(prev: GameState?, new: GameState)
    for _, id in Config.MODULE_ORDER do
        local entry = entries[id]
        if entry then
            applyVisuals(entry, new)
        end
        if prev then
            local before = prev.modules[id]
            local after = new.modules[id]
            local def = Config.MODULES[id]
            if before and after and before.status ~= after.status then
                if after.status == "active" then
                    ResourceState.notifyAll(
                        string.format(Config.TEXTS.buildDone, def.displayName),
                        "good"
                    )
                    -- KitImports 장식 (연결 통로, 작물). 메시가 없으면 아무 것도 하지 않는다
                    local base = currentBase
                    if base then
                        ServerUtil.safeCall(
                            "KitImports",
                            KitImports.onModuleActivated,
                            id,
                            base,
                            function(moduleId: string): boolean
                                local m = new.modules[moduleId]
                                return m ~= nil and m.status == "active"
                            end
                        )
                    end
                elseif after.status == "available" and before.status == "locked" then
                    ResourceState.notifyAll(
                        string.format(Config.TEXTS.moduleUnlocked, def.displayName),
                        "info"
                    )
                end
            end
        end
    end
end

local function onTriggered(player: Player, id: string)
    local prev = ResourceState.get()
    local ok, newState, message = Simulation.startBuild(prev, Config, id)
    if not ok then
        ResourceState.notify(player, message, "warn")
        return
    end
    ResourceState.set(newState)
    Construction.sync(prev, newState)
    ResourceState.notifyAll(message, "info")
    ResourceState.publish()
end

-- 새 기지에 연결
function Construction.attach(base: Model)
    Construction.detach()
    currentBase = base
    local pads = base:FindFirstChild("ModulePads")
    for _, id in Config.MODULE_ORDER do
        local model = ServerUtil.findModel(pads, "Pad" .. id)
        local padPart = ServerUtil.findPart(model, "Pad")
        if model and padPart then
            local def = Config.MODULES[id]
            local ghost = model:FindFirstChild("Ghost")
            local built = model:FindFirstChild("Built")
            if ghost then
                ghost.Parent = nil
            end
            if built then
                built.Parent = nil
            end
            local prompt = ServerUtil.makePrompt(padPart, {
                actionText = Config.PROMPT_TEXTS.build,
                objectText = string.format(
                    Config.PROMPT_TEXTS.buildObject,
                    def.displayName,
                    def.cost.energy,
                    def.cost.water
                ),
                holdDuration = Config.PROMPT.buildHold,
                enabled = false,
            })
            local gui, label = makeLabel(padPart)
            entries[id] = {
                id = id,
                model = model,
                pad = padPart,
                ghost = ghost,
                built = built,
                prompt = prompt,
                label = label,
                gui = gui,
            }
            table.insert(
                connections,
                prompt.Triggered:Connect(function(player: Player)
                    onTriggered(player, id)
                end)
            )
        else
            warn("[Construction] Base.ModulePads.Pad" .. id .. ".Pad를 찾지 못했습니다")
        end
    end
    Construction.sync(nil, ResourceState.get())
end

function Construction.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, entry in entries do
        entry.prompt:Destroy()
        entry.gui:Destroy()
        -- 빼 두었던 모델은 Base와 함께 사라지지 않으므로 직접 정리한다
        if entry.ghost and entry.ghost.Parent == nil then
            entry.ghost:Destroy()
        end
        if entry.built and entry.built.Parent == nil then
            entry.built:Destroy()
        end
    end
    table.clear(entries)
    currentBase = nil
end

return Construction
