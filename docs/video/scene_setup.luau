-- The Frontier 데모 영상용 장면 세팅 (짝 문서: docs/video/DEMO_SHOTLIST.md)
--
-- 사용법 (리드용)
--   1) 이 파일 전체를 붙여넣지 않는다. "PRELUDE" 구간 + 필요한 "SCENE" do-블록 하나를 이어 붙여
--      Roblox Studio MCP execute_luau (Play 중, Server 데이터모델)에서 한 번에 실행한다.
--   2) execute_luau 호출은 서로 상태를 공유하지 않는다고 보고, 매번 PRELUDE를 같이 붙인다.
--   3) 모듈은 require로 얻는다. Main.server가 이미 올린 모듈이라 같은 인스턴스가 돌아온다
--      (docs/qa/QA_2026-11-15_code.md U5가 같은 방식으로 MissionFlow.setNextWindow를 쓴다).
--      PROBE 블록의 phase, day가 화면(HUD)과 다르면 같은 인스턴스가 아니다. 그때는 멈추고 사용자에게 알린다.
--   4) src는 건드리지 않는다. 파일 맨 아래 H1 ~ H3은 "있으면 편한 작은 도우미" 제안일 뿐이고 적용하지 않았다.
--   5) 줄 번호(file:line)는 2026-11-15 11시 50분경 기준이다. 다른 담당이 src를 고치는 중이라 어긋나면 함수 이름으로 찾는다.
--
-- 핵심 원리 (모두 기존 코드)
--   - 상태 바꾸기: Rules.copy(MissionFlow.getRules()) -> 복사본 수정 -> MissionFlow.flow.commit(복사본).
--     commit이 월드(시설, 패널)와 화면(StateUpdate)을 같이 맞춘다. tests/server_smoke_v2.luau:859 H.topUp이 같은 방법.
--   - 하루 넘기기: MissionFlow.debugAdvanceDay() = 진짜 하루 마감(Rules.applyDay, 우주 기상 연출, 종료 판정) 한 번.
--   - 시계 멈추기: MissionClock.stop(), 다시 켜기 MissionClock.start() (하루 30초부터 새로 센다).
--     HUD는 dayEndsAt을 쓰지 않으므로(src/client grep 결과 0건) 멈춰도 화면은 같다. 단 자율주행 지도 아이콘의
--     부드러운 이동은 시계가 돌 때만 계산된다(RoverFleet.luau:1503 fsdView, endsAt이 nil이면 mapFrom/mapTo 없음).
--   - 하루 마감은 대원 소비(에너지 12, 물 3, 식량 3)와 시설 유지비를 실제로 뺀다. advance 직전에 자원을 맞춘다.
--   - 상태의 날짜(state.day)를 직접 뛰어넘으면 SpaceWeather의 "끝남" 전환을 건너뛰어 문 잠금이 남을 수 있다.
--     jumpToDay가 먼저 SpaceWeather.reset()을 부르는 이유. 사건이 있는 날로 바로 뛰지 말고 하루 전으로 뛴 뒤
--     advance로 틱을 넘겨 들어간다.
--
-- 우주 기상 구간: "2023-01-27" 하나만 쓴다 (src/shared/SpaceWeatherData.luau:60 부근).
--   SEP 29일(2일, 실제 날짜 2023-02-24), GST 32일(Kp 7, 2023-02-27), SEP 36일, SEP 46일, GST 56일(Kp 8).
--   처음 28일은 사건이 없어 자연 플레이에서도 장면 3 ~ 9가 조용하다. 결과 화면 날씨 요약은
--   "2023년 1월 27일부터 2023년 3월 27일까지, 태양 방사선 폭풍 3번, 지자기 폭풍 2번".

-- ===================================================================================
-- PRELUDE START (매 호출 맨 앞에 붙인다)
-- ===================================================================================
local Players = game:GetService("Players")
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local MissionFlow = require(Server.MissionFlow)
local MissionClock = require(Server.MissionClock)
local MissionWorld = require(Server.MissionWorld)
local SpaceWeather = require(Server.SpaceWeather)
local RoverFleet = require(Server.RoverFleet)
local Interactions = require(Server.Interactions)
local OxygenV2 = require(Server.OxygenV2)
local Roles = require(Server.Roles)
local RecordsV2 = require(Server.RecordsV2)
local PlayerPrefs = require(Server.PlayerPrefs)
local Rules = require(Shared.Rules)
local MissionConfig = require(Shared.MissionConfig)
local SpaceWeatherData = require(Shared.SpaceWeatherData)

-- Studio 플레이어 n번째 (솔로면 1번)
local function me(index)
    return Players:GetPlayers()[index or 1]
end

-- 판이 playing이고 Rules 상태가 있는지 (MissionFlow.getPhase 1119, getRules 1123)
local function playing()
    return MissionFlow.getPhase() == "playing" and MissionFlow.getRules() ~= nil
end

-- Rules 상태 복사 -> 고치기 -> commit (Rules.copy 212, MissionFlow.flow.commit 624, flow 표 1141)
local function edit(mutate)
    local current = MissionFlow.getRules()
    if not current then
        warn("[demo] Rules state 없음 (phase " .. MissionFlow.getPhase() .. ")")
        return nil
    end
    local s = Rules.copy(current)
    mutate(s)
    MissionFlow.flow.commit(s)
    return s
end

-- 자원 맞추기 (nil이면 그대로). 상한은 state.cap(100)
local function setRes(energy, water, food)
    return edit(function(s)
        if energy then
            s.energy = math.clamp(energy, 0, s.cap)
        end
        if water then
            s.water = math.clamp(water, 0, s.cap)
        end
        if food then
            s.food = math.clamp(food, 0, s.cap)
        end
    end)
end

-- 설치한 패널 수 (commit -> MissionFlow.syncWorld -> MissionWorld.setPanelCount, MissionWorld.luau:2129)
-- 늘어난 만큼 새 패널이 솟아오르고, 줄이면 지운다
local function setPanels(count)
    return edit(function(s)
        s.panels = math.clamp(count, 0, MissionConfig.MISSIONS.C.panels.total)
        s.panelsToday = 0
    end)
end

-- 날짜 뛰기. 먼저 SpaceWeather.reset()(SpaceWeather.luau:172)로 문 잠금과 SEP 보류를 푼다
local function jumpToDay(day)
    SpaceWeather.reset()
    return edit(function(s)
        s.day = day
        s.panelsToday = 0
    end)
end

-- 시설 하나를 Rules 상태에 넣는다 (Rules.Facility 모양, Rules.luau:22 / startBuild 805의 필드와 같음)
-- status "building"이면 daysLeft(기본 buildDays)로 솟아오름 연출, "active"면 바로 완공
local function setFacility(s, defId, status, daysLeft, extra)
    local def = MissionConfig.MISSIONS.C.facilities[defId]
    local f = {
        id = defId,
        defId = defId,
        status = status,
        daysLeft = if status == "building" then (daysLeft or def.buildDays) else 0,
        buildDays = def.buildDays,
        paused = false,
        progress = 0,
        siteIndex = nil,
        startedDay = s.day,
        completedDay = if status == "active" then s.day else nil,
    }
    if extra then
        for key, value in extra do
            f[key] = value
        end
    end
    s.facilities[defId] = f
end

-- 우주 기상 구간 바꾸기 (SpaceWeatherData.windows의 id). state.weather는 바꾸지 않는 값이라 통째로 새 표를 넣는다
local function useWindow(id)
    for _, w in SpaceWeatherData.windows do
        if w.id == id then
            edit(function(s)
                s.weather = { id = w.id, startDate = w.startDate, events = w.events }
            end)
            return true
        end
    end
    return false
end

-- 캐릭터 옮기기 (Instance:PivotTo)
local function pivot(player, cf)
    local character = player and player.Character
    if character then
        character:PivotTo(cf)
        return true
    end
    return false
end

-- 파트 옆에 세운다: 착륙선 쪽으로 away stud 떨어진 곳, 파트를 바라봄
local function standAt(part, away, player)
    if not part then
        warn("[demo] standAt: part 없음")
        return false
    end
    local p = part.Position
    local lander = MissionWorld.getMarker("Lander") -- MissionWorld.luau:3573
    local dir = Vector3.new(1, 0, 0)
    if lander then
        local d = Vector3.new(lander.position.X - p.X, 0, lander.position.Z - p.Z)
        if d.Magnitude > 1 then
            dir = d.Unit
        end
    end
    local from = p + dir * (away or 5) + Vector3.new(0, 4, 0)
    return pivot(player or me(), CFrame.lookAt(from, Vector3.new(p.X, from.Y, p.Z)))
end

-- 상호작용 자리 id: console, airlockPanel, installPad, buildSpot, unloadPoint, pipeSpot, roverPark, exit
-- (MissionWorld.anchor 3565, 목록 주석 3564)
local function stand(anchorId, away, player)
    local part = MissionWorld.anchor(anchorId)
    if not part then
        warn("[demo] anchor 없음: " .. anchorId)
        return false
    end
    return standAt(part, away, player)
end

-- 얼음 후보지 지면 위치. siteIndex는 Rules 순서(1 = 가장 가까움: Ice4, Ice5, Ice1, Ice3, Ice2, MissionConfig.luau:252)
local function icePos(siteIndex)
    local s = MissionFlow.getRules()
    local site = s and s.sites[siteIndex]
    if not site then
        return nil
    end
    for _, info in MissionWorld.iceSites() do -- MissionWorld.luau:2356
        if info.markerName == site.id then
            return info.position
        end
    end
    return nil
end

-- 하루 마감을 times번, gap초 간격으로 (기다리지 않고 바로 돌아온다)
-- MissionFlow.debugAdvanceDay 1137 = onDayTick (Rules.applyDay -> SpaceWeather.onDay -> 종료 판정)
local function advance(times, gap)
    task.spawn(function()
        for i = 1, times do
            MissionFlow.debugAdvanceDay()
            if i < times then
                task.wait(gap or 3)
            end
        end
    end)
end

-- 지금 상태 한 줄 요약 (PROBE와 각 장면 출력에 쓴다)
local function describe()
    local s = MissionFlow.getRules()
    if not s then
        return "phase=" .. MissionFlow.getPhase() .. " (no rules)"
    end
    return string.format(
        "phase=%s day=%d E=%.0f W=%.0f F=%.0f panels=%d rover=%s window=%s",
        MissionFlow.getPhase(),
        s.day,
        s.energy,
        s.water,
        s.food,
        s.panels,
        s.rover.status,
        s.weather.id
    )
end
-- ===================================================================================
-- PRELUDE END
-- ===================================================================================

-- ===================================================================================
-- PROBE: 같은 모듈 인스턴스인지 확인 (Play 중 언제든). 출력이 화면 HUD와 같아야 한다
-- ===================================================================================
do
    print("[PROBE] " .. describe() .. " players=" .. #Players:GetPlayers())
end

-- ===================================================================================
-- SCENE 0  녹화 전 한 번 (Play 직후, 타이틀 화면에서)
--   다음 판의 우주 기상 구간을 고정한다 (MissionFlow.setNextWindow 1132, pickWindow 756이 읽음).
--   미션을 확정하기 전에만 효과가 있다. 이미 시작한 판에는 useWindow로 바꾼다.
--   저장소 상태도 확인한다: RecordsV2.status() 179, PlayerPrefs.status() 245.
--   records가 "ok"면 결과 장면(13)이 진짜 DataStore에 기록을 쓴다 -> SCENE 13 참고
-- ===================================================================================
do
    MissionFlow.setNextWindow("2023-01-27")
    print(
        "[S0] window=2023-01-27 phase="
            .. MissionFlow.getPhase()
            .. " records="
            .. RecordsV2.status()
            .. " prefs="
            .. PlayerPrefs.status()
            .. " players="
            .. #Players:GetPlayers()
    )
end

-- ===================================================================================
-- SCENE 1, 2  타이틀, About the data, 미션 선택: 서버 명령 없음 (화면만)
--   미션 선택은 "Start mission"을 누르는 순간 확정된다(client -> SelectMission -> MissionFlow.luau:994).
--   서버에서 확정을 부를 수 없다(confirmMission이 local). 재촬영이 잦으면 H2 제안 참고.
-- ===================================================================================

-- ===================================================================================
-- SCENE 3  착륙 + HUD: "Start mission"을 누른 직후 실행
--   착륙 연출 5초(MissionFlow.CONFIG.landingSeconds, MissionFlow.luau:51)가 끝나 playing이 되면 시계를 멈춘다.
--   (startPlaying이 MissionClock.start를 부르므로 playing이 된 뒤에 멈춰야 한다. MissionFlow.luau:783-797)
--   이후 장면 3 ~ 9, 13은 시계를 멈춘 채 advance로만 하루를 넘긴다.
-- ===================================================================================
do
    task.spawn(function()
        local waited = 0
        while MissionFlow.getPhase() ~= "playing" and waited < 60 do
            task.wait(0.25)
            waited += 0.25
        end
        if MissionFlow.getPhase() == "playing" then
            MissionClock.stop() -- MissionClock.luau:105
            print("[S3] clock stopped. " .. describe())
        else
            warn("[S3] playing이 되지 않았다: " .. MissionFlow.getPhase())
        end
    end)
end

-- ===================================================================================
-- SCENE 4  에어록 점검과 산소
--   4a: 에어록 패널 앞에 세우고 산소를 낮춘다. 밖에서 초당 약 1.67 줄어 35에서 20까지 약 9초,
--       20 이하가 되면 "Oxygen is low!" 토스트(OxygenV2.luau:29 lowRatio, 165-168). 0이 되면 구조되어 -100점이니 서두른다.
--       OxygenV2.set 193
--   4b: 점검(2일) 끝내기. 사용자가 패널에서 E 1초를 눌러 착공한 뒤 실행한다. 착공은 Rules.inspectAirlock(853)
--   4c: (대체) 사용자가 E를 못 누를 때 서버가 착공
-- ===================================================================================
do -- 4a
    if playing() then
        MissionClock.stop()
        setRes(60, 60, 50)
        stand("airlockPanel", 6)
        OxygenV2.set(me(), 35)
        print("[S4a] " .. describe())
    end
end

do -- 4b (사용자가 점검을 시작한 뒤). 2일이 3초 간격으로 지나 "Airlock is ready!" 후 에어록이 산소를 채운다
    if playing() then
        advance(2, 3)
    end
end

do -- 4c (대체) 서버가 점검 착공. MissionFlow.luau:561 act(player, fn): fn(state, config) -> (ok, new, msg, events)
    if playing() then
        MissionFlow.flow.act(me(), Rules.inspectAirlock)
    end
end

-- ===================================================================================
-- SCENE 5  태양광 패널
--   5a: 설치 자리 앞에 세운다. 사용자가 E 3초(MissionConfig.panels.installSeconds)로 한 장씩 설치(에너지 4, 하루 2장)
--   5b: 컷 전환용. 패널을 N장 깔린 모습으로 만든다 (새 패널이 솟아오름). 하루 발전은 장당 2 (MissionConfig.luau:151-161)
-- ===================================================================================
do -- 5a
    if playing() then
        MissionClock.stop()
        setRes(40, nil, nil)
        setPanels(0)
        stand("installPad", 6)
    end
end

do -- 5b
    if playing() then
        setPanels(8)
    end
end

-- ===================================================================================
-- SCENE 6  건설 비용 프롬프트와 건물 정보 카드
--   프롬프트의 비용 줄(에너지, 물, 일수, 낼 수 있는지)은 PromptKit.setCost가 Attribute로 보낸다(PromptKit.luau:102,
--   Interactions 헤더 13-15). 건물 카드는 14 stud 안에서 가장 가까운 건물 하나(BuildingInfoUI.luau SHOW_DISTANCE).
--   MCP screen_capture는 PlayerGui 아래 BillboardGui(프롬프트)를 못 찍는다. 실제 화면 녹화는 문제없다.
--   6a: 그린하우스 자리, 낼 수 있음  6b: 에너지 부족(숫자가 빨갛게)  6c: 물 파이프 자리(해금 전, 하역 5번 필요)
-- ===================================================================================
do -- 6a
    if playing() then
        MissionClock.stop()
        setRes(40, 50, 37)
        stand("buildSpot", 6)
    end
end

do -- 6b
    if playing() then
        setRes(5, 3, nil)
    end
end

do -- 6c
    if playing() then
        setRes(40, 50, nil)
        stand("pipeSpot", 6)
    end
end

-- ===================================================================================
-- SCENE 7  그린하우스 솟아오름과 식량
--   7a: 서버가 착공(대체. 보통은 사용자가 E 1초). Rules.startBuild 805: 에너지 10, 물 5, 3일
--   7b: 3일을 3초 간격으로 넘긴다. 하루마다 1/3씩 솟아오른다(MissionWorld.setBuildProgress 3334, riseSeconds 1초).
--       마지막 틱에 "Greenhouse is ready!"
--   7c: 첫 수확. farm.progress를 4로 두고 하루를 넘기면 5일째라 수확 +26 (MissionConfig.luau:176-186, Rules.applyDay 3단계)
-- ===================================================================================
do -- 7a
    if playing() then
        setRes(80, 80, 40)
        stand("buildSpot", 6)
        MissionFlow.flow.act(me(), function(s, config)
            return Rules.startBuild(s, config, "farm")
        end)
    end
end

do -- 7b
    if playing() then
        advance(3, 3)
    end
end

do -- 7c
    if playing() then
        edit(function(s)
            local farm = s.facilities.farm
            if farm and farm.status == "active" then
                farm.progress = 4
            end
            s.food = 30
            s.energy = 80
            s.water = 80
        end)
        advance(1)
    end
end

do -- 7r (재촬영) 그린하우스를 지운다. 목록에 없는 시설은 월드에서 치워진다 (MissionWorld.syncFacilities 3467, 끝부분 removeFacility)
    if playing() then
        edit(function(s)
            s.facilities.farm = nil
        end)
    end
end

-- ===================================================================================
-- SCENE 8  자율주행 로버 파견과 콘솔 지도
--   8a: 시계를 켜고(지도 아이콘 이동 계산에 필요), 콘솔 앞에 세운다. 사용자가 E -> 지도 탭 -> 얼음 후보지 4 -> 보내기
--       솔로만 가능 (RoverFleet.dispatch 1399, 1407줄 solo 검사). 지점 4는 가장 가까움: 왕복 약 1일, 에너지 11, 위험 낮음
--       (BALANCE_LOG 8.6 표, Rules.tripPlan 916). 화면 거리는 stud x 1.2524 = 약 516 m
--   8b: (대체) 서버가 파견. 사용자가 UI를 쓰는 편이 영상에 낫다
--   8c: 파견이 하루의 뒤쪽 절반에 이뤄지면 서버가 elapsed를 -1로 시작해 귀환이 하루 늦다
--       (RoverFleet.luau:67 dispatchDayMinLeft 0.5, 적용 1429-1436). 그때 0으로 바로잡는다 (tests/server_smoke_v2.luau:1493과 같은 방법)
--   8d: 귀환 앞당기기. 1일 왕복이면 하루 한 번 넘기면 돌아와 "back from Ice Site 4 with 30 Water!"
-- ===================================================================================
do -- 8a
    if playing() then
        MissionClock.start() -- MissionClock.luau:95, 하루 30초를 새로 센다 (파견은 이 시점 직후가 하루 앞쪽 절반)
        setRes(60, 40, nil)
        edit(function(s)
            s.rover.damage = 0
        end)
        stand("console", 3)
        print("[S8a] " .. describe())
    end
end

do -- 8b
    if playing() then
        RoverFleet.dispatch(me(), 1, false) -- siteIndex 1 = 가장 가까움, rush false
    end
end

do -- 8c
    if playing() then
        edit(function(s)
            local trip = s.rover.trip
            if trip and trip.elapsed < 0 then
                trip.elapsed = 0
            end
        end)
    end
end

do -- 8d
    if playing() then
        advance(1)
    end
end

-- ===================================================================================
-- SCENE 9  직접 운전, 배터리, 충전 (솔로도 가능. RoverFleet.luau 헤더 "직접 운전(멀티, 솔로도 가능)")
--   9a: 시계 멈춤, 자원, 로버 주차판 옆에 세운다. 사용자가 E "Get in" -> WASD -> Shift(부스터)
--   9b: 얼음 후보지 5 근처로 로버를 옮긴다(컷). 사용자가 E 3초 "Dig ice"
--   9c: 물탱크 하역 자리로 옮긴다(컷). 사용자가 E "Unload Water"
--   9d: 충전이 막힌 이유 보이기: 기지 에너지 20 이하 -> "Not charging: base Energy is 20 or less" (chargeKeepEnergy 20)
--   9e: 충전 보이기: 에너지를 올린다. 로버를 주차판에 세우고 내리면 번개 표시와 "Charging"
--   배터리 값을 직접 맞추는 기존 함수가 없다. 풀 배터리 50에서 초당 0.15(부스터 x2)라 짧은 컷에서는 변화가 작다.
--   H1 도우미(RoverFleet.debugSetBattery)가 있으면 아래에서 쓴다. 없으면 부스터로 몇 초 달려 줄인다.
-- ===================================================================================
do -- 9a
    if playing() then
        MissionClock.stop()
        setRes(70, 60, 60)
        local park = MissionWorld.roverParkCFrame() -- MissionWorld.luau:3587
        if park then
            pivot(me(), park * CFrame.new(8, 3, 0))
        end
        if RoverFleet.debugSetBattery then
            RoverFleet.debugSetBattery(32)
        else
            print("[S9a] H1(debugSetBattery) 없음: 부스터로 달려 배터리를 줄인다")
        end
    end
end

do -- 9b
    local model = RoverFleet.model() -- RoverFleet.luau:265
    local pos = icePos(2) -- Ice5 (주차판에서 가장 가까움, MissionConfig.luau:262 manualDriveDistances)
    if playing() and model and pos then
        local base = MissionWorld.getMarker("RoverPark")
        local dir = Vector3.new(1, 0, 0)
        if base then
            local d = Vector3.new(base.position.X - pos.X, 0, base.position.Z - pos.Z)
            if d.Magnitude > 1 then
                dir = d.Unit
            end
        end
        model:PivotTo(CFrame.new(pos + dir * 14 + Vector3.new(0, 5, 0)))
    end
end

do -- 9c
    local model = RoverFleet.model()
    local unload = MissionWorld.anchor("unloadPoint")
    if playing() and model and unload then
        model:PivotTo(CFrame.new(unload.Position + Vector3.new(8, 5, 0)))
    end
end

do -- 9d
    if playing() then
        setRes(15, nil, nil)
    end
end

do -- 9e
    if playing() then
        setRes(70, nil, nil)
    end
end

-- ===================================================================================
-- SCENE 10  NASA DONKI SEP: 15초 경보와 대피 (구간 2023-01-27, 29일 SEP, 실제 날짜 2023-02-24)
--   10a: 28일로 뛰고, 로버 주차판 옆(빈 로버 40 stud 안)에 세운 뒤 경보를 바로 낸다.
--        SpaceWeather.beforeTick 115 = 하루 끝 15초 전에 자연스럽게 불리는 함수와 같다(경보 화면 테두리 붉은 깜빡임, 배너).
--        15초 뒤 하루를 넘기면 SEP 시작: 문 잠금, 대피(로버에 자동 탑승, 아니면 에어록 안), 화면 딤드, 출처
--        "NASA DONKI record, February 24, 2023". 경보와 시작 사이는 실제 15초.
--        (시계를 멈춘 채 쓴다. 시계가 돌면 자연 경보가 한 번 더 울린다)
--   10b: SEP 끝내기. 2일짜리라 틱 2번이면 "The solar storm is over." (SpaceWeather.onDay 133의 ended 전환)
--   10c: SEP가 켜져 있는지 확인 출력 (SpaceWeather.sepActive 64. 문 잠금 AirlockDoors.isLocked 277와 같은 시점에 바뀐다)
-- ===================================================================================
do -- 10a
    if playing() then
        MissionClock.stop()
        useWindow("2023-01-27")
        jumpToDay(28)
        setRes(70, 70, 60)
        local park = MissionWorld.roverParkCFrame()
        if park then
            pivot(me(), park * CFrame.new(10, 3, 0))
        end
        SpaceWeather.beforeTick()
        task.delay(15, function()
            MissionFlow.debugAdvanceDay()
        end)
        print("[S10a] 경보 발송. 15초 뒤 29일 SEP 시작. " .. describe())
    end
end

do -- 10b
    if playing() then
        advance(2, 4)
    end
end

do -- 10c
    print("[S10c] sepActive=" .. tostring(SpaceWeather.sepActive()) .. " " .. describe())
end

-- ===================================================================================
-- SCENE 11  NASA DONKI GST: 지도 끊김 (32일 GST, Kp 7, 실제 날짜 2023-02-27)
--   11a: 31일(SEP는 이미 끝남)로 뛰고 콘솔 앞에 세운다. 이어서 하루를 넘기면 32일 GST 시작:
--        배너 "Geomagnetic storm! Earth support is down: no map or GPS.", 콘솔 지도가 지직거리고 "Offline",
--        보내기와 핀 버튼이 꺼진다 (ConsoleUI 헤더, Rules.dispatchRover 965-970 GST 거절).
--        시계는 멈춘 채라 GST가 사용자가 끝낼 때까지 유지된다.
--   11b: (선택) 로버가 나가 있는 채로 GST를 맞는 판. 가장 가까운 곳은 1일 왕복이라 틱에 돌아와 버리므로
--        지점 3(Ice1, 왕복 2일)로 31일에 보내고 틱을 넘긴다. 배너 "Your rover lost its location data and stopped."
--        지도 아이콘의 부드러운 이동은 시계가 돌 때만 계산되므로(RoverFleet.luau:1503) 이 변형만 시계를 켠다.
--        그 경우 GST는 다음 진짜 하루 마감(최대 30초)에 끝난다.
--   11c: GST 끝내기 "Earth support is back. The map works again."
-- ===================================================================================
do -- 11a
    if playing() then
        MissionClock.stop()
        jumpToDay(31)
        setRes(70, 70, 60)
        stand("console", 3)
        advance(1)
        print("[S11a] 32일 GST 시작. " .. describe())
    end
end

do -- 11b (선택, 11a 대신)
    if playing() then
        jumpToDay(31)
        setRes(80, 70, 60)
        stand("console", 3)
        MissionClock.start()
        RoverFleet.dispatch(me(), 3, false) -- Ice1, 왕복 2일, 에너지 17
        task.delay(2, function()
            MissionFlow.debugAdvanceDay()
        end)
    end
end

do -- 11c
    if playing() then
        advance(1)
    end
end

-- ===================================================================================
-- SCENE 12  관제사 핀 화살표와 역할 미션 (2명 필요, 선택 장면)
--   Studio Test 탭에서 Clients and Servers 2명으로 시작한다. 미션 확정 순간 인원이 2명이면 멀티(MissionFlow.luau:805-806).
--   12a: 역할 선택 10초 안에(Roles.choose 258: 선택 중에는 어디서나 가능) 1번을 관제사, 2번을 탐사대원으로. 10초를 기다리지 않아도 됨
--   12b: 관제사가 지점 3(Ice Site 1, 약 810 m)에 핀. Roles.setPin 360 (관제사만, GST 중 거절)
--   12c: 탐사대원을 핀 근처로 옮긴다 -> 길잡이 미션 진행 1/2 (RoleMissions.luau:34 guide goal 2, radius 30)
--   12d: 핀을 다른 곳(지점 1)으로 옮기고 다시 도착시켜 완료 -> "Job mission done!" + 팀 알림
--   12e: (선택) 탐사대원 물 미션 목표 3을 바로 채운다. flow.contribute(MissionFlow.luau:635)는 물 하역 1회로 세고
--        결과 화면 "함께 한 일"의 물 숫자도 올린다. 점수와 메달에는 영향이 없다(역할 미션은 점수와 무관)
-- ===================================================================================
do -- 12a
    local p1, p2 = me(1), me(2)
    if p1 and p2 then
        Roles.choose(p1, "controller")
        Roles.choose(p2, "explorer")
    else
        warn("[S12a] 플레이어 2명 필요")
    end
end

do -- 12b
    if playing() then
        for _, p in Players:GetPlayers() do
            if Roles.roleOf(p) == "controller" then -- Roles.luau:241
                Roles.setPin(p, 3)
            end
        end
    end
end

do -- 12c
    if playing() then
        local pos = icePos(3)
        for _, p in Players:GetPlayers() do
            if pos and Roles.roleOf(p) == "explorer" then
                pivot(p, CFrame.new(pos + Vector3.new(12, 6, 0)))
            end
        end
    end
end

do -- 12d
    if playing() then
        local pos = icePos(1)
        for _, p in Players:GetPlayers() do
            if Roles.roleOf(p) == "controller" then
                Roles.setPin(p, 1)
            end
        end
        for _, p in Players:GetPlayers() do
            if pos and Roles.roleOf(p) == "explorer" then
                task.delay(3, function()
                    pivot(p, CFrame.new(pos + Vector3.new(12, 6, 0)))
                end)
            end
        end
    end
end

do -- 12e
    if playing() then
        for _, p in Players:GetPlayers() do
            if Roles.roleOf(p) == "explorer" then
                for _ = 1, 3 do
                    MissionFlow.flow.contribute(p, "water", 30)
                end
            end
        end
    end
end

-- ===================================================================================
-- SCENE 13  메달 결과 화면 (점수, 순위)
--   13a: 금메달 직전 상태를 만든다. 34일, 패널 13장, 에어록과 그린하우스, LED, 영양분, 물 파이프 가동(하역 5번),
--        수경 재배만 남김. 사용자가 수경 자리에서 E 1초(에너지 60, 물 40, 1일)로 착공 -> 13b에서 하루를 넘기면
--        수경 완공 -> Rules.checkEnd(1629)가 금메달 판정 -> MissionFlow.endGame이 그 순간 결과 화면 (Q2).
--        사유별 감점 목록이 보이도록 에너지 부족 3일, 식량 부족 2일을 넣었다(화면용 연출. 줄이려면 아래 숫자를 0으로).
--        결과 화면: 점수 950 (1000 - 부족 5일 x 10, MissionConfig.luau:58-65 SCORE), 지낸 날 34,
--        우주 날씨 요약(2023-01-27 ~ 2023-03-27, SEP 3, GST 2), 함께 한 일, 순위.
--   13b: 하루 넘기기 (사용자가 수경을 착공한 뒤)
--   13c: (대체) 사용자가 E를 못 누를 때. 수경 재배를 이미 1일 남은 건설 중으로 만들고 바로 하루를 넘긴다
--   저장소 주의: endGame은 메달을 따면 RecordsV2.submit을 부른다(MissionFlow.luau:898-908). RecordsV2.status()가
--   "ok"(Studio API 접근이 켜져 있음)면 이 연출 판이 진짜 DataStore 순위에 올라간다. "offline"이면 서버 메모리 순위만이다.
--   "ok"일 때는 사용자 허락 없이 실행하지 않는다. 허락을 받으면 아래 ALLOW_REAL_RECORD를 true로 바꾼다.
--   순위 칸: 메모리 순위에는 이 서버에서 끝낸 판만 쌓인다. 줄을 여러 개 보이려면 실제로 여러 판을 끝내거나
--   한 줄만 보이는 화면을 그대로 쓴다. 가짜 이름의 기록을 넣지 않는다.
-- ===================================================================================
do -- 13a
    local ALLOW_REAL_RECORD = false
    if playing() then
        if RecordsV2.status() == "ok" and not ALLOW_REAL_RECORD then
            warn(
                "[S13a] 중단: DataStore가 켜져 있어 연출 판이 실제 순위에 기록된다. 사용자 허락 후 ALLOW_REAL_RECORD = true"
            )
        else
            MissionClock.stop()
            jumpToDay(34)
            edit(function(s)
                s.energy, s.water, s.food = 90, 80, 70
                s.panels = 13
                s.panelsToday = 0
                setFacility(s, "airlock", "active")
                setFacility(s, "farm", "active", nil, { progress = 2 })
                setFacility(s, "led", "active")
                setFacility(s, "nutrient", "active")
                setFacility(s, "pipe", "active", nil, { siteIndex = 5 })
                s.sites[5].pipeId = "pipe" -- 가장 먼 얼음 후보지에 파이프 (그 지점은 로버로 못 캔다)
                s.deliveries = 5 -- 파이프 해금 조건 (MissionConfig.luau:225)
                s.score.energy.low = 3 -- 연출용 감점 사유 (Rules.finalScore 1703이 목록으로 만든다)
                s.score.food.low = 2
            end)
            local prompt = Interactions.prompt("upgrade_hydroponics") -- Interactions.luau:656
            if prompt and prompt.Parent then
                standAt(prompt.Parent, 4)
            end
            print("[S13a] 수경 재배만 남았다. " .. describe())
        end
    end
end

do -- 13b
    if playing() then
        advance(1)
    end
end

do -- 13c (대체)
    local ALLOW_REAL_RECORD = false
    if playing() and RecordsV2.status() == "ok" and not ALLOW_REAL_RECORD then
        warn("[S13c] 중단: DataStore가 켜져 있다")
    elseif playing() then
        edit(function(s)
            setFacility(s, "hydroponics", "building", 1)
        end)
        advance(1)
    end
end

-- ===================================================================================
-- SCENE 14  EN / KR 전환
--   사용자가 우측 하단 토글(Tips, Fact cards 옆)을 누르는 것이 기본(SettingsUI는 플레이 중에만 보인다).
--   결과 화면에서는 설정 패널이 숨겨지므로 이 장면은 플레이 중에 따로 찍어 편집에서 끝에 붙인다.
--   대체: 서버가 바꾼다. PlayerPrefs.setLanguage 231 (플레이어별, 요청 제한 없음). 서버가 키만 보내므로
--   HUD, 프롬프트, 콘솔, 3D 표지가 새 언어로 다시 그려진다.
-- ===================================================================================
do -- 14 ko
    PlayerPrefs.setLanguage(me(), "ko")
end

do -- 14 en
    PlayerPrefs.setLanguage(me(), "en")
end

-- ===================================================================================
-- RESCUE  막혔을 때
--   SEP 문 잠금이 남았거나 이상할 때: SpaceWeather.reset() (문 열림, 로버 보류 해제)
--   시계 다시 켜기: MissionClock.start()
-- ===================================================================================
do
    SpaceWeather.reset()
    MissionClock.start()
    print("[RESCUE] " .. describe())
end

-- ===================================================================================
-- 기존 코드로 안 되는 것과 가장 작은 도우미 제안 (적용하지 않았다. src는 건드리지 않는다)
--
-- H1  로버 배터리를 값으로 맞추기 (장면 9, 있으면 편한 정도)
--     배터리는 RoverFleet.luau:128의 모듈 안쪽 변수라 밖에서 바꿀 수 없다.
--     src/server/RoverFleet.luau, RoverFleet.model() (265) 아래에:
--         function RoverFleet.debugSetBattery(value: number)
--             battery = math.clamp(value, 0, manual().batteryMax)
--             RoverFleet.refresh()
--             if flow then
--                 flow.markDirty()
--             end
--         end
--     (manual() 159, refresh 340, flow는 파일 위쪽 local. 장면 9a가 있으면 자동으로 쓴다)
--
-- H2  미션 선택을 서버에서 확정하기 (재촬영이 잦을 때, 필수 아님)
--     confirmMission(MissionFlow.luau:672 선언, 799 정의)이 local이고 SelectMission 원격(994)만 부른다.
--     src/server/MissionFlow.luau, debugAdvanceDay (1137) 아래에:
--         function MissionFlow.debugConfirmMission(id: string)
--             confirmMission(id)
--         end
--
-- H3  순위 저장을 끄기 (장면 13에서 RecordsV2.status()가 "ok"일 때만 필요)
--     Studio API 접근이 켜져 있으면 연출 판이 진짜 순위에 올라간다. 모듈 안 goOffline(RecordsV2.luau:88)을 밖에 연다:
--         function RecordsV2.debugOffline()
--             goOffline()
--         end
--     부르면 status가 "offline"이 되어 그 서버 메모리에만 쌓인다 (장면 13a 가드가 통과한다).
-- ===================================================================================
