--!strict
-- 서버 공용 도우미: 인스턴스 찾기, ProximityPrompt 생성, 박스 판정

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local ServerUtil = {}

-- 이름으로 자식 BasePart 찾기 (없거나 BasePart가 아니면 nil)
function ServerUtil.findPart(parent: Instance?, name: string): BasePart?
    if not parent then
        return nil
    end
    local child = parent:FindFirstChild(name)
    if child and child:IsA("BasePart") then
        return child
    end
    return nil
end

-- 이름으로 자식 Model 찾기
function ServerUtil.findModel(parent: Instance?, name: string): Model?
    if not parent then
        return nil
    end
    local child = parent:FindFirstChild(name)
    if child and child:IsA("Model") then
        return child
    end
    return nil
end

export type PromptOptions = {
    actionText: string,
    objectText: string?,
    holdDuration: number,
    maxDistance: number?,
    enabled: boolean?,
}

-- CONTRACT 4절 공통 설정(RequiresLineOfSight false, MaxActivationDistance)을 적용한 프롬프트
function ServerUtil.makePrompt(parent: BasePart, options: PromptOptions): ProximityPrompt
    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = options.actionText
    prompt.ObjectText = options.objectText or ""
    prompt.HoldDuration = options.holdDuration
    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = options.maxDistance or Config.PROMPT.maxDistance
    prompt.Enabled = if options.enabled == nil then true else options.enabled
    prompt.Parent = parent
    return prompt
end

-- 점이 파트의 회전된 박스 안에 있는지
function ServerUtil.isInsidePart(part: BasePart, point: Vector3): boolean
    local localPoint = part.CFrame:PointToObjectSpace(point)
    local half = part.Size / 2
    return math.abs(localPoint.X) <= half.X
        and math.abs(localPoint.Y) <= half.Y
        and math.abs(localPoint.Z) <= half.Z
end

-- 점에서 파트 박스 표면까지 거리 (안에 있으면 0)
function ServerUtil.distanceToPart(part: BasePart, point: Vector3): number
    local localPoint = part.CFrame:PointToObjectSpace(point)
    local half = part.Size / 2
    local clamped = Vector3.new(
        math.clamp(localPoint.X, -half.X, half.X),
        math.clamp(localPoint.Y, -half.Y, half.Y),
        math.clamp(localPoint.Z, -half.Z, half.Z)
    )
    return (localPoint - clamped).Magnitude
end

-- 오류가 나도 호출한 루프가 죽지 않도록 감싸서 실행하고, 오류는 출력 창에 남긴다
function ServerUtil.safeCall(label: string, fn: (...any) -> ...any, ...: any): boolean
    local results = table.pack(xpcall(fn, function(err: any): string
        return debug.traceback(tostring(err), 2)
    end, ...))
    if not results[1] then
        warn(string.format("[%s] 오류: %s", label, tostring(results[2])))
        return false
    end
    return true
end

-- 캐릭터에서 플레이어 찾기
function ServerUtil.playerFromHumanoid(humanoid: Humanoid?): Player?
    if not humanoid or not humanoid.Parent then
        return nil
    end
    return game:GetService("Players"):GetPlayerFromCharacter(humanoid.Parent)
end

-- 좌석에서 내리게 한다 (SeatWeld 제거, Sit 해제)
function ServerUtil.unseat(humanoid: Humanoid?)
    if not humanoid then
        return
    end
    local seatPart = humanoid.SeatPart
    if seatPart then
        local weld = seatPart:FindFirstChild("SeatWeld")
        if weld then
            weld:Destroy()
        end
    end
    humanoid.Sit = false
end

-- 플레이어 캐릭터를 좌석에서 내리게 한다
function ServerUtil.unseatPlayer(player: Player)
    local character = player.Character
    if character then
        ServerUtil.unseat(character:FindFirstChildOfClass("Humanoid"))
    end
end

-- 현재 배치된 기지 모델 (Workspace.Base)
function ServerUtil.getBase(): Model?
    return ServerUtil.findModel(workspace, "Base")
end

-- 기지 로버의 DriverSeat
function ServerUtil.getRoverSeat(): VehicleSeat?
    local rover = ServerUtil.findModel(ServerUtil.getBase(), "Rover")
    if not rover then
        return nil
    end
    local seat = rover:FindFirstChild("DriverSeat")
    if seat and seat:IsA("VehicleSeat") then
        return seat
    end
    return nil
end

return ServerUtil
