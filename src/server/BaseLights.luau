--!strict
-- 착륙 유도등 (2026-10-18, BASE_LAYOUT): Base.BaseLayout.GuideLights의 원판(Attribute GuideIndex 1..n).
-- 착륙 연출(LandingSequence) 동안 서버 루프가 1초 주기로 순서대로 밝히는 체이스, 끝나면 은은하게 고정.
-- 밝기는 Neon 원판의 Transparency로 표현한다 (수치는 DevMap BASE_LAYOUT.guide).

local DevMap = require(script.Parent.DevMap)
local ServerUtil = require(script.Parent.ServerUtil)

local BaseLights = {}

local discs: { BasePart } = {}
local generation = 0

-- 새 기지의 유도등을 모은다 (번호 순)
function BaseLights.attach(base: Model)
    BaseLights.detach()
    local layout = base:FindFirstChild("BaseLayout")
    local guides = layout and layout:FindFirstChild("GuideLights")
    if not guides then
        return
    end
    local list: { { index: number, part: BasePart } } = {}
    for _, child in guides:GetChildren() do
        local index = child:GetAttribute("GuideIndex")
        if child:IsA("BasePart") and typeof(index) == "number" then
            table.insert(list, { index = index, part = child })
        end
    end
    table.sort(list, function(a, b)
        return a.index < b.index
    end)
    for _, entry in list do
        table.insert(discs, entry.part)
    end
end

local function setSteady()
    for _, disc in discs do
        disc.Transparency = DevMap.GUIDE.steadyTransparency
    end
end

-- t초 시점의 체이스 밝기 (i번째 원판). 켜진 구간이면 onTransparency, 아니면 offTransparency
function BaseLights.chaseTransparency(i: number, count: number, t: number): number
    local g = DevMap.GUIDE
    local phase = (t / g.period - (i - 1) / count) % 1
    return if phase < g.litFraction then g.onTransparency else g.offTransparency
end

-- seconds초 동안 체이스, 그 뒤 은은하게 고정
function BaseLights.playLanding(seconds: number)
    generation += 1
    local myGeneration = generation
    local g = DevMap.GUIDE
    task.spawn(function()
        local start = os.clock()
        while myGeneration == generation and os.clock() - start < seconds do
            local t = os.clock() - start
            for i, disc in discs do
                disc.Transparency = BaseLights.chaseTransparency(i, #discs, t)
            end
            task.wait(1 / g.hz)
        end
        if myGeneration == generation then
            ServerUtil.safeCall("BaseLights", setSteady)
        end
    end)
end

function BaseLights.detach()
    generation += 1
    table.clear(discs)
end

return BaseLights
