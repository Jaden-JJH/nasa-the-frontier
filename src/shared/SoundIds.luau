--!strict
-- 효과음 카탈로그. id가 0이면 재생하지 않는다(무음). 서버와 클라이언트가 공유한다.
-- 출처 규칙: Roblox가 배포한 무료 라이브러리 음원(누구나 사용 가능)만 쓴다. docs/SOUNDS.md에 출처와 검증 기록.
-- volume은 0..1, pitchJitter는 재생마다 PlaybackSpeed에 더하는 무작위 폭(0이면 고정), loop는 반복 여부.

export type SoundSpec = {
    id: number,
    volume: number,
    pitchJitter: number,
    loop: boolean,
    note: string,
}

local function spec(
    id: number,
    volume: number,
    pitchJitter: number,
    loop: boolean,
    note: string
): SoundSpec
    return { id = id, volume = volume, pitchJitter = pitchJitter, loop = loop, note = note }
end

local SoundIds = {
    -- 로버
    rover_board = spec(9116642648, 0.6, 0.05, false, "로버 승차(해치, 좌석)"),
    rover_exit = spec(9116643292, 0.6, 0.05, false, "로버 하차"),
    rover_engine_loop = spec(
        9125767745,
        0.35,
        0,
        true,
        "로버 전기 모터 주행 루프, 속도에 따라 PlaybackSpeed 0.8~1.4"
    ),
    rover_hit = spec(9116673678, 0.8, 0.1, false, "바위 충돌 충격음"),
    rover_broken = spec(9118805673, 0.8, 0, false, "로버 고장 경고(클랙슨 2.5초)"),
    rover_repair = spec(
        9118047507,
        0.6,
        0.05,
        false,
        "수리 래칫 렌치 소리(원본 2.9초, 4초 홀드는 호출 쪽에서 반복)"
    ),
    rover_recover = spec(9114055470, 0.7, 0, false, "로버 복구 순간이동"),
    rover_dock = spec(9113561873, 0.6, 0, false, "충전 도크 결합 래치 소리"),
    rover_charge_loop = spec(9114246115, 0.3, 0, true, "충전 중 전기 허밍 루프"),
    rover_charge_full = spec(9126073938, 0.6, 0, false, "충전 완료 차임"),
    rover_battery_low = spec(9113085764, 0.6, 0, false, "배터리 부족 경고음"),
    rover_boost_loop = spec(
        9114253664,
        0.45,
        0,
        true,
        "부스터 작동 루프(전기 모터 고회전 4.2초)"
    ),
    rover_boost_ready = spec(
        9113399643,
        0.5,
        0,
        false,
        "부스터 쿨다운 완료 비프(짧은 음 뒤 긴 음)"
    ),
    -- 물
    ice_mine_loop = spec(
        9125883730,
        0.45,
        0,
        true,
        "얼음 채취 긁는 소리 루프(3초 홀드 동안)"
    ),
    ice_collected = spec(9114863539, 0.6, 0.05, false, "탱크 채움 완료"),
    ice_depleted = spec(12222005, 0.6, 0, false, "매장량 고갈(결정 사라짐)"),
    water_unload = spec(9120577126, 0.6, 0, false, "물 하역, 액체 흐르는 소리"),
    water_processing = spec(9120578114, 0.5, 0, false, "정수 처리 기계음"),
    -- 에어락과 건물
    airlock_open = spec(9125610263, 0.7, 0, false, "에어락 문 열림(공기 배출)"),
    airlock_close = spec(9116644054, 0.7, 0, false, "에어락 문 닫힘"),
    interior_hum_loop = spec(9125446543, 0.2, 0, true, "건물 내부 공조 허밍 루프"),
    -- 건설
    panel_install = spec(
        9116727630,
        0.6,
        0.05,
        false,
        "패널 설치 금속 래치 클릭(홀드 완료)"
    ),
    panel_unfold = spec(
        9118329245,
        0.6,
        0,
        false,
        "패널 펼침 서보 구동음(원본 2.1초, 펼침 1.5초)"
    ),
    build_start = spec(9117882918, 0.7, 0, false, "모듈 착공"),
    build_loop = spec(
        9116639168,
        0.3,
        0,
        true,
        "건설 중 공사 소리 루프(모듈 위치 3D)"
    ),
    build_complete = spec(9116395179, 0.8, 0, false, "모듈 완공 팡파르"),
    -- 산소와 캐릭터
    oxygen_breath_loop = spec(
        9113073789,
        0.25,
        0,
        true,
        "헬멧 안 호흡 루프, 산소 낮을수록 볼륨 상승"
    ),
    oxygen_low_beep = spec(9113880475, 0.6, 0, false, "산소 20 이하 경고 비프"),
    oxygen_rescue = spec(9113056997, 0.7, 0, false, "산소 고갈 구조"),
    -- UI와 게임 흐름
    ui_click = spec(15675059323, 0.5, 0, false, "버튼 클릭"),
    mission_advance = spec(17208361335, 0.5, 0, false, "미션 단계 전진"),
    notify_warn = spec(17208353912, 0.5, 0, false, "경고 토스트"),
    notify_good = spec(9114132512, 0.5, 0, false, "완료 토스트"),
    landing_thrust = spec(12222095, 0.7, 0, false, "착륙 연출 추진기"),
    win = spec(9125641025, 0.8, 0, false, "승리 음악(짧은 스팅어)"),
    lose = spec(9119903219, 0.8, 0, false, "실패 음악(짧은 스팅어)"),
}

return SoundIds
