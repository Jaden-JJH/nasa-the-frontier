--!strict
-- v2 착륙선과 에어록 문 (docs/CONTRACT_V2.md 7.5 "Entry.Door", V2_PLAN Q15).
-- v1 Airlock과 같은 여닫기(E로 열면 openSeconds 동안 반투명하게 열리고, 문 범위에 캐릭터가 있으면 닫지 않고 기다린다)에
-- 두 가지를 바꿨다.
--   1) 프롬프트는 Attribute 키 프로토콜(PromptKit)만 쓴다. v1 Airlock은 ActionText에 문장을 쓰고 v1 ResourceState로 알린다.
--   2) SEP(태양 방사선 폭풍) 동안 잠금: setLocked(true)면 열린 문을 닫고(사람이 문틀에 있으면 비켜날 때까지 기다림),
--      프롬프트를 "잠김" 키로 바꾼다. 누르면 그 플레이어에게만 "밖에 나갈 수 없어요" 토스트.
-- MissionWorld가 만든 MissionRuntime 안의 Entry.Door를 모두 찾는다. MissionWorld.reset 뒤에는 attach를 다시 부른다.

local PromptKit = require(script.Parent.PromptKit)
local Sfx = require(script.Parent.Sfx)

local AirlockDoors = {}

-- 엔진 수준 값 (v1 Config.AIRLOCK과 같은 값)
AirlockDoors.CONFIG = {
    openSeconds = 6,
    openTransparency = 0.75,
    openColor = { 160, 175, 190 },
    promptDistance = 8,
    closeCheckDepth = 1.6, -- 닫기 전 캐릭터를 찾는 범위 = 문 두께 + 이 깊이
    closeRetrySeconds = 0.5,
}
local CFG = AirlockDoors.CONFIG

type Door = {
    part: BasePart,
    prompt: ProximityPrompt,
    closedColor: Color3,
    closedTransparency: number,
    open: boolean,
}

local doors: { Door } = {}
local connections: { RBXScriptConnection } = {}
local generation = 0
local locked = false
local lockedNotice: ((Player) -> ())? = nil

local function applyPromptKeys(door: Door)
    if locked then
        PromptKit.set(door.prompt, "prompt.act.door_locked", nil, "world.door.name")
    else
        PromptKit.set(door.prompt, "prompt.act.open_door", nil, "world.door.name")
    end
    PromptKit.setEnabled(door.prompt, locked or not door.open)
end

local function setOpen(door: Door, open: boolean)
    door.open = open
    door.part.CanCollide = not open
    door.part.Transparency = if open then CFG.openTransparency else door.closedTransparency
    door.part.Color = if open
        then Color3.fromRGB(CFG.openColor[1], CFG.openColor[2], CFG.openColor[3])
        else door.closedColor
    applyPromptKeys(door)
end

local function characterInDoorway(part: BasePart): boolean
    local size = part.Size + Vector3.new(0, 0, CFG.closeCheckDepth)
    for _, hit in workspace:GetPartBoundsInBox(part.CFrame, size) do
        local model = hit:FindFirstAncestorOfClass("Model")
        if model and model:FindFirstChildOfClass("Humanoid") then
            return true
        end
    end
    return false
end

-- 문틀이 비면 닫는다 (지금 세대가 끝나면 그만둔다)
local function closeWhenClear(door: Door, myGeneration: number)
    while myGeneration == generation and characterInDoorway(door.part) do
        task.wait(CFG.closeRetrySeconds)
    end
    if myGeneration == generation and door.open then
        setOpen(door, false)
        Sfx.play("airlock_close", door.part)
    end
end

local function openDoor(door: Door, player: Player?)
    if locked then
        local notice = lockedNotice
        if player and notice then
            notice(player)
        end
        return
    end
    if door.open then
        return
    end
    setOpen(door, true)
    Sfx.play("airlock_open", door.part)
    local myGeneration = generation
    task.delay(CFG.openSeconds, function()
        closeWhenClear(door, myGeneration)
    end)
end

-- 잠김 상태에서 문을 누른 플레이어에게 보낼 알림 (MissionFlow가 연결)
function AirlockDoors.setLockedNotice(fn: (Player) -> ())
    lockedNotice = fn
end

-- root 아래 Entry.Door마다 프롬프트를 붙이고 닫힌 상태로 둔다
function AirlockDoors.attach(root: Instance)
    AirlockDoors.detach()
    for _, descendant in root:GetDescendants() do
        local parent = descendant.Parent
        if
            descendant.Name == "Door"
            and descendant:IsA("BasePart")
            and parent ~= nil
            and parent.Name == "Entry"
        then
            local prompt = PromptKit.make(descendant, {
                name = "DoorPrompt",
                actionKey = "prompt.act.open_door",
                objectKey = "world.door.name",
                hold = 0,
                distance = CFG.promptDistance,
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
        warn("[AirlockDoors] MissionRuntime에서 Entry.Door를 찾지 못했습니다")
    end
end

function AirlockDoors.detach()
    generation += 1
    for _, connection in connections do
        connection:Disconnect()
    end
    table.clear(connections)
    for _, door in doors do
        pcall(function()
            door.prompt:Destroy()
        end)
    end
    table.clear(doors)
end

-- SEP 잠금 (Q15). 열린 문은 문틀이 비면 바로 닫는다
function AirlockDoors.setLocked(value: boolean)
    if locked == value then
        return
    end
    locked = value
    generation += 1
    local myGeneration = generation
    for _, door in doors do
        applyPromptKeys(door)
        -- 세대를 바꿔 이전 닫기 대기가 멈췄으므로 열린 문은 다시 닫기를 기다린다
        if door.open then
            task.spawn(closeWhenClear, door, myGeneration)
        end
    end
end

function AirlockDoors.isLocked(): boolean
    return locked
end

-- 테스트와 진단용: 문 수, 열린 문 수
function AirlockDoors.counts(): (number, number)
    local open = 0
    for _, door in doors do
        if door.open then
            open += 1
        end
    end
    return #doors, open
end

return AirlockDoors
