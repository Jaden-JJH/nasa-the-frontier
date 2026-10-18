--!strict
-- CONTRACT 2절의 공용 타입 모음
-- 게임 상태 타입은 순수 로직 모듈(Simulation)이 정의하고 여기서 다시 내보낸다.
-- 사용 예: local Types = require(ReplicatedStorage.Shared.Types)
--          local function onState(state: Types.GameState) ... end

local Ranking = require(script.Parent.Ranking)
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
-- 랜덤 이벤트 (2026-10-18 15차)
export type EventKind = Simulation.EventKind -- "solarStorm" | "micrometeoroid"
export type EventStage = Simulation.EventStage -- "warning" | "active"
export type ActiveEvent = Simulation.ActiveEvent -- GameState.event { kind, stage, daysLeft, text, eduText }
export type EventEntry = Simulation.EventEntry -- GameState.eventSchedule 한 줄 (서버 규칙용)

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
    crew: { CrewRow }, -- 2026-10-19 16차. 플레이어별 기여도(기여 합이 큰 순, 최대 RECORDS.crewRows). 순위 표기는 하지 않는다
}

-- 결과 화면 "함께 한 일" 한 행 (2026-10-19 16차). 나간 플레이어도 남는다
export type CrewRow = {
    name: string, -- DisplayName
    panels: number, -- 패널 설치 수
    water: number, -- 물 하역량 W
    builds: number, -- 착공 수
    repairs: number, -- 로버 수리 + 모듈 외벽 수리
    deaths: number, -- 산소 고갈(산소 0)과 쓰러짐(초기화, 추락) 횟수
}

-- 승리 기록 한 줄 (Shared.Ranking.Entry)
export type RecordEntry = Ranking.Entry

-- Records(S->C) 페이로드 (2026-10-19 16차)
export type RecordsStatus = "loading" | "ok" | "offline" -- offline: DataStore를 못 써서 이번 서버 기록만
export type RecordsPayload = {
    entries: { RecordEntry }, -- 상위 RECORDS.maxEntries개, 순위 순
    rank: number?, -- submitted일 때 이번 승리의 순위. 상위 밖이면 nil
    status: RecordsStatus,
    submitted: boolean, -- true면 방금 끝난 승리를 반영한 결과 (rank가 nil이면 상위 밖)
}

return {}
