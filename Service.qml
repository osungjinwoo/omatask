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

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/io.github.osungjinwoo.omatask/"
  readonly property string tasksPath: stateDir + "tasks.json"
  readonly property string notesPath: stateDir + "notes.json"

  // Upper bound on a state file we're willing to trust (bytes). Anything
  // bigger is treated as tampered/corrupt rather than parsed — private
  // task/note data should never grow anywhere near this from normal use.
  readonly property int maxStateFileBytes: 5242880

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
    onSaved: chmodTasksProc.running = true
  }
  FileView {
    id: notesFile
    path: root.notesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadNotes(text())
    onLoadFailed: root.loadNotes("")
    onSaved: chmodNotesProc.running = true
  }

  // FileView has no mode/permission property of its own, so a save via
  // atomicWrites (temp file + rename) picks up whatever umask this shell
  // process happens to run with. Force 0600 on every save rather than
  // trusting that.
  Process { id: chmodTasksProc; command: ["chmod", "600", root.tasksPath] }
  Process { id: chmodNotesProc; command: ["chmod", "600", root.notesPath] }

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

  // Runs once before the first load: creates the state dir as 0700 (not
  // whatever the ambient umask gives `mkdir -p`), then for each state file
  // — if present — refuses to trust it unless it's a regular file (not a
  // symlink someone swapped in), owned by us, and under maxStateFileBytes;
  // anything that fails those checks is deleted so the FileView below just
  // loads an empty default instead of silently reading through a symlink
  // or choking on a huge/corrupt file. Existing valid files get chmod 600.
  // All of dir/cap are fixed, non-attacker-controlled argv, not interpolated
  // into the script text, so there's no injection risk in using sh -c here.
  Process {
    id: sanitizeStateProc
    command: ["sh", "-c",
      'set -e; umask 077; dir="$1"; cap="$2"; install -d -m 700 "$dir"; me=$(id -un); for name in tasks.json notes.json; do f="$dir$name"; [ -e "$f" ] || continue; if [ -L "$f" ] || [ ! -f "$f" ]; then rm -f "$f"; continue; fi; info=$(stat -c "%U %a %s" "$f" 2>/dev/null) || { rm -f "$f"; continue; }; owner=${info%% *}; rest=${info#* }; perm=${rest%% *}; size=${rest#* }; if [ "$owner" != "$me" ] || [ "$size" -gt "$cap" ]; then rm -f "$f"; continue; fi; case "$perm" in 600|400) ;; *) chmod 600 "$f" ;; esac; done',
      "_", root.stateDir, String(root.maxStateFileBytes)]
    onExited: function() { tasksFile.reload(); notesFile.reload() }
  }

  Component.onCompleted: Qt.callLater(function() { sanitizeStateProc.running = true })
}
