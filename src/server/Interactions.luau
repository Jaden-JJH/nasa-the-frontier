--!strict
-- v2 상호작용 프롬프트 (docs/CONTRACT_V2.md 3절, 7.5). MissionWorld 상호작용 자리(anchor)에 PromptKit 프롬프트를 붙이고
-- MissionFlow의 Rules 창구(flow.act)로 처리한다. 문장은 쓰지 않는다(ActionKey, ObjectKey, ActionArgs만).
--   airlockPanel  에어록 점검 시작 -> 가동 뒤에는 멈춤/재개 (Q28, Q33)
--   installPad    태양광 패널 설치 (홀드 = MissionConfig panels.installSeconds)
--   buildSpot     재배 공간 착공. 재배 공간이 생기면 옆에 업그레이드 착공 자리 3개(LED, 영양분, 수경)를 만든다
--   pipeSpot      파이프 착공 (해금 뒤, 콘솔 SetPipeSite로 고른 얼음 후보지로. 안 골랐으면 "콘솔에서 고르기")
--   unloadPoint   물 하역 (RoverFleet.unload)
--   console       콘솔 열기 (Attribute OpenUI = "console", 클라이언트가 로컬 Triggered로 연다. 서버는 아무것도 안 한다)
--   IceN.MinePoint 얼음 채취 (RoverFleet.collect, 운전석). 쿨타임이면 남은 일수, 파이프가 연결되면 그 표시
--   시설 제어반   멈춤/재개 (MissionWorld.controlPanel(id), E 1초, Q33). 바꾸면 모두에게 알림
-- 원격 요청: SetFacilityPaused(facilityId, paused), SetPipeSite(siteIndex)도 여기서 처리한다.
-- MissionWorld.reset 뒤에는 attach를 다시 부른다(프롬프트가 MissionRuntime과 함께 지워진다).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Rules = require(ReplicatedStorage.Shared.Rules)
local MissionWorld = require(script.Parent.MissionWorld)
local PromptKit = require(script.Parent.PromptKit)
local RoverFleet = require(script.Parent.RoverFleet)
local ServerUtil = require(script.Parent.ServerUtil)

local Interactions = {}

-- 엔진 수준 값 (studs, 초). 홀드 시간 중 MissionConfig에 있는 것(패널 3초, 채취 3초, 하역 3초)은 거기서 읽는다
Interactions.CONFIG = {
    promptDistance = 10,
    icePromptDistance = 18, -- 로버 운전석이 높아서 넉넉하게
    consoleDistance = 8,
    inspectHold = 1,
    buildHold = 1,
    pauseHold = 1, -- [Q33] E 1초
    upgradeSpacing = 4, -- 업그레이드 착공 자리 간격
    upgradeOffset = 6, -- 재배 공간 착공 자리에서 업그레이드 줄까지 거리
    panelRemoteDistance = 14, -- SetFacilityPaused: 제어반에서 이 안이면 허용
}
local CFG = Interactions.CONFIG

local FACILITY_NAMES: { [string]: string } = {
    airlock = "facility.airlock.name",
    farm = "facility.farm.name",
    led = "facility.led.name",
    nutrient = "facility.nutrient.name",
    pipe = "facility.pipe.name",
    hydroponics = "facility.hydroponics.name",
}
local UPGRADES = { "led", "nutrient", "hydroponics" }

local flow: any = nil
local initialized = false
local connections: { RBXScriptConnection } = {}
local created: { Instance } = {}
local prompts: { [string]: ProximityPrompt } = {}
local panelPrompts: { [string]: { part: BasePart, prompt: ProximityPrompt } } = {}
local icePrompts: { [number]: { part: BasePart, prompt: ProximityPrompt } } = {}
local pipeSite: number? = nil

local function nameMsg(defId: string): Msg.Msg
    local key = FACILITY_NAMES[defId] or "world.placeholder.name"
    return Msg.new(key)
end

-- 얼음 후보지 이름 (map.ice.label { n }, n = 출구에서 가까운 순 번호 siteIndex)
local function siteLabel(siteIndex: number): Msg.Msg
    return Msg.new("map.ice.label", { n = siteIndex })
end

local function mission(): any
    return if flow then flow.mission() else nil
end

local function facilityDef(defId: string): any
    local m = mission() or MissionConfig.MISSIONS.C
    return m.facilities[defId]
end

local function connect(prompt: ProximityPrompt, handler: (Player) -> ())
    table.insert(
        connections,
        prompt.Triggered:Connect(function(player: Player)
            ServerUtil.safeCall("Interactions", handler, player)
        end)
    )
end

local function makeAt(id: string, anchorId: string, spec: PromptKit.Spec, handler: (Player) -> ())
    local part = MissionWorld.anchor(anchorId)
    if not part then
        warn("[Interactions] 상호작용 자리 없음: " .. anchorId)
        return
    end
    local prompt = PromptKit.make(part, spec)
    prompts[id] = prompt
    connect(prompt, handler)
end

local function playing(): boolean
    return flow ~= nil and flow.phase() == "playing"
end

-- 처리 함수 --------------------------------------------------------------

local function onAirlock(player: Player)
    local state = flow.rules()
    if not state then
        return
    end
    local airlock = state.facilities.airlock
    if airlock == nil then
        local ok = flow.act(player, Rules.inspectAirlock)
        if ok then
            flow.contribute(player, "builds", 1)
        end
    elseif airlock.status == "active" then
        flow.act(player, function(s, c)
            return Rules.setPaused(s, c, "airlock", not airlock.paused)
        end, { okKind = "info" })
    end
end

local function onInstallPanel(player: Player)
    local ok = flow.act(player, Rules.installPanel)
    if ok then
        flow.contribute(player, "panels", 1)
    end
end

local function startBuild(player: Player, defId: string, siteIndex: number?)
    local ok = flow.act(player, function(s, c)
        return Rules.startBuild(s, c, defId, siteIndex)
    end)
    if ok then
        flow.contribute(player, "builds", 1)
    end
end

local function onPipe(player: Player)
    local site = pipeSite
    if site == nil then
        flow.notify(player, Msg.new("toast.pipe.pick_site"), "warn")
        return
    end
    startBuild(player, "pipe", site)
end

local function togglePause(player: Player, facilityId: string, paused: boolean?)
    local state = flow.rules()
    local f = state and state.facilities[facilityId]
    if not f then
        flow.act(player, function(s, c)
            return Rules.setPaused(s, c, facilityId, paused == true)
        end)
        return
    end
    local target = if paused == nil then not f.paused else paused
    flow.act(player, function(s, c)
        return Rules.setPaused(s, c, facilityId, target)
    end, { okKind = "info" })
end

-- 업그레이드 착공 자리 3개 (재배 공간 착공 자리 옆, 한 줄)
local function makeUpgradeSpots()
    local spot = MissionWorld.anchor("buildSpot")
    local root = MissionWorld.runtimeFolder()
    if not spot or not root then
        return
    end
    local folder = Instance.new("Folder")
    folder.Name = "InteractionPoints"
    folder.Parent = root
    table.insert(created, folder)
    for i, defId in UPGRADES do
        local offset = (i - 2) * CFG.upgradeSpacing
        local part = Instance.new("Part")
        part.Name = "UpgradeSpot_" .. defId
        part.Size = Vector3.new(2, 1, 2)
        part.CFrame = spot.CFrame * CFrame.new(offset, 0.5, -CFG.upgradeOffset)
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.Transparency = 1
        part:SetAttribute("FacilityDefId", defId)
        part.Parent = folder
        local prompt = PromptKit.make(part, {
            name = "BuildPrompt",
            actionKey = "prompt.act.build",
            actionArgs = { facility = nameMsg(defId) },
            objectKey = FACILITY_NAMES[defId],
            hold = CFG.buildHold,
            distance = CFG.promptDistance,
            enabled = false,
        })
        prompts["upgrade_" .. defId] = prompt
        connect(prompt, function(player: Player)
            startBuild(player, defId, nil)
        end)
    end
end

local function makeIcePrompts()
    local root = MissionWorld.runtimeFolder()
    local folder = root and root:FindFirstChild("IceSites")
    if not folder then
        return
    end
    for _, model in folder:GetChildren() do
        local point = model:FindFirstChild("MinePoint")
        local index = point and point:GetAttribute("SiteIndex")
        if point and point:IsA("BasePart") and typeof(index) == "number" then
            local siteIndex: number = index
            local prompt = PromptKit.make(point, {
                name = "MinePrompt",
                actionKey = "prompt.act.collect_ice",
                objectKey = "world.ice_site.name",
                hold = MissionConfig.MANUAL_DRIVE.fillSeconds,
                distance = CFG.icePromptDistance,
                enabled = false,
            })
            icePrompts[siteIndex] = { part = point, prompt = prompt }
            connect(prompt, function(player: Player)
                RoverFleet.collect(player, siteIndex, point)
            end)
        end
    end
end

-- 시설 제어반 프롬프트 맞추기 (시설이 생기거나 다시 놓이면 새로 붙인다)
local function syncPanels(state: any)
    local wanted: { [string]: boolean } = {}
    if state then
        for id, f in state.facilities do
            local def = facilityDef(f.defId)
            if f.status == "active" and def and def.canPause then
                wanted[id] = true
            end
        end
    end
    for id, entry in panelPrompts do
        local part = MissionWorld.controlPanel(id)
        if not wanted[id] or part ~= entry.part or entry.prompt.Parent == nil then
            pcall(function()
                entry.prompt:Destroy()
            end)
            panelPrompts[id] = nil
        end
    end
    for id in wanted do
        -- 에어록 제어반은 airlockPanel 프롬프트가 맡는다 (점검과 멈춤 겸용)
        if id ~= "airlock" and not panelPrompts[id] then
            local part = MissionWorld.controlPanel(id)
            if part then
                local prompt = PromptKit.make(part, {
                    name = "PausePrompt",
                    actionKey = "prompt.act.pause",
                    objectKey = FACILITY_NAMES[state.facilities[id].defId],
                    hold = CFG.pauseHold,
                    distance = CFG.promptDistance,
                })
                panelPrompts[id] = { part = part, prompt = prompt }
                local facilityId = id
                connect(prompt, function(player: Player)
                    togglePause(player, facilityId, nil)
                end)
            end
        end
    end
    for id, entry in panelPrompts do
        local f = state and state.facilities[id]
        PromptKit.set(
            entry.prompt,
            if f and f.paused then "prompt.act.resume" else "prompt.act.pause",
            nil,
            FACILITY_NAMES[if f then f.defId else "farm"]
        )
        PromptKit.setEnabled(entry.prompt, playing())
    end
end

-- 상태에 맞춰 키와 활성 여부를 다시 쓴다 (commit마다)
function Interactions.refresh()
    local state = if flow then flow.rules() else nil
    local live = playing() and state ~= nil
    local m = mission() or MissionConfig.MISSIONS.C

    local airlockPrompt = prompts.airlock
    if airlockPrompt then
        local airlock = state and state.facilities.airlock
        if airlock == nil then
            PromptKit.set(airlockPrompt, "prompt.act.inspect", nil, "facility.airlock.name")
            PromptKit.setHold(airlockPrompt, CFG.inspectHold)
            PromptKit.setEnabled(airlockPrompt, live)
        elseif airlock.status == "active" then
            PromptKit.set(
                airlockPrompt,
                if airlock.paused then "prompt.act.resume" else "prompt.act.pause",
                nil,
                "facility.airlock.name"
            )
            PromptKit.setHold(airlockPrompt, CFG.pauseHold)
            PromptKit.setEnabled(airlockPrompt, live)
        else
            PromptKit.setEnabled(airlockPrompt, false)
        end
    end

    local panel = prompts.installPad
    if panel then
        PromptKit.setEnabled(panel, live and state.panels < m.panels.total)
    end

    local farmPrompt = prompts.farm
    local hasFarm = state ~= nil and state.facilities.farm ~= nil
    if farmPrompt then
        PromptKit.setEnabled(farmPrompt, live and not hasFarm)
    end
    for _, defId in UPGRADES do
        local prompt = prompts["upgrade_" .. defId]
        if prompt then
            local started = state ~= nil and state.facilities[defId] ~= nil
            PromptKit.setEnabled(
                prompt,
                live and hasFarm and not started and m.facilities[defId] ~= nil
            )
        end
    end

    local pipePrompt = prompts.pipe
    if pipePrompt then
        local def = m.facilities.pipe
        local count = 0
        if state then
            for _, f in state.facilities do
                if f.defId == "pipe" then
                    count += 1
                end
            end
        end
        local unlocked = def ~= nil
            and state ~= nil
            and state.deliveries >= (def.unlockDeliveries or 0)
            and count < (def.maxCount or 1)
        if pipeSite ~= nil and state and state.sites[pipeSite] and state.sites[pipeSite].pipeId then
            pipeSite = nil
        end
        if pipeSite == nil then
            PromptKit.set(pipePrompt, "prompt.act.pick_pipe_site", nil, "facility.pipe.name")
            PromptKit.setHold(pipePrompt, 0)
        else
            PromptKit.set(
                pipePrompt,
                "prompt.act.build",
                { facility = nameMsg("pipe") },
                "facility.pipe.name"
            )
            PromptKit.setHold(pipePrompt, CFG.buildHold)
        end
        PromptKit.setEnabled(pipePrompt, live and unlocked)
    end

    local unload = prompts.unload
    if unload then
        PromptKit.setEnabled(unload, live and RoverFleet.tankAmount() > 0)
    end

    local console = prompts.console
    if console then
        PromptKit.setEnabled(console, flow ~= nil and flow.phase() ~= "selecting")
    end

    for siteIndex, entry in icePrompts do
        local site = state and state.sites[siteIndex]
        if site and site.pipeId then
            PromptKit.set(entry.prompt, "prompt.act.ice_piped", nil, "world.ice_site.name")
            PromptKit.setHold(entry.prompt, 0)
        elseif site and site.cooldownLeft > 0 then
            PromptKit.set(
                entry.prompt,
                "prompt.act.ice_wait",
                Msg.count("prompt.act.ice_wait", site.cooldownLeft).args,
                "world.ice_site.name"
            )
            PromptKit.setHold(entry.prompt, 0)
        else
            PromptKit.set(entry.prompt, "prompt.act.collect_ice", nil, "world.ice_site.name")
            PromptKit.setHold(entry.prompt, MissionConfig.MANUAL_DRIVE.fillSeconds)
        end
        PromptKit.setEnabled(entry.prompt, live)
    end

    syncPanels(if live then state else nil)
end

-- 콘솔에서 고른 파이프 얼음 후보지 (착공 전)
function Interactions.pipeSite(): number?
    return pipeSite
end

function Interactions.setPipeSite(player: Player, siteIndex: any)
    if not playing() then
        return
    end
    local state = flow.rules()
    if
        typeof(siteIndex) ~= "number"
        or siteIndex % 1 ~= 0
        or not state
        or state.sites[siteIndex] == nil
    then
        return
    end
    if not flow.nearConsole(player) then
        flow.notify(player, Msg.new("toast.console.too_far"), "warn")
        return
    end
    -- 파이프 자리 고르기는 건설이라 역할과 무관하다 (Q25: 잠그는 것은 전체 지도와 핀뿐)
    local _, gst = flow.weather()
    if gst then
        flow.notify(player, Msg.new("toast.map.offline_gst"), "warn")
        return
    end
    local def = (mission() or MissionConfig.MISSIONS.C).facilities.pipe
    if def and state.deliveries < (def.unlockDeliveries or 0) then
        flow.notify(
            player,
            Msg.new("toast.pipe.locked", { done = state.deliveries, need = def.unlockDeliveries }),
            "warn"
        )
        return
    end
    local site = state.sites[siteIndex]
    if site.pipeId ~= nil then
        flow.notify(
            player,
            Msg.new("toast.pipe.site_taken", { site = siteLabel(siteIndex) }),
            "warn"
        )
        return
    end
    pipeSite = siteIndex
    flow.notifyAll(Msg.new("toast.pipe.site_set", { site = siteLabel(siteIndex) }), "info")
    Interactions.refresh()
    flow.markDirty()
end

function Interactions.setFacilityPaused(player: Player, facilityId: any, paused: any)
    if not playing() or typeof(facilityId) ~= "string" or typeof(paused) ~= "boolean" then
        return
    end
    local near = flow.nearConsole(player)
        or PromptKit.near(player, MissionWorld.controlPanel(facilityId), CFG.panelRemoteDistance)
    if not near then
        flow.notify(player, Msg.new("toast.facility.too_far"), "warn")
        return
    end
    togglePause(player, facilityId, paused)
end

-- 기지가 놓인 뒤 (부팅, MissionWorld.reset 뒤)
function Interactions.attach()
    Interactions.detach()
    local m = mission() or MissionConfig.MISSIONS.C
    makeAt("airlock", "airlockPanel", {
        name = "AirlockPrompt",
        actionKey = "prompt.act.inspect",
        objectKey = "facility.airlock.name",
        hold = CFG.inspectHold,
        distance = CFG.promptDistance,
        enabled = false,
    }, onAirlock)
    makeAt("installPad", "installPad", {
        name = "PanelPrompt",
        actionKey = "prompt.act.install_panel",
        objectKey = "world.solar_field.name",
        hold = m.panels.installSeconds,
        distance = CFG.promptDistance,
        enabled = false,
    }, onInstallPanel)
    makeAt("farm", "buildSpot", {
        name = "BuildPrompt",
        actionKey = "prompt.act.build",
        actionArgs = { facility = nameMsg("farm") },
        objectKey = "facility.farm.name",
        hold = CFG.buildHold,
        distance = CFG.promptDistance,
        enabled = false,
    }, function(player: Player)
        startBuild(player, "farm", nil)
    end)
    makeAt("pipe", "pipeSpot", {
        name = "PipePrompt",
        actionKey = "prompt.act.pick_pipe_site",
        objectKey = "facility.pipe.name",
        hold = 0,
        distance = CFG.promptDistance,
        enabled = false,
    }, onPipe)
    makeAt("unload", "unloadPoint", {
        name = "UnloadPrompt",
        actionKey = "prompt.act.unload_water",
        objectKey = "world.water_tank.name",
        hold = MissionConfig.MANUAL_DRIVE.unloadSeconds,
        distance = CFG.promptDistance,
        enabled = false,
    }, function(player: Player)
        RoverFleet.unload(player)
    end)
    makeAt("console", "console", {
        name = "ConsolePrompt",
        actionKey = "prompt.act.open_console",
        objectKey = "world.console.name",
        hold = 0,
        distance = CFG.consoleDistance,
        enabled = false,
    }, function() end)
    local console = prompts.console
    if console then
        console:SetAttribute("OpenUI", "console")
    end
    makeUpgradeSpots()
    makeIcePrompts()
    Interactions.refresh()
end

function Interactions.detach()
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, prompt in prompts do
        pcall(function()
            prompt:Destroy()
        end)
    end
    table.clear(prompts)
    for _, entry in panelPrompts do
        pcall(function()
            entry.prompt:Destroy()
        end)
    end
    table.clear(panelPrompts)
    for _, entry in icePrompts do
        pcall(function()
            entry.prompt:Destroy()
        end)
    end
    table.clear(icePrompts)
    for _, inst in created do
        pcall(function()
            inst:Destroy()
        end)
    end
    table.clear(created)
end

-- 새 판
function Interactions.reset()
    pipeSite = nil
end

-- 테스트와 진단용: 이름으로 프롬프트 (airlock, installPad, farm, upgrade_led, pipe, unload, console)
function Interactions.prompt(id: string): ProximityPrompt?
    return prompts[id]
end

function Interactions.icePrompt(siteIndex: number): ProximityPrompt?
    local entry = icePrompts[siteIndex]
    return entry and entry.prompt
end

function Interactions.panelPrompt(facilityId: string): ProximityPrompt?
    local entry = panelPrompts[facilityId]
    return entry and entry.prompt
end

function Interactions.init(api: any)
    flow = api
    if initialized then
        return
    end
    initialized = true
    Remotes.get("SetFacilityPaused").OnServerEvent
        :Connect(function(player: Player, id: any, paused: any)
            ServerUtil.safeCall(
                "SetFacilityPaused",
                Interactions.setFacilityPaused,
                player,
                id,
                paused
            )
        end)
    Remotes.get("SetPipeSite").OnServerEvent:Connect(function(player: Player, siteIndex: any)
        ServerUtil.safeCall("SetPipeSite", Interactions.setPipeSite, player, siteIndex)
    end)
end

return Interactions
