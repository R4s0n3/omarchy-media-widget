import QtQuick
import qs.Commons

// Single row of the widget's context menu.
Item {
  id: row
  property string text: ""
  property bool checked: false
  property int rowHeight: 30
  property alias containsMouse: hoverArea.containsMouse
  signal triggered()

  width: parent.width
  height: row.rowHeight

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: row.containsMouse ? Color.menu.selectedBackground : "transparent"
  }

  Text {
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    text: row.text
    color: row.containsMouse ? Color.menu.selectedText : Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
    width: parent.width - 30
  }

  Text {
    visible: row.checked
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    text: "✓"
    color: Color.menu.selectedText
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    onClicked: row.triggered()
  }
}