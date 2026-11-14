// 웹판 해석기(i18n/loc.js) 골든 테스트. 저장소 루트에서: node i18n/test_golden.mjs
// tests/i18n.spec.luau가 같은 i18n/golden.json으로 Luau 해석기를 검사한다. 둘 다 통과해야 규칙이 같다.
// 추가로 i18n/strings.json(빌드 생성물)을 읽어 실제 문구 몇 개와 형식을 확인한다.
// 실패가 하나라도 있으면 종료 코드 1.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const Loc = require("./loc.js");

const golden = JSON.parse(readFileSync(join(here, "golden.json"), "utf8"));
const table = golden.strings;

let passed = 0;
let failed = 0;

function check(id, actual, expected) {
  if (actual === expected) {
    passed += 1;
    return;
  }
  failed += 1;
  console.log(`  실패  ${id}`);
  console.log(`        기대값 ${JSON.stringify(expected)}, 실제값 ${JSON.stringify(actual)}`);
}

function runCase(c) {
  switch (c.kind) {
    case "resolve":
      return Loc.resolve(c.msg, c.lang, table);
    case "template":
      return Loc.interpolate(c.template, c.args, c.lang, table, c.rich === true);
    case "date":
      return Loc.formatDate(c.date, c.lang, c.style, table);
    case "date_arg":
      return Loc.resolve(
        Loc.msg(c.key, { [c.arg]: Loc.msgDate(c.date, c.style) }),
        c.lang,
        table
      );
    case "date_time":
      return Loc.resolve(Loc.msgDateFromTime(c.time, c.style), c.lang, table);
    case "list":
      return Loc.interpolate("{x}", { x: Loc.msgList(c.items) }, c.lang, table, false);
    case "escape":
      return Loc.escape(c.text);
    case "normalize":
      return Loc.normalize(c.value) ?? "";
    case "is_msg":
      return Loc.isMsg(c.value);
    case "equals":
      return Loc.equals(c.a, c.b);
    default:
      throw new Error(`알 수 없는 kind: ${c.kind}`);
  }
}

console.log("[golden.json]");
for (const c of golden.cases) {
  let actual;
  try {
    actual = runCase(c);
  } catch (err) {
    actual = `오류: ${err.message}`;
  }
  check(c.id, actual, c.expected);
}
console.log(`  골든 ${golden.cases.length}개 실행`);

// 실제 문구 표 (빌드 생성물)
console.log("[strings.json]");
const built = JSON.parse(readFileSync(join(here, "strings.json"), "utf8"));
const s = built.strings;
check("strings.languages", built.languages.join(","), "en,ko");
check("strings.count", Object.keys(s).length, built.count);
check("strings.every_en", Object.values(s).every((e) => typeof e.en === "string" && e.en !== ""), true);
check("strings.energy.en", Loc.resolve("res.energy.name", "en", s), "Energy");
check("strings.energy.ko", Loc.resolve("res.energy.name", "ko", s), "에너지");
check(
  "strings.donki_source.en",
  Loc.resolve(Loc.msg("event.source", { date: Loc.msgDate({ year: 2024, month: 8, day: 12 }) }), "en", s),
  "NASA DONKI record, August 12, 2024"
);
check(
  "strings.donki_source.ko",
  Loc.resolve(Loc.msg("event.source", { date: Loc.msgDate({ year: 2024, month: 8, day: 12 }) }), "ko", s),
  "NASA DONKI 기록, 2024년 8월 12일"
);
check(
  "strings.deduct.one.en",
  Loc.resolve(Loc.msgCount("score.deduct.water_low", 1, { points: 10 }), "en", s),
  "Water was low for 1 day: -10"
);
check(
  "strings.deduct.other.ko",
  Loc.resolve(Loc.msgCount("score.deduct.water_low", 3, { points: 30 }), "ko", s),
  "물이 부족했던 날 3일: -30점"
);
check(
  "strings.crew_list.en",
  Loc.interpolate("{x}", { x: Loc.msgList(["Mia", "Leo", "Sam"]) }, "en", s),
  "Mia, Leo, and Sam"
);

console.log("");
console.log(`결과: 통과 ${passed}, 실패 ${failed}`);
process.exit(failed > 0 ? 1 : 0);
