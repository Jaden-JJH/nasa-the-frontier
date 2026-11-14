--!strict
-- v2 ProximityPrompt 도우미 (docs/CONTRACT_V2.md 3절 Attribute 키 프로토콜)
-- 서버는 프롬프트에 문장을 쓰지 않는다. ActionText, ObjectText는 비워 두고 Attribute만 쓴다.
--   ActionKey, ObjectKey: 문구 키 (i18n/strings.csv)
--   ActionArgs, ObjectArgs: Msg args의 JSON 문자열 (없으면 Attribute를 지운다)
--   CooldownUntil: 서버 시각(workspace:GetServerTimeNow 기준, 선택)
--   CostEnergy, CostWater, BuildDays, Affordable, LockMsg: 자원을 쓰는 프롬프트의 비용 표시 (setCost)
-- 클라이언트 PromptUI가 Attribute 변화를 구독해 현재 언어로 그린다.
-- Interactions, RoverFleet, AirlockDoors가 같이 쓴다 (서로 require하지 않도록 따로 둔 모듈).

local HttpService = game:GetService("HttpService")

export type Args = { [string]: any }

export type Spec = {
    name: string?,
    actionKey: string,
    actionArgs: Args?,
    objectKey: string?,
    objectArgs: Args?,
    hold: number?,
    distance: number?,
    keyCode: Enum.KeyCode?,
    enabled: boolean?,
}

local PromptKit = {}

-- 엔진 수준 기본값 (studs, 초)
PromptKit.CONFIG = {
    defaultDistance = 10,
}

-- Msg args를 JSON 문자열로 (없거나 비어 있으면 nil)
function PromptKit.encode(args: Args?): string?
    if args == nil or next(args) == nil then
        return nil
    end
    local ok, text = pcall(function()
        return HttpService:JSONEncode(args)
    end)
    if not ok then
        warn("[PromptKit] JSONEncode 실패: " .. tostring(text))
        return nil
    end
    return text
end

local function setAttr(inst: Instance, name: string, value: any)
    if inst:GetAttribute(name) ~= value then
        inst:SetAttribute(name, value)
    end
end

-- 키와 값을 바꾼다 (같은 값이면 쓰지 않아 복제가 생기지 않는다)
function PromptKit.set(
    prompt: ProximityPrompt,
    actionKey: string,
    actionArgs: Args?,
    objectKey: string?,
    objectArgs: Args?
)
    setAttr(prompt, "ActionKey", actionKey)
    setAttr(prompt, "ActionArgs", PromptKit.encode(actionArgs))
    if objectKey ~= nil then
        setAttr(prompt, "ObjectKey", objectKey)
    end
    setAttr(prompt, "ObjectArgs", PromptKit.encode(objectArgs))
end

function PromptKit.setEnabled(prompt: ProximityPrompt, enabled: boolean)
    if prompt.Enabled ~= enabled then
        prompt.Enabled = enabled
    end
end

function PromptKit.setHold(prompt: ProximityPrompt, seconds: number)
    if prompt.HoldDuration ~= seconds then
        prompt.HoldDuration = seconds
    end
end

-- 쿨다운 끝 서버 시각 (nil이면 지운다)
function PromptKit.setCooldown(prompt: ProximityPrompt, untilTime: number?)
    setAttr(prompt, "CooldownUntil", untilTime)
end

-- 비용 표시 (2026-11-15 시험 피드백: 무엇이 얼마인지 안 보였다). 숫자는 호출한 쪽이 MissionConfig, Rules에서 읽는다
--   CostEnergy, CostWater: number, 0이면 Attribute를 지운다 (클라이언트는 nil을 0으로 본다)
--   BuildDays: number, 건설을 시작하는 프롬프트에만
--   Affordable: boolean, 지금 기지 자원으로 낼 수 있는지 (비용이나 BuildDays가 있을 때만, 상태를 모르면 nil)
--   LockMsg: 규칙상 잠겨 있으면 Msg의 JSON 문자열 { key, args } (예: toast.pipe.locked { need, done })
-- info가 nil이면 다섯 개 모두 지운다
export type CostInfo = {
    energy: number?,
    water: number?,
    buildDays: number?,
    affordable: boolean?,
    lock: { key: string, args: Args? }?,
}

function PromptKit.setCost(prompt: ProximityPrompt, info: CostInfo?)
    local energy = if info and info.energy and info.energy > 0 then info.energy else nil
    local water = if info and info.water and info.water > 0 then info.water else nil
    local days = if info then info.buildDays else nil
    local costed = energy ~= nil or water ~= nil or days ~= nil
    setAttr(prompt, "CostEnergy", energy)
    setAttr(prompt, "CostWater", water)
    setAttr(prompt, "BuildDays", days)
    setAttr(prompt, "Affordable", if costed and info then info.affordable else nil)
    local lock = if info then info.lock else nil
    setAttr(prompt, "LockMsg", if lock then PromptKit.encode(lock :: any) else nil)
end

-- Attribute 프로토콜 프롬프트를 만든다. Style Custom, 시야 검사 없음
function PromptKit.make(parent: Instance, spec: Spec): ProximityPrompt
    local prompt = Instance.new("ProximityPrompt")
    prompt.Name = spec.name or "Prompt"
    prompt.ActionText = ""
    prompt.ObjectText = ""
    prompt.HoldDuration = spec.hold or 0
    prompt.RequiresLineOfSight = false
    prompt.Style = Enum.ProximityPromptStyle.Custom
    prompt.MaxActivationDistance = spec.distance or PromptKit.CONFIG.defaultDistance
    if spec.keyCode then
        prompt.KeyboardKeyCode = spec.keyCode
    end
    prompt.Enabled = if spec.enabled == nil then true else spec.enabled
    PromptKit.set(prompt, spec.actionKey, spec.actionArgs, spec.objectKey, spec.objectArgs)
    prompt.Parent = parent
    return prompt
end

-- 플레이어 캐릭터의 HumanoidRootPart 위치 (없으면 nil)
function PromptKit.rootPosition(player: Player): Vector3?
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root.CFrame.Position
    end
    return nil
end

-- 클라이언트 요청 거리 검사: 플레이어가 파트에서 limit 안에 있는지
function PromptKit.near(player: Player, part: BasePart?, limit: number): boolean
    if not part then
        return false
    end
    local position = PromptKit.rootPosition(player)
    if not position then
        return false
    end
    return (position - part.CFrame.Position).Magnitude <= limit
end

return PromptKit
