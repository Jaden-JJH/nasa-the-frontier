-- 아주 작은 테스트 하네스 (외부 라이브러리 없음). Lune 0.11에서 실행한다.

export type Harness = {
    test: (name: string, fn: () -> ()) -> (),
    eq: (actual: any, expected: any, label: string?) -> (),
    near: (actual: number, expected: number, label: string?) -> (),
    truthy: (value: any, label: string?) -> (),
    falsy: (value: any, label: string?) -> (),
    contains: (text: string, part: string, label: string?) -> (),
    report: () -> (number, number),
}

local EPSILON = 1e-6

local passed = 0
local failed = 0
local failures: { string } = {}

local function fail(message: string, label: string?)
    error((label and (label .. ": ") or "") .. message, 3)
end

local harness = {}

function harness.test(name: string, fn: () -> ())
    local ok, err = pcall(fn)
    if ok then
        passed += 1
        print("  통과  " .. name)
    else
        failed += 1
        table.insert(failures, name .. " -> " .. tostring(err))
        print("  실패  " .. name)
        print("        " .. tostring(err))
    end
end

function harness.eq(actual: any, expected: any, label: string?)
    if actual ~= expected then
        fail(
            string.format("기대값 %s, 실제값 %s", tostring(expected), tostring(actual)),
            label
        )
    end
end

function harness.near(actual: number, expected: number, label: string?)
    if typeof(actual) ~= "number" or math.abs(actual - expected) > EPSILON then
        fail(
            string.format("기대값 %s 근처, 실제값 %s", tostring(expected), tostring(actual)),
            label
        )
    end
end

function harness.truthy(value: any, label: string?)
    if not value then
        fail("참이어야 하는데 " .. tostring(value), label)
    end
end

function harness.falsy(value: any, label: string?)
    if value then
        fail("거짓이어야 하는데 " .. tostring(value), label)
    end
end

function harness.contains(text: string, part: string, label: string?)
    if typeof(text) ~= "string" or not string.find(text, part, 1, true) then
        fail(string.format("'%s' 안에 '%s'가 없음", tostring(text), part), label)
    end
end

function harness.report(): (number, number)
    print("")
    print(string.format("결과: 통과 %d, 실패 %d", passed, failed))
    for _, line in failures do
        print("  - " .. line)
    end
    return passed, failed
end

return harness
