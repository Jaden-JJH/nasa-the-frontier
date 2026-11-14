--!strict
-- v2 우주 기상 연출 (V2_PLAN Q14, Q15, Q36. docs/CONTRACT_V2.md 2.2 SpaceWeather, 4.1 SpaceWeather)
-- 사건(어느 날 SEP, GST)은 Rules가 정한다(state.weather, Rules.weatherOn). 이 모듈은 화면과 월드 효과만 한다.
--   경보: 내일 SEP가 시작하면 하루가 끝나기 CONFIG.warningSeconds(15초, 반나절) 전에 SpaceWeather{ stage = "warning" }.
--   SEP 시작(DayTick): stage "active". 밖에 있는 대원은 가까운 로버 운전석에 자동 탑승, 로버가 멀거나 차 있으면 에어록 안으로.
--     문 잠금(AirlockDoors), 직접 운전 로버 정지(RoverFleet). 자율주행 정지와 야외 행동 금지는 Rules가 한다.
--   SEP 끝: stage "ended", 문 열림, 로버 다시 움직임.
--   GST 시작과 끝: stage "active", "ended". 지도와 핀 끊김은 클라이언트가 그리고, 파견과 핀 거절은 Rules와 Roles가 한다.
-- 페이로드: { kind, stage, day, durationDays, sourceDate = { year, month, day } } (사건마다 실제 날짜, Q36)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Msg = require(ReplicatedStorage.Shared.Msg)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Rules = require(ReplicatedStorage.Shared.Rules)
local AirlockDoors = require(script.Parent.AirlockDoors)
local OxygenV2 = require(script.Parent.OxygenV2)
local PromptKit = require(script.Parent.PromptKit)

local SpaceWeather = {}

-- 엔진 수준 값
SpaceWeather.CONFIG = {
    warningSeconds = 15, -- [Q15] SEP 15초(반나절) 전 경보
    roverShelterRadius = 40, -- 이 안의 빈 로버에 자동 탑승 (studs)
}
local CFG = SpaceWeather.CONFIG

local flow: any = nil
local warningFor: number? = nil -- 경보를 보낸 SEP 시작일
local sepOn = false
local gstOn = false
local onSepChanged: ((boolean) -> ())? = nil

local function payload(kind: string, stage: string, e: any): { [string]: any }
    return {
        kind = kind,
        stage = stage,
        day = e and e.day,
        durationDays = e and e.durationDays,
        sourceDate = if e and e.sourceDate then table.clone(e.sourceDate) else nil,
    }
end

local function fire(kind: string, stage: string, e: any)
    Remotes.get("SpaceWeather"):FireAllClients(payload(kind, stage, e))
end

function SpaceWeather.init(api: any)
    flow = api
end

-- SEP 시작과 끝을 RoverFleet에 알리는 함수 (MissionFlow가 연결)
function SpaceWeather.setSepHandler(fn: (boolean) -> ())
    onSepChanged = fn
end

-- 경보가 나간 뒤인지 (StateUpdate.weather의 warning 단계는 이때부터 보인다)
function SpaceWeather.isWarning(): boolean
    return warningFor ~= nil
end

function SpaceWeather.sepActive(): boolean
    return sepOn
end

function SpaceWeather.gstActive(): boolean
    return gstOn
end

-- 밖에 있는 대원을 대피시킨다: 가까운 빈 로버 운전석 -> 에어록 안
local function shelterPlayers()
    for _, player in Players:GetPlayers() do
        local zone = OxygenV2.zoneOf(player)
        if zone == "outside" then
            local position = PromptKit.rootPosition(player)
            local seat = if flow then flow.roverSeat() else nil
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local seated = false
            if
                position
                and humanoid
                and seat
                and seat:IsDescendantOf(workspace)
                and seat.Occupant == nil
                and (seat.CFrame.Position - position).Magnitude <= CFG.roverShelterRadius
            then
                seat:Sit(humanoid)
                seated = true
            end
            if seated then
                flow.notify(player, Msg.new("toast.sep.shelter_rover"), "warn")
            elseif OxygenV2.moveInside(player) then
                flow.notify(player, Msg.new("toast.sep.shelter_airlock"), "warn")
            end
        end
    end
end

local function setSep(on: boolean)
    if sepOn == on then
        return
    end
    sepOn = on
    AirlockDoors.setLocked(on)
    local handler = onSepChanged
    if handler then
        handler(on)
    end
end

-- 하루가 끝나기 15초 전 (MissionClock.onBeforeTick)
function SpaceWeather.beforeTick()
    if not flow or flow.phase() ~= "playing" then
        return
    end
    local state = flow.rules()
    if not state then
        return
    end
    local sepNow = Rules.weatherOn(state)
    local sepTomorrow = Rules.weatherOn(state, state.day + 1)
    if sepTomorrow and sepTomorrow ~= sepNow and sepTomorrow.day == state.day + 1 then
        warningFor = sepTomorrow.day
        fire("SEP", "warning", sepTomorrow)
        flow.markDirty()
    end
end

-- 하루 마감 뒤 (prev: 마감 전 상태, new: 다음 날 상태)
function SpaceWeather.onDay(prev: any, new: any)
    local sepBefore, gstBefore = Rules.weatherOn(prev)
    local sepAfter, gstAfter = Rules.weatherOn(new)
    if sepAfter and sepAfter ~= sepBefore then
        warningFor = nil
        fire("SEP", "active", sepAfter)
        setSep(true)
        shelterPlayers()
    elseif sepBefore and sepAfter == nil then
        fire("SEP", "ended", sepBefore)
        setSep(false)
    end
    if gstAfter and gstAfter ~= gstBefore then
        gstOn = true
        fire("GST", "active", gstAfter)
    elseif gstBefore and gstAfter == nil then
        gstOn = false
        fire("GST", "ended", gstBefore)
    end
end

-- playing 시작 때: 이미 진행 중인 사건이 있으면 바로 적용 (데이터는 첫 5일이 조용하다)
function SpaceWeather.start(state: any)
    warningFor = nil
    local sep, gst = Rules.weatherOn(state)
    gstOn = gst ~= nil
    if gst then
        fire("GST", "active", gst)
    end
    if sep then
        fire("SEP", "active", sep)
        setSep(true)
        shelterPlayers()
    else
        setSep(false)
    end
end

-- 판이 끝나거나 재시작: 문 열고 효과를 모두 끈다
function SpaceWeather.reset()
    warningFor = nil
    gstOn = false
    setSep(false)
    AirlockDoors.setLocked(false)
end

-- 테스트용: 페이로드 모양
SpaceWeather.payload = payload

return SpaceWeather
