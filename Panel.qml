import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// nbfc-linux fan control. Fans are shown as spinning ASCII art with their live
// RPM below; the art spins faster the higher the RPM. Control is staged:
// Auto/Manual mode, a fan picker (All fans / per-fan), and a target percent
// are only written to nbfc when the user presses Save. Cancel discards pending
// changes, and the panel re-syncs its controls to the real system state on
// every status poll while open.
Panel {
  id: root
  moduleName: "kshatriya-abhay.nbfc"
  ipcTarget: "kshatriya-abhay.nbfc"

  // ---- live fan state (from `nbfc status`) ----
  // ListModel so each fan card keeps its own spin timer and frame index across
  // poll updates (roles are updated in place via set(), never rebuilt).
  property ListModel fansModel: ListModel {}
  property bool available: true
  property string availabilityIssue: ""
  property bool readOnly: false
  property string configName: ""
  // Whether the nbfc binary is installed at all. Drives the "this plugin only
  // works with nbfc-linux" warning, separate from the service being reachable.
  property bool nbfcFound: true

  // ---- staged control state ----
  // `mode`/`fanIndex`/`percent` are what the user is editing (pending);
  // `applied*` is the last state known to be on the system. Dirty = pending
  // differs from applied, which is what reveals the Save/Cancel row.
  property string mode: "auto"       // "auto" | "manual"
  property int fanIndex: -1          // -1 = all fans, else index into fansModel
  property int percent: 50
  property string appliedMode: "auto"
  property int appliedFanIndex: -1
  property int appliedPercent: 50
  property string applyError: ""

  // True when pending differs from what's applied. When mode is auto the
  // fan/percent selections are irrelevant, so they can't make it dirty.
  readonly property bool dirty:
    root.mode !== root.appliedMode ||
    (root.mode === "manual" && (root.fanIndex !== root.appliedFanIndex || root.percent !== root.appliedPercent))

  // Fan picker choices: "All fans" (index -1) plus one entry per fan.
  readonly property var fanOptions: {
    var arr = [{ label: "All fans", index: -1 }]
    for (var i = 0; i < root.fansModel.count; i++) {
      arr.push({ label: root.fansModel.get(i).shortName, index: i })
    }
    return arr
  }

  property string focusSection: "mode"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var visibleSections: root.computeSections()

  function fanName(index) {
    if (index < 0 || index >= root.fansModel.count) return ""
    return root.fansModel.get(index).name
  }

  // Applied state summary for the hero line, e.g. "AUTO" or
  // "MANUAL · CPU · 47%".
  function appliedSummary() {
    if (root.appliedMode === "auto") return "AUTO"
    var label = root.appliedFanIndex === -1
      ? "ALL FANS"
      : (root.fansModel.get(root.appliedFanIndex)
          ? root.fansModel.get(root.appliedFanIndex).shortName.toUpperCase()
          : "FAN")
    return "MANUAL · " + label + " · " + root.appliedPercent + "%"
  }

  // ---- status / polling ---------------------------------------------------
  function refresh() {
    if (!checkProc.running) checkProc.running = true
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(parsed) {
    // If the nbfc binary itself is missing, the "only works with nbfc-linux"
    // warning takes priority over any fan/status result (parseStatus of an
    // error blob yields zero fans).
    if (!root.nbfcFound) {
      root.available = false
      root.availabilityIssue = "This widget only works with nbfc-linux. Install it (e.g. `pacman -S nbfc-linux`) to use fan control."
      return
    }
    root.readOnly = parsed.readOnly
    root.configName = parsed.configName
    root.available = parsed.fans.length > 0
    root.availabilityIssue = parsed.fans.length > 0 ? "" : "nbfc reported no fans. Is the service running?"

    // Update the fans model in place when the fan set hasn't changed, so fan
    // card delegates (and their spin timers) survive the poll.
    var fans = parsed.fans
    if (root.fansModel.count === fans.length) {
      for (var i = 0; i < fans.length; i++) {
        var f = fans[i]
        root.fansModel.set(i, {
          name: f.name, shortName: f.shortName, temp: f.temperature,
          rpm: f.rpm, autoMode: f.auto, target: f.target
        })
      }
    } else {
      root.fansModel.clear()
      for (i = 0; i < fans.length; i++) {
        f = fans[i]
        root.fansModel.append({
          name: f.name, shortName: f.shortName, temp: f.temperature,
          rpm: f.rpm, autoMode: f.auto, target: f.target
        })
      }
    }

    // Only re-sync the controls when nothing is staged — an in-progress edit
    // must not be yanked back to the system state mid-flight.
    if (!root.dirty) {
      var st = Model.deriveApplied(fans)
      root.appliedMode = st.mode
      root.appliedFanIndex = st.fanIndex
      root.appliedPercent = st.percent
      root.mode = st.mode
      root.fanIndex = st.fanIndex
      root.percent = st.percent
      root.clampCursor()
    }
  }

  // ---- staged edits -------------------------------------------------------
  function setMode(m) {
    if (m === root.mode) return
    root.mode = m
    // Entering manual: seed the fan/percent from the applied state so the
    // controls match what's actually running until the user changes something.
    if (m === "manual") {
      root.fanIndex = root.appliedFanIndex
      root.percent = root.appliedPercent
    }
    root.clampCursor()
  }

  function setFan(index) {
    if (index === root.fanIndex) return
    root.fanIndex = index
    // Seed the percent from that fan's live target speed for a natural start.
    if (index >= 0 && index < root.fansModel.count) {
      root.percent = Model.clampPercent(root.fansModel.get(index).target)
    } else {
      root.percent = 50
    }
  }

  function setPercent(value) {
    root.percent = Model.clampPercent(value)
  }

  function save() {
    if (!root.dirty || !root.available) return
    if (root.readOnly) {
      root.applyError = "nbfc is read-only — cannot apply changes."
      return
    }
    if (applyProc.running) return

    var args = ["nbfc", "set"]
    if (root.mode === "auto") {
      args.push("-a")
    } else if (root.fanIndex === -1) {
      args.push("-s", String(root.percent))
    } else {
      args.push("-s", String(root.percent), "-f", String(root.fanIndex))
    }
    root.applyError = ""
    applyProc.command = args
    applyProc.running = true
  }

  function cancel() {
    if (!root.dirty) return
    root.mode = root.appliedMode
    root.fanIndex = root.appliedFanIndex
    root.percent = root.appliedPercent
    root.applyError = ""
    root.clampCursor()
  }

  // ---- keyboard cursor model ----------------------------------------------
  function computeSections() {
    var s = ["mode"]
    if (root.mode === "manual") { s.push("fan"); s.push("percent") }
    if (root.dirty) s.push("actions")
    return s
  }

  function sectionCount(section) {
    if (section === "mode") return 2
    if (section === "fan") return root.fanOptions.length
    if (section === "percent") return 0   // slider sentinel at -1
    if (section === "actions") return 2
    return 0
  }

  function sectionIsSingleRow(section) {
    return true // every section is a single row (buttons or a slider)
  }

  function sectionFirstIndex(section) {
    return section === "percent" ? -1 : 0
  }

  function moveCursor(delta) {
    var sections = root.visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(root.focusSection)
    if (sIdx < 0) {
      root.focusSection = sections[0]
      root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      return
    }
    if (delta > 0) {
      if (sIdx < sections.length - 1) {
        root.focusSection = sections[sIdx + 1]
        root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      }
    } else {
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        root.focusSection = prev
        root.selectedIndex = root.sectionFirstIndex(prev)
      }
    }
  }

  // h/l within a row (buttons), or adjusts the percent slider.
  function moveCursorH(delta) {
    if (root.focusSection === "percent") {
      root.setPercent(root.percent + delta * 5)
      return
    }
    var count = root.sectionCount(root.focusSection)
    if (count <= 0) return
    var t = root.selectedIndex + delta
    if (t >= 0 && t < count) root.selectedIndex = t
  }

  function activateCursor() {
    if (root.focusSection === "mode") {
      root.setMode(root.selectedIndex === 0 ? "auto" : "manual")
    } else if (root.focusSection === "fan") {
      if (root.selectedIndex >= 0 && root.selectedIndex < root.fanOptions.length) {
        root.setFan(root.fanOptions[root.selectedIndex].index)
      }
    } else if (root.focusSection === "actions") {
      if (root.selectedIndex === 0) root.save()
      else root.cancel()
    }
    // percent: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = root.visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(root.focusSection) < 0) {
      root.focusSection = sections[0]
      root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      return
    }
    if (root.focusSection === "percent") {
      root.selectedIndex = -1
      return
    }
    var count = root.sectionCount(root.focusSection)
    if (root.selectedIndex > count - 1) root.selectedIndex = count - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: root.refresh()

  onOpenedChanged: {
    if (opened) {
      root.refresh()
      root.focusSection = "mode"
      root.selectedIndex = 0
      root.cursorActive = false
    }
  }

  onDirtyChanged: root.clampCursor()
  onModeChanged: root.clampCursor()

  Process {
    id: checkProc
    command: ["sh", "-c", "command -v nbfc >/dev/null 2>&1"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.nbfcFound = exitCode === 0
      if (!root.nbfcFound) {
        root.available = false
        root.availabilityIssue = "This widget only works with nbfc-linux. Install it (e.g. `pacman -S nbfc-linux`) to use fan control."
      }
    }
  }

  Process {
    id: statusProc
    command: ["nbfc", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        root.applyStatus(parsed)
      }
    }
    onExited: function(exitCode) {
      if (root.nbfcFound && exitCode !== 0) {
        root.available = false
        root.availabilityIssue = "nbfc exited with code " + exitCode + ". Is nbfc_service running?"
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        // Applied state now matches what the user staged.
        root.appliedMode = root.mode
        root.appliedFanIndex = root.fanIndex
        root.appliedPercent = root.percent
        root.applyError = ""
        // Re-read so the fan cards (and any critical-mode flags) catch up.
        root.refresh()
      } else {
        root.applyError = "nbfc set failed (exit " + exitCode + ")"
      }
    }
  }

  // Poll only while the panel is open. Fan RPM/temperature drift is what we're
  // tracking, so 2s keeps the art and numbers live without hammering the CLI.
  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uEFA7"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Warning banner (service / fans missing) ----------
          Rectangle {
            id: warningBanner
            visible: !root.available
            width: parent.width
            implicitHeight: warningMessage.implicitHeight + Style.space(18)
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.10)
            border.color: Util.alpha(Color.urgent, 0.45)
            border.width: 1

            Row {
              id: warningRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(10)

              Text {
                id: warningIcon
                text: "⚠"
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: warningMessage
                text: root.availabilityIssue !== ""
                  ? root.availabilityIssue
                  : "Fan control is unavailable."
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: warningRow.width - warningIcon.width - warningRow.spacing
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // ---------- Hero: fan icon · title/status ----------
          PanelHero {
            width: parent.width
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            title: "Fan control"
            meta: root.appliedSummary()
            detail: root.dirty ? "UNSAVED" : ""
            iconComponent: Component {
              Text {
text: "\uEFA7"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Fans ----------
          PanelSeparator {
            visible: root.available
            foreground: root.bar.foreground
          }

          Column {
            visible: root.available
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(fansHeader.implicitHeight, configNameValue.implicitHeight)

              PanelSectionHeader {
                id: fansHeader
                text: "FANS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Selected nbfc config, shown right above the fan art.
              Text {
                id: configNameValue
                text: root.configName !== "" ? root.configName : "No config"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
                width: Math.max(0, parent.width - fansHeader.implicitWidth - Style.space(20))
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
              }
            }

            Row {
              id: fansRow
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.fansModel

                FanCard {
                  width: (fansRow.width - fansRow.spacing * Math.max(0, root.fansModel.count - 1)) / Math.max(1, root.fansModel.count)
                }
              }
            }
          }

          // ---------- Mode (Auto / Manual) ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(modeHeader.implicitHeight, modeValue.implicitHeight)

              PanelSectionHeader {
                id: modeHeader
                text: "MODE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: modeValue
                text: root.mode === "auto" ? "Auto" : "Manual"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: modeRow
              width: parent.width
              height: modeButtons.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "mode"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(modeRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: modeButtons
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Button {
                  id: autoButton
                  width: (modeButtons.width - modeButtons.spacing) / 2
                  text: "Auto"
                  selected: root.mode === "auto"
                  hasCursor: root.cursorActive && root.focusSection === "mode" && root.selectedIndex === 0
                  enabled: root.available
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.setMode("auto")
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.focusSection = "mode"
                    root.selectedIndex = 0
                  }
                }

                Button {
                  id: manualButton
                  width: (modeButtons.width - modeButtons.spacing) / 2
                  text: "Manual"
                  selected: root.mode === "manual"
                  hasCursor: root.cursorActive && root.focusSection === "mode" && root.selectedIndex === 1
                  enabled: root.available
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.setMode("manual")
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.focusSection = "mode"
                    root.selectedIndex = 1
                  }
                }
              }
            }
          }

          // ---------- Fan picker (manual) ----------
          Column {
            visible: root.mode === "manual"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(fanHeader.implicitHeight, fanValue.implicitHeight)

              PanelSectionHeader {
                id: fanHeader
                text: "FAN"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: fanValue
                text: {
                  if (root.fanIndex === -1) return "All fans"
                  if (root.fanIndex >= 0 && root.fanIndex < root.fansModel.count)
                    return root.fansModel.get(root.fanIndex).shortName
                  return "Fan"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: fanRow
              width: parent.width
              height: fanButtons.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "fan"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fanRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: fanButtons
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Repeater {
                  model: root.fanOptions

                  Button {
                    id: fanButton
                    required property var modelData
                    required property int index

                    width: (fanButtons.width - fanButtons.spacing * (root.fanOptions.length - 1)) / Math.max(1, root.fanOptions.length)
                    text: fanButton.modelData.label
                    selected: root.fanIndex === fanButton.modelData.index
                    hasCursor: root.cursorActive && root.focusSection === "fan" && root.selectedIndex === index
                    enabled: root.available
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.setFan(fanButton.modelData.index)
                    onHovered: function(on) {
                      if (!on) return
                      root.cursorActive = true
                      root.focusSection = "fan"
                      root.selectedIndex = index
                    }
                  }
                }
              }
            }
          }

          // ---------- Percent (manual) ----------
          Column {
            visible: root.mode === "manual"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(percentHeader.implicitHeight, percentValue.implicitHeight)

              PanelSectionHeader {
                id: percentHeader
                text: "PERCENT"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: percentValue
                text: Math.round(percentSlider.dragging ? percentSlider.liveValue : root.percent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: percentRow
              width: parent.width
              height: percentSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "percent" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(percentRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: percentSlider
                bar: root.bar
                enabled: root.available && !root.readOnly
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 100
                step: 1
                integer: true
                value: root.percent
                onMoved: function(v) { root.setPercent(v) }
                onReleased: function(v) { root.setPercent(v) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "percent"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Save / Cancel (staged changes) ----------
          Column {
            visible: root.dirty
            width: parent.width
            spacing: Style.space(6)

            CursorSurface {
              id: actionsRow
              width: parent.width
              height: actionsButtons.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "actions"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(actionsRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: actionsButtons
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Button {
                  id: saveButton
                  width: (actionsButtons.width - actionsButtons.spacing) / 2
                  text: "Save"
                  // Save is the primary action: filled with the accent.
                  selected: true
                  accent: Color.accent
                  hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === 0
                  enabled: root.available
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.save()
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.focusSection = "actions"
                    root.selectedIndex = 0
                  }
                }

                Button {
                  id: cancelButton
                  width: (actionsButtons.width - actionsButtons.spacing) / 2
                  text: "Cancel"
                  // Cancel is secondary: quiet bordered button.
                  bordered: true
                  hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === 1
                  enabled: root.available
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.cancel()
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.focusSection = "actions"
                    root.selectedIndex = 1
                  }
                }
              }
            }

            Text {
              visible: root.applyError !== ""
              text: root.applyError
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              width: parent.width
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // Fan card: label, spinning ASCII art, live RPM, and a dim temperature.
  component FanCard: Column {
    id: card
    required property int index
    required property string name
    required property string shortName
    required property real temp
    required property real rpm
    required property bool autoMode
    required property real target

    property int frameIndex: 0

    spacing: Style.space(4)

    Text {
      text: card.shortName
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
    }

    Text {
      text: Model.FAN_FRAMES[card.frameIndex]
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.title
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
    }

    Text {
      text: Math.round(card.rpm) + " rpm"
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
    }

    Text {
      text: Math.round(card.temp) + "°C"
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
    }

    Timer {
      id: spinTimer
      interval: Model.spinInterval(card.rpm)
      running: root.opened && card.rpm > 0
      repeat: true
      onTriggered: card.frameIndex = (card.frameIndex + 1) % Model.FAN_FRAMES.length
      onIntervalChanged: if (running) restart()
    }
  }
}