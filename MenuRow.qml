import QtQuick
import qs.Commons

// Single row of the widget's context menu. Mouse and keyboard driven:
// tab focus, Enter/Space activation, and a visible focus ring.
Item {
  id: row
  property string text: ""
  property bool checked: false
  property int rowHeight: 30
  property alias containsMouse: hoverArea.containsMouse
  signal triggered()

  width: parent.width
  height: row.rowHeight

  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: row.text
  Accessible.checked: row.checked
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      row.triggered()
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: 6
    color: row.containsMouse || row.activeFocus ? Color.menu.selectedBackground : "transparent"
  }

  Rectangle {
    anchors.fill: parent
    radius: 6
    border.width: 1
    border.color: Style.focusBorderColor
    color: "transparent"
    visible: row.activeFocus
  }

  Text {
    anchors.left: parent.left
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    text: row.text
    color: row.containsMouse || row.activeFocus ? Color.menu.selectedText : Color.menu.text
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