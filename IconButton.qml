import QtQuick

// Small circular control button used by the slideshow's hover controls.
Item {
  id: btn
  property string icon: "play"
  property alias containsMouse: hoverArea.containsMouse
  signal clicked()
  width: 32
  height: 32

  Rectangle {
    anchors.fill: parent
    radius: 16
    color: btn.containsMouse ? "#40FFFFFF" : "transparent"
    Behavior on color { ColorAnimation { duration: 100 } }
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

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    onClicked: btn.clicked()
  }
}