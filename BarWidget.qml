import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Razer mouse battery in the bar, with a settings panel on left click.
//
// Everything comes from razer-bridge.py, which speaks to the OpenRazer daemon
// over the session bus: no hidraw, no sysfs, so this widget never fights the
// daemon for the device. Battery is polled slowly (60 s) because every read is
// a real USB transaction, and there is no D-Bus signal to subscribe to.
//
// The widget stays visible with "--" until the daemon answers, so a stopped
// daemon shows up as an empty reading instead of an invisible widget.
BarWidget {
  id: root
  moduleName: "alexpazzo.razer-mouse"

  readonly property string pluginDir: {
    var value = String(Qt.resolvedUrl("."))
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try {
      return decodeURIComponent(value).replace(/\/$/, "")
    } catch (e) {
      return value
    }
  }

  property int batteryLevel: -1
  property bool charging: false
  property string deviceName: ""
  property int deviceCount: 0
  property string lastError: ""

  readonly property string faceText: batteryLevel >= 0
    ? (charging ? batteryLevel + "%+" : batteryLevel + "%")
    : "--"

  readonly property string tooltipText: batteryLevel >= 0
    ? (deviceName + " — " + batteryLevel + "%" + (charging ? " (in carica)" : ""))
    : (lastError !== "" ? "Razer: " + lastError : "Razer: in lettura…")

  function refresh() {
    if (statusProc.running) return
    killTimer.restart()
    statusProc.running = true
  }

  // A failed read must not leave a stale percentage on the bar: the whole
  // point of showing "--" is that the number is unknown, not remembered.
  function failure(text) {
    batteryLevel = -1
    charging = false
    deviceCount = 0
    deviceName = ""
    lastError = text
  }

  function errorFromText(code, text) {
    var trimmed = text ? String(text).trim() : ""
    if (trimmed !== "") {
      try {
        var parsed = JSON.parse(trimmed)
        if (parsed && parsed.error)
          return parsed.detail ? parsed.error + ": " + parsed.detail : String(parsed.error)
      } catch (e) {
        return trimmed
      }
    }
    return "bridge exited " + code
  }

  function onStatus(code, text, errorOutput) {
    if (code !== 0) {
      failure(errorFromText(code, errorOutput && String(errorOutput).trim() !== "" ? errorOutput : text))
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      failure("risposta non valida")
      return
    }
    if (!parsed || parsed.ok !== true) {
      failure(parsed && parsed.error ? String(parsed.error) : "errore sconosciuto")
      return
    }
    var devices = parsed.devices || []
    var device = devices.length > 0 ? devices[0] : null
    if (!device) {
      failure("nessun mouse")
      return
    }
    if (device.asleep === true) {
      failure("mouse in sleep")
      return
    }
    deviceCount = devices.length
    deviceName = device.name ? String(device.name) : ""
    batteryLevel = typeof device.battery === "number" ? device.battery : -1
    charging = device.charging === true
    lastError = ""
  }

  // ---- Panel. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget looks up open/close/opened on this root.
  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function open() {
    if (panelItem) panelItem.open()
  }
  function close() {
    if (panelItem) panelItem.close()
  }
  function toggle() {
    if (panelItem) panelItem.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelItem) panelItem.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelItem
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Process {
    id: statusProc
    command: ["/usr/bin/python3", root.pluginDir + "/razer-bridge.py", "status"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: statusErr
      waitForEnd: true
    }
    onExited: function(code) {
      killTimer.stop()
      root.onStatus(code, statusOut.text, statusErr.text)
    }
  }

  // The bridge has its own 6 s alarm; this watchdog is the belt to that
  // suspenders, so a stuck child never leaves the widget frozen.
  Timer {
    id: killTimer
    interval: 4000
    repeat: false
    onTriggered: if (statusProc.running) statusProc.running = false
  }

  Timer {
    id: pollTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.faceText
    tooltipText: root.tooltipText
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }
}
