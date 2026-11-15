--!strict
-- v2 게임 흐름 (docs/CONTRACT_V2.md 2.2 MissionFlow, 4절 Remotes, 5절 MissionState, 6절 MissionResult)
-- phase: selecting -> landing -> playing -> result -> (재시작) selecting
--   selecting: 첫 입장자가 미션을 고른다(MissionSelectOpen). CONFIG.selectSeconds(30초)가 지나면 C (Q23).
--     30초는 누군가 타이틀에서 시작을 눌러 미션 선택 화면에 들어온 순간(클라이언트 MissionSelectSeen)부터 센다.
--     그 전에는 마감이 없고(payload.deadline nil) 확정하지 않는다 (2026-11-15 QA A9: 타이틀에 머무는 동안 C가 확정됨)
--   landing: 미션 확정 순간 서버 인원으로 솔로(1명)와 멀티(2명 이상)를 정하고 판 동안 바꾸지 않는다(Q6).
--            Rules.newState(실측 얼음 거리, 무작위 DONKI 구간), LandingSequence, 멀티면 역할 선택 10초.
--   playing: MissionClock 30초 DayTick -> Rules.applyDay -> 알림 -> Rules.checkEnd. 금메달이면 그 순간 끝(Q2).
--   result: GameOver(MissionResult), 메달을 땄으면 RecordsV2 제출. CONFIG.resultMinSeconds 뒤 권한자가 재시작.
-- Rules 상태의 유일한 주인이다. 다른 모듈은 init(flow)로 받은 아래 창구로만 상태를 바꾼다(서로 require하지 않도록 주입).
--   flow.phase(), mode(), missionId(), mission(), rules()       읽기 (rules()는 고치지 않는다)
--   flow.act(player?, fn, opts?) -> (ok, msg)                    fn(state, config) -> (ok, newState, msg, events?)를 실행하고
--                                                                 성공이면 commit + 알림(기본 모두에게 good), 실패면 그 플레이어에게 warn
--   flow.commit(newState, { publish = false }?)                  알림 없이 교체 (충전 에너지, 수동 충돌 파손)
--   flow.notify(player, msg, kind), notifyAll(msg, kind), markDirty()
--   flow.weather() -> (sepToday, gstToday), contribute(player, field, n), roleOf, canUseMap, nearConsole, roverSeat
-- 서버는 문장을 만들지 않는다. 모든 화면 문구는 Msg(키 + 값).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Rules = require(ReplicatedStorage.Shared.Rules)
local SpaceWeatherData = require(ReplicatedStorage.Shared.SpaceWeatherData)
local AirlockDoors = require(script.Parent.AirlockDoors)
local ContributionsV2 = require(script.Parent.ContributionsV2)
local Interactions = require(script.Parent.Interactions)
local MissionClock = require(script.Parent.MissionClock)
local MissionWorld = require(script.Parent.MissionWorld)
local OxygenV2 = require(script.Parent.OxygenV2)
local PromptKit = require(script.Parent.PromptKit)
local RecordsV2 = require(script.Parent.RecordsV2)
local RoleMissions = require(script.Parent.RoleMissions)
local Roles = require(script.Parent.Roles)
local RoverFleet = require(script.Parent.RoverFleet)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)
local SpaceWeather = require(script.Parent.SpaceWeather)
local Spacesuit = require(script.Parent.Spacesuit)

local MissionFlow = {}

-- 흐름 설정 (MissionConfig에 없는 화면 시간과 엔진 수준 값)
MissionFlow.CONFIG = {
    selectSeconds = 30, -- [Q23] 미션 선택, 지나면 defaultMission
    defaultMission = "C",
    missionOrder = { "A", "B", "C", "D" }, -- 미션 선택 지도 순서
    landingSeconds = 5, -- 착륙 연출 (v1 LANDING_SECONDS)
    resultMinSeconds = 10, -- 결과 화면 뒤 재시작을 받기까지 (v1 RESULT_MIN_SECONDS)
    consoleRadius = 30, -- 콘솔 파트에서 이 안이면 "콘솔 근처" (클라이언트는 25 밖이면 콘솔 화면을 닫는다)
    crewRows = 4, -- 결과 화면 "함께 한 일" 줄 수 (서버 최대 4명, Q6)
    stepPanels = 2, -- 미션 문구: 패널이 이보다 적으면 "패널을 지어요"
    spawnLift = 3,
}
local CFG = MissionFlow.CONFIG

-- 하루 마감 이벤트 알림 종류 (없으면 info)
local EVENT_KINDS: { [string]: string } = {
    ["toast.harvest"] = "good",
    ["toast.build.done"] = "good",
    ["toast.pipe.delivered"] = "good",
    ["toast.pipe.unlocked"] = "good",
    ["toast.rover.returned"] = "good",
    ["toast.stall.cleared"] = "good",
    ["toast.stall.stopped_water"] = "warn",
    ["toast.stall.stopped_energy"] = "warn",
    ["toast.stall.resumed"] = "good",
    ["banner.energy.crew_unpaid"] = "warn",
    ["toast.rover.damaged"] = "warn",
    ["toast.rover.broken_walkable"] = "warn",
    ["toast.rover.broken_far"] = "warn",
    ["toast.water.overflow"] = "warn",
    ["toast.food.overflow"] = "warn",
    ["banner.gst.rover_stopped"] = "warn",
    ["banner.shortage.water"] = "warn",
    ["banner.shortage.food"] = "warn",
    ["banner.shortage.both"] = "warn",
}
-- SpaceWeather Remote가 대신 알리는 이벤트 (토스트로 겹쳐 보내지 않는다). SEP 경보는 15초 전에 따로 보낸다(Q15)
local SUPPRESSED: { [string]: boolean } = {
    ["banner.sep.active"] = true,
    ["banner.sep.end"] = true,
    ["banner.sep.warning"] = true,
    ["banner.gst.active"] = true,
    ["banner.gst.end"] = true,
    ["event.source"] = true,
}
local FACILITY_NAMES: { [string]: string } = {
    airlock = "facility.airlock.name",
    farm = "facility.farm.name",
    led = "facility.led.name",
    nutrient = "facility.nutrient.name",
    pipe = "facility.pipe.name",
    hydroponics = "facility.hydroponics.name",
    tower = "facility.tower.name",
    powerline = "facility.powerline.name",
}

type Phase = "selecting" | "landing" | "playing" | "result"

local started = false
local phase: Phase = "selecting"
local missionId: string? = nil
local worldMission: string? = nil
local mode = "solo"
local rules: any = nil
local chooser: Player? = nil
local selectDeadline = 0
local selectArmed = false -- 이번 선택 라운드에서 누군가 미션 선택 화면에 들어왔는지 (30초 타이머 시작)
local selectToken = 0
local landingToken = 0
local maxPlayers = 1
local lastResult: { [string]: any }? = nil
local publishQueued = false
local dayStart: { energy: number, water: number, food: number }? = nil
local prevDayStart: { energy: number, water: number, food: number }? = nil
local facilitySig = ""
local panelCount = -1
local nextWindowId: string? = nil
local rng = Random.new()

-- 송신 ------------------------------------------------------------------

local function notify(player: Player, msg: Msg.Msg, kind: string)
    Remotes.get("Notify"):FireClient(player, msg, kind)
end

local function notifyAll(msg: Msg.Msg, kind: string)
    Remotes.get("Notify"):FireAllClients(msg, kind)
end

local function kindOf(key: string): string
    return EVENT_KINDS[key] or "info"
end

local function currentMission(): any
    return if missionId then (MissionConfig.MISSIONS :: any)[missionId] else nil
end

local function viewMission(): any
    return currentMission() or (MissionConfig.MISSIONS :: any)[CFG.defaultMission]
end

local function round(value: number): number
    return math.floor(value * 100 + 0.5) / 100
end

local function snapshot(state: any): { energy: number, water: number, food: number }
    return { energy = state.energy, water = state.water, food = state.food }
end

-- 화면 상태 (MissionState) ----------------------------------------------------------

local function facilityName(defId: string): Msg.Msg
    return Msg.new(FACILITY_NAMES[defId] or "world.placeholder.name")
end

local function lockMsg(state: any, m: any, defId: string): Msg.Msg?
    local def = m.facilities[defId]
    if def.unlockDeliveries and state.deliveries < def.unlockDeliveries then
        return Msg.new(
            "toast.pipe.locked",
            { done = state.deliveries, need = def.unlockDeliveries }
        )
    end
    for _, req in def.requires do
        if not Rules.isBuilt(state, req) then
            return Msg.new("toast.build.need_prereq", { facility = facilityName(req) })
        end
    end
    return nil
end

local function facilitiesView(state: any, m: any): { [string]: any }
    local out: { [string]: any } = {}
    local upkeep: { [string]: { energy: number, water: number } } = {}
    local list = Rules.upkeepBreakdown(state, MissionConfig)
    for _, row in list do
        upkeep[row.id] = { energy = row.energy, water = row.water }
    end
    -- 마지막 하루 마감에서 자원이 모자라 멈춘 시설 (Rules state.shed, stallMode "priority")
    local shed: { [string]: boolean } = {}
    for _, id in state.shed or {} do
        shed[id] = true
    end
    local farmEvery = m.facilities.farm and m.facilities.farm.harvestEveryDays
    local led = state.facilities.led
    if farmEvery and led and led.status == "active" and not led.paused then
        farmEvery = m.facilities.led.harvestEveryDays or farmEvery
    end
    for _, defId in m.facilityOrder do
        if defId ~= "airlock" then
            local def = m.facilities[defId]
            local found = false
            for id, f in state.facilities do
                if f.defId == defId then
                    found = true
                    local entry: { [string]: any } = {
                        status = if f.status == "building"
                            then "building"
                            elseif f.paused then "paused"
                            else "active",
                        daysLeft = if f.status == "building" then f.daysLeft else 0,
                        progress = if f.status == "building"
                            then round((f.buildDays - f.daysLeft) / math.max(1, f.buildDays))
                            else 1,
                        upkeep = upkeep[id] or { energy = 0, water = 0 },
                        siteIndex = f.siteIndex,
                        stalled = shed[id] == true,
                    }
                    if defId == "farm" and f.status == "active" and farmEvery then
                        entry.nextHarvestIn = math.max(0, farmEvery - f.progress)
                    end
                    if def.kind == "pipe" and f.status == "active" and def.deliverEveryDays then
                        entry.nextDeliveryIn = math.max(0, def.deliverEveryDays - f.progress)
                    end
                    out[id] = entry
                end
            end
            if not found then
                local unlock = lockMsg(state, m, defId)
                out[defId] = {
                    status = if unlock then "locked" else "available",
                    progress = 0,
                    daysLeft = def.buildDays,
                    unlockMsg = unlock,
                }
            end
        end
    end
    return out
end

local function airlockView(state: any): { [string]: any }
    local f = state.facilities.airlock
    if f == nil then
        return { status = "idle", daysLeft = 0 }
    elseif f.status == "building" then
        return { status = "inspecting", daysLeft = f.daysLeft }
    end
    local stalled = table.find(state.shed or {}, "airlock") ~= nil
    return { status = if f.paused then "paused" else "active", daysLeft = 0, stalled = stalled }
end

-- StreamingEnabled 대비 지도 좌표 (클라이언트가 월드에서 표시를 못 찾을 때 쓴다). 미션 표시는 바뀌지 않아 한 번만 만든다
local MAP_POINT_NAMES =
    { "Lander", "BaseExit", "RoverPark", "Airlock", "SolarField", "FarmPad", "WaterTank" }
local mapPointCache: { [string]: { x: number, z: number } }? = nil
local iceXZCache: { [string]: { x: number, z: number } }? = nil

local function xz(position: Vector3): { x: number, z: number }
    return { x = round(position.X), z = round(position.Z) }
end

local function mapPoints(): { [string]: { x: number, z: number } }
    if not mapPointCache then
        local points: { [string]: { x: number, z: number } } = {}
        for _, name in MAP_POINT_NAMES do
            local marker = MissionWorld.getMarker(name)
            if marker then
                points[name] = xz(marker.position)
            end
        end
        mapPointCache = points
    end
    return table.clone(mapPointCache :: any)
end

-- 얼음 후보지 MinePoint 지면 좌표 (표시 이름으로)
local function iceXZ(markerName: string): { x: number, z: number }?
    if not iceXZCache then
        local points: { [string]: { x: number, z: number } } = {}
        for _, site in MissionWorld.iceSites() do
            points[site.markerName] = xz(site.position)
        end
        iceXZCache = points
    end
    return (iceXZCache :: any)[markerName]
end

local function iceView(state: any): { any }
    local out = {}
    for index, site in state.sites do
        local point = iceXZ(site.id)
        local plan = Rules.tripPlan(state, MissionConfig, index, false)
        local rushPlan = Rules.tripPlan(state, MissionConfig, index, true)
        table.insert(out, {
            index = index,
            markerName = site.id,
            number = tonumber(string.match(site.id, "%d+")), -- 화면 이름 map.ice.label { n } (정렬 순서 index와 다르다)
            distance = math.floor(site.distance + 0.5),
            cooldownDaysLeft = site.cooldownLeft,
            pipe = site.pipeId ~= nil,
            fsdDays = plan and plan.days,
            fsdEnergy = plan and plan.energy,
            risk = plan and plan.risk or site.risk,
            rushDays = rushPlan and rushPlan.days,
            rushEnergy = rushPlan and rushPlan.energy,
            rushRisk = rushPlan and rushPlan.risk,
            rushHelps = plan ~= nil and plan.rushHelps,
            x = point and point.x,
            z = point and point.z,
        })
    end
    return out
end

local function stepMsg(state: any?, m: any): Msg.Msg
    if phase == "selecting" then
        return Msg.new("mission_select.title")
    elseif phase == "landing" then
        return Msg.new("mission.step.landing")
    elseif phase == "result" and lastResult then
        return (lastResult :: any).reason
    end
    if not state then
        return Msg.new("mission.step.landing")
    end
    local f = state.facilities
    if f.airlock == nil then
        return Msg.new("mission.step.airlock")
    end
    if state.panels < CFG.stepPanels then
        return Msg.new("mission.step.panels")
    end
    if state.deliveries == 0 and f.farm == nil then
        return if mode == "multi"
            then Msg.new("mission.step.water_multi")
            else Msg.new("mission.step.water_solo")
    end
    if f.farm == nil then
        return Msg.new("mission.step.farm")
    end
    if f.led == nil or f.nutrient == nil then
        return Msg.new("mission.step.upgrades")
    end
    local pipeDef = m.facilities.pipe
    if pipeDef then
        local hasPipe = false
        for _, facility in f do
            if facility.defId == "pipe" then
                hasPipe = true
            end
        end
        if not hasPipe then
            local need = pipeDef.unlockDeliveries or 0
            if state.deliveries < need then
                return Msg.new("mission.step.pipe_unlock", { done = state.deliveries, need = need })
            end
            return Msg.new("mission.step.pipe")
        end
    end
    if f.hydroponics == nil then
        return Msg.new("mission.step.hydroponics")
    end
    return Msg.new("mission.step.finish")
end

local function defaultRover(): { [string]: any }
    local m = MissionConfig.MANUAL_DRIVE
    return {
        state = "parked",
        damage = 0,
        maxDamage = viewMission().rover.maxDamage,
        battery = m.batteryMax,
        batteryMax = m.batteryMax,
        batteryPercent = 100,
        tank = 0,
        tankMax = viewMission().ice.amountPerTrip,
        boosting = false,
        boostHeat = 0,
        charging = false,
        atBase = true,
    }
end

-- 지금 상태를 CONTRACT_V2 5절 MissionState 모양으로
function MissionFlow.buildState(): { [string]: any }
    local m = viewMission()
    local state = rules
    local base: { [string]: any } = {
        phase = phase,
        missionId = missionId,
        mode = mode,
        players = maxPlayers,
        chooserUserId = if chooser then chooser.UserId else 0,
        totalDays = MissionConfig.TOTAL_DAYS,
        cap = m.cap,
        dayEndsAt = MissionClock.dayEndsAt(),
        mission = stepMsg(state, m),
        pipeSite = Interactions.pipeSite(),
        mapPoints = mapPoints(),
        roleMissions = RoleMissions.view(), -- 멀티 역할 미션 (솔로 nil, 점수와 무관)
    }
    if not state then
        base.day = 0
        base.resources = table.clone(m.start)
        base.net = { energy = 0, water = 0, food = 0 }
        base.daysLeft = {
            water = math.floor(m.start.water / math.max(1, m.crew.water)),
            food = math.floor(m.start.food / math.max(1, m.crew.food)),
        }
        base.lowWarn = { energy = false, water = false, food = false }
        base.panels = { installed = 0, today = 0, perDay = m.panels.perDay, total = m.panels.total }
        base.airlock = { status = "idle", daysLeft = 0 }
        base.facilities = {}
        base.ice = {}
        base.rover = defaultRover()
        base.deliveries = 0
        base.weather = nil
        base.stalled = false
        base.facilitiesShed = {}
        return base
    end
    local low = MissionConfig.SCORE.lowThreshold
    local crew = Rules.crewUse(state, MissionConfig)
    local _, _, upkeepWater = Rules.upkeepBreakdown(state, MissionConfig)
    local waterUse = crew.water + upkeepWater
    local start, before = dayStart, prevDayStart
    base.day = math.min(state.day, state.totalDays)
    base.totalDays = state.totalDays
    base.resources = { energy = state.energy, water = state.water, food = state.food }
    base.cap = state.cap
    base.net = if start and before
        then {
            energy = round(start.energy - before.energy),
            water = round(start.water - before.water),
            food = round(start.food - before.food),
        }
        else { energy = 0, water = 0, food = 0 }
    base.daysLeft = {
        water = if waterUse > 0 then math.floor(state.water / waterUse) else state.totalDays,
        food = if crew.food > 0 then math.floor(state.food / crew.food) else state.totalDays,
    }
    base.lowWarn = {
        energy = state.energy < low,
        water = state.water < low,
        food = state.food < low,
    }
    base.panels = {
        installed = state.panels,
        today = state.panelsToday,
        perDay = m.panels.perDay,
        total = m.panels.total,
    }
    base.airlock = airlockView(state)
    base.facilities = facilitiesView(state, m)
    base.ice = iceView(state)
    base.rover = RoverFleet.view(state)
    base.deliveries = state.deliveries
    local weather: any = Rules.weatherStatus(state)
    if weather and weather.stage == "warning" and not SpaceWeather.isWarning() then
        weather = nil
    end
    if weather then
        -- SEP와 GST가 같은 날이면 kind는 SEP지만 GST 규칙(지도, 핀, 파견, 파이프 거절)도 걸린다. 화면이 서버 거절과
        -- 같게 따로 알린다 (2026-11-15 QA B4)
        local sepOn, gstOn = Rules.weatherOn(state)
        weather.sep = weather.stage == "active" and sepOn ~= nil
        weather.gst = weather.stage == "active" and gstOn ~= nil
    end
    base.weather = weather
    base.stalled = state.stalled
    base.stallReason = state.stallReason
    -- 마지막 하루 마감에서 자원이 모자라 멈춘 시설 id (Rules state.shed, HUD가 이름을 보인다)
    base.facilitiesShed = table.clone(state.shed or {})
    return base
end

local function publish()
    publishQueued = false
    -- 탱크처럼 Rules 밖 값으로 켜고 끄는 프롬프트(하역)가 있어 보낼 때마다 맞춘다
    Interactions.refresh()
    Remotes.get("StateUpdate"):FireAllClients(MissionFlow.buildState())
end

local function markDirty()
    if publishQueued then
        return
    end
    publishQueued = true
    task.defer(function()
        if publishQueued then
            publish()
        end
    end)
end

-- 상태 교체와 월드 반영 -----------------------------------------------------------

-- 월드에 보낼 시설 목록: 자원이 모자라 멈춘 시설(state.shed)도 멈춘 모습으로 (에어록이면 산소 회복도 멈춘다)
local function worldFacilities(state: any): { [string]: any }
    local shed: { [string]: boolean } = {}
    for _, id in state.shed or {} do
        shed[id] = true
    end
    local list: { [string]: any } = {}
    for id, f in state.facilities do
        local copy = table.clone(f)
        copy.paused = f.paused or (f.status == "active" and shed[id] == true)
        list[id] = copy
    end
    return list
end

local function facilitySignature(list: { [string]: any }): string
    local parts = {}
    for id, f in list do
        table.insert(
            parts,
            string.format(
                "%s:%s:%d:%s:%s",
                id,
                f.status,
                f.daysLeft,
                tostring(f.paused),
                tostring(f.siteIndex)
            )
        )
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function syncWorld(prev: any, new: any)
    if new then
        local list = worldFacilities(new)
        local sig = facilitySignature(list)
        if sig ~= facilitySig then
            facilitySig = sig
            ServerUtil.safeCall("MissionWorld.syncFacilities", MissionWorld.syncFacilities, list)
        end
        if new.panels ~= panelCount then
            panelCount = new.panels
            ServerUtil.safeCall(
                "MissionWorld.setPanelCount",
                MissionWorld.setPanelCount,
                new.panels
            )
        end
    end
    RoverFleet.onRulesChanged(prev, new)
    Interactions.refresh()
end

local function commit(new: any, opts: { publish: boolean? }?)
    local prev = rules
    rules = new
    if opts and opts.publish == false then
        return
    end
    syncWorld(prev, new)
    markDirty()
end

export type ActOptions = { private: boolean?, okKind: string?, quiet: boolean? }

local function act(
    player: Player?,
    fn: (any, any) -> (boolean, any, any, any),
    opts: ActOptions?
): (boolean, Msg.Msg?)
    if phase ~= "playing" or rules == nil then
        if player then
            notify(player, Msg.new("toast.game.not_playing"), "warn")
        end
        return false, nil
    end
    local ok, new, msg, events = fn(rules, MissionConfig)
    local options: ActOptions = opts or {}
    if ok then
        commit(new)
        if msg and not options.quiet then
            local kind = options.okKind or "good"
            if options.private and player then
                notify(player, msg, kind)
            else
                notifyAll(msg, kind)
            end
        end
        if type(events) == "table" then
            for _, e in events do
                notifyAll(e, kindOf(e.key))
            end
        end
    elseif player and Msg.isMsg(msg) then
        notify(player, msg, "warn")
    end
    return ok, if Msg.isMsg(msg) then msg else nil
end

local function nearConsole(player: Player): boolean
    local position = PromptKit.rootPosition(player)
    if not position then
        return false
    end
    local console = MissionWorld.anchor("console")
    if console and (position - console.CFrame.Position).Magnitude <= CFG.consoleRadius then
        return true
    end
    local _, zoneId = MissionWorld.zoneAt(position)
    return zoneId == "lander"
end

local flow = {
    config = MissionConfig,
    phase = function(): string
        return phase
    end,
    mode = function(): string
        return mode
    end,
    missionId = function(): string?
        return missionId
    end,
    mission = currentMission,
    rules = function(): any
        return rules
    end,
    act = act,
    commit = commit,
    notify = notify,
    notifyAll = notifyAll,
    markDirty = markDirty,
    weather = function(): (boolean, boolean)
        if not rules then
            return false, false
        end
        local sep, gst = Rules.weatherOn(rules)
        return sep ~= nil, gst ~= nil
    end,
    contribute = function(player: Player?, field: any, amount: number?)
        ContributionsV2.add(player, field, amount)
        RoleMissions.onContribute(player, field, amount)
    end,
    roleOf = Roles.roleOf,
    canUseMap = Roles.canUseMap,
    nearConsole = nearConsole,
    roverSeat = RoverFleet.seat,
}

-- 미션 선택 ----------------------------------------------------------------

local function missionStates(): { { id: string, state: string } }
    local list = {}
    for _, id in CFG.missionOrder do
        local def = (MissionConfig.MISSIONS :: any)[id]
        local state = if def == nil then "locked" elseif def.playable then "playable" else "soon"
        table.insert(list, { id = id, state = state })
    end
    return list
end

local function selectPayload(player: Player): { [string]: any }
    return {
        chooserUserId = if chooser then chooser.UserId else 0,
        chooserName = if chooser then chooser.DisplayName else "",
        deadline = if selectArmed then selectDeadline else nil,
        defaultMissionId = CFG.defaultMission,
        missions = missionStates(),
        bestMedals = RecordsV2.bestMedals(player),
    }
end

local function sendSelectOpen(player: Player)
    Remotes.get("MissionSelectOpen"):FireClient(player, selectPayload(player))
end

local confirmMission: (id: string) -> ()

local function openSelection()
    selectToken += 1
    if not chooser then
        return
    end
    if selectArmed then
        selectDeadline = workspace:GetServerTimeNow() + CFG.selectSeconds
    end
    for _, player in Players:GetPlayers() do
        sendSelectOpen(player)
    end
    if not selectArmed then
        return
    end
    local token = selectToken
    task.delay(CFG.selectSeconds, function()
        if token == selectToken and phase == "selecting" then
            ServerUtil.safeCall("MissionFlow auto select", confirmMission, CFG.defaultMission)
        end
    end)
end

local function firstPlayer(except: Player?): Player?
    for _, player in Players:GetPlayers() do
        if player ~= except then
            return player
        end
    end
    return nil
end

local function beginSelecting(leaving: Player?)
    phase = "selecting"
    missionId = nil
    rules = nil
    mode = "solo"
    lastResult = nil
    dayStart, prevDayStart = nil, nil
    RecordsV2.clearSubmitted()
    chooser = firstPlayer(leaving)
    selectArmed = false
    openSelection()
    publish()
end

-- 세계 연결 (부팅과 재시작)
local function attachWorld()
    local root = MissionWorld.runtimeFolder()
    if root then
        AirlockDoors.attach(root)
    end
    RoverFleet.attach()
    Interactions.attach()
    facilitySig = ""
    panelCount = -1
end

local function detachWorld()
    Interactions.detach()
    RoverFleet.detach()
    AirlockDoors.detach()
end

local function ensureWorld(id: string)
    if worldMission == id then
        return
    end
    detachWorld()
    local ok = MissionWorld.init(id)
    if not ok then
        warn(
            "[MissionFlow] 미션 "
                .. id
                .. " 표시가 모자랍니다. 있는 것만 놓습니다"
        )
    end
    MissionWorld.placeBase()
    worldMission = id
    mapPointCache, iceXZCache = nil, nil
    attachWorld()
end

local function pickWindow(): any
    local windows = SpaceWeatherData.windows
    if #windows == 0 then
        return nil
    end
    local wanted = nextWindowId
    nextWindowId = nil
    if wanted then
        for _, window in windows do
            if window.id == wanted then
                return window
            end
        end
    end
    local index = math.clamp(math.floor(rng:NextNumber() * #windows) + 1, 1, #windows)
    return windows[index]
end

local function landerCFrame(): CFrame
    local shelter = MissionWorld.getShelter("lander")
    if shelter then
        return shelter.frame
    end
    local marker = MissionWorld.getMarker("Lander")
    return if marker then marker.cframe else CFrame.new()
end

local function startPlaying(token: number)
    if token ~= landingToken or phase ~= "landing" then
        return
    end
    Roles.finalize()
    phase = "playing"
    for _, player in Players:GetPlayers() do
        ContributionsV2.ensure(player)
    end
    MissionClock.start()
    SpaceWeather.start(rules)
    syncWorld(nil, rules)
    RoverFleet.refresh()
    publish()
end

confirmMission = function(id: string)
    if phase ~= "selecting" then
        return
    end
    selectToken += 1
    local list = Players:GetPlayers()
    missionId = id
    mode = if #list >= 2 then "multi" else "solo"
    maxPlayers = math.max(1, #list)
    ensureWorld(id)
    local seed = math.floor(rng:NextNumber() * 2147483646) + 1
    rules = Rules.newState(id, MissionConfig, seed, pickWindow(), {
        iceDistances = MissionWorld.iceDistances(),
        players = maxPlayers,
    })
    dayStart = snapshot(rules)
    prevDayStart = dayStart
    ContributionsV2.reset()
    RoleMissions.reset()
    for _, player in list do
        ContributionsV2.ensure(player)
    end
    RoverFleet.reset()
    Interactions.reset()
    RecordsV2.setMission(id)
    phase = "landing"
    Roles.begin(mode)
    syncWorld(nil, rules)
    local seconds = CFG.landingSeconds
    if mode == "multi" then
        seconds = math.max(seconds, Roles.CONFIG.selectSeconds)
    end
    Remotes.get("LandingSequence"):FireAllClients(id, landerCFrame(), seconds)
    publish()
    landingToken += 1
    local token = landingToken
    task.delay(seconds, function()
        ServerUtil.safeCall("MissionFlow startPlaying", startPlaying, token)
    end)
end

-- 하루 마감과 종료 ------------------------------------------------------------

-- 결과 "함께 한 일" 줄에 역할 미션 결과를 붙인다 (멀티만, 점수와 무관)
local function crewWithMissions(): { any }
    local rows = ContributionsV2.crew(CFG.crewRows)
    if mode == "multi" then
        for _, row in rows do
            row.roleMission = RoleMissions.resultFor(row.userId)
        end
    end
    return rows
end

local function endGame(result: any)
    MissionClock.stop()
    rules = Rules.finish(rules, MissionConfig, result)
    phase = "result"
    SpaceWeather.reset()
    for _, player in Players:GetPlayers() do
        ContributionsV2.ensure(player)
    end
    local report = Rules.finalScore(rules, MissionConfig)
    local summary = Rules.weatherSummary(rules)
    local deductions = {}
    for _, d in report.deductions do
        table.insert(deductions, {
            reason = d.reason,
            count = d.count,
            points = d.points,
            resource = d.resource,
            msg = d.msg,
        })
    end
    local info: { [string]: any } = {
        won = result.outcome == "won",
        medal = result.medal,
        reason = result.msg or Msg.new("end.lost.no_medal"),
        day = result.daysTaken,
        score = report.score,
        startScore = report.start,
        deductions = deductions,
        weather = {
            windowId = summary.id,
            startDate = summary.startDate,
            endDate = summary.endDate,
            sep = summary.sep,
            gst = summary.gst,
        },
        crew = crewWithMissions(),
        restartAvailableAt = workspace:GetServerTimeNow() + CFG.resultMinSeconds,
        chooserUserId = if chooser then chooser.UserId else 0,
        missionId = missionId,
        mode = mode,
        players = maxPlayers,
    }
    lastResult = info
    Remotes.get("GameOver"):FireAllClients(info)
    syncWorld(nil, rules)
    if result.medal and missionId then
        RecordsV2.submit({
            missionId = missionId,
            medal = result.medal,
            score = report.score,
            days = result.daysTaken,
            mode = mode,
            players = maxPlayers,
            members = ContributionsV2.members(),
        })
    end
    publish()
end

local function onDayTick()
    if phase ~= "playing" or not rules then
        return
    end
    local prev = rules
    local new, events = Rules.applyDay(prev, MissionConfig)
    prevDayStart = dayStart
    dayStart = snapshot(new)
    rules = new
    syncWorld(prev, new)
    SpaceWeather.onDay(prev, new)
    for _, e in events do
        if not SUPPRESSED[e.key] then
            notifyAll(e, kindOf(e.key))
        end
    end
    local result = Rules.checkEnd(new, MissionConfig)
    if result.outcome ~= "none" then
        endGame(result)
        return
    end
    publish()
end

-- 재시작 ----------------------------------------------------------------

local function spawnCFrame(): CFrame?
    local marker = MissionWorld.getMarker("SpawnLocation")
    if not marker then
        return nil
    end
    return CFrame.new(marker.position + Vector3.new(0, marker.size.Y / 2 + CFG.spawnLift, 0))
end

local function restart(leaving: Player?)
    MissionClock.stop()
    landingToken += 1
    selectToken += 1
    Sfx.stopAll()
    SpaceWeather.reset()
    local spawn = spawnCFrame()
    for _, player in Players:GetPlayers() do
        ServerUtil.unseatPlayer(player)
        local character = player.Character
        if spawn and character and player ~= leaving then
            pcall(function()
                character:PivotTo(spawn)
            end)
        end
    end
    detachWorld()
    MissionWorld.reset()
    attachWorld()
    OxygenV2.resetAll()
    Roles.reset()
    ContributionsV2.reset()
    RoleMissions.reset()
    RoverFleet.reset()
    Interactions.reset()
    beginSelecting(leaving)
end

local function onRequestRestart(player: Player)
    if phase ~= "result" then
        return
    end
    local info = lastResult
    if info then
        local remaining = info.restartAvailableAt - workspace:GetServerTimeNow()
        if remaining > 0 then
            notify(player, Msg.count("toast.restart.too_soon", math.ceil(remaining)), "info")
            return
        end
    end
    if chooser ~= player then
        local name = if chooser then chooser.DisplayName else ""
        notify(player, Msg.new("toast.restart.not_chooser", { name = name }), "info")
        return
    end
    restart()
end

local function onSelectMission(player: Player, id: any)
    if phase ~= "selecting" then
        return
    end
    if player ~= chooser then
        local name = if chooser then chooser.DisplayName else ""
        notify(player, Msg.new("mission_select.chooser", { name = name }), "info")
        return
    end
    local def = if typeof(id) == "string" then (MissionConfig.MISSIONS :: any)[id] else nil
    if not def or not def.playable then
        notify(player, Msg.new("toast.mission.not_ready"), "info")
        return
    end
    confirmMission(id)
end

-- 입장과 퇴장 ----------------------------------------------------------------

local function onPlayerAdded(player: Player)
    OxygenV2.addPlayer(player)
    Spacesuit.watch(player)
    if phase ~= "selecting" then
        ContributionsV2.ensure(player)
        maxPlayers = math.max(maxPlayers, #Players:GetPlayers())
    end
    Roles.onPlayerAdded(player)
    Remotes.get("StateUpdate"):FireClient(player, MissionFlow.buildState())
    RecordsV2.sendTo(player, lastResult ~= nil)
    if phase == "selecting" then
        if chooser == nil then
            chooser = player
            openSelection()
        else
            sendSelectOpen(player)
        end
    elseif phase == "result" and lastResult then
        Remotes.get("GameOver"):FireClient(player, lastResult)
    end
    markDirty()
end

local function onPlayerRemoving(player: Player)
    Roles.onPlayerRemoving(player)
    local nextChooser = firstPlayer(player)
    if nextChooser == nil then
        restart(player)
        return
    end
    if chooser == player then
        chooser = nextChooser
        if phase == "selecting" then
            openSelection()
        elseif phase == "result" and lastResult then
            local info = lastResult :: { [string]: any }
            info.chooserUserId = nextChooser.UserId
            Remotes.get("GameOver"):FireAllClients(info)
        end
    end
    markDirty()
end

-- 시작 ------------------------------------------------------------------

-- 부팅 (Main.server: MissionWorld.init(bootMission) -> placeBase 뒤)
function MissionFlow.start(bootMission: string?)
    if started then
        return
    end
    started = true
    worldMission = bootMission

    Roles.init(flow)
    RoleMissions.init(flow)
    SpaceWeather.init(flow)
    OxygenV2.init(flow)
    RoverFleet.init(flow)
    Interactions.init(flow)
    RecordsV2.init()

    AirlockDoors.setLockedNotice(function(player: Player)
        notify(player, Msg.new("toast.outdoor.locked_sep"), "warn")
    end)
    SpaceWeather.setSepHandler(RoverFleet.setWeatherHold)
    MissionClock.onDayTick(onDayTick)
    MissionClock.onBeforeTick(SpaceWeather.CONFIG.warningSeconds, SpaceWeather.beforeTick)

    Remotes.get("SelectMission").OnServerEvent:Connect(function(player: Player, id: any)
        ServerUtil.safeCall("SelectMission", onSelectMission, player, id)
    end)
    Remotes.get("MissionSelectSeen").OnServerEvent:Connect(function()
        ServerUtil.safeCall("MissionSelectSeen", function()
            -- 첫 사람이 미션 선택 화면에 들어온 순간부터 30초 (이미 세는 중이면 그대로)
            if phase == "selecting" and not selectArmed and chooser ~= nil then
                selectArmed = true
                openSelection()
            end
        end)
    end)
    Remotes.get("RequestRestart").OnServerEvent:Connect(function(player: Player)
        ServerUtil.safeCall("RequestRestart", onRequestRestart, player)
    end)
    Remotes.get("ChooseRole").OnServerEvent:Connect(function(player: Player, role: any)
        ServerUtil.safeCall("ChooseRole", Roles.choose, player, role)
    end)
    Remotes.get("SetPin").OnServerEvent:Connect(function(player: Player, siteIndex: any)
        ServerUtil.safeCall("SetPin", Roles.setPin, player, siteIndex)
    end)

    attachWorld()
    beginSelecting()

    Players.PlayerAdded:Connect(function(player: Player)
        ServerUtil.safeCall("MissionFlow PlayerAdded", onPlayerAdded, player)
    end)
    Players.PlayerRemoving:Connect(function(player: Player)
        ServerUtil.safeCall("MissionFlow PlayerRemoving", onPlayerRemoving, player)
    end)
    for _, player in Players:GetPlayers() do
        onPlayerAdded(player)
    end
end

-- 진단과 테스트 ----------------------------------------------------------------

function MissionFlow.getPhase(): string
    return phase
end

function MissionFlow.getRules(): any
    return rules
end

function MissionFlow.getResult(): { [string]: any }?
    return lastResult
end

-- 다음 판의 우주 기상 구간을 정한다 (Studio 시험, 스모크 테스트)
function MissionFlow.setNextWindow(windowId: string?)
    nextWindowId = windowId
end

-- 다음 DayTick을 바로 처리한다 (스모크 테스트와 Studio 명령줄 시험용)
function MissionFlow.debugAdvanceDay()
    onDayTick()
end

-- 미션 선택을 서버에서 확정한다 (DevBridge selectMission, Studio 재촬영용. selecting일 때만)
function MissionFlow.debugConfirmMission(id: string)
    confirmMission(id)
end

MissionFlow.flow = flow

return MissionFlow
