--!strict
-- 기지 안 실물 기록판 "명예의 전당" (2026-10-19 16차).
-- 기지가 놓이면(onBasePlaced) Base 아래에 RecordBoard 파트(어두운 판 + 노란 테두리 + 다리 2개)와 SurfaceGui를 만든다.
-- 자리와 크기는 DevMap.RECORD_BOARD(Origin 기준 로컬 좌표). Records 목록이 바뀌면 글자만 갱신한다.
-- 서버가 SurfaceGui 텍스트를 바꾸면 복제되므로 클라이언트 코드는 없다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Ranking = require(ReplicatedStorage.Shared.Ranking)
local DevMap = require(script.Parent.DevMap)
local Records = require(script.Parent.Records)

local RecordBoard = {}

local PIXELS_PER_STUD = 50
local BOARD_COLOR = Color3.fromRGB(14, 18, 32)
local TRIM_COLOR = Color3.fromRGB(255, 214, 64) -- 에너지 노랑 (충전 패드 테두리와 같은 계열)
local LEG_COLOR = Color3.fromRGB(70, 74, 84)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local DIM_COLOR = Color3.fromRGB(165, 175, 200)
-- 판 10 x 6 studs = 500 x 300 px. 제목 46 + 줄 5 x 32 + 상태 24 + 간격 6 x 6 + 위아래 여백 22 = 288
local TITLE_HEIGHT, TITLE_SIZE = 46, 40
local LINE_HEIGHT, LINE_MAX_SIZE = 32, 26 -- 긴 줄은 TextScaled로 줄여 한 줄에 넣는다
local STATUS_HEIGHT, STATUS_SIZE = 24, 18
local GAP = 6

local board: Part? = nil
local lineLabels: { TextLabel } = {}
local statusLabel: TextLabel? = nil

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3): Part
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = cframe
    part.Color = color
    part.Material = Enum.Material.SmoothPlastic
    part.Anchored = true
    part.CanCollide = true
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    return part
end

local function makeLabel(
    name: string,
    order: number,
    height: number,
    textSize: number,
    color: Color3
): TextLabel
    local label = Instance.new("TextLabel")
    label.Name = name
    label.LayoutOrder = order
    label.Size = UDim2.new(1, 0, 0, height)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = textSize
    label.TextColor3 = color
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Text = ""
    return label
end

-- 글자 갱신 (Records.onChanged에도 연결)
function RecordBoard.refresh()
    if not board or #lineLabels == 0 then
        return
    end
    local entries, status = Records.get()
    local t = Config.TEXTS
    for i, label in lineLabels do
        local entry = entries[i]
        if entry then
            label.Text = Ranking.formatLine(entry, i, Config)
            label.TextColor3 = if i == 1 then TRIM_COLOR else TEXT_COLOR
        elseif i == 1 then
            label.Text = if status == "loading" then t.recordsLoading else t.recordsEmpty
            label.TextColor3 = DIM_COLOR
        else
            label.Text = ""
        end
    end
    local statusText = statusLabel
    if statusText then
        statusText.Text = if status == "offline" then t.recordsOffline else ""
    end
end

-- 기지에 기록판을 만든다 (Origin이 없으면 기지 피벗 기준)
function RecordBoard.attach(base: Model)
    RecordBoard.detach()
    local spec = DevMap.RECORD_BOARD
    local origin = base.PrimaryPart
    local originCFrame = if origin then origin.CFrame else base:GetPivot()
    local size = spec.size
    local centerY = spec.groundY + spec.lift + size.Y / 2
    local localCenter = Vector3.new(spec.center.X, centerY, spec.center.Z)
    local localFace = Vector3.new(spec.faceToward.X, centerY, spec.faceToward.Z)
    -- 앞면(-Z, SurfaceGui Front)이 faceToward를 본다
    local boardCFrame = originCFrame * CFrame.lookAt(localCenter, localFace)

    local part = makePart("RecordBoard", size, boardCFrame, BOARD_COLOR)

    local trim = makePart(
        "Trim",
        Vector3.new(size.X + spec.trim * 2, size.Y + spec.trim * 2, size.Z * 0.5),
        boardCFrame * CFrame.new(0, 0, size.Z * 0.5),
        TRIM_COLOR
    )
    trim.Material = Enum.Material.Neon
    trim.CanCollide = false
    trim.Parent = part

    -- 다리: 테두리 아랫면에서 지면 아래 legEmbed까지
    local legHeight = spec.lift + spec.legEmbed - spec.trim
    local legY = -size.Y / 2 - spec.trim - legHeight / 2
    for i, side in { -1, 1 } do
        local leg = makePart(
            "Leg" .. i,
            Vector3.new(spec.legSize.X, legHeight, spec.legSize.Z),
            boardCFrame * CFrame.new(side * (size.X / 2 - spec.legInset), legY, size.Z * 0.5),
            LEG_COLOR
        )
        leg.Parent = part
    end

    local gui = Instance.new("SurfaceGui")
    gui.Name = "RecordGui"
    gui.Face = Enum.NormalId.Front
    gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud = PIXELS_PER_STUD
    gui.LightInfluence = 0 -- 달 그늘에서도 읽히게
    gui.Brightness = 1.5
    gui.Parent = part

    local root = Instance.new("Frame")
    root.Name = "Root"
    root.Size = UDim2.fromScale(1, 1)
    root.BackgroundTransparency = 1
    root.Parent = gui
    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 12)
    padding.PaddingBottom = UDim.new(0, 10)
    padding.PaddingLeft = UDim.new(0, 26)
    padding.PaddingRight = UDim.new(0, 26)
    padding.Parent = root
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, GAP)
    layout.Parent = root

    local title = makeLabel("Title", 1, TITLE_HEIGHT, TITLE_SIZE, TRIM_COLOR)
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Center
    title.Text = Config.TEXTS.recordsTitle
    title.Parent = root

    lineLabels = {}
    for i = 1, Config.RECORDS.showTop do
        local line = makeLabel("Line" .. i, 1 + i, LINE_HEIGHT, LINE_MAX_SIZE, TEXT_COLOR)
        line.TextScaled = true
        local limit = Instance.new("UITextSizeConstraint")
        limit.MaxTextSize = LINE_MAX_SIZE
        limit.Parent = line
        line.Parent = root
        table.insert(lineLabels, line)
    end
    local status =
        makeLabel("Status", 2 + Config.RECORDS.showTop, STATUS_HEIGHT, STATUS_SIZE, DIM_COLOR)
    status.TextXAlignment = Enum.TextXAlignment.Center
    status.Parent = root
    statusLabel = status

    part.Parent = base
    board = part
    RecordBoard.refresh()
end

-- 재시작: 기지와 함께 지운다
function RecordBoard.detach()
    local current = board
    board = nil
    lineLabels = {}
    statusLabel = nil
    if current then
        current:Destroy()
    end
end

-- 현재 기록판 (스모크 테스트용)
function RecordBoard.get(): Part?
    return board
end

return RecordBoard
