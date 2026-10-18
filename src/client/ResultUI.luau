--!nonstrict
-- 결과 화면 (승리와 실패 공용). 재도전 버튼은 RequestRestart를 보낸다.
-- 16차(2026-10-19): 요약 아래 "함께 한 일" 기여도 표(GameOverInfo.crew), 승리면 "역대 N위" 배지(Records 이벤트로 갱신),
-- 명예의 전당 상위 목록. 카드가 화면보다 길면(가로 폰 높이 390) 카드 안에서 세로 스크롤한다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(script.Parent.UI)
local FactUI = require(script.Parent.FactUI)
local Layout = require(script.Parent.Layout)
local Ranking = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Ranking"))
local Colors = UI.Colors

local CARD_WIDTH = 460
local CARD_MARGIN = 12 -- 화면 가장자리와 카드 사이 최소 여백
local CREW_TEXT_SIZE = 14
local RECORD_TEXT_SIZE = 14

local ResultUI = {}

local gui
local restartRemote
local titleLabel
local reasonLabel
local values = {}
local restartButton
local visible = false
local noteLabel
local learnedLabel
local restartPressed = false
local restartAvailableAt = nil -- workspace:GetServerTimeNow() 기준, nil이면 즉시 가능
local chooserUserId = nil -- nil이면 누구나 (기존 동작)

local config
local card
local cardList
local cardPadding
local badgeLabel
local crewFrame
local crewRows
local recordsFrame
local recordLines = {}
local recordStatusLabel
local latestRecords = nil -- 마지막 Records 페이로드
local resultWon = false
local rankKnown = false -- 이번 승리의 저장 결과(submitted)를 받았는지
local myRank = nil -- 이번 승리 순위 (상위 밖이면 nil)
local showBadge = false -- 대체 표시(showFromState)는 순위를 모르므로 배지를 숨긴다
-- 저장 결과가 GameOver보다 먼저 도착한 경우(같은 프레임 송신) 잠시 보관했다가 결과 화면에 붙인다
local pendingSubmit = nil
local pendingSubmitAt = 0
local PENDING_SUBMIT_SECONDS = 5

local function makeRow(parent, order, labelText)
    local value = UI.create("TextLabel", {
        Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromScale(0.5, 1),
        Text = "-",
        Preset = "heading",
        TextXAlignment = Enum.TextXAlignment.Right,
    })
    UI.create("Frame", {
        Name = labelText,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
        Parent = parent,
    }, {
        UI.create("TextLabel", {
            Size = UDim2.fromScale(0.5, 1),
            Text = labelText,
            TextColor3 = Colors.textDim,
            Preset = "body",
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        value,
    })
    return value
end

-- "오늘 배운 것": 이번 세션에 본 사실 카드 제목(최대 3개), 하나도 없으면 결과별 한 문장
local function updateLearned(won)
    local titles = FactUI.seenTitles(3)
    if #titles == 0 then
        learnedLabel.Text = FactUI.resultText(won)
        return
    end
    local lines = {}
    for _, title in ipairs(titles) do
        table.insert(lines, "- " .. title)
    end
    learnedLabel.Text = table.concat(lines, "\n")
end

-- 재도전 버튼 상태: 권한자 아님(숨김), 카운트다운(비활성), 가능, 이미 눌림
local function updateRestartButton()
    local localId = Players.LocalPlayer.UserId
    if chooserUserId ~= nil and chooserUserId ~= localId then
        local chooser = Players:GetPlayerByUserId(chooserUserId)
        noteLabel.Text = if chooser
            then string.format(
                "선택 권한자(%s)가 재도전을 결정합니다",
                chooser.DisplayName
            )
            else "선택 권한자가 재도전을 결정합니다"
        noteLabel.Visible = true
        restartButton.Visible = false
        return
    end
    noteLabel.Visible = false
    restartButton.Visible = true
    if restartPressed then
        return
    end
    local remaining = if restartAvailableAt
        then restartAvailableAt - workspace:GetServerTimeNow()
        else 0
    if remaining > 0 then
        restartButton.Active = false
        restartButton.BackgroundColor3 = Colors.disabled
        restartButton.Text = string.format("재도전 %d초 후", math.ceil(remaining))
    else
        restartButton.Active = true
        restartButton.BackgroundColor3 = Colors.accent
        restartButton.Text = "재도전"
    end
end

-- "역대 N위" 배지: 저장 중, 순위, 상위 밖. 실패나 대체 표시면 숨김
local function updateBadge()
    if not resultWon or not showBadge then
        badgeLabel.Visible = false
        return
    end
    local t = config.TEXTS
    badgeLabel.Visible = true
    if not rankKnown then
        badgeLabel.Text = t.recordSaving
        badgeLabel.TextColor3 = Colors.textDim
        return
    end
    if myRank then
        badgeLabel.Text = string.format(t.recordRank, myRank)
        badgeLabel.TextColor3 = Colors.energy
        return
    end
    local entries = latestRecords and latestRecords.entries or {}
    local best = entries[1]
    if best then
        badgeLabel.Text = string.format(t.recordOutside, config.RECORDS.maxEntries, best.days)
        badgeLabel.TextColor3 = Colors.textDim
    else
        badgeLabel.Visible = false
    end
end

-- 명예의 전당 상위 목록 (이번 승리 줄은 노랑)
local function updateRecordsList()
    local t = config.TEXTS
    local payload = latestRecords
    local entries = payload and payload.entries or {}
    local status = payload and payload.status or "loading"
    for i, label in ipairs(recordLines) do
        local entry = entries[i]
        if entry then
            label.Text = Ranking.formatLine(entry, i, config)
            label.TextColor3 = if rankKnown
                    and myRank == i
                    and showBadge
                then Colors.energy
                else Colors.text
            label.Visible = true
        elseif i == 1 then
            label.Text = if status == "loading" then t.recordsLoading else t.recordsEmpty
            label.TextColor3 = Colors.textDim
            label.Visible = true
        else
            label.Visible = false
        end
    end
    recordStatusLabel.Text = t.recordsOffline
    recordStatusLabel.Visible = status == "offline"
end

-- 표 한 행: 이름 + 숫자 칸들. widths는 칸별 가로 비율
local function makeCrewRow(order, texts, widths, color, height, bold)
    local row = UI.create("Frame", {
        Name = "CrewRow" .. order,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Horizontal, 0) })
    for i, text in ipairs(texts) do
        UI.create("TextLabel", {
            Name = "Cell" .. i,
            LayoutOrder = i,
            Size = UDim2.fromScale(widths[i], 1),
            Text = text,
            TextColor3 = color,
            Font = if bold then UI.FontBold else UI.Font,
            TextSize = CREW_TEXT_SIZE,
            TextWrapped = i > 1,
            TextTruncate = if i == 1 then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None,
            TextXAlignment = if i == 1
                then Enum.TextXAlignment.Left
                else Enum.TextXAlignment.Center,
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
    local header = { t.crewName, t.crewPanels, t.crewWater, t.crewBuilds, t.crewRepairs }
    if showDeaths then
        table.insert(header, t.crewDeaths)
    end
    local numeric = #header - 1
    local nameWidth = if showDeaths then 0.28 else 0.36
    local widths = { nameWidth }
    for _ = 1, numeric do
        table.insert(widths, (1 - nameWidth) / numeric)
    end
    -- "산소 고갈"은 좁은 칸에서 두 줄이 될 수 있다
    local headerRow =
        makeCrewRow(2, header, widths, Colors.textDim, if showDeaths then 34 else 20, true)
    headerRow.Parent = crewFrame
    table.insert(crewRows, headerRow)
    for i, c in ipairs(crew) do
        if i > config.RECORDS.crewRows then
            break
        end
        local cells = {
            c.name,
            tostring(c.panels),
            tostring(c.water),
            tostring(c.builds),
            tostring(c.repairs),
        }
        if showDeaths then
            table.insert(cells, tostring(c.deaths))
        end
        local row = makeCrewRow(2 + i, cells, widths, Colors.text, 22, false)
        row.Parent = crewFrame
        table.insert(crewRows, row)
    end
end

-- 카드 크기: 내용 높이까지 자라되 화면 높이 - 여백을 넘으면 그 높이에서 세로 스크롤
local function fitCard()
    if not card then
        return
    end
    local camera = workspace.CurrentCamera
    local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
    local compact = Layout.isCompact()
    local pad = if compact then 14 else 22
    cardPadding.PaddingTop = UDim.new(0, pad)
    cardPadding.PaddingBottom = UDim.new(0, pad)
    cardPadding.PaddingLeft = UDim.new(0, pad)
    cardPadding.PaddingRight = UDim.new(0, pad)
    cardList.Padding = UDim.new(0, if compact then 8 else 14)
    titleLabel.TextSize = if compact then 32 else 44
    titleLabel.Size = UDim2.new(1, 0, 0, if compact then 40 else 56)
    local width = math.min(CARD_WIDTH, math.max(280, viewport.X - CARD_MARGIN * 2))
    local contentHeight = cardList.AbsoluteContentSize.Y + pad * 2
    local maxHeight = math.max(160, viewport.Y - CARD_MARGIN * 2)
    card.Size = UDim2.fromOffset(width, math.min(contentHeight, maxHeight))
    card.CanvasSize = UDim2.fromOffset(0, contentHeight)
end

function ResultUI.init(ctx)
    config = ctx.Config
    restartRemote = ctx.remotes.RequestRestart
    gui = UI.gui("Result", 80)
    gui.Enabled = false

    titleLabel = UI.create("TextLabel", {
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 56),
        Text = "",
        Preset = "title",
        TextSize = 44,
    })
    badgeLabel = UI.create("TextLabel", {
        Name = "RankBadge",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, 28),
        Text = "",
        Font = UI.FontBold,
        TextSize = 22,
        TextColor3 = Colors.energy,
        Visible = false,
    })
    reasonLabel = UI.create("TextLabel", {
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextWrapped = true,
    })
    local summary = UI.create("Frame", {
        Name = "Summary",
        LayoutOrder = 4,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.bg,
    }, { UI.corner(10), UI.padding(14), UI.list(Enum.FillDirection.Vertical, 4) })
    values.day = makeRow(summary, 1, "소요 일수")
    values.trips = makeRow(summary, 2, "물 원정 횟수")
    values.deaths = makeRow(summary, 3, "산소 고갈 횟수")
    values.site = makeRow(summary, 4, "착륙지")

    -- "함께 한 일" 기여도 표 (16차). 순위 표기 없이 기여 합이 큰 순으로 서버가 정렬해 보낸다
    crewRows = {}
    crewFrame = UI.create("Frame", {
        Name = "Crew",
        LayoutOrder = 5,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.bg,
        Visible = false,
    }, {
        UI.corner(10),
        UI.padding(12),
        UI.list(Enum.FillDirection.Vertical, 2),
        UI.create("TextLabel", {
            Name = "CrewTitle",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 22),
            Text = config.TEXTS.crewTitle,
            Font = UI.FontBold,
            TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
    })

    -- 명예의 전당 상위 목록 (16차)
    recordsFrame = UI.create("Frame", {
        Name = "Records",
        LayoutOrder = 6,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.bg,
    }, {
        UI.corner(10),
        UI.padding(12),
        UI.list(Enum.FillDirection.Vertical, 4),
        UI.create("TextLabel", {
            Name = "RecordsTitle",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 22),
            Text = config.TEXTS.recordsTitle,
            Font = UI.FontBold,
            TextSize = 16,
            TextColor3 = Colors.energy,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
    })
    recordLines = {}
    for i = 1, config.RECORDS.showTop do
        local line = UI.create("TextLabel", {
            Name = "RecordLine" .. i,
            LayoutOrder = 1 + i,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Text = "",
            TextSize = RECORD_TEXT_SIZE,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = recordsFrame,
        })
        table.insert(recordLines, line)
    end
    recordStatusLabel = UI.create("TextLabel", {
        Name = "RecordsStatus",
        LayoutOrder = 2 + config.RECORDS.showTop,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        TextSize = RECORD_TEXT_SIZE,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = false,
        Parent = recordsFrame,
    })

    restartButton = UI.create("TextButton", {
        Name = "RestartButton",
        LayoutOrder = 7,
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = Colors.accent,
        Text = "재도전",
        Preset = "heading",
    }, { UI.corner(10) })

    noteLabel = UI.create("TextLabel", {
        Name = "RestartNote",
        LayoutOrder = 8,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        Preset = "body",
        TextWrapped = true,
        Visible = false,
    })

    learnedLabel = UI.create("TextLabel", {
        Name = "LearnedBody",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Text = "",
        TextColor3 = Colors.textDim,
        TextSize = 15,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local learned = UI.create("Frame", {
        Name = "Learned",
        LayoutOrder = 9,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Colors.bg,
    }, {
        UI.corner(10),
        UI.padding(12),
        UI.list(Enum.FillDirection.Vertical, 4),
        UI.create("TextLabel", {
            Name = "LearnedTitle",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, 20),
            Text = "오늘 배운 것",
            Font = UI.FontBold,
            TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        learnedLabel,
    })

    -- 카드는 세로 스크롤 프레임: 크기는 fitCard가 내용 높이와 화면 높이로 정한다 (16차, 높이 390 폰 넘침 방지)
    cardPadding = UI.padding(22)
    cardList = UI.list(Enum.FillDirection.Vertical, 14)
    card = UI.create("ScrollingFrame", {
        Name = "Card",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(CARD_WIDTH, 200),
        BackgroundColor3 = Colors.panel,
        BorderSizePixel = 0,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.fromOffset(0, 0),
        ScrollBarThickness = 6,
        ScrollBarImageColor3 = Colors.textDim,
        VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
    }, {
        UI.corner(14),
        UI.stroke(Colors.panelLight, 2),
        cardPadding,
        cardList,
        titleLabel,
        badgeLabel,
        reasonLabel,
        summary,
        crewFrame,
        recordsFrame,
        restartButton,
        noteLabel,
        learned,
    })
    UI.create("Frame", {
        Name = "Dim",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.35,
        Parent = gui,
    }, { card })
    cardList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fitCard)
    Layout.changed:Connect(fitCard)
    fitCard()
    updateRecordsList()

    restartButton.Activated:Connect(function()
        if not restartButton.Active then
            return
        end
        restartPressed = true
        restartButton.Active = false
        restartButton.BackgroundColor3 = Colors.disabled
        restartButton.Text = "다시 준비 중..."
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
    titleLabel.Text = result.won and "임무 성공" or "임무 실패"
    titleLabel.TextColor3 = result.won and Colors.good or Colors.bad
    reasonLabel.Text = result.reason or ""
    reasonLabel.Visible = (result.reason or "") ~= ""
    values.day.Text = string.format("%d일", result.day)
    values.trips.Text = string.format("%d회", result.waterTrips)
    values.deaths.Text = string.format("%d회", result.oxygenDeaths)
    values.site.Text = result.siteName or "-"

    updateLearned(result.won)
    restartAvailableAt = result.restartAvailableAt
    chooserUserId = result.chooserUserId
    if not visible then
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
    resultWon = result.won == true
    showBadge = result.fallback ~= true
    updateCrew(result.crew)
    updateBadge()
    updateRecordsList()
    visible = true
    gui.Enabled = true
    updateRestartButton()
    fitCard()
    card.CanvasPosition = Vector2.new(0, 0)
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
