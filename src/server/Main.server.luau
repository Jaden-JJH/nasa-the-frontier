--!strict
-- v2 서버 진입점 (docs/CONTRACT_V2.md 2.2 Main.server, 7.5 연결 규칙)
-- 부팅 순서: Remotes.init -> PlayerPrefs.init -> MissionWorld.init(C) -> MissionWorld.placeBase -> MissionFlow.start
-- MissionFlow.start가 문(AirlockDoors), 로버(RoverFleet), 상호작용(Interactions)을 기지에 붙이고 미션 선택을 연다.
-- v1 부팅(DevMap, GameFlow, Construction, ModulePanels, WaterLoop, Events, LandingSite, KitImports)은 더 이상 돌리지 않는다.
-- v1 파일은 지우지 않았다(다음 라운드에 정리).
-- Studio(RunService:IsStudio())일 때만 DevBridge가 ServerStorage.FrontierDev(BindableFunction)를 만든다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local DevBridge = require(script.Parent.DevBridge)
local MissionFlow = require(script.Parent.MissionFlow)
local MissionWorld = require(script.Parent.MissionWorld)
local PlayerPrefs = require(script.Parent.PlayerPrefs)

local BOOT_MISSION = "C" -- 지금 플레이할 수 있는 미션 (B는 구현 뒤)

Remotes.init()
PlayerPrefs.init()
local ok, missing = MissionWorld.init(BOOT_MISSION)
if not ok then
    warn(
        "[Main] Mission"
            .. BOOT_MISSION
            .. " 표시가 모자랍니다: "
            .. table.concat(missing, ", ")
    )
end
MissionWorld.placeBase()
MissionFlow.start(BOOT_MISSION)
-- Studio에서만: ServerStorage.FrontierDev (데모 촬영용 장면 명령, 라이브 서버에는 만들지 않는다)
DevBridge.install(RunService:IsStudio())
