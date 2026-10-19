--!nonstrict
-- 결과 화면 (승리와 실패 공용). 재도전 버튼은 RequestRestart를 보낸다.
-- 16차(2026-10-19): "함께 한 일" 기여도 표(GameOverInfo.crew), 승리면 "역대 N위" 배지(Records 이벤트로 갱신),
-- 명예의 전당 상위 목록.
-- 18차(2026-10-19, 사용자 결정): 전체는 C안 "루나 소프트"(C_Result.dc.html: 보라-남색 그라데이션, 금색 둥근 명예의 전당,
-- 오늘 배운 것 패널), 왼쪽 열만 A안 "관제실"(A_Result.dc.html: 상태 모노 라벨, 제목 56, 사유, 요약 타일 2x2,
-- CREW LOG 표, 재도전 줄)을 C 색과 둥근 모서리로 옮겼다. 숫자는 RobotoMono, 큰 순위는 Nunito.
-- PC는 Layout 루트(가상 좌표) 안에서 12열 중 왼쪽 7열과 오른쪽 5열을 가운데 정렬한다. 큰 화면은 배율로 커진다.
-- compact(Layout.isCompact)나 좁은 창은 두 열을 세로로 쌓고, compact는 배율 없는 실제 px 공간에서 글자 최소 14를 지킨다.
-- 내용이 화면보다 길면(가로 폰 높이 390) 전체 ScrollingFrame에서 세로 스크롤한다.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.UI)
local FactUI = require(script.Parent.FactUI)
local Layout = require(script.Parent.Layout)
local Ranking = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Ranking"))
local Colors = UI.Colors
local L = UI.Luna

-- 목업 기준 수치 (가상 좌표, 1280x720, 패딩 40/56)
local CANVAS_HEIGHT = 720
local CONTENT_HEIGHT = 640 -- 720 - 위아래 패딩 40
local PAD_Y = 40
local PAD_MIN = 24 -- Roblox 상단 바 때문에 위가 밀리면 아래 패딩을 여기까지 줄인다
local TOPBAR_GAP = 6 -- Roblox 상단 바(GetGuiInset) 아래 최소 여백
local LEFT_WIDTH = 671 -- 12열 그리드(열 간격 24, 내용 폭 1168)의 7열
local RIGHT_WIDTH = 473 -- 5열
local COLUMN_GAP = 24
local INNER_WIDTH = LEFT_WIDTH + COLUMN_GAP + RIGHT_WIDTH
local TWO_COLUMN_MIN_WIDTH = INNER_WIDTH + 32 -- 가상 폭이 이보다 좁으면(좌우 여백 16 미만) 세로로 쌓는다
local STACK_MAX_WIDTH = 720
local STACK_PAD = 16
local BUTTON_WIDTH = 240
local BUTTON_HEIGHT = 60
local BUTTON_GAP = 16 -- 위 내용과 재도전 줄 사이 최소 간격
local NOTE_GAP = 18
local RIGHT_GAP = 16
local PANEL_PAD = 20
local CREW_ROW_HEIGHT = 32
local CREW_HEADER_HEIGHT = 25
local RECORD_ROW_HEIGHT = 34
local COMPACT_RECORD_LINES = 3
local FADE_SECONDS = 0.35
local BUTTON_HOVER_TRANSPARENCY = 0.12
local BACKDROP_TRANSPARENCY = 0.06 -- 게임 화면이 아주 살짝 비친다
local LESSON_DOT_COLORS = { L.sky, L.mint, L.gold }

-- 모드별 크기. pc는 가상 좌표(배율 적용), compact는 실제 px
local SIZES = {
    pc = {
        title = 56,
        reason = 18,
        headerGap = 10,
        sectionGap = 22,
        tilePad = 16,
        tileGap = 14,
        tileValue = 40,
        unit = 18,
        siteValue = 24,
    },
    compact = {
        title = 40,
        reason = 16,
        headerGap = 6,
        sectionGap = 16,
        tilePad = 14,
        tileGap = 12,
        tileValue = 32,
        unit = 16,
        siteValue = 20,
    },
}

local ResultUI = {}

local gui
local restartRemote
local statusLabel
local titleLabel
local reasonLabel
local values: { [string]: TextLabel } = {} -- day, trips, deaths, site
local units = {}
local restartButton
local visible = false
local noteLabel
local restartPressed = false
local restartAvailableAt = nil -- workspace:GetServerTimeNow() 기준, nil이면 즉시 가능
local chooserUserId = nil -- nil이면 누구나 (기존 동작)

local config
local body
local fadeGroup
local root
local scroll
local stage
local leftColumn
local leftUpper
local leftUpperList
local headerList
local tilesGrid
local tilesGridLayout
local tilePaddings = {}
local tileValueRows = {}
local rightColumn
local crewFrame
local crewRows
local hofPanel
local badgePill
local badgeLabel
local recordRows = {}
local recordsEmptyLabel
local recordStatusLabel
local lessonsPanel
local lessonsList
local lessonRows = {}
local lastCompact = nil
local latestRecords = nil -- 마지막 Records 페이로드
local resultWon = false
local rankKnown = false -- 이번 승리의 저장 결과(submitted)를 받았는지
local myRank = nil -- 이번 승리 순위 (상위 밖이면 nil)
local showBadge = false -- 대체 표시(showFromState)는 순위를 모르므로 배지를 숨긴다
-- 저장 결과가 GameOver보다 먼저 도착한 경우(같은 프레임 송신) 잠시 보관했다가 결과 화면에 붙인다
local pendingSubmit = nil
local pendingSubmitAt = 0
local PENDING_SUBMIT_SECONDS = 5

local function currentSizes()
    return if Layout.isCompact() then SIZES.compact else SIZES.pc
end

-- 요약 타일 (A 구조, C 색): 라벨 14 + 값(모노 굵게 + 단위) 또는 착륙지 이름(굵게 24)
local function makeTile(order, labelText, valueColor, unitText)
    local padding = UI.padding({ 16, 16, 20, 20 })
    table.insert(tilePaddings, padding)
    local valueRow
    local valueLabel
    if unitText then
        valueLabel = UI.create("TextLabel", {
            Name = "Number",
            LayoutOrder = 1,
            Size = UDim2.fromScale(0, 1),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = "-",
            FontFace = UI.MonoBold,
            TextSize = 40,
            TextColor3 = valueColor,
            TextYAlignment = Enum.TextYAlignment.Bottom,
        })
        local unitLabel = UI.create("TextLabel", {
            Name = "Unit",
            LayoutOrder = 2,
            Size = UDim2.fromScale(0, 1),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = unitText,
            TextSize = 18,
            TextColor3 = L.label,
            TextYAlignment = Enum.TextYAlignment.Bottom,
        }, { UI.padding({ 0, 4, 0, 0 }) })
        table.insert(units, unitLabel)
        valueRow = UI.create("Frame", {
            Name = "Value",
            LayoutOrder = 2,
            Size = UDim2.new(1, 0, 0, 40),
            BackgroundTransparency = 1,
        }, {
            UI.create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, 6),
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Bottom,
            }),
            valueLabel,
            unitLabel,
        })
    else
        valueLabel = UI.create("TextLabel", {
            Name = "Value",
            LayoutOrder = 2,
            Size = UDim2.new(1, 0, 0, 40),
            Text = "-",
            Font = UI.FontBold,
            TextSize = 24,
            TextColor3 = valueColor,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        })
        valueRow = valueLabel
    end
    table.insert(tileValueRows, valueRow)
    UI.lunaPanel({
        Name = "Tile" .. order,
        LayoutOrder = order,
    }, {
        padding,
        UI.list(Enum.FillDirection.Vertical, 6),
        UI.create("TextLabel", {
            Name = "Label",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 20),
            Text = labelText,
            TextSize = 14,
            TextColor3 = L.label,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        valueRow,
    }, 18).Parent =
        tilesGrid
    return valueLabel
end

-- "오늘 배운 것": 이번 세션에 본 사실 카드 제목(최대 3개), 하나도 없으면 결과별 한 문장(불릿 없이)
local function updateLearned(won)
    local titles = FactUI.seenTitles(3)
    for i, row in ipairs(lessonRows) do
        if #titles == 0 then
            row.frame.Visible = i == 1
            row.bullet.Visible = false
            row.label.Position = UDim2.fromOffset(0, 0)
            row.label.Size = UDim2.fromScale(1, 0)
            row.label.Text = if i == 1 then FactUI.resultText(won) else ""
        else
            local title = titles[i]
            row.frame.Visible = title ~= nil
            row.bullet.Visible = true
            row.label.Position = UDim2.fromOffset(18, 0)
            row.label.Size = UDim2.new(1, -18, 0, 0)
            row.label.Text = title or ""
        end
    end
end

local function setButtonEnabledLook(enabled)
    if enabled then
        restartButton.BackgroundColor3 = L.mint
        restartButton.TextColor3 = L.ink
    else
        restartButton.BackgroundColor3 = Colors.disabled
        restartButton.TextColor3 = L.dim
    end
end

-- 재도전 버튼 상태: 권한자 아님(숨김), 카운트다운(비활성), 가능, 이미 눌림
local function updateRestartButton()
    local t = config.TEXTS
    local localId = Players.LocalPlayer.UserId
    if chooserUserId ~= nil and chooserUserId ~= localId then
        local chooser = Players:GetPlayerByUserId(chooserUserId)
        noteLabel.Text = if chooser
            then string.format(t.restartWaitChooser, chooser.DisplayName)
            else t.restartWaitChooserUnknown
        noteLabel.Visible = true
        restartButton.Visible = false
        return
    end
    -- 권한자에게는 목업처럼 버튼 옆에 안내를 둔다. 권한 개념이 없으면(누구나) 숨긴다
    noteLabel.Text = t.restartChooserHint
    noteLabel.Visible = chooserUserId ~= nil
    restartButton.Visible = true
    if restartPressed then
        return
    end
    local remaining = if restartAvailableAt
        then restartAvailableAt - workspace:GetServerTimeNow()
        else 0
    if remaining > 0 then
        restartButton.Active = false
        setButtonEnabledLook(false)
        restartButton.Text = string.format(t.restartCountdown, math.ceil(remaining))
    else
        restartButton.Active = true
        setButtonEnabledLook(true)
        restartButton.Text = t.restartLabel
    end
end

-- 명예의 전당 머리 오른쪽 알약 배지: "역대 N위!"(금색), 또는 저장 중/상위 밖(흰 반투명). 실패나 대체 표시면 숨김
local function setPill(text, rank)
    badgeLabel.Text = text
    if rank then
        badgePill.BackgroundColor3 = L.gold
        badgePill.BackgroundTransparency = 0
        badgeLabel.FontFace = UI.RoundHeavy
        badgeLabel.TextSize = 16
        badgeLabel.TextColor3 = L.ink
    else
        badgePill.BackgroundColor3 = L.white
        badgePill.BackgroundTransparency = 0.86
        badgeLabel.Font = UI.FontBold
        badgeLabel.TextSize = 14
        badgeLabel.TextColor3 = L.label
    end
    badgePill.Visible = true
end

local function updateBadge()
    if not resultWon or not showBadge then
        badgePill.Visible = false
        return
    end
    local t = config.TEXTS
    if not rankKnown then
        setPill(t.recordSaving, false)
        return
    end
    if myRank then
        setPill(string.format(t.recordRankPill, myRank), true)
        return
    end
    local entries = latestRecords and latestRecords.entries or {}
    local best = entries[1]
    if best then
        setPill(string.format(t.recordOutside, config.RECORDS.maxEntries, best.days), false)
    else
        badgePill.Visible = false
    end
end

-- 명예의 전당 상위 목록 (이번 승리 줄은 금색 바탕 강조). compact는 3줄까지
local function updateRecordsList()
    local t = config.TEXTS
    local payload = latestRecords
    local entries = payload and payload.entries or {}
    local status = payload and payload.status or "loading"
    local limit = if Layout.isCompact()
        then math.min(COMPACT_RECORD_LINES, #recordRows)
        else #recordRows
    for i, row in ipairs(recordRows) do
        local entry = entries[i]
        if entry and i <= limit then
            local mine = rankKnown and myRank == i and showBadge
            row.rank.Text = tostring(i)
            row.days.Text = string.format(t.recordDays, entry.days)
            row.siteCrew.Text =
                string.format(t.recordSiteCrew, entry.site, Ranking.crewText(entry.crew, config))
            row.date.Text = Ranking.dateText(entry.at, config)
            row.frame.BackgroundTransparency = if mine then 0.78 else 1
            row.rank.TextColor3 = if mine then L.gold else L.body
            row.days.TextColor3 = if mine then L.white else L.body
            row.siteCrew.TextColor3 = if mine then L.white else L.body
            row.siteCrew.Font = if mine then UI.FontBold else UI.Font
            row.date.TextColor3 = if mine then L.white else L.label
            row.frame.Visible = true
        else
            row.frame.Visible = false
        end
    end
    recordsEmptyLabel.Text = if status == "loading" then t.recordsLoading else t.recordsEmpty
    recordsEmptyLabel.Visible = #entries == 0
    recordStatusLabel.Text = t.recordsOffline
    recordStatusLabel.Visible = status == "offline"
end

-- 표 한 행. 칸 비율은 목업 grid 2fr + 1fr x n, 칸 간격 8
local CELL_GAP = 8
local function makeCrewRow(order, cells, height, separator)
    local count = #cells
    local parts = count + 1 -- 이름 칸은 2fr
    local gapTotal = CELL_GAP * (count - 1)
    local row = UI.create("Frame", {
        Name = "CrewRow" .. order,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, CELL_GAP),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
    for i, cell in ipairs(cells) do
        local fraction = (if i == 1 then 2 else 1) / parts
        UI.create("TextLabel", {
            Name = "Cell" .. i,
            LayoutOrder = i,
            Size = UDim2.new(fraction, -gapTotal * fraction, 1, if separator then -1 else 0),
            Text = cell.text,
            Font = if cell.mono then UI.Mono else UI.FontBold,
            TextSize = cell.size or 16,
            TextColor3 = cell.color or L.white,
            TextXAlignment = if i == 1 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right,
            TextTruncate = if cell.overflow
                then Enum.TextTruncate.None
                else Enum.TextTruncate.AtEnd,
            Parent = row,
        })
    end
    if separator then
        UI.create("Frame", {
            Name = "Separator",
            AnchorPoint = Vector2.new(0, 1),
            Position = UDim2.fromScale(0, 1),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = L.white,
            BackgroundTransparency = UI.LUNA_STROKE_TRANSPARENCY,
            Parent = row,
        })
    end
    return row
end

-- "함께 한 일" 표 (최대 RECORDS.crewRows명, 산소 고갈 칸은 누군가 0이 아닐 때만)
local function updateCrew(crew)
    for _, row in ipairs(crewRows) do
        row:Destroy()
    end
    crewRows = {}
    crew = crew or {}
    if #crew == 0 then
        crewFrame.Visible = false
        return
    end
    crewFrame.Visible = true
    local t = config.TEXTS
    local showDeaths = false
    for _, c in ipairs(crew) do
        if (c.deaths or 0) > 0 then
            showDeaths = true
        end
    end
    local function tag(text, overflow)
        return { text = text, mono = true, size = 14, color = L.sky, overflow = overflow }
    end
    local header = {
        tag(t.crewLogTitle, true),
        tag(t.crewColPanels),
        tag(t.crewColWater),
        tag(t.crewColBuilds),
        tag(t.crewColRepairs),
    }
    if showDeaths then
        table.insert(header, tag(t.crewColDeaths))
    end
    local headerRow = makeCrewRow(1, header, CREW_HEADER_HEIGHT, false)
    -- 헤더 글자는 위쪽 17px에 두고 아래 8px은 첫 행과의 간격
    for _, child in ipairs(headerRow:GetChildren()) do
        if child:IsA("TextLabel") then
            child.Size = UDim2.new(child.Size.X.Scale, child.Size.X.Offset, 0, 17)
        end
    end
    headerRow.Parent = crewFrame
    table.insert(crewRows, headerRow)
    local shown = math.min(#crew, config.RECORDS.crewRows)
    for i = 1, shown do
        local c = crew[i]
        local cells = {
            { text = c.name },
            { text = tostring(c.panels), mono = true },
            {
                text = string.format(t.crewWaterValue, math.floor((c.water or 0) + 0.5)),
                mono = true,
                color = L.sky,
            },
            { text = tostring(c.builds), mono = true },
            { text = tostring(c.repairs), mono = true },
        }
        if showDeaths then
            table.insert(cells, { text = tostring(c.deaths), mono = true, color = L.orange })
        end
        local row = makeCrewRow(1 + i, cells, CREW_ROW_HEIGHT, i < shown)
        row.Parent = crewFrame
        table.insert(crewRows, row)
    end
end

-- 모드별 글자와 간격
local function applySizes(s)
    titleLabel.TextSize = s.title
    titleLabel.Size = UDim2.new(1, 0, 0, s.title)
    reasonLabel.TextSize = s.reason
    headerList.Padding = UDim.new(0, s.headerGap)
    leftUpperList.Padding = UDim.new(0, s.sectionGap)
    local tileHeight = s.tilePad * 2 + 20 + 6 + s.tileValue
    tilesGrid.Size = UDim2.new(1, 0, 0, tileHeight * 2 + s.tileGap)
    tilesGridLayout.CellSize = UDim2.new(0.5, -s.tileGap / 2, 0, tileHeight)
    tilesGridLayout.CellPadding = UDim2.fromOffset(s.tileGap, s.tileGap)
    for _, padding in ipairs(tilePaddings) do
        padding.PaddingTop = UDim.new(0, s.tilePad)
        padding.PaddingBottom = UDim.new(0, s.tilePad)
    end
    for _, row in ipairs(tileValueRows) do
        row.Size = UDim2.new(1, 0, 0, s.tileValue)
    end
    for _, label in ipairs({ values.day, values.trips, values.deaths }) do
        label.TextSize = s.tileValue
    end
    for _, label in ipairs(units) do
        label.TextSize = s.unit
    end
    values.site.TextSize = s.siteValue
end

-- 배치: 열 크기와 위치, 스크롤 캔버스. 크기 측정은 AbsoluteSize / 단위 배율(가상 좌표)
local function fit()
    if not stage then
        return
    end
    local compact = Layout.isCompact()
    local unit = if compact then 1 else Layout.scale()
    scroll.Parent = if compact then body else root
    local s = currentSizes()
    applySizes(s)
    if compact ~= lastCompact then
        lastCompact = compact
        updateRecordsList()
    end

    local abs = body.AbsoluteSize
    if abs.X <= 0 or abs.Y <= 0 then
        abs = Vector2.new(1280, 720) * unit
    end
    local space = abs / unit
    local stacked = compact or space.X < TWO_COLUMN_MIN_WIDTH
    local insetTop = GuiService:GetGuiInset().Y / unit + TOPBAR_GAP

    local upperHeight = leftUpper.AbsoluteSize.Y / unit
    local hofHeight = hofPanel.AbsoluteSize.Y / unit
    local lessonsHeight = lessonsList.AbsoluteContentSize.Y / unit + PANEL_PAD * 2
    local leftHeight = upperHeight + BUTTON_GAP + BUTTON_HEIGHT
    local rightHeight = hofHeight + RIGHT_GAP + lessonsHeight
    local canvasHeight

    if stacked then
        local width = math.min(STACK_MAX_WIDTH, space.X - STACK_PAD * 2)
        local top = math.max(STACK_PAD, insetTop)
        leftColumn.Position = UDim2.fromOffset(0, 0)
        leftColumn.Size = UDim2.fromOffset(width, leftHeight)
        rightColumn.Position = UDim2.fromOffset(0, leftHeight + s.sectionGap)
        rightColumn.Size = UDim2.fromOffset(width, rightHeight)
        lessonsPanel.Size = UDim2.new(1, 0, 0, lessonsHeight)
        local stageHeight = leftHeight + s.sectionGap + rightHeight
        stage.Position = UDim2.fromOffset(math.floor((space.X - width) / 2), top)
        stage.Size = UDim2.fromOffset(width, stageHeight)
        canvasHeight = top + stageHeight + STACK_PAD
    else
        -- 목업처럼 640 높이 내용 상자를 세로 가운데. 상단 바에 밀리면 아래 패딩을 PAD_MIN까지 줄인다
        local idealTop = (space.Y - CANVAS_HEIGHT) / 2 + PAD_Y
        local top = math.max(idealTop, insetTop, PAD_MIN)
        local bottom = math.max(PAD_MIN, idealTop - (top - idealTop))
        local columnHeight =
            math.max(leftHeight, rightHeight, math.min(CONTENT_HEIGHT, space.Y - top - bottom))
        leftColumn.Position = UDim2.fromOffset(0, 0)
        leftColumn.Size = UDim2.fromOffset(LEFT_WIDTH, columnHeight)
        rightColumn.Position = UDim2.fromOffset(LEFT_WIDTH + COLUMN_GAP, 0)
        rightColumn.Size = UDim2.fromOffset(RIGHT_WIDTH, columnHeight)
        -- 오늘 배운 것은 남은 높이를 채워 아래 끝을 왼쪽 열(재도전 버튼)과 맞춘다
        lessonsPanel.Size = UDim2.new(1, 0, 0, columnHeight - hofHeight - RIGHT_GAP)
        stage.Position = UDim2.fromOffset(math.floor((space.X - INNER_WIDTH) / 2), top)
        stage.Size = UDim2.fromOffset(INNER_WIDTH, columnHeight)
        canvasHeight = top + columnHeight + bottom
    end
    lessonsPanel.Position = UDim2.fromOffset(0, hofHeight + RIGHT_GAP)
    scroll.CanvasSize = UDim2.fromOffset(0, math.ceil(canvasHeight))
end

-- 등장 연출: 0.35초 페이드 인. 연출 동안만 CanvasGroup에 넣고 끝나면 일반 Frame으로 돌려 글자 선명도를 지킨다
local function playFadeIn()
    body.Parent = fadeGroup
    fadeGroup.GroupTransparency = 1
    fadeGroup.Visible = true
    local tween = TweenService:Create(
        fadeGroup,
        TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { GroupTransparency = 0 }
    )
    tween.Completed:Connect(function(state)
        -- 연출 중 다시 열려 새 트윈이 이 트윈을 취소했으면 새 트윈이 정리한다
        if state ~= Enum.PlaybackState.Completed then
            return
        end
        body.Parent = gui
        fadeGroup.Visible = false
    end)
    tween:Play()
end

-- 패널 머리: 색 점(아이콘 대신) + 굵은 제목 17
local function panelHeading(name, order, color, text)
    return UI.create("Frame", {
        Name = name,
        LayoutOrder = order,
        Size = UDim2.fromScale(0, 1),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        UI.dot(12, color, { LayoutOrder = 1 }),
        UI.create("TextLabel", {
            LayoutOrder = 2,
            Size = UDim2.fromScale(0, 1),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = text,
            Font = UI.FontBold,
            TextSize = 17,
            TextColor3 = L.white,
        }),
    })
end

local function buildHallOfFame(t)
    badgeLabel = UI.create("TextLabel", {
        Name = "Text",
        Size = UDim2.fromScale(0, 1),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = "",
        FontFace = UI.RoundHeavy,
        TextSize = 16,
        TextColor3 = L.ink,
    })
    badgePill = UI.create("Frame", {
        Name = "RankBadge",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(0, 30),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = L.gold,
        Visible = false,
    }, { UI.roundCorner(), UI.padding({ 0, 0, 14, 14 }), badgeLabel })
    local headRow = UI.create("Frame", {
        Name = "Head",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
    }, {
        panelHeading("Title", 1, L.gold, t.recordsTitle),
        badgePill,
    })

    -- 상위 목록: 칸 폭은 목업 grid 28px, 52px, 1fr, 52px (간격 8, 행 안쪽 여백 10)
    local list = UI.create("Frame", {
        Name = "Records",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 6) })
    recordRows = {}
    for i = 1, config.RECORDS.showTop do
        local function cell(name, x, width, props)
            local merged = {
                Name = name,
                Position = UDim2.new(x.Scale, x.Offset, 0, 0),
                Size = UDim2.new(width.Scale, width.Offset, 1, 0),
                Text = "",
                TextSize = 15,
                TextColor3 = L.body,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
            }
            for key, value in pairs(props) do
                merged[key] = value
            end
            return UI.create("TextLabel", merged)
        end
        local row = {}
        row.rank = cell("Rank", UDim.new(0, 0), UDim.new(0, 28), { FontFace = UI.RoundHeavy })
        row.days = cell("Days", UDim.new(0, 36), UDim.new(0, 52), { FontFace = UI.RoundBold })
        row.siteCrew = cell("SiteCrew", UDim.new(0, 96), UDim.new(1, -156), { Font = UI.Font })
        row.date = cell("Date", UDim.new(1, -52), UDim.new(0, 52), {
            Font = UI.Font,
            TextXAlignment = Enum.TextXAlignment.Right,
        })
        row.frame = UI.create("Frame", {
            Name = "RecordLine" .. i,
            LayoutOrder = i,
            Size = UDim2.new(1, 0, 0, RECORD_ROW_HEIGHT),
            BackgroundColor3 = L.gold,
            BackgroundTransparency = 1,
            Visible = false,
            Parent = list,
        }, {
            UI.corner(10),
            UI.padding({ 0, 0, 10, 10 }),
            row.rank,
            row.days,
            row.siteCrew,
            row.date,
        })
        table.insert(recordRows, row)
    end
    recordsEmptyLabel = UI.create("TextLabel", {
        Name = "Empty",
        LayoutOrder = 0,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextSize = 15,
        TextColor3 = L.label,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = list,
    })
    recordStatusLabel = UI.create("TextLabel", {
        Name = "RecordsStatus",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = L.label,
        TextSize = 14,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
    })

    hofPanel = UI.create("Frame", {
        Name = "HallOfFame",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = L.gold,
        BackgroundTransparency = 0.86, -- rgba(255,209,102,0.14)
    }, {
        UI.corner(20),
        UI.stroke(L.gold, 1.5, 0.4), -- rgba(255,209,102,0.6)
        UI.padding(PANEL_PAD),
        UI.list(Enum.FillDirection.Vertical, 12),
        headRow,
        list,
        recordStatusLabel,
    })
    return hofPanel
end

local function buildLessons(t)
    lessonsList = UI.list(Enum.FillDirection.Vertical, 12)
    lessonsPanel = UI.lunaPanel({ Name = "Lessons", Size = UDim2.new(1, 0, 0, 160) }, {
        UI.padding(PANEL_PAD),
        lessonsList,
        UI.create("Frame", {
            Name = "Head",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 24),
            BackgroundTransparency = 1,
        }, { panelHeading("Title", 1, L.sky, t.lessonsTitle) }),
    }, 20)
    lessonRows = {}
    for i = 1, 3 do
        local bullet = UI.dot(8, LESSON_DOT_COLORS[i], {
            Name = "Bullet",
            Position = UDim2.fromOffset(0, 7),
        })
        local label = UI.create("TextLabel", {
            Name = "Text",
            Position = UDim2.fromOffset(18, 0),
            Size = UDim2.new(1, -18, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Text = "",
            TextSize = 16,
            LineHeight = 1.3,
            TextColor3 = L.body,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
        })
        local frame = UI.create("Frame", {
            Name = "Lesson" .. i,
            LayoutOrder = 1 + i,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Visible = false,
            Parent = lessonsPanel,
        }, { bullet, label })
        table.insert(lessonRows, { frame = frame, bullet = bullet, label = label })
    end
    return lessonsPanel
end

function ResultUI.init(ctx)
    config = ctx.Config
    local t = config.TEXTS
    restartRemote = ctx.remotes.RequestRestart
    gui = UI.gui("Result", 80)
    gui.Enabled = false

    -- 왼쪽 열 머리 (A): 상태 라벨(모노), 제목, 사유
    statusLabel = UI.monoLabel({
        Name = "Status",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 17),
        Text = "",
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    titleLabel = UI.create("TextLabel", {
        Name = "Title",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 56),
        Text = "",
        Font = UI.FontBold,
        TextSize = 56,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    reasonLabel = UI.create("TextLabel", {
        Name = "Reason",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextSize = 18,
        TextColor3 = L.soft,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    headerList = UI.list(Enum.FillDirection.Vertical, 10)
    local header = UI.create("Frame", {
        Name = "Header",
        LayoutOrder = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { headerList, statusLabel, titleLabel, reasonLabel })

    -- 요약 타일 2x2
    tilesGridLayout = UI.create("UIGridLayout", {
        CellSize = UDim2.new(0.5, -7, 0, 98),
        CellPadding = UDim2.fromOffset(14, 14),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
    tilesGrid = UI.create("Frame", {
        Name = "Summary",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 210),
        BackgroundTransparency = 1,
    }, { tilesGridLayout })
    tilePaddings = {}
    tileValueRows = {}
    units = {}
    values.day = makeTile(1, t.resultDays, L.white, t.unitDay)
    values.trips = makeTile(2, t.resultTrips, L.sky, t.unitCount)
    values.deaths = makeTile(3, t.resultDeaths, L.orange, t.unitCount)
    values.site = makeTile(4, t.resultSite, L.white, nil)

    -- CREW LOG "함께 한 일" 기여도 표 (16차). 순위 표기 없이 기여 합이 큰 순으로 서버가 정렬해 보낸다
    crewRows = {}
    crewFrame = UI.lunaPanel({
        Name = "Crew",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Visible = false,
    }, {
        UI.padding({ 16, 16, 20, 20 }),
        UI.list(Enum.FillDirection.Vertical, 0),
    }, 18)

    leftUpperList = UI.list(Enum.FillDirection.Vertical, 22)
    leftUpper = UI.create("Frame", {
        Name = "Upper",
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { leftUpperList, header, tilesGrid, crewFrame })

    -- 재도전 줄: 민트 둥근 버튼 + 권한 안내. 왼쪽 열 아래 끝에 붙는다
    restartButton = UI.create("TextButton", {
        Name = "RestartButton",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(BUTTON_WIDTH, BUTTON_HEIGHT),
        BackgroundColor3 = L.mint,
        BackgroundTransparency = 0,
        AutoButtonColor = false,
        Text = t.restartLabel,
        Font = UI.FontBold,
        TextSize = 20,
        TextColor3 = L.ink,
    }, { UI.roundCorner() })
    UI.hoverTransparency(restartButton, 0, BUTTON_HOVER_TRANSPARENCY)
    noteLabel = UI.create("TextLabel", {
        Name = "RestartNote",
        LayoutOrder = 2,
        Size = UDim2.new(1, -(BUTTON_WIDTH + NOTE_GAP), 1, 0),
        Text = "",
        TextSize = 14,
        TextColor3 = L.label,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
    })
    local buttonRow = UI.create("Frame", {
        Name = "RestartRow",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.fromScale(0, 1),
        Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
        BackgroundTransparency = 1,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, NOTE_GAP),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        restartButton,
        noteLabel,
    })

    leftColumn = UI.create("Frame", {
        Name = "Left",
        Size = UDim2.fromOffset(LEFT_WIDTH, CONTENT_HEIGHT),
        BackgroundTransparency = 1,
    }, { leftUpper, buttonRow })
    rightColumn = UI.create("Frame", {
        Name = "Right",
        Position = UDim2.fromOffset(LEFT_WIDTH + COLUMN_GAP, 0),
        Size = UDim2.fromOffset(RIGHT_WIDTH, CONTENT_HEIGHT),
        BackgroundTransparency = 1,
    }, { buildHallOfFame(t), buildLessons(t) })

    stage = UI.create("Frame", {
        Name = "Stage",
        Size = UDim2.fromOffset(INNER_WIDTH, CONTENT_HEIGHT),
        BackgroundTransparency = 1,
    }, { leftColumn, rightColumn })
    scroll = UI.create("ScrollingFrame", {
        Name = "Scroll",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 3, -- compact에서 Body 바로 아래로 옮겨도 배경 위에 그린다
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.fromOffset(0, 0),
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = L.label,
        ScrollBarImageTransparency = 0.4,
    }, { stage })

    -- 화면 전체: 루나 그라데이션 배경(게임 화면이 아주 살짝 비침) + 스크롤 내용
    body = UI.create("Frame", {
        Name = "Body",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Parent = gui,
    }, {
        UI.create("Frame", {
            Name = "Backdrop",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = L.white,
            BackgroundTransparency = BACKDROP_TRANSPARENCY,
        }, { UI.lunaGradient() }),
    })
    root = Layout.root(gui)
    root.Parent = body
    root.ZIndex = 2
    scroll.Parent = root
    fadeGroup = UI.create("CanvasGroup", {
        Name = "Fade",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = gui,
    })

    leftUpper:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    hofPanel:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    lessonsList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
    body:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
    Layout.changed:Connect(fit)
    fit()
    updateRecordsList()

    restartButton.Activated:Connect(function()
        if not restartButton.Active then
            return
        end
        restartPressed = true
        restartButton.Active = false
        setButtonEnabledLook(false)
        restartButton.Text = t.restartPending
        restartRemote:FireServer()
    end)

    -- 카운트다운 갱신
    task.spawn(function()
        while true do
            if visible then
                updateRestartButton()
            end
            task.wait(0.25)
        end
    end)
end

-- GameOver 페이로드(GameOverInfo)로 표시
function ResultUI.show(result)
    local t = config.TEXTS
    local won = result.won == true
    statusLabel.Text = if won then t.resultWonTag else t.resultLostTag
    statusLabel.TextColor3 = if won then L.mint else L.red
    titleLabel.Text = if won then t.resultWon else t.resultLost
    reasonLabel.Text = result.reason or ""
    reasonLabel.Visible = (result.reason or "") ~= ""
    values.day.Text = tostring(result.day)
    values.trips.Text = tostring(result.waterTrips)
    values.deaths.Text = tostring(result.oxygenDeaths)
    values.site.Text = result.siteName or "-"

    updateLearned(result.won)
    restartAvailableAt = result.restartAvailableAt
    chooserUserId = result.chooserUserId
    local opening = not visible
    if opening then
        restartPressed = false
        -- 새 결과: 순위는 Records(submitted) 이벤트가 따라온다. 권한자 변경 재송신(같은 결과)은 순위를 유지한다
        rankKnown = false
        myRank = nil
        if pendingSubmit and os.clock() - pendingSubmitAt <= PENDING_SUBMIT_SECONDS then
            rankKnown = true
            myRank = pendingSubmit.rank
        end
        pendingSubmit = nil
    end
    resultWon = won
    showBadge = result.fallback ~= true
    updateCrew(result.crew)
    updateBadge()
    updateRecordsList()
    visible = true
    gui.Enabled = true
    updateRestartButton()
    fit()
    if opening then
        scroll.CanvasPosition = Vector2.new(0, 0)
        playFadeIn()
    end
end

-- Records 수신 (입장 시, 로드 완료, 승리 저장 뒤). submitted면 방금 끝난 승리의 순위
function ResultUI.setRecords(payload)
    if type(payload) ~= "table" or type(payload.entries) ~= "table" then
        return
    end
    latestRecords = payload
    if payload.submitted then
        if visible and resultWon then
            rankKnown = true
            myRank = payload.rank
        elseif not visible then
            pendingSubmit = payload
            pendingSubmitAt = os.clock()
        end
    end
    updateBadge()
    updateRecordsList()
end

-- 늦게 들어온 플레이어용 대체 표시 (GameOver를 놓친 경우)
function ResultUI.showFromState(state)
    ResultUI.show({
        won = state.phase == "won",
        reason = "",
        day = state.day,
        waterTrips = state.waterTrips,
        oxygenDeaths = state.oxygenDeaths,
        siteName = state.siteName or "-",
        fallback = true, -- GameOver를 놓쳐 기여도와 순위를 모른다
    })
end

function ResultUI.hide()
    visible = false
    restartPressed = false
    rankKnown = false
    myRank = nil
    gui.Enabled = false
end

function ResultUI.isVisible()
    return visible
end

return ResultUI
