// Pure data helpers — no QML types touched here, so this stays easy to
// reason about and safe to change without worrying about binding cycles.
.pragma library

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// ---------------- dates: real ISO "YYYY-MM-DD", not just today/tomorrow ----------------

function toISO(d) {
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}
function fromISO(iso) {
  var p = iso.split("-").map(Number)
  return new Date(p[0], p[1] - 1, p[2])
}
function todayISO() {
  return toISO(new Date())
}
function addDaysISO(iso, delta) {
  var d = fromISO(iso)
  d.setDate(d.getDate() + delta)
  return toISO(d)
}

var WEEKDAYS = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"]
var MONTHS = ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"]
// Exposed as functions, not bare top-level vars — .pragma library exports
// are guaranteed for functions; plain data properties are not as reliably
// visible on the imported module object.
function monthNames() { return MONTHS }

// "Hoje" / "Amanhã" / "Ontem" for the days that matter most; a real weekday
// + day + month for everything else, so a week from now still reads at a
// glance instead of as a bare ISO string.
function dateLabel(iso) {
  var today = todayISO()
  if (iso === today) return "Hoje"
  if (iso === addDaysISO(today, 1)) return "Amanhã"
  if (iso === addDaysISO(today, -1)) return "Ontem"
  var d = fromISO(iso)
  return WEEKDAYS[d.getDay()] + ", " + d.getDate() + " " + MONTHS[d.getMonth()].slice(0, 3)
}

function timeDecimal(hhmm) {
  var parts = hhmm.split(":")
  return Number(parts[0]) + Number(parts[1]) / 60
}

function nowDecimal(date) {
  var d = date || new Date()
  return d.getHours() + d.getMinutes() / 60
}

// A task from a past day that's still not done is overdue outright — it
// doesn't need a time attached, the day itself already passed. A task dated
// today is only overdue once its own time has passed.
function isOverdue(task, date) {
  var today = todayISO()
  if (task.date < today) return true
  return task.date === today && !!task.time && timeDecimal(task.time) < nowDecimal(date)
}

var PRIORITY_ORDER = { urgent: 0, normal: 1, whenever: 2 }

function tasksForDate(tasks, iso) {
  return tasks.filter(function(t) { return t.date === iso })
}

// What the "Hoje" view actually shows: today's own tasks plus every
// still-open task left behind on an earlier day (never completing/deleting
// a task doesn't quietly bury it — it should keep showing up as a pendency
// until it's actually dealt with). Browsing any other day (past or future
// via ‹ ›) stays a strict, single-day view — only "Hoje" rolls the backlog
// forward.
function tasksForView(tasks, viewDate) {
  if (viewDate === todayISO()) return tasks.filter(function(t) { return t.date <= viewDate })
  return tasksForDate(tasks, viewDate)
}

// Manual drag order is the default sort — priority is a visual signal (the
// stripe color) that the user can also apply as a one-shot "organize now"
// action (assignPriorityOrder), never as a standing auto-sort that would
// fight a drag a second later.
function sortByOrder(list) {
  return list.slice().sort(function(a, b) { return a.order - b.order })
}

function assignPriorityOrder(list) {
  var sorted = list.slice().sort(function(a, b) { return PRIORITY_ORDER[a.priority] - PRIORITY_ORDER[b.priority] })
  sorted.forEach(function(item, i) { item.order = i })
  return sorted
}

function minOrder(list) {
  return list.length ? Math.min.apply(null, list.map(function(i) { return i.order })) : 0
}
function maxOrder(list) {
  return list.length ? Math.max.apply(null, list.map(function(i) { return i.order })) : 0
}

function makeId(prefix) {
  return (prefix || "i") + Date.now().toString(36) + Math.floor(Math.random() * 1000).toString(36)
}

function makeTask(text, dateISO, time, priority, order) {
  return {
    id: makeId("t"),
    text: clampText(text, MAX_TEXT_LEN),
    date: dateISO,
    time: time || "",
    priority: priority || "normal",
    order: order || 0,
    createdAt: Date.now()
  }
}

// Re-clamped right before writing, not just trusted from creation/edit
// time — the last line of defense against anything that reaches this
// point over-sized (an in-memory array assembled some other way, a bug
// elsewhere) so a corrupt/oversized state file is never a thing this
// plugin itself produces.
function serialize(tasks) {
  var bounded = []
  var used = 64
  for (var i = 0; i < tasks.length && bounded.length < MAX_ITEMS; i++) {
    var copy = Object.assign({}, tasks[i])
    copy.text = clampText(copy.text, MAX_TEXT_LEN)
    var itemBytes = byteLength(JSON.stringify(copy)) + PRETTY_OVERHEAD_PER_ITEM
    if (used + itemBytes > SERIALIZE_BUDGET) break
    used += itemBytes
    bounded.push(copy)
  }
  return JSON.stringify({ version: 3, tasks: bounded }, null, 2) + "\n"
}

// Defensive caps applied on load: a tampered/corrupt state file (e.g. one
// that slipped past Service.qml's size check, or was hand-edited) should
// degrade to "truncated" rather than hand an unbounded array or unbounded
// per-item strings to the UI/render layer.
var MAX_ITEMS = 5000
var MAX_TEXT_LEN = 20000
var MAX_RAW_LEN = 8 * 1024 * 1024

// Hard ceiling statehelper.py's save() refuses to write past (Service.qml
// passes this same number to the helper as `max_bytes`) — kept here as the
// single source of truth so the UI-facing limits below and the helper's
// actual cap can't drift apart the way they used to (5000 items x 20000
// chars could serialize to ~100x the helper's 5 MiB limit, so a full task
// list could become permanently unsavable with only load-time truncation to
// notice, and silently).
var MAX_STATE_BYTES = 5242880

// Budget serialize()/serializeNotes() actually write to, below the hard
// ceiling: JSON.stringify(..., null, 2)'s per-item indentation/newlines
// aren't counted by the compact per-item estimate below, and up to
// MAX_ITEMS small items each add a fixed slice of that. 768 KiB comfortably
// covers indentation for a full 5000-item list while leaving ~4.5 MiB of
// real, usable budget.
var SERIALIZE_BUDGET = MAX_STATE_BYTES - 786432
var PRETTY_OVERHEAD_PER_ITEM = 96

// Worst case for one not-yet-added item — used by canAddItem() so the UI
// never accepts an item serialize()/serializeNotes() would then have to
// silently drop. Two things this needs to get right, both found by
// deliberately trying to break this gate rather than just exercising the
// happy path:
//   1. Bytes-per-JS-char: a 4-byte UTF-8 codepoint needs a surrogate pair in
//      JS strings (2 UTF-16 units for those 4 bytes = 2 bytes/unit); a
//      3-byte BMP codepoint needs only 1 unit (3 bytes/unit) — that's the
//      real worst case per unit of clampText()'s length limit, not 4.
//   2. Field count: a task has one long field (text), but a note has TWO
//      independently MAX_TEXT_LEN-capped fields (title + body). Sizing this
//      off a single field (a task's worst case) let canAddItem() approve a
//      note near the budget boundary that serializeNotes() then had to
//      drop — reproducing the exact bug this cap exists to prevent, just in
//      a narrower window. Must cover the worse of the two callers.
var MAX_ITEM_BYTES = MAX_TEXT_LEN * 3 * 2 + PRETTY_OVERHEAD_PER_ITEM + 2048

function clampText(s, max) {
  s = typeof s === "string" ? s : ""
  return s.length > max ? s.slice(0, max) : s
}

// Real UTF-8 byte length, not JS string length (which counts UTF-16 code
// units) — needed because the helper's max_bytes check is a byte count.
// encodeURIComponent turns every non-ASCII byte into a "%XX" escape, so
// counting each escape as one byte and everything else as-is recovers the
// true UTF-8 length without needing TextEncoder (not guaranteed present in
// this QML JS engine).
function byteLength(s) {
  return encodeURIComponent(s).replace(/%[0-9A-F]{2}/g, "x").length
}

function estimatedBytes(list) {
  return list.reduce(function(sum, item) { return sum + byteLength(JSON.stringify(item)) + PRETTY_OVERHEAD_PER_ITEM }, 64)
}

// Exposed the same way as monthNames() above — a function, not a bare
// top-level var, so it's reliably visible on the imported module object.
// Previously these caps were only applied on load (parse/parseNotes),
// which left creating/editing a task or note, and serialize()/
// serializeNotes(), able to write out an unbounded array or unbounded
// per-item text — the cap only bit once, on the *next* app restart.
// Every mutation path (Panel.qml's add/edit) and every write path
// (serialize/serializeNotes below) now goes through these too.
function maxItems() { return MAX_ITEMS }
function maxTextLen() { return MAX_TEXT_LEN }

// Whether `list` has room for one more item — checked by the composer/
// editor before pushing a new task or note. Both the item-count cap load()
// enforces AND the serialize() byte budget above must hold: count alone
// used to let the UI accept an item that serialize() would then silently
// drop (or that the helper would flat-out refuse to write), leaving state
// the UI showed as saved but that never actually reached disk.
function canAddItem(list) {
  if (list.length >= MAX_ITEMS) return false
  return estimatedBytes(list) + MAX_ITEM_BYTES <= SERIALIZE_BUDGET
}

// v1/v2 files stored day:"today"|"tomorrow" instead of a real date, and may
// be missing `order`. Both get backfilled on load so old data keeps working.
function parse(raw) {
  if (!raw || !raw.trim()) return []
  if (raw.length > MAX_RAW_LEN) {
    console.warn("io.github.osungjinwoo.omatask: tasks.json too large, ignoring")
    return []
  }
  try {
    var data = JSON.parse(raw)
    if (!data || !Array.isArray(data.tasks)) return []
    var today = todayISO()
    return data.tasks.slice(0, MAX_ITEMS).map(function(t, i) {
      if (typeof t.order !== "number") t.order = i
      if (!t.date) t.date = t.day === "tomorrow" ? addDaysISO(today, 1) : today
      t.text = clampText(t.text, MAX_TEXT_LEN)
      return t
    })
  } catch (e) {
    console.warn("io.github.osungjinwoo.omatask: failed to parse tasks.json:", e)
    return []
  }
}

// ---------------- notes ----------------

function makeNote(title, body, order) {
  return {
    id: makeId("n"),
    title: clampText(title || "", MAX_TEXT_LEN),
    body: clampText(body || "", MAX_TEXT_LEN),
    order: order || 0,
    updatedAt: Date.now()
  }
}

function notePreview(note) {
  var firstLine = note.body.split("\n").filter(function(l) { return l.trim().length > 0 })[0] || ""
  return firstLine.slice(0, 60)
}

function serializeNotes(notes) {
  var bounded = []
  var used = 64
  for (var i = 0; i < notes.length && bounded.length < MAX_ITEMS; i++) {
    var copy = Object.assign({}, notes[i])
    copy.title = clampText(copy.title, MAX_TEXT_LEN)
    copy.body = clampText(copy.body, MAX_TEXT_LEN)
    var itemBytes = byteLength(JSON.stringify(copy)) + PRETTY_OVERHEAD_PER_ITEM
    if (used + itemBytes > SERIALIZE_BUDGET) break
    used += itemBytes
    bounded.push(copy)
  }
  return JSON.stringify({ version: 1, notes: bounded }, null, 2) + "\n"
}

function parseNotes(raw) {
  if (!raw || !raw.trim()) return []
  if (raw.length > MAX_RAW_LEN) {
    console.warn("io.github.osungjinwoo.omatask: notes.json too large, ignoring")
    return []
  }
  try {
    var data = JSON.parse(raw)
    if (!data || !Array.isArray(data.notes)) return []
    return data.notes.slice(0, MAX_ITEMS).map(function(n, i) {
      if (typeof n.order !== "number") n.order = i
      n.title = clampText(n.title, MAX_TEXT_LEN)
      n.body = clampText(n.body, MAX_TEXT_LEN)
      return n
    })
  } catch (e) {
    console.warn("io.github.osungjinwoo.omatask: failed to parse notes.json:", e)
    return []
  }
}

// ---------------- natural-language date/time (Todoist-style) ----------------
// Typing "reunião amanhã 15h" should be enough — no picker required. This
// scans the raw composer text for a date phrase and a time phrase, strips
// whatever it finds from the text, and reports the ISO date / "HH:MM" it
// detected so the caller can fill composerDate/composerTime and save a
// clean title. Accent-insensitive (users won't always type "ã"/"á").

function foldAccents(s) {
  return s
    .replace(/[áàâã]/g, "a").replace(/[ÁÀÂÃ]/g, "A")
    .replace(/[éê]/g, "e").replace(/[ÉÊ]/g, "E")
    .replace(/[í]/g, "i").replace(/[Í]/g, "I")
    .replace(/[óôõ]/g, "o").replace(/[ÓÔÕ]/g, "O")
    .replace(/[ú]/g, "u").replace(/[Ú]/g, "U")
    .replace(/[ç]/g, "c").replace(/[Ç]/g, "C")
}

var WEEKDAY_PATTERNS = [
  { dow: 0, re: /\bdomingo\b/ },
  { dow: 1, re: /\bsegunda(?:-feira)?\b/ },
  { dow: 2, re: /\bterca(?:-feira)?\b/ },
  { dow: 3, re: /\bquarta(?:-feira)?\b/ },
  { dow: 4, re: /\bquinta(?:-feira)?\b/ },
  { dow: 5, re: /\bsexta(?:-feira)?\b/ },
  { dow: 6, re: /\bsabado\b/ }
]

// Next date (today included) that falls on weekday `dow`, counting from
// `refISO`. Bare weekday names mean "the next one", same as Todoist.
function nextDateForWeekday(dow, refISO) {
  var ref = fromISO(refISO)
  var diff = (dow - ref.getDay() + 7) % 7
  ref.setDate(ref.getDate() + diff)
  return toISO(ref)
}

// Tries each date pattern against the folded/lowercased text and returns
// {index, length, iso} for the first one found, or null. Order matters:
// explicit dd/mm beats relative words beats bare weekday names, so
// "sexta 15/08" resolves to the explicit date, not the weekday.
function findDatePhrase(folded, refISO) {
  var m

  m = /\b(\d{1,2})[\/\-](\d{1,2})(?:[\/\-](\d{2,4}))?\b/.exec(folded)
  if (m) {
    var day = Number(m[1]), month = Number(m[2]) - 1
    var year = m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : fromISO(refISO).getFullYear()
    var d = new Date(year, month, day)
    if (d.getMonth() === month && d.getDate() === day) {
      // A bare "dd/mm" that already passed this year rolls to next year —
      // typing "3/1" in December almost certainly means next January, not
      // eleven months ago.
      if (!m[3] && toISO(d) < refISO) d = new Date(year + 1, month, day)
      return { index: m.index, length: m[0].length, iso: toISO(d) }
    }
  }

  m = /\bdepois\s*de\s*amanha\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, iso: addDaysISO(refISO, 2) }

  m = /\bamanha\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, iso: addDaysISO(refISO, 1) }

  m = /\bhoje\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, iso: refISO }

  m = /\b(?:daqui\s*a|em)\s*(\d{1,2})\s*dias?\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, iso: addDaysISO(refISO, Number(m[1])) }

  m = /\bsemana\s*que\s*vem\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, iso: addDaysISO(refISO, 7) }

  for (var i = 0; i < WEEKDAY_PATTERNS.length; i++) {
    m = WEEKDAY_PATTERNS[i].re.exec(folded)
    if (m) return { index: m.index, length: m[0].length, iso: nextDateForWeekday(WEEKDAY_PATTERNS[i].dow, refISO) }
  }

  return null
}

function findTimePhrase(folded) {
  var m

  m = /\bmeio[\s-]?dia\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, hhmm: "12:00" }

  m = /\bmeia[\s-]?noite\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, hhmm: "00:00" }

  m = /\bas\s*(\d{1,2})(?:[h:](\d{2}))?\s*h?\b/.exec(folded)
  if (m && Number(m[1]) <= 23) return { index: m.index, length: m[0].length, hhmm: pad2(Number(m[1])) + ":" + pad2(Number(m[2] || 0)) }

  m = /\b(\d{1,2})h(\d{2})?\b/.exec(folded)
  if (m && Number(m[1]) <= 23) return { index: m.index, length: m[0].length, hhmm: pad2(Number(m[1])) + ":" + pad2(Number(m[2] || 0)) }

  m = /\b([01]?\d|2[0-3]):([0-5]\d)\b/.exec(folded)
  if (m) return { index: m.index, length: m[0].length, hhmm: pad2(Number(m[1])) + ":" + m[2] }

  return null
}

// Removes a matched [index, index+length) span from `text` and tidies up
// the whitespace/punctuation left behind (a lone comma, doubled spaces).
function stripSpan(text, index, length) {
  var out = text.slice(0, index) + text.slice(index + length)
  out = out.replace(/\s{2,}/g, " ")
  out = out.replace(/\s+,/g, ",").replace(/,\s*,/g, ",")
  out = out.replace(/^[\s,]+|[\s,]+$/g, "")
  return out
}

// Main entry point: scan `raw` for a date phrase and a time phrase, strip
// whatever was found, and report what was detected. `date`/`time` are null
// when nothing matched, so the caller can fall back to its own default.
function parseComposerText(raw, refISO) {
  var folded = foldAccents(raw).toLowerCase()
  var text = raw
  var date = null, time = null

  var dateHit = findDatePhrase(folded, refISO || todayISO())
  if (dateHit) {
    date = dateHit.iso
    text = stripSpan(text, dateHit.index, dateHit.length)
    folded = stripSpan(folded, dateHit.index, dateHit.length)
  }

  var timeHit = findTimePhrase(folded)
  if (timeHit) {
    time = timeHit.hhmm
    text = stripSpan(text, timeHit.index, timeHit.length)
  }

  return { text: text, date: date, time: time }
}
