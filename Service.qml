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

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/sung.omatask/"
  readonly property string tasksPath: stateDir + "tasks.json"
  readonly property string notesPath: stateDir + "notes.json"

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

  FileView {
    id: tasksFile
    path: root.tasksPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadTasks(text())
    onLoadFailed: root.loadTasks("")
  }
  FileView {
    id: notesFile
    path: root.notesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadNotes(text())
    onLoadFailed: root.loadNotes("")
  }

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

  Timer { id: saveTimer; interval: 200; repeat: false; onTriggered: tasksFile.setText(Store.serialize(root.tasks)) }
  Timer { id: saveNotesTimer; interval: 200; repeat: false; onTriggered: notesFile.setText(Store.serializeNotes(root.notes)) }

  Process { id: ensureDirProc; command: ["mkdir", "-p", root.stateDir] }

  Component.onCompleted: {
    ensureDirProc.running = true
    Qt.callLater(function() { tasksFile.reload(); notesFile.reload() })
  }
}
