--!nonstrict
-- v2 미션 선택 화면 (CONTRACT_V2 4.1 MissionSelectOpen, V2_PLAN 15.9 Q23, Q24). v1 SiteSelectUI 지도형 디자인을 옮겼다.
-- 왼쪽: 달 남극 지도(위도 링, 크레이터 음영, 남극점, 지구 쪽 표시, 기지 핀 A ~ D, 핀 옆 "내 최고 메달" 배지).
-- 오른쪽: 미리보기 상세(이름, 착륙지, 상태 배지, 한 줄 설명, 안내)와 4행 목록, 확정 버튼.
-- 누구나 핀이나 행을 눌러 미리보기(잠긴 A, D도 설명은 읽을 수 있다). 확정은 고르는 사람만, playable 미션만(SelectMission).
-- 30초 자동 선택 카운트다운은 payload.deadline(서버 시각). 기본 미리보기는 defaultMissionId(C).
-- 지도는 단순화한 그림이다: 방향(경도 쪽)은 지키되 서로 가까운 B와 C를 읽기 쉽게 벌렸다(지도 아래 안내 문구).
-- 좁은 화면과 compact는 지도를 숨기고 상세와 목록을 세로로 쌓아 스크롤한다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))

local Layout = require(script.Parent.Layout)
local Net = require(script.Parent.Net)
local UI = require(script.Parent.UI)
local L = UI.Luna

local MissionSelectUI = {}

local CONTENT_WIDTH = 1168
local MAP_WIDTH = 640
local MAP_HEIGHT = 540
local MAP_CANVAS = Vector2.new(600, 500)
local MAP_CENTER = Vector2.new(300, 250)
local PX_PER_DEGREE = 32 -- 극에서 위도 1도당 픽셀
local RINGS = { 84, 86, 88 }
local CRATERS = { -- 지도 그림 안 좌상단, 크기, 투명도
    { 250, 220, 80, 68, 0.45 },
    { 120, 330, 120, 96, 0.55 },
    { 400, 100, 96, 80, 0.55 },
    { 430, 320, 140, 110, 0.55 },
    { 90, 120, 70, 56, 0.65 },
}
local SIDE_GAP = 14
local BODY_GAP = 24
local WIDE_MIN_WIDTH = MAP_WIDTH + 360 + BODY_GAP + 32
local PIN_SMALL = 36
local PIN_BIG = 46
local PIN_GLOW = 64
local ROW_HEIGHT = 52
local PAD = 16
local CONFIRM_RETRY_SECONDS = 4

-- 미션 표시 정보 (리터럴 키). 지도 위치는 극에서 거리(도)와 방향(도, 위 = 경도 0 = 지구 쪽, 시계 방향 = 동경)
local MISSIONS = {
    {
        id = "A",
        name = "mission.a.name",
        site = "mission.a.site",
        desc = "mission.a.desc",
        r = 4.0,
        angle = -5,
    },
    {
        id = "B",
        name = "mission.b.name",
        site = "mission.b.site",
        desc = "mission.b.desc",
        r = 3.0,
        angle = 25,
    },
    {
        id = "C",
        name = "mission.c.name",
        site = "mission.c.site",
        desc = "mission.c.desc",
        r = 4.7,
        angle = 75,
    },
    {
        id = "D",
        name = "mission.d.name",
        site = "mission.d.site",
        desc = "mission.d.desc",
        r = 6.6,
        angle = -55,
    },
}
local DEFAULT_STATES = { A = "locked", B = "soon", C = "playable", D = "locked" }
local STATUS_KEYS = {
    playable = "mission_select.status.play",
    soon = "mission_select.status.coming_soon",
    locked = "mission_select.status.locked",
}
local HINT_KEYS = { soon = "mission_select.soon_hint", locked = "mission_select.locked_hint" }
local MEDAL_KEYS =
    { gold = "medal.gold.name", silver = "medal.silver.name", bronze = "medal.bronze.name" }
local MEDAL_COLORS = {
    gold = Color3.fromRGB(255, 209, 102),
    silver = Color3.fromRGB(205, 214, 235),
    bronze = Color3.fromRGB(222, 150, 96),
}

local gui
local root
local scroll
local stage
local header
local titleLabel
local subtitleLabel
local chooserLabel
local countdownFill
local countdownLabel
local body
local bodyLayout
local mapPanel
local mapCanvas
local side
local detail
local detailLetter
local detailName
local detailSite
local detailStatus
local detailStatusLabel
local detailDesc
local detailMedal
local detailMedalLabel
local detailHint
local recommendBadge
local confirmButton
local listPanel

local info = nil
local openedAt = 0
local states = table.clone(DEFAULT_STATES)
local bestMedals = {}
local previewId = "C"
local chosen = false
local pins = {} -- [id] = { holder, glow, circle, stroke, letter, label, medal }
local rows = {} -- [id] = { button, bar, letter, name, tag, medal }
local countdownConn = nil

local function missionById(id)
    for _, m in ipairs(MISSIONS) do
        if m.id == id then
            return m
        end
    end
    return nil
end

local function isChooser()
    return info ~= nil and info.chooserUserId == Players.LocalPlayer.UserId
end

local function pinPosition(m)
    local rad = math.rad(m.angle)
    local radius = m.r * PX_PER_DEGREE
    return Vector2.new(MAP_CENTER.X + radius * math.sin(rad), MAP_CENTER.Y - radius * math.cos(rad))
end

local function statusColor(state)
    if state == "playable" then
        return L.mint
    elseif state == "soon" then
        return L.gold
    end
    return L.faint
end

local function refresh()
    local m = missionById(previewId) or MISSIONS[3]
    local state = states[m.id] or "locked"
    UI.raw(detailLetter, m.id)
    detailLetter.Parent.BackgroundColor3 = statusColor(state)
    UI.msg(detailName, m.name)
    UI.msg(detailSite, m.site)
    UI.msg(detailDesc, m.desc)
    UI.msg(detailStatusLabel, STATUS_KEYS[state])
    detailStatus.BackgroundColor3 = statusColor(state)
    recommendBadge.Visible = info ~= nil
        and m.id == (info.defaultMissionId or "C")
        and state == "playable"
    local hintKey = HINT_KEYS[state]
    detailHint.Visible = hintKey ~= nil
    if hintKey then
        UI.msg(detailHint, hintKey)
    end
    local medal = bestMedals[m.id]
    detailMedal.Visible = MEDAL_KEYS[medal] ~= nil
    if detailMedal.Visible then
        UI.msg(
            detailMedalLabel,
            { key = "mission_select.best_medal", args = { medal = { key = MEDAL_KEYS[medal] } } }
        )
        detailMedal.BackgroundColor3 = MEDAL_COLORS[medal]
    end

    local canConfirm = isChooser() and not chosen and state == "playable"
    UI.setButtonEnabled(confirmButton, canConfirm, true)
    if chosen then
        UI.msg(confirmButton, "mission_select.chosen")
    elseif isChooser() then
        UI.msg(confirmButton, "mission_select.confirm")
    else
        UI.msg(confirmButton, "mission_select.wait")
    end

    for id, pin in pairs(pins) do
        local selected = id == previewId
        local pinState = states[id] or "locked"
        local size = if selected then PIN_BIG else PIN_SMALL
        pin.glow.Visible = selected
        pin.circle.Size = UDim2.fromOffset(size, size)
        pin.circle.BackgroundColor3 = if selected then statusColor(pinState) else L.pin
        pin.circle.BackgroundTransparency = if pinState == "locked" and not selected then 0.4 else 0
        pin.stroke.Color = if selected then L.white else statusColor(pinState)
        pin.letter.TextColor3 = if selected then L.inkDeep else L.white
        pin.letter.TextTransparency = if pinState == "locked" and not selected then 0.35 else 0
        pin.label.TextColor3 = if selected
            then L.white
            elseif pinState == "locked" then L.faint
            else L.label
        local medalKey = bestMedals[id]
        pin.medal.Visible = MEDAL_COLORS[medalKey] ~= nil
        if pin.medal.Visible then
            pin.medal.BackgroundColor3 = MEDAL_COLORS[medalKey]
        end
    end
    for id, row in pairs(rows) do
        local selected = id == previewId
        local rowState = states[id] or "locked"
        row.button.BackgroundColor3 = if selected then L.mint else L.white
        row.button.BackgroundTransparency = if selected then 0.86 else 1
        row.bar.Visible = selected
        row.letter.TextColor3 = if selected
            then L.mint
            elseif rowState == "locked" then L.faint
            else L.label
        row.name.TextColor3 = if rowState == "locked" then L.dim else L.white
        UI.msg(row.tag, STATUS_KEYS[rowState])
        row.tag.TextColor3 = statusColor(rowState)
        local medalKey = bestMedals[id]
        row.medal.Visible = MEDAL_COLORS[medalKey] ~= nil
        if row.medal.Visible then
            row.medal.BackgroundColor3 = MEDAL_COLORS[medalKey]
        end
    end
end

local function setPreview(id)
    if missionById(id) then
        previewId = id
        refresh()
    end
end

local function updateCountdown()
    if not info then
        return
    end
    local hasDeadline = type(info.deadline) == "number"
    countdownLabel.Visible = hasDeadline
    countdownFill.Parent.Visible = hasDeadline
    if not hasDeadline then
        return
    end
    local now = workspace:GetServerTimeNow()
    local left = ClientMath.secondsLeft(info.deadline, now)
    local total = math.max(1, info.deadline - openedAt)
    countdownFill.Size = UDim2.fromScale(ClientMath.ratio(info.deadline - now, total), 1)
    local defaultMission = missionById(info.defaultMissionId or "C") or MISSIONS[3]
    UI.msg(countdownLabel, {
        key = "mission_select.auto_pick",
        args = { count = left, mission = { key = defaultMission.name } },
    })
end

local function updateChooser()
    if not info then
        UI.msg(chooserLabel, "mission_select.wait")
        return
    end
    if isChooser() then
        UI.msg(chooserLabel, "mission_select.you_pick")
    else
        UI.msg(
            chooserLabel,
            { key = "mission_select.chooser", args = { name = tostring(info.chooserName or "") } }
        )
    end
end

local function buildPin(m)
    local p = pinPosition(m)
    local glow = UI.create("Frame", {
        Name = "Glow",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PIN_GLOW, PIN_GLOW),
        BackgroundColor3 = L.mint,
        BackgroundTransparency = 0.75,
        Visible = false,
    }, { UI.roundCorner() })
    local stroke = UI.stroke(L.label, 2.5, 0)
    local letter = UI.create("TextLabel", {
        Name = "Letter",
        Size = UDim2.fromScale(1, 1),
        FontFace = UI.RoundHeavy,
        TextSize = 18,
        TextColor3 = L.white,
    })
    UI.raw(letter, m.id)
    local circle = UI.create("Frame", {
        Name = "Circle",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PIN_SMALL, PIN_SMALL),
        BackgroundColor3 = L.pin,
    }, { UI.roundCorner(), stroke, letter })
    local medal = UI.create("Frame", {
        Name = "Medal",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, PIN_SMALL / 2, 0.5, -PIN_SMALL / 2),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = L.gold,
        Visible = false,
        ZIndex = 3,
    }, { UI.roundCorner(), UI.stroke(L.inkDeep, 2, 0) })
    local holder = UI.create("TextButton", {
        Name = "Pin" .. m.id,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromOffset(p.X, p.Y),
        Size = UDim2.fromOffset(PIN_GLOW, PIN_GLOW),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        ZIndex = 5,
        Parent = mapCanvas,
    }, { glow, circle, medal })
    local label = UI.create("TextButton", {
        Name = "PinLabel" .. m.id,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.fromOffset(p.X, p.Y + PIN_BIG / 2 + 4),
        Size = UDim2.fromOffset(0, 18),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Font = UI.FontBold,
        TextSize = 14,
        TextColor3 = L.label,
        ZIndex = 5,
        Parent = mapCanvas,
    })
    UI.msg(label, m.site)
    holder.Activated:Connect(function()
        setPreview(m.id)
    end)
    label.Activated:Connect(function()
        setPreview(m.id)
    end)
    pins[m.id] = {
        holder = holder,
        glow = glow,
        circle = circle,
        stroke = stroke,
        letter = letter,
        label = label,
        medal = medal,
    }
end

local function buildMap()
    mapCanvas = UI.create("Frame", {
        Name = "Canvas",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 6),
        Size = UDim2.fromOffset(MAP_CANVAS.X, MAP_CANVAS.Y),
        BackgroundTransparency = 1,
    })
    for _, crater in ipairs(CRATERS) do
        UI.create("Frame", {
            Name = "Crater",
            Position = UDim2.fromOffset(crater[1], crater[2]),
            Size = UDim2.fromOffset(crater[3], crater[4]),
            BackgroundColor3 = L.crater,
            BackgroundTransparency = crater[5],
            ZIndex = 1,
            Parent = mapCanvas,
        }, { UI.roundCorner() })
    end
    for _, lat in ipairs(RINGS) do
        local radius = (90 - lat) * PX_PER_DEGREE
        UI.create("Frame", {
            Name = "Ring" .. lat,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(MAP_CENTER.X, MAP_CENTER.Y),
            Size = UDim2.fromOffset(radius * 2, radius * 2),
            BackgroundTransparency = 1,
            ZIndex = 2,
            Parent = mapCanvas,
        }, { UI.roundCorner(), UI.stroke(L.dim, 1.5, 0.65) })
        local ringLabel = UI.create("TextLabel", {
            Name = "Lat" .. lat,
            Position = UDim2.fromOffset(
                MAP_CENTER.X + radius * 0.71 + 4,
                MAP_CENTER.Y + radius * 0.71 - 4
            ),
            Size = UDim2.fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.RoundBold,
            TextSize = 13,
            TextColor3 = L.faint,
            ZIndex = 3,
            Parent = mapCanvas,
        })
        UI.msg(ringLabel, { key = "mission_select.latitude", args = { lat = lat } })
    end
    UI.dot(8, L.white, {
        Name = "Pole",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromOffset(MAP_CENTER.X, MAP_CENTER.Y),
        ZIndex = 3,
        Parent = mapCanvas,
    })
    local poleLabel = UI.create("TextLabel", {
        Name = "PoleLabel",
        Position = UDim2.fromOffset(MAP_CENTER.X + 8, MAP_CENTER.Y + 2),
        Size = UDim2.fromOffset(0, 16),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundBold,
        TextSize = 13,
        TextColor3 = L.white,
        ZIndex = 3,
        Parent = mapCanvas,
    })
    UI.msg(poleLabel, "mission_select.pole")
    for _, m in ipairs(MISSIONS) do
        buildPin(m)
    end

    local mapTitle = UI.create("TextLabel", {
        Name = "MapTitle",
        Position = UDim2.fromOffset(20, 14),
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.label,
        ZIndex = 7,
    })
    UI.msg(mapTitle, "mission_select.map_title")
    local earth = UI.create("TextLabel", {
        Name = "Earth",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 14),
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.9,
        Font = UI.FontBold,
        TextSize = 13,
        TextColor3 = L.faint,
        ZIndex = 7,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 10, 10 }) })
    UI.msg(earth, "mission_select.earth")
    local note = UI.create("TextLabel", {
        Name = "Note",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 20, 1, -12),
        Size = UDim2.new(1, -40, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = 13,
        TextColor3 = L.faint,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7,
    })
    UI.msg(note, "mission_select.map_note")

    mapPanel = UI.lunaPanel({
        Name = "Map",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(MAP_WIDTH, MAP_HEIGHT),
        BackgroundTransparency = 0.92,
        ClipsDescendants = true,
    }, { mapCanvas, mapTitle, earth, note })
    return mapPanel
end

local function buildDetail()
    detailLetter = UI.create("TextLabel", {
        Name = "Letter",
        Size = UDim2.fromScale(1, 1),
        FontFace = UI.RoundHeavy,
        TextSize = 22,
        TextColor3 = L.inkDeep,
    })
    local letterDot = UI.create("Frame", {
        Name = "LetterDot",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(40, 40),
        BackgroundColor3 = L.mint,
    }, { UI.roundCorner(), detailLetter })
    detailName = UI.create("TextLabel", {
        Name = "Name",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.RoundHeavy,
        TextSize = 26,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    detailSite = UI.create("TextLabel", {
        Name = "Site",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.MonoBold,
        TextSize = 14,
        TextColor3 = L.sky,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local titles = UI.create("Frame", {
        Name = "Titles",
        LayoutOrder = 2,
        Size = UDim2.new(1, -52, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 2), detailName, detailSite })
    local top = UI.create("Frame", {
        Name = "Top",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 12),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        letterDot,
        titles,
    })

    local function badge(name, order, color)
        local label = UI.create("TextLabel", {
            Name = "Text",
            Size = UDim2.fromOffset(0, 26),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.RoundHeavy,
            TextSize = 14,
            TextColor3 = L.inkDeep,
        })
        local frame = UI.create("Frame", {
            Name = name,
            LayoutOrder = order,
            Size = UDim2.fromOffset(0, 26),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = color,
        }, { UI.roundCorner(), UI.padding({ 0, 0, 12, 12 }), label })
        return frame, label
    end
    detailStatus, detailStatusLabel = badge("Status", 1, L.mint)
    local recommendLabel
    recommendBadge, recommendLabel = badge("Recommended", 2, L.sky)
    UI.msg(recommendLabel, "mission_select.recommended")
    detailMedal, detailMedalLabel = badge("BestMedal", 3, L.gold)
    local badges = UI.create("Frame", {
        Name = "Badges",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Wraps = true,
        }),
        detailStatus,
        recommendBadge,
        detailMedal,
    })
    detailDesc = UI.create("TextLabel", {
        Name = "Desc",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = 16,
        LineHeight = 1.15,
        TextColor3 = L.body,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    detailHint = UI.create("TextLabel", {
        Name = "Hint",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.gold,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    confirmButton = UI.lunaButton({
        Name = "Confirm",
        LayoutOrder = 5,
        Size = UDim2.new(1, 0, 0, 56),
        TextSize = 20,
    }, true)
    confirmButton.Activated:Connect(function()
        if not confirmButton.Active or chosen then
            return
        end
        chosen = Net.fire("SelectMission", previewId)
        refresh()
        -- 서버가 받지 않으면(이미 넘어갔거나 거절) 잠시 뒤 다시 누를 수 있게 푼다
        task.delay(CONFIRM_RETRY_SECONDS, function()
            if chosen and gui.Enabled then
                chosen = false
                refresh()
            end
        end)
    end)

    detail = UI.lunaPanel({
        Name = "Detail",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
    }, {
        UI.padding(20),
        UI.list(Enum.FillDirection.Vertical, 12),
        top,
        badges,
        detailDesc,
        detailHint,
        confirmButton,
    })
    return detail
end

local function buildRow(m, order)
    local row = {}
    row.bar = UI.create("Frame", {
        Name = "Bar",
        Size = UDim2.new(0, 4, 1, 0),
        BackgroundColor3 = L.mint,
        Visible = false,
    })
    row.letter = UI.create("TextLabel", {
        Name = "Letter",
        Position = UDim2.fromOffset(16, 0),
        Size = UDim2.new(0, 24, 1, 0),
        FontFace = UI.RoundHeavy,
        TextSize = 17,
        TextColor3 = L.label,
    })
    UI.raw(row.letter, m.id)
    row.name = UI.create("TextLabel", {
        Name = "Name",
        Position = UDim2.fromOffset(48, 6),
        Size = UDim2.new(1, -190, 0, 22),
        Font = UI.FontBold,
        TextSize = 16,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    UI.msg(row.name, m.name)
    local site = UI.create("TextLabel", {
        Name = "Site",
        Position = UDim2.fromOffset(48, 28),
        Size = UDim2.new(1, -190, 0, 18),
        Font = UI.Mono,
        TextSize = 13,
        TextColor3 = L.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    UI.msg(site, m.site)
    row.tag = UI.create("TextLabel", {
        Name = "Tag",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -40, 0.5, 0),
        Size = UDim2.fromOffset(110, 22),
        FontFace = UI.RoundBold,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    UI.scaledText(row.tag, 14, 10)
    row.medal = UI.create("Frame", {
        Name = "Medal",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = L.gold,
        Visible = false,
    }, { UI.roundCorner() })
    row.button = UI.create("TextButton", {
        Name = "Row" .. m.id,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        Parent = listPanel,
    }, { row.bar, row.letter, row.name, site, row.tag, row.medal })
    row.button.Activated:Connect(function()
        setPreview(m.id)
    end)
    rows[m.id] = row
end

local function fit()
    if not stage then
        return
    end
    local compact = Layout.isCompact()
    local scale = Layout.scale()
    local abs = gui.AbsoluteSize
    if abs.X <= 0 or abs.Y <= 0 then
        abs = Vector2.new(1280, 720) * scale
    end
    local space = abs / scale
    local stacked = compact or space.X < WIDE_MIN_WIDTH
    local width = math.min(CONTENT_WIDTH, space.X - PAD * 2)
    titleLabel.TextSize = if compact then 24 else 34
    subtitleLabel.Visible = not compact
    mapPanel.Visible = not stacked
    if stacked then
        width = math.min(640, width)
        bodyLayout.FillDirection = Enum.FillDirection.Vertical
        side.Size = UDim2.fromOffset(width, 0)
    else
        bodyLayout.FillDirection = Enum.FillDirection.Horizontal
        local sideWidth = width - MAP_WIDTH - BODY_GAP
        side.Size = UDim2.fromOffset(sideWidth, 0)
        mapPanel.Size = UDim2.fromOffset(MAP_WIDTH, math.max(MAP_HEIGHT, 0))
    end
    stage.Size = UDim2.fromOffset(width, 0)
    header.Size = UDim2.fromOffset(width, 0)
end

local function buildHeader()
    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        FontFace = UI.RoundHeavy,
        TextSize = 34,
        TextColor3 = L.white,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(titleLabel, "mission_select.title")
    subtitleLabel = UI.create("TextLabel", {
        Name = "Subtitle",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Font = UI.Font,
        TextSize = 15,
        TextColor3 = L.dim,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    UI.msg(subtitleLabel, "mission_select.subtitle")
    chooserLabel = UI.create("TextLabel", {
        Name = "Chooser",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.label,
    })
    countdownFill = UI.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.mint,
    }, { UI.corner(2) })
    countdownLabel = UI.create("TextLabel", {
        Name = "Countdown",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, 24),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.Font,
        TextSize = 14,
        TextColor3 = L.dim,
    })
    local status = UI.create("Frame", {
        Name = "Status",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 12),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Wraps = true,
        }),
        chooserLabel,
        UI.create("Frame", {
            Name = "Bar",
            LayoutOrder = 2,
            Size = UDim2.fromOffset(140, 4),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.88,
        }, { UI.corner(2), countdownFill }),
        countdownLabel,
    })
    header = UI.create("Frame", {
        Name = "Header",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(CONTENT_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 6), titleLabel, subtitleLabel, status })
    return header
end

function MissionSelectUI.init(_ctx)
    gui = UI.gui("MissionSelect", 95)
    gui.Enabled = false
    local backdrop = UI.create("Frame", {
        Name = "Backdrop",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.white,
        Parent = gui,
    }, { UI.lunaGradient() })
    root = Layout.root(gui)
    root.Parent = backdrop

    scroll = UI.create("ScrollingFrame", {
        Name = "Scroll",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 6,
        ScrollBarImageColor3 = L.dim,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Parent = root,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        UI.padding({ math.floor(UI.topInset() + 12), PAD, PAD, PAD }),
    })

    listPanel = UI.lunaPanel({
        Name = "List",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        ClipsDescendants = true,
    }, { UI.list(Enum.FillDirection.Vertical, 0) })
    side = UI.create("Frame", {
        Name = "Side",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(480, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, SIDE_GAP), buildDetail(), listPanel })
    for i, m in ipairs(MISSIONS) do
        buildRow(m, i)
    end

    bodyLayout = UI.create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, BODY_GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
    })
    body = UI.create("Frame", {
        Name = "Body",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { bodyLayout, buildMap(), side })

    stage = UI.create("Frame", {
        Name = "Stage",
        Size = UDim2.fromOffset(CONTENT_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = scroll,
    }, { UI.list(Enum.FillDirection.Vertical, 20), buildHeader(), body })

    updateChooser()
    refresh()
    fit()
    Layout.changed:Connect(fit)
    gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
end

-- MissionSelectOpen 페이로드 (CONTRACT_V2 4.1 + bestMedals 요청)
function MissionSelectUI.open(payload)
    if type(payload) ~= "table" then
        return
    end
    info = payload
    openedAt = workspace:GetServerTimeNow()
    chosen = false
    states = table.clone(DEFAULT_STATES)
    for _, entry in ipairs(payload.missions or {}) do
        if type(entry) == "table" and type(entry.id) == "string" then
            states[entry.id] = entry.state
        end
    end
    bestMedals = if type(payload.bestMedals) == "table" then payload.bestMedals else {}
    previewId = if missionById(payload.defaultMissionId) then payload.defaultMissionId else "C"
    updateChooser()
    updateCountdown()
    refresh()
end

function MissionSelectUI.setVisible(visible)
    if not gui then
        return
    end
    gui.Enabled = visible
    if visible then
        fit()
        if not countdownConn then
            countdownConn = RunService.Heartbeat:Connect(updateCountdown)
        end
    elseif countdownConn then
        countdownConn:Disconnect()
        countdownConn = nil
    end
end

return MissionSelectUI
