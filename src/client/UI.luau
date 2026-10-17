--!nonstrict
-- 공용 UI 헬퍼: 색상, 폰트, 인스턴스 생성 단축 함수.
-- 모든 GUI는 코드로만 만든다 (에셋 파일 없음).

local Players = game:GetService("Players")

local UI = {}

-- 다크 남색 계열 팔레트 (CONTRACT 5절 스타일 노트)
UI.Colors = {
    bg = Color3.fromRGB(8, 12, 26),
    panel = Color3.fromRGB(18, 26, 48),
    panelLight = Color3.fromRGB(32, 44, 76),
    text = Color3.fromRGB(255, 255, 255),
    textDim = Color3.fromRGB(165, 175, 200),
    energy = Color3.fromRGB(255, 214, 64),
    water = Color3.fromRGB(86, 190, 255),
    food = Color3.fromRGB(96, 210, 120),
    oxygen = Color3.fromRGB(255, 150, 50),
    good = Color3.fromRGB(90, 210, 120),
    bad = Color3.fromRGB(235, 80, 80),
    neutral = Color3.fromRGB(150, 155, 170),
    accent = Color3.fromRGB(70, 130, 255),
    disabled = Color3.fromRGB(60, 66, 86),
}

-- 월드 라벨(프롬프트, 표지판)이 파트 중심에서 위로 띄우는 기본 거리 (파트 높이의 절반에 더함)
UI.WORLD_ANCHOR_OFFSET = 3

UI.Font = Enum.Font.GothamMedium
UI.FontBold = Enum.Font.GothamBold

-- 텍스트 스타일 프리셋. UI.create의 Preset 속성으로 쓴다 (고정 TextSize, 최소 14).
UI.TextStyles = {
    title = { Font = UI.FontBold, TextSize = 36 },
    heading = { Font = UI.FontBold, TextSize = 20 },
    body = { Font = UI.Font, TextSize = 17 },
    caption = { Font = UI.Font, TextSize = 15 },
    badge = { Font = UI.FontBold, TextSize = 15 },
}

-- 클래스별 기본 속성. props로 덮어쓴다.
local DEFAULTS = {
    Frame = { BorderSizePixel = 0 },
    CanvasGroup = { BorderSizePixel = 0 },
    TextLabel = {
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        Font = UI.Font,
        TextColor3 = UI.Colors.text,
        TextSize = 16,
    },
    TextButton = {
        BorderSizePixel = 0,
        Font = UI.FontBold,
        TextColor3 = UI.Colors.text,
        TextSize = 18,
    },
}

-- Instance.new 래퍼. Parent는 자식 부착 뒤 마지막에 설정한다.
function UI.create(className, props, children)
    local inst = Instance.new(className)
    local defaults = DEFAULTS[className]
    if defaults then
        for key, value in pairs(defaults) do
            inst[key] = value
        end
    end
    local parent = nil
    local preset = props and props.Preset
    if preset then
        for key, value in pairs(UI.TextStyles[preset]) do
            inst[key] = value
        end
    end
    for key, value in pairs(props or {}) do
        if key == "Preset" then
            continue
        elseif key == "Parent" then
            parent = value
        else
            inst[key] = value
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    inst.Parent = parent
    return inst
end

function UI.corner(radius)
    return UI.create("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
end

function UI.roundCorner()
    return UI.create("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end

-- 숫자 하나면 사방 동일, 테이블이면 { top, bottom, left, right }
function UI.padding(value)
    local top, bottom, left, right
    if type(value) == "table" then
        top, bottom, left, right = value[1], value[2], value[3], value[4]
    else
        top, bottom, left, right = value, value, value, value
    end
    return UI.create("UIPadding", {
        PaddingTop = UDim.new(0, top),
        PaddingBottom = UDim.new(0, bottom),
        PaddingLeft = UDim.new(0, left),
        PaddingRight = UDim.new(0, right),
    })
end

function UI.stroke(color, thickness, transparency)
    return UI.create("UIStroke", {
        Color = color or UI.Colors.panelLight,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

function UI.list(direction, padding, hAlign)
    return UI.create("UIListLayout", {
        FillDirection = direction or Enum.FillDirection.Vertical,
        Padding = UDim.new(0, padding or 0),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
    })
end

-- LocalPlayer.PlayerGui 아래에 ScreenGui를 만든다.
function UI.gui(name, displayOrder, ignoreInset)
    local player = Players.LocalPlayer
    return UI.create("ScreenGui", {
        Name = name,
        ResetOnSpawn = false,
        IgnoreGuiInset = ignoreInset ~= false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = displayOrder or 0,
        Parent = player:WaitForChild("PlayerGui"),
    })
end

-- 월드 라벨용 외곽선 (밝은 배경에서도 읽히게)
function UI.worldStroke()
    return UI.create("UIStroke", {
        Color = Color3.fromRGB(8, 12, 26),
        Thickness = 1.5,
        Transparency = 0.3,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
    })
end

-- 터치 기기이면서 키보드가 없으면 true (모바일 배치용)
function UI.isTouchOnly()
    local input = game:GetService("UserInputService")
    return input.TouchEnabled and not input.KeyboardEnabled
end

-- 진행바. root 안에 fill이 있고 setRatio(0..1)로 채운다.
function UI.progressBar(color, height)
    local fill = UI.create("Frame", {
        Name = "Fill",
        BackgroundColor3 = color,
        Size = UDim2.fromScale(0, 1),
    }, { UI.corner(3) })
    local root = UI.create("Frame", {
        Name = "Bar",
        BackgroundColor3 = UI.Colors.bg,
        Size = UDim2.new(1, 0, 0, height or 6),
    }, { UI.corner(3), fill })
    local bar = { root = root, fill = fill }
    function bar.setRatio(ratio)
        fill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
    end
    return bar
end

return UI
