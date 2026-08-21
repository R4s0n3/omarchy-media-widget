// Shared helpers for the media slideshow widget. Pure functions only so the
// logic can be exercised by QML tests without the Quickshell runtime.

function isVideo(url) {
  return /\.(mp4|mov|m4v|webm|mkv|avi)$/i.test(url)
}

function isGif(url) {
  return /\.gif$/i.test(url)
}

function decodeBase64(s) {
  try { return Qt.atob(String(s || "")) } catch (e) { return "" }
}

// Local paths must be absolute, carry no scheme, and contain no ".." escape.
// When `root` is given, the path must also stay inside it. scan.sh emits the
// canonical root it walked as the first record, so this check runs against
// the same canonical base the paths were produced from.
function isSafePath(path, root) {
  path = String(path || "")
  if (path === "") return false
  if (path.charAt(0) !== "/") return false
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(path)) return false
  var segments = path.split("/")
  for (var i = 0; i < segments.length; i++) {
    if (segments[i] === "..") return false
  }
  if (root) {
    var base = String(root || "").replace(/\/+$/, "")
    if (base !== "" && path !== base && path.indexOf(base + "/") !== 0) return false
  }
  return true
}

// Parse the output of scan.sh into { files, root }. Every record is a
// base64-encoded raw path so filenames with spaces, hashes, percent signs,
// or even newlines survive the line-based pipe intact. The first record,
// kind "R", is the canonical root the scan walked; the rest, kind "F", are
// media files. iCloud placeholder files (still-downloading media) are
// dropped. Records that fail to decode or escape the root are discarded.
function parseScan(text) {
  var root = ""
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line === "") continue
    var kind = line.charAt(0)
    if (kind !== "R" && kind !== "F") continue
    var payload = line.length > 2 ? line.substring(2) : ""
    var path = decodeBase64(payload)
    if (path === "") continue
    if (kind === "R") {
      root = path
      continue
    }
    if (/\.icloud$/i.test(path)) continue
    if (!isSafePath(path, root)) continue
    out.push(path)
  }
  return { files: out, root: root }
}

// Turn a validated local path into a percent-encoded file:// URL. Rejects
// anything that is not an absolute, scheme-less path.
function toFileUrl(path) {
  if (!isSafePath(path, "")) return ""
  var segments = String(path).split("/")
  for (var i = 0; i < segments.length; i++) segments[i] = encodeURIComponent(segments[i])
  return "file://" + segments.join("/")
}

// Merge a fresh scan into the current slideshow state, keeping the current
// item if it still exists. Returns { files, index }.
function mergeMedia(list, files, index) {
  var same = list.length === files.length
  if (same) {
    for (var i = 0; i < list.length; i++) {
      if (list[i] !== files[i]) { same = false; break }
    }
  }
  if (same) return { files: files, index: index }

  var cur = index >= 0 && index < files.length ? files[index] : ""
  if (cur !== "" && list.indexOf(cur) >= 0) {
    return { files: list, index: list.indexOf(cur) }
  }
  return { files: list, index: -1 }
}

// Pick the next index to show, skipping paths marked as failed. Returns -1
// when every remaining item is known-bad (callers surface the terminal
// "no playable media" state instead of looping forever).
function nextIndex(index, files, shuffle, failed) {
  var count = files.length
  if (count === 0) return -1
  failed = failed || {}
  var candidates = []
  for (var i = 0; i < count; i++) {
    if (!failed[files[i]]) candidates.push(i)
  }
  if (candidates.length === 0) return -1
  if (!shuffle) {
    for (var c = 0; c < candidates.length; c++) {
      if (candidates[c] > index) return candidates[c]
    }
    return candidates[0]
  }
  if (candidates.length === 1) return candidates[0]
  var n = index
  while (n === index) n = candidates[Math.floor(Math.random() * candidates.length)]
  return n
}

// True when every file in the list is marked failed: nothing left to show.
function allFailed(files, failed) {
  if (!files || files.length === 0) return false
  failed = failed || {}
  for (var i = 0; i < files.length; i++) {
    if (!failed[files[i]]) return false
  }
  return true
}

// Shuffle history helpers so Previous returns the previously viewed item
// instead of a random one. The history holds indices, most recent last.
function pushHistory(history, index, max) {
  var h = (history || []).slice(0)
  h.push(index)
  if (h.length > (max || 200)) h.splice(0, h.length - (max || 200))
  return h
}

function popHistory(history) {
  var h = (history || []).slice(0)
  return { index: h.length > 0 ? h.pop() : -1, history: h }
}

// Clamp a right/bottom margin so the card stays fully on the screen.
function clampMargin(value, size, screenSize) {
  var max = Math.max(0, screenSize - size)
  return Math.max(0, Math.min(max, value))
}

// ---- playback/lock lifecycle ----------------------------------------------
// Single source of truth for "media is actually playing": visible, not
// paused, not locked. The timer, video, GIF, and Ken Burns all follow it.
function playbackActive(opened, paused, locked) {
  return !!opened && !paused && !locked
}

// Independent lock sources (service + Hyprland) combine; no last-event-wins.
function lockCombined(serviceLocked, hyprLocked) {
  return !!serviceLocked || !!hyprLocked
}

// Context-menu/status text for the explicit UI states. Pure so tests can
// drive every combination without the shell.
function statusFor(flash, flashError, flashActive, scanError, watchError, allFailed) {
  if (flashActive) return { text: String(flash || ""), error: !!flashError }
  if (scanError !== "") return { text: String(scanError), error: true }
  if (watchError) return { text: "Folder watching failed — edits won't refresh automatically", error: true }
  if (allFailed) return { text: "Every file failed to load — check that the media is supported", error: true }
  return { text: "", error: false }
}

// What the interval tick should do. Multi-frame GIFs (and videos) wait for a
// loop boundary / end so they cannot be cut off; one-frame GIFs and photos
// advance immediately; pause/autoplay/all-failed stop the advance entirely.
function timerDecision(hasFiles, allFailed, autoplay, videoVisible, gifVisible, gifFrameCount) {
  if (!hasFiles || allFailed || !autoplay) return { advanceNow: false, awaitBoundary: false }
  if (videoVisible) return { advanceNow: false, awaitBoundary: true }
  if (gifVisible && gifFrameCount !== 1) return { advanceNow: false, awaitBoundary: true }
  return { advanceNow: true, awaitBoundary: false }
}