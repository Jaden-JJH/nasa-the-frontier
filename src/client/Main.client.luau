--!nonstrict
-- v2 클라이언트 진입점 (CONTRACT_V2 2.3): Localizer 초기화, Remotes 연결, phase에 따른 화면 전환.
-- v1 화면(TitleUI, SiteSelectUI, HUD, ResultUI, RadarUI, PadSignUI, DockSignUI, RoverHint, ObjectiveHighlight)은
-- 이 스크립트가 require하지 않으므로 실행되지 않는다(파일은 이번 라운드에 지우지 않는다).
--
-- 화면 전환
--   StateUpdate 전이나 selecting: 타이틀(로컬에서 시작을 누르기 전) -> 미션 선택
--   landing: 착륙 카메라 (RoleUpdate selecting이면 역할 선택이 위에 뜬다)
--   playing: HUD, 산소 바, 설정, Tip/사실 카드, 콘솔(프롬프트로 열기), 핀 화살표(탐사대원),
--            건물 안내 카드(콘솔, 결과, 역할 선택이 닫혀 있을 때), 로버 충전 표지,
--            멀티 역할 미션(HUD 카드는 HUDV2, 정찰 표시는 ScoutMarkers)
--   result: 결과 화면 (GameOver, 놓쳤으면 상태로 최소 표시)

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Localizer = require(script.Parent.Localizer)
local Net = require(script.Parent.Net)
local Session = require(script.Parent.Session)
local WorldPoints = require(script.Parent.WorldPoints)

local SoundFX = require(script.Parent.SoundFX)
local RoverBoost = require(script.Parent.RoverBoost)
local BoostFX = require(script.Parent.BoostFX)
local TitleV2 = require(script.Parent.TitleV2)
local MissionSelectUI = require(script.Parent.MissionSelectUI)
local RoleSelectUI = require(script.Parent.RoleSelectUI)
local LandingCamera = require(script.Parent.LandingCamera)
local HUDV2 = require(script.Parent.HUDV2)
local HeadStatus = require(script.Parent.HeadStatus)
local WeatherFX = require(script.Parent.WeatherFX)
local OxygenBar = require(script.Parent.OxygenBar)
local ToastUI = require(script.Parent.ToastUI)
local PromptUI = require(script.Parent.PromptUI)
local TipUI = require(script.Parent.TipUI)
local FactUI = require(script.Parent.FactUI)
local SettingsUI = require(script.Parent.SettingsUI)
local ConsoleUI = require(script.Parent.ConsoleUI)
local PinArrowUI = require(script.Parent.PinArrowUI)
local ResultV2 = require(script.Parent.ResultV2)
local BuildingInfoUI = require(script.Parent.BuildingInfoUI)
local RoverChargeSign = require(script.Parent.RoverChargeSign)
local ScoutMarkers = require(script.Parent.ScoutMarkers)

local RUNTIME_FOLDER = "MissionRuntime"
local RESET_RETRY_COUNT = 10
local RESET_RETRY_SECONDS = 0.5

-- 한 모듈의 에러가 클라이언트 전체(뒤의 init, 원격 핸들러, 화면 전환)를 멈추지 않게 격리한다
local function safe(name, fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
        warn("[Main] " .. name .. " 실패: " .. tostring(err))
    end
end

-- 기본 체력바는 산소 바와 혼동되므로 끈다 (실패해도 무시)
pcall(function()
    StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)
pcall(function()
    StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)
-- 메뉴의 캐릭터 초기화(Reset)를 끈다. CoreScript가 늦게 뜨면 실패하므로 몇 번 다시 시도한다
task.spawn(function()
    for _ = 1, RESET_RETRY_COUNT do
        if
            pcall(function()
                StarterGui:SetCore("ResetButtonCallback", false)
            end)
        then
            return
        end
        task.wait(RESET_RETRY_SECONDS)
    end
end)

-- 다국어 ------------------------------------------------------------------------
Localizer.get() -- 속성 감시 시작 (서버가 복제한 Lang)

-- 입력 장치별 키 라벨 ({key_interact}, {key_repair}, {key_boost}, I18N_PLAN 4.4)
local KEYBOARD_LABELS = { key_interact = "E", key_repair = "R", key_boost = "Shift" }
local GAMEPAD_LABELS = { key_interact = "X", key_repair = "X", key_boost = "X" }
local TOUCH_LABELS = {
    key_interact = { key = "key.touch.tap" },
    key_repair = { key = "key.touch.tap" },
    key_boost = { key = "key.touch.boost" },
}
local lastDevice = nil
local function applyKeyLabels(inputType)
    local device
    if inputType == Enum.UserInputType.Touch then
        device = "touch"
    elseif inputType and string.find(inputType.Name, "Gamepad") then
        device = "gamepad"
    elseif inputType == nil then
        device = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
            then "touch"
            else "keyboard"
    else
        device = "keyboard"
    end
    if device == lastDevice then
        return
    end
    lastDevice = device
    Localizer.setKeyLabels(
        if device == "touch"
            then TOUCH_LABELS
            elseif device == "gamepad" then GAMEPAD_LABELS
            else KEYBOARD_LABELS
    )
end
applyKeyLabels(nil)
UserInputService.LastInputTypeChanged:Connect(function(inputType)
    if
        inputType == Enum.UserInputType.Touch
        or string.find(inputType.Name, "Gamepad")
        or inputType == Enum.UserInputType.Keyboard
        or inputType == Enum.UserInputType.MouseButton1
    then
        applyKeyLabels(inputType)
    end
end)

-- 3D 이름표와 표지판 (MissionWorld가 TextKey 속성만 단다, CONTRACT_V2 7.5)
-- 글자 요소면 TextKey(+ TextArgs, 예: 얼음 후보지 번호)로 등록하고 true. 속성이 바뀌면 Localizer가 다시 그린다
local function bindTextObject(object)
    local isText = Localizer.bindTextObject(object)
    return isText
end

local function watchRuntime(folder)
    Localizer.bindTextKeys(folder)
    folder.DescendantAdded:Connect(function(object)
        -- 속성은 부모를 붙인 직후에 달릴 수 있어 한 프레임 미룬다
        task.defer(function()
            if not object.Parent then
                return
            end
            if
                not bindTextObject(object)
                and (object:IsA("LayerCollector") or #object:GetChildren() > 0)
            then
                Localizer.bindTextKeys(object)
            end
        end)
    end)
end

local existingRuntime = workspace:FindFirstChild(RUNTIME_FOLDER)
if existingRuntime then
    watchRuntime(existingRuntime)
end
workspace.ChildAdded:Connect(function(child)
    if child.Name == RUNTIME_FOLDER then
        watchRuntime(child)
    end
end)

-- 화면 전환 ------------------------------------------------------------------------
local titleDismissed = false

local function applyScreens()
    local phase = Session.phase()
    local selecting = phase == nil or phase == "selecting"
    local playing = phase == "playing"
    local role = Session.myRole()
    local pinArrow = playing
        and Session.isMulti()
        and role ~= nil
        and role ~= "controller"
        and Session.pinSite ~= nil
        and not Session.isGst()
        and not ConsoleUI.isOpen()

    -- 화면마다 따로 격리한다 (init에 실패한 화면이 있어도 나머지는 바뀐다)
    safe("TitleV2.setVisible", TitleV2.setVisible, selecting and not titleDismissed)
    safe("MissionSelectUI.setVisible", MissionSelectUI.setVisible, selecting and titleDismissed)
    safe(
        "RoleSelectUI.setVisible",
        RoleSelectUI.setVisible,
        Session.rolesSelecting and Session.isMulti() and phase ~= "result"
    )
    safe("HUDV2.setVisible", HUDV2.setVisible, playing)
    safe("OxygenBar.setVisible", OxygenBar.setVisible, playing)
    safe("SettingsUI.setVisible", SettingsUI.setVisible, playing)
    safe("TipUI.setContext", TipUI.setContext, Session.mode(), role)
    safe("PinArrowUI.setActive", PinArrowUI.setActive, pinArrow)
    safe(
        "BuildingInfoUI.setVisible",
        BuildingInfoUI.setVisible,
        playing
            and not ConsoleUI.isOpen()
            and not ResultV2.isVisible()
            and not (Session.rolesSelecting and Session.isMulti())
    )
    if phase ~= "landing" then
        safe("LandingCamera.stop", LandingCamera.stop)
    end
    if not playing then
        safe("ConsoleUI.close", ConsoleUI.close)
    end
    if selecting then
        safe("ResultV2.hide", ResultV2.hide)
    end
end

local ctx = {
    onStart = function()
        titleDismissed = true
        applyScreens()
    end,
}

local MODULES = {
    { name = "SoundFX", module = SoundFX },
    { name = "RoverBoost", module = RoverBoost },
    { name = "BoostFX", module = BoostFX },
    { name = "TitleV2", module = TitleV2 },
    { name = "MissionSelectUI", module = MissionSelectUI },
    { name = "RoleSelectUI", module = RoleSelectUI },
    { name = "LandingCamera", module = LandingCamera },
    { name = "HUDV2", module = HUDV2 },
    { name = "BuildingInfoUI", module = BuildingInfoUI }, -- HUDV2 뒤 (compact 위치가 HUD 오른쪽 열을 따른다)
    { name = "RoverChargeSign", module = RoverChargeSign },
    { name = "ScoutMarkers", module = ScoutMarkers },
    { name = "HeadStatus", module = HeadStatus },
    { name = "WeatherFX", module = WeatherFX },
    { name = "OxygenBar", module = OxygenBar },
    { name = "ToastUI", module = ToastUI },
    { name = "PromptUI", module = PromptUI },
    { name = "TipUI", module = TipUI },
    { name = "FactUI", module = FactUI },
    { name = "SettingsUI", module = SettingsUI },
    { name = "ConsoleUI", module = ConsoleUI },
    { name = "PinArrowUI", module = PinArrowUI },
    { name = "ResultV2", module = ResultV2 },
}
for _, entry in ipairs(MODULES) do
    safe(entry.name .. ".init", entry.module.init, ctx)
end

safe("applyScreens", applyScreens)

-- 콘솔 열기: 착륙선 콘솔 프롬프트 (Attribute OpenUI == "console" 또는 ActionKey == prompt.act.open_console)
ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
    if player ~= nil and player ~= Players.LocalPlayer then
        return
    end
    if ConsoleUI.isConsolePrompt(prompt) then
        safe("ConsoleUI.open", ConsoleUI.open, prompt.Parent)
        safe("applyScreens", applyScreens)
    end
end)

-- 원격 이벤트 (CONTRACT_V2 4.1) ------------------------------------------------------
Net.on("StateUpdate", function(state)
    if type(state) ~= "table" then
        return
    end
    Session.setState(state)
    WorldPoints.setStatePoints(state)
    -- 화면 전환을 먼저 한다 (아래 소비자 하나가 실패해도 화면은 바뀐다)
    safe("applyScreens", applyScreens)
    safe("HUDV2.update", HUDV2.update, state)
    safe("BuildingInfoUI.update", BuildingInfoUI.update, state)
    safe("RoverChargeSign.update", RoverChargeSign.update, state)
    safe("ScoutMarkers.update", ScoutMarkers.update, state)
    safe("HeadStatus.update", HeadStatus.update, state)
    safe("WeatherFX.update", WeatherFX.update, state)
    safe("BoostFX.update", BoostFX.update, state)
    safe("TipUI.onState", TipUI.onState, state)
    safe("FactUI.onState", FactUI.onState, state)
    safe("SoundFX.onState", SoundFX.onState, state)
    -- GameOver를 놓친 늦은 입장자를 위한 대체 표시
    if state.phase == "result" and not ResultV2.isVisible() then
        safe("ResultV2.showFromState", ResultV2.showFromState, state)
    end
end)

Net.on("MissionSelectOpen", function(payload)
    safe("MissionSelectUI.open", MissionSelectUI.open, payload)
    safe("applyScreens", applyScreens)
end)

Net.on("LandingSequence", function(missionId, landerCFrame, seconds)
    safe("LandingCamera.play", LandingCamera.play, missionId, landerCFrame, seconds)
end)

Net.on("SpaceWeather", function(payload)
    safe("HUDV2.onSpaceWeather", HUDV2.onSpaceWeather, payload)
    safe("WeatherFX.onSpaceWeather", WeatherFX.onSpaceWeather, payload)
    safe("FactUI.onSpaceWeather", FactUI.onSpaceWeather, payload)
    if type(payload) == "table" and payload.stage == "warning" then
        SoundFX.play("notify_warn")
    end
end)

Net.on("RoleUpdate", function(...)
    safe("Session.setRoles", Session.setRoles, ...)
    safe("applyScreens", applyScreens)
end)

Net.on("PinUpdate", function(payload)
    safe("Session.setPin", Session.setPin, payload)
    safe("TipUI.onPin", TipUI.onPin, Session.pinSite)
    safe("FactUI.onPin", FactUI.onPin, Session.pinSite)
    safe("applyScreens", applyScreens)
end)

Net.on("OxygenUpdate", function(oxygen, max, zone)
    safe("OxygenBar.update", OxygenBar.update, oxygen, max, zone)
    safe("SoundFX.onOxygen", SoundFX.onOxygen, oxygen, max, zone)
    safe("TipUI.onOxygen", TipUI.onOxygen, oxygen, max, zone)
    safe("FactUI.onOxygen", FactUI.onOxygen, oxygen, max, zone)
end)

Net.on("Notify", function(msg, kind)
    safe("ToastUI.push", ToastUI.push, msg, kind)
    safe("SoundFX.onNotify", SoundFX.onNotify, msg, kind)
end)

Net.on("GameOver", function(result)
    safe("ConsoleUI.close", ConsoleUI.close)
    safe("ResultV2.show", ResultV2.show, result)
    safe("SoundFX.onGameOver", SoundFX.onGameOver, result)
end)

Net.on("Records", function(payload)
    safe("ResultV2.setRecords", ResultV2.setRecords, payload)
end)

-- 콘솔을 닫으면 핀 화살표를 다시 보일 수 있게 주기적으로 맞춘다 (닫기는 여러 곳에서 일어난다)
task.spawn(function()
    local wasOpen = false
    while true do
        task.wait(0.25)
        local open = ConsoleUI.isOpen()
        if open ~= wasOpen then
            wasOpen = open
            safe("applyScreens", applyScreens)
        end
    end
end)
