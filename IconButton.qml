import QtQuick
import QtQuick.Controls
import qs.Commons

// Small circular control button used by the slideshow's hover controls.
// Keyboard-accessible (tab focus, Enter/Space activation, visible focus
// ring) and announced to assistive tech via an Accessible role/name.
Item {
  id: btn
  property string icon: "play"
  property string tooltipText: ""
  property alias containsMouse: hoverArea.containsMouse
  signal clicked()
  width: 32
  height: 32

  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: btn.tooltipText !== "" ? btn.tooltipText : btn.icon
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      btn.clicked()
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: 16
    color: btn.containsMouse ? "#40FFFFFF" : "transparent"
    Behavior on color { ColorAnimation { duration: 100 } }
  }

  Rectangle {
    anchors.fill: parent
    radius: 16
    border.width: 2
    border.color: Style.focusBorderColor
    color: "transparent"
    visible: btn.activeFocus
  }

  Canvas {
    id: ic
    property string icon: btn.icon
    anchors.centerIn: parent
    width: 16
    height: 16
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.fillStyle = "#F2FFFFFF"
      switch (btn.icon) {
      case "play":
        ctx.beginPath()
        ctx.moveTo(2, 0); ctx.lineTo(16, 8); ctx.lineTo(2, 16)
        ctx.closePath(); ctx.fill()
        break
      case "pause":
        ctx.fillRect(1, 0, 5, 16)
        ctx.fillRect(10, 0, 5, 16)
        break
      case "prev":
        ctx.fillRect(10, 0, 4, 16)
        ctx.beginPath()
        ctx.moveTo(8, 0); ctx.lineTo(8, 16); ctx.lineTo(0, 8)
        ctx.closePath(); ctx.fill()
        break
      case "next":
        ctx.fillRect(2, 0, 4, 16)
        ctx.beginPath()
        ctx.moveTo(8, 0); ctx.lineTo(8, 16); ctx.lineTo(16, 8)
        ctx.closePath(); ctx.fill()
        break
      }
    }
    onIconChanged: requestPaint()
  }

  ToolTip {
    visible: btn.tooltipText !== "" && hoverArea.containsMouse
    text: btn.tooltipText
    delay: 400
    background: Rectangle {
      color: Color.tooltip.background
      border.color: Color.tooltip.border
      border.width: 1
      radius: 4
    }
    contentItem: Text {
      text: btn.tooltipText
      color: Color.tooltip.text
      font.family: Style.font.family
      font.pixelSize: 11
      padding: 4
    }
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    onClicked: btn.clicked()
  }
}