import QtQuick

// Text pill button, themed from the active Omarchy theme.
Rectangle {
  id: b

  property string text: ""
  property bool primary: false

  signal clicked()

  readonly property color base: primary ? Theme.accent : Theme.panel

  implicitHeight: 30
  implicitWidth: label.implicitWidth + 26
  radius: height / 2
  color: !enabled ? Qt.darker(Theme.panel, 1.15)
    : ma.pressed ? Qt.darker(base, 1.25)
    : ma.containsMouse ? Qt.lighter(base, 1.2) : base

  Text {
    id: label
    anchors.centerIn: parent
    text: b.text
    color: !b.enabled ? Theme.muted : b.primary ? Theme.background : Theme.fg
    font.family: Theme.fontFamily
    font.pixelSize: 12
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    onClicked: b.clicked()
  }
}
