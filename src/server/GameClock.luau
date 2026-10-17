--!strict
-- 게임 시계: Config.DAY_SECONDS / speed 초마다 DayTick을 보낸다 (CONTRACT 3절)
-- 하나의 task 루프가 절대 시각(nextTickAt)을 기준으로 기다리므로 누적 오차가 생기지 않는다.
-- phase가 playing일 때만 DayTick을 보낸다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ResourceState = require(script.Parent.ResourceState)
local ServerUtil = require(script.Parent.ServerUtil)

local GameClock = {}

local listeners: { () -> () } = {}
local running = false
local speed: number = Config.SPEEDS[1]
local nextTickAt = 0
local generation = 0 -- 루프 세대. 재시작하면 이전 루프는 스스로 끝난다
local loopThread: thread? = nil

local function interval(): number
    return Config.DAY_SECONDS / speed
end

local function fireDayTick()
    for _, listener in listeners do
        ServerUtil.safeCall("GameClock DayTick", listener)
    end
end

local function loop(myGeneration: number)
    while running and myGeneration == generation do
        local remaining = nextTickAt - os.clock()
        if remaining > 0 then
            task.wait(remaining)
        else
            nextTickAt += interval()
            if ResourceState.get().phase == "playing" then
                fireDayTick()
            end
        end
    end
end

-- 현재 루프를 끝내고 (실행 중이면) 새 루프를 시작한다
local function restartLoop()
    generation += 1
    local old = loopThread
    loopThread = nil
    if old and old ~= coroutine.running() and coroutine.status(old) == "suspended" then
        task.cancel(old)
    end
    if running then
        loopThread = task.spawn(loop, generation)
    end
end

-- DayTick 구독. 등록 순서대로 호출된다
function GameClock.onDayTick(listener: () -> ())
    table.insert(listeners, listener)
end

-- 시계 시작. 첫 DayTick은 한 간격 뒤
function GameClock.start(newSpeed: number?)
    if newSpeed then
        speed = newSpeed
    end
    running = true
    nextTickAt = os.clock() + interval()
    restartLoop()
end

function GameClock.stop()
    running = false
    restartLoop()
end

-- 배속 변경. 진행 중인 하루의 남은 시간을 새 배속에 맞춰 줄이거나 늘린다
function GameClock.setSpeed(newSpeed: number)
    if newSpeed == speed then
        return
    end
    if running then
        local now = os.clock()
        local remaining = math.max(0, nextTickAt - now)
        nextTickAt = now + remaining * speed / newSpeed
        speed = newSpeed
        restartLoop()
    else
        speed = newSpeed
    end
end

function GameClock.isRunning(): boolean
    return running
end

return GameClock
