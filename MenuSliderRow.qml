import QtQuick
import QtQuick.Controls
import qs.Commons

// Menu row with a theme-styled slider, e.g. for the widget corner radius.
Item {
  id: row
  property string text: ""
  property real from: 0
  property real to: 100
  property real stepSize: 1
  property real value: 0
  signal sliderMoved(real v)
  signal committed()
  property int rowHeight: 30

  width: parent.width
  height: row.rowHeight

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: control.hovered || control.pressed ? Color.menu.selectedBackground : "transparent"
  }

  Text {
    id: label
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    text: row.text
    color: Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    width: Math.min(implicitWidth, parent.width * 0.45)
    elide: Text.ElideRight
  }

  Slider {
    id: control
    anchors.left: label.right
    anchors.leftMargin: 8
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    implicitHeight: 22
    from: row.from
    to: row.to
    stepSize: row.stepSize
    value: row.value
    focusPolicy: Qt.StrongFocus
    Accessible.name: row.text
    onMoved: row.sliderMoved(value)
    onPressedChanged: if (!pressed) row.committed()

    background: Rectangle {
      x: control.leftPadding
      y: control.topPadding + control.availableHeight / 2 - height / 2
      width: control.availableWidth
      height: 4
      radius: 2
      color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.25)
    }
    handle: Rectangle {
      x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
      y: control.topPadding + control.availableHeight / 2 - height / 2
      width: 16
      height: 16
      radius: 8
      border.color: Color.menu.border
      border.width: 1
      color: Color.menu.selectedText
    }
  }
}