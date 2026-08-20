import QtQuick
import qs.Ui
import qs.Commons

// Bar button that toggles the desktop slideshow widget.
BarWidget {
  id: root
  moduleName: "io.github.ras.mediawidget"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Toggle media widget"
    iconComponent: Component {
      Canvas {
        anchors.fill: parent
        function roundRectPath(ctx, x, y, w, h, r) {
          r = Math.min(r, w / 2, h / 2)
          ctx.beginPath()
          ctx.moveTo(x + r, y)
          ctx.arcTo(x + w, y, x + w, y + h, r)
          ctx.arcTo(x + w, y + h, x, y + h, r)
          ctx.arcTo(x, y + h, x, y, r)
          ctx.arcTo(x, y, x + w, y, r)
          ctx.closePath()
        }
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.lineWidth = Math.max(1.5, width / 14)
          ctx.strokeStyle = button.foreground
          ctx.fillStyle = button.foreground

          // frame
          var inset = ctx.lineWidth / 2
          roundRectPath(ctx, inset, inset, width - inset * 2, height - inset * 2, width / 5)
          ctx.stroke()

          // sun
          ctx.beginPath()
          ctx.arc(width * 0.62, height * 0.36, width * 0.13, 0, Math.PI * 2)
          ctx.fill()

          // mountains
          ctx.beginPath()
          ctx.moveTo(width * 0.2, height * 0.72)
          ctx.lineTo(width * 0.42, height * 0.5)
          ctx.lineTo(width * 0.58, height * 0.68)
          ctx.lineTo(width * 0.72, height * 0.55)
          ctx.lineTo(width * 0.82, height * 0.72)
          ctx.closePath()
          ctx.fill()
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton && root.bar)
        root.bar.run("omarchy-shell shell toggle io.github.ras.mediawidget '{}'")
    }
  }
}