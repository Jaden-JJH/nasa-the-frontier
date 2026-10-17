--!strict
-- 서버 단일 GameState 보관과 송신 (CONTRACT 2절 StateUpdate, Notify)
-- 다른 모듈은 get()으로 읽고, Simulation 함수가 돌려준 새 테이블을 set()으로 넣는다.
-- get()이 돌려주는 테이블은 직접 고치지 않는다. 고칠 때는 patch()를 쓴다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Types = require(ReplicatedStorage.Shared.Types)

type GameState = Simulation.GameState

local ResourceState = {}

local state: GameState = Simulation.newState(Config)

function ResourceState.get(): GameState
    return state
end

function ResourceState.set(newState: GameState)
    state = newState
end

-- 복사본을 만들어 mutate 함수로 고친 뒤 교체한다
function ResourceState.patch(mutate: (GameState) -> ())
    local copy = Simulation.copy(state)
    mutate(copy)
    state = copy
end

-- 새 게임 상태로 초기화 (phase = selecting)
function ResourceState.reset()
    state = Simulation.newState(Config)
end

-- 모든 플레이어에게 현재 상태 송신. 파생 필드(missionStage, daysLeft, stallReason, 모듈 unlocked와
-- shortfall, missionText)는 송신 직전에 항상 다시 계산한다
function ResourceState.publish()
    ResourceState.patch(function(s)
        Simulation.refreshDerived(s, Config)
    end)
    Remotes.get("StateUpdate"):FireAllClients(state)
end

-- 한 플레이어에게만 현재 상태 송신 (입장 직후)
function ResourceState.publishTo(player: Player)
    Remotes.get("StateUpdate"):FireClient(player, state)
end

-- 토스트 알림 ------------------------------------------------------------

-- Simulation이 돌려준 종류 문자열을 Notify 종류로 (모르는 값은 info)
function ResourceState.kind(value: string): Types.NotifyKind
    if value == "good" then
        return "good"
    elseif value == "warn" then
        return "warn"
    end
    return "info"
end

function ResourceState.notify(player: Player, text: string, kind: Types.NotifyKind)
    Remotes.get("Notify"):FireClient(player, text, kind)
end

function ResourceState.notifyAll(text: string, kind: Types.NotifyKind)
    Remotes.get("Notify"):FireAllClients(text, kind)
end

function ResourceState.notifyOthers(except: Player, text: string, kind: Types.NotifyKind)
    local remote = Remotes.get("Notify")
    for _, player in Players:GetPlayers() do
        if player ~= except then
            remote:FireClient(player, text, kind)
        end
    end
end

return ResourceState
