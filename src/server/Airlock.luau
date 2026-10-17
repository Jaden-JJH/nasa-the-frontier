--!strict
-- 에어락 문 (착륙선, Habitat A): 기지 안의 Entry.Door 파트마다 "에어락 / 열기" 프롬프트를 붙인다.
-- 닫힌 문은 막혀 있고(CanCollide true), E를 누르면 Config.AIRLOCK.openSeconds 동안 반투명하게 열린다.
-- 시간이 지나도 문 범위 안에 캐릭터가 있으면 닫지 않고 기다린다.
-- 처음 문을 연 플레이어에게는 안내 토스트를 한 번 보낸다 (게임마다 초기화).
-- Habitat A의 문은 Built 안에 있으므로 Construction.attach가 Built를 빼기 전에 attach를 불러야 한다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)

local Airlock = {}

type Door = {
    part: BasePart,
    prompt: ProximityPrompt,
    closedColor: Color3,
    closedTransparency: number,
    open: boolean,
}

local doors: { Door } = {}
local connections: { RBXScriptConnection } = {}
local notified: { [Player]: boolean } = {}
local generation = 0 -- attach/detach마다 증가. 이전 기지의 닫기 대기 스레드를 멈춘다

local function setOpen(door: Door, open: boolean)
    local a = Config.AIRLOCK
    door.open = open
    door.part.CanCollide = not open
    door.part.Transparency = if open then a.openTransparency else door.closedTransparency
    door.part.Color = if open then Color3.fromRGB(table.unpack(a.openColor)) else door.closedColor
    door.prompt.Enabled = not open
end

-- 문 범위(문 크기 + 앞뒤 closeCheckDepth) 안에 캐릭터 파트가 있는지
local function characterInDoorway(part: BasePart): boolean
    local size = part.Size + Vector3.new(0, 0, Config.AIRLOCK.closeCheckDepth)
    for _, hit in workspace:GetPartBoundsInBox(part.CFrame, size) do
        local model = hit:FindFirstAncestorOfClass("Model")
        if model and model:FindFirstChildOfClass("Humanoid") then
            return true
        end
    end
    return false
end

local function openDoor(door: Door, player: Player?)
    if door.open then
        return
    end
    setOpen(door, true)
    if player and not notified[player] then
        notified[player] = true
        ResourceState.notify(player, Config.TEXTS.airlockOpened, "info")
    end
    local myGeneration = generation
    task.delay(Config.AIRLOCK.openSeconds, function()
        while myGeneration == generation and characterInDoorway(door.part) do
            task.wait(Config.AIRLOCK.closeRetrySeconds)
        end
        if myGeneration == generation then
            setOpen(door, false)
        end
    end)
end

-- 새 기지의 에어락 문에 프롬프트를 붙이고 닫힌 상태로 둔다
function Airlock.attach(base: Model)
    Airlock.detach()
    for _, descendant in base:GetDescendants() do
        local parent = descendant.Parent
        if
            descendant.Name == "Door"
            and descendant:IsA("BasePart")
            and parent ~= nil
            and parent.Name == "Entry"
        then
            local prompt = ServerUtil.makePrompt(descendant, {
                actionText = Config.PROMPT_TEXTS.openDoor,
                objectText = Config.PROMPT_TEXTS.airlockObject,
                holdDuration = 0,
                maxDistance = Config.AIRLOCK.promptDistance,
            })
            local door: Door = {
                part = descendant,
                prompt = prompt,
                closedColor = descendant.Color,
                closedTransparency = descendant.Transparency,
                open = false,
            }
            setOpen(door, false)
            table.insert(doors, door)
            table.insert(
                connections,
                prompt.Triggered:Connect(function(player: Player)
                    openDoor(door, player)
                end)
            )
        end
    end
    if #doors == 0 then
        warn(
            "[Airlock] 기지에서 Entry.Door를 찾지 못했습니다. 에어락 문 프롬프트가 없습니다"
        )
    end
end

function Airlock.detach()
    generation += 1
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, door in doors do
        door.prompt:Destroy()
    end
    table.clear(doors)
    table.clear(notified)
end

-- 테스트와 진단용: 지금 붙어 있는 문 수와 열린 문 수
function Airlock.counts(): (number, number)
    local open = 0
    for _, door in doors do
        if door.open then
            open += 1
        end
    end
    return #doors, open
end

return Airlock
