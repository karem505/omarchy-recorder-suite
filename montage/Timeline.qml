import QtQuick

// Zoomable filmstrip timeline in the omacut style: thumbnail strip framed by
// the theme accent, ruler above, cut ranges tinted red with a remove button,
// overlay range as a yellow bar. Click/drag seeks, plain wheel pans,
// Ctrl+wheel zooms around the cursor.
Rectangle {
  id: tl

  property real durationS: 0
  property real positionS: 0
  property real pendingIn: -1
  property var cutsModel
  property bool hasOverlay: false
  property real ovStart: 0
  property real ovEnd: 0
  property string thumbDir: ""
  property bool thumbsReady: false
  readonly property int thumbCount: 24

  signal seekTo(real s)
  signal removeCut(int index)

  // 0 = fit whole video in view; zoom raises it up to 400 px/s.
  property real pxPerSec: 0
  readonly property real fitPps: durationS > 0 ? Math.max(1, (width - 24) / durationS) : 10
  readonly property real pps: pxPerSec > 0 ? pxPerSec : fitPps

  readonly property int rulerH: 18
  readonly property int stripY: rulerH + 4

  color: "transparent"

  function zoomAt(factor, centerS) {
    var newPps = Math.max(fitPps, Math.min(400, pps * factor))
    var viewX = centerS * pps - flick.contentX
    pxPerSec = newPps
    flick.contentX = Math.max(0, Math.min(Math.max(0, durationS * newPps + 24 - flick.width),
      centerS * newPps - viewX))
  }
  function zoomIn() { zoomAt(1.5, positionS) }
  function zoomOut() { zoomAt(1 / 1.5, positionS) }

  readonly property var steps: [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
  readonly property real tickStep: {
    for (var i = 0; i < steps.length; i++)
      if (steps[i] * pps >= 70) return steps[i]
    return 600
  }

  function fmtTick(s) {
    var m = Math.floor(s / 60)
    var sec = s - m * 60
    var txt = sec % 1 === 0 ? sec.toFixed(0) : sec.toFixed(1)
    if (sec < 10) txt = "0" + txt
    return m + ":" + txt
  }

  // Keep the playhead in view while it moves.
  onPositionSChanged: {
    var px = positionS * pps
    if (px < flick.contentX + 8 || px > flick.contentX + flick.width - 8)
      flick.contentX = Math.max(0, px - flick.width / 2)
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: tl.durationS * tl.pps + 24
    contentHeight: height
    interactive: false
    clip: true

    Item {
      width: flick.contentWidth
      height: flick.height

      MouseArea {
        anchors.fill: parent
        onPressed: mouse => tl.seekTo(Math.max(0, Math.min(tl.durationS, mouse.x / tl.pps)))
        onPositionChanged: mouse => {
          if (pressed) tl.seekTo(Math.max(0, Math.min(tl.durationS, mouse.x / tl.pps)))
        }
      }

      // Ruler.
      Repeater {
        model: tl.durationS > 0 ? Math.floor(tl.durationS / tl.tickStep) + 1 : 0
        delegate: Item {
          required property int index
          x: index * tl.tickStep * tl.pps
          Rectangle { width: 1; height: 6; color: Theme.muted; y: tl.rulerH - 6 }
          Text {
            y: 0
            x: 3
            text: tl.fmtTick(index * tl.tickStep)
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: 10
          }
        }
      }

      // Filmstrip track framed by the accent, like omacut's trim strip.
      Rectangle {
        id: track
        y: tl.stripY
        width: tl.durationS * tl.pps
        height: flick.height - tl.stripY
        radius: 7
        color: Qt.darker(Theme.panel, 1.2)
        border.color: Theme.accent
        border.width: 2
        clip: true

        Repeater {
          model: tl.thumbsReady ? tl.thumbCount : 0
          delegate: Image {
            required property int index
            x: index * track.width / tl.thumbCount
            width: track.width / tl.thumbCount + 1
            height: track.height
            source: tl.thumbDir !== ""
              ? "file://" + tl.thumbDir + "/t" + String(index + 1).padStart(3, "0") + ".png"
              : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            clip: true
          }
        }
      }

      // Overlay range bar.
      Rectangle {
        visible: tl.hasOverlay
        x: tl.ovStart * tl.pps
        y: tl.stripY - 4
        width: Math.max(2, (tl.ovEnd - tl.ovStart) * tl.pps)
        height: 4
        radius: 2
        color: Theme.yellow
      }

      // Cut ranges (after the seek MouseArea so their remove buttons win).
      Repeater {
        model: tl.cutsModel
        delegate: Rectangle {
          id: cutRect
          required property int index
          required property real s
          required property real e
          x: s * tl.pps
          y: track.y
          width: Math.max(2, (e - s) * tl.pps)
          height: track.height
          radius: 7
          color: Qt.alpha(Theme.red, 0.45)
          border.color: Theme.red
          border.width: 1

          Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 3
            width: 16
            height: 16
            radius: 8
            color: xMa.containsMouse ? Theme.red : Qt.alpha(Theme.background, 0.6)
            Rectangle {
              anchors.centerIn: parent
              width: 8; height: 1.6
              radius: 1
              rotation: 45
              color: Theme.fg
            }
            Rectangle {
              anchors.centerIn: parent
              width: 8; height: 1.6
              radius: 1
              rotation: -45
              color: Theme.fg
            }
            MouseArea {
              id: xMa
              anchors.fill: parent
              hoverEnabled: true
              onClicked: tl.removeCut(cutRect.index)
            }
          }
        }
      }

      // Pending mark-in point.
      Rectangle {
        visible: tl.pendingIn >= 0
        x: tl.pendingIn * tl.pps - 1
        y: tl.rulerH
        width: 2
        height: flick.height - tl.rulerH
        color: Theme.yellow
      }

      // Playhead.
      Rectangle {
        x: tl.positionS * tl.pps - 1
        y: tl.rulerH - 6
        width: 2
        height: flick.height - tl.rulerH + 6
        color: Theme.fg
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: -5
          width: 9
          height: 9
          radius: 5
          color: Theme.accent
          border.color: Theme.fg
          border.width: 1
        }
      }
    }
  }

  WheelHandler {
    target: null
    onWheel: event => {
      if (event.modifiers & Qt.ControlModifier) {
        var centerS = (flick.contentX + event.x) / tl.pps
        tl.zoomAt(event.angleDelta.y > 0 ? 1.3 : 1 / 1.3, centerS)
      } else {
        var max = Math.max(0, flick.contentWidth - flick.width)
        flick.contentX = Math.max(0, Math.min(max,
          flick.contentX - (event.angleDelta.y + event.angleDelta.x) * 0.6))
      }
    }
  }
}
