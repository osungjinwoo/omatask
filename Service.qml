import QtQuick
import Quickshell
import Quickshell.Io
import "TodoStore.js" as Store

// Owns the single shared copy of tasks/notes for the whole shell process.
// omarchy-shell renders one BarWidget/Panel per monitor; each Panel used to
// hold its own private tasks/notes array, loaded from disk once at creation
// and never refreshed, so a task added on one screen's popup was invisible
// on every other screen's — they were three independent snapshots, not one
// shared list. Mounting this as a "service" (kind: service, loaded once by
// shell.qml's ensureService()) gives every monitor's Panel the same live
// object instead of a private copy.
Item {
  id: root

  property var shell: null

  property var tasks: []
  property bool tasksLoaded: false
  property var notes: []
  property bool notesLoaded: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/io.github.osungjinwoo.omatask"

  // Upper bound on a state file we're willing to trust (bytes). Anything
  // bigger is treated as tampered/corrupt rather than parsed — private
  // task/note data should never grow anywhere near this from normal use.
  readonly property int maxStateFileBytes: 5242880

  // All load/save of tasks.json/notes.json goes through this helper instead
  // of QML FileView + separate shell stat/chmod/rm-by-path calls. QML/JS has
  // no syscall access, and path-based checks are inherently TOCTOU-able — a
  // file at a path can be swapped between a check and a later act on that
  // same path. The helper opens the state directory once with O_NOFOLLOW and
  // does every filename lookup relative to that held directory fd, rejects
  // symlinks/FIFOs at open() rather than via a separate stat, quarantines an
  // invalid file by hardlinking the exact fd it already validated (immune to
  // the path being swapped again afterward), and writes via a private
  // temp-file + fsync + atomic rename with permissions set before the file
  // ever has its real name. See statehelper.py's own docstring for the full
  // rationale (this replaced a design flagged by marketplace review as
  // TOCTOU-prone: separate check-then-reload-by-path, and a post-save chmod
  // that could itself follow a symlink swapped in after the save).
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("statehelper.py").toString().replace(/^file:\/\//, ""))

  // "concluídas hoje" in the header — shared so completing a task from any
  // monitor's popup updates the count everywhere, not just on that screen.
  property int doneToday: 0

  // Live "today", re-derived on a timer rather than read once at creation.
  // This process runs for weeks without restarting, so a plain `Store.todayISO()`
  // default value would freeze at whatever day the service happened to start
  // on — pendingTodayCount/hasOverdue (the bar badge) and every Panel's
  // rolled-forward "Hoje" view need this to actually track the calendar.
  property string todayISO: Store.todayISO()
  property bool tick: false

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      root.tick = !root.tick
      var fresh = Store.todayISO()
      if (fresh !== root.todayISO) root.todayISO = fresh
    }
  }

  // What the bar badge shows: today's own tasks plus every still-open task
  // left behind on an earlier day (see Store.tasksForView) — an unfinished
  // task never just quietly disappears once its original day is gone.
  readonly property var todayTasks: (root.tick, Store.tasksForView(root.tasks, root.todayISO))
  readonly property int pendingTodayCount: todayTasks.length
  readonly property bool hasOverdue: todayTasks.some(function(t) { return Store.isOverdue(t) })

  function loadTasks(raw) {
    if (root.tasksLoaded) return
    root.tasks = Store.parse(raw)
    root.tasksLoaded = true
  }
  function loadNotes(raw) {
    if (root.notesLoaded) return
    root.notes = Store.parseNotes(raw)
    root.notesLoaded = true
  }

  function scheduleSave() {
    if (!root.tasksLoaded) return
    saveTimer.restart()
  }
  function scheduleSaveNotes() {
    if (!root.notesLoaded) return
    saveNotesTimer.restart()
  }
  onTasksChanged: scheduleSave()
  onNotesChanged: scheduleSaveNotes()

  Timer { id: saveTimer; interval: 200; repeat: false; onTriggered: root.runSave(saveTasksProc, "tasks.json", Store.serialize(root.tasks)) }
  Timer { id: saveNotesTimer; interval: 200; repeat: false; onTriggered: root.runSave(saveNotesProc, "notes.json", Store.serializeNotes(root.notes)) }

  function helperCommand(op, name) {
    return ["python3", root.helperPath, root.stateDir, op, name, String(root.maxStateFileBytes)]
  }

  function runSave(proc, name, content) {
    proc._pending = content
    proc.command = root.helperCommand("save", name)
    proc.running = true
  }

  // Load: one helper invocation does the fd-safe open/validate/read in a
  // single step, so there's no separate "check the path, then later load
  // the path" gap for anything to race into. A non-zero exit (helper
  // couldn't even open/create the state dir) is treated the same as "no
  // file yet" — start empty — never as "trust whatever stdout there is".
  Process {
    id: loadTasksProc
    command: root.helperCommand("load", "tasks.json")
    stdout: StdioCollector { id: loadTasksOut; waitForEnd: true }
    onExited: function(exitCode) { root.loadTasks(exitCode === 0 ? loadTasksOut.text : "") }
  }
  Process {
    id: loadNotesProc
    command: root.helperCommand("load", "notes.json")
    stdout: StdioCollector { id: loadNotesOut; waitForEnd: true }
    onExited: function(exitCode) { root.loadNotes(exitCode === 0 ? loadNotesOut.text : "") }
  }

  // Save: content is written to the helper's stdin (same reasoning as
  // copyNote()'s wl-copy call below in Panel.qml — argv is visible to other
  // local users via /proc/<pid>/cmdline, so private task/note text never
  // goes there). The helper writes to a private temp file, chmods/fsyncs
  // it, then atomically renames it into place — permissions land before the
  // name is public, so there's no window for a separate later chmod-by-path
  // to land on a symlink swapped in after the fact.
  Process {
    id: saveTasksProc
    property string _pending: ""
    stdinEnabled: true
    onStarted: { var d = _pending; _pending = ""; write(d); stdinEnabled = false }
    onExited: function(exitCode) { if (exitCode !== 0) console.warn("io.github.osungjinwoo.omatask: failed to save tasks.json") }
  }
  Process {
    id: saveNotesProc
    property string _pending: ""
    stdinEnabled: true
    onStarted: { var d = _pending; _pending = ""; write(d); stdinEnabled = false }
    onExited: function(exitCode) { if (exitCode !== 0) console.warn("io.github.osungjinwoo.omatask: failed to save notes.json") }
  }

  Component.onCompleted: Qt.callLater(function() {
    loadTasksProc.running = true
    loadNotesProc.running = true
  })
}
