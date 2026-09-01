import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TodoStore.js" as Store

// v0.2: adds Notes mode, manual drag reorder (tasks + notes), a day-agenda
// timeline, a one-shot "organize by priority" action, and a real
// QtQuick.Particles dissolve on complete/delete (scattered from the row's
// area rather than glyph-masked — grabToImage+MaskShape would be fragile to
// tune without a visual feedback loop).
Panel {
  id: root
  moduleName: "sung.omatask"
  ipcTarget: "sung.omatask"
  manageIpc: false // BarWidget.qml already owns the IpcHandler for this target

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The one shared state instance for the whole shell process (see
  // Service.qml) — every monitor's Panel reads/writes through this instead
  // of holding a private copy, so a task added on one screen shows up on
  // all of them. Injected by BarWidget.qml's injectPanel().
  property var service: null

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dividerColor: Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, 0.12)

  property string activeMode: "tasks" // "tasks" | "notes"

  // ---------------- shared task state (owned by Service.qml) ----------------
  readonly property var tasks: root.service ? root.service.tasks : []

  // "today" always means the real calendar day, independent of whichever
  // day the panel happens to be browsing — the bar badge/overdue pulse must
  // stay anchored to reality, not to viewDate. Sourced from the service so
  // it's live even when this particular Panel has never been opened today.
  readonly property var todayTasks: root.service ? root.service.todayTasks : []
  readonly property int pendingTodayCount: root.service ? root.service.pendingTodayCount : 0
  readonly property bool hasOverdue: root.service ? root.service.hasOverdue : false

  // The single day currently being browsed. ‹ › shift it by one day; the
  // task list, agenda and header all follow it. Kept as `activeTasks` below
  // (not renamed) so the rest of the file — drag, cursor, rendering — didn't
  // need touching just because the day model changed underneath it.
  // Browsing "Hoje" specifically also rolls forward every still-open task
  // left behind on an earlier day (see Store.tasksForView) — an unfinished
  // task from three days ago doesn't just quietly sit on that old day where
  // nobody will ever look again, it stays a visible pendency until it's
  // actually completed, postponed or deleted.
  property string viewDate: Store.todayISO()
  readonly property var activeTasks: Store.sortByOrder(Store.tasksForView(root.tasks, root.viewDate))
  readonly property var timedTasks: root.activeTasks.filter(function(t) { return !!t.time })
  readonly property bool viewingToday: root.viewDate === Store.todayISO()

  readonly property real agendaPxPerHour: Style.space(30)
  readonly property int agendaStart: {
    var hours = root.timedTasks.map(function(t) { return Math.floor(Store.timeDecimal(t.time)) })
    hours.push(7)
    if (root.viewingToday) hours.push(Math.floor(Store.nowDecimal()))
    return Math.min.apply(null, hours)
  }
  readonly property int agendaEnd: {
    var hours = root.timedTasks.map(function(t) { return Math.ceil(Store.timeDecimal(t.time)) })
    hours.push(23)
    if (root.viewingToday) hours.push(Math.ceil(Store.nowDecimal()) + 1)
    return Math.max.apply(null, hours)
  }

  // ---------------- shared note state (owned by Service.qml) ----------------
  readonly property var notes: root.service ? root.service.notes : []
  readonly property var sortedNotes: Store.sortByOrder(root.notes)
  property string notesView: "grid" // "grid" | "editor"
  property string editingNoteId: ""

  // ---------------- task composer state ----------------
  property string editingId: ""
  property string composerText: ""
  property string composerPriority: "normal"
  property string composerDate: Store.todayISO()
  property string composerTime: ""
  readonly property bool isEditing: editingId !== ""

  // Live preview of what addOrSaveTask() would detect in the current text
  // (e.g. typing "reunião amanhã 15h" lights this up as "Amanhã · 15:00")
  // — the actual date/time only gets applied on submit, this is just
  // feedback so the picker isn't the only way to know it worked.
  readonly property var composerParsePreview: Store.parseComposerText(root.composerText, root.composerDate)

  // ---------------- keyboard cursor (tasks) ----------------
  property bool cursorActive: false
  property int cursorIndex: -1

  function clampCursor() {
    if (root.activeTasks.length === 0) { root.cursorIndex = -1; return }
    if (root.cursorIndex > root.activeTasks.length - 1) root.cursorIndex = root.activeTasks.length - 1
  }
  onActiveTasksChanged: clampCursor()
  onOpenedChanged: if (!opened) root.cursorActive = false

  // ---------------- drag-to-reorder (shared by tasks + notes) ----------------
  // Deliberately simple: the dragged row shows a floating label + a drop
  // line while dragging; siblings do not live-shuffle (that needs a real
  // ListModel with move() semantics to keep delegate identity across a
  // Repeater rebuild — plain-array + Repeater always destroys/recreates on
  // change). The reorder itself still commits correctly on release.
  readonly property var emptyDragState: ({ active: false, kind: "", id: "", label: "", listTop: 0, itemH: 1, grabOffset: 0, localY: 0, targetIndex: -1, count: 0 })
  property var dragState: emptyDragState

  // `contentItem` is the shared overlay's coordinate space (contentRoot,
  // spanning the whole popup) — the ghost/drop-line render there. `rowItem`
  // is the delegate being dragged; its *parent* is the list's own content
  // Item, which is a different coordinate space than contentRoot (offset by
  // the mode switch, tabs, scroll position, ...). listTop bridges the two:
  // everything below is computed in list-local terms and only converted to
  // contentRoot coordinates at render time (localY + listTop). itemH is the
  // per-row spacing for THIS list — notes use a taller row than tasks.
  function beginDrag(kind, id, label, count, currentIndex, itemH, rowItem, handleItem, contentItem, mouse) {
    var mouseP = handleItem.mapToItem(contentItem, mouse.x, mouse.y)
    var listTopP = rowItem.parent.mapToItem(contentItem, 0, 0)
    root.dragState = { active: true, kind: kind, id: id, label: label,
      listTop: listTopP.y, itemH: itemH,
      grabOffset: mouseP.y - listTopP.y - currentIndex * itemH,
      localY: currentIndex * itemH,
      targetIndex: currentIndex, count: count }
  }
  function updateDrag(handleItem, contentItem, mouse) {
    if (!root.dragState.active) return
    var mouseP = handleItem.mapToItem(contentItem, mouse.x, mouse.y)
    var localY = mouseP.y - root.dragState.listTop - root.dragState.grabOffset
    var idx = Math.max(0, Math.min(root.dragState.count - 1, Math.round(localY / root.dragState.itemH)))
    root.dragState = Object.assign({}, root.dragState, { localY: localY, targetIndex: idx })
  }
  function endDrag() {
    if (!root.dragState.active) return
    if (root.dragState.kind === "task") root.commitTaskReorder(root.dragState.id, root.dragState.targetIndex)
    else if (root.dragState.kind === "note") root.commitNoteReorder(root.dragState.id, root.dragState.targetIndex)
    root.dragState = root.emptyDragState
  }
  readonly property real rowH: Style.space(52)
  readonly property real noteRowH: root.rowH * 1.5

  function commitTaskReorder(id, targetIndex) {
    if (!root.service) return
    var arr = root.activeTasks.slice()
    var curIdx = arr.findIndex(function(t) { return t.id === id })
    if (curIdx === -1 || targetIndex === curIdx) return
    var item = arr.splice(curIdx, 1)[0]
    arr.splice(targetIndex, 0, item)
    arr.forEach(function(t, i) { t.order = i })
    root.service.tasks = root.tasks.slice()
  }

  function commitNoteReorder(id, targetIndex) {
    if (!root.service) return
    var arr = root.sortedNotes.slice()
    var curIdx = arr.findIndex(function(n) { return n.id === id })
    if (curIdx === -1 || targetIndex === curIdx) return
    var item = arr.splice(curIdx, 1)[0]
    arr.splice(targetIndex, 0, item)
    arr.forEach(function(n, i) { n.order = i })
    root.service.notes = root.notes.slice()
  }

  function organizeByPriority() {
    if (!root.service) return
    Store.assignPriorityOrder(root.activeTasks)
    root.service.tasks = root.tasks.slice()
  }

  // Keep "atrasada" honest without requiring interaction, and keep the
  // "Hoje" tab pinned to the real calendar day: omarchy-shell is a single
  // long-running process and this Panel instance is never recreated, so
  // without actively re-syncing, viewDate would freeze at whatever day it
  // happened to be when the panel first loaded and "Hoje" would silently
  // stop being today — exactly why old pending tasks stopped rolling
  // forward. trackedToday remembers what "today" was as of the last tick;
  // if viewDate was still following it (i.e. the user hadn't manually
  // browsed to a different day), it advances viewDate along with it.
  property bool tasksTick: false
  property string trackedToday: Store.todayISO()
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      root.tasksTick = !root.tasksTick
      var fresh = Store.todayISO()
      if (fresh !== root.trackedToday) {
        if (root.viewDate === root.trackedToday) root.viewDate = fresh
        root.trackedToday = fresh
      }
    }
  }

  // ---------------- task actions ----------------
  function addOrSaveTask() {
    if (!root.service) return
    var raw = root.composerText.trim()
    if (!raw) { root.resetComposer(); return }

    // "reunião amanhã 15h" — a date/time phrase found in the text wins over
    // whatever the 📅/🕐 pickers currently hold (that's the whole point:
    // type it and it's set, no click required) and gets stripped from the
    // saved title. If the phrase would eat the entire text (e.g. just
    // "amanhã" with no title), keep the original text instead of saving a
    // blank task.
    var parsed = Store.parseComposerText(raw, root.composerDate)
    var text = parsed.text.trim() || raw
    var time = parsed.time || (/^([01]\d|2[0-3]):[0-5]\d$/.test(root.composerTime) ? root.composerTime : "")
    root.composerDate = parsed.date || root.composerDate

    if (root.isEditing) {
      root.service.tasks = root.tasks.map(function(t) {
        if (t.id !== root.editingId) return t
        var copy = Object.assign({}, t)
        copy.text = text; copy.priority = root.composerPriority; copy.date = root.composerDate; copy.time = time
        return copy
      })
    } else {
      var list = root.tasks.slice()
      var date = root.composerDate
      var bucket = Store.tasksForDate(root.tasks, date)
      list.push(Store.makeTask(text, date, time, root.composerPriority, Store.minOrder(bucket) - 1))
      root.service.tasks = list
      root.viewDate = date
    }
    root.resetComposer()
  }

  function resetComposer() {
    root.editingId = ""
    root.composerText = ""
    root.composerPriority = "normal"
    root.composerDate = root.viewDate
    root.composerTime = ""
    taskInput.text = ""
  }

  function startEdit(task) {
    root.editingId = task.id
    root.composerText = task.text
    root.composerPriority = task.priority
    root.composerDate = task.date
    root.composerTime = task.time
    taskInput.text = task.text
    Qt.callLater(function() { taskInput.forceActiveFocus(); taskInput.selectAll() })
  }

  function removeTaskNow(id) {
    if (!root.service) return
    root.service.tasks = root.tasks.filter(function(t) { return t.id !== id })
    if (root.editingId === id) root.resetComposer()
  }

  function setTaskDate(task, iso) {
    if (!root.service) return
    root.service.tasks = root.tasks.map(function(t) {
      if (t.id !== task.id) return t
      var copy = Object.assign({}, t)
      copy.date = iso
      return copy
    })
  }

  function postponeTask(task) {
    if (!root.service) return
    // "Adiar" always means push to tomorrow relative to today, not to
    // task.date + 1: for an overdue task rolled into the Hoje view from a
    // few days back, date+1 would still land in the past and it would stay
    // stuck showing as overdue right after being "postponed".
    var base = task.date < Store.todayISO() ? Store.todayISO() : task.date
    var target = Store.addDaysISO(base, 1)
    var bucket = Store.tasksForDate(root.tasks, target)
    root.service.tasks = root.tasks.map(function(t) {
      if (t.id !== task.id) return t
      var copy = Object.assign({}, t)
      copy.date = target
      copy.order = Store.maxOrder(bucket) + 1
      return copy
    })
  }

  function cyclePriority() {
    var order = ["normal", "urgent", "whenever"]
    root.composerPriority = order[(order.indexOf(root.composerPriority) + 1) % order.length]
  }

  function priorityLabel(p) { return p === "urgent" ? "Urgente" : p === "whenever" ? "Pode esperar" : "Normal" }
  function priorityColor(p) { return p === "urgent" ? Color.urgent : p === "whenever" ? Color.muted : Color.accent }

  // ---------------- note actions ----------------
  function openNoteEditor(note) {
    root.editingNoteId = note ? note.id : ""
    noteTitleInput.text = note ? note.title : ""
    noteBodyEdit.text = note ? note.body : ""
    root.notesView = "editor"
    Qt.callLater(function() { noteBodyEdit.forceActiveFocus() })
  }
  function closeNoteEditor() {
    root.notesView = "grid"
    root.editingNoteId = ""
    noteTitleInput.text = ""
    noteBodyEdit.text = ""
  }
  function saveNote() {
    if (!root.service) return
    var body = noteBodyEdit.text
    if (!body.trim()) { root.closeNoteEditor(); return }
    var title = noteTitleInput.text.trim()
    if (root.editingNoteId) {
      root.service.notes = root.notes.map(function(n) {
        if (n.id !== root.editingNoteId) return n
        var copy = Object.assign({}, n)
        copy.title = title; copy.body = body; copy.updatedAt = Date.now()
        return copy
      })
    } else {
      var list = root.notes.slice()
      list.push(Store.makeNote(title, body, Store.minOrder(root.notes) - 1))
      root.service.notes = list
    }
    root.closeNoteEditor()
  }
  function removeNoteNow(id) {
    if (!root.service) return
    root.service.notes = root.notes.filter(function(n) { return n.id !== id })
    if (root.editingNoteId === id) root.closeNoteEditor()
  }
  function copyNote(note) {
    copyProc.command = ["wl-copy", note.body]
    copyProc.running = true
  }

  Process {
    id: copyProc
  }

  // Shared across monitors (Service.qml) so completing a task from any
  // screen's popup updates the "concluídas hoje" count on all of them.
  readonly property int doneToday: root.service ? root.service.doneToday : 0

  // ---------------- dissolve-then-remove (real removal happens in the
  // effect's finished() handler so the row visibly disappears in sync) ----
  function debugDissolveFirst() {
    if (root.activeTasks.length > 0) root.completeTask(root.activeTasks[0])
  }
  function completeTask(task) { if (root.service) root.service.doneToday += 1; root.dissolveTask(task, Color.accent) }
  function deleteTask(task) { root.dissolveTask(task, Color.muted) }
  function dissolveTask(task, tint) {
    var idx = root.activeTasks.findIndex(function(t) { return t.id === task.id })
    var el = taskRepeater.itemAt(idx)
    if (!el) { root.removeTaskNow(task.id); return }
    el.dissolve(tint, function() { root.removeTaskNow(task.id) })
  }
  function deleteNote(note) {
    var el = noteRepeater.itemAt(root.sortedNotes.findIndex(function(n) { return n.id === note.id }))
    if (!el) { root.removeNoteNow(note.id); return }
    el.dissolve(Color.muted, function() { root.removeNoteNow(note.id) })
  }

  // ---------------- keyboard: tasks ----------------
  function moveCursor(dx, dy) {
    if (root.activeMode !== "tasks") return
    if (dx !== 0) {
      root.viewDate = Store.addDaysISO(root.viewDate, dx > 0 ? 1 : -1)
      root.cursorActive = true
      root.cursorIndex = root.activeTasks.length > 0 ? 0 : -1
      return
    }
    if (root.activeTasks.length === 0) return
    root.cursorActive = true
    root.cursorIndex = root.cursorIndex < 0 ? 0 : Math.max(0, Math.min(root.activeTasks.length - 1, root.cursorIndex + dy))
  }
  function activateCursor() {
    if (root.activeMode !== "tasks" || root.cursorIndex < 0 || root.cursorIndex >= root.activeTasks.length) return
    root.completeTask(root.activeTasks[root.cursorIndex])
  }
  function deleteCursor() {
    if (root.activeMode !== "tasks" || root.cursorIndex < 0 || root.cursorIndex >= root.activeTasks.length) return
    root.deleteTask(root.activeTasks[root.cursorIndex])
  }
  function onTextKey(t) {
    if (t === "t") { root.activeMode = "tasks"; return }
    if (t === "n") { root.activeMode = "notes"; return }
    if (root.activeMode !== "tasks") return
    if (root.cursorIndex < 0 || root.cursorIndex >= root.activeTasks.length) {
      if (t === "/") taskInput.forceActiveFocus()
      return
    }
    var task = root.activeTasks[root.cursorIndex]
    if (t === "e") root.startEdit(task)
    else if (t === "p") root.postponeTask(task)
    else if (t === "/") taskInput.forceActiveFocus()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(378))
    // No fixed guess: the mockup's .panel has no set height either, it just
    // wraps whatever's actually in it. A hardcoded height here (previously
    // Style.space(820)) left dead space whenever real content came in
    // shorter than the guess.
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: taskInput.activeFocus || noteTitleInput.activeFocus || noteBodyEdit.activeFocus
      onCloseRequested: {
        if (root.activeMode === "notes" && root.notesView === "editor") root.closeNoteEditor()
        else if (root.isEditing) root.resetComposer()
        else root.close()
      }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.onTextKey(t) }

      Item {
        id: contentRoot
        anchors.fill: parent

        Column {
          id: mainColumn
          anchors.fill: parent
          spacing: Style.space(8)

          // ---- header ----
          Row {
            width: parent.width
            Text {
              id: headerTitle
              text: root.activeMode === "tasks" ? "Tarefas" : "Notas"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
            }
            Item { width: parent.width - headerTitle.implicitWidth - headerSub.implicitWidth; height: 1 }
            Text {
              id: headerSub
              anchors.verticalCenter: parent.verticalCenter
              text: root.activeMode === "tasks"
                ? "concluídas hoje: " + root.doneToday
                : root.notes.length + (root.notes.length === 1 ? " nota" : " notas")
              color: root.activeMode === "tasks" ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.55)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.activeMode === "tasks"
              textFormat: Text.PlainText
            }
          }

          // ---- mode switch: sliding pill, not two loose buttons ----
          Rectangle {
            width: parent.width
            height: Style.space(32)
            radius: Style.space(6)
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.14)

            Rectangle {
              width: (parent.width - 4) / 2
              height: parent.height - 4
              x: (root.activeMode === "tasks" ? 2 : 2 + width)
              y: 2
              radius: Style.space(5)
              color: Style.hoverFillFor(root.contentForeground, Color.accent)
              border.width: 1
              border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
              Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }

            Row {
              anchors.fill: parent
              Item {
                width: parent.width / 2; height: parent.height
                Text {
                  anchors.centerIn: parent
                  text: "☑ Tarefas"
                  color: root.activeMode === "tasks" ? root.contentForeground : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.55)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: root.activeMode === "tasks"
                  textFormat: Text.PlainText
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.activeMode = "tasks" }
              }
              Item {
                width: parent.width / 2; height: parent.height
                Text {
                  anchors.centerIn: parent
                  text: "▤ Notas (" + root.notes.length + ")"
                  color: root.activeMode === "notes" ? root.contentForeground : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.55)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: root.activeMode === "notes"
                  textFormat: Text.PlainText
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.activeMode = "notes" }
              }
            }
          }

          // ================= TASKS =================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.activeMode === "tasks"

            // Day-by-day navigation instead of fixed Hoje/Amanhã tabs — any
            // date is a real date now, not just two hardcoded buckets.
            Row {
              id: tabsRow
              width: parent.width
              height: Style.space(28)

              Button {
                id: prevDayBtn
                iconText: "‹"
                iconSize: Style.font.title
                tooltipText: "Dia anterior"
                onClicked: { root.viewDate = Store.addDaysISO(root.viewDate, -1); root.cursorActive = false }
              }

              Item {
                id: dayLabelWrap
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: dayLabelCol.implicitWidth
                implicitHeight: dayLabelCol.implicitHeight
                Column {
                  id: dayLabelCol
                  spacing: 0
                  Row {
                    spacing: Style.space(6)
                    Text {
                      text: Store.dateLabel(root.viewDate)
                      color: root.viewingToday ? Color.accent : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      textFormat: Text.PlainText
                    }
                    Text {
                      visible: !root.viewingToday
                      text: "· hoje"
                      color: Color.accent
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      MouseArea { anchors.fill: parent; anchors.margins: -3; cursorShape: Qt.PointingHandCursor; onClicked: { root.viewDate = Store.todayISO(); root.cursorActive = false } }
                    }
                  }
                  Text {
                    text: root.activeTasks.length + (root.activeTasks.length === 1 ? " tarefa" : " tarefas")
                    color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption - 1
                    textFormat: Text.PlainText
                  }
                }
              }

              Button {
                id: nextDayBtn
                iconText: "›"
                iconSize: Style.font.title
                tooltipText: "Próximo dia"
                onClicked: { root.viewDate = Store.addDaysISO(root.viewDate, 1); root.cursorActive = false }
              }

              Item { width: tabsRow.width - prevDayBtn.width - dayLabelWrap.width - nextDayBtn.width - organizeBtn.width; height: 1 }

              Button {
                id: organizeBtn
                iconText: "⇅"
                tooltipText: "Organizar por prioridade agora (não fica ordenando sozinho depois)"
                fontSize: Style.font.caption
                onClicked: root.organizeByPriority()
              }
            }

            ScrollView {
              width: parent.width
              height: Style.space(340)
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              Item {
                width: parent.width
                height: Math.max(root.activeTasks.length * root.rowH, root.activeTasks.length === 0 ? Style.space(60) : 1)

                Text {
                  visible: root.activeTasks.length === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.space(18)
                  text: root.viewingToday ? "Nada pendente pra hoje." : "Nada marcado pra " + Store.dateLabel(root.viewDate).toLowerCase() + " ainda."
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  textFormat: Text.PlainText
                }

                Repeater {
                  id: taskRepeater
                  model: root.activeTasks

                  delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property var task: modelData
                    readonly property bool overdue: Store.isOverdue(task) && root.tasksTick !== undefined
                    // True only for a task rolled into "Hoje" from an
                    // earlier day (Store.tasksForView) — never true for a
                    // day's own tasks when browsing that day directly, so
                    // the ATRASADA badge can say which day it's actually
                    // from instead of just "overdue, somewhere".
                    readonly property bool rolledOver: task.date !== root.viewDate
                    readonly property bool hasCursor: root.cursorActive && root.cursorIndex === index
                    readonly property bool isDragging: root.dragState.active && root.dragState.kind === "task" && root.dragState.id === task.id
                    property bool dissolving: false

                    function dissolve(tint, onDone) {
                      dissolveFx.tint = tint
                      dissolveDone = onDone
                      dissolveFx.trigger()
                      row.dissolving = true
                    }
                    property var dissolveDone: null

                    width: parent.width
                    y: index * root.rowH
                    height: root.rowH - Style.space(2)
                    Behavior on y { enabled: !row.isDragging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutQuad } }
                    radius: Style.cornerRadius
                    opacity: row.dissolving ? 0 : (row.isDragging ? 0.35 : 1)
                    color: hasCursor ? Style.hoverFillFor(root.contentForeground, Color.accent)
                      : overdue ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.08)
                      : "transparent"
                    border.width: hasCursor ? 1.5 : 0
                    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)

                    Rectangle { width: 3; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; color: root.priorityColor(task.priority) }

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(6)
                      spacing: Style.space(6)

                      Text {
                        id: handle
                        text: "⠿"
                        color: Qt.darker(root.contentForeground, 1.7)
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: (rowHover.hovered || row.hasCursor || row.isDragging) ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        MouseArea {
                          anchors.fill: parent
                          anchors.margins: -5
                          cursorShape: Qt.SizeVerCursor
                          onPressed: function(mouse) { root.beginDrag("task", task.id, task.text, root.activeTasks.length, row.index, root.rowH, row, handle, contentRoot, mouse) }
                          onPositionChanged: function(mouse) { root.updateDrag(handle, contentRoot, mouse) }
                          onReleased: root.endDrag()
                        }
                      }

                      Rectangle {
                        id: check
                        width: Style.space(14); height: Style.space(14)
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: "transparent"
                        border.width: 1.5
                        border.color: task.priority === "urgent" ? Color.urgent : root.contentForeground
                        MouseArea {
                          anchors.fill: parent
                          anchors.margins: -4
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.completeTask(task)
                        }
                      }

                      Column {
                        width: parent.width - handle.width - check.width - actions.width - parent.spacing * 3
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                          width: parent.width
                          text: task.text
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                        }
                        Row {
                          spacing: Style.space(6)

                          // No box here — the mockup's .prio-label is plain
                          // colored text, letter-spaced, no background/border.
                          // Only the time gets the chip treatment below.
                          Text {
                            id: prioText
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.priorityLabel(task.priority).toUpperCase()
                            color: root.priorityColor(task.priority)
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 0.4
                            textFormat: Text.PlainText
                          }

                          Rectangle {
                            visible: !!task.time
                            height: Style.space(17)
                            width: timeText.implicitWidth + Style.space(10)
                            radius: Style.space(3)
                            color: row.overdue ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.18)
                              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
                            border.width: 1
                            border.color: row.overdue ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.45)
                              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.18)
                            Text {
                              id: timeText
                              anchors.centerIn: parent
                              text: task.time
                              color: row.overdue ? Color.urgent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.8)
                              font.family: root.contentFontFamily
                              font.pixelSize: Style.font.caption
                              font.bold: row.overdue
                              textFormat: Text.PlainText
                            }
                          }

                          Row {
                            visible: row.overdue
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(3)
                            SequentialAnimation on opacity {
                              running: row.overdue
                              loops: Animation.Infinite
                              NumberAnimation { from: 1.0; to: 0.55; duration: 800; easing.type: Easing.InOutQuad }
                              NumberAnimation { from: 0.55; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                            }
                            Text { anchors.verticalCenter: parent.verticalCenter; text: "⚠"; color: Color.urgent; font.pixelSize: Style.font.caption }
                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              text: row.rolledOver ? "ATRASADA · " + Store.dateLabel(task.date) : "ATRASADA"
                              color: Color.urgent
                              font.bold: true
                              font.family: root.contentFontFamily
                              font.pixelSize: Style.font.caption
                              textFormat: Text.PlainText
                            }
                          }
                        }
                      }

                      Row {
                        id: actions
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0
                        opacity: rowHover.hovered || row.hasCursor ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }

                        Button {
                          iconText: "→"
                          tooltipText: "Adiar pra " + Store.dateLabel(Store.addDaysISO(task.date < Store.todayISO() ? Store.todayISO() : task.date, 1)).toLowerCase()
                          fontSize: Style.font.caption
                          onClicked: root.postponeTask(task)
                        }
                        Button { iconText: "✎"; tooltipText: "Editar"; fontSize: Style.font.caption; onClicked: root.startEdit(task) }
                        Button { iconText: "🗑"; tooltipText: "Apagar"; fontSize: Style.font.caption; onClicked: root.deleteTask(task) }
                      }
                    }

                    HoverHandler { id: rowHover; onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorIndex = row.index } }

                    DissolveEffect {
                      id: dissolveFx
                      targetItem: row
                      onFinished: if (row.dissolveDone) row.dissolveDone()
                    }
                  }
                }
              }
            }

            Rectangle { width: parent.width; height: 1; color: root.dividerColor }

            // ---- agenda: day timeline for whichever tab is open ----
            Column {
              width: parent.width
              spacing: Style.space(4)

              Row {
                width: parent.width
                Text {
                  id: agendaLabel
                  text: "AGENDA"
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.bold: true
                  font.pixelSize: Style.font.caption
                  font.family: root.contentFontFamily
                  textFormat: Text.PlainText
                }
                Item { width: parent.width - agendaLabel.implicitWidth - agendaDayLabel.implicitWidth; height: 1 }
                Text {
                  id: agendaDayLabel
                  text: Store.dateLabel(root.viewDate).toLowerCase()
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.6)
                  font.pixelSize: Style.font.caption
                  font.family: root.contentFontFamily
                  textFormat: Text.PlainText
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(172)
                radius: Style.cornerRadius
                color: Style.controlFill(false, false, root.contentForeground, Color.accent)
                border.width: 1
                border.color: root.dividerColor
                clip: true

              Flickable {
                id: agendaFlick
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: (root.agendaEnd - root.agendaStart) * root.agendaPxPerHour

                Item {
                  width: parent.width
                  height: agendaFlick.contentHeight

                  // Faint background wash — a sibling, not a parent: opacity
                  // on a QtQuick Item cascades multiplicatively to children,
                  // so nesting the labels/markers inside a 3%-opacity
                  // Rectangle (an earlier version of this file did exactly
                  // that) made the entire agenda unreadable, not just tinted.
                  Rectangle { anchors.fill: parent; color: root.contentForeground; opacity: 0.03 }

                  Repeater {
                    model: root.agendaEnd - root.agendaStart + 1
                    delegate: Item {
                      required property int index
                      readonly property int hour: root.agendaStart + index
                      y: index * root.agendaPxPerHour
                      width: parent.width
                      Rectangle { width: parent.width; height: 1; color: root.dividerColor }
                      Text {
                        text: Store.pad2(hour) + ":00"
                        color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.55)
                        font.pixelSize: Style.font.caption - 1
                        font.family: root.contentFontFamily
                        x: 2; y: -6
                        textFormat: Text.PlainText
                      }
                    }
                  }

                  Rectangle {
                    visible: root.viewingToday
                    x: Style.space(28)
                    width: parent.width - Style.space(28)
                    height: 1
                    color: Color.accent
                    y: (Store.nowDecimal() - root.agendaStart) * root.agendaPxPerHour
                  }

                  Repeater {
                    model: root.timedTasks
                    delegate: Item {
                      required property var modelData
                      readonly property real dec: Store.timeDecimal(modelData.time)
                      x: Style.space(30)
                      y: (dec - root.agendaStart) * root.agendaPxPerHour - Style.space(6)
                      width: parent.width - Style.space(34)
                      height: Style.space(13)

                      Row {
                        spacing: Style.space(5)
                        Rectangle { width: 6; height: 6; radius: 3; anchors.verticalCenter: parent.verticalCenter; color: root.priorityColor(modelData.priority) }
                        Text { text: modelData.time; color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.7); font.pixelSize: Style.font.caption - 1; font.family: root.contentFontFamily; textFormat: Text.PlainText }
                        Text {
                          text: modelData.text
                          color: root.contentForeground
                          font.pixelSize: Style.font.caption - 1
                          font.family: root.contentFontFamily
                          elide: Text.ElideRight
                          width: Style.space(220)
                          textFormat: Text.PlainText
                        }
                      }
                    }
                  }
                }
              }
              }
            }

            Rectangle { width: parent.width; height: 1; color: root.dividerColor }

            // ---- composer ----
            Column {
              width: parent.width
              spacing: Style.space(6)

              Row {
                visible: root.isEditing
                width: parent.width
                spacing: Style.space(6)
                Text { text: "✎ editando tarefa"; color: Color.accent; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption; font.bold: true; textFormat: Text.PlainText }
                Button { text: "cancelar"; fontSize: Style.font.caption; onClicked: root.resetComposer() }
              }

              // One bordered pill holding everything — not a text field
              // sitting next to a row of separate boxed buttons.
              Rectangle {
                id: composerPill
                width: parent.width
                height: Style.space(34)
                radius: Style.cornerRadius
                color: Style.controlFill(taskInput.activeFocus, false, root.contentForeground, Color.accent)
                border.width: 1
                border.color: taskInput.activeFocus ? Color.accent
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.22)
                Behavior on border.color { ColorAnimation { duration: 120 } }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(3)
                  spacing: Style.space(3)

                  TextField {
                    id: taskInput
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - prioBtn.width - addBtn.width - parent.spacing * 2
                    placeholderText: "Nova tarefa... (ex: \"reunião amanhã 15h\")"
                    background: Item {}
                    leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                    onTextChanged: root.composerText = text
                    onAccepted: root.addOrSaveTask()
                    Keys.onEscapePressed: { if (root.isEditing) root.resetComposer(); taskInput.focus = false }
                  }
                  Button {
                    id: prioBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(26); height: Style.space(26)
                    iconText: "🚩"
                    iconSize: Style.font.body
                    tooltipText: "Prioridade: " + root.priorityLabel(root.composerPriority) + " (clique pra trocar)"
                    foreground: root.priorityColor(root.composerPriority)
                    bordered: root.composerPriority !== "normal"
                    onClicked: root.cyclePriority()
                  }

                  Button {
                    id: addBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(26); height: Style.space(26)
                    radius: width / 2
                    iconText: root.isEditing ? "✔" : "+"
                    iconSize: Style.font.title
                    tooltipText: root.isEditing ? "Salvar" : "Adicionar"
                    background: Color.accent
                    foreground: "#ffffff"
                    onClicked: root.addOrSaveTask()
                  }
                }
              }

              // Live feedback for the "type it, don't click it" flow: shows
              // what addOrSaveTask() would detect right now, so typing
              // "amanhã 15h" gets an immediate answer instead of a silent
              // picker click being the only confirmation.
              Text {
                readonly property var preview: root.composerParsePreview
                visible: !!preview.date || !!preview.time
                text: "detectado: " + [
                  preview.date ? Store.dateLabel(preview.date) : "",
                  preview.time || ""
                ].filter(function(s) { return !!s }).join(" · ")
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption - 1
                textFormat: Text.PlainText
              }
            }

            Text {
              width: parent.width
              text: "↑↓ navegar   ↔ aba   enter concluir   p postergar   e editar\nd apagar   / nova   t/n tarefas/notas   esc fechar"
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.35)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption - 1
              lineHeight: 1.5
              wrapMode: Text.NoWrap
              textFormat: Text.PlainText
            }
          }

          // ================= NOTES =================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.activeMode === "notes"

            Row {
              width: parent.width
              Button {
                text: root.notesView === "editor" ? "← voltar" : "+ Nova nota"
                bordered: true
                onClicked: root.notesView === "editor" ? root.closeNoteEditor() : root.openNoteEditor(null)
              }
            }

            ScrollView {
              visible: root.notesView === "grid"
              width: parent.width
              height: Style.space(430)
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              Item {
                width: parent.width
                height: Math.max(root.sortedNotes.length * root.noteRowH, root.sortedNotes.length === 0 ? Style.space(60) : 1)

                Text {
                  visible: root.sortedNotes.length === 0
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.space(18)
                  text: "Nenhuma nota ainda."
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  textFormat: Text.PlainText
                }

                Repeater {
                  id: noteRepeater
                  model: root.sortedNotes

                  delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property var note: modelData
                    readonly property bool isDragging: root.dragState.active && root.dragState.kind === "note" && root.dragState.id === note.id
                    readonly property real cardH: root.noteRowH
                    property bool dissolving: false

                    function dissolve(tint, onDone) {
                      cardDissolveFx.tint = tint
                      dissolveDone = onDone
                      cardDissolveFx.trigger()
                      card.dissolving = true
                    }
                    property var dissolveDone: null

                    width: parent.width
                    y: index * cardH
                    height: cardH - Style.space(4)
                    Behavior on y { enabled: !card.isDragging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutQuad } }
                    radius: Style.cornerRadius
                    opacity: card.dissolving ? 0 : (card.isDragging ? 0.35 : 1)
                    color: cardHover.hovered ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"

                    Rectangle { width: 3; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; color: Color.accent }

                    MouseArea {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(30)
                      onClicked: root.openNoteEditor(note)
                    }
                    HoverHandler { id: cardHover }

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(6)
                      spacing: Style.space(6)

                      Text {
                        id: noteHandle
                        text: "⠿"
                        color: Qt.darker(root.contentForeground, 1.7)
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: (cardHover.hovered || card.isDragging) ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        MouseArea {
                          anchors.fill: parent
                          anchors.margins: -5
                          cursorShape: Qt.SizeVerCursor
                          onPressed: function(mouse) { root.beginDrag("note", note.id, note.title || Store.notePreview(note), root.sortedNotes.length, card.index, root.noteRowH, card, noteHandle, contentRoot, mouse) }
                          onPositionChanged: function(mouse) { root.updateDrag(noteHandle, contentRoot, mouse) }
                          onReleased: root.endDrag()
                        }
                      }

                      Column {
                        width: parent.width - noteHandle.width - noteActions.width - parent.spacing * 2
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        Text {
                          width: parent.width
                          text: note.title || Store.notePreview(note) || "(sem título)"
                          font.bold: true
                          color: root.contentForeground
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                        }
                        Text {
                          width: parent.width
                          text: Store.notePreview(note)
                          color: Qt.darker(root.contentForeground, 1.4)
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Row {
                        id: noteActions
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: cardHover.hovered ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        Button { iconText: "⧉"; tooltipText: "Copiar"; fontSize: Style.font.caption; onClicked: root.copyNote(note) }
                        Button { iconText: "✎"; tooltipText: "Editar"; fontSize: Style.font.caption; onClicked: root.openNoteEditor(note) }
                        Button { iconText: "🗑"; tooltipText: "Apagar"; fontSize: Style.font.caption; onClicked: root.deleteNote(note) }
                      }
                    }

                    DissolveEffect { id: cardDissolveFx; targetItem: card; onFinished: if (card.dissolveDone) card.dissolveDone() }
                  }
                }
              }
            }

            // ---- note editor ----
            Column {
              visible: root.notesView === "editor"
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: noteTitleInput
                width: parent.width
                placeholderText: "Título (opcional)..."
              }

              Rectangle {
                width: parent.width
                height: Style.space(365)
                radius: Style.cornerRadius
                color: Style.controlFill(noteBodyEdit.activeFocus, noteBodyHover.hovered, root.contentForeground, Color.accent)
                border.width: 1
                border.color: noteBodyEdit.activeFocus ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.25)

                HoverHandler { id: noteBodyHover }

                Flickable {
                  id: noteBodyFlick
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  clip: true
                  contentWidth: width
                  contentHeight: Math.max(height, noteBodyEdit.paintedHeight)

                  TextEdit {
                    id: noteBodyEdit
                    width: noteBodyFlick.width
                    wrapMode: TextEdit.Wrap
                    // Non-negotiable: notes are pasted code/text that must never
                    // be interpreted. TextEdit defaults to auto-detecting HTML
                    // and switching render modes; PlainText disables that.
                    textFormat: TextEdit.PlainText
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    selectionColor: Style.selectionFillFor(root.contentForeground, Color.accent)
                    selectedTextColor: root.contentForeground
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(6)
                Button { text: "cancelar"; bordered: true; onClicked: root.closeNoteEditor() }
                Button { iconText: "✔"; text: "salvar"; onClicked: root.saveNote() }
              }
            }
          }
        }

        // ---- drag ghost + drop line, shared overlay on top of everything ----
        Rectangle {
          visible: root.dragState.active
          x: Style.space(2)
          y: root.dragState.localY + root.dragState.listTop
          width: contentRoot.width - Style.space(4)
          height: root.dragState.itemH - Style.space(6)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.contentForeground, Color.accent)
          border.width: 1
          border.color: Color.accent
          opacity: 0.94
          z: 999
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            width: parent.width - Style.space(16)
            text: root.dragState.label
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }
        Rectangle {
          visible: root.dragState.active
          x: Style.space(2)
          y: root.dragState.targetIndex * root.dragState.itemH - 1 + root.dragState.listTop
          width: contentRoot.width - Style.space(4)
          height: 2
          color: Color.accent
          z: 998
        }
      }
    }
  }
}
