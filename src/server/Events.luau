--!strict
-- 랜덤 이벤트 알림 (2026-10-18 15차, CONTRACT 3절 Events)
-- 규칙(일정, 폭풍 효과, 미세운석 처리)은 전부 Shared.Simulation에 있고 DayTick(applyDay) 안에서 전진한다.
-- 이 모듈은 DayTick 앞뒤 상태를 비교해 토스트(Notify)와 효과음만 낸다.
--   토스트: 폭풍 예고 시작(warn), 폭풍 시작(warn), 폭풍 끝(good), 미세운석 충돌(warn, 빗나가면 info).
--           클라이언트 ToastUI가 warn/good 토스트음(SoundFX notify_warn, notify_good)을 낸다.
--   효과음: 미세운석이 모듈을 때리면 그 패드에서 rover_hit(충돌음), 빗나가면 기지 Origin에서.
--           패널 파괴음은 SolarPanels.syncCount가 그 슬롯에서 낸다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

local Events = {}

-- 미세운석 충돌음 위치: 모듈이면 그 Pad 파트, 빗나가면 기지 Origin
local function impactPart(target: string?): Instance?
    local base = ServerUtil.getBase()
    if not base or target == nil or target == "panel" then
        return nil
    end
    if Config.MODULES[target] then
        local pads = base:FindFirstChild("ModulePads")
        return ServerUtil.findPart(ServerUtil.findModel(pads, "Pad" .. target), "Pad")
    end
    return base.PrimaryPart or ServerUtil.findPart(base, "Origin")
end

-- DayTick 한 번의 앞(prev)과 뒤(new) 상태로 알림을 보낸다. 보낸 알림 수를 돌려준다 (테스트용)
function Events.onDayTick(prev: Simulation.GameState, new: Simulation.GameState): number
    local notices = Simulation.eventNotices(prev, new, Config)
    for _, notice in notices do
        ResourceState.notifyAll(notice.text, notice.kind)
        if notice.target ~= nil then
            Sfx.play("rover_hit", impactPart(notice.target))
        end
    end
    return #notices
end

return Events
