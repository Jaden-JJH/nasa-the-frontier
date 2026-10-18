-- Ranking 순수 로직 테스트 (2026-10-19 16차): 승리 기록 정렬, 동률, 상한, 순위, 잘못된 항목, 표시 문구

local Config = require("../src/shared/Config")
local Ranking = require("../src/shared/Ranking")

local function entry(days: number, at: number, crew: { string }?): any
    return {
        days = days,
        site = "Shackleton Rim",
        crew = crew or { "Alice" },
        at = at,
        version = 1,
    }
end

local function daysOf(list): string
    local parts = {}
    for _, e in list do
        table.insert(parts, tostring(e.days) .. "@" .. tostring(e.at))
    end
    return table.concat(parts, ",")
end

return function(t)
    t.test("랭킹: 소요 일수 오름차순으로 넣는다", function()
        local list = {}
        local rank
        list, rank = Ranking.insert(list, entry(40, 1), 10)
        t.eq(rank, 1, "빈 목록 첫 기록")
        list, rank = Ranking.insert(list, entry(30, 2), 10)
        t.eq(rank, 1, "더 빠른 기록은 1위")
        list, rank = Ranking.insert(list, entry(35, 3), 10)
        t.eq(rank, 2, "가운데")
        list, rank = Ranking.insert(list, entry(50, 4), 10)
        t.eq(rank, 4, "가장 느린 기록은 끝")
        t.eq(daysOf(list), "30@2,35@3,40@1,50@4")
    end)

    t.test("랭킹: 같은 일수면 먼저 세운 기록이 앞", function()
        local list = Ranking.insert({}, entry(32, 100), 10)
        local rank
        list, rank = Ranking.insert(list, entry(32, 200), 10)
        t.eq(rank, 2, "나중에 세운 같은 일수는 뒤")
        list, rank = Ranking.insert(list, entry(32, 50), 10)
        t.eq(rank, 1, "더 먼저 세운 같은 일수는 앞 (저장소 병합 순서와 무관)")
        t.eq(daysOf(list), "32@50,32@100,32@200")
        -- 저장소에서 섞인 순서로 와도 같은 결과
        local shuffled = { entry(32, 200), entry(31, 300), entry(32, 50), entry(32, 100) }
        t.eq(daysOf(Ranking.sanitize(shuffled, 10)), "31@300,32@50,32@100,32@200")
    end)

    t.test("랭킹: 상한 maxEntries, 밖이면 순위 nil", function()
        local list = {}
        for i = 1, 10 do
            list = Ranking.insert(list, entry(20 + i, i), 10)
        end
        t.eq(#list, 10)
        local same, rank = Ranking.insert(list, entry(31, 99), 10)
        t.eq(rank, nil, "10위(30일)보다 느리면 밖")
        t.eq(#same, 10)
        t.eq(same[10].days, 30, "목록은 그대로")
        local tie
        same, tie = Ranking.insert(list, entry(30, 99), 10)
        t.eq(tie, nil, "10위와 같은 일수라도 나중 기록이면 밖")
        local better
        list, better = Ranking.insert(list, entry(25, 99), 10)
        t.eq(better, 6, "25일은 21~25일 다음 6위")
        t.eq(#list, 10, "넣고도 10개")
        t.eq(list[10].days, 29, "가장 느린 30일이 밀려남")
        t.eq(Ranking.sanitize(list, 3)[3].days, 23, "sanitize도 상한을 지킨다")
    end)

    t.test("랭킹: 같은 기록을 두 번 넣지 않는다 (UpdateAsync 재시도)", function()
        local list, rank = Ranking.insert({}, entry(30, 7, { "A", "B" }), 10)
        local again, rank2 = Ranking.insert(list, entry(30, 7, { "A", "B" }), 10)
        t.eq(rank, 1)
        t.eq(rank2, 1, "이미 있으면 그 순위")
        t.eq(#again, 1, "중복 없음")
        local other = Ranking.insert(list, entry(30, 7, { "A", "C" }), 10)
        t.eq(#other, 2, "승무원이 다르면 다른 기록")
        t.eq(
            #Ranking.sanitize({ entry(30, 7), entry(30, 7) }, 10),
            1,
            "저장값 안의 중복도 하나로"
        )
    end)

    t.test("랭킹: 잘못된 항목은 무시한다", function()
        local raw = {
            entry(30, 1),
            { days = 0, site = "x", crew = {}, at = 1 }, -- 0일
            { days = 12.5, site = "x", crew = {}, at = 1 }, -- 정수 아님
            { days = 0 / 0, site = "x", crew = {}, at = 1 }, -- NaN
            { days = 20, site = 5, crew = {}, at = 1 }, -- 착륙지가 문자열 아님
            { days = 20, site = "x", crew = { 1 }, at = 1 }, -- 이름이 문자열 아님
            { days = 20, site = "x", crew = "Alice", at = 1 }, -- crew가 표 아님
            { days = 20, site = "x", crew = {} }, -- 시각 없음
            "broken",
            42,
        }
        local list = Ranking.sanitize(raw, 10)
        t.eq(#list, 1, "올바른 항목 하나만")
        t.eq(list[1].days, 30)
        t.eq(#Ranking.sanitize(nil, 10), 0, "저장값 없음(nil)은 빈 목록")
        t.eq(#Ranking.sanitize("text", 10), 0, "표가 아닌 저장값은 빈 목록")
        local kept, rank = Ranking.insert(list, { days = -3, site = "x", crew = {}, at = 2 }, 10)
        t.eq(rank, nil, "잘못된 새 항목은 순위 없음")
        t.eq(#kept, 1, "목록은 그대로")
        t.truthy(Ranking.isValid(entry(1, 0, {})), "승무원 0명도 올바른 형식")
    end)

    t.test("랭킹: 넣어도 원래 목록은 바뀌지 않는다", function()
        local list = Ranking.insert({}, entry(30, 1, { "A" }), 10)
        local before = daysOf(list)
        local new = Ranking.insert(list, entry(20, 2), 10)
        t.eq(daysOf(list), before, "원본 그대로")
        t.eq(#new, 2)
        new[2].crew[1] = "Z"
        t.eq(list[1].crew[1], "A", "crew도 복사")
    end)

    t.test(
        "랭킹 문구: 순위, 일수, 착륙지, 승무원 2명 + 외 n명, 한국 시간 월/일",
        function()
            -- 2026-10-18 20:00 UTC = 2026-10-19 05:00 KST
            local e = entry(32, 1792353600, { "Alice", "Bob", "Carol" })
            t.eq(
                Ranking.formatLine(e, 1, Config),
                "1위  32일  Shackleton Rim  Alice, Bob 외 1명  10/19"
            )
            local two = entry(40, 1792332000, { "Alice", "Bob" }) -- 14:00 UTC = 23:00 KST 같은 날
            t.eq(
                Ranking.formatLine(two, 3, Config),
                "3위  40일  Shackleton Rim  Alice, Bob  10/18"
            )
            t.eq(Ranking.crewText({}, Config), "", "승무원 없음")
            t.eq(Ranking.crewText({ "A", "B", "C", "D" }, Config), "A, B 외 2명")
        end
    )

    t.test("랭킹: 이름 글자 수 제한(한글 포함)", function()
        t.eq(Ranking.clip("가나다라마", 3), "가나다")
        t.eq(Ranking.clip("Alice", 20), "Alice")
        t.eq(Ranking.clip("abcdef", 4), "abcd")
    end)
end
