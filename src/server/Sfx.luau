--!strict
-- 서버 효과음 헬퍼 (2026-10-18). 음원은 Shared.SoundIds 카탈로그(키별 id, volume, pitchJitter, loop).
-- id가 0이거나 키가 없으면 Sound를 만들지 않고 조용히 건너뛴다 (카탈로그를 채우는 중에도 오류 없음).
--   Sfx.play(key, parent, opts?) -> Sound?   한 번 재생 후 지운다. pitchJitter 적용, RollOffMaxDistance 기본 Config.SFX
--   Sfx.loop(key, parent, opts?) -> Handle   반복 재생. 무음 키도 핸들은 돌려준다 (stop은 그냥 아무 일도 안 함)
--   Sfx.setLoopSpeed(handle, speed), Sfx.setLoopVolume(handle, volume)
--   Sfx.stopAll()                            재시작 때 남은 루프를 모두 멈추고 지운다

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local SoundIds = require(ReplicatedStorage.Shared.SoundIds)

export type Options = {
    volume: number?, -- 카탈로그 볼륨 대신
    rollOff: number?, -- RollOffMaxDistance
    speed: number?, -- 기본 PlaybackSpeed (pitchJitter는 여기에 더한다)
}

export type Handle = {
    key: string,
    sound: Sound?,
    stop: () -> (),
}

local Sfx = {}

local rng = Random.new()
local loops: { [Handle]: boolean } = {}

-- 키의 카탈로그 항목 (없거나 id 0이면 nil)
local function specOf(key: string): SoundIds.SoundSpec?
    local spec = (SoundIds :: any)[key]
    if typeof(spec) ~= "table" or typeof(spec.id) ~= "number" or spec.id <= 0 then
        return nil
    end
    return spec
end

-- 재생 가능한 키인지 (테스트와 진단용)
function Sfx.enabled(key: string): boolean
    return specOf(key) ~= nil
end

local function makeSound(
    key: string,
    spec: SoundIds.SoundSpec,
    parent: Instance,
    opts: Options?
): Sound
    local sound = Instance.new("Sound")
    sound.Name = "Sfx_" .. key
    sound.SoundId = "rbxassetid://" .. tostring(spec.id)
    sound.Volume = if opts and opts.volume then opts.volume else spec.volume
    local jitter = spec.pitchJitter
    local base = if opts and opts.speed then opts.speed else 1
    sound.PlaybackSpeed = if jitter > 0 then base + rng:NextNumber(-jitter, jitter) else base
    sound.RollOffMaxDistance = if opts and opts.rollOff
        then opts.rollOff
        else Config.SFX.rollOffMaxDistance
    sound.Parent = parent
    return sound
end

function Sfx.play(key: string, parent: Instance?, opts: Options?): Sound?
    local spec = specOf(key)
    if not spec or not parent then
        return nil
    end
    local sound = makeSound(key, spec, parent, opts)
    sound.Looped = false
    sound.Ended:Once(function()
        sound:Destroy()
    end)
    task.delay(Config.SFX.oneShotLifetime, function()
        if sound.Parent then
            sound:Destroy()
        end
    end)
    sound:Play()
    return sound
end

function Sfx.loop(key: string, parent: Instance?, opts: Options?): Handle
    local spec = specOf(key)
    local sound: Sound? = nil
    if spec and parent then
        local s = makeSound(key, spec, parent, opts)
        s.Looped = true
        s:Play()
        sound = s
    end
    local handle: Handle
    handle = {
        key = key,
        sound = sound,
        stop = function()
            loops[handle] = nil
            local current = handle.sound
            handle.sound = nil
            if current then
                -- 부모(로버 등)와 함께 이미 지워졌을 수 있다
                pcall(function()
                    current:Stop()
                    current:Destroy()
                end)
            end
        end,
    }
    loops[handle] = true
    return handle
end

function Sfx.setLoopSpeed(handle: Handle?, speed: number)
    local sound = handle and handle.sound
    if sound then
        sound.PlaybackSpeed = speed
    end
end

function Sfx.setLoopVolume(handle: Handle?, volume: number)
    local sound = handle and handle.sound
    if sound then
        sound.Volume = volume
    end
end

-- 카탈로그 볼륨 (무음 키면 0)
function Sfx.baseVolume(key: string): number
    local spec = specOf(key)
    return if spec then spec.volume else 0
end

-- 살아 있는 루프 수 (테스트용)
function Sfx.loopCount(): number
    local n = 0
    for _ in loops do
        n += 1
    end
    return n
end

function Sfx.stopAll()
    local list = {}
    for handle in loops do
        table.insert(list, handle)
    end
    for _, handle in list do
        handle.stop()
    end
end

return Sfx
