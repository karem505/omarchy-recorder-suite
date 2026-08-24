import QtQuick

// Circular icon button in the omacut style: flat dark circle, icon drawn on
// a canvas (no emoji, no icon-font dependency).
Rectangle {
  id: b

  // play | pause | export | plus | minus
  property string icon: "play"
  property real size: 40
  property bool primary: false

  signal clicked()

  readonly property color base: primary ? Theme.accent : Theme.panel
  readonly property color ink: !enabled ? Theme.muted : primary ? Theme.background : Theme.fg

  width: size
  height: size
  radius: size / 2
  color: !enabled ? Qt.darker(Theme.panel, 1.15)
    : ma.pressed ? Qt.darker(base, 1.25)
    : ma.containsMouse ? Qt.lighter(base, 1.2) : base

  Canvas {
    id: cv
    anchors.fill: parent
    onPaint: {
      var c = getContext("2d")
      c.clearRect(0, 0, width, height)
      c.strokeStyle = String(b.ink)
      c.fillStyle = String(b.ink)
      c.lineWidth = Math.max(2, width * 0.055)
      c.lineCap = "round"
      c.lineJoin = "round"
      var cx = width / 2
      var cy = height / 2
      var s = width * 0.22

      if (b.icon === "play") {
        c.beginPath()
        c.moveTo(cx - s * 0.7, cy - s)
        c.lineTo(cx - s * 0.7, cy + s)
        c.lineTo(cx + s * 1.05, cy)
        c.closePath()
        c.fill()
      } else if (b.icon === "pause") {
        c.fillRect(cx - s, cy - s, s * 0.65, s * 2)
        c.fillRect(cx + s * 0.35, cy - s, s * 0.65, s * 2)
      } else if (b.icon === "export") {
        c.beginPath()
        c.moveTo(cx, cy - s * 1.1)
        c.lineTo(cx, cy + s * 0.45)
        c.moveTo(cx - s * 0.7, cy - s * 0.2)
        c.lineTo(cx, cy + s * 0.55)
        c.lineTo(cx + s * 0.7, cy - s * 0.2)
        c.stroke()
        c.beginPath()
        c.moveTo(cx - s, cy + s * 1.1)
        c.lineTo(cx + s, cy + s * 1.1)
        c.stroke()
      } else if (b.icon === "plus") {
        c.beginPath()
        c.moveTo(cx - s, cy)
        c.lineTo(cx + s, cy)
        c.moveTo(cx, cy - s)
        c.lineTo(cx, cy + s)
        c.stroke()
      } else if (b.icon === "minus") {
        c.beginPath()
        c.moveTo(cx - s, cy)
        c.lineTo(cx + s, cy)
        c.stroke()
      }
    }
  }

  onIconChanged: cv.requestPaint()
  onInkChanged: cv.requestPaint()

  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    onClicked: b.clicked()
  }
}
