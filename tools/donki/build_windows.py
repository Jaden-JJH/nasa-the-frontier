#!/usr/bin/env python3
"""NASA DONKI 우주 기상 기록으로 게임용 60일 구간을 만든다 (V2_PLAN.md 15.8, Q14).

사용법 (저장소 루트에서):
    python3 -I tools/donki/build_windows.py            # 캐시(data/donki/raw.json)로 다시 생성
    python3 -I tools/donki/build_windows.py --refresh  # API에서 다시 받기 (키 필요)

키는 저장소 밖 ../.env 의 NASA_DATA_KEY 또는 환경 변수 NASA_DATA_KEY 에서 읽는다.
키 값은 출력하지 않는다. DONKI는 한 번에 60일까지만 조회되므로 60일씩 나눠 받는다.

규칙 (grill Q14):
- SEP: 3일 안에 이어지는 기록(여러 관측소 중복 포함)을 사건 하나로 묶는다.
  하루짜리 묶음은 야외 금지 1일, 이어지면 2일.
- GST: Kp 6 이상만 쓴다. 1일.
- 구간: 60일 안에 SEP 사건 2~4건, GST 2~4건. 첫 5일에는 사건이 없게 한다(초반 준비 시간).
  서로 겹치지 않는 구간 중 사건이 많은 순서로 5개를 고른다.

출력:
- data/donki/raw.json            DONKI 원본 응답 모음 (공개 데이터, 키 없음)
- data/donki/windows.json        웹판(PlayCanvas)과 공유하는 구간 데이터
- src/shared/SpaceWeatherData.luau  게임이 읽는 생성 파일
"""

import datetime as dt
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RAW_PATH = os.path.join(ROOT, "data", "donki", "raw.json")
WINDOWS_JSON = os.path.join(ROOT, "data", "donki", "windows.json")
LUAU_PATH = os.path.join(ROOT, "src", "shared", "SpaceWeatherData.luau")

RANGE_START = dt.date(2021, 1, 1)
RANGE_END = dt.date(2025, 12, 31)
CHUNK_DAYS = 60
WINDOW_DAYS = 60
WINDOW_STEP_DAYS = 7
SEP_GAP_DAYS = 3
GST_MIN_KP = 6
COUNT_MIN, COUNT_MAX = 2, 4
QUIET_START_DAYS = 5
WINDOW_PICK = 5


def read_key():
    key = os.environ.get("NASA_DATA_KEY")
    if key:
        return key.strip()
    env_path = os.path.join(ROOT, "..", ".env")
    if os.path.isfile(env_path):
        with open(env_path, encoding="utf-8") as f:
            m = re.search(r"NASA_DATA_KEY\s*=\s*\"?([^\s\"]+)", f.read())
            if m:
                return m.group(1)
    sys.exit("NASA_DATA_KEY를 찾지 못했습니다 (../.env 또는 환경 변수)")


def fetch_all():
    key = read_key()
    raw = {"range": [RANGE_START.isoformat(), RANGE_END.isoformat()], "SEP": [], "GST": []}
    d = RANGE_START
    while d <= RANGE_END:
        e = min(d + dt.timedelta(days=CHUNK_DAYS - 1), RANGE_END)
        for kind in ("SEP", "GST"):
            url = f"https://api.nasa.gov/DONKI/{kind}?startDate={d}&endDate={e}&api_key={key}"
            with urllib.request.urlopen(url, timeout=30) as r:
                body = r.read().decode()
            data = json.loads(body) if body.strip() else []
            raw[kind].extend(data if isinstance(data, list) else [])
        d = e + dt.timedelta(days=1)
    os.makedirs(os.path.dirname(RAW_PATH), exist_ok=True)
    with open(RAW_PATH, "w", encoding="utf-8") as f:
        json.dump(raw, f, ensure_ascii=False)
    return raw


def to_date(s):
    return dt.date.fromisoformat(s[:10])


def build_events(raw):
    sep_days = sorted({to_date(x["eventTime"]) for x in raw["SEP"] if x.get("eventTime")})
    clusters = []
    for day in sep_days:
        if clusters and (day - clusters[-1][-1]).days <= SEP_GAP_DAYS:
            clusters[-1].append(day)
        else:
            clusters.append([day])
    seps = [{"kind": "SEP", "date": c[0], "durationDays": 1 if len(c) == 1 else 2} for c in clusters]
    gsts = []
    for x in raw["GST"]:
        kps = [k.get("kpIndex") or 0 for k in x.get("allKpIndex", [])]
        kp = max(kps) if kps else 0
        if kp >= GST_MIN_KP and x.get("startTime"):
            gsts.append({"kind": "GST", "date": to_date(x["startTime"]), "durationDays": 1, "kp": int(round(kp))})
    gsts.sort(key=lambda g: g["date"])
    return seps, gsts


def pick_windows(seps, gsts):
    candidates = []
    start = RANGE_START
    last_start = RANGE_END - dt.timedelta(days=WINDOW_DAYS - 1)
    while start <= last_start:
        end = start + dt.timedelta(days=WINDOW_DAYS - 1)
        s_in = [e for e in seps if start <= e["date"] <= end]
        g_in = [e for e in gsts if start <= e["date"] <= end]
        all_in = s_in + g_in
        quiet = all((e["date"] - start).days + 1 > QUIET_START_DAYS for e in all_in)
        if COUNT_MIN <= len(s_in) <= COUNT_MAX and COUNT_MIN <= len(g_in) <= COUNT_MAX and quiet:
            candidates.append((len(all_in), start, s_in, g_in))
        start += dt.timedelta(days=WINDOW_STEP_DAYS)
    candidates.sort(key=lambda c: (-c[0], c[1]))
    picked = []
    for c in candidates:
        if all(abs((c[1] - p[1]).days) >= WINDOW_DAYS for p in picked):
            picked.append(c)
        if len(picked) >= WINDOW_PICK:
            break
    picked.sort(key=lambda c: c[1])
    windows = []
    for _, start, s_in, g_in in picked:
        events = []
        for e in sorted(s_in + g_in, key=lambda e: (e["date"], e["kind"])):
            item = {
                "kind": e["kind"],
                "day": (e["date"] - start).days + 1,
                "durationDays": e["durationDays"],
                "sourceDate": {"year": e["date"].year, "month": e["date"].month, "day": e["date"].day},
            }
            if e["kind"] == "GST":
                item["kp"] = e["kp"]
            events.append(item)
        windows.append(
            {
                "id": start.isoformat(),
                "startDate": {"year": start.year, "month": start.month, "day": start.day},
                "sepCount": len(s_in),
                "gstCount": len(g_in),
                "events": events,
            }
        )
    return windows, len(candidates)


def date_luau(d):
    return "{ year = %d, month = %d, day = %d }" % (d["year"], d["month"], d["day"])


def write_outputs(windows, meta):
    os.makedirs(os.path.dirname(WINDOWS_JSON), exist_ok=True)
    with open(WINDOWS_JSON, "w", encoding="utf-8") as f:
        json.dump({**meta, "windows": windows}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    lines = [
        "-- GENERATED by tools/donki/build_windows.py, do not edit.",
        "-- NASA DONKI(api.nasa.gov) 실제 우주 기상 기록에서 고른 60일 구간 (V2_PLAN.md 15.8, Q14).",
        "-- day는 게임 일차(1~60), sourceDate는 실제 발생 날짜. 고정 과거 기록이므로 실시간처럼 표시하지 않는다.",
        "",
        "return {",
        '\tsource = "NASA DONKI (Space Weather Database Of Notifications, Knowledge, Information)",',
        '\tsourceUrl = "https://api.nasa.gov/",',
        '\trange = { from = "%s", to = "%s" },' % (meta["range"][0], meta["range"][1]),
        "\trules = { sepGapDays = %d, gstMinKp = %d, countMin = %d, countMax = %d, quietStartDays = %d },"
        % (SEP_GAP_DAYS, GST_MIN_KP, COUNT_MIN, COUNT_MAX, QUIET_START_DAYS),
        "\twindows = {",
    ]
    for w in windows:
        lines.append("\t\t{")
        lines.append('\t\t\tid = "%s",' % w["id"])
        lines.append("\t\t\tstartDate = %s," % date_luau(w["startDate"]))
        lines.append("\t\t\tsepCount = %d," % w["sepCount"])
        lines.append("\t\t\tgstCount = %d," % w["gstCount"])
        lines.append("\t\t\tevents = {")
        for e in w["events"]:
            extra = ", kp = %d" % e["kp"] if e["kind"] == "GST" else ""
            lines.append(
                '\t\t\t\t{ kind = "%s", day = %d, durationDays = %d%s, sourceDate = %s },'
                % (e["kind"], e["day"], e["durationDays"], extra, date_luau(e["sourceDate"]))
            )
        lines.append("\t\t\t},")
        lines.append("\t\t},")
    lines.append("\t},")
    lines.append("}")
    with open(LUAU_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main():
    if "--refresh" in sys.argv or not os.path.isfile(RAW_PATH):
        raw = fetch_all()
    else:
        with open(RAW_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    seps, gsts = build_events(raw)
    windows, candidate_count = pick_windows(seps, gsts)
    meta = {
        "source": "NASA DONKI",
        "range": raw.get("range", [RANGE_START.isoformat(), RANGE_END.isoformat()]),
        "sepEvents": len(seps),
        "gstEventsKp6": len(gsts),
        "candidateWindows": candidate_count,
    }
    write_outputs(windows, meta)
    print(
        "SEP 사건 %d건, GST(Kp %d 이상) %d건, 후보 구간 %d개, 선택 %d개"
        % (len(seps), GST_MIN_KP, len(gsts), candidate_count, len(windows))
    )
    for w in windows:
        days = ", ".join("%s D%d" % (e["kind"], e["day"]) for e in w["events"])
        print("  %s  SEP %d, GST %d  [%s]" % (w["id"], w["sepCount"], w["gstCount"], days))


if __name__ == "__main__":
    main()
