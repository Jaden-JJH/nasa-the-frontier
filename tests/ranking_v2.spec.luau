-- RankingV2 순수 로직 테스트 (V2_PLAN Q5, Q24, docs/CONTRACT_V2.md 7절)
local RankingV2 = require("../src/shared/RankingV2")

return function(t)
    local function entry(medal, score, days, at, crew)
        return RankingV2.makeMission("C", medal, score, days, crew or { "Ana" }, "solo", 1, at)
    end

    t.test("미션 순위: 메달 > 점수 > 일수 > 먼저", function()
        local list = {}
        list = RankingV2.insertMission(list, entry("silver", 990, 30, 1), 10)
        list = RankingV2.insertMission(list, entry("gold", 500, 50, 2), 10)
        list = RankingV2.insertMission(list, entry("gold", 800, 50, 3), 10)
        list = RankingV2.insertMission(list, entry("gold", 800, 40, 4), 10)
        list = RankingV2.insertMission(list, entry("gold", 800, 40, 5), 10)
        t.eq(list[1].at, 4, "같은 메달, 점수면 일수 적은 순, 같으면 먼저")
        t.eq(list[2].at, 5)
        t.eq(list[3].at, 3)
        t.eq(list[4].at, 2)
        t.eq(list[5].medal, "silver", "은메달은 점수가 높아도 금 뒤")
    end)

    t.test(
        "미션 순위: 넣은 기록의 순위, 상한 밖이면 nil, 같은 기록은 두 번 넣지 않는다",
        function()
            local list = {}
            for i = 1, 10 do
                list = RankingV2.insertMission(list, entry("gold", 900 - i, 30, i), 10)
            end
            local mine = entry("gold", 950, 30, 99)
            local merged, rank = RankingV2.insertMission(list, mine, 10)
            t.eq(rank, 1)
            t.eq(#merged, 10)
            local again, rank2 = RankingV2.insertMission(merged, mine, 10)
            t.eq(#again, 10, "재시도로 같은 기록이 두 번 들어가지 않는다")
            t.eq(rank2, 1)
            local _, low = RankingV2.insertMission(merged, entry("bronze", 1, 60, 100), 10)
            t.eq(low, nil, "상한 밖")
        end
    )

    t.test("미션 순위: 잘못된 저장 값은 거른다", function()
        local list = RankingV2.sanitizeMission({
            entry("gold", 900, 30, 1),
            { medal = "platinum", score = 1, days = 1, at = 1, missionId = "C", crew = {} },
            { medal = "gold", score = "x" },
            "junk",
        }, 10)
        t.eq(#list, 1)
        t.eq(#RankingV2.sanitizeMission(nil, 10), 0)
    end)

    t.test("이름 자르기와 팀원 수", function()
        local e =
            RankingV2.makeMission("C", "gold", 900, 30, { "A", "B", "C", "D", "E" }, "multi", 5, 1)
        t.eq(#e.crew, RankingV2.CREW_MAX)
        t.eq(e.mode, "multi")
        t.eq(RankingV2.clip("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnopqrst")
        t.eq(RankingV2.clip("가나다", 2), "가나")
    end)

    t.test(
        "전체 리더보드: 팀 금메달은 팀원 모두에게, 미션별 최고만 남긴다",
        function()
            local members = { { userId = 1, name = "Ana" }, { userId = 2, name = "Ben" } }
            local list = RankingV2.mergeRun(
                {},
                { missionId = "C", medal = "silver", score = 700, members = members },
                50
            )
            t.eq(#list, 2)
            t.eq(list[1].goldMissions, 0)
            t.eq(list[1].bestScoreSum, 700)
            list = RankingV2.mergeRun(
                list,
                { missionId = "C", medal = "gold", score = 600, members = { members[2] } },
                50
            )
            t.eq(list[1].userId, 2, "금메달이 먼저")
            t.eq(list[1].goldMissions, 1)
            t.eq(list[1].bestScoreSum, 600, "메달이 좋아지면 점수가 낮아도 바꾼다")
            list = RankingV2.mergeRun(
                list,
                { missionId = "C", medal = "silver", score = 990, members = { members[2] } },
                50
            )
            t.eq(list[1].goldMissions, 1, "더 낮은 메달은 무시")
            list = RankingV2.mergeRun(
                list,
                { missionId = "B", medal = "bronze", score = 300, members = { members[2] } },
                50
            )
            t.eq(list[1].bestScoreSum, 900, "미션별 최고 점수 합")
            local rank, mine = RankingV2.findUser(list, 1)
            t.eq(rank, 2)
            t.eq(mine and mine.name, "Ana")
            local medals = RankingV2.bestMedals(list, 2)
            t.eq(medals.C, "gold")
            t.eq(medals.B, "bronze")
            local public = RankingV2.publicGlobal(list[1])
            t.eq(public.missions, nil, "화면용에는 미션 상세를 뺀다")
        end
    )

    t.test("전체 리더보드: 저장 값 정리, 같은 사람 한 줄, 상한", function()
        local raw = {
            { userId = 5, name = "E", missions = { C = { medal = "gold", score = 10 } } },
            { userId = 5, name = "E2", missions = { C = { medal = "gold", score = 20 } } },
            { userId = 6, name = "F", missions = { C = { medal = "tin", score = 1 } } },
            { userId = 7, name = "G", missions = {} },
        }
        local list = RankingV2.sanitizeGlobal(raw, 50)
        t.eq(#list, 2)
        t.eq(list[1].userId, 5)
        t.eq(list[1].goldMissions, 1, "저장 값의 합계는 다시 센다")
        t.eq(#RankingV2.sanitizeGlobal(raw, 1), 1)
    end)
end
