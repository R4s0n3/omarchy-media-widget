import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "MediaModel.js" as MediaModel

// Desktop slideshow widget: a floating square that plays photos, GIFs and
// videos from a user-picked folder, always on top of the desktop.
//
// Panel lifecycle contract (see shell.qml):
//   - open(payloadJson) / close()  summoned by `omarchy-shell shell {summon,hide}`
//   - `opened` drives the shell's toggle state
Item {
  id: root

  // ---- host injections --------------------------------------------------
  property var shell: null
  property var pluginRegistry: null
  property var manifest: null
  property string pluginId: ""
  property string pluginDir: ""
  property bool started: false

  function startAfterInjection() {
    if (root.started || !root.manifest || !root.shell || !root.pluginRegistry) return
    root.pluginId = String(root.manifest.id || "")
    root.pluginDir = String(root.manifest.__sourceDir || "")
    root.started = true
    console.log("MediaWidget started:", root.pluginId, "dir:", root.pluginDir, "media:", root.files.length)
    root.applySettings()
    root.ensureFolder()
    root.runScan()
    root.restartWatcher()
  }

  onManifestChanged: root.startAfterInjection()
  onShellChanged: root.startAfterInjection()
  onPluginRegistryChanged: root.startAfterInjection()

  // ---- visibility lifecycle --------------------------------------------
  property bool opened: false

  function open(payloadJson) {
    opened = true
    window.visible = true
    Qt.callLater(function() { card.forceActiveFocus() })
  }

  function close() {
    opened = false
    window.visible = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else root.close()
  }

  // Debug/introspection via `omarchy-shell shell call <id> <method> ''`.
  function widgetState() { return root.opened ? "open" : "closed" }
  function mediaCount() { return String(root.files.length) }
  function currentMedia() { return root.currentBase }
  function mediaFolder() { return root.folder }

  // ---- settings (inline shell.json entry) -------------------------------
  property string folder: ""
  property int intervalSec: 300
  property int size: 360
  property real radius: 0
  property bool shuffle: false
  property bool effects: true
  property int marginRight: 48
  property int marginBottom: 48

  function readEntry() {
    var cfg = shell && shell.shellConfig ? shell.shellConfig : null
    if (!cfg || !pluginRegistry) return {}
    var loc = pluginRegistry.findEntryLocation(cfg, pluginId)
    if (!loc || !loc.found) return {}
    if (loc.kind === "bar" && cfg.bar && cfg.bar.layout)
      return cfg.bar.layout[loc.section][loc.index]
    if (loc.kind === "plugin" && cfg.plugins)
      return cfg.plugins[loc.index]
    return {}
  }

  function applySettings() {
    var e = root.readEntry()
    root.folder = String(e.folder || "") || Quickshell.env("HOME") + "/Pictures/mediawidget"
    root.intervalSec = Math.max(300, Number(e.interval) || 300)
    root.size = Math.min(1200, Math.max(160, Number(e.size) || 360))
    root.radius = Math.min(Number(e.radius) || 0, root.size / 2)
    root.shuffle = e.shuffle === true
    root.effects = e.effects !== false
    root.marginRight = Number(e.marginRight) || 48
    root.marginBottom = Number(e.marginBottom) || 48
  }

  function persistEntry() {
    if (!shell || typeof shell.updateEntryInline !== "function") return
    shell.updateEntryInline(pluginId, {
      folder: root.folder,
      interval: root.intervalSec,
      size: root.size,
      radius: root.radius,
      shuffle: root.shuffle,
      effects: root.effects,
      marginRight: root.marginRight,
      marginBottom: root.marginBottom
    })
  }

  // ---- slideshow state ----------------------------------------------------
  property var files: []
  property int index: -1
  property bool paused: false
  property string currentBase: ""
  property int failCount: 0
  property bool pendingAdvance: false
  property bool picking: false

  function restartTimer() { slideTimer.restart() }

  function loadCurrent() {
    if (root.index < 0 || root.index >= root.files.length) return
    root.pendingAdvance = false
    var url = root.files[root.index]
    root.currentBase = url.substring(url.lastIndexOf("/") + 1)
    root.failCount = 0
    if (MediaModel.isVideo(url)) {
      photo.visible = false
      gifItem.visible = false
      videoItem.visible = true
      videoPlayer.source = url
      videoPlayer.play()
    } else if (MediaModel.isGif(url)) {
      videoPlayer.stop()
      videoPlayer.source = ""
      photo.visible = false
      videoItem.visible = false
      gifItem.visible = true
      gifItem.source = url
      gifItem.playing = true
      kenBurns.running = false
    } else {
      videoPlayer.stop()
      videoPlayer.source = ""
      gifItem.visible = false
      videoItem.visible = false
      photo.visible = true
      photo.source = url
      photo.scale = 1.0
      kenBurns.restart()
    }
    root.restartTimer()
  }

  function next() {
    if (root.files.length === 0) return
    root.index = MediaModel.nextIndex(root.index, root.files.length, root.shuffle)
    root.loadCurrent()
  }

  function prev() {
    if (root.files.length === 0) return
    root.index = (root.index - 1 + root.files.length) % root.files.length
    root.loadCurrent()
  }

  function togglePause() {
    root.paused = !root.paused
    if (!root.paused && root.files.length > 0 && videoItem.visible) videoPlayer.play()
    slideTimer.running = root.files.length > 0 && !root.paused
  }

  function onTimerExpired() {
    if (root.files.length === 0) return
    if (videoItem.visible) {
      root.pendingAdvance = true
    } else if (gifItem.visible && gifItem.frameCount > 0) {
      root.pendingAdvance = true
    } else {
      root.next()
    }
  }

  function applyMedia(list) {
    var merged = MediaModel.mergeMedia(list, root.files, root.index)
    if (merged.files === root.files && merged.index === root.index) return
    root.files = merged.files
    if (merged.index >= 0 && merged.index < merged.files.length) {
      root.index = merged.index
      root.restartTimer()
    } else if (merged.files.length > 0) {
      root.index = Math.floor(Math.random() * merged.files.length)
      root.loadCurrent()
    } else {
      root.index = -1
      root.currentBase = ""
      photo.visible = false
      gifItem.visible = false
      gifItem.playing = false
      videoItem.visible = false
      videoPlayer.stop()
      videoPlayer.source = ""
      kenBurns.running = false
      slideTimer.stop()
    }
  }

  // ---- folder management -------------------------------------------------
  function ensureFolder() {
    if (root.folder === "") return
    mkdirProcess.command = ["bash", "-c", 'mkdir -p "$0"', root.folder]
    mkdirProcess.running = true
  }

  function runScan() {
    if (root.folder === "" || scanProcess.running) return
    scanProcess.command = ["bash", root.pluginDir + "/scan.sh", root.folder]
    scanProcess.running = true
  }

  function restartWatcher() {
    watchProcess.running = false
    Qt.callLater(function() {
      if (root.folder === "") return
      watchProcess.command = [
        "inotifywait", "-m", "-r",
        "-e", "close_write,create,delete,move",
        "--format", "%w%f",
        root.folder
      ]
      watchProcess.running = true
    })
  }

  function setFolder(path) {
    path = String(path || "").trim()
    if (path === "") return
    if (path === root.folder) {
      root.runScan()
      return
    }
    root.folder = path
    root.ensureFolder()
    root.runScan()
    root.restartWatcher()
    root.persistEntry()
  }

  function pickFolder() {
    contextMenu.visible = false
    root.picking = true
    pickProcess.command = ["bash", root.pluginDir + "/pick-folder.sh"]
    pickProcess.running = true
  }

  function openFolder() {
    Util.execDetached(["xdg-open", root.folder])
  }

  // ---- window -------------------------------------------------------------
  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-mediawidget"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore
    // Only the card is interactive; everything else is click-through.
    mask: Region {
      x: card.x
      y: card.y
      width: card.width
      height: card.height
    }

    Shortcut { sequence: "Space"; enabled: root.opened; onActivated: root.togglePause() }
    Shortcut { sequence: "Right"; enabled: root.opened; onActivated: root.next() }
    Shortcut { sequence: "Left"; enabled: root.opened; onActivated: root.prev() }
    Shortcut { sequence: "Esc"; enabled: root.opened; onActivated: root.requestClose() }

    // The widget square. Anchored to the bottom-right of the screen; dragging
    // it updates the margins.
    Rectangle {
      id: card
      width: root.size
      height: root.size
      color: "transparent"
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: root.marginRight
      anchors.bottomMargin: root.marginBottom
      clip: true
      focus: true

      // ---- media layers -------------------------------------------------
      // Masked to the user's corner radius via a layer effect
      // (Rectangle.clip only ever clips to a square).
      Item {
        id: cardContent
        anchors.fill: parent
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: cardMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: photo
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          smooth: true
          visible: false
          onStatusChanged: {
            if (status === Image.Error && visible && root.failCount++ < root.files.length) root.next()
          }
        }

        AnimatedImage {
          id: gifItem
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          visible: false
          paused: root.paused
          onCurrentFrameChanged: {
            if (root.pendingAdvance && currentFrame === 0 && visible) {
              root.pendingAdvance = false
              root.next()
            }
          }
          onStatusChanged: {
            if (status === Image.Error && visible && root.failCount++ < root.files.length) root.next()
          }
        }

        Item {
          id: videoItem
          anchors.fill: parent
          visible: false

          MediaPlayer {
            id: videoPlayer
            videoOutput: videoOutput
            audioOutput: audioOut
            onMediaStatusChanged: {
              if (mediaStatus === MediaPlayer.EndOfMedia && !root.paused) {
                if (root.pendingAdvance) {
                  root.pendingAdvance = false
                  root.next()
                } else {
                  videoPlayer.play()
                }
              }
            }
            onErrorOccurred: {
              if (!root.paused && root.failCount++ < root.files.length) root.next()
            }
            onPlayingChanged: function(playing) {
              if (playing) root.failCount = 0
            }
          }

          AudioOutput { id: audioOut; muted: true; volume: 0 }
          VideoOutput {
            id: videoOutput
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
          }
        }

        SequentialAnimation {
          id: kenBurns
          running: root.effects && photo.visible && !root.paused
          loops: Animation.Infinite
          NumberAnimation { target: photo; property: "scale"; from: 1.0; to: 1.08; duration: 45000; easing.type: Easing.InOutSine }
          NumberAnimation { target: photo; property: "scale"; from: 1.08; to: 1.0; duration: 45000; easing.type: Easing.InOutSine }
        }
      }

      // Mask shape for cardContent's layer effect; invisible, radius 0..size/2.
      Rectangle {
        id: cardMask
        anchors.fill: parent
        radius: Math.min(root.radius, root.size / 2)
        visible: false
        layer.enabled: true
      }

      // ---- empty state --------------------------------------------------
      Column {
        id: emptyHint
        visible: root.files.length === 0 && !root.picking
        anchors.centerIn: parent
        spacing: 6
        Text {
          text: "No media found"
          color: "#E6FFFFFF"
          font.pixelSize: 13
          font.bold: true
          anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
          text: root.folder
          color: "#99FFFFFF"
          font.pixelSize: 10
          elide: Text.ElideMiddle
          width: Math.min(implicitWidth, root.size - 40)
          horizontalAlignment: Text.AlignHCenter
        }
        Text {
          text: "Drop images, GIFs or videos in and they appear here."
          color: "#99FFFFFF"
          font.pixelSize: 10
          anchors.horizontalCenter: parent.horizontalCenter
        }
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: pickHintButton.implicitWidth + 24
          height: 30
          radius: 15
          color: root.picking ? "#33FFFFFF" : "#26FFFFFF"
          anchors.topMargin: 10
          Text {
            id: pickHintButton
            anchors.centerIn: parent
            text: root.picking ? "Picking folder…" : "Pick a folder"
            color: "#F2FFFFFF"
            font.pixelSize: 12
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.pickFolder()
            onEntered: parent.color = "#3DFFFFFF"
            onExited: parent.color = root.picking ? "#33FFFFFF" : "#26FFFFFF"
          }
        }
      }

      // ---- hover chrome ---------------------------------------------------
      Rectangle {
        id: namePill
        anchors.top: parent.top
        anchors.topMargin: 10
        anchors.horizontalCenter: parent.horizontalCenter
        height: 24
        width: nameLabel.width + 20
        radius: 14
        color: "#B0101010"
        opacity: cardHover.hovered ? 1 : 0
        visible: false
        onOpacityChanged: visible = opacity > 0.05
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Text {
          id: nameLabel
          anchors.centerIn: parent
          text: root.currentBase
          color: "#F0FFFFFF"
          font.pixelSize: 11
          elide: Text.ElideMiddle
          width: Math.min(implicitWidth, root.size - 60)
        }
      }

      Rectangle {
        id: controlsBar
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        height: 36
        width: controlsRow.width + 16
        radius: 14
        color: "#B0101010"
        opacity: cardHover.hovered ? 1 : 0
        visible: false
        onOpacityChanged: visible = opacity > 0.05
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Row {
          id: controlsRow
          anchors.centerIn: parent
          spacing: 2
          IconButton { icon: "prev"; onClicked: root.prev() }
          IconButton { icon: root.paused ? "play" : "pause"; onClicked: root.togglePause() }
          IconButton { icon: "next"; onClicked: root.next() }
        }
      }

      // ---- input ----------------------------------------------------------
      MouseArea {
        id: cardHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.RightButton
        onPressed: function(mouse) {
          if (mouse.button === Qt.RightButton) contextMenu.visible = true
        }
      }

      MouseArea {
        id: dragArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        property int startX: 0
        property int startY: 0
        property int startRight: 0
        property int startBottom: 0
        onPressed: function(mouse) {
          card.forceActiveFocus()
          contextMenu.visible = false
          var g = dragArea.mapToGlobal(mouse.x, mouse.y)
          startX = g.x
          startY = g.y
          startRight = root.marginRight
          startBottom = root.marginBottom
        }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var g = dragArea.mapToGlobal(mouse.x, mouse.y)
          root.marginRight = Math.max(0, startRight - (g.x - startX))
          root.marginBottom = Math.max(0, startBottom - (g.y - startY))
        }
        onReleased: root.persistEntry()
      }

      // ---- context menu ---------------------------------------------------
      // Solid theme-colored panel, full card width, half card height,
      // anchored bottom-right of the card. Two pages: main actions and the
      // size choices. Pages scroll when the rows don't fit.
      Rectangle {
        id: contextMenu
        visible: false
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: parent.width / 2
        height: parent.height
        z: 10
        color: Qt.rgba(Color.menu.background.r, Color.menu.background.g,
                       Color.menu.background.b, 1.0)
        border.color: Color.menu.border
        border.width: 1

        Flickable {
          id: mainPage
          visible: true
          anchors.fill: parent
          anchors.margins: 6
          contentHeight: mainColumn.height
          clip: true

          Column {
            id: mainColumn
            width: mainPage.width

            MenuRow {
              text: root.paused ? "Resume" : "Pause"
              rowHeight: 30
              onTriggered: { contextMenu.visible = false; root.togglePause() }
            }
            MenuRow {
              text: "Previous"
              rowHeight: 30
              onTriggered: { contextMenu.visible = false; root.prev() }
            }
            MenuRow {
              text: "Next"
              rowHeight: 30
              onTriggered: { contextMenu.visible = false; root.next() }
            }
            MenuRow {
              text: "Shuffle: " + (root.shuffle ? "on" : "off")
              rowHeight: 30
              onTriggered: {
                root.shuffle = !root.shuffle
                root.persistEntry()
              }
            }
            MenuRow {
              text: "Ken Burns: " + (root.effects ? "on" : "off")
              rowHeight: 30
              onTriggered: {
                root.effects = !root.effects
                root.persistEntry()
              }
            }
            MenuSliderRow {
              text: "Radius: " + Math.round(root.radius) + "px"
              from: 0
              to: root.size / 2
              stepSize: 4
              value: root.radius
              rowHeight: 30
              onSliderMoved: root.radius = v
              onCommitted: root.persistEntry()
            }
            MenuSliderRow {
              text: "Interval: " + Math.round(root.intervalSec / 60) + " min"
              from: 300
              to: 3600
              stepSize: 60
              value: root.intervalSec
              rowHeight: 30
              onSliderMoved: root.intervalSec = v
              onCommitted: root.persistEntry()
            }
            MenuRow {
              text: root.picking ? "Picking folder…" : "Pick folder…"
              rowHeight: 30
              onTriggered: root.pickFolder()
            }
            MenuRow {
              text: "Open folder"
              rowHeight: 30
              onTriggered: { contextMenu.visible = false; root.openFolder() }
            }
            MenuRow {
              text: "Size…"
              rowHeight: 30
              onTriggered: { mainPage.visible = false; sizePage.visible = true }
            }
            MenuRow {
              text: "Hide widget"
              rowHeight: 30
              onTriggered: { contextMenu.visible = false; root.requestClose() }
            }
          }
        }

        Flickable {
          id: sizePage
          visible: false
          anchors.fill: parent
          anchors.margins: 6
          contentHeight: sizeColumn.height
          clip: true

          Column {
            id: sizeColumn
            width: sizePage.width

            MenuRow {
              text: "← Back"
              rowHeight: 30
              onTriggered: { sizePage.visible = false; mainPage.visible = true }
            }
            Repeater {
              model: [240, 360, 480, 720]
              delegate: MenuRow {
                required property int modelData
                text: modelData + "px"
                checked: root.size === modelData
                rowHeight: 30
                onTriggered: {
                  root.size = modelData
                  root.radius = Math.min(root.radius, root.size / 2)
                  root.persistEntry()
                  sizePage.visible = false
                  mainPage.visible = true
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- media scanning ------------------------------------------------------
  Process {
    id: scanProcess
    stdout: StdioCollector {
      id: scanStdout
      waitForEnd: true
    }
    onExited: root.applyMedia(MediaModel.parseScan(scanStdout.text))
  }

  Process {
    id: watchProcess
    stdout: SplitParser {
      onRead: function(chunk) { debounceTimer.restart() }
    }
  }

  Timer {
    id: debounceTimer
    interval: 400
    onTriggered: root.runScan()
  }

  Process {
    id: mkdirProcess
    command: ["bash", "-c", "true"]
  }

  Process {
    id: pickProcess
    stdout: StdioCollector {
      id: pickStdout
      waitForEnd: true
    }
    onExited: {
      root.picking = false
      if (exitCode !== 0) return
      root.setFolder(pickStdout.text)
    }
  }

  Timer {
    id: slideTimer
    interval: root.intervalSec * 1000
    repeat: true
    running: root.files.length > 0 && !root.paused
    onTriggered: root.onTimerExpired()
  }

  Component.onCompleted: {
    root.open()
  }
}