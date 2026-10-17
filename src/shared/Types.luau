--!strict
-- CONTRACT 2절의 공용 타입 모음
-- 게임 상태 타입은 순수 로직 모듈(Simulation)이 정의하고 여기서 다시 내보낸다.
-- 사용 예: local Types = require(ReplicatedStorage.Shared.Types)
--          local function onState(state: Types.GameState) ... end

local Simulation = require(script.Parent.Simulation)

export type Phase = Simulation.Phase
export type ModuleStatus = Simulation.ModuleStatus
export type ModuleState = Simulation.ModuleState
export type Modules = Simulation.Modules -- 키는 "A", "B", "C"
export type RoverState = Simulation.RoverState
export type GameState = Simulation.GameState
export type EndResult = Simulation.EndResult
export type MissionStage = Simulation.MissionStage
export type Shortfall = Simulation.Shortfall -- ModuleState.shortfall { energy, water }
export type DaysLeft = Simulation.DaysLeft -- GameState.daysLeft { water, food }

export type NotifyKind = "info" | "warn" | "good"

export type SiteInfo = {
    id: number, -- 1..4
    name: string, -- 예: "Shackleton Rim"
    sunlight: number, -- 0..1
    iceDistanceLabel: string, -- "멀다" | "중간" | "가깝다" | "매우 가깝다"
    hazardLabel: string, -- "낮음" | "중간" | "높음"
    description: string, -- 한 줄 설명 (한국어)
}

export type SiteSelectionInfo = {
    chooserUserId: number, -- 선택 권한이 있는 플레이어
    chooserName: string,
    deadlineUnix: number, -- workspace:GetServerTimeNow() 기준 자동 선택 시각(초). 클라이언트도 같은 함수로 남은 시간을 계산한다
    defaultSiteId: number,
    sites: { SiteInfo },
}

export type GameOverInfo = {
    won: boolean,
    reason: string, -- 한국어 사유
    day: number,
    waterTrips: number,
    oxygenDeaths: number,
    siteName: string,
    restartAvailableAt: number, -- workspace:GetServerTimeNow() 기준 재시작을 받기 시작하는 시각(초)
    chooserUserId: number, -- 재시작할 수 있는 플레이어(선택 권한자). 권한자가 나가면 다시 보낸다
}

return {}
