--!strict
-- Studio 전용 개발 다리 (2026-11-15 데모 영상 촬영). Studio MCP execute_luau에서 require(Server.MissionFlow)를 하면
-- 게임이 쓰는 인스턴스와 다른 사본이 나와(getRules() = nil) 장면을 맞출 수 없었다. 그래서 게임 쪽 서버 스크립트가
-- ServerStorage에 BindableFunction "FrontierDev"를 만들고, OnInvoke(cmd, args)로 실제 MissionFlow, Rules, SpaceWeather,
-- MissionClock 인스턴스에서 명령을 실행한다. 라이브 서버(RunService:IsStudio() = false)에서는 만들지 않는다.
--
-- 부르는 법 (MCP execute_luau, Play 중 서버):
--   game.ServerStorage.FrontierDev:Invoke("probe")
--   game.ServerStorage.FrontierDev:Invoke("setResources", { energy = 80, water = 60, food = 50 })
-- 반환은 항상 표: { ok = true, ... } 또는 { ok = false, error = "..." }. 상태를 바꾸는 명령은 probe 결과를 state에 담는다.
--
-- 명령
--   probe                         phase, day, 자원, 시설, 로버, 우주 기상 구간, 시계
--   setResources {energy, water, food}   nil은 그대로, 0 ~ cap
--   setWindow {id}                다음 판 구간(setNextWindow). 진행 중이면 지금 판에도 바꿔 넣는다
--   jumpToDay {day}               우주 기상 효과를 끄고 날짜를 옮긴다. 그날 사건이 진행 중이면 사건 하루 전으로 가서
--                                 진짜 하루 마감(advance)으로 들어간다(경보와 시작 연출, 문 잠금이 제대로 걸리게)
--   advance {days}                MissionFlow.debugAdvanceDay를 days번 (판이 끝나면 멈춤)
--   completeFacility {id, leaveDays?, siteIndex?}   farm, led, nutrient, pipe, hydroponics, airlock을 완공. leaveDays면
--                                 남은 일수 그만큼인 건설 중(솟아오름 장면). 선행 시설이 없으면 함께 완공
--   givePanels {count, add?}      설치한 패널 수를 count로 (add = true면 더한다). 0 ~ 총 칸
--   nearGold                      금메달 직전: 에어록, 그린하우스, LED, 영양분, 파이프 완공, 수경 재배만 1일 남김, 자원 넉넉
--   clock {run}                   MissionClock 정지(false), 다시 시작(true, 하루 30초부터)
--   selectMission {id}            미션 선택 확정 (selecting일 때)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local Rules = require(ReplicatedStorage.Shared.Rules)
local SpaceWeatherData = require(ReplicatedStorage.Shared.SpaceWeatherData)
local MissionClock = require(script.Parent.MissionClock)
local MissionFlow = require(script.Parent.MissionFlow)
local RecordsV2 = require(script.Parent.RecordsV2)
local SpaceWeather = require(script.Parent.SpaceWeather)

local DevBridge = {}

DevBridge.NAME = "FrontierDev"
DevBridge.FACILITIES = { "airlock", "farm", "led", "nutrient", "pipe", "hydroponics" }

type Result = { [string]: any }

local function fail(message: string): Result
    return { ok = false, error = message }
end

local function rules(): any
    return MissionFlow.getRules()
end

local function playing(): boolean
    return MissionFlow.getPhase() == "playing" and rules() ~= nil
end

local function mission(state: any): any
    return (MissionConfig.MISSIONS :: any)[state.missionId] or MissionConfig.MISSIONS.C
end

-- Rules 상태 복사 -> 고치기 -> commit (월드와 StateUpdate가 같이 맞춰진다. tests H.topUp과 같은 방법)
local function edit(mutate: (any) -> ()): any
    local s = Rules.copy(rules())
    mutate(s)
    MissionFlow.flow.commit(s)
    return s
end

local function probe(): Result
    local s = rules()
    local out: Result = {
        ok = true,
        phase = MissionFlow.getPhase(),
        clockRunning = MissionClock.isRunning(),
        records = RecordsV2.status(),
        players = #Players:GetPlayers(),
    }
    if not s then
        return out
    end
    out.missionId = s.missionId
    out.day = s.day
    out.totalDays = s.totalDays
    out.resources = { energy = s.energy, water = s.water, food = s.food }
    out.panels = s.panels
    out.deliveries = s.deliveries
    local facilities: { [string]: any } = {}
    for id, f in s.facilities do
        facilities[id] = { status = f.status, daysLeft = f.daysLeft, paused = f.paused }
    end
    out.facilities = facilities
    out.rover = { status = s.rover.status, damage = s.rover.damage }
    out.window = s.weather.id
    local sep, gst = Rules.weatherOn(s)
    out.weatherToday = { sep = sep ~= nil, gst = gst ~= nil }
    return out
end

local function withState(result: Result): Result
    result.ok = result.ok ~= false
    result.state = probe()
    return result
end

-- Rules 안쪽 normalizeWeather와 같은 모양 (GST는 Kp가 기준 미만이면 뺀다)
local function windowState(window: any): any
    local minKp = (MissionConfig :: any).WEATHER.GST.minKp
    local events = {}
    for _, e in window.events or {} do
        local keep = e.kind == "SEP" or e.kind == "GST"
        if keep and e.kind == "GST" and e.kp ~= nil and e.kp < minKp then
            keep = false
        end
        if keep and typeof(e.day) == "number" then
            table.insert(events, {
                kind = e.kind,
                day = e.day,
                durationDays = math.max(1, e.durationDays or 1),
                kp = e.kp,
                sourceDate = if e.sourceDate then table.clone(e.sourceDate) else nil,
            })
        end
    end
    table.sort(events, function(a: any, b: any)
        if a.day == b.day then
            return a.kind < b.kind
        end
        return a.day < b.day
    end)
    return {
        id = window.id or "unknown",
        startDate = if window.startDate then table.clone(window.startDate) else nil,
        events = events,
    }
end

local function findWindow(id: any): any
    for _, w in SpaceWeatherData.windows do
        if w.id == id then
            return w
        end
    end
    return nil
end

-- 시설 하나를 상태에 넣는다 (Rules.startBuild가 만드는 모양). leaveDays면 건설 중, 아니면 완공
local function putFacility(s: any, defId: string, leaveDays: number?, siteIndex: number?)
    local def = mission(s).facilities[defId]
    local building = leaveDays ~= nil and leaveDays > 0
    local old = s.facilities[defId]
    s.facilities[defId] = {
        id = defId,
        defId = defId,
        status = if building then "building" else "active",
        daysLeft = if building then math.min(leaveDays :: number, def.buildDays) else 0,
        buildDays = def.buildDays,
        paused = false,
        progress = if old and old.progress then old.progress else 0,
        siteIndex = if def.kind == "pipe" then siteIndex else nil,
        startedDay = s.day,
        completedDay = if building then nil else s.day,
    }
end

-- 파이프 지점: 고른 지점, 이미 연결된 지점, 아니면 가장 먼 얼음 후보지
local function pipeSite(s: any, wanted: any): number
    if typeof(wanted) == "number" and s.sites[wanted] then
        return wanted
    end
    for index, site in s.sites do
        if site.pipeId ~= nil then
            return index
        end
    end
    return #s.sites
end

-- defId와 선행 시설을 넣는다. 반환: 함께 완공한 선행 시설 id 목록
local function complete(s: any, defId: string, leaveDays: number?, siteIndex: any): { string }
    local m = mission(s)
    local def = m.facilities[defId]
    local added: { string } = {}
    for _, req in def.requires do
        local f = s.facilities[req]
        if not f or f.status ~= "active" then
            table.insert(added, req)
            for _, more in complete(s, req, nil, siteIndex) do
                table.insert(added, more)
            end
        end
    end
    local index: number? = nil
    if def.kind == "pipe" then
        index = pipeSite(s, siteIndex)
        for _, site in s.sites do
            if site.pipeId == defId then
                site.pipeId = nil
            end
        end
        s.sites[index :: number].pipeId = defId
        if def.unlockDeliveries then
            s.deliveries = math.max(s.deliveries, def.unlockDeliveries)
        end
    end
    putFacility(s, defId, leaveDays, index)
    return added
end

-- 그날 진행 중인 우주 기상 사건 중 가장 이른 시작일 (없으면 nil)
local function eventStart(s: any, day: number): number?
    local first: number? = nil
    for _, e in s.weather.events do
        if day >= e.day and day < e.day + e.durationDays then
            first = if first then math.min(first, e.day) else e.day
        end
    end
    return first
end

local function advanceDays(days: number): number
    local done = 0
    for _ = 1, days do
        if not playing() then
            break
        end
        MissionFlow.debugAdvanceDay()
        done += 1
    end
    return done
end

local COMMANDS: { [string]: (args: any) -> Result } = {}

COMMANDS.probe = function(_args)
    return probe()
end

COMMANDS.setResources = function(args)
    if not playing() then
        return fail("not playing")
    end
    edit(function(s)
        for _, key in { "energy", "water", "food" } do
            local value = args[key]
            if typeof(value) == "number" then
                s[key] = math.clamp(value, 0, s.cap)
            end
        end
    end)
    return withState({})
end

COMMANDS.setWindow = function(args)
    local window = findWindow(args.id)
    if not window then
        return fail("unknown window id: " .. tostring(args.id))
    end
    MissionFlow.setNextWindow(window.id)
    local appliedNow = false
    if playing() then
        SpaceWeather.reset()
        local updated = edit(function(s)
            s.weather = windowState(window)
        end)
        SpaceWeather.start(updated)
        appliedNow = true
    end
    return withState({ nextWindow = window.id, appliedNow = appliedNow })
end

COMMANDS.jumpToDay = function(args)
    if not playing() then
        return fail("not playing")
    end
    local target = args.day
    local total = rules().totalDays
    if typeof(target) ~= "number" or target < 1 or target > total then
        return fail("day must be 1.." .. tostring(total))
    end
    target = math.floor(target)
    SpaceWeather.reset()
    local start = eventStart(rules(), target)
    local landing = target
    if start then
        landing = math.max(1, start - 1)
    end
    edit(function(s)
        s.day = landing
        s.panelsToday = 0
    end)
    local advanced = 0
    if landing < target then
        advanced = advanceDays(target - landing)
    elseif start then
        -- 1일째부터 사건이 있으면 하루 전이 없다: 그 자리에서 효과를 켠다
        SpaceWeather.start(rules())
    end
    return withState({ landedOn = landing, advanced = advanced })
end

COMMANDS.advance = function(args)
    if not playing() then
        return fail("not playing")
    end
    local days = if typeof(args.days) == "number"
        then math.clamp(math.floor(args.days), 1, 60)
        else 1
    return withState({ advanced = advanceDays(days) })
end

COMMANDS.completeFacility = function(args)
    if not playing() then
        return fail("not playing")
    end
    local id = args.id
    if typeof(id) ~= "string" or table.find(DevBridge.FACILITIES, id) == nil then
        return fail("id must be one of " .. table.concat(DevBridge.FACILITIES, ", "))
    end
    if mission(rules()).facilities[id] == nil then
        return fail("facility not in this mission: " .. id)
    end
    local leave = if typeof(args.leaveDays) == "number" and args.leaveDays > 0
        then math.floor(args.leaveDays)
        else nil
    local added = {}
    edit(function(s)
        added = complete(s, id, leave, args.siteIndex)
    end)
    return withState({ completed = id, leaveDays = leave, alsoCompleted = added })
end

COMMANDS.givePanels = function(args)
    if not playing() then
        return fail("not playing")
    end
    if typeof(args.count) ~= "number" then
        return fail("count must be a number")
    end
    edit(function(s)
        local total = mission(s).panels.total
        local count = if args.add == true then s.panels + args.count else args.count
        s.panels = math.clamp(math.floor(count), 0, total)
        s.panelsToday = 0
    end)
    return withState({})
end

COMMANDS.nearGold = function(_args)
    if not playing() then
        return fail("not playing")
    end
    edit(function(s)
        for _, id in { "airlock", "farm", "led", "nutrient", "pipe" } do
            complete(s, id, nil, nil)
        end
        complete(s, "hydroponics", 1, nil)
        s.energy, s.water, s.food = math.min(90, s.cap), math.min(80, s.cap), math.min(70, s.cap)
        s.panels = mission(s).panels.total
        s.panelsToday = 0
    end)
    local result: Result = {}
    if RecordsV2.status() == "ok" then
        -- 다음 하루 마감에서 메달로 끝나면 진짜 DataStore 순위에 기록된다
        result.warning = "records ok: finishing this run writes to the real DataStore ranking"
    end
    return withState(result)
end

COMMANDS.clock = function(args)
    if args.run == true then
        if not playing() then
            return fail("not playing")
        end
        if not MissionClock.isRunning() then
            MissionClock.start()
        end
    elseif args.run == false then
        MissionClock.stop()
    else
        return fail("run must be true or false")
    end
    return withState({})
end

COMMANDS.selectMission = function(args)
    if MissionFlow.getPhase() ~= "selecting" then
        return fail("not selecting (phase " .. MissionFlow.getPhase() .. ")")
    end
    local id = args.id
    local def = if typeof(id) == "string" then (MissionConfig.MISSIONS :: any)[id] else nil
    if not def or not def.playable then
        return fail("mission not playable: " .. tostring(id))
    end
    MissionFlow.debugConfirmMission(id)
    return withState({ selected = id })
end

-- 명령 하나 실행 (테스트도 이 함수를 부른다). 오류는 표로 돌려준다
function DevBridge.run(cmd: any, args: any): Result
    local fn = if typeof(cmd) == "string" then COMMANDS[cmd] else nil
    if not fn then
        local names = {}
        for name in COMMANDS do
            table.insert(names, name)
        end
        table.sort(names)
        return fail("unknown command; use one of " .. table.concat(names, ", "))
    end
    local ok, result = pcall(fn, if typeof(args) == "table" then args else {})
    if not ok then
        return fail(tostring(result))
    end
    return result
end

-- isStudio일 때만 ServerStorage.FrontierDev를 만든다. 반환: 만든 BindableFunction 또는 nil
function DevBridge.install(isStudio: boolean): BindableFunction?
    if not isStudio then
        return nil
    end
    local old = ServerStorage:FindFirstChild(DevBridge.NAME)
    if old then
        old:Destroy()
    end
    local fn = Instance.new("BindableFunction")
    fn.Name = DevBridge.NAME
    fn.OnInvoke = function(cmd: any, args: any): any
        return DevBridge.run(cmd, args)
    end
    fn.Parent = ServerStorage
    return fn
end

return DevBridge
