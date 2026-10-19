--!strict
-- 게임 흐름: phase 전이, DayTick 처리, 승리/실패 판정, 배속, 재시작 (CONTRACT 3절)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Simulation = require(ReplicatedStorage.Shared.Simulation)
local Types = require(ReplicatedStorage.Shared.Types)
local Airlock = require(script.Parent.Airlock)
local BaseLights = require(script.Parent.BaseLights)
local Construction = require(script.Parent.Construction)
local Contributions = require(script.Parent.Contributions)
local Events = require(script.Parent.Events)
local GameClock = require(script.Parent.GameClock)
local KitImports = require(script.Parent.KitImports)
local LandingSite = require(script.Parent.LandingSite)
local ModulePanels = require(script.Parent.ModulePanels)
local Oxygen = require(script.Parent.Oxygen)
local Records = require(script.Parent.Records)
local ResourceState = require(script.Parent.ResourceState)
local RunLog = require(script.Parent.RunLog)
local RoverBattery = require(script.Parent.RoverBattery)
local RoverBoost = require(script.Parent.RoverBoost)
local RoverDamage = require(script.Parent.RoverDamage)
local RoverDrive = require(script.Parent.RoverDrive)
local RoverRecovery = require(script.Parent.RoverRecovery)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)
local SolarPanels = require(script.Parent.SolarPanels)
local Spacesuit = require(script.Parent.Spacesuit)
local WaterLoop = require(script.Parent.WaterLoop)

local GameFlow = {}

local started = false
local lastGameOver: Types.GameOverInfo? = nil -- 결과 화면 정보 (재시작 게이트와 권한자 변경 재송신)
local lastSpeedRequest: { [Player]: number } = {} -- 플레이어별 마지막 SetSpeed 수락 시각 (os.clock)
local lastWasteNoticeDay: number? = nil -- 저장 상한으로 전력이 버려진다고 마지막으로 알린 날 (계속 버려지는 동안만 유지)

-- 기지가 놓이면 각 시스템을 연결한다.
-- Oxygen과 Airlock은 Construction이 Ghost/Built를 빼기 전에 구역과 문을 모아야 하고,
-- RoverRecovery는 물리가 시작되기 전에 로버 홈 위치를 저장해야 한다.
local function onBasePlaced(base: Model)
    Oxygen.attach(base)
    Airlock.attach(base)
    RoverRecovery.attach(base)
    SolarPanels.attach(base)
    Construction.attach(base)
    -- 모듈 외벽 제어반 (19차): 완공된 Built 위치를 Construction에서 받으므로 그 다음에 붙인다
    ModulePanels.attach(base)
    WaterLoop.attach(base)
    RoverDrive.attach(base)
    RoverDamage.attach(base)
    RoverBattery.attach(base)
    RoverBoost.attach(base)
    -- 착륙 유도등: 기지가 놓이는 순간이 착륙 연출 시작이다 (LandingSequence와 같은 틱)
    BaseLights.attach(base)
    BaseLights.playLanding(Config.LANDING_SECONDS)
    -- 행성을 이 기지에서 가장 가까운 얼음 쪽 하늘로
    ServerUtil.safeCall("KitImports Planet", KitImports.aimPlanetFrom, base:GetPivot().Position)
end

-- phase에 따라 켜고 끄는 프롬프트를 모두 현재 상태에 맞춘다
local function refreshPrompts(prev: Simulation.GameState?)
    local state = ResourceState.get()
    Construction.sync(prev, state)
    -- 제어반은 Construction이 완공 Built를 최종 위치에 놓은 뒤에 만든다 (가동 중지, 외벽 수리 프롬프트 포함)
    ModulePanels.refresh()
    SolarPanels.syncCount() -- 미세운석이 패널을 부쉈으면 월드 패널도 줄인다
    SolarPanels.refresh()
    WaterLoop.refresh()
    RoverRecovery.refresh()
    RoverDamage.refresh()
    local habitat = state.modules[Config.OXYGEN.habitatModule]
    Airlock.syncHum(habitat ~= nil and habitat.status == "active")
end

-- 착륙 연출이 끝나 playing이 되면 프롬프트를 켜고 시계를 시작한다
local function onPlaying()
    -- 아무것도 하지 않은 대원도 "함께 한 일" 표에 나오게 지금 있는 플레이어 행을 만든다
    for _, player in Players:GetPlayers() do
        Contributions.ensure(player)
    end
    refreshPrompts(nil)
    GameClock.start(ResourceState.get().speed)
end

local handlers: LandingSite.Handlers = {
    onBasePlaced = onBasePlaced,
    onPlaying = onPlaying,
}

local function endGame(result: Simulation.EndResult, reason: string, midDay: boolean?)
    GameClock.stop()
    local finished = Simulation.finishGame(ResourceState.get(), Config, result, midDay)
    ResourceState.set(finished)
    refreshPrompts(nil)
    ResourceState.publish()
    RunLog.finish(finished, result == "won", reason)
    RunLog.printSummary()
    local chooser = LandingSite.getChooser()
    for _, player in Players:GetPlayers() do
        Contributions.ensure(player)
    end
    local info: Types.GameOverInfo = {
        won = result == "won",
        reason = reason,
        day = finished.day,
        waterTrips = finished.waterTrips,
        oxygenDeaths = finished.oxygenDeaths,
        siteName = finished.siteName or "",
        restartAvailableAt = workspace:GetServerTimeNow() + Config.RESULT_MIN_SECONDS,
        chooserUserId = if chooser then chooser.UserId else 0,
        crew = Contributions.crew(Config.RECORDS.crewRows),
    }
    lastGameOver = info
    Remotes.get("GameOver"):FireAllClients(info)
    -- 승리 기록은 GameOver 뒤에 비동기로 저장하고, 끝나면 Records 이벤트로 순위를 보낸다
    if info.won then
        Records.submit(
            Records.makeEntry(
                info.day,
                info.siteName,
                Contributions.names(Config.RECORDS.crewNameLimit)
            )
        )
    end
end

-- DayTick 1회: 하루 계산 -> 화면 반영 -> 경고 -> 종료 판정 -> 송신
local function onDayTick()
    local prev = ResourceState.get()
    if prev.phase ~= "playing" then
        return
    end
    local new = Simulation.applyDay(prev, Config)
    ResourceState.set(new)
    refreshPrompts(prev)
    RunLog.snapshot(prev, new) -- 종료 판정 전에 남겨 마지막 날도 표에 들어간다

    local t = Config.TEXTS
    if new.modulesStalled and not prev.modulesStalled then
        ResourceState.notifyAll(t.modulesStalled, "warn")
    end
    -- 저장 상한: 버려지기 시작한 날, 그리고 계속 버려지면 ENERGY_WASTE_NOTIFY_DAYS일마다 알린다
    if new.energyWasted > 0 then
        local last = lastWasteNoticeDay
        if last == nil or new.day - last >= Config.ENERGY_WASTE_NOTIFY_DAYS then
            lastWasteNoticeDay = new.day
            ResourceState.notifyAll(t.energyWasted, "warn")
        end
    else
        lastWasteNoticeDay = nil
    end

    local result: Simulation.EndResult, reason: string = Simulation.checkEnd(new, Config)
    if result == "won" or result == "lost" then
        endGame(result, reason)
        return
    end
    -- 랜덤 이벤트 알림: 폭풍 예고, 시작, 끝, 미세운석 충돌 (2026-10-18 15차)
    Events.onDayTick(prev, new)
    if new.shortageDays > 0 then
        local text = string.format(
            t.shortageWarn,
            Simulation.shortageName(new, Config),
            new.shortageDays,
            Config.SHORTAGE_DAYS_TO_LOSE
        )
        ResourceState.notifyAll(text, "warn")
    end
    ResourceState.publish()
end

-- 새 게임: 상태 초기화 후 착륙지 선택 단계로. leaving은 지금 나가는 중이라 권한자에서 뺄 플레이어
local function beginNewGame(leaving: Player?)
    lastGameOver = nil
    lastWasteNoticeDay = nil
    Contributions.reset()
    RunLog.reset()
    ResourceState.reset()
    WaterLoop.resetDeposits()
    Oxygen.resetAll()
    ResourceState.publish()
    LandingSite.beginSelection(handlers, leaving)
end

-- 재시작: 전원 하차, 시스템 분리, 기지 제거, 상태 초기화 후 selecting으로
local function restart(leaving: Player?)
    GameClock.stop()
    Sfx.stopAll() -- 주행, 충전, 건설, 채취, 내부 허밍 루프를 모두 멈추고 지운다
    for _, player in Players:GetPlayers() do
        ServerUtil.unseatPlayer(player)
    end
    Airlock.detach()
    RoverRecovery.detach()
    SolarPanels.detach()
    ModulePanels.detach()
    Construction.detach()
    WaterLoop.detach()
    RoverDamage.detach()
    RoverBattery.detach()
    BaseLights.detach()
    RoverDrive.detach()
    Oxygen.detach()
    local base = ServerUtil.getBase()
    if base then
        base:Destroy()
    end
    beginNewGame(leaving)
end

local function onSetSpeed(player: Player, speed: any)
    local state = ResourceState.get()
    if state.phase ~= "playing" then
        return
    end
    if typeof(speed) ~= "number" or not table.find(Config.SPEEDS, speed) then
        return
    end
    if state.speed == speed then
        return
    end
    local now = os.clock()
    local last = lastSpeedRequest[player]
    if last and now - last < Config.SPEED_COOLDOWN_SECONDS then
        return
    end
    lastSpeedRequest[player] = now
    ResourceState.patch(function(s)
        s.speed = speed
    end)
    GameClock.setSpeed(speed)
    ResourceState.notifyAll(string.format(Config.TEXTS.speedChanged, speed), "info")
    ResourceState.publish()
end

-- 재시작 게이트 (리뷰 I12): 결과 화면이 RESULT_MIN_SECONDS 이상 떠 있었고, 요청자가 선택 권한자일 때만
local function onRequestRestart(player: Player)
    local phase = ResourceState.get().phase
    if phase ~= "won" and phase ~= "lost" then
        return
    end
    local info = lastGameOver
    if info then
        local remaining = info.restartAvailableAt - workspace:GetServerTimeNow()
        if remaining > 0 then
            ResourceState.notify(
                player,
                string.format(Config.TEXTS.restartTooSoon, math.ceil(remaining)),
                "info"
            )
            return
        end
    end
    local chooser = LandingSite.getChooser()
    if chooser ~= player then
        local name = if chooser then chooser.DisplayName else ""
        ResourceState.notify(player, string.format(Config.TEXTS.restartNotChooser, name), "info")
        return
    end
    restart()
end

local function onPlayerAdded(player: Player)
    ResourceState.publishTo(player)
    Records.sendTo(player)
    Oxygen.addPlayer(player)
    LandingSite.onPlayerAdded(player)
    Spacesuit.watch(player)
end

-- 마지막 플레이어가 나가면 재시작과 같은 정리를 하고 selecting으로 되돌린다 (선택 타이머도 취소됨)
local function onPlayerRemoving(player: Player)
    lastSpeedRequest[player] = nil
    local chooserChanged = LandingSite.onPlayerRemoving(player)
    for _, other in Players:GetPlayers() do
        if other ~= player then
            -- 결과 화면 중 권한자가 나갔으면 새 권한자로 결과 정보를 다시 보낸다 (재시작 버튼 주인 변경)
            local info = lastGameOver
            local phase = ResourceState.get().phase
            if chooserChanged and info and (phase == "won" or phase == "lost") then
                local chooser = LandingSite.getChooser()
                info.chooserUserId = if chooser then chooser.UserId else 0
                Remotes.get("GameOver"):FireAllClients(info)
            end
            return
        end
    end
    restart(player)
end

function GameFlow.start()
    if started then
        return
    end
    started = true

    LandingSite.init()
    -- 승리 기록: 서버 시작 때 1회 불러온다 (비동기)
    Records.init()
    WaterLoop.init()
    Oxygen.init()
    RoverRecovery.init()
    RoverBattery.init()
    GameClock.onDayTick(onDayTick)
    -- 산소 0은 즉시 실패 (하루 도중이므로 지금 날짜로 끝낸다)
    Oxygen.setDepletedHandler(function(player: Player)
        if ResourceState.get().phase == "playing" then
            endGame("lost", string.format(Config.TEXTS.endOxygen, player.DisplayName), true)
        end
    end)

    Remotes.get("SetSpeed").OnServerEvent:Connect(onSetSpeed)
    Remotes.get("RequestRestart").OnServerEvent:Connect(onRequestRestart)

    beginNewGame()

    Players.PlayerAdded:Connect(onPlayerAdded)
    Players.PlayerRemoving:Connect(onPlayerRemoving)
    for _, player in Players:GetPlayers() do
        onPlayerAdded(player)
    end
end

return GameFlow
