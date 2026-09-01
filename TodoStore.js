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
    text: text,
    date: dateISO,
    time: time || "",
    priority: priority || "normal",
    order: order || 0,
    createdAt: Date.now()
  }
}

function serialize(tasks) {
  return JSON.stringify({ version: 3, tasks: tasks }, null, 2) + "\n"
}

// Defensive caps applied on load: a tampered/corrupt state file (e.g. one
// that slipped past Service.qml's size check, or was hand-edited) should
// degrade to "truncated" rather than hand an unbounded array or unbounded
// per-item strings to the UI/render layer.
var MAX_ITEMS = 5000
var MAX_TEXT_LEN = 20000
var MAX_RAW_LEN = 8 * 1024 * 1024

function clampText(s, max) {
  s = typeof s === "string" ? s : ""
  return s.length > max ? s.slice(0, max) : s
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
    title: title || "",
    body: body || "",
    order: order || 0,
    updatedAt: Date.now()
  }
}

function notePreview(note) {
  var firstLine = note.body.split("\n").filter(function(l) { return l.trim().length > 0 })[0] || ""
  return firstLine.slice(0, 60)
}

function serializeNotes(notes) {
  return JSON.stringify({ version: 1, notes: notes }, null, 2) + "\n"
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
