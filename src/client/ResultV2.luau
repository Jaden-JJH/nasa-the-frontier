--!nonstrict
-- v2 결과 화면 (CONTRACT_V2 4.1 GameOver, Records, 6절 MissionResult, V2_PLAN 15.2 Q4 Q5 Q24, 15.8 Q36, 15.9 Q32).
-- v1 ResultUI의 루나 디자인(그라데이션 배경, 흰 반투명 패널, 왼쪽 상태 모노 라벨과 큰 제목)을 따른다.
-- 왼쪽: 상태 라벨, 제목, 사유(실패는 "다음엔 이렇게 해 보자" 문구), 메달, 걸린 날, 점수,
--       깎인 점수 내역(사유별 Msg), 이번 판 우주 날씨(실제 NASA DONKI 기록 구간, SEP n회, GST n회), 함께 한 일(역할 포함).
-- 오른쪽: 이번 미션 상위 5와 전체 상위 5(내 순위가 밖이면 아래 한 줄), 다시 하기 버튼(restartAvailableAt, 권한자만).
-- 넓은 화면은 두 열, 좁거나 compact는 한 열로 쌓아 스크롤한다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ClientMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientMath"))
local MissionConfig =
    require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MissionConfig"))
local Msg = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Msg"))

local Layout = require(script.Parent.Layout)
local Net = require(script.Parent.Net)
local Session = require(script.Parent.Session)
local UI = require(script.Parent.UI)
local L = UI.Luna

local ResultV2 = {}

local LEFT_WIDTH = 640
local RIGHT_WIDTH = 460
local COLUMN_GAP = 24
local STACK_MAX_WIDTH = 720
local PAD = 16
local TOP_LIMIT = 5
local FADE_SECONDS = 0.35
local RESTART_RETRY_SECONDS = 3
local RANK_VALUE_WIDTH = 190 -- 순위 줄 오른쪽 값 ("Score: 1000 and 1 day" 한 줄 14px). 이름은 그만큼 좁힌다

-- 리터럴 키 표
local MEDAL_KEYS =
    { gold = "medal.gold.name", silver = "medal.silver.name", bronze = "medal.bronze.name" }
local MEDAL_COLORS = {
    gold = Color3.fromRGB(255, 209, 102),
    silver = Color3.fromRGB(205, 214, 235),
    bronze = Color3.fromRGB(222, 150, 96),
}
local MISSION_NAMES = {
    A = "mission.a.name",
    B = "mission.b.name",
    C = "mission.c.name",
    D = "mission.d.name",
}
local CREW_COLUMNS = {
    { field = "panels", key = "result.crew.panels" },
    { field = "water", key = "res.water.name" },
    { field = "builds", key = "result.crew.builds" },
    { field = "repairs", key = "result.crew.repairs" },
    { field = "rescues", key = "result.crew.rescues" },
}

local gui
local fadeGroup
local summaryTiles -- 메달, 일수, 점수 칸 (GameOver 전 늦은 입장자 화면에서는 숨김)
local scorePanelFrame
local crewPanelFrame
local contentRoot -- Layout.root. 페이드가 끝나면 fadeGroup 밖(gui 바로 아래)으로 옮겨 글자를 선명하게, 숨기면 되돌린다
local fadeToken = 0
local scroll
local stage
local stageLayout
local leftColumn
local rightColumn
local tagLabel
local titleLabel
local reasonLabel
local medalDot
local medalLabel
local daysValue
local scoreValue
local scoreStart
local deductionList
local weatherBox
local weatherRange
local weatherCounts
local crewTable
local missionRanks
local globalRanks
local restartButton
local restartNote

local visible = false
local result = nil
local records = nil
local restartSent = false
local heartbeat = nil

local function label(props)
    local merged = {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextSize = 16,
        TextColor3 = L.body,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    }
    for key, value in pairs(props or {}) do
        merged[key] = value
    end
    -- Font와 FontFace를 같이 넣으면 적용 순서에 따라 한쪽이 덮인다. FontFace가 있으면 Font는 넣지 않는다
    if merged.FontFace == nil and merged.Font == nil then
        merged.Font = UI.Font
    end
    return UI.create("TextLabel", merged)
end

local function panel(name, order)
    return UI.lunaPanel({
        Name = name,
        LayoutOrder = order,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
    }, { UI.padding(18), UI.list(Enum.FillDirection.Vertical, 8) })
end

local function heading(text, order, color)
    local h = label({
        Name = "Heading",
        LayoutOrder = order,
        FontFace = UI.MonoBold,
        TextSize = 13,
        TextColor3 = color or L.mint,
    })
    UI.msg(h, text)
    return h
end

-- 자식 전부(레이아웃, 여백 포함)를 지운다. 다시 그릴 때 레이아웃을 새로 단다
local function clearChildren(frame)
    for _, child in ipairs(frame:GetChildren()) do
        if not child:IsA("UICorner") and not child:IsA("UIStroke") then
            child:Destroy()
        end
    end
end

local function tile(name, order, headingKey)
    local value = label({
        Name = "Value",
        LayoutOrder = 2,
        FontFace = UI.RoundHeavy,
        TextSize = 30,
        TextColor3 = L.white,
    })
    local frame = UI.lunaPanel({
        Name = name,
        LayoutOrder = order,
        Size = UDim2.fromOffset(180, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 0.9,
    }, {
        UI.padding(14),
        UI.list(Enum.FillDirection.Vertical, 4),
        heading(headingKey, 1, L.dim),
        value,
    }, 14)
    return frame, value
end

-- 순위 한 줄: 순위, 색 점, 이름, 오른쪽 값
local function rankRow(order, rank, color, nameText, valueText, mine)
    local frame = UI.create("Frame", {
        Name = "Row" .. order,
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = L.mint,
        BackgroundTransparency = if mine then 0.85 else 1,
    }, { UI.corner(8) })
    local rankLabel = UI.create("TextLabel", {
        Name = "Rank",
        Position = UDim2.fromOffset(8, 0),
        Size = UDim2.new(0, 44, 1, 0),
        FontFace = UI.RoundHeavy,
        TextSize = 16,
        TextColor3 = if mine then L.mint else L.gold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    UI.msg(rankLabel, rank)
    UI.dot(12, color or L.faint, {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 56, 0.5, 0),
        Parent = frame,
    })
    local nameLabel = UI.create("TextLabel", {
        Name = "Name",
        Position = UDim2.fromOffset(76, 0),
        Size = UDim2.new(1, -(76 + RANK_VALUE_WIDTH + 16), 1, 0),
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.white,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = frame,
    })
    -- 플레이어 이름(문자열)은 번역하지 않는다
    if type(nameText) == "string" then
        UI.raw(nameLabel, nameText)
    else
        UI.msg(nameLabel, nameText)
    end
    local valueLabel = UI.create("TextLabel", {
        Name = "Value",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -8, 0, 0),
        Size = UDim2.new(0, RANK_VALUE_WIDTH, 1, 0),
        FontFace = UI.MonoBold,
        TextSize = 14,
        TextScaled = false,
        TextWrapped = false,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextColor3 = L.label,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = frame,
    })
    UI.msg(valueLabel, valueText)
    return frame
end

local function crewNames(entry)
    local names = {}
    for _, member in ipairs(type(entry.crew) == "table" and entry.crew or {}) do
        if type(member) == "string" then
            table.insert(names, member)
        elseif type(member) == "table" and type(member.name) == "string" then
            table.insert(names, member.name)
        end
    end
    return names
end

local function modeMsg(entry)
    local players = if type(entry.players) == "number" then entry.players else #crewNames(entry)
    if entry.mode == "solo" or players <= 1 then
        return { key = "role.solo.name" }
    end
    return { key = "result.team", args = { n = players } }
end

local function missionRow(order, rank, entry, mine)
    local names = crewNames(entry)
    -- 순위 줄: "솔로" 또는 "팀 N명" 다음에 이름 (V2_PLAN Q5, 2026-11-15 QA D9: 이름만 보였다)
    local nameValue = if #names > 0
        then { key = "fmt.list.start", args = { a = modeMsg(entry), b = Msg.list(names) } }
        else modeMsg(entry)
    local value = {
        key = "fmt.list.two",
        args = {
            a = { key = "score.total", args = { points = ClientMath.wholeNumber(entry.score) } },
            b = Msg.count("unit.day", ClientMath.wholeNumber(entry.days)),
        },
    }
    return rankRow(
        order,
        { key = "result.rank", args = { rank = rank } },
        MEDAL_COLORS[entry.medal],
        nameValue,
        value,
        mine
    )
end

local function globalRow(order, rank, entry, mine)
    local value = Msg.count("result.gold_count", ClientMath.wholeNumber(entry.goldMissions))
    return rankRow(
        order,
        { key = "result.rank", args = { rank = rank } },
        if (entry.goldMissions or 0) > 0 then MEDAL_COLORS.gold else L.faint,
        tostring(entry.name or "?"),
        value,
        mine
    )
end

local function statusLine(order, key)
    local line = label({ Name = "Status", LayoutOrder = order, TextSize = 14, TextColor3 = L.dim })
    UI.msg(line, key)
    return line
end

local function fillRanks(frame, titleMsg, block, makeRow, extraRow)
    clearChildren(frame)
    UI.padding(18).Parent = frame
    UI.list(Enum.FillDirection.Vertical, 6).Parent = frame
    local title = label({
        Name = "Title",
        LayoutOrder = 1,
        FontFace = UI.RoundHeavy,
        TextSize = 20,
        TextColor3 = L.gold,
    })
    UI.msg(title, titleMsg)
    title.Parent = frame
    local status = records and records.status
    local entries = type(block) == "table" and block.entries or nil
    if status == "loading" or records == nil then
        statusLine(2, "result.ranks.loading").Parent = frame
        return
    end
    if status == "offline" then
        statusLine(2, "result.ranks.offline").Parent = frame
    end
    if type(entries) ~= "table" or #entries == 0 then
        statusLine(3, "result.ranks.empty").Parent = frame
        return
    end
    local myRank = if type(block.rank) == "number" then block.rank else nil
    local rows, extra = ClientMath.rankRows(entries, TOP_LIMIT, myRank)
    for i, r in ipairs(rows) do
        makeRow(10 + i, r.rank, r.entry, r.mine).Parent = frame
    end
    if extra then
        local sep = UI.create("Frame", {
            Name = "Separator",
            LayoutOrder = 90,
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = L.white,
            BackgroundTransparency = 0.85,
        })
        sep.Parent = frame
        local row = extraRow(extra)
        if row then
            row.LayoutOrder = 91
            row.Parent = frame
        end
    end
end

local function refreshRanks()
    local missionId = result and result.missionId or Session.missionId()
    local missionBlock = records and records.mission
    fillRanks(
        missionRanks,
        {
            key = "result.ranks.mission",
            args = { mission = { key = MISSION_NAMES[missionId] or "mission.c.name" } },
        },
        missionBlock,
        missionRow,
        function(rank)
            -- 서버가 이번 판 기록(mission.entry)을 보내면 그대로, 없으면 결과로 만든다
            local entry = type(missionBlock) == "table" and missionBlock.entry or nil
            if type(entry) ~= "table" then
                if not result then
                    return nil
                end
                entry = {
                    medal = result.medal,
                    score = result.score,
                    days = result.day,
                    mode = result.mode,
                    players = result.players,
                    crew = {},
                }
                for _, member in ipairs(result.crew or {}) do
                    table.insert(entry.crew, member.name)
                end
            end
            return missionRow(91, rank, entry, true)
        end
    )
    local globalBlock = records and records.global
    fillRanks(globalRanks, "result.ranks.global", globalBlock, globalRow, function(rank)
        local mine = type(globalBlock) == "table" and globalBlock.mine or nil
        local entry = {
            name = Players.LocalPlayer.DisplayName,
            goldMissions = if type(mine) == "table" then mine.goldMissions else 0,
        }
        return globalRow(91, rank, entry, true)
    end)
end

local function refreshRestart()
    if not result then
        return
    end
    local now = workspace:GetServerTimeNow()
    local left = ClientMath.secondsLeft(result.restartAvailableAt, now)
    local me = Players.LocalPlayer.UserId
    local isChooser = result.chooserUserId == nil or result.chooserUserId == me
    local canPress = left <= 0 and isChooser and not restartSent
    UI.setButtonEnabled(restartButton, canPress, true)
    if restartSent then
        UI.msg(restartButton, "result.restart_sent")
    elseif left > 0 then
        UI.msg(restartButton, Msg.count("result.restart_wait", left))
    else
        UI.msg(restartButton, "result.restart")
    end
    if not isChooser then
        local chooser = Players:GetPlayerByUserId(result.chooserUserId)
        restartNote.Visible = chooser ~= nil
        if chooser then
            UI.msg(
                restartNote,
                { key = "result.restart_host", args = { name = chooser.DisplayName } }
            )
        end
    else
        restartNote.Visible = false
    end
end

-- 역할 미션 배지 줄 (C4, 멀티만): 끝났으면 체크 + 배지 이름 + "완료!", 아니면 배지 이름 + "못 끝냄" + n / goal
local MEMBER_HEIGHT = 40
local BADGE_HEIGHT = 20

local function badgeRow(parent, mission)
    local row = UI.create("Frame", {
        Name = "RoleMission",
        Position = UDim2.fromOffset(6, MEMBER_HEIGHT - 2),
        Size = UDim2.new(1, -12, 0, BADGE_HEIGHT),
        BackgroundTransparency = 1,
        Parent = parent,
    }, {
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
    })
    if mission.done then
        UI.checkMark(L.mint, { LayoutOrder = 1 }).Parent = row
    end
    local badge = UI.create("TextLabel", {
        Name = "Badge",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, BADGE_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 14,
        TextColor3 = if mission.done then L.mint else L.label,
        Parent = row,
    })
    UI.msg(badge, ClientMath.ROLE_MISSION_KEYS[mission.id].badge)
    local tag = UI.create("TextLabel", {
        Name = "Tag",
        LayoutOrder = 3,
        Size = UDim2.fromOffset(0, BADGE_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        Font = UI.FontBold,
        TextSize = 13,
        TextColor3 = if mission.done then L.mint else L.dim,
        Parent = row,
    })
    UI.msg(tag, if mission.done then "rolemission.done" else "rolemission.result.not_done")
    if not mission.done then
        local progress = UI.create("TextLabel", {
            Name = "Progress",
            LayoutOrder = 4,
            Size = UDim2.fromOffset(0, BADGE_HEIGHT),
            AutomaticSize = Enum.AutomaticSize.X,
            FontFace = UI.MonoBold,
            TextSize = 13,
            TextColor3 = L.dim,
            Parent = row,
        })
        UI.msg(
            progress,
            { key = "fmt.fraction", args = { value = mission.progress, max = mission.goal } }
        )
    end
end

local function refreshCrew(crew)
    clearChildren(crewTable)
    UI.list(Enum.FillDirection.Vertical, 2).Parent = crewTable
    local missions = {}
    local anyMission = false
    for index, member in ipairs(crew or {}) do
        missions[index] = ClientMath.normalizeRoleMission(member.roleMission)
        anyMission = anyMission or missions[index] ~= nil
    end
    -- 역할 미션 배지 섹션 제목 (멀티만, 배지는 이름 아래 줄마다)
    if anyMission then
        local title = heading("rolemission.result.title", 0, L.gold)
        title.Name = "RoleMissionTitle"
        title.Parent = crewTable
    end
    local headerRow = UI.create("Frame", {
        Name = "Header",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Parent = crewTable,
    })
    local nameWidth = 0.34
    local colWidth = (1 - nameWidth) / #CREW_COLUMNS
    for i, column in ipairs(CREW_COLUMNS) do
        local h = UI.create("TextLabel", {
            Name = column.field,
            Position = UDim2.fromScale(nameWidth + colWidth * (i - 1), 0),
            Size = UDim2.fromScale(colWidth, 1),
            FontFace = UI.MonoBold,
            TextColor3 = L.dim,
            Parent = headerRow,
        })
        UI.scaledText(h, 12, 8)
        UI.msg(h, column.key)
    end
    for index, member in ipairs(crew or {}) do
        local line = UI.create("Frame", {
            Name = "Member" .. index,
            LayoutOrder = 1 + index,
            Size = UDim2.new(
                1,
                0,
                0,
                if anyMission then MEMBER_HEIGHT + BADGE_HEIGHT else MEMBER_HEIGHT
            ),
            BackgroundColor3 = L.white,
            BackgroundTransparency = if index % 2 == 0 then 0.95 else 1,
            Parent = crewTable,
        }, { UI.corner(6) })
        local nameLabel = UI.create("TextLabel", {
            Name = "Name",
            Position = UDim2.fromOffset(6, 2),
            Size = UDim2.new(nameWidth, -6, 0, 20),
            Font = UI.FontBold,
            TextSize = 15,
            TextColor3 = L.white,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = line,
        })
        UI.raw(nameLabel, tostring(member.name or "?"))
        if member.userId ~= nil and member.userId == Players.LocalPlayer.UserId then
            nameLabel.TextColor3 = L.mint -- 내 줄 (GameOver crew[i].userId)
        end
        local roleLabel = UI.create("TextLabel", {
            Name = "Role",
            Position = UDim2.fromOffset(6, 21),
            Size = UDim2.new(nameWidth, -6, 0, 16),
            Font = UI.Font,
            TextSize = 13,
            TextColor3 = L.gold,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = line,
        })
        UI.msg(roleLabel, Session.ROLE_NAMES[member.role] or "role.solo.name")
        for i, column in ipairs(CREW_COLUMNS) do
            local value = UI.create("TextLabel", {
                Name = column.field,
                Position = UDim2.fromScale(nameWidth + colWidth * (i - 1), 0),
                Size = UDim2.fromScale(colWidth, 1),
                FontFace = UI.MonoBold,
                TextSize = 15,
                TextColor3 = L.body,
                Parent = line,
            })
            UI.raw(value, tostring(ClientMath.wholeNumber(member[column.field])))
            value.Size = UDim2.new(colWidth, 0, 0, MEMBER_HEIGHT)
        end
        if missions[index] then
            badgeRow(line, missions[index])
        end
    end
    -- 역할 미션은 점수와 무관하다는 안내 (멀티만)
    if anyMission then
        local note = UI.create("TextLabel", {
            Name = "RoleMissionNote",
            LayoutOrder = 2 + #(crew or {}),
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Font = UI.Font,
            TextSize = 13,
            TextColor3 = L.dim,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = crewTable,
        }, { UI.padding({ 4, 0, 6, 6 }) })
        UI.msg(note, "rolemission.note")
    end
end

local function refreshResult()
    if not result then
        return
    end
    -- 늦은 입장자(GameOver 유실, showFromState): 승패, 메달, 점수를 모른다. 중립 머리글("미션 종료")과 순위, 다시 하기만
    -- 보이고, GameOver가 오면 show가 다시 불려 정상 화면이 된다
    local partial = result.partial == true
    titleLabel.Visible = not partial
    summaryTiles.Visible = not partial
    scorePanelFrame.Visible = not partial
    crewPanelFrame.Visible = not partial
    local won = result.won == true
    UI.msg(tagLabel, if won then "result.tag.won" else "result.tag.lost")
    tagLabel.TextColor3 = if won then L.mint elseif partial then L.label else L.red
    UI.msg(titleLabel, if won then "result.title.won" else "result.title.lost")
    if Msg.isMsg(result.reason) and not partial then
        reasonLabel.Visible = true
        UI.msg(reasonLabel, result.reason)
    else
        reasonLabel.Visible = false
    end
    local medal = result.medal
    medalDot.BackgroundColor3 = MEDAL_COLORS[medal] or L.faint
    UI.msg(medalLabel, MEDAL_KEYS[medal] or "medal.none.name")
    UI.raw(daysValue, tostring(ClientMath.wholeNumber(result.day)))
    UI.raw(scoreValue, tostring(ClientMath.wholeNumber(result.score)))

    clearChildren(deductionList)
    UI.list(Enum.FillDirection.Vertical, 4).Parent = deductionList
    local deductions = result.deductions or {}
    if #deductions == 0 then
        local none = label({ Name = "None", TextColor3 = L.mint, Font = UI.FontBold })
        UI.msg(none, "score.lost.none")
        none.Parent = deductionList
    else
        for i, d in ipairs(deductions) do
            local line = label({ Name = "Deduction" .. i, LayoutOrder = i, TextSize = 15 })
            if Msg.isMsg(d.msg) then
                UI.msg(line, d.msg)
            else
                UI.raw(line, "-" .. tostring(ClientMath.wholeNumber(d.points)))
            end
            line.Parent = deductionList
        end
    end
    scoreStart.Visible = #deductions > 0
    local startScore = if type(result.startScore) == "number"
        then result.startScore
        else MissionConfig.SCORE.start
    UI.msg(scoreStart, { key = "result.score.start", args = { points = startScore } })

    local weather = result.weather
    weatherBox.Visible = type(weather) == "table" and not partial
    if type(weather) == "table" then
        if type(weather.startDate) == "table" and type(weather.endDate) == "table" then
            weatherRange.Visible = true
            UI.msg(weatherRange, {
                key = "result.weather.range",
                args = {
                    start = Msg.date(weather.startDate, "long"),
                    ["end"] = Msg.date(weather.endDate, "long"),
                },
            })
        else
            weatherRange.Visible = false
        end
        UI.msg(weatherCounts, {
            key = "fmt.list.two",
            args = {
                a = Msg.count("result.weather.sep", ClientMath.wholeNumber(weather.sep)),
                b = Msg.count("result.weather.gst", ClientMath.wholeNumber(weather.gst)),
            },
        })
    end
    refreshCrew(result.crew)
    refreshRanks()
    refreshRestart()
end

local function fit()
    if not stage then
        return
    end
    local compact = Layout.isCompact()
    local scale = Layout.scale()
    local abs = gui.AbsoluteSize
    if abs.X <= 0 then
        abs = Vector2.new(1280, 720) * scale
    end
    local space = abs / scale
    local stacked = compact or space.X < LEFT_WIDTH + RIGHT_WIDTH + COLUMN_GAP + PAD * 2
    if stacked then
        local width = math.min(STACK_MAX_WIDTH, space.X - PAD * 2)
        stageLayout.FillDirection = Enum.FillDirection.Vertical
        leftColumn.Size = UDim2.fromOffset(width, 0)
        rightColumn.Size = UDim2.fromOffset(width, 0)
        stage.Size = UDim2.fromOffset(width, 0)
    else
        stageLayout.FillDirection = Enum.FillDirection.Horizontal
        leftColumn.Size = UDim2.fromOffset(LEFT_WIDTH, 0)
        rightColumn.Size = UDim2.fromOffset(RIGHT_WIDTH, 0)
        stage.Size = UDim2.fromOffset(LEFT_WIDTH + RIGHT_WIDTH + COLUMN_GAP, 0)
    end
    titleLabel.TextSize = if compact then 36 else 52
end

function ResultV2.init(_ctx)
    gui = UI.gui("ResultV2", 110)
    gui.Enabled = false
    -- UIGradient를 CanvasGroup에 직접 달면 그룹 전체(글자, 패널 포함)가 그 색으로 물든다.
    -- 그래서 그라데이션은 맨 뒤 배경 판(Backdrop)에만 단다
    fadeGroup = UI.create("CanvasGroup", {
        Name = "Fade",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Parent = gui,
    })
    UI.create("Frame", {
        Name = "Backdrop",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = L.white,
        BackgroundTransparency = 0.04,
        BorderSizePixel = 0,
        ZIndex = 0,
        Parent = fadeGroup,
    }, { UI.lunaGradient() })
    local root = Layout.root(gui)
    root.Parent = fadeGroup
    root.ZIndex = 2 -- gui 바로 아래로 옮겼을 때 Backdrop(fadeGroup) 위에 그린다
    contentRoot = root
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
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        UI.padding({ math.floor(UI.topInset() + 16), 24, PAD, PAD }),
    })

    -- 왼쪽 열
    tagLabel = label({
        Name = "Tag",
        LayoutOrder = 1,
        FontFace = UI.MonoBold,
        TextSize = 14,
        TextColor3 = L.mint,
    })
    titleLabel = label({
        Name = "Title",
        LayoutOrder = 2,
        FontFace = UI.RoundHeavy,
        TextSize = 52,
        TextColor3 = L.white,
    })
    reasonLabel = label({
        Name = "Reason",
        LayoutOrder = 3,
        Font = UI.FontBold,
        TextSize = 18,
        TextColor3 = L.soft,
    })

    medalDot = UI.create("Frame", {
        Name = "MedalDot",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(28, 28),
        BackgroundColor3 = L.gold,
    }, { UI.roundCorner(), UI.stroke(L.white, 2, 0.3) })
    medalLabel = UI.create("TextLabel", {
        Name = "MedalName",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(0, 30),
        AutomaticSize = Enum.AutomaticSize.X,
        FontFace = UI.RoundHeavy,
        TextSize = 24,
        TextColor3 = L.white,
    })
    local medalTile = UI.lunaPanel({
        Name = "Medal",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(0, 0),
        AutomaticSize = Enum.AutomaticSize.XY,
        BackgroundTransparency = 0.88,
    }, {
        UI.padding(14),
        UI.create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 10),
            SortOrder = Enum.SortOrder.LayoutOrder,
            VerticalAlignment = Enum.VerticalAlignment.Center,
        }),
        medalDot,
        medalLabel,
    }, 14)
    local daysTile
    daysTile, daysValue = tile("Days", 2, "result.days.label")
    local scoreTile
    scoreTile, scoreValue = tile("Score", 3, "score.title")
    daysTile.Size = UDim2.fromOffset(120, 0)
    scoreTile.Size = UDim2.fromOffset(140, 0)
    local tiles = UI.create("Frame", {
        Name = "Tiles",
        LayoutOrder = 4,
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
        medalTile,
        daysTile,
        scoreTile,
    })
    summaryTiles = tiles
    local summary = panel("Summary", 1)
    for _, child in ipairs({ tagLabel, titleLabel, reasonLabel, tiles }) do
        child.Parent = summary
    end

    local scorePanel = panel("ScoreDetail", 2)
    scorePanelFrame = scorePanel
    heading("score.lost.title", 1, L.red).Parent = scorePanel
    scoreStart = label({ Name = "Start", LayoutOrder = 2, TextSize = 14, TextColor3 = L.dim })
    scoreStart.Parent = scorePanel
    deductionList = UI.create("Frame", {
        Name = "Deductions",
        LayoutOrder = 3,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = scorePanel,
    })

    weatherBox = panel("Weather", 3)
    heading("result.weather.title", 1, L.sky).Parent = weatherBox
    weatherRange = label({ Name = "Range", LayoutOrder = 2, TextSize = 15 })
    weatherRange.Parent = weatherBox
    weatherCounts = label({
        Name = "Counts",
        LayoutOrder = 3,
        Font = UI.FontBold,
        TextSize = 15,
        TextColor3 = L.white,
    })
    weatherCounts.Parent = weatherBox

    local crewPanel = panel("Crew", 4)
    crewPanelFrame = crewPanel
    heading("result.crew.title", 1, L.gold).Parent = crewPanel
    crewTable = UI.create("Frame", {
        Name = "Table",
        LayoutOrder = 2,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = crewPanel,
    })

    leftColumn = UI.create("Frame", {
        Name = "Left",
        LayoutOrder = 1,
        Size = UDim2.fromOffset(LEFT_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 14), summary, scorePanel, weatherBox, crewPanel })

    -- 오른쪽 열
    missionRanks = panel("MissionRanks", 1)
    globalRanks = panel("GlobalRanks", 2)
    restartButton =
        UI.lunaButton({ Name = "Restart", Size = UDim2.new(1, 0, 0, 58), TextSize = 20 }, true)
    restartButton.Activated:Connect(function()
        if restartButton.Active and not restartSent then
            restartSent = Net.fire("RequestRestart")
            refreshRestart()
            -- 서버가 거절하면(토스트로 알림) 다시 누를 수 있게 잠시 뒤 푼다
            task.delay(RESTART_RETRY_SECONDS, function()
                restartSent = false
            end)
        end
    end)
    restartNote = label({
        Name = "Note",
        LayoutOrder = 2,
        TextSize = 14,
        TextColor3 = L.dim,
        Visible = false,
    })
    -- 다시 하기는 오른쪽 열 맨 위 (720 높이에서도 스크롤 없이 보이게)
    local restartBox = UI.create("Frame", {
        Name = "RestartBox",
        LayoutOrder = 0,
        Size = UDim2.fromScale(1, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 6), restartButton, restartNote })
    restartButton.LayoutOrder = 1
    rightColumn = UI.create("Frame", {
        Name = "Right",
        LayoutOrder = 2,
        Size = UDim2.fromOffset(RIGHT_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, { UI.list(Enum.FillDirection.Vertical, 14), missionRanks, globalRanks, restartBox })

    stageLayout = UI.create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, COLUMN_GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
    })
    stage = UI.create("Frame", {
        Name = "Stage",
        Size = UDim2.fromOffset(LEFT_WIDTH + RIGHT_WIDTH + COLUMN_GAP, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = scroll,
    }, { stageLayout, leftColumn, rightColumn })

    fit()
    Layout.changed:Connect(fit)
    gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
end

function ResultV2.show(payload)
    if type(payload) ~= "table" then
        return
    end
    result = payload
    restartSent = false
    refreshResult()
    if not visible then
        visible = true
        gui.Enabled = true
        -- CanvasGroup은 제 해상도로 한 번 그려 늘리므로 글자가 흐리다. 페이드 동안만 안에 두고 끝나면 gui 바로 아래로
        -- (v1 ResultUI와 같은 방식)
        fadeToken += 1
        local token = fadeToken
        contentRoot.Parent = fadeGroup
        fadeGroup.GroupTransparency = 1
        local tween =
            TweenService:Create(fadeGroup, TweenInfo.new(FADE_SECONDS), { GroupTransparency = 0 })
        tween.Completed:Connect(function()
            if token == fadeToken and visible then
                contentRoot.Parent = gui
            end
        end)
        tween:Play()
        scroll.CanvasPosition = Vector2.zero
        fit()
    end
    if not heartbeat then
        heartbeat = RunService.Heartbeat:Connect(refreshRestart)
    end
end

-- Records(S->C) 페이로드. 결과 화면이 열려 있지 않아도 저장해 두었다가 쓴다
function ResultV2.setRecords(payload)
    if type(payload) ~= "table" then
        return
    end
    records = payload
    if visible then
        refreshRanks()
    end
end

-- GameOver를 놓친 늦은 입장자: 상태만으로 최소 화면 (메달과 점수는 알 수 없어 중립 머리글, 기록, 재시작만.
-- partial = true면 refreshResult가 제목, 메달과 점수 칸, 감점, 우주 기상, 함께 한 일을 숨긴다)
function ResultV2.showFromState(state)
    if visible or type(state) ~= "table" then
        return
    end
    ResultV2.show({
        partial = true,
        won = false,
        medal = nil,
        day = state.day,
        score = nil,
        deductions = {},
        crew = {},
        missionId = state.missionId,
        mode = state.mode,
        chooserUserId = state.chooserUserId,
    })
end

function ResultV2.hide()
    if not visible then
        return
    end
    visible = false
    gui.Enabled = false
    fadeToken += 1
    contentRoot.Parent = fadeGroup
    result = nil
    if heartbeat then
        heartbeat:Disconnect()
        heartbeat = nil
    end
end

function ResultV2.isVisible()
    return visible
end

return ResultV2
