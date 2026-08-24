import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Click ripple: a purely visual, click-through overlay that draws expanding
// rings at the cursor when told to. click-ripple-emit (bound non-consuming to
// mouse:272) calls the IPC target below on every left click while the system
// screen recorder is running, so the waves end up in the recording.
Item {
  id: root

  // Recording-finished watcher: offers "Edit in Montage" for stops that
  // bypass the ALT + PRINT shim (bar indicator, capture menu, CLI). The
  // script is a flock singleton, so shell reloads never stack copies.
  Process {
    id: recordWatch
    command: [Quickshell.env("HOME") + "/.local/bin/recorder-notify-watch"]
    running: true
    onExited: restartTimer.start()
  }
  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: recordWatch.running = true
  }

  IpcHandler {
    target: "recorder-suite.click-ripple"

    function ripple(x: string, y: string): string {
      root.spawn(parseFloat(x), parseFloat(y))
      return "ok"
    }

    function ping(): string {
      return "ok"
    }
  }

  function spawn(gx, gy) {
    if (isNaN(gx) || isNaN(gy)) return
    var windows = screenWindows.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].containsGlobal(gx, gy)) {
        windows[i].addRipple(gx, gy)
        return
      }
    }
  }

  Variants {
    id: screenWindows
    model: Quickshell.screens

    PanelWindow {
      id: win

      required property var modelData
      // The surface is only mapped while a ripple is animating, so no
      // overlay is composited the rest of the time.
      property int liveRipples: 0

      screen: modelData
      visible: liveRipples > 0
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "click-ripple"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Visual-only surface: an empty input region so clicks always pass
      // through to whatever is underneath.
      mask: Region {}

      function containsGlobal(gx, gy) {
        var s = win.screen
        return gx >= s.x && gy >= s.y && gx < s.x + s.width && gy < s.y + s.height
      }

      function addRipple(gx, gy) {
        rippleComponent.createObject(content, {
          cx: gx - win.screen.x,
          cy: gy - win.screen.y
        })
      }

      Item {
        id: content
        anchors.fill: parent
      }

      Component {
        id: rippleComponent

        Item {
          id: wave

          property real cx: 0
          property real cy: 0
          // Single animation clock; both rings and the center fill derive
          // from it so the whole wave stays in phase.
          property real t: 0
          readonly property color tint: Color.accent || "#ffffff"

          x: cx - width / 2
          y: cy - height / 2
          width: 180
          height: 180

          Component.onCompleted: win.liveRipples++

          // Soft center splash that dies quickly.
          Rectangle {
            anchors.centerIn: parent
            width: 64 * Math.min(1, wave.t * 3)
            height: width
            radius: width / 2
            color: Qt.alpha(wave.tint, 0.55 * Math.max(0, 1 - wave.t * 1.8))
          }

          // White contrast halo just outside the leading ring, so the wave
          // stays readable over both dark and accent-colored content.
          Rectangle {
            anchors.centerIn: parent
            width: wave.width * Math.min(1, wave.t * 1.1) + 6
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Math.max(2, 4 * (1 - wave.t))
            border.color: Qt.alpha("#ffffff", 0.55 * (1 - wave.t))
          }

          // Leading ring.
          Rectangle {
            anchors.centerIn: parent
            width: wave.width * Math.min(1, wave.t * 1.1)
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Math.max(3, 8 * (1 - wave.t))
            border.color: Qt.alpha(wave.tint, 0.95 * (1 - wave.t * 0.85))
          }

          // Trailing ring, delayed a quarter beat for the wave feel.
          Rectangle {
            readonly property real t2: Math.max(0, (wave.t - 0.25) / 0.75)
            anchors.centerIn: parent
            width: wave.width * 0.7 * t2
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Math.max(2, 5 * (1 - t2))
            border.color: Qt.alpha(wave.tint, 0.85 * (1 - t2))
          }

          NumberAnimation on t {
            from: 0
            to: 1
            duration: 700
            easing.type: Easing.OutCubic
            onFinished: {
              win.liveRipples--
              wave.destroy()
            }
          }
        }
      }
    }
  }
}
