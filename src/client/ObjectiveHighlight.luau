--!nonstrict
-- 현재 목표 대상 하나에 Highlight 외곽선을 붙인다. state.missionStage가 nil이거나 대상이 없으면 숨긴다.
-- 대상이 아직 생성되지 않았거나 바뀔 수 있으므로 짧은 주기로 다시 찾는다.

local Players = game:GetService("Players")

local UI = require(script.Parent.UI)
local Colors = UI.Colors

local ObjectiveHighlight = {}

local POLL_SECONDS = 0.5

local stage = nil
local highlight = nil
local currentTarget = nil

local function findPath(...)
    local node = workspace
    for _, name in ipairs({ ... }) do
        node = node and node:FindFirstChild(name)
    end
    return node
end

local function nearestIce()
    local folder = workspace:FindFirstChild("IceSites")
    if not folder then
        return nil
    end
    local character = Players.LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local origin = root and root.Position
    local best, bestDist = nil, math.huge
    for _, part in ipairs(folder:GetChildren()) do
        local deposit = part:GetAttribute("Deposit")
        local depleted = type(deposit) == "number" and deposit <= 0
        if part:IsA("BasePart") and not depleted then
            local dist = if origin then (part.Position - origin).Magnitude else 0
            if dist < bestDist then
                best, bestDist = part, dist
            end
        end
    end
    return best
end

local function resolveTarget()
    if stage == "panels" then
        return findPath("Base", "SolarField", "InstallPad")
    elseif stage == "board_rover" then
        return findPath("Base", "Rover")
    elseif stage == "find_ice" then
        return nearestIce()
    elseif stage == "unload" then
        return findPath("Base", "WaterTank")
    end
    local moduleId = stage and string.match(stage, "^build_(%u)$")
    if moduleId then
        return findPath("Base", "ModulePads", "Pad" .. moduleId, "Pad")
    end
    return nil
end

local function clear()
    if highlight then
        highlight:Destroy()
        highlight = nil
    end
    currentTarget = nil
end

local function refresh()
    local target = resolveTarget()
    if target == currentTarget and (target == nil or highlight) then
        return
    end
    clear()
    if not target then
        return
    end
    currentTarget = target
    highlight = UI.create("Highlight", {
        Name = "ObjectiveHighlight",
        Adornee = target,
        OutlineColor = Colors.energy,
        FillTransparency = 1,
        OutlineTransparency = 0.2,
        DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
        Parent = workspace,
    })
end

function ObjectiveHighlight.init(_ctx)
    task.spawn(function()
        while true do
            if stage then
                refresh()
            end
            task.wait(POLL_SECONDS)
        end
    end)
end

function ObjectiveHighlight.update(state)
    local newStage = state and state.missionStage
    if newStage ~= stage then
        stage = newStage
        clear()
    end
    if stage then
        refresh()
    end
end

return ObjectiveHighlight
