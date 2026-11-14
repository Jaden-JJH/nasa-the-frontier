// The Frontier 다국어 해석기, 웹판(PlayCanvas) 참조 구현.
// src/shared/Loc.luau, src/shared/Msg.luau와 규칙이 똑같아야 한다. 둘 다 i18n/golden.json으로 검사한다
// (Luau: lune run tests/run_i18n.luau, JS: node i18n/test_golden.mjs). 규칙을 바꾸면 세 곳을 같이 고친다.
//
// 사용
//   Node/번들러: const Loc = require("./loc.js")
//   브라우저 classic script: <script src="loc.js"></script> 뒤 window.FrontierLoc
//   문구 표: i18n/strings.json 의 strings 필드 (key -> { en, ko })
//   Loc.resolve({ key: "event.source", args: { date: Loc.msgDate({ year: 2024, month: 8, day: 12 }) } }, "ko", table)
//
// 규칙 요약 (자세한 설명은 Loc.luau 맨 위)
// 1. {name} 자리표시자, {{ }} 는 글자 그대로, 값이 없으면 {name} 유지
// 2. 복수형: args.count가 숫자면 en은 1일 때 .one, 그 밖은 .other, ko는 항상 .other
// 3. 대체: 요청 언어 -> en -> 키 문자열
// 4. 값: 문자열 그대로, 숫자 formatNumber, 불리언 "true"/"false", Msg는 중첩 해석 (깊이 MAX_DEPTH)
// 5. .rich 키만 <b></b>, 값은 escape (중첩 Msg가 .rich면 그대로)
// 6. 숫자: 정수 그대로, 소수 둘째 자리 반올림 floor(|n| * 100 + 0.5), 끝 0 제거, NaN/무한/|n| >= 1e15 는 "?"
(function (root, factory) {
  "use strict";
  if (typeof module === "object" && module && module.exports) {
    module.exports = factory();
  } else {
    root.FrontierLoc = factory();
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const SUPPORTED = ["en", "ko"];
  const DEFAULT = "en";
  const FALLBACK = "en";
  const MAX_DEPTH = 10;
  const MAX_KEY_LENGTH = 200;
  const EMPTY = Object.freeze({});
  const hasOwn = (obj, name) => Object.prototype.hasOwnProperty.call(obj, name);

  function normalize(code) {
    if (typeof code !== "string") return null;
    const lower = code.toLowerCase();
    return SUPPORTED.includes(lower) ? lower : null;
  }

  function pluralForm(lang, count) {
    return lang === "en" && count === 1 ? "one" : "other";
  }

  function formatNumber(n) {
    if (typeof n !== "number" || Number.isNaN(n) || Math.abs(n) >= 1e15) return "?";
    if (Number.isInteger(n)) return String(n === 0 ? 0 : n);
    const rounded = Math.floor(Math.abs(n) * 100 + 0.5);
    const whole = Math.floor(rounded / 100);
    const frac = rounded % 100;
    let text = String(whole);
    if (frac !== 0) {
      if (frac % 10 === 0) text += "." + String(frac / 10);
      else text += "." + (frac < 10 ? "0" : "") + String(frac);
    }
    if (n < 0 && rounded > 0) text = "-" + text;
    return text;
  }

  const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" };

  function escape(text) {
    return String(text).replace(/[&<>"']/g, (ch) => ESCAPES[ch]);
  }

  function isRich(key) {
    return ("." + key + ".").includes(".rich.");
  }

  function isTable(value) {
    return typeof value === "object" && value !== null;
  }

  function cell(strings, key, lang) {
    if (!hasOwn(strings, key)) return null;
    const entry = strings[key];
    if (!isTable(entry) || !hasOwn(entry, lang)) return null;
    const text = entry[lang];
    return typeof text === "string" && text !== "" ? text : null;
  }

  // 반환: [템플릿, 실제 키] 또는 [null, null]
  function lookup(strings, key, lang, args) {
    const count = isTable(args) && hasOwn(args, "count") ? args.count : undefined;
    const chain = lang === FALLBACK ? [lang] : [lang, FALLBACK];
    for (const l of chain) {
      const candidates =
        typeof count === "number"
          ? [key + "." + pluralForm(l, count), key + ".other", key]
          : [key, key + ".other"];
      for (const candidate of candidates) {
        const text = cell(strings, candidate, l);
        if (text !== null) return [text, candidate];
      }
    }
    return [null, null];
  }

  function valueText(value, lang, strings, rich, depth) {
    const kind = typeof value;
    if (kind === "string") return rich ? escape(value) : value;
    if (kind === "number") return formatNumber(value);
    if (kind === "boolean") return value ? "true" : "false";
    if (isTable(value) && typeof value.key === "string") {
      const text = resolveAt(value, lang, strings, depth + 1);
      return rich && !isRich(value.key) ? escape(text) : text;
    }
    return null;
  }

  const NAME = /^[A-Za-z0-9_]+$/;

  function interpolateAt(template, args, lang, strings, rich, depth) {
    let out = "";
    const n = template.length;
    let i = 0;
    while (i < n) {
      const c = template[i];
      if (c === "{") {
        if (template[i + 1] === "{") {
          out += "{";
          i += 2;
          continue;
        }
        const close = template.indexOf("}", i + 1);
        const name = close >= 0 ? template.slice(i + 1, close) : "";
        if (close >= 0 && NAME.test(name)) {
          const value = isTable(args) && hasOwn(args, name) ? args[name] : undefined;
          const text =
            value !== undefined && value !== null
              ? valueText(value, lang, strings, rich, depth)
              : null;
          out += text !== null ? text : "{" + name + "}";
          i = close + 1;
          continue;
        }
        out += "{";
        i += 1;
      } else if (c === "}") {
        out += "}";
        i += template[i + 1] === "}" ? 2 : 1;
      } else {
        let stop = i;
        while (stop < n && template[stop] !== "{" && template[stop] !== "}") stop += 1;
        out += template.slice(i, stop);
        i = stop;
      }
    }
    return out;
  }

  function resolveAt(msg, lang, strings, depth) {
    if (depth > MAX_DEPTH) return msg.key;
    const [template] = lookup(strings, msg.key, lang, msg.args);
    if (template === null) return msg.key;
    return interpolateAt(template, msg.args, lang, strings, isRich(msg.key), depth);
  }

  function interpolate(template, args, lang, strings, rich) {
    return interpolateAt(template, args, lang, strings || EMPTY, rich === true, 0);
  }

  function resolve(msg, lang, strings) {
    let target;
    if (typeof msg === "string") target = { key: msg };
    else if (isTable(msg) && typeof msg.key === "string") target = msg;
    else return "";
    const code = typeof lang === "string" ? lang : DEFAULT;
    return resolveAt(target, code, strings || EMPTY, 0);
  }

  function monthText(month) {
    return typeof month === "number" && Number.isInteger(month) && Math.abs(month) < 1e15
      ? String(month)
      : "?";
  }

  // Msg.date와 같은 구조
  function msgDate(date, style) {
    const m = monthText(date.month);
    return {
      key: "fmt.date." + (style || "long"),
      args: {
        year: date.year,
        month: date.month,
        day: date.day,
        month_name: { key: "date.month." + m },
        month_short: { key: "date.month_short." + m },
      },
    };
  }

  function formatDate(date, lang, style, strings) {
    return resolve(msgDate(date, style), lang, strings);
  }

  // os.date("!*t") 와 같은 UTC 날짜
  function msgDateFromTime(unixSeconds, style) {
    const d = new Date(Math.floor(unixSeconds) * 1000);
    return msgDate(
      { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() },
      style
    );
  }

  function msg(key, args) {
    return args === undefined ? { key } : { key, args };
  }

  function msgCount(key, count, args) {
    const copy = Object.assign({}, args || {});
    copy.count = count;
    return { key, args: copy };
  }

  function msgList(items) {
    const n = items.length;
    if (n === 0) return "";
    if (n === 1) return items[0];
    if (n === 2) return { key: "fmt.list.two", args: { a: items[0], b: items[1] } };
    let acc = { key: "fmt.list.end", args: { a: items[n - 2], b: items[n - 1] } };
    for (let i = n - 3; i >= 1; i -= 1) {
      acc = { key: "fmt.list.middle", args: { a: items[i], b: acc } };
    }
    return { key: "fmt.list.start", args: { a: items[0], b: acc } };
  }

  // Luau 표는 빈 배열과 빈 객체를 구별하지 못하므로 빈 배열은 빈 args로 본다
  function isMsgAt(value, depth) {
    if (!isTable(value) || Array.isArray(value)) return false;
    const key = value.key;
    if (typeof key !== "string" || key === "" || key.length > MAX_KEY_LENGTH) return false;
    for (const field of Object.keys(value)) {
      if (field !== "key" && field !== "args") return false;
    }
    const args = value.args;
    if (args === undefined || args === null) return true;
    if (!isTable(args)) return false;
    if (Array.isArray(args)) return args.length === 0;
    for (const name of Object.keys(args)) {
      const arg = args[name];
      const kind = typeof arg;
      if (isTable(arg)) {
        if (depth >= MAX_DEPTH || !isMsgAt(arg, depth + 1)) return false;
      } else if (kind !== "string" && kind !== "number" && kind !== "boolean") {
        return false;
      }
    }
    return true;
  }

  function isMsg(value) {
    return isMsgAt(value, 0);
  }

  function argsEqual(a, b) {
    const left = isTable(a) ? a : {};
    const right = isTable(b) ? b : {};
    for (const name of Object.keys(left)) {
      if (!equals(left[name], right[name])) return false;
    }
    for (const name of Object.keys(right)) {
      if (left[name] === undefined) return false;
    }
    return true;
  }

  function equals(a, b) {
    if (isTable(a) && isTable(b)) return a.key === b.key && argsEqual(a.args, b.args);
    return a === b;
  }

  return Object.freeze({
    SUPPORTED,
    DEFAULT,
    FALLBACK,
    MAX_DEPTH,
    normalize,
    pluralForm,
    formatNumber,
    escape,
    isRich,
    lookup,
    interpolate,
    resolve,
    formatDate,
    msg,
    msgCount,
    msgDate,
    msgDateFromTime,
    msgList,
    isMsg,
    equals,
  });
});
