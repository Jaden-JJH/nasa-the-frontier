--!nonstrict
-- 대원 머리 위 상태 아이콘 (V2_PLAN 15.9 Q32, 3.8). 기지의 물이나 식량이 20 미만이면(state.lowWarn)
-- 모든 대원 머리 위에 물방울(목마름), 잎(배고픔) 아이콘을 띄운다. 글자 없이 아이콘만 쓴다.
-- BillboardGui는 PlayerGui에 두고 Adornee만 각 캐릭터의 Head로 잡는다(이 클라이언트에만 보인다).

local Players = game:GetService("Players")

local Icons = require(script.Parent.Icons)
local UI = require(script.Parent.UI)
local L = UI.Luna

local HeadStatus = {}

local ICON_SIZE = 26
local BADGE_SIZE = 34
local STUDS_ABOVE = 2.6
local KINDS = { "water", "food" }

local playerGui
local boards = {} -- [Player] = { gui, badges = { [kind] = Frame } }
local low = { water = false, food = false }
local enabled = false

local function build(player)
    local badges = {}
    local gui = UI.create("BillboardGui", {
        Name = "HeadStatus_" .. player.UserId,
        Size = UDim2.fromOffset(BADGE_SIZE * 2 + 6, BADGE_SIZE),
        StudsOffset = Vector3.new(0, STUDS_ABOVE, 0),
        AlwaysOnTop = true,
        LightInfluence = 0,
        MaxDistance = 120,
        ResetOnSpawn = false,
        Enabled = false,
        Parent = playerGui,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
    for i, kind in ipairs(KINDS) do
        local icon = Icons.resource(kind, ICON_SIZE)
        icon.AnchorPoint = Vector2.new(0.5, 0.5)
        icon.Position = UDim2.fromScale(0.5, 0.5)
        badges[kind] = UI.create("Frame", {
            Name = kind,
            LayoutOrder = i,
            Size = UDim2.fromOffset(BADGE_SIZE, BADGE_SIZE),
            BackgroundColor3 = L.inkDeep,
            BackgroundTransparency = 0.2,
            Visible = false,
            Parent = gui,
        }, { UI.roundCorner(), UI.stroke(L.red, 2, 0), icon })
    end
    boards[player] = { gui = gui, badges = badges }
    return boards[player]
end

local function refreshPlayer(player)
    local board = boards[player] or build(player)
    local character = player.Character
    local head = character and character:FindFirstChild("Head")
    board.gui.Adornee = head
    local any = false
    for _, kind in ipairs(KINDS) do
        local show = enabled and low[kind]
        board.badges[kind].Visible = show
        any = any or show
    end
    board.gui.Enabled = any and head ~= nil
end

local function refreshAll()
    for _, player in ipairs(Players:GetPlayers()) do
        refreshPlayer(player)
    end
end

function HeadStatus.init(_ctx)
    playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    local function watch(player)
        player.CharacterAdded:Connect(function(character)
            character:WaitForChild("Head", 10)
            refreshPlayer(player)
        end)
        refreshPlayer(player)
    end
    for _, player in ipairs(Players:GetPlayers()) do
        watch(player)
    end
    Players.PlayerAdded:Connect(watch)
    Players.PlayerRemoving:Connect(function(player)
        local board = boards[player]
        if board then
            board.gui:Destroy()
            boards[player] = nil
        end
    end)
end

function HeadStatus.update(state)
    local lowWarn = type(state) == "table" and state.lowWarn or {}
    low.water = lowWarn.water == true
    low.food = lowWarn.food == true
    enabled = type(state) == "table" and state.phase == "playing"
    refreshAll()
end

return HeadStatus
