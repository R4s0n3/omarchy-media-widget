import QtQuick
import QtTest
import "../MediaModel.js" as MediaModel

// Pure-logic tests for the slideshow widget: path parsing/validation, scan
// handling, failure skipping, lifecycle transitions, status states, and
// position clamping. The Quickshell runtime is not available here, so
// everything tested lives in MediaModel.js (the QML layer is a thin binding
// shell over these functions).
TestCase {
  id: tst
  name: "MediaModel"

  function enc(s) { return Qt.btoa(s) }

  // ---- scan parsing -------------------------------------------------------

  function test_parseScan_empty() {
    var r = MediaModel.parseScan("")
    compare(r.files.length, 0)
    compare(r.root, "")
  }

  function test_parseScan_roundtrip() {
    var root = "/tmp/media root"
    var f1 = "/tmp/media root/a photo #1?.jpg"
    var f2 = "/tmp/media root/sub dir/line\nbreak.gif"
    var text = "R " + enc(root) + "\nF " + enc(f1) + "\nF " + enc(f2) + "\n"
    var r = MediaModel.parseScan(text)
    compare(r.root, root)
    compare(r.files.length, 2)
    compare(r.files[0], f1)
    compare(r.files[1], f2)
  }

  function test_parseScan_whitespaceAndPercent() {
    var root = "/tmp/media"
    var f = "/tmp/media/  leading  trailing  .jpg"
    var r = MediaModel.parseScan("R " + enc(root) + "\nF " + enc(f))
    compare(r.files.length, 1)
    compare(r.files[0], f)
  }

  function test_parseScan_dropsIcloudPlaceholders() {
    var root = "/tmp/media"
    var text = "R " + enc(root) + "\nF " + enc("/tmp/media/a.jpg.icloud") + "\nF " + enc("/tmp/media/b.jpg")
    var r = MediaModel.parseScan(text)
    compare(r.files.length, 1)
    compare(r.files[0], "/tmp/media/b.jpg")
  }

  function test_parseScan_rejectsJunkLines() {
    var root = "/tmp/media"
    var text = "garbage\nX " + enc("/tmp/media/x.jpg") + "\nR " + enc(root) + "\nF\nF  \nF " + enc("/tmp/media/ok.jpg")
    var r = MediaModel.parseScan(text)
    compare(r.files.length, 1)
    compare(r.files[0], "/tmp/media/ok.jpg")
  }

  function test_parseScan_rejectsUnsafePaths() {
    var root = "/tmp/media"
    var cases = [
      "relative.jpg",
      "/etc/passwd",
      "../escape.jpg",
      "/tmp/media/../escape.jpg",
      "file:///tmp/media/url.jpg",
      "/tmp/other/a.jpg"                 // outside the walked root
    ]
    var lines = ["R " + enc(root)]
    for (var i = 0; i < cases.length; i++) lines.push("F " + enc(cases[i]))
    var r = MediaModel.parseScan(lines.join("\n"))
    compare(r.files.length, 0)
  }

  function test_parseScan_badBase64Dropped() {
    var root = "/tmp/media"
    var text = "R " + enc(root) + "\nF not-base64!!\nF " + enc("/tmp/media/good.jpg")
    var r = MediaModel.parseScan(text)
    compare(r.files.length, 1)
    compare(r.files[0], "/tmp/media/good.jpg")
  }

  function test_parseScan_rootRecordRejectedWhenUnsafe() {
    var r = MediaModel.parseScan("R " + enc("relative"))
    compare(r.root, "relative")
    compare(r.files.length, 0)
  }

  // ---- url conversion -----------------------------------------------------

  function test_toFileUrl_percentEncodes() {
    compare(MediaModel.toFileUrl("/tmp/media/a b#c?.jpg"), "file:///tmp/media/a%20b%23c%3F.jpg")
    compare(MediaModel.toFileUrl("/tmp/media/100%.jpg"), "file:///tmp/media/100%25.jpg")
    compare(MediaModel.toFileUrl("/tmp/media/plain.jpg"), "file:///tmp/media/plain.jpg")
  }

  function test_toFileUrl_rejectsUnsafe() {
    compare(MediaModel.toFileUrl(""), "")
    compare(MediaModel.toFileUrl("relative.jpg"), "")
    compare(MediaModel.toFileUrl("file:///etc/passwd"), "")
    compare(MediaModel.toFileUrl("http://example.com/x.jpg"), "")
    compare(MediaModel.toFileUrl("/etc/../x.jpg"), "")
  }

  function test_isSafePath() {
    verify(MediaModel.isSafePath("/a/b/c.jpg", "/a/b"))
    verify(!MediaModel.isSafePath("/a/b/c.jpg", "/a/x"))
    verify(!MediaModel.isSafePath("/a/b/c.jpg", "/a/bc"))
    verify(MediaModel.isSafePath("/a/b/c.jpg", ""))
    verify(!MediaModel.isSafePath("a/b.jpg", ""))
  }

  // ---- merge/scan refresh -------------------------------------------------

  function test_mergeMedia_keepsCurrent() {
    var files = ["/m/1.jpg", "/m/2.jpg", "/m/3.jpg"]
    var m = MediaModel.mergeMedia(files, ["/m/1.jpg", "/m/2.jpg"], 1)
    compare(m.files, files)
    compare(m.index, 1)
  }

  function test_mergeMedia_currentGone() {
    var m = MediaModel.mergeMedia(["/m/new.jpg"], ["/m/old.jpg"], 0)
    compare(m.files.length, 1)
    compare(m.index, -1)
  }

  function test_mergeMedia_identicalListSameRefs() {
    var files = ["/m/1.jpg"]
    var m = MediaModel.mergeMedia(files, files, 0)
    compare(m.files, files)
    compare(m.index, 0)
  }

  // ---- failure skipping ---------------------------------------------------

  function test_nextIndex_wraps() {
    var files = ["a", "b", "c"]
    compare(MediaModel.nextIndex(1, files, false, {}), 2)
    compare(MediaModel.nextIndex(2, files, false, {}), 0)
    compare(MediaModel.nextIndex(0, ["only"], false, {}), 0)
  }

  function test_nextIndex_skipsFailed() {
    var files = ["a", "b", "c"]
    compare(MediaModel.nextIndex(0, files, false, { b: true }), 2)
    compare(MediaModel.nextIndex(2, files, false, { a: true, b: true }), 2)
  }

  function test_nextIndex_allFailedTerminal() {
    var files = ["a", "b"]
    compare(MediaModel.nextIndex(0, files, false, { a: true, b: true }), -1)
  }

  function test_nextIndex_shuffleNeverRepeatsOrFailed() {
    var files = ["a", "b", "c", "d", "e"]
    var failed = { c: true }
    for (var i = 0; i < 100; i++) {
      var idx = MediaModel.nextIndex(0, files, true, failed)
      verify(idx >= 0 && idx < files.length)
      verify(idx !== 0)
      verify(!failed[files[idx]])
    }
  }

  function test_allFailed() {
    verify(!MediaModel.allFailed([], {}))
    verify(!MediaModel.allFailed(["a"], {}))
    verify(!MediaModel.allFailed(["a", "b"], { a: true }))
    verify(MediaModel.allFailed(["a", "b"], { a: true, b: true }))
  }

  // ---- shuffle history ----------------------------------------------------

  function test_history_pushPop() {
    var h = MediaModel.pushHistory([], 2)
    h = MediaModel.pushHistory(h, 5)
    compare(h, [2, 5])
    var r = MediaModel.popHistory(h)
    compare(r.index, 5)
    compare(r.history, [2])
  }

  function test_history_capped() {
    var h = []
    for (var i = 0; i < 300; i++) h = MediaModel.pushHistory(h, i, 10)
    compare(h.length, 10)
    compare(h[9], 299)
  }

  function test_history_emptyPop() {
    var r = MediaModel.popHistory([])
    compare(r.index, -1)
    compare(r.history.length, 0)
  }

  // ---- lifecycle ----------------------------------------------------------

  function test_playbackActive() {
    verify(MediaModel.playbackActive(true, false, false))
    verify(!MediaModel.playbackActive(false, false, false))  // hidden
    verify(!MediaModel.playbackActive(true, true, false))    // paused
    verify(!MediaModel.playbackActive(true, false, true))    // locked
  }

  function test_lockCombined() {
    verify(MediaModel.lockCombined(true, false))
    verify(MediaModel.lockCombined(false, true))
    verify(!MediaModel.lockCombined(false, false))
  }

  function test_timerDecision() {
    // paused/autoplay-off/all-failed: nothing happens
    compare(MediaModel.timerDecision(false, false, true, false, false, 0).advanceNow, false)
    compare(MediaModel.timerDecision(true, true, true, false, false, 0).advanceNow, false)
    compare(MediaModel.timerDecision(true, false, false, false, false, 0).advanceNow, false)
    // photo: advance now
    var photo = MediaModel.timerDecision(true, false, true, false, false, 0)
    verify(photo.advanceNow)
    verify(!photo.awaitBoundary)
    // video: await end
    var vid = MediaModel.timerDecision(true, false, true, true, false, 0)
    verify(!vid.advanceNow)
    verify(vid.awaitBoundary)
    // multi-frame GIF: await loop boundary
    var gif = MediaModel.timerDecision(true, false, true, false, true, 5)
    verify(!gif.advanceNow)
    verify(gif.awaitBoundary)
    // one-frame GIF: advance directly (cannot stall on a boundary)
    var still = MediaModel.timerDecision(true, false, true, false, true, 1)
    verify(still.advanceNow)
    verify(!still.awaitBoundary)
    // frame count unknown (still loading): await, watchdog breaks stalls
    var unknown = MediaModel.timerDecision(true, false, true, false, true, 0)
    verify(unknown.awaitBoundary)
  }

  // ---- status states ------------------------------------------------------

  function test_statusStates() {
    compare(MediaModel.statusFor("", false, false, "", false, false).text, "")
    compare(MediaModel.statusFor("flash!", false, true, "", false, false).text, "flash!")
    verify(!MediaModel.statusFor("flash!", false, true, "", false, false).error)
    verify(MediaModel.statusFor("oops", true, true, "", false, false).error)
    var scanErr = MediaModel.statusFor("", false, false, "Scan failed (exit 1)", false, false)
    compare(scanErr.text, "Scan failed (exit 1)")
    verify(scanErr.error)
    var watchErr = MediaModel.statusFor("", false, false, "", true, false)
    verify(watchErr.text.indexOf("watching") >= 0)
    verify(watchErr.error)
    var allBad = MediaModel.statusFor("", false, false, "", false, true)
    verify(allBad.text.indexOf("failed to load") >= 0)
    verify(allBad.error)
    // flash wins over error states while active
    var flashWins = MediaModel.statusFor("picking", false, true, "Scan failed (exit 1)", true, true)
    compare(flashWins.text, "picking")
    verify(!flashWins.error)
  }

  // ---- position clamping --------------------------------------------------

  function test_clampMargin() {
    compare(MediaModel.clampMargin(48, 360, 1920), 48)
    compare(MediaModel.clampMargin(0, 360, 1920), 0)      // zero is valid
    compare(MediaModel.clampMargin(-20, 360, 1920), 0)
    compare(MediaModel.clampMargin(1700, 360, 1920), 1560) // card stays on screen
    compare(MediaModel.clampMargin(50, 2000, 1920), 0)     // card larger than screen
  }
}
