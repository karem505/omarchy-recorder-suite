import QtQuick

// Minimal themed slider (0..1). Emits moved() while dragging.
Item {
  id: s

  property real value: 0.5

  signal moved(real v)

  implicitWidth: 130
  implicitHeight: 24

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: 4
    radius: 2
    color: Theme.panelHi

    Rectangle {
      width: parent.width * Math.max(0, Math.min(1, s.value))
      height: parent.height
      radius: 2
      color: Theme.accent
    }
  }

  Rectangle {
    x: Math.max(0, Math.min(1, s.value)) * (parent.width - 14)
    anchors.verticalCenter: parent.verticalCenter
    width: 14
    height: 14
    radius: 7
    color: Theme.fg
    border.color: Theme.accent
    border.width: 1
  }

  MouseArea {
    anchors.fill: parent
    function setFrom(mx) {
      s.moved(Math.max(0, Math.min(1, (mx - 7) / (s.width - 14))))
    }
    onPressed: mouse => setFrom(mouse.x)
    onPositionChanged: mouse => { if (pressed) setFrom(mouse.x) }
  }
}
