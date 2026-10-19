--!strict
-- 미세운석으로 손상된 모듈 수리 로직 (2026-10-18 15차, CONTRACT 3절 ModuleRepair)
--   19차 (2026-10-19): 프롬프트는 ModulePanels가 모듈 외벽 제어반(ControlPanel)에 붙이고 켜고 끈다.
--   이 모듈은 수리 규칙과 소리만 맡는다 (프롬프트 수명은 제어반과 같이 간다).
--   수리: Simulation.repairModule (전력 repairEnergy, 모자라면 거절 토스트). 홀드 동안 공구 소리 루프.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Contributions = require(script.Parent.Contributions)
local ResourceState = require(script.Parent.ResourceState)
local Sfx = require(script.Parent.Sfx)

local ModuleRepair = {}

local holdLoop: Sfx.Handle? = nil

-- 홀드 공구 소리를 멈춘다 (홀드가 끝나거나 수리가 끝나거나 제어반이 사라질 때)
function ModuleRepair.endHold()
    local handle = holdLoop
    holdLoop = nil
    if handle then
        handle.stop()
    end
end

-- 수리 홀드 시작: at(제어반 파트) 위치에서 공구 소리 루프
function ModuleRepair.beginHold(at: Instance?)
    ModuleRepair.endHold()
    holdLoop = Sfx.loop("rover_repair", at)
end

-- 수리 시도. 성공하면 상태를 바꾸고 알린 뒤 true (프롬프트 갱신과 publish는 호출한 쪽이 한다)
function ModuleRepair.repair(player: Player, id: string, at: Instance?): boolean
    ModuleRepair.endHold()
    local ok, new, message, kind = Simulation.repairModule(ResourceState.get(), Config, id)
    if not ok then
        ResourceState.notify(player, message, ResourceState.kind(kind))
        return false
    end
    ResourceState.set(new)
    Contributions.add(player, "repairs", 1)
    Sfx.play("rover_repair", at)
    ResourceState.notifyAll(message, ResourceState.kind(kind))
    return true
end

return ModuleRepair
