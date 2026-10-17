--!nonstrict
-- 클라이언트 진입점: Remotes 연결, UI 모듈 init, phase에 따라 화면 전환.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local TitleUI = require(script.Parent.TitleUI)
local SiteSelectUI = require(script.Parent.SiteSelectUI)
local LandingCamera = require(script.Parent.LandingCamera)
local HUD = require(script.Parent.HUD)
local OxygenBar = require(script.Parent.OxygenBar)
local RadarUI = require(script.Parent.RadarUI)
local ToastUI = require(script.Parent.ToastUI)
local ResultUI = require(script.Parent.ResultUI)
local PromptUI = require(script.Parent.PromptUI)
local PadSignUI = require(script.Parent.PadSignUI)
local RoverHint = require(script.Parent.RoverHint)
local ObjectiveHighlight = require(script.Parent.ObjectiveHighlight)

-- 기본 체력바는 산소 바와 혼동되므로 끈다 (실패해도 무시)
pcall(function()
    StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

pcall(function()
    StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)

-- 메뉴의 캐릭터 초기화(Reset)를 끈다 (실패해도 무시)
pcall(function()
    StarterGui:SetCore("ResetButtonCallback", false)
end)

local REMOTE_NAMES = {
    "StateUpdate",
    "OxygenUpdate",
    "Notify",
    "SiteSelectionOpen",
    "LandingSequence",
    "GameOver",
    "SelectSite",
    "SetSpeed",
    "RequestRestart",
}

local remotes = {}
for _, name in ipairs(REMOTE_NAMES) do
    remotes[name] = Remotes.get(name)
end

local lastState = nil
local titleDismissed = false

-- 마지막 StateUpdate의 phase에 맞춰 화면을 보이거나 숨긴다
local function applyScreens()
    if not lastState then
        return
    end
    local phase = lastState.phase
    local selecting = phase == "selecting"
    local playing = phase == "playing"

    TitleUI.setVisible(selecting and not titleDismissed)
    SiteSelectUI.setVisible(selecting and titleDismissed)
    HUD.setVisible(playing or phase == "won" or phase == "lost")
    OxygenBar.setVisible(playing)
    RadarUI.setEnabled(playing)

    if phase ~= "landing" then
        LandingCamera.stop()
    end
    if selecting then
        ResultUI.hide()
    end
end

local ctx = {
    Config = Config,
    remotes = remotes,
    onStart = function()
        titleDismissed = true
        applyScreens()
    end,
}

TitleUI.init(ctx)
SiteSelectUI.init(ctx)
LandingCamera.init(ctx)
HUD.init(ctx)
OxygenBar.init(ctx)
RadarUI.init(ctx)
ToastUI.init(ctx)
ResultUI.init(ctx)
PromptUI.init(ctx)
PadSignUI.init(ctx)
RoverHint.init(ctx)
ObjectiveHighlight.init(ctx)

remotes.StateUpdate.OnClientEvent:Connect(function(state)
    lastState = state
    HUD.update(state)
    PadSignUI.update(state)
    RoverHint.onState(state)
    ObjectiveHighlight.update(state)
    RadarUI.onState(state)
    applyScreens()
    -- GameOver를 놓친 늦은 입장자를 위한 대체 표시
    if (state.phase == "won" or state.phase == "lost") and not ResultUI.isVisible() then
        ResultUI.showFromState(state)
    end
end)

remotes.SiteSelectionOpen.OnClientEvent:Connect(function(info)
    SiteSelectUI.open(info)
    applyScreens()
end)

remotes.OxygenUpdate.OnClientEvent:Connect(function(oxygen, max, inside)
    OxygenBar.update(oxygen, max, inside)
end)

remotes.Notify.OnClientEvent:Connect(function(text, kind)
    ToastUI.push(text, kind)
end)

remotes.GameOver.OnClientEvent:Connect(function(result)
    ResultUI.show(result)
end)
