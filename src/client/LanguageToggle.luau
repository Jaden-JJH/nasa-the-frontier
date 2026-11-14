--!nonstrict
-- EN | KR 언어 전환 토글 (v2 다국어, docs/I18N_PLAN.md 5절 3단계). 타이틀 화면과 설정에 넣을 작은 부품이다.
-- LanguageToggle.create(parent) -> Frame. 루나 소프트 팔레트의 둥근 반투명 틀 안에 두 칸, 고른 칸은 민트 바탕.
-- 누르면 Localizer.set(code). 다른 곳에서 언어가 바뀌어도(서버 복제, 다른 토글) Localizer.changed로 따라간다.
-- 칸 글자(EN, KR)는 CSV settings.language.*_short 키라 두 언어에서 같다. 아직 기존 화면에는 연결하지 않았다.

local Localizer = require(script.Parent.Localizer)
local UI = require(script.Parent.UI)

local LanguageToggle = {}

local SEGMENT_WIDTH = 48
local HEIGHT = 32
local INSET = 3
local TEXT_SIZE = 15

local OPTIONS = {
    { code = "en", key = "settings.language.en_short" },
    { code = "ko", key = "settings.language.ko_short" },
}

function LanguageToggle.create(parent)
    local luna = UI.Luna
    local frame = UI.lunaPanel({
        Name = "LanguageToggle",
        Size = UDim2.fromOffset(SEGMENT_WIDTH * #OPTIONS + INSET * 2, HEIGHT),
    }, {
        UI.padding(INSET),
        UI.list(Enum.FillDirection.Horizontal, 0, Enum.HorizontalAlignment.Center),
    }, HEIGHT / 2)

    local buttons = {}
    for index, option in OPTIONS do
        local button = UI.create("TextButton", {
            Name = option.code,
            LayoutOrder = index,
            Size = UDim2.new(0, SEGMENT_WIDTH, 1, 0),
            AutoButtonColor = false,
            BackgroundColor3 = luna.mint,
            BackgroundTransparency = 1,
            FontFace = UI.RoundHeavy,
            TextSize = TEXT_SIZE,
            TextColor3 = luna.dim,
            Parent = frame,
        }, { UI.corner((HEIGHT - INSET * 2) / 2) })
        Localizer.bind(button, { key = option.key })
        button.Activated:Connect(function()
            Localizer.set(option.code)
        end)
        buttons[option.code] = button
    end

    local function refresh(lang)
        for code, button in buttons do
            local selected = code == lang
            button.BackgroundTransparency = if selected then 0 else 1
            button.TextColor3 = if selected then luna.ink else luna.dim
        end
    end
    refresh(Localizer.get())

    local connection = Localizer.changed:Connect(refresh)
    frame.Destroying:Connect(function()
        connection:Disconnect()
    end)

    frame.Parent = parent
    return frame
end

return LanguageToggle
