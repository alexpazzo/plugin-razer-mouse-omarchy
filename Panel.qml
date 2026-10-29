import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Settings panel for the Razer mouse: battery headline, pointer, power saving
// and lighting. Every read and write goes through razer-bridge.py — the panel
// never touches the device itself.
//
// Reads poll every 5 s while open (each read is a USB transaction, so a closed
// panel polls nothing at all). Writes are serialised through one Process and a
// small queue: a slider drag produces exactly one command per key, and a
// command that is still queued for the same key is replaced rather than
// stacked.
Panel {
  id: root
  moduleName: "alexpazzo.razer-mouse"
  manageIpc: false

  // The bar-widget root hands these in. hostWidget is the bar's popout
  // identity, so panel switching routes back through it, not through us.
  property var anchorItem: null
  property var hostWidget: null

  readonly property string pluginDir: {
    var value = String(Qt.resolvedUrl("."))
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try {
      return decodeURIComponent(value).replace(/\/$/, "")
    } catch (e) {
      return value
    }
  }

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- state -------------------------------------------------------------

  property bool ready: false
  property string deviceName: ""
  property int deviceCount: 0
  property string serial: ""
  property string firmware: ""
  property int maxDpi: 30000
  property var dpi: [0, 0]

  // The stops people actually use, offered as chips under the slider. Filtered
  // by the mouse's own ceiling so a smaller sensor never shows a dead chip.
  readonly property var dpiPresets: {
    var wanted = [400, 800, 1600, 3200, 6400]
    var reachable = []
    for (var i = 0; i < wanted.length; i++)
      if (wanted[i] <= maxDpi) reachable.push(wanted[i])
    return reachable.length > 0 ? reachable : [100]
  }
  property int pollRate: 0
  property var pollRates: []
  property int idleTime: 0
  property int lowBatteryThreshold: 0
  property int brightness: 0
  property string effect: ""
  property int batteryLevel: -1
  property bool charging: false
  property string lastError: ""
  property string lastUpdated: ""

  // Key of the slider the pointer is currently on. The poll must not move a
  // value out from under a finger mid-drag.
  property string activeSlider: ""

  readonly property string batteryText: batteryLevel < 0
    ? "--"
    : (charging ? batteryLevel + "% · in carica" : batteryLevel + "%")

  // The hero title needs the width: the device name is long, so the serial
  // lives on the meta line and the pill keeps only the short fields.
  readonly property string metaText: serial !== "" ? batteryText + " · " + serial : batteryText

  readonly property string detailText: {
    var parts = []
    if (firmware !== "") parts.push("fw " + firmware)
    if (deviceCount > 1) parts.push(deviceCount + " dispositivi")
    return parts.join(" · ")
  }

  function errorText(code, out, err) {
    var parsed = null
    var text = out ? String(out).trim() : ""
    if (text !== "") {
      try {
        parsed = JSON.parse(text)
      } catch (e) {
        parsed = null
      }
    }
    if (parsed && parsed.error) {
      var detail = parsed.detail ? String(parsed.detail) : ""
      return detail !== "" ? parsed.error + ": " + detail : String(parsed.error)
    }
    var stderrText = err ? String(err).trim() : ""
    if (stderrText !== "") return stderrText
    return "errore (exit " + code + ")"
  }

  function applyStatus(payload) {
    var devices = payload && payload.devices ? payload.devices : []
    var device = devices.length > 0 ? devices[0] : null
    if (!device) {
      fail("nessun mouse")
      return
    }

    // Sleeping mouse: the hardware fields come back as gaps, but the daemon's
    // own cached settings (poll rate, brightness, effect) are still real, so
    // those are shown and the rest keeps the last committed value.
    if (device.asleep === true) {
      deviceCount = devices.length
      deviceName = device.name ? String(device.name) : ""
      serial = device.serial ? String(device.serial) : ""
      firmware = device.firmware ? String(device.firmware) : ""
      if (typeof device.maxDpi === "number" && device.maxDpi > 0) maxDpi = device.maxDpi
      if (typeof device.pollRate === "number") pollRate = device.pollRate
      if (Array.isArray(device.pollRates) && device.pollRates.length > 0) pollRates = device.pollRates
      if (typeof device.brightness === "number") brightness = Math.round(device.brightness)
      if (device.effect) effect = String(device.effect)
      batteryLevel = -1
      charging = false
      ready = true
      lastError = "mouse in sleep — muovilo per aggiornare i valori"
      return
    }

    deviceCount = devices.length
    deviceName = device.name ? String(device.name) : ""
    serial = device.serial ? String(device.serial) : ""
    firmware = device.firmware ? String(device.firmware) : ""
    if (typeof device.maxDpi === "number" && device.maxDpi > 0) maxDpi = device.maxDpi

    // A daemon that just re-enumerated the device can answer (0, 0); that is
    // not a DPI, it is a gap. Keep the last known value instead of dragging the
    // knob to the floor.
    if (Array.isArray(device.dpi) && device.dpi.length === 2
        && Number(device.dpi[0]) >= 100 && activeSlider !== "dpi")
      dpi = [Number(device.dpi[0]), Number(device.dpi[1])]
    if (typeof device.pollRate === "number") pollRate = device.pollRate
    if (Array.isArray(device.pollRates) && device.pollRates.length > 0) pollRates = device.pollRates
    if (typeof device.idleTime === "number" && activeSlider !== "idle_time")
      idleTime = device.idleTime
    if (typeof device.lowBatteryThreshold === "number" && activeSlider !== "low_battery_threshold")
      lowBatteryThreshold = device.lowBatteryThreshold
    if (typeof device.brightness === "number" && activeSlider !== "brightness")
      brightness = Math.round(device.brightness)
    if (device.effect) effect = String(device.effect)

    batteryLevel = typeof device.battery === "number" ? device.battery : -1
    charging = device.charging === true
    ready = true
    lastError = ""
    lastUpdated = Qt.formatTime(new Date(), "hh:mm:ss")
  }

  // A failed read blanks the headline (battery, name, serial) rather than
  // leaving a stale device summary; the controls keep their last values so the
  // panel still shows what was last applied.
  function fail(text) {
    lastError = text
    ready = false
    batteryLevel = -1
    charging = false
    deviceName = ""
    serial = ""
    firmware = ""
  }

  function onStatus(code, out, err) {
    if (code !== 0) {
      fail(errorText(code, out, err))
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(out)
    } catch (e) {
      fail("risposta non valida")
      return
    }
    if (!parsed || parsed.ok !== true) {
      fail(parsed && parsed.error ? String(parsed.error) : "errore sconosciuto")
      return
    }
    applyStatus(parsed)
  }

  function refresh() {
    if (statusProc.running) return
    statusKill.restart()
    statusProc.running = true
  }

  // ---- writes ------------------------------------------------------------

  function apply(key, value) {
    var queue = []
    for (var i = 0; i < actionProc.queue.length; i++) {
      if (actionProc.queue[i].key !== key) queue.push(actionProc.queue[i])
    }
    queue.push({ key: key, value: String(value) })
    actionProc.queue = queue
    if (!actionProc.running) pump()
  }

  function pump() {
    if (actionProc.queue.length === 0) return
    var job = actionProc.queue.shift()
    actionProc.command = ["/usr/bin/python3", pluginDir + "/razer-bridge.py", "set", job.key, job.value]
    actionKill.restart()
    actionProc.running = true
  }

  // ---- DPI ----------------------------------------------------------------

  // The track is a logarithmic axis over 0..dpiSliderSteps rather than a
  // linear 100..30000 one: linear puts 400-3200 dpi inside the first 10 % of
  // the slider, where a single pixel already moves the value by ~100 dpi.
  // Logarithmic spreads the useful range over half the track and keeps the
  // step small exactly where people tune.
  readonly property int dpiSliderSteps: 1000

  function dpiToPos(value) {
    var span = Math.log(maxDpi / 100)
    if (!(span > 0)) return 0
    return Math.round(dpiSliderSteps * Math.log(Math.max(100, value) / 100) / span)
  }

  function posToDpi(pos) {
    return 100 * Math.pow(maxDpi / 100, Math.max(0, Math.min(dpiSliderSteps, pos)) / dpiSliderSteps)
  }

  function clampDpi(value) {
    return Math.max(100, Math.min(maxDpi, Math.round(value)))
  }

  // Snapping works in axis steps: a release within six steps (~2 px) of a
  // preset commits that preset's own value, so the drag and the chip can never
  // disagree by a few dpi. Everywhere else the drag keeps the value it
  // reached. Returns 0 when no preset is close enough.
  function presetNear(pos) {
    var best = 0
    var bestDistance = 6
    for (var i = 0; i < dpiPresets.length; i++) {
      var distance = Math.abs(pos - dpiToPos(dpiPresets[i]))
      if (distance <= bestDistance) {
        bestDistance = distance
        best = dpiPresets[i]
      }
    }
    return best
  }

  // One place commits a DPI: the chip, the release and the wheel all come
  // through here, so the label, the slider and the device never disagree.
  function commitDpi(value) {
    var next = clampDpi(value)
    activeSlider = ""
    if (next === dpi[0]) return
    dpi = [next, next]
    apply("dpi", next)
  }

  // ---- IO ----------------------------------------------------------------

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
      statusKill.stop()
      root.onStatus(code, statusOut.text, statusErr.text)
    }
  }

  // Belt to the bridge's own 6 s alarm: a wedged child never stays "in lettura".
  Timer {
    id: statusKill
    interval: 4000
    repeat: false
    onTriggered: if (statusProc.running) statusProc.running = false
  }

  Timer {
    id: pollTimer
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: actionProc
    property var queue: []
    stdout: StdioCollector {
      id: actionOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(code) {
      actionKill.stop()
      if (code !== 0) root.lastError = root.errorText(code, actionOut.text, actionErr.text)
      root.pump()
      if (actionProc.queue.length === 0) root.refresh()
    }
  }

  Timer {
    id: actionKill
    interval: 6000
    repeat: false
    onTriggered: if (actionProc.running) actionProc.running = false
  }

  // The mark in front of the device name: the Nerd Font mouse glyph, tinted
  // like any other panel icon, so the plugin ships no artwork. Swapping in a
  // logo here (an Image instead of this Text) does not touch the hero.
  component RazerMark: Text {
    property real iconSize: Style.font.display

    text: "\u{f037d}"
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: iconSize
    renderType: Text.NativeRendering
  }

  // ---- view --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    // The card must be tall enough for every row it owns: a Column taller than
    // the card does not clip, it paints over the windows behind — that is how
    // the Aggiorna row ended up outside the panel's border.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(780))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        root.switchPanel(direction)
      }

      Column {
        id: column
        width: parent ? parent.width : implicitWidth
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: root.deviceName !== "" ? root.deviceName : "Razer"
          meta: root.metaText
          detail: root.detailText
          foreground: root.barForeground
          fontFamily: root.fontFamily
          iconComponent: Component {
            RazerMark {
              iconSize: hero.iconSize
              color: root.barForeground
            }
          }
        }

        PanelSectionHeader {
          text: "Puntatore"
          foreground: root.barForeground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(dpiLabel.implicitHeight, dpiValue.implicitHeight)

            Text {
              id: dpiLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "DPI"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: dpiValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // Follows the finger: the number is the candidate value while a
              // drag is in flight, the committed one otherwise. A mouse that has
              // not answered yet has no dpi to show.
              text: dpiSlider.dragging
                ? Math.round(root.posToDpi(dpiSlider.liveValue)) + " dpi"
                : (root.dpi[0] >= 100 ? root.dpi[0] + " dpi" : "--")
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          PanelSlider {
            id: dpiSlider
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: root.dpiSliderSteps
            step: 5
            integer: true
            value: root.dpiToPos(root.dpi[0])
            onMoved: root.activeSlider = "dpi"
            onReleased: function(pos) {
              var preset = root.presetNear(pos)
              root.commitDpi(preset > 0 ? preset : root.posToDpi(pos))
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.dpiPresets

              Button {
                required property int modelData
                text: String(modelData)
                tooltipText: modelData + " dpi"
                fontFamily: root.fontFamily
                foreground: root.barForeground
                fontSize: Style.font.caption
                verticalPadding: Style.space(3)
                bordered: true
                active: root.dpi[0] === modelData
                onClicked: root.commitDpi(modelData)
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Dropdown {
            width: parent.width
            label: "Poll rate"
            fontFamily: root.fontFamily
            value: String(root.pollRate)
            options: root.pollRates.map(function(r) { return String(r) })
            onChanged: function(v) { root.apply("poll_rate", v) }
          }
        }

        PanelSectionHeader {
          text: "Risparmio energetico"
          foreground: root.barForeground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(idleLabel.implicitHeight, idleValue.implicitHeight)

            Text {
              id: idleLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Idle prima dello sleep"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: idleValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.idleTime > 0 ? root.idleTime + " s" : "--"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 60
            maximum: 900
            step: 30
            integer: true
            value: root.idleTime
            onMoved: root.activeSlider = "idle_time"
            onReleased: function(v) {
              root.activeSlider = ""
              root.idleTime = Math.round(v)
              root.apply("idle_time", Math.round(v))
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(thresholdLabel.implicitHeight, thresholdValue.implicitHeight)

            Text {
              id: thresholdLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Soglia batteria scarica"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: thresholdValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.lowBatteryThreshold > 0 ? root.lowBatteryThreshold + "%" : "--"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 5
            maximum: 25
            step: 1
            integer: true
            value: Math.min(25, Math.max(5, root.lowBatteryThreshold))
            onMoved: root.activeSlider = "low_battery_threshold"
            onReleased: function(v) {
              root.activeSlider = ""
              root.lowBatteryThreshold = Math.round(v)
              root.apply("low_battery_threshold", Math.round(v))
            }
          }

          Text {
            width: parent.width
            text: "range scrivibile 5–25% (il driver clampa); valore attuale "
              + (root.lowBatteryThreshold > 0 ? root.lowBatteryThreshold + "%" : "non disponibile")
            color: root.barForeground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSectionHeader {
          text: "Illuminazione"
          foreground: root.barForeground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(brightnessLabel.implicitHeight, brightnessValue.implicitHeight)

            Text {
              id: brightnessLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Luminosità (ultimo valore impostato)"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: brightnessValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.brightness + "%"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.brightness
            onMoved: root.activeSlider = "brightness"
            onReleased: function(v) {
              root.activeSlider = ""
              root.brightness = Math.round(v)
              root.apply("brightness", Math.round(v))
            }
          }
        }

        Dropdown {
          width: parent.width
          label: "Effetto"
          fontFamily: root.fontFamily
          value: root.effect
          options: ["none", "spectrum", "wave", "static"]
          onChanged: function(v) {
            if (v === "static") root.apply("color", "FF0000")
            else root.apply("effect", v)
          }
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(refreshButton.implicitHeight, updatedText.implicitHeight)

          Button {
            id: refreshButton
            text: "Aggiorna"
            tooltipText: "Aggiorna"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            bordered: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.refresh()
          }

          Text {
            id: updatedText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.lastUpdated !== ""
              ? "aggiornato " + root.lastUpdated
              : (root.ready ? "" : "in lettura…")
            color: root.barForeground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          visible: root.lastError !== ""
          text: root.lastError
          color: root.bar ? root.bar.urgent : Commons.Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
