--!strict
-- 플레이 기록 로그 (2026-10-19 20차 보조). 밸런스 조정용으로 "사람이 한 판"을 서버 Output에 남긴다.
-- 새 게임마다 reset, 매 DayTick 뒤 snapshot(한 줄 상태), 각 시스템 성공 지점에서 event(한 줄 사건).
-- 10일마다 진행 한 줄을 print하고, 게임이 끝나면 머리말 + 사건 목록 + 10일 간격 표를 한 번에 print한다.
-- 수치는 Config가 아니라 아래 상수에 둔다 (게임 규칙이 아니라 기록 형식이므로)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local ResourceState = require(script.Parent.ResourceState)

local PRINT_INTERVAL = 10 -- 진행 한 줄과 표의 날짜 간격
local MAX_SNAPSHOTS = 400 -- 메모리 상한 (한 판이 이보다 길면 이후는 쌓지 않는다)
local MAX_EVENTS = 80 -- 사건 저장 상한
local MAX_LINES = 60 -- 요약 문자열 줄 수 상한 (Output 잘림 방지)
local MAX_TABLE_ROWS = 20 -- 표 행 상한

type Snapshot = {
    day: number,
    energy: number,
    water: number,
    food: number,
    panels: number,
    modules: string, -- 모듈 상태 글자를 순서대로 이은 것 (예: "AVL")
    tank: number,
    trips: number,
    shortage: number,
    event: string,
}

type Entry = { day: number, text: string }

local RunLog = {}

local snapshots: { Snapshot } = {}
local events: { Entry } = {}
local onceKeys: { [string]: boolean } = {}
local finished: { won: boolean, reason: string, day: number, siteName: string, trips: number }? =
    nil

local function round(value: number): number
    return math.floor(value + 0.5)
end

-- 새 게임 (beginNewGame)
function RunLog.reset()
    snapshots = {}
    events = {}
    onceKeys = {}
    finished = nil
end

local function addEvent(day: number, text: string)
    if #events >= MAX_EVENTS then
        return
    end
    table.insert(events, { day = day, text = text })
end

-- 사건 한 줄. 날짜는 지금 게임 날짜. 플레이 중이 아니면 기록하지 않는다
function RunLog.event(text: string)
    local state = ResourceState.get()
    if state.phase ~= "playing" then
        return
    end
    addEvent(state.day, text)
end

-- 게임당 한 번만 남기는 사건 (로버 첫 탑승 등)
function RunLog.once(key: string, text: string)
    if onceKeys[key] then
        return
    end
    if ResourceState.get().phase ~= "playing" then
        return
    end
    onceKeys[key] = true
    RunLog.event(text)
end

-- 모듈 상태 한 글자: L 잠김, V 가능, B 건설 중, A 가동, P 대기(가동 중지), D 손상
local function moduleLetter(m: Simulation.ModuleState?): string
    if not m then
        return "-"
    end
    if m.status == "locked" then
        return "L"
    elseif m.status == "available" then
        return "V"
    elseif m.status == "building" then
        return "B"
    end
    if m.damaged then
        return "D"
    end
    if m.paused then
        return "P"
    end
    return "A"
end

-- 이벤트 한 글자: W 폭풍 예고, A 폭풍 진행, M 미세운석, - 없음
local function eventLetter(event: Simulation.ActiveEvent?): string
    if not event then
        return "-"
    end
    if event.kind == "micrometeoroid" then
        return "M"
    end
    return if event.stage == "warning" then "W" else "A"
end

local function modulesText(state: Simulation.GameState): string
    local letters = {}
    for _, id in Config.MODULE_ORDER do
        table.insert(letters, moduleLetter(state.modules[id]))
    end
    return table.concat(letters)
end

local function progressLine(s: Snapshot): string
    return string.format(
        "D%d E%d W%d F%d P%d A/B/C %s tank %d trips %d",
        s.day,
        s.energy,
        s.water,
        s.food,
        s.panels,
        s.modules,
        s.tank,
        s.trips
    )
end

-- DayTick 앞뒤 상태 비교로 잡는 사건: 완공, 폭풍 예고/시작/끝, 운석, 자원 부족 시작
local function detectEvents(prev: Simulation.GameState, new: Simulation.GameState)
    local day = new.day
    for _, id in Config.MODULE_ORDER do
        local before, after = prev.modules[id], new.modules[id]
        if after and after.status == "active" and not (before and before.status == "active") then
            addEvent(day, id .. " 완공")
        end
    end
    local function stormStage(state: Simulation.GameState): string?
        local event = state.event
        if event and event.kind == "solarStorm" then
            return event.stage
        end
        return nil
    end
    local stormBefore: string = stormStage(prev) or "none"
    local stormAfter: string = stormStage(new) or "none"
    if stormAfter ~= stormBefore then
        if stormAfter == "warning" then
            addEvent(day, "폭풍 예고")
        elseif stormAfter == "active" then
            addEvent(day, "폭풍 시작")
        elseif stormBefore == "active" then
            addEvent(day, "폭풍 끝")
        end
    end
    for index, entry in new.eventSchedule do
        local old = prev.eventSchedule[index]
        if entry.kind == "micrometeoroid" and entry.resolved and not (old and old.resolved) then
            local target = entry.target
            if Config.MODULES[target] then
                addEvent(day, "운석 " .. target .. " 손상")
            elseif target == "panel" then
                addEvent(day, "운석 패널 1장 파손")
            else
                addEvent(day, "운석 빗나감")
            end
        end
    end
    if prev.shortageDays == 0 and new.shortageDays > 0 then
        addEvent(day, "자원 부족 시작 " .. Simulation.shortageName(new, Config))
    end
end

-- DayTick 직후 (GameFlow.onDayTick). prev는 하루 계산 전, new는 후
function RunLog.snapshot(prev: Simulation.GameState, new: Simulation.GameState)
    if new.phase ~= "playing" then
        return
    end
    detectEvents(prev, new)
    if #snapshots >= MAX_SNAPSHOTS then
        return
    end
    local row: Snapshot = {
        day = new.day,
        energy = round(new.energy),
        water = round(new.water),
        food = round(new.food),
        panels = new.panelsInstalled,
        modules = modulesText(new),
        tank = round(new.rover.tank),
        trips = new.waterTrips,
        shortage = new.shortageDays,
        event = eventLetter(new.event),
    }
    table.insert(snapshots, row)
    if row.day % PRINT_INTERVAL == 0 then
        print("[RunLog] " .. progressLine(row))
    end
end

-- 게임 종료 (GameFlow.endGame). 머리말에 쓸 결과를 저장한다
function RunLog.finish(state: Simulation.GameState, won: boolean, reason: string)
    finished = {
        won = won,
        reason = reason,
        day = state.day,
        siteName = state.siteName or "?",
        trips = state.waterTrips,
    }
end

-- 요약 문자열 (MAX_LINES줄 이내). 게임이 끝나기 전이면 "(진행 중)"으로 머리말을 만든다
function RunLog.summaryText(): string
    local head = finished
    local lines: { string } = {}
    table.insert(lines, "[RunLog] ===== 플레이 기록 =====")
    if head then
        table.insert(
            lines,
            string.format(
                "착륙지 %s, 결과 %s, %d일, 원정 %d회",
                head.siteName,
                if head.won then "승리" else "실패",
                head.day,
                head.trips
            )
        )
        table.insert(lines, "사유 " .. head.reason)
    else
        table.insert(lines, "(진행 중)")
    end

    -- 표: PRINT_INTERVAL일마다 + 마지막 날. 행이 너무 많으면 간격을 넓힌다
    local picked: { Snapshot } = {}
    for i, row in snapshots do
        if row.day % PRINT_INTERVAL == 0 or i == #snapshots then
            table.insert(picked, row)
        end
    end
    local stride = math.max(1, math.ceil(#picked / MAX_TABLE_ROWS))
    local table_: { string } = {
        "일  전력 물   식량 패널 A/B/C 탱크 원정 부족 이벤트",
    }
    for i, row in picked do
        if (i - 1) % stride == 0 or i == #picked then
            table.insert(
                table_,
                string.format(
                    "%-3d %-4d %-4d %-4d %-4d %-5s %-4d %-4d %-4d %s",
                    row.day,
                    row.energy,
                    row.water,
                    row.food,
                    row.panels,
                    row.modules,
                    row.tank,
                    row.trips,
                    row.shortage,
                    row.event
                )
            )
        end
    end

    -- 사건 목록은 남는 줄 수 안에서 앞에서부터
    local budget = MAX_LINES - #lines - #table_ - 2 -- 2 = 사건 제목, 표 제목 줄
    table.insert(lines, "-- 사건 --")
    local shown = if #events > budget then math.max(0, budget - 1) else #events
    for i = 1, shown do
        local entry = events[i]
        table.insert(lines, string.format("D%d %s", entry.day, entry.text))
    end
    if shown < #events then
        table.insert(lines, string.format("(외 %d건 생략)", #events - shown))
    end
    table.insert(lines, "-- 10일 간격 상태 --")
    for _, line in table_ do
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

-- 마지막 DayTick까지 쌓인 스냅샷 수 (테스트용)
function RunLog.snapshotCount(): number
    return #snapshots
end

-- 사건 문구 목록 (테스트용). "D3 A 착공" 형태
function RunLog.eventLines(): { string }
    local out = {}
    for _, entry in events do
        table.insert(out, string.format("D%d %s", entry.day, entry.text))
    end
    return out
end

-- 게임 종료 때 한 번에 찍는다 (GameFlow.endGame)
function RunLog.printSummary()
    print(RunLog.summaryText())
end

return RunLog
