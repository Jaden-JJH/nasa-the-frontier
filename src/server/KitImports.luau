--!strict
-- KitImports: Studio에서 가져온 메시를 그레이박스 외형 대신 쓰기 위한 도우미 (docs/MAP_SPEC.md 간편 경로)
--
-- 사용자는 편집 중 Workspace.KitImports 폴더에 아래 이름으로 Model 또는 MeshPart를 넣어 둔다.
--   기지 외형: Rover, Lander, HabitatA, HabitatB, HabitatC, Panel, Rock1, Rock2, ...
--   장식(선택): Planet, IceCrystal, WaterTank, Pad, Antenna, Radar, Crate (DevMap이 조립 때 사용)
--               Connector, Crop (모듈이 완공될 때 onModuleActivated가 Base 아래에 배치)
--               ConnectorElbow (이름은 받아 두지만 아직 쓰지 않는다. 직선 통로만 놓는다)
-- 장식은 모두 외형 전용이고, 없으면 아무 것도 하지 않는다.
-- 서버가 시작되면 load()가 이 폴더를 ServerStorage로 옮겨 플레이 중에는 보이지 않게 한다.
-- 이 이동은 플레이 세션 안에서만 일어나므로 Stop하면 편집 화면의 Workspace.KitImports는 그대로 남는다.
-- 원본은 절대 바꾸지 않고, take()가 돌려주는 복제본만 크기와 위치를 바꾼다.
-- 이름 오타, 잘못된 클래스, 빈 모델은 warn 한 줄로 알리고 무시한다 (DevMap이 그레이박스로 대체).
-- 각 항목에 number Attribute "Yaw"(도)를 주면 그 각도로 돌린 뒤 쓰고, 자동 방향 맞춤은 하지 않는다.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local KitImports = {}

local FOLDER_NAME = "KitImports"
local KNOWN_NAMES = {
    "Rover",
    "Lander",
    "HabitatA",
    "HabitatB",
    "HabitatC",
    "Panel",
    "Planet",
    "IceCrystal",
    "WaterTank",
    "Connector",
    "ConnectorElbow",
    "Pad",
    "Antenna",
    "Radar",
    "Crate",
    "Crop",
}
local ROCK_PATTERN = "^Rock(%d*)$"
local MIN_EXTENT = 0.01 -- 크기 계산에서 0으로 나누지 않도록 하는 최소 길이

-- 런타임 장식 상수 (studs, 도) --------------------------------------------
local DECOR_FOLDER = "Decor" -- Workspace.Decor: 재시작해도 남는 장식 (Planet)
local BASE_DECOR_FOLDER = "KitDecor" -- Base.KitDecor: 재시작 때 Base와 함께 사라지는 장식
local PLANET_DISTANCE = 1500 -- 맵 원점에서 행성 중심까지
local PLANET_ELEVATION = 25 -- 고도각
local PLANET_AZIMUTH = 20 -- 방위각 (+Z에서 +X 쪽으로). 착륙 패드 대부분이 +Z를 바라본다
local PLANET_DIAMETER = 400
-- 자정 조명에는 직사광이 없어 행성이 어두우므로 Neon으로 스스로 빛나게 한다. TextureID는 그대로 두고,
-- Neon이 텍스처를 덮어 단색으로 보이는 경우에 대비해 색은 지구 바다빛 계열로
local PLANET_GLOW_COLOR = Color3.fromRGB(120, 170, 230)
local CONNECTOR_WIDTH = 4 -- 통로 튜브 굵기. 길이 방향으로는 늘리지 않고 세그먼트를 이어 붙인다
local CONNECTOR_PAIRS = { { "A", "B" }, { "B", "C" } } -- 둘 다 가동되면 잇는다
local CROP_MODULE = "B" -- 작물을 심는 모듈 (Farm)
local CROP_SIZE = 2
local CROP_MARGIN = 2.5 -- Built 경계에서 작물 원까지 여유
-- 앞쪽(-Z) 반원에 심되, 정면 A-B 통로와 겹치지 않도록 가운데를 비운 양쪽 각도 (도)
local CROP_ANGLES = { -85, -68, -51, -34, 34, 51, 68, 85 }
local GROUND_PROBE_UP, GROUND_PROBE_DEPTH = 20, 60 -- 지면 탐색 광선 시작 높이와 길이

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

-- frame 기준 좌표계에서 모델을 덮는 경계 상자 (회전된 기지 안에서 계산할 때)
function KitImports.boundsIn(model: Instance, frame: CFrame): (Vector3, Vector3)
    local lo = Vector3.new(math.huge, math.huge, math.huge)
    local hi = -lo
    local function addPart(part: BasePart)
        local cf, half = part.CFrame, part.Size / 2
        for _, sx in { -1, 1 } do
            for _, sy in { -1, 1 } do
                for _, sz in { -1, 1 } do
                    local p = frame:PointToObjectSpace(
                        cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z)
                    )
                    lo = Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
                    hi = Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
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
    return lo, hi
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

-- 경계 상자 중심을 center에 맞춘다
function KitImports.placeCenter(model: Model, center: Vector3)
    local lo, hi = KitImports.bounds(model)
    translate(model, center - (lo + hi) / 2)
end

-- 외형 파트 공통 설정: 고정, 충돌 여부, 판정 제외
function KitImports.setStatic(model: Model, canCollide: boolean)
    KitImports.forEachPart(model, function(part)
        part.Anchored = true
        part.CanCollide = canCollide
        part.CanQuery = canCollide
        part.CanTouch = false
    end)
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

-- 앞뒤(Z) 길이가 length가 되도록 균일 스케일한 뒤 바닥면 중심을 bottomCenter에 맞춘다 (높이 제한 없음)
function KitImports.fitLength(model: Model, length: number, bottomCenter: Vector3)
    local lo, hi = KitImports.bounds(model)
    KitImports.scaleBy(model, length / math.max(hi.Z - lo.Z, MIN_EXTENT))
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

-- 텍스처를 걷어 내고 단색 재질로 칠한다 (얼음 덩어리, 회색 바위)
function KitImports.recolor(
    model: Instance,
    color: Color3,
    material: Enum.Material,
    transparency: number?
)
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
        part.Material = material
        if transparency ~= nil then
            part.Transparency = transparency
        end
        if part:IsA("MeshPart") then
            part.TextureID = ""
        end
    end)
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
                    "[KitImports] '%s'는 알 수 없는 이름이라 무시합니다 (가능한 이름: %s, Rock1 ...)",
                    name,
                    table.concat(KNOWN_NAMES, ", ")
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

-- 런타임 장식 ------------------------------------------------------------

local function getFolder(parent: Instance, name: string): Folder
    local existing = parent:FindFirstChild(name)
    if existing and existing:IsA("Folder") then
        return existing
    end
    local folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

-- 기지 기준 좌표계 (Origin, 없으면 Base 피벗)
local function baseFrame(base: Model): CFrame
    local origin = base.PrimaryPart
    if origin then
        return origin.CFrame
    end
    return base:GetPivot()
end

-- frame 기준 (x, z) 위치의 지면 높이 (frame 기준 y). 못 찾으면 nil
local function groundYAt(frame: CFrame, x: number, z: number, exclude: { Instance }): number?
    for _, player in Players:GetPlayers() do
        if player.Character then
            table.insert(exclude, player.Character)
        end
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclude
    local origin = frame * Vector3.new(x, GROUND_PROBE_UP, z)
    local direction = frame:VectorToWorldSpace(Vector3.new(0, -GROUND_PROBE_DEPTH, 0))
    local result = workspace:Raycast(origin, direction, params)
    if not result then
        return nil
    end
    return frame:PointToObjectSpace(result.Position).Y
end

-- 서버 시작 시: 하늘에 거대한 행성 하나 (Workspace.Decor.Planet). 이미 있으면 건너뛴다
function KitImports.ensurePlanet()
    local decor = workspace:FindFirstChild(DECOR_FOLDER)
    if decor and decor:FindFirstChild("Planet") then
        return
    end
    local planet = KitImports.take("Planet")
    if not planet then
        return
    end
    KitImports.fitInto(planet, Vector3.one * PLANET_DIAMETER, Vector3.zero)
    local elevation, azimuth = math.rad(PLANET_ELEVATION), math.rad(PLANET_AZIMUTH)
    local direction = Vector3.new(
        math.cos(elevation) * math.sin(azimuth),
        math.sin(elevation),
        math.cos(elevation) * math.cos(azimuth)
    )
    KitImports.placeCenter(planet, direction * PLANET_DISTANCE)
    KitImports.forEachPart(planet, function(part)
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        part.CastShadow = false
        part.Material = Enum.Material.Neon
        part.Color = PLANET_GLOW_COLOR
    end)
    planet.Name = "Planet"
    -- 멀리 있어도 클라이언트에 항상 스트리밍되게
    planet.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
    planet.Parent = getFolder(workspace, DECOR_FOLDER)
end

-- 활성화된 모듈의 Built (Pad 아래에 붙어 있을 때만)
local function findBuilt(base: Model, moduleId: string): Instance?
    local pads = base:FindFirstChild("ModulePads")
    local padModel = pads and pads:FindFirstChild("Pad" .. moduleId)
    local built = padModel and padModel:FindFirstChild("Built")
    if built and built.Parent then
        return built
    end
    return nil
end

-- 중심에서 dir 방향으로 xz 경계 상자 가장자리까지 거리
local function exitDistance(dir: Vector3, lo: Vector3, hi: Vector3): number
    local hx, hz = (hi.X - lo.X) / 2, (hi.Z - lo.Z) / 2
    local tx = if math.abs(dir.X) > MIN_EXTENT then hx / math.abs(dir.X) else math.huge
    local tz = if math.abs(dir.Z) > MIN_EXTENT then hz / math.abs(dir.Z) else math.huge
    return math.min(tx, tz)
end

-- 두 모듈 Built 사이 직선 통로. Connector 세그먼트를 길이 방향으로 이어 붙인다
local function buildConnector(base: Model, a: string, b: string)
    local decor = getFolder(base, BASE_DECOR_FOLDER)
    local name = "Connector" .. a .. b
    if decor:FindFirstChild(name) then
        return
    end
    local builtA, builtB = findBuilt(base, a), findBuilt(base, b)
    local template, yawSet = KitImports.take("Connector")
    if not builtA or not builtB or not template then
        return
    end
    -- 세그먼트 원본: 긴 축을 Z로, 굵기를 CONNECTOR_WIDTH로, 중심을 원점에
    if not yawSet then
        KitImports.alignLongAxis(template, "Z")
    end
    local tLo, tHi = KitImports.bounds(template)
    KitImports.scaleBy(template, CONNECTOR_WIDTH / math.max(tHi.X - tLo.X, MIN_EXTENT))
    KitImports.placeCenter(template, Vector3.zero)
    tLo, tHi = KitImports.bounds(template)
    local segment = math.max(tHi.Z - tLo.Z, MIN_EXTENT)
    local height = tHi.Y - tLo.Y

    local frame = baseFrame(base)
    local loA, hiA = KitImports.boundsIn(builtA, frame)
    local loB, hiB = KitImports.boundsIn(builtB, frame)
    local centerA = Vector3.new((loA.X + hiA.X) / 2, 0, (loA.Z + hiA.Z) / 2)
    local centerB = Vector3.new((loB.X + hiB.X) / 2, 0, (loB.Z + hiB.Z) / 2)
    local delta = centerB - centerA
    if delta.Magnitude < MIN_EXTENT then
        template:Destroy()
        return
    end
    local dir = delta.Unit
    local startPoint = centerA + dir * exitDistance(dir, loA, hiA)
    local endPoint = centerB - dir * exitDistance(dir, loB, hiB)
    local gap = (endPoint - startPoint):Dot(dir)
    if gap <= 0 then
        template:Destroy()
        return
    end
    -- 모듈 바닥 높이, 사이 지면이 더 낮으면 지면에 맞춘다
    local floorY = math.max(loA.Y, loB.Y)
    local middle = (startPoint + endPoint) / 2
    local ground = groundYAt(frame, middle.X, middle.Z, { decor, builtA, builtB })
    local bottomY = if ground then math.min(floorY, ground) else floorY
    local centerY = bottomY + height / 2

    local model = Instance.new("Model")
    model.Name = name
    local count = math.max(1, math.ceil(gap / segment))
    local step = if count > 1 then (gap - segment) / (count - 1) else 0
    for i = 1, count do
        local along = if count > 1 then segment / 2 + (i - 1) * step else gap / 2
        local p = startPoint + dir * along
        local position = Vector3.new(p.X, centerY, p.Z)
        local piece = template:Clone()
        piece.Name = "Segment" .. i
        piece:PivotTo(frame * CFrame.lookAt(position, position + dir) * piece:GetPivot())
        KitImports.setStatic(piece, false)
        piece.Parent = model
    end
    template:Destroy()
    model.Parent = decor
end

-- Farm 앞쪽 반원 바닥에 작물 심기
local function plantCrops(base: Model, moduleId: string)
    local decor = getFolder(base, BASE_DECOR_FOLDER)
    local name = "Crops" .. moduleId
    if decor:FindFirstChild(name) then
        return
    end
    local built = findBuilt(base, moduleId)
    local template = KitImports.take("Crop")
    if not built or not template then
        return
    end
    KitImports.fitInto(template, Vector3.one * CROP_SIZE, Vector3.zero)
    KitImports.setStatic(template, false)
    local frame = baseFrame(base)
    local lo, hi = KitImports.boundsIn(built, frame)
    local center = Vector3.new((lo.X + hi.X) / 2, 0, (lo.Z + hi.Z) / 2)
    local radius = math.max(hi.X - lo.X, hi.Z - lo.Z) / 2 + CROP_MARGIN
    local model = Instance.new("Model")
    model.Name = name
    for i, angle in CROP_ANGLES do
        local theta = math.rad(angle)
        -- 앞쪽 = 기지 기준 -Z
        local x = center.X + math.sin(theta) * radius
        local z = center.Z - math.cos(theta) * radius
        local ground = groundYAt(frame, x, z, { decor, built })
        local bottom = Vector3.new(x, ground or lo.Y, z)
        local crop = template:Clone()
        crop.Name = "Crop" .. i
        KitImports.rotateAboutCenter(crop, CFrame.Angles(0, theta, 0))
        KitImports.placeBottom(crop, Vector3.zero)
        crop:PivotTo(frame * CFrame.new(bottom) * crop:GetPivot())
        crop.Parent = model
    end
    template:Destroy()
    model.Parent = decor
end

-- Construction이 모듈 완공 순간에 부른다. isActive(id)는 그 시점 상태 기준
function KitImports.onModuleActivated(moduleId: string, base: Model, isActive: (string) -> boolean)
    for _, pair in CONNECTOR_PAIRS do
        local a, b = pair[1], pair[2]
        if (moduleId == a or moduleId == b) and isActive(a) and isActive(b) then
            buildConnector(base, a, b)
        end
    end
    if moduleId == CROP_MODULE then
        plantCrops(base, moduleId)
    end
end

return KitImports
