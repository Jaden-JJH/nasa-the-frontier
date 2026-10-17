--!strict
-- 착륙지 선택 단계: 선택 권한자, 타임아웃, BaseKit 복제와 배치, 착륙 연출 (CONTRACT 3절)
-- 흐름: selecting -> (SelectSite 또는 타임아웃) -> landing -> LANDING_SECONDS 뒤 playing, day = 1

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)
local Sfx = require(script.Parent.Sfx)

export type Handlers = {
    onBasePlaced: (base: Model) -> (), -- 기지 복제 직후 (각 시스템 연결)
    onPlaying: () -> (), -- phase가 playing이 된 직후 (시계 시작)
}

local LandingSite = {}

local token = 0 -- 선택 회차. 재시작하면 이전 타이머는 무시된다
local chooser: Player? = nil
local deadlineUnix = 0 -- workspace:GetServerTimeNow() 기준
local timerThread: thread? = nil
local handlers: Handlers? = nil
local initialized = false

local function getPad(siteId: number): BasePart?
    return ServerUtil.findPart(workspace:FindFirstChild("LandingPads"), "Pad" .. siteId)
end

local function stringAttribute(inst: Instance?, name: string, fallback: string): string
    if inst then
        local value = inst:GetAttribute(name)
        if typeof(value) == "string" and value ~= "" then
            return value
        end
    end
    return fallback
end

local function isValidSiteId(siteId: any): boolean
    return typeof(siteId) == "number"
        and siteId == siteId -- NaN 제외
        and siteId % 1 == 0
        and siteId >= 1
        and siteId <= #Config.SITES
end

-- 착륙지 정보: 패드 Attribute가 있으면 우선, 없으면 Config.SITES
function LandingSite.getSiteInfo(siteId: number): Types.SiteInfo
    local def = Config.SITES[siteId]
    local pad = getPad(siteId)
    local sunlight = def.sunlight
    if pad then
        local value = pad:GetAttribute("Sunlight")
        if typeof(value) == "number" and value == value then
            sunlight = math.clamp(value, 0, 1)
        end
    end
    return {
        id = siteId,
        name = stringAttribute(pad, "SiteName", def.name),
        sunlight = sunlight,
        iceDistanceLabel = stringAttribute(pad, "IceDistanceLabel", def.iceDistanceLabel),
        hazardLabel = stringAttribute(pad, "HazardLabel", def.hazardLabel),
        description = stringAttribute(pad, "Description", def.description),
    }
end

local function buildSelectionInfo(): Types.SiteSelectionInfo
    local sites: { Types.SiteInfo } = {}
    for id = 1, #Config.SITES do
        table.insert(sites, LandingSite.getSiteInfo(id))
    end
    local current = chooser
    return {
        chooserUserId = if current then current.UserId else 0,
        chooserName = if current then current.DisplayName else "",
        deadlineUnix = deadlineUnix,
        defaultSiteId = Config.DEFAULT_SITE_ID,
        sites = sites,
    }
end

-- 선택 마감 타이머 취소 (자기 자신 스레드는 취소하지 않는다)
local function cancelTimer()
    local thread = timerThread
    timerThread = nil
    if thread and thread ~= coroutine.running() and coroutine.status(thread) == "suspended" then
        task.cancel(thread)
    end
end

-- 선택 권한자 지정. 첫 지정 때 마감 타이머를 시작한다
local function assignChooser(player: Player)
    chooser = player
    if deadlineUnix == 0 then
        deadlineUnix = workspace:GetServerTimeNow() + Config.SITE_SELECT_TIMEOUT
        local myToken = token
        timerThread = task.delay(Config.SITE_SELECT_TIMEOUT, function()
            if myToken == token and ResourceState.get().phase == "selecting" then
                LandingSite.choose(Config.DEFAULT_SITE_ID)
            end
        end)
    end
    Remotes.get("SiteSelectionOpen"):FireAllClients(buildSelectionInfo())
end

-- 기지 스폰 위치 (Base.Lander.SpawnPoint 윗면 위)
function LandingSite.getSpawnCFrame(): CFrame?
    local lander = ServerUtil.findModel(ServerUtil.getBase(), "Lander")
    local spawnPoint = ServerUtil.findPart(lander, "SpawnPoint")
    if not spawnPoint then
        return nil
    end
    return spawnPoint.CFrame * CFrame.new(0, spawnPoint.Size.Y / 2 + Config.SPAWN_HEIGHT_OFFSET, 0)
end

-- 캐릭터를 착륙선 스폰 위치로 옮긴다 (좌석에 앉아 있으면 먼저 내린다)
function LandingSite.sendToLander(player: Player)
    local target = LandingSite.getSpawnCFrame()
    local character = player.Character
    if not target or not character then
        return
    end
    ServerUtil.unseat(character:FindFirstChildOfClass("Humanoid"))
    character:PivotTo(target)
end

-- BaseKit을 복제해 패드 윗면에 Origin이 오도록 배치한다
local function placeBase(siteId: number): Model?
    local kit = ServerStorage:FindFirstChild("BaseKit")
    local pad = getPad(siteId)
    if not kit or not kit:IsA("Model") or not pad then
        warn("[LandingSite] BaseKit 또는 착륙 패드를 찾지 못했습니다: Pad" .. siteId)
        return nil
    end
    local old = workspace:FindFirstChild("Base")
    if old then
        old:Destroy()
    end
    local base = kit:Clone()
    base.Name = "Base"
    local origin = base.PrimaryPart or ServerUtil.findPart(base, "Origin")
    if origin then
        -- Origin 바닥면이 패드 윗면에 닿는 위치
        local target = pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + origin.Size.Y / 2, 0)
        local pivotFromOrigin = origin.CFrame:ToObjectSpace(base:GetPivot())
        base:PivotTo(target * pivotFromOrigin)
    else
        base:PivotTo(pad.CFrame * CFrame.new(0, pad.Size.Y / 2, 0))
    end
    base.Parent = workspace
    return base
end

-- 착륙지 확정. 선택 단계가 아니면 무시한다
function LandingSite.choose(requestedSiteId: number)
    if ResourceState.get().phase ~= "selecting" then
        return
    end
    local siteId = requestedSiteId
    if not getPad(siteId) then
        siteId = Config.DEFAULT_SITE_ID
    end
    local base = placeBase(siteId)
    if not base then
        return
    end
    cancelTimer()
    local myToken = token
    local info = LandingSite.getSiteInfo(siteId)
    ResourceState.patch(function(s)
        s.phase = "landing"
        s.siteId = siteId
        s.siteName = info.name
        s.sunlight = info.sunlight
    end)

    local current = handlers
    if current then
        current.onBasePlaced(base)
    end
    for _, player in Players:GetPlayers() do
        LandingSite.sendToLander(player)
    end

    local lander = ServerUtil.findModel(base, "Lander")
    local landerCFrame = if lander then lander:GetPivot() else base:GetPivot()
    -- 착륙 연출 추진기 효과음 (착륙선 위치)
    local landerPart = if lander
        then lander.PrimaryPart or lander:FindFirstChildWhichIsA("BasePart", true)
        else nil
    Sfx.play("landing_thrust", landerPart)
    ResourceState.publish()
    Remotes.get("LandingSequence"):FireAllClients(siteId, landerCFrame)

    task.delay(Config.LANDING_SECONDS, function()
        if myToken ~= token or ResourceState.get().phase ~= "landing" then
            return
        end
        ResourceState.patch(function(s)
            s.phase = "playing"
            s.day = 1
        end)
        ResourceState.publish()
        local after = handlers
        if after then
            after.onPlaying()
        end
    end)
end

-- 새 선택 단계 시작 (게임 시작과 재시작). phase는 호출 전에 selecting이어야 한다.
-- leaving은 PlayerRemoving 중이라 아직 목록에 남아 있는 플레이어 (권한자에서 제외)
function LandingSite.beginSelection(newHandlers: Handlers, leaving: Player?)
    cancelTimer()
    token += 1
    handlers = newHandlers
    chooser = nil
    deadlineUnix = 0
    for _, player in Players:GetPlayers() do
        if player ~= leaving then
            assignChooser(player)
            return
        end
    end
end

function LandingSite.onPlayerAdded(player: Player)
    if ResourceState.get().phase == "selecting" then
        if chooser == nil then
            assignChooser(player)
        else
            Remotes.get("SiteSelectionOpen"):FireClient(player, buildSelectionInfo())
        end
    end
    -- 기지가 있으면 (재)스폰할 때마다 착륙선 앞으로
    player.CharacterAdded:Connect(function(character)
        if not ServerUtil.getBase() then
            return
        end
        character:WaitForChild("HumanoidRootPart", Config.CHARACTER_LOAD_TIMEOUT)
        -- 기본 스폰 배치가 끝난 다음 프레임에 옮겨야 덮어써지지 않는다
        task.wait()
        if player.Character == character then
            LandingSite.sendToLander(player)
        end
    end)
end

-- 권한자가 나가면 남은 플레이어 중 가장 먼저 들어온 사람에게 넘긴다 (모든 단계).
-- 선택 단계에서는 선택 화면도 다시 보낸다. 권한자가 바뀌었으면 true
function LandingSite.onPlayerRemoving(player: Player): boolean
    if player ~= chooser then
        return false
    end
    chooser = nil
    for _, other in Players:GetPlayers() do
        if other ~= player then
            if ResourceState.get().phase == "selecting" then
                assignChooser(other) -- 마감 시각은 그대로 유지
            else
                chooser = other
            end
            return true
        end
    end
    return true
end

-- 현재 선택 권한자 (재시작 권한에도 쓴다). 권한자가 없거나 나갔으면 가장 먼저 들어온 플레이어
function LandingSite.getChooser(): Player?
    local current = chooser
    local list = Players:GetPlayers()
    if current and table.find(list, current) then
        return current
    end
    local first = list[1]
    chooser = first
    return first
end

-- SelectSite 수신 연결 (한 번만)
function LandingSite.init()
    if initialized then
        return
    end
    initialized = true
    Remotes.get("SelectSite").OnServerEvent:Connect(function(player: Player, siteId: any)
        if ResourceState.get().phase ~= "selecting" then
            return
        end
        if player ~= chooser then
            local name = if chooser then chooser.DisplayName else ""
            ResourceState.notify(player, string.format(Config.TEXTS.notChooser, name), "warn")
            return
        end
        if not isValidSiteId(siteId) then
            return
        end
        LandingSite.choose(siteId)
    end)
end

return LandingSite
