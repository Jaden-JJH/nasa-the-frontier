--!strict
-- 미세운석으로 손상된 모듈 수리 (2026-10-18 15차, CONTRACT 3절 ModuleRepair)
--   프롬프트: Base.ModulePads.PadX.Pad 파트마다 "외벽 수리" 프롬프트 1개(이름 RepairPrompt).
--             키 EVENTS.micrometeoroid.repairKey(R), 홀드 repairHold초, 거리 promptDistance.
--             같은 Pad 파트의 건설(E), 가동 중지(E) 프롬프트와 키를 나눈다 (RoverDamage의 로버 수리와 같은 방식).
--   활성: 플레이 중이고 그 모듈이 damaged일 때만.
--   수리: Simulation.repairModule (전력 repairEnergy, 모자라면 거절 토스트). 홀드 동안 공구 소리 루프.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Contributions = require(script.Parent.Contributions)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

type Entry = { id: string, pad: BasePart, prompt: ProximityPrompt }

local ModuleRepair = {}

local entries: { [string]: Entry } = {}
local connections: { RBXScriptConnection } = {}
local holdLoop: Sfx.Handle? = nil

local function stopHoldLoop()
    local handle = holdLoop
    holdLoop = nil
    if handle then
        handle.stop()
    end
end

-- 프롬프트 활성 상태를 현재 상태에 맞춘다 (DayTick, 수리 뒤, phase 변화 때 GameFlow가 부른다)
function ModuleRepair.refresh()
    local state = ResourceState.get()
    for id, entry in entries do
        local m = state.modules[id]
        entry.prompt.Enabled = state.phase == "playing" and m ~= nil and m.damaged == true
    end
end

local function onTriggered(player: Player, id: string)
    stopHoldLoop()
    local ok, new, message, kind = Simulation.repairModule(ResourceState.get(), Config, id)
    if not ok then
        ResourceState.notify(player, message, ResourceState.kind(kind))
        return
    end
    ResourceState.set(new)
    Contributions.add(player, "repairs", 1)
    local entry = entries[id]
    Sfx.play("rover_repair", entry and entry.pad)
    ResourceState.notifyAll(message, ResourceState.kind(kind))
    ModuleRepair.refresh()
    ResourceState.publish()
end

-- 새 기지에 연결
function ModuleRepair.attach(base: Model)
    ModuleRepair.detach()
    local meteor = Config.EVENTS.micrometeoroid
    local pads = base:FindFirstChild("ModulePads")
    for _, id in Config.MODULE_ORDER do
        local padPart = ServerUtil.findPart(ServerUtil.findModel(pads, "Pad" .. id), "Pad")
        if padPart then
            local prompt = ServerUtil.makePrompt(padPart, {
                actionText = Config.PROMPT_TEXTS.repairModule,
                objectText = Config.MODULES[id].displayName,
                holdDuration = meteor.repairHold,
                maxDistance = meteor.promptDistance,
                enabled = false,
            })
            prompt.Name = "RepairPrompt"
            prompt.KeyboardKeyCode = (Enum.KeyCode :: any)[meteor.repairKey]
            entries[id] = { id = id, pad = padPart, prompt = prompt }
            table.insert(
                connections,
                prompt.Triggered:Connect(function(player: Player)
                    onTriggered(player, id)
                end)
            )
            table.insert(
                connections,
                prompt.PromptButtonHoldBegan:Connect(function()
                    stopHoldLoop()
                    holdLoop = Sfx.loop("rover_repair", padPart)
                end)
            )
            table.insert(connections, prompt.PromptButtonHoldEnded:Connect(stopHoldLoop))
        end
    end
    ModuleRepair.refresh()
end

function ModuleRepair.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    stopHoldLoop()
    for _, entry in entries do
        entry.prompt:Destroy()
    end
    table.clear(entries)
end

return ModuleRepair
