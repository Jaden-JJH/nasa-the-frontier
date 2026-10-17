--!strict
-- KitImports: Studio에서 가져온 메시를 그레이박스 외형 대신 쓰기 위한 도우미 (docs/MAP_SPEC.md 간편 경로)
--
-- 사용자는 편집 중 Workspace.KitImports 폴더에 아래 이름으로 Model 또는 MeshPart를 넣어 둔다.
--   Rover, Lander, HabitatA, HabitatB, HabitatC, Panel, Rock1, Rock2, ...
-- 서버가 시작되면 load()가 이 폴더를 ServerStorage로 옮겨 플레이 중에는 보이지 않게 한다.
-- 이 이동은 플레이 세션 안에서만 일어나므로 Stop하면 편집 화면의 Workspace.KitImports는 그대로 남는다.
-- 원본은 절대 바꾸지 않고, take()가 돌려주는 복제본만 크기와 위치를 바꾼다.
-- 이름 오타, 잘못된 클래스, 빈 모델은 warn 한 줄로 알리고 무시한다 (DevMap이 그레이박스로 대체).
-- 각 항목에 number Attribute "Yaw"(도)를 주면 그 각도로 돌린 뒤 쓰고, 자동 방향 맞춤은 하지 않는다.

local ServerStorage = game:GetService("ServerStorage")

local KitImports = {}

local FOLDER_NAME = "KitImports"
local KNOWN_NAMES = { "Rover", "Lander", "HabitatA", "HabitatB", "HabitatC", "Panel" }
local ROCK_PATTERN = "^Rock(%d*)$"
local MIN_EXTENT = 0.01 -- 크기 계산에서 0으로 나누지 않도록 하는 최소 길이

local sources: { [string]: Instance } = {}
local rockSources: { Instance } = {}
local loaded = false

-- 기하 도우미 (외형 Model 전용) -----------------------------------------

-- 모델 안 모든 BasePart를 덮는 월드 축 정렬 경계 상자 (최소점, 최대점)
function KitImports.bounds(model: Instance): (Vector3, Vector3)
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local function addPart(part: BasePart)
        local cf, half = part.CFrame, part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local p = cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                    minX, minY, minZ = math.min(minX, p.X), math.min(minY, p.Y), math.min(minZ, p.Z)
                    maxX, maxY, maxZ = math.max(maxX, p.X), math.max(maxY, p.Y), math.max(maxZ, p.Z)
                end
            end
        end
    end
    if model:IsA("BasePart") then
        addPart(model)
    end
    for _, descendant in model:GetDescendants() do
        if descendant:IsA("BasePart") then
            addPart(descendant)
        end
    end
    return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

function KitImports.forEachPart(model: Instance, fn: (BasePart) -> ())
    for _, descendant in model:GetDescendants() do
        if descendant:IsA("BasePart") then
            fn(descendant)
        end
    end
end

-- 가장 큰 파트 (PrimaryPart 후보)
function KitImports.largestPart(model: Model): BasePart?
    local best: BasePart? = nil
    local bestVolume = -1
    KitImports.forEachPart(model, function(part)
        local volume = part.Size.X * part.Size.Y * part.Size.Z
        if volume > bestVolume then
            best, bestVolume = part, volume
        end
    end)
    return best
end

local function translate(model: Model, delta: Vector3)
    model:PivotTo(CFrame.new(delta) * model:GetPivot())
end

-- 경계 상자 중심을 기준으로 돌린다
function KitImports.rotateAboutCenter(model: Model, rotation: CFrame)
    local lo, hi = KitImports.bounds(model)
    local center = (lo + hi) / 2
    local around = CFrame.new(center) * rotation * CFrame.new(-center)
    model:PivotTo(around * model:GetPivot())
end

-- 현재 크기의 factor배로 균일 스케일
function KitImports.scaleBy(model: Model, factor: number)
    if factor > 0 and factor < math.huge then
        model:ScaleTo(model:GetScale() * factor)
    end
end

-- 경계 상자 바닥면 중심을 bottomCenter에 맞춘다
function KitImports.placeBottom(model: Model, bottomCenter: Vector3)
    local lo, hi = KitImports.bounds(model)
    local current = Vector3.new((lo.X + hi.X) / 2, lo.Y, (lo.Z + hi.Z) / 2)
    translate(model, bottomCenter - current)
end

-- box 안에 들어가도록 균일 스케일한 뒤 바닥면 중심을 bottomCenter에 맞춘다
function KitImports.fitInto(model: Model, box: Vector3, bottomCenter: Vector3)
    local lo, hi = KitImports.bounds(model)
    local size = hi - lo
    local factor = math.min(
        box.X / math.max(size.X, MIN_EXTENT),
        box.Y / math.max(size.Y, MIN_EXTENT),
        box.Z / math.max(size.Z, MIN_EXTENT)
    )
    KitImports.scaleBy(model, factor)
    KitImports.placeBottom(model, bottomCenter)
end

-- 수평 긴 축이 axis("X" 또는 "Z")를 향하도록 필요하면 90도 돌린다
function KitImports.alignLongAxis(model: Model, axis: "X" | "Z")
    local lo, hi = KitImports.bounds(model)
    local size = hi - lo
    local longIsX = size.X >= size.Z
    if (axis == "X") ~= longIsX then
        KitImports.rotateAboutCenter(model, CFrame.Angles(0, math.rad(90), 0))
    end
end

-- 고스트 외형: 반투명 단색, 충돌과 판정 없음
function KitImports.ghostify(model: Model, color: Color3, transparency: number)
    for _, descendant in model:GetDescendants() do
        if
            descendant:IsA("SurfaceAppearance")
            or descendant:IsA("Decal")
            or descendant:IsA("Texture")
        then
            descendant:Destroy()
        end
    end
    KitImports.forEachPart(model, function(part)
        part.Color = color
        part.Material = Enum.Material.SmoothPlastic
        part.Transparency = transparency
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.CastShadow = false
        if part:IsA("MeshPart") then
            part.TextureID = ""
        end
    end)
end

-- 불러오기 ---------------------------------------------------------------

local function hasParts(inst: Instance): boolean
    if inst:IsA("BasePart") then
        return true
    end
    for _, descendant in inst:GetDescendants() do
        if descendant:IsA("BasePart") then
            return true
        end
    end
    return false
end

local function isKnownName(name: string): boolean
    return table.find(KNOWN_NAMES, name) ~= nil or string.match(name, ROCK_PATTERN) ~= nil
end

local function rockNumber(inst: Instance): number
    return tonumber((string.match(inst.Name, ROCK_PATTERN))) or 0
end

-- 서버 시작 시 1회: Workspace.KitImports를 ServerStorage로 옮기고 항목을 검사한다
function KitImports.load()
    if loaded then
        return
    end
    loaded = true
    local folder = workspace:FindFirstChild(FOLDER_NAME)
    if folder then
        -- 플레이 중에는 보이지 않게 (Stop하면 편집 화면에는 그대로 남는다)
        folder.Parent = ServerStorage
    else
        folder = ServerStorage:FindFirstChild(FOLDER_NAME)
    end
    if not folder then
        return
    end
    for _, child in folder:GetChildren() do
        local name = child.Name
        if not isKnownName(name) then
            warn(
                string.format(
                    "[KitImports] '%s'는 알 수 없는 이름이라 무시합니다 (Rover, Lander, HabitatA, HabitatB, HabitatC, Panel, Rock1 ...)",
                    name
                )
            )
        elseif not (child:IsA("Model") or child:IsA("BasePart")) then
            warn(
                string.format(
                    "[KitImports] '%s'는 Model이나 MeshPart가 아니라(%s) 그레이박스를 씁니다",
                    name,
                    child.ClassName
                )
            )
        elseif not hasParts(child) then
            warn(
                string.format(
                    "[KitImports] '%s' 안에 파트가 없어 그레이박스를 씁니다",
                    name
                )
            )
        elseif string.match(name, ROCK_PATTERN) then
            table.insert(rockSources, child)
        elseif sources[name] then
            warn(
                string.format(
                    "[KitImports] '%s'가 두 개 있습니다. 첫 번째만 씁니다",
                    name
                )
            )
        else
            sources[name] = child
        end
    end
    table.sort(rockSources, function(a, b)
        return rockNumber(a) < rockNumber(b)
    end)
end

-- 이름에 해당하는 항목이 있는지
function KitImports.has(name: string): boolean
    if sources[name] then
        return true
    end
    return false
end

-- 원본을 복제해 외형용 Model로 돌려준다. 스크립트는 제거한다.
-- 두 번째 반환값은 원본에 Yaw Attribute가 있었는지 (있으면 자동 방향 맞춤을 건너뛴다)
local function cloneAsModel(source: Instance): (Model, boolean)
    local model: Model
    if source:IsA("Model") then
        model = source:Clone()
    else
        model = Instance.new("Model")
        model.Name = source.Name
        local part = source:Clone()
        part.Parent = model
        if part:IsA("BasePart") then
            model.PrimaryPart = part
        end
    end
    for _, descendant in model:GetDescendants() do
        if descendant:IsA("LuaSourceContainer") then
            descendant:Destroy()
        end
    end
    local yaw = source:GetAttribute("Yaw")
    local hasYaw = typeof(yaw) == "number" and yaw == yaw
    if hasYaw then
        KitImports.rotateAboutCenter(model, CFrame.Angles(0, math.rad(yaw :: number), 0))
    end
    return model, hasYaw
end

function KitImports.take(name: string): (Model?, boolean)
    local source = sources[name]
    if not source then
        return nil, false
    end
    return cloneAsModel(source)
end

-- Rock1, Rock2 ... 순서의 복제본 목록 (없으면 빈 목록)
function KitImports.takeRocks(): { Model }
    local result: { Model } = {}
    for _, source in rockSources do
        local model = cloneAsModel(source)
        table.insert(result, model)
    end
    return result
end

return KitImports
