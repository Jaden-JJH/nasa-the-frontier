--!nonstrict
-- v2 아이콘: 글자 없이 Frame 도형만으로 그린다 (Q35 자원 약어 W, E 대신 아이콘 + 숫자).
-- 색은 v1 디자인 언어(에너지 노랑, 물 하늘색, 식량 초록, 산소 주황)를 따른다.
-- Icons.resource(kind, size) -> Frame. kind: "energy" | "water" | "food" | "oxygen" | "battery"
-- Icons.rover(size, color), Icons.base(size, color), Icons.person(size, color), Icons.pin(size, color)

local UI = require(script.Parent.UI)

local Icons = {}

Icons.COLORS = {
    energy = UI.Colors.energy,
    water = UI.Colors.water,
    food = UI.Colors.food,
    oxygen = UI.Colors.oxygen,
    battery = UI.Luna.mint,
}

local function holder(size, name)
    return UI.create("Frame", {
        Name = name or "Icon",
        Size = UDim2.fromOffset(size, size),
        BackgroundTransparency = 1,
    })
end

-- 상대 좌표(0..1)로 막대 하나
local function bar(parent, x, y, w, h, rotation, color, round)
    local frame = UI.create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(x, y),
        Size = UDim2.fromScale(w, h),
        Rotation = rotation or 0,
        BackgroundColor3 = color,
        Parent = parent,
    })
    if round then
        UI.roundCorner().Parent = frame
    end
    return frame
end

-- 번개 (두 개의 기울어진 막대)
local function energy(size, color)
    local icon = holder(size, "Energy")
    bar(icon, 0.56, 0.3, 0.2, 0.5, 25, color, false)
    bar(icon, 0.44, 0.7, 0.2, 0.5, 25, color, false)
    bar(icon, 0.5, 0.5, 0.5, 0.14, -10, color, false)
    return icon
end

-- 물방울 (아래 원 + 45도 돌린 사각형 윗부분)
local function water(size, color)
    local icon = holder(size, "Water")
    bar(icon, 0.5, 0.38, 0.42, 0.42, 45, color, false)
    bar(icon, 0.5, 0.6, 0.62, 0.62, 0, color, true)
    return icon
end

-- 잎 (둥근 몸통 + 줄기)
local function food(size, color)
    local icon = holder(size, "Food")
    local leaf = bar(icon, 0.5, 0.52, 0.56, 0.74, 35, color, false)
    UI.create("UICorner", { CornerRadius = UDim.new(0.5, 0) }).Parent = leaf
    bar(icon, 0.38, 0.82, 0.1, 0.3, -35, color, true)
    return icon
end

-- 산소 (고리 + 작은 점)
local function oxygen(size, color)
    local icon = holder(size, "Oxygen")
    local ring = UI.create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.42, 0.55),
        Size = UDim2.fromScale(0.62, 0.62),
        BackgroundTransparency = 1,
        Parent = icon,
    }, { UI.roundCorner() })
    UI.create("UIStroke", {
        Color = color,
        Thickness = math.max(2, size * 0.12),
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }).Parent =
        ring
    bar(icon, 0.8, 0.22, 0.26, 0.26, 0, color, true)
    return icon
end

-- 배터리 (몸통 + 꼭지)
local function battery(size, color)
    local icon = holder(size, "Battery")
    local body = UI.create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.46, 0.5),
        Size = UDim2.fromScale(0.72, 0.46),
        BackgroundTransparency = 1,
        Parent = icon,
    }, { UI.corner(3) })
    UI.create("UIStroke", {
        Color = color,
        Thickness = 2,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }).Parent =
        body
    bar(body, 0.35, 0.5, 0.5, 0.6, 0, color, false)
    bar(icon, 0.88, 0.5, 0.08, 0.22, 0, color, false)
    return icon
end

local BUILDERS = {
    energy = energy,
    water = water,
    food = food,
    oxygen = oxygen,
    battery = battery,
}

function Icons.resource(kind, size, color)
    local builder = BUILDERS[kind] or energy
    return builder(size or 20, color or Icons.COLORS[kind] or UI.Luna.white)
end

-- 로버 위에서 본 모양 (몸통 + 바퀴 4)
function Icons.rover(size, color)
    local icon = holder(size, "Rover")
    local c = color or UI.Luna.gold
    bar(icon, 0.5, 0.5, 0.56, 0.78, 0, c, false).Name = "Body"
    for _, x in ipairs({ 0.16, 0.84 }) do
        for _, y in ipairs({ 0.25, 0.75 }) do
            bar(icon, x, y, 0.18, 0.28, 0, UI.Luna.inkDeep, true)
        end
    end
    bar(icon, 0.5, 0.22, 0.34, 0.14, 0, UI.Luna.inkDeep, false).Name = "Front"
    return icon
end

-- 기지 (지붕 있는 건물)
function Icons.base(size, color)
    local icon = holder(size, "Base")
    local c = color or UI.Luna.sky
    bar(icon, 0.5, 0.64, 0.8, 0.5, 0, c, false)
    bar(icon, 0.5, 0.34, 0.5, 0.5, 45, c, false)
    bar(icon, 0.5, 0.72, 0.2, 0.3, 0, UI.Luna.inkDeep, false)
    return icon
end

-- 사람 (머리 + 몸)
function Icons.person(size, color)
    local icon = holder(size, "Person")
    local c = color or UI.Luna.white
    bar(icon, 0.5, 0.28, 0.42, 0.42, 0, c, true)
    local body = bar(icon, 0.5, 0.78, 0.7, 0.42, 0, c, false)
    UI.corner(math.max(2, size * 0.18)).Parent = body
    return icon
end

-- 지도 핀 (원 + 아래로 뾰족한 사각형)
function Icons.pin(size, color)
    local icon = holder(size, "Pin")
    local c = color or UI.Luna.mint
    bar(icon, 0.5, 0.56, 0.42, 0.42, 45, c, false)
    bar(icon, 0.5, 0.38, 0.66, 0.66, 0, c, true)
    bar(icon, 0.5, 0.38, 0.26, 0.26, 0, UI.Luna.inkDeep, true)
    return icon
end

-- 위를 가리키는 화살 (핀 화살표 A안의 삼각형 대용: 돌린 사각형 두 개)
function Icons.arrow(size, color)
    local icon = holder(size, "Arrow")
    local c = color or UI.Luna.mint
    local left = bar(icon, 0.36, 0.5, 0.2, 0.86, 28, c, true)
    local right = bar(icon, 0.64, 0.5, 0.2, 0.86, -28, c, true)
    for _, part in ipairs({ left, right }) do
        UI.create("UIStroke", {
            Color = UI.Luna.inkDeep,
            Thickness = 1.5,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }).Parent =
            part
    end
    return icon
end

return Icons
