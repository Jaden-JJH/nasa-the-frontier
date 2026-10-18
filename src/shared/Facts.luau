--!strict
-- "알고 있나요?" 교육 사실 카드 문구 (15차). 표시 로직은 client/FactUI.luau.
-- 널리 확인된 일반 사실만 쓰고, 숫자는 "약"으로 보수적으로 적는다. 본문은 2~3문장, 중학생이 읽을 수 있는 수준.
-- body의 {site}는 FactUI가 선택된 착륙지 이름으로 바꾼다.
-- trigger: landed(플레이 시작 4초 뒤), panel(첫 패널), water(첫 물 하역), module(모듈 가동),
--          oxygen(산소 50 미만), board(첫 탑승 20초 뒤), result(결과 화면 전용, 카드로는 뜨지 않음)

export type Fact = {
    key: string,
    title: string,
    body: string,
    trigger: string,
}

local list: { Fact } = {
    -- NASA Artemis 공개 자료와 LCROSS 관측 수준의 일반 사실
    {
        key = "landing_site",
        title = "왜 달의 남극일까요?",
        body = "{site} 착륙지는 달의 남극 가까이에 있어요. 햇빛이 닿지 않는 깊은 크레이터 안에는 물이 얼음으로 남아 있을 가능성이 커서, NASA 아르테미스 계획도 남극을 목표로 합니다.",
        trigger = "landed",
    },
    -- 달의 자전과 공전 주기에 관한 교과서 수준의 일반 사실, 극지 고지대 일조는 NASA 공개 자료 수준
    {
        key = "first_panel",
        title = "달의 하루는 얼마나 길까요?",
        body = "달의 하루는 지구 시간으로 약 한 달이에요. 낮이 약 2주, 밤이 약 2주 이어집니다. 극지방의 높은 곳은 햇빛이 오래 들어서 태양광 기지를 짓기 좋은 후보지예요.",
        trigger = "panel",
    },
    -- 물의 전기분해와 현지 자원 활용(ISRU) 개념. NASA 공개 자료 수준
    {
        key = "first_water",
        title = "얼음은 물만이 아니에요",
        body = "달의 얼음은 마시는 물이 될 뿐 아니라, 전기로 분해하면 산소와 수소를 얻을 수 있어요. 산소는 숨 쉬는 데, 수소와 산소는 로켓 연료로 쓸 수 있죠. 이렇게 현지 자원을 쓰는 일을 ISRU라고 해요.",
        trigger = "water",
    },
    -- 달에 대기와 자기장이 거의 없다는 일반 사실. 표토 차폐는 NASA와 ESA 연구 아이디어 수준
    {
        key = "module_A",
        title = "달에는 방패가 없어요",
        body = "달에는 두꺼운 대기와 지구 같은 자기장이 없어서 우주 방사선과 작은 운석이 그대로 닿아요. 그래서 거주 모듈을 달 흙(표토)으로 덮어 보호하는 방법이 연구되고 있어요.",
        trigger = "module",
    },
    -- 국제우주정거장 채소 재배(Veggie)와 2022년 플로리다대 연구(Communications Biology)
    {
        key = "module_B",
        title = "우주에서 농사짓기",
        body = "국제우주정거장에서는 우주비행사가 상추 같은 채소를 길러 먹었어요. 2022년에는 플로리다대 연구팀이 아폴로가 가져온 달 흙에서 식물(애기장대)의 싹을 틔웠습니다. 식물은 산소도 만들어 줘요.",
        trigger = "module",
    },
    -- 달 과학의 일반 사실. 뒷면 전파망원경 후보지는 NASA와 ESA 공개 논의 수준
    {
        key = "module_C",
        title = "달은 거대한 기록 보관소",
        body = "달은 지구와 달이 어떻게 생겼는지, 태양계 초기에 무슨 일이 있었는지를 간직한 기록이에요. 달 뒷면은 지구의 전파 잡음이 가려져서 전파망원경을 세울 후보지로 꼽힙니다.",
        trigger = "module",
    },
    -- 달에 대기가 사실상 없다는 일반 사실과 우주복의 기본 기능
    {
        key = "oxygen_low",
        title = "달에서는 숨을 쉴 수 없어요",
        body = "달에는 숨 쉴 공기가 사실상 없어요. 그래서 우주복이 산소를 공급하고 압력과 온도를 지켜 줍니다. 공기가 없어서 소리도 퍼지지 않기 때문에, 우주비행사들은 무전기로 대화해요.",
        trigger = "oxygen",
    },
    -- 달 중력은 지구의 약 1/6(교과서 수준), 아폴로 발자국 보존은 NASA 공개 자료 수준
    {
        key = "gravity",
        title = "달 중력은 지구의 약 6분의 1",
        body = "달의 중력은 지구의 약 6분의 1이라서 로버도 사람도 가볍게 튀어 오르듯 움직여요. 달에는 바람이 없어서 먼지 위에 남긴 발자국도 아주 오래 남는다고 알려져 있어요.",
        trigger = "board",
    },
    -- NASA Artemis 공개 목표 수준의 일반 사실
    {
        key = "result_win",
        title = "임무 성공, 그다음은?",
        body = "아르테미스 계획은 달에 오래 머물 수 있는 거점을 만들고, 그 경험으로 화성에 가는 길을 열려는 계획이에요.",
        trigger = "result",
    },
    -- 격려 문구. 물과 전력 계획이 핵심이라는 점은 NASA 공개 자료 수준
    {
        key = "result_lose",
        title = "실패도 배움이에요",
        body = "실제 달 임무도 물과 전력 계획이 가장 중요해요. 이번에 배운 점을 살려 다시 도전해 봐요.",
        trigger = "result",
    },
}

local byKey: { [string]: Fact } = {}
for _, fact in ipairs(list) do
    byKey[fact.key] = fact
end

return {
    list = list,
    byKey = byKey,
}
