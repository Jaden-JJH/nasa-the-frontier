--!strict
-- v2 미션 시계 (docs/CONTRACT_V2.md 2.2 MissionClock): MissionConfig.DAY_SECONDS(30초)마다 DayTick.
-- MissionFlow가 phase가 playing일 때만 start하고, 끝나거나 재시작하면 stop한다.
-- 하나의 task 루프가 절대 시각(nextTickAt, os.clock)을 기준으로 기다리므로 누적 오차가 없다.
-- onBeforeTick(seconds, fn): 하루가 끝나기 seconds초 전에 하루 한 번 부른다 (SEP 15초 전 경보, Q15).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MissionConfig = require(ReplicatedStorage.Shared.MissionConfig)
local ServerUtil = require(script.Parent.ServerUtil)

local MissionClock = {}

type BeforeHook = { seconds: number, fn: () -> (), firedFor: number }

local tickListeners: { () -> () } = {}
local beforeHooks: { BeforeHook } = {}
local running = false
local nextTickAt = 0
local tickCount = 0 -- 이번 판에서 보낸 DayTick 수 (훅이 하루 한 번만 불리게)
local generation = 0
local loopThread: thread? = nil

local function interval(): number
    return MissionConfig.DAY_SECONDS
end

local function fireTick()
    tickCount += 1
    for _, listener in tickListeners do
        ServerUtil.safeCall("MissionClock DayTick", listener)
    end
end

local function fireBefore(now: number)
    for _, hook in beforeHooks do
        if hook.firedFor ~= tickCount and nextTickAt - now <= hook.seconds then
            hook.firedFor = tickCount
            ServerUtil.safeCall("MissionClock BeforeTick", hook.fn)
        end
    end
end

-- 다음에 깨어날 시각: 다음 DayTick과 아직 안 부른 훅 시각 중 가장 이른 것
local function nextWake(): number
    local wake = nextTickAt
    for _, hook in beforeHooks do
        if hook.firedFor ~= tickCount then
            wake = math.min(wake, nextTickAt - hook.seconds)
        end
    end
    return wake
end

local function loop(myGeneration: number)
    while running and myGeneration == generation do
        local now = os.clock()
        fireBefore(now)
        if not running or myGeneration ~= generation then
            break
        end
        if now >= nextTickAt then
            nextTickAt += interval()
            fireTick()
        else
            local remaining = nextWake() - now
            task.wait(math.max(remaining, 0))
        end
    end
end

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

-- DayTick 구독. 등록 순서대로 부른다
function MissionClock.onDayTick(listener: () -> ())
    table.insert(tickListeners, listener)
end

-- 하루가 끝나기 seconds초 전에 하루 한 번
function MissionClock.onBeforeTick(seconds: number, fn: () -> ())
    table.insert(beforeHooks, { seconds = seconds, fn = fn, firedFor = -1 })
end

-- 시계 시작. 첫 DayTick은 한 간격 뒤
function MissionClock.start()
    running = true
    tickCount = 0
    for _, hook in beforeHooks do
        hook.firedFor = -1
    end
    nextTickAt = os.clock() + interval()
    restartLoop()
end

function MissionClock.stop()
    running = false
    restartLoop()
end

function MissionClock.isRunning(): boolean
    return running
end

-- 지금 하루가 끝나는 서버 시각 (workspace:GetServerTimeNow 기준, HUD 진행 표시용). 멈춰 있으면 nil
function MissionClock.dayEndsAt(): number?
    if not running then
        return nil
    end
    return workspace:GetServerTimeNow() + math.max(0, nextTickAt - os.clock())
end

return MissionClock
