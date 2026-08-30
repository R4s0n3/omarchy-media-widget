import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
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
    console.log("MediaWidget v2 started:", root.pluginId, "dir:", root.pluginDir, "media:", root.files.length)
    root.applySettings()
    root.runScan()
    root.restartWatcher()
    root.connectLockService()
    hyprLockProbe.running = true
  }

  onManifestChanged: root.startAfterInjection()
  onShellChanged: root.startAfterInjection()
  onPluginRegistryChanged: root.startAfterInjection()

  // ---- visibility + playback lifecycle -----------------------------------
  property bool opened: false

  // Lock state is tracked independently for the omarchy lock service and for
  // Hyprland's `lockactive` IPC, then combined; the last event never wins.
  // Until a source reports otherwise the session counts as unlocked, exactly
  // like before the review: the widget must never hide itself on a hunch.
  property bool serviceLocked: false
  property bool hyprLocked: false
  readonly property bool locked: MediaModel.lockCombined(root.serviceLocked, root.hyprLocked)

  // Single source of truth for every playback consumer: the interval timer,
  // the MediaPlayer, the GIF animation, and the Ken Burns zoom all follow
  // this one binding instead of being driven by imperative assignments.
  readonly property bool playbackActive: MediaModel.playbackActive(root.opened, root.paused, root.locked)

  function open(payloadJson) {
    root.opened = true
    // No focus steal: keyboard shortcuts are scoped to deliberate card focus.
  }

  function close() {
    root.opened = false
  }

  onPlaybackActiveChanged: {
    if (root.playbackActive) root.restartTimer()
    if (videoItem.visible && videoPlayer.source !== "") {
      if (root.playbackActive) videoPlayer.play()
      else videoPlayer.pause()
    }
  }

  // Switching the effect off mid-zoom would leave the photo at a scaled
  // state; kenBurns.running is a binding and cannot write properties, so the
  // reset lives here, next to the `effects` property it depends on.
  onEffectsChanged: {
    if (!root.effects) photo.scale = 1.0
  }

  // Track the omarchy lock service (omarchy.lock) so the widget hides the
  // moment the in-shell session lock engages. The service loads asynchronously
  // and can be recreated when the plugin is reloaded, so a poller keeps the
  // connection current.
  property var lockService: null

  function connectLockService() {
    if (!root.shell || typeof root.shell.serviceFor !== "function") return
    var svc = root.shell.serviceFor("omarchy.lock")
    if (!svc) return
    root.lockService = svc
    lockServiceConn.target = svc
    root.serviceLocked = svc.locked === true
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else root.close()
  }

  // Debug/introspection via `omarchy-shell shell call <id> <method> ''`.
  function widgetState() { return root.opened ? "open" : "closed" }
  function lockedState() { return root.locked ? "locked" : "unlocked" }
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
  property bool autoplay: true
  property int marginRight: 48
  property int marginBottom: 48
  readonly property int defaultMarginRight: 48
  readonly property int defaultMarginBottom: 48

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

  // A zero margin is a valid choice; only missing/invalid values fall back.
  function readMargin(v, dflt) {
    if (v === undefined || v === null || v === "") return dflt
    var n = Number(v)
    return isFinite(n) ? n : dflt
  }

  function applySettings() {
    var e = root.readEntry()
    root.folder = String(e.folder || "") || Quickshell.env("HOME") + "/Pictures/mediawidget"
    // Honor hand-edited values; only clamp to sane bounds. The menu slider
    // still constrains interactive changes to 300..3600s.
    root.intervalSec = Math.min(86400, Math.max(5, Number(e.interval) || 300))
    root.size = Math.min(1200, Math.max(160, Number(e.size) || 360))
    root.radius = Math.max(0, Math.min(Number(e.radius) || 0, root.size / 2))
    root.shuffle = e.shuffle === true
    root.effects = e.effects !== false
    root.autoplay = e.autoplay !== false
    // Zero is a valid margin; only missing/invalid values fall back. Both
    // margins are clamped so the card always stays on screen.
    root.marginRight = root.clampRight(root.readMargin(e.marginRight, root.defaultMarginRight))
    root.marginBottom = root.clampBottom(root.readMargin(e.marginBottom, root.defaultMarginBottom))
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
      autoplay: root.autoplay,
      marginRight: root.marginRight,
      marginBottom: root.marginBottom
    })
  }

  // ---- slideshow state ----------------------------------------------------
  property var files: []
  property int index: -1
  property bool paused: false
  property string currentBase: ""
  property string currentPath: ""
  // Paths that failed to load, keyed by full path. An entry is removed only
  // after the file loads successfully (or the folder is rescanned), so a
  // broken file cannot hot-loop the slideshow.
  property var failedPaths: ({})
  property bool pendingAdvance: false
  property bool picking: false
  property var history: []
  // Poll-based countdown. `advanceDueAt` is a plain timestamp, so nothing
  // ever needs to sever the slideTimer.running binding to "restart".
  property double advanceDueAt: 0
  property double gifLastFrameChange: 0
  property int gifLastFrame: -1
  property bool gifWrapped: false
  // Transient status messages (picker results, scan errors, …).
  property string flash: ""
  property bool flashError: false
  property bool flashActive: false

  // ---- scanning ------------------------------------------------------------
  // Every scan is tagged with the folder generation it was started for;
  // results from a previous folder are discarded. If changes arrive while a
  // scan is running, exactly one replacement scan is queued.
  property int folderGeneration: 0
  property int scanGen: -1
  property bool pendingScan: false
  property string scanError: ""
  readonly property bool scanning: scanProcess.running
  readonly property bool watchError: root.watcherFailures >= 20

  function restartTimer() {
    root.advanceDueAt = Date.now() + root.intervalSec * 1000
  }

  function loadCurrent() {
    if (root.index < 0 || root.index >= root.files.length) return
    root.pendingAdvance = false
    gifWatchdog.stop()
    root.gifLastFrame = -1
    root.gifWrapped = false
    root.gifLastFrameChange = Date.now()
    var url = root.files[root.index]
    // The tag travels with each item so late asynchronous status changes can
    // be matched against the file that is actually on display.
    photo.loadedPath = ""
    gifItem.loadedPath = ""
    videoItem.loadedPath = ""
    root.currentPath = url
    root.currentBase = url.substring(url.lastIndexOf("/") + 1)
    if (MediaModel.isVideo(url)) {
      videoItem.visible = true
      photo.visible = false
      photo.source = ""
      gifItem.visible = false
      gifItem.source = ""
      gifItem.playing = false
      videoItem.loadedPath = url
      videoPlayer.source = MediaModel.toFileUrl(url)
      if (root.playbackActive) videoPlayer.play()
    } else if (MediaModel.isGif(url)) {
      gifItem.visible = true
      photo.visible = false
      photo.source = ""
      videoItem.visible = false
      videoPlayer.stop()
      videoPlayer.source = ""
      // Tag the request before assigning source. Image status can change
      // synchronously (notably for an unsupported/corrupt first file); if
      // the tag comes second that error is lost and startup stays blank.
      gifItem.loadedPath = url
      gifItem.source = MediaModel.toFileUrl(url)
      gifItem.playing = root.playbackActive
      if (kenBurns.running) kenBurns.restart()
    } else {
      photo.visible = true
      gifItem.source = ""
      gifItem.playing = false
      gifItem.visible = false
      videoItem.visible = false
      videoPlayer.stop()
      videoPlayer.source = ""
      photo.loadedPath = url
      photo.source = MediaModel.toFileUrl(url)
      if (kenBurns.running) kenBurns.restart()
    }
    root.restartTimer()
  }

  function next() {
    if (root.files.length === 0) return
    if (root.shuffle) root.history = MediaModel.pushHistory(root.history, root.index)
    var idx = MediaModel.nextIndex(root.index, root.files, root.shuffle, root.failedPaths)
    if (idx < 0) return
    root.index = idx
    root.loadCurrent()
  }

  function prev() {
    if (root.files.length === 0) return
    if (root.shuffle && root.history.length > 0) {
      var r = MediaModel.popHistory(root.history)
      root.history = r.history
      root.index = r.index
    } else {
      root.index = (root.index - 1 + root.files.length) % root.files.length
    }
    root.loadCurrent()
  }

  function togglePause() {
    root.paused = !root.paused
  }

  function onTimerExpired() {
    var d = MediaModel.timerDecision(
      root.files.length > 0, root.allFailed, root.autoplay,
      videoItem.visible, gifItem.visible, gifItem.frameCount)
    if (d.advanceNow) {
      root.next()
    } else if (d.awaitBoundary) {
      // Videos advance at EndOfMedia; GIFs on the next loop boundary (the
      // watchdog breaks a stall from one-frame or finite GIFs).
      root.pendingAdvance = true
    }
  }

  // Mark an unplayable item and move on. The path is passed in by the
  // reporter so an asynchronous error that arrives after the slideshow has
  // advanced can never blame the wrong file. Marks are not permanent:
  // rescans clear them and a full-failure state auto-recovers (see
  // allFailedTimer), so one bad iCloud sync moment cannot kill the widget.
  function clearMediaFailure(path) {
    if (!root.failedPaths[path]) return
    var updated = {}
    for (var key in root.failedPaths) {
      if (key !== path) updated[key] = true
    }
    root.failedPaths = updated
  }

  function handleMediaFailure(path) {
    if (path === undefined || path === null || path === "") return
    // Reassign the map instead of mutating it in place so `allFailed` and
    // its empty/retry UI are notified immediately.
    var updated = {}
    for (var key in root.failedPaths) updated[key] = true
    updated[path] = true
    root.failedPaths = updated
    // A late callback from the item we just replaced must not skip the new,
    // healthy current item.
    if (path !== root.currentPath) return
    if (!root.playbackActive || root.files.length === 0) return
    root.pendingAdvance = false
    gifWatchdog.stop()
    var nextIdx = MediaModel.nextIndex(root.index, root.files, root.shuffle, root.failedPaths)
    if (nextIdx < 0) {
      root.index = -1
      root.stopPlayback()
      allFailedTimer.restart()
      return
    }
    root.history = []
    root.index = nextIdx
    root.loadCurrent()
  }

  function stopPlayback() {
    root.pendingAdvance = false
    gifWatchdog.stop()
    videoPlayer.stop()
    videoPlayer.source = ""
    videoItem.visible = false
    gifItem.visible = false
    gifItem.playing = false
    gifItem.source = ""
    photo.visible = false
    photo.source = ""
    photo.loadedPath = ""
    gifItem.loadedPath = ""
    videoItem.loadedPath = ""
    photo.scale = 1.0
  }

  // Forget every failure mark and try again. Used by the context-menu retry
  // row, the all-failed auto-recovery, and after a scan replaces the folder.
  function retryMedia() {
    root.failedPaths = {}
    allFailedTimer.stop()
    if (root.files.length === 0) {
      root.runScan()
      return
    }
    var idx = MediaModel.nextIndex(-1, root.files, root.shuffle, {})
    if (idx < 0) idx = 0
    root.index = idx
    root.loadCurrent()
  }

  // Fresh scan output arrives here. The current item is always reloaded so
  // an overwritten file shows its new contents right away. Failure marks do
  // not survive a scan: a file rewritten by iCloud/sync gets a clean slate
  // (it may have been fixed or replaced), matching pre-review self-healing.
  function applyMedia(result) {
    var list = result.files || []
    var merged = MediaModel.mergeMedia(list, root.files, root.index)
    root.failedPaths = {}
    root.files = merged.files
    if (merged.files.length === 0) {
      root.index = -1
      root.currentBase = ""
      root.currentPath = ""
      root.stopPlayback()
      return
    }
    if (merged.index >= 0) {
      root.index = merged.index
    } else {
      var idx = MediaModel.nextIndex(-1, merged.files, root.shuffle, root.failedPaths)
      if (idx < 0) {
        root.index = -1
        root.stopPlayback()
        allFailedTimer.restart()
        return
      }
      root.index = idx
    }
    root.loadCurrent()
    root.restartTimer()
  }

  // ---- folder management -------------------------------------------------
  // scan.sh creates the folder itself before scanning, so there is no race
  // between folder creation and the first scan/watch.
  function runScan() {
    if (root.folder === "") return
    if (scanProcess.running) {
      root.pendingScan = true
      return
    }
    root.scanError = ""
    root.scanGen = root.folderGeneration
    scanProcess.command = ["bash", root.pluginDir + "/scan.sh", root.folder]
    scanProcess.running = true
  }

  property int watcherFailures: 0
  property bool stoppingWatcher: false

  function restartWatcher() {
    root.stoppingWatcher = true
    watchProcess.running = false
    Qt.callLater(function() {
      root.stoppingWatcher = false
      if (root.folder === "") return
      watchProcess.command = [
        "inotifywait", "-m", "-r",
        "-e", "close_write,create,delete,move",
        "--format", "%w%f",
        root.folder
      ]
      watchProcess.running = true
      watcherHealthTimer.restart()
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
    root.folderGeneration += 1
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

  // The window may not have a screen assigned yet while the shell is still
  // starting; fall back to the first Quickshell screen in that case.
  function screenForWindow() {
    var s = window.screen
    if (!s) {
      var screens = Quickshell.screens || []
      s = screens.length > 0 ? screens[0] : null
    }
    return s
  }

  function screenWidth() {
    var s = root.screenForWindow()
    return s ? s.width : 1920
  }

  function screenHeight() {
    var s = root.screenForWindow()
    return s ? s.height : 1080
  }

  // Clamp a right/bottom margin so the card stays fully on its screen.
  function clampRight(v) { return MediaModel.clampMargin(v, root.size, root.screenWidth()) }
  function clampBottom(v) { return MediaModel.clampMargin(v, root.size, root.screenHeight()) }

  function resetPosition() {
    root.marginRight = root.clampRight(root.defaultMarginRight)
    root.marginBottom = root.clampBottom(root.defaultMarginBottom)
    root.persistEntry()
  }

  // ---- derived UI state -----------------------------------------------------
  readonly property bool allFailed: MediaModel.allFailed(root.files, root.failedPaths)
  readonly property bool loadingMedia: (photo.visible && photo.status === Image.Loading)
    || (gifItem.visible && gifItem.status === Image.Loading)
    || (videoItem.visible && videoPlayer.mediaStatus === MediaPlayer.LoadingMedia)
  readonly property var status: MediaModel.statusFor(
    root.flash, root.flashError, root.flashActive,
    root.scanError, root.watchError, root.allFailed)
  readonly property string statusText: root.status.text
  readonly property bool statusError: root.status.error

  function showFlash(msg, isError) {
    root.flash = msg
    root.flashError = isError === true
    root.flashActive = true
    flashTimer.restart()
  }

  // ---- window -------------------------------------------------------------
  // Keep the layer surface the size of the card. A full-screen transparent
  // overlay still costs a full-screen surface and, on some compositors, its
  // input region can stall interaction/rendering in normal application
  // windows even when a smaller mask is requested.
  PanelWindow {
    id: window
    visible: root.opened && !root.locked
    anchors { right: true; bottom: true }
    margins { right: root.marginRight; bottom: root.marginBottom }
    width: root.size
    height: root.size
    color: "transparent"
    WlrLayershell.namespace: "omarchy-mediawidget"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Keyboard shortcuts only work after the card (or a control inside it)
    // has deliberate focus; the context menu owns its keys while open.
    Shortcut { sequence: "Space"; enabled: root.opened && card.activeFocus && !contextMenu.visible; onActivated: root.togglePause() }
    Shortcut { sequence: "Right"; enabled: root.opened && card.activeFocus && !contextMenu.visible; onActivated: root.next() }
    Shortcut { sequence: "Left"; enabled: root.opened && card.activeFocus && !contextMenu.visible; onActivated: root.prev() }
    Shortcut { sequence: "Esc"; enabled: root.opened && card.activeFocus; onActivated: { if (contextMenu.visible) contextMenu.visible = false; else root.requestClose() } }

    Rectangle {
      id: card
      anchors.fill: parent
      color: "transparent"
      clip: true
      focus: true

      // Visible focus state for keyboard users.
      Rectangle {
        id: focusRing
        anchors.fill: parent
        radius: Math.min(root.radius, root.size / 2)
        border.width: 2
        border.color: Style.focusBorderColor
        color: "transparent"
        visible: card.activeFocus
        z: 5
      }

      // ---- media layers -------------------------------------------------
      // The masking layer only engages when rounded corners are actually
      // configured; a square card renders with no layer at all.
      Item {
        id: cardContent
        anchors.fill: parent
        layer.enabled: root.radius > 0
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
          asynchronous: true
          cache: false
          smooth: true
          visible: false
          // Raw path this item was last asked to load; status changes are
          // only trusted while they still refer to it.
          property string loadedPath: ""
          // Decode at card size × display scale; never at full resolution.
          sourceSize.width: root.mediaPixelSize
          sourceSize.height: root.mediaPixelSize
          onStatusChanged: {
            if (loadedPath === "") return
            if (status === Image.Ready) root.clearMediaFailure(loadedPath)
            else if (status === Image.Error) root.handleMediaFailure(loadedPath)
          }
        }

        AnimatedImage {
          id: gifItem
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          // No frame caching: a long GIF must not pin every frame in RAM.
          cache: false
          visible: false
          property string loadedPath: ""
          paused: !root.playbackActive
          sourceSize.width: root.mediaPixelSize
          sourceSize.height: root.mediaPixelSize
          onCurrentFrameChanged: {
            root.gifLastFrameChange = Date.now()
            if (currentFrame === 0 && root.gifLastFrame > 0) root.gifWrapped = true
            root.gifLastFrame = currentFrame
            if (root.pendingAdvance && currentFrame === 0 && root.gifWrapped && visible) {
              root.pendingAdvance = false
              root.next()
            }
          }
          onStatusChanged: {
            if (loadedPath === "") return
            if (status === Image.Ready) root.clearMediaFailure(loadedPath)
            else if (status === Image.Error) root.handleMediaFailure(loadedPath)
          }
        }

        Item {
          id: videoItem
          anchors.fill: parent
          visible: false
          property string loadedPath: ""

          MediaPlayer {
            id: videoPlayer
            videoOutput: videoOutput
            audioOutput: audioOut
            onMediaStatusChanged: {
              if (mediaStatus === MediaPlayer.EndOfMedia && root.playbackActive) {
                if (root.pendingAdvance) {
                  root.pendingAdvance = false
                  root.next()
                } else {
                  videoPlayer.play()
                }
              } else if ((mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) && videoItem.loadedPath !== "") {
                root.clearMediaFailure(videoItem.loadedPath)
              }
            }
            onErrorOccurred: {
              // Ignore noise from source swaps/stops; only a failure while a
              // video is actually on display marks it.
              if (root.playbackActive && videoItem.visible && videoPlayer.source !== "" && videoItem.loadedPath !== "") {
                root.handleMediaFailure(videoItem.loadedPath)
              }
            }
          }

          AudioOutput { id: audioOut; muted: true; volume: 0 }
          VideoOutput {
            id: videoOutput
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
          }
        }

        // Ken Burns zoom, bound to the same playbackActive lifecycle.
        // Imperative `running =` writes are never used, so the binding
        // cannot be severed.
        SequentialAnimation {
          id: kenBurns
          running: root.effects && root.playbackActive && photo.visible
          loops: Animation.Infinite
          NumberAnimation { target: photo; property: "scale"; from: 1.0; to: 1.08; duration: 45000; easing.type: Easing.InOutSine }
          NumberAnimation { target: photo; property: "scale"; from: 1.08; to: 1.0; duration: 45000; easing.type: Easing.InOutSine }
        }

        // Keep the zoom pinned to 1.0 when the effect is switched off (see
        // the root-level onEffectsChanged handler: signals cannot cross
        // objects, so the reset lives where the `effects` property lives).
      }

      // Mask shape for cardContent's layer effect; invisible, radius 0..size/2.
      Rectangle {
        id: cardMask
        anchors.fill: parent
        radius: Math.min(root.radius, root.size / 2)
        visible: false
        layer.enabled: true
      }

      // ---- loading indicator ---------------------------------------------
      Rectangle {
        id: loadingPill
        visible: root.loadingMedia && !root.allFailed
        anchors.centerIn: parent
        height: 26
        width: Math.min(loadingLabel.implicitWidth + 24, parent.width - 24)
        radius: 13
        color: "#B0101010"
        Text {
          id: loadingLabel
          anchors.centerIn: parent
          text: "Loading…"
          color: "#E6FFFFFF"
          font.pixelSize: 11
        }
      }

      // ---- empty state ---------------------------------------------------
      // Shown when the folder is empty OR when every file is currently
      // marked failed — the card must never render as a fully transparent,
      // invisible square.
      Column {
        id: emptyHint
        visible: root.files.length === 0 || root.allFailed
        anchors.centerIn: parent
        spacing: 10

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.allFailed ? "Media unavailable" : "No media found"
          color: "#99FFFFFF"
          font.pixelSize: 12
        }

        // Status line above the pick button while picking/scanning/failing.
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.statusText
          color: root.statusError ? "#FFB9B9" : "#99FFFFFF"
          font.pixelSize: 10
          visible: root.statusText !== ""
        }

        // Hint shown only while idle: nothing pending and nothing failed.
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.picking ? "Picking folder…" : "Pick a folder"
          color: "#99FFFFFF"
          font.pixelSize: 10
          visible: !root.picking && !root.scanning && root.statusText === ""
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: pickHintButton.implicitWidth + 24
          height: 30
          radius: 15
          color: root.picking ? "#33FFFFFF" : "#26FFFFFF"
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

      // ---- floating status pill (over live media) ------------------------
      Rectangle {
        id: statusPill
        anchors.top: parent.top
        anchors.topMargin: 10
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.statusText !== "" && root.files.length > 0
        height: 24
        width: Math.min(statusLabel.implicitWidth + 20, parent.width - 24)
        radius: 12
        color: root.statusError ? "#CC402020" : "#B0101010"
        Text {
          id: statusLabel
          anchors.centerIn: parent
          text: root.statusText
          color: "#F0FFFFFF"
          font.pixelSize: 11
          elide: Text.ElideMiddle
          width: Math.min(implicitWidth, statusPill.width - 20)
        }
      }

      // ---- dragging -------------------------------------------------------
      // Pre-review drag implementation: a plain left-button MouseArea that
      // moves the layer surface via margins. Declared before the hover
      // chrome so the IconButtons keep priority for plain clicks.
      MouseArea {
        id: dragArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        property int startX: 0
        property int startY: 0
        property int startRight: 0
        property int startBottom: 0
        property bool dragged: false
        onPressed: function(mouse) {
          card.forceActiveFocus()
          contextMenu.visible = false
          var g = dragArea.mapToGlobal(mouse.x, mouse.y)
          startX = g.x
          startY = g.y
          startRight = root.marginRight
          startBottom = root.marginBottom
          dragged = false
        }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var g = dragArea.mapToGlobal(mouse.x, mouse.y)
          if (g.x !== startX || g.y !== startY) dragged = true
          root.marginRight = root.clampRight(startRight - (g.x - startX))
          root.marginBottom = root.clampBottom(startBottom - (g.y - startY))
        }
        // Only a real drag (not a plain click) rewrites the saved position.
        onReleased: if (dragged) root.persistEntry()
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
      // Non-blocking hover: the card never steals the pointer from windows
      // that happen to pass under it.
      HoverHandler {
        id: cardHover
        acceptedDevices: PointerDevice.Mouse
      }

      MouseArea {
        id: contextArea
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onPressed: function(mouse) {
          if (mouse.button === Qt.RightButton) contextMenu.visible = true
        }
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
            MenuRow {
              text: "Autoplay: " + (root.autoplay ? "on" : "off")
              rowHeight: 30
              onTriggered: {
                root.autoplay = !root.autoplay
                if (root.autoplay) root.restartTimer()
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
              text: "Retry media"
              rowHeight: 30
              onTriggered: { contextMenu.visible = false; root.retryMedia() }
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
                  root.marginRight = root.clampRight(root.marginRight)
                  root.marginBottom = root.clampBottom(root.marginBottom)
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
    onExited: {
      if (root.scanGen !== root.folderGeneration) return
      if (exitCode !== 0) {
        root.scanError = "Folder scan failed (exit " + exitCode + ")"
        return
      }
      root.applyMedia(MediaModel.parseScan(scanStdout.text))
      if (root.pendingScan) {
        root.pendingScan = false
        root.runScan()
      }
    }
  }

  Process {
    id: watchProcess
    stdout: SplitParser {
      onRead: function(chunk) { debounceTimer.restart() }
    }
    onExited: function(exitCode) {
      if (root.stoppingWatcher || exitCode === 0) return
      root.watcherFailures += 1
      if (root.watcherFailures <= 20) {
        watcherRetryTimer.interval = Math.min(60000, 1000 * Math.pow(2, Math.min(root.watcherFailures - 1, 5)))
        watcherRetryTimer.restart()
      }
    }
  }

  // A watcher that stays up for 10 s after a restart is healthy.
  Timer {
    id: watcherHealthTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (watchProcess.running) {
        root.watcherFailures = 0
      }
    }
  }

  Timer {
    id: watcherRetryTimer
    interval: 1000
    repeat: false
    onTriggered: root.restartWatcher()
  }

  Timer {
    id: debounceTimer
    interval: 400
    onTriggered: root.runScan()
  }

  Process {
    id: pickProcess
    stdout: StdioCollector {
      id: pickStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.picking = false
      if (exitCode === 1) { root.showFlash("Folder picker cancelled", false); return }
      if (exitCode === 2) { root.showFlash("Install zenity or kdialog to pick a folder", true); return }
      if (exitCode !== 0) { root.showFlash("Folder picker failed (exit " + exitCode + ")", true); return }
      var path = String(pickStdout.text || "").replace(/^\s+|\s+$/g, "")
      if (path === "") return
      root.setFolder(path)
    }
  }

  // ---- slideshow clock -----------------------------------------------------
  // A plain 250 ms poll against a deadline timestamp: restarting the countdown
  // never has to touch slideTimer.running, so the `files`/`playbackActive`
  // binding stays intact.
  Timer {
    id: slideTimer
    interval: 250
    repeat: true
    running: root.files.length > 0 && root.playbackActive
    onTriggered: {
      if (Date.now() >= root.advanceDueAt) root.onTimerExpired()
    }
  }

  // Breaks a stalled GIF: if a pending advance never sees a loop boundary
  // (one-frame or finite GIFs that stop producing frames), move on anyway.
  Timer {
    id: gifWatchdog
    interval: 500
    repeat: true
    running: root.pendingAdvance && gifItem.visible
    onTriggered: {
      var stalled = Date.now() - root.gifLastFrameChange > 4000
      if (gifItem.frameCount === 1 || stalled) {
        root.pendingAdvance = false
        root.next()
      }
    }
  }

  Timer {
    id: flashTimer
    interval: 4000
    onTriggered: root.flashActive = false
  }

  // Self-healing: if every file is marked failed (typically because iCloud
  // sync was rewriting the folder), forget all marks and try again instead
  // of waiting for the user to notice.
  Timer {
    id: allFailedTimer
    interval: 60000
    repeat: false
    onTriggered: {
      if (root.allFailed) root.retryMedia()
    }
  }

  // ---- lock state ----------------------------------------------------------
  // Polls the lock service so a reloaded service instance is reconnected.
  // If the service is momentarily unavailable the last known state is kept;
  // a missing service must never hide the widget (pre-review behavior).
  Timer {
    id: lockServiceRetry
    interval: 2000
    repeat: true
    running: root.started
    onTriggered: {
      if (!root.shell || typeof root.shell.serviceFor !== "function") return
      var svc = root.shell.serviceFor("omarchy.lock")
      if (svc && svc !== root.lockService) {
        root.connectLockService()
      } else if (!svc && root.lockService) {
        root.lockService = null
        lockServiceConn.target = null
      }
    }
  }

  Connections {
    id: lockServiceConn
    function onLockedChanged() {
      root.serviceLocked = root.lockService.locked === true
    }
  }

  // External locks (e.g. hyprlock) emit `lockactive` on the Hyprland IPC
  // event socket; hide the widget for those too.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "lockactive") {
        root.hyprLocked = event.data === "1"
      }
    }
  }

  // Initial Hyprland lock state: the shell's own helper answers 0/1/2
  // (locked / unlocked / undetermined). Undetermined leaves hyprLocked as-is.
  Process {
    id: hyprLockProbe
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      if (exitCode === 0 || exitCode === 1) {
        root.hyprLocked = exitCode === 0
      }
    }
  }

  readonly property int mediaPixelSize: Math.max(
    64,
    Math.round(root.size * (window.devicePixelRatio > 0 ? window.devicePixelRatio : 1))
  )

  Component.onCompleted: {
    root.open()
  }
}
