--!strict
-- 우주복: 서버가 캐릭터마다 입힌다 (모든 플레이어에게 보인다). 리스폰마다 다시 적용한다.
--   (a) Shirt, Pants, ShirtGraphic, Accessory(머리카락 포함) 제거. 늦게 붙는 것도 ChildAdded로 제거
--   (b) BodyColors: 몸통, 오른팔, 다리는 흰 수트, 왼팔은 주황 포인트 (머리는 그대로, 헬멧 안에 보인다)
--   (c) 머리에 반투명 유리 헬멧 (구형, 머리의 약 1.4배)
--   (d) 등에 생명유지 배낭, (e) 가슴에 작은 주황 제어판
-- 장식 파트는 모두 Massless, CanCollide/CanQuery/CanTouch 꺼짐이라 산소 판정이나 프롬프트를 가리지 않는다.
-- R15(UpperTorso)와 R6(Torso) 모두 동작한다. 수치는 Config.SUIT.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local Spacesuit = {}

local SUIT_PART_NAMES = { "SuitHelmet", "SuitPack", "SuitPanel" }

local function rgb(values: { number }): Color3
    return Color3.fromRGB(values[1], values[2], values[3])
end

local function vec(values: { number }): Vector3
    return Vector3.new(values[1], values[2], values[3])
end

local function isClothing(inst: Instance): boolean
    return inst:IsA("Accessory")
        or inst:IsA("Shirt")
        or inst:IsA("Pants")
        or inst:IsA("ShirtGraphic")
end

local function paintBody(colors: BodyColors)
    local suit = Config.SUIT
    local white, accent = rgb(suit.suitColor), rgb(suit.accentColor)
    colors.TorsoColor3 = white
    colors.RightArmColor3 = white
    colors.LeftLegColor3 = white
    colors.RightLegColor3 = white
    colors.LeftArmColor3 = accent
end

-- 대상 파트에 용접된 장식 파트
local function attachPart(
    character: Model,
    target: BasePart,
    name: string,
    size: Vector3,
    offset: CFrame,
    color: Color3
): Part
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = target.CFrame * offset
    part.Color = color
    part.Material = Enum.Material.SmoothPlastic
    part.Anchored = false
    part.Massless = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = target
    weld.Part1 = part
    weld.Parent = part
    part.Parent = character
    return part
end

local function findPart(character: Model, name: string): BasePart?
    local child = character:FindFirstChild(name)
    if child and child:IsA("BasePart") then
        return child
    end
    return nil
end

-- 캐릭터에 우주복을 입힌다 (여러 번 불러도 결과는 같다)
function Spacesuit.apply(character: Model)
    local suit = Config.SUIT
    for _, child in character:GetChildren() do
        if isClothing(child) then
            child:Destroy()
        end
    end
    for _, name in SUIT_PART_NAMES do
        local old = character:FindFirstChild(name)
        if old then
            old:Destroy()
        end
    end

    local colors = character:FindFirstChildOfClass("BodyColors")
    if not colors then
        local created = Instance.new("BodyColors")
        created.Parent = character
        colors = created
    end
    if colors then
        paintBody(colors)
    end

    local head = findPart(character, "Head")
    if head then
        local headSize = math.max(head.Size.Y, head.Size.Z, suit.headMinSize)
        local helmet = attachPart(
            character,
            head,
            "SuitHelmet",
            Vector3.one * headSize * suit.helmetScale,
            CFrame.identity,
            rgb(suit.helmetColor)
        )
        helmet.Shape = Enum.PartType.Ball
        helmet.Material = Enum.Material.Glass
        helmet.Transparency = suit.helmetTransparency
    end

    local torso = findPart(character, "UpperTorso") or findPart(character, "Torso")
    if torso then
        local packSize = vec(suit.packSize)
        attachPart(
            character,
            torso,
            "SuitPack",
            packSize,
            -- 캐릭터 앞쪽이 -Z이므로 등은 +Z
            CFrame.new(0, suit.packOffsetY, torso.Size.Z / 2 + packSize.Z / 2),
            rgb(suit.packColor)
        )
        local panelSize = vec(suit.panelSize)
        attachPart(
            character,
            torso,
            "SuitPanel",
            panelSize,
            CFrame.new(0, suit.panelOffsetY, -(torso.Size.Z / 2 + panelSize.Z / 2)),
            rgb(suit.panelColor)
        )
    end
end

-- 플레이어의 현재와 이후 캐릭터에 우주복을 입힌다
function Spacesuit.watch(player: Player)
    local function onCharacter(character: Model)
        -- 아바타 외형이 늦게 붙으면 바로 걷어 내고, BodyColors가 새로 생기면 다시 칠한다
        character.ChildAdded:Connect(function(child: Instance)
            if isClothing(child) then
                task.defer(function()
                    child:Destroy()
                end)
            elseif child:IsA("BodyColors") then
                task.defer(paintBody, child)
            end
        end)
        task.spawn(function()
            character:WaitForChild("Head", Config.SUIT.loadTimeout)
            if character.Parent ~= nil or player.Character == character then
                Spacesuit.apply(character)
            end
        end)
    end
    player.CharacterAdded:Connect(onCharacter)
    -- 외형이 다 붙은 뒤 한 번 더 (머리 크기가 바뀌었을 수 있다)
    player.CharacterAppearanceLoaded:Connect(function(character: Model)
        Spacesuit.apply(character)
    end)
    local current = player.Character
    if current then
        onCharacter(current)
    end
end

return Spacesuit
