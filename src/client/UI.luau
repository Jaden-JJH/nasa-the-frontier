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
-- v2: 모든 글자 요소는 AutoLocalize = false (Roblox 자동 번역 금지, CONTRACT_V2 1절, Q38)
local DEFAULTS = {
    Frame = { BorderSizePixel = 0 },
    CanvasGroup = { BorderSizePixel = 0 },
    TextLabel = {
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        Font = UI.Font,
        TextColor3 = UI.Colors.text,
        TextSize = 16,
        AutoLocalize = false,
    },
    TextButton = {
        BorderSizePixel = 0,
        Font = UI.FontBold,
        TextColor3 = UI.Colors.text,
        TextSize = 18,
        AutoLocalize = false,
    },
    TextBox = { AutoLocalize = false },
    ScreenGui = { AutoLocalize = false },
    BillboardGui = { AutoLocalize = false },
    SurfaceGui = { AutoLocalize = false },
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

-- 메뉴 화면 C안 "루나 소프트" 팔레트와 헬퍼 (2026-10-19 18차, 타이틀, 착륙지 선택, 결과 화면).
-- 목업 1280x720 기준 수치를 그대로 쓴다. 한글은 어떤 폰트든 시스템 폰트로 대체되므로 영문과 숫자에만 폰트가 보인다.
-- 역할 분리: 제목과 큰 숫자는 둥근 Nunito, 표 데이터는 RobotoMono, 한글은 기존 Gotham.
UI.Luna = {
    bgTop = Color3.fromRGB(20, 33, 92), -- #14215c
    bgMid = Color3.fromRGB(42, 42, 120), -- #2a2a78
    bgBottom = Color3.fromRGB(75, 47, 134), -- #4b2f86
    mint = Color3.fromRGB(126, 224, 184), -- 주 버튼, 선택, 성공 (#7ee0b8)
    gold = Color3.fromRGB(255, 209, 102), -- 에너지, 명예의 전당 (#ffd166)
    sky = Color3.fromRGB(143, 211, 255), -- 물, 정보 (#8fd3ff)
    orange = Color3.fromRGB(255, 179, 107), -- 산소 (#ffb36b)
    red = Color3.fromRGB(255, 157, 157), -- 실패, 험한 지형 (#ff9d9d)
    soft = Color3.fromRGB(223, 230, 255), -- 부제, 설명 (#dfe6ff)
    body = Color3.fromRGB(228, 235, 255), -- 패널 본문 (#e4ebff)
    label = Color3.fromRGB(207, 216, 247), -- 라벨, 보조 (#cfd8f7)
    dim = Color3.fromRGB(170, 182, 220), -- 흐린 글자 (#aab6dc)
    faint = Color3.fromRGB(127, 143, 189), -- 지도 라벨, 비선택 번호 (#7f8fbd)
    ink = Color3.fromRGB(15, 42, 58), -- 민트, 금색 위 글자 (#0f2a3a)
    inkDeep = Color3.fromRGB(11, 18, 48), -- 착륙 버튼, 아바타 글자 (#0b1230)
    pin = Color3.fromRGB(43, 47, 120), -- 비선택 핀 (#2b2f78)
    crater = Color3.fromRGB(60, 70, 120), -- 지도 크레이터 음영
    white = Color3.new(1, 1, 1),
}
UI.LUNA_PANEL_TRANSPARENCY = 0.9 -- rgba(255,255,255,0.10)
UI.LUNA_STROKE_TRANSPARENCY = 0.86 -- rgba(255,255,255,0.14)

UI.Mono = Enum.Font.RobotoMono
UI.MonoBold = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
UI.RoundHeavy = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.Heavy)
UI.RoundBold = Font.new("rbxasset://fonts/families/Nunito.json", Enum.FontWeight.ExtraBold)

-- 루나 배경 그라데이션 (CSS linear-gradient 160deg = Roblox Rotation 70)
function UI.lunaGradient()
    local l = UI.Luna
    return UI.create("UIGradient", {
        Rotation = 70,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, l.bgTop),
            ColorSequenceKeypoint.new(0.55, l.bgMid),
            ColorSequenceKeypoint.new(1, l.bgBottom),
        }),
    })
end

-- 흰색 반투명 둥근 패널. radius 기본 18, 테두리는 stroke=false로 끈다
function UI.lunaPanel(props, children, radius, withStroke)
    local merged = table.clone(props or {})
    merged.BackgroundColor3 = merged.BackgroundColor3 or UI.Luna.white
    if merged.BackgroundTransparency == nil then
        merged.BackgroundTransparency = UI.LUNA_PANEL_TRANSPARENCY
    end
    local panel = UI.create("Frame", merged, children)
    UI.corner(radius or 18).Parent = panel
    if withStroke ~= false then
        UI.stroke(UI.Luna.white, 1, UI.LUNA_STROKE_TRANSPARENCY).Parent = panel
    end
    return panel
end

-- 원 (아이콘 대신 색 점). ring이면 속이 빈 테두리 원
function UI.dot(size, color, props, ring)
    local merged = table.clone(props or {})
    merged.Size = UDim2.fromOffset(size, size)
    merged.BackgroundColor3 = color
    merged.BackgroundTransparency = if ring then 1 else (merged.BackgroundTransparency or 0)
    local dot = UI.create("Frame", merged, { UI.roundCorner() })
    if ring then
        UI.stroke(color, 2.5, 0).Parent = dot
    end
    return dot
end

-- 체크 표시 (두 막대를 기울여 그린다, 16x16)
function UI.checkMark(color, props)
    local merged = table.clone(props or {})
    merged.Size = UDim2.fromOffset(16, 16)
    merged.BackgroundTransparency = 1
    return UI.create("Frame", merged, {
        UI.create("Frame", {
            Name = "Short",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(5, 10),
            Size = UDim2.fromOffset(7, 3),
            Rotation = 45,
            BackgroundColor3 = color,
        }, { UI.roundCorner() }),
        UI.create("Frame", {
            Name = "Long",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(10, 8),
            Size = UDim2.fromOffset(13, 3),
            Rotation = -50,
            BackgroundColor3 = color,
        }, { UI.roundCorner() }),
    })
end

-- 모노 라벨 (기본 RobotoMono 14). 굵게는 FontFace = UI.MonoBold
function UI.monoLabel(props, children)
    local merged = table.clone(props or {})
    if merged.Font == nil and merged.FontFace == nil then
        merged.Font = UI.Mono
    end
    merged.TextSize = merged.TextSize or 14
    merged.TextColor3 = merged.TextColor3 or UI.Luna.label
    return UI.create("TextLabel", merged, children)
end

-- 버튼 hover: 마우스가 올라오면 배경 투명도만 바꾼다
function UI.hoverTransparency(button, normal, hovered)
    button.MouseEnter:Connect(function()
        button.BackgroundTransparency = hovered
    end)
    button.MouseLeave:Connect(function()
        button.BackgroundTransparency = normal
    end)
end

-- Roblox 상단 바(메뉴, 채팅 버튼) 높이를 가상 좌표로. 위쪽 문구가 상단 바에 가리지 않게 쓴다
function UI.topInset(unit)
    local inset = game:GetService("GuiService"):GetGuiInset()
    return inset.Y / (unit or 1)
end

-- v2 다국어 도우미 ---------------------------------------------------------
-- 글자는 Localizer로만 그린다. msg는 키 문자열 또는 Msg. 언어가 바뀌면 다시 그린다.
-- 숫자처럼 번역하지 않는 글자는 raw로 쓴다(등록을 풀고 Text를 직접 쓴다).
local Localizer = require(script.Parent.Localizer)

function UI.msg(label, msg)
    if msg == nil then
        Localizer.unbind(label)
        label.Text = ""
        return label
    end
    return Localizer.bind(label, msg)
end

function UI.raw(label, text)
    Localizer.unbind(label)
    label.AutoLocalize = false
    label.Text = text
    return label
end

-- TextScaled 글자에 크기 상한과 하한 (영어가 길어도 넘치지 않게)
function UI.scaledText(label, maxSize, minSize)
    label.TextScaled = true
    UI.create("UITextSizeConstraint", {
        MaxTextSize = maxSize,
        MinTextSize = minSize or 10,
        Parent = label,
    })
    return label
end

-- 루나 알약 버튼 (민트 주 버튼 또는 반투명 보조 버튼). 글자는 AutomaticSize X로 늘어난다
function UI.lunaButton(props, primary)
    local merged = table.clone(props or {})
    merged.AutoButtonColor = false
    merged.BackgroundColor3 = merged.BackgroundColor3
        or (if primary then UI.Luna.mint else UI.Luna.white)
    if merged.BackgroundTransparency == nil then
        merged.BackgroundTransparency = if primary then 0 else 0.86
    end
    merged.TextColor3 = merged.TextColor3 or (if primary then UI.Luna.ink else UI.Luna.white)
    merged.FontFace = merged.FontFace or UI.RoundBold
    merged.TextSize = merged.TextSize or 18
    merged.Text = merged.Text or ""
    local button =
        UI.create("TextButton", merged, { UI.roundCorner(), UI.padding({ 0, 0, 16, 16 }) })
    return button
end

-- 버튼 사용 가능 모양 (주 버튼 민트, 꺼지면 흐린 회색)
function UI.setButtonEnabled(button, enabled, primary)
    button.Active = enabled
    button.AutoButtonColor = false
    if enabled then
        button.BackgroundColor3 = if primary then UI.Luna.mint else UI.Luna.white
        button.BackgroundTransparency = if primary then 0 else 0.86
        button.TextColor3 = if primary then UI.Luna.ink else UI.Luna.white
    else
        button.BackgroundColor3 = UI.Luna.white
        button.BackgroundTransparency = 0.92
        button.TextColor3 = UI.Luna.dim
    end
end

return UI
