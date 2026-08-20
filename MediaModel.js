// Shared helpers for the media slideshow widget.

function isVideo(url) {
  return /\.(mp4|mov|m4v|webm|mkv|avi)$/i.test(url)
}

function isGif(url) {
  return /\.gif$/i.test(url)
}

// Parse the output of scan.sh into a sorted array of file:// URLs.
// Drops empty lines and iCloud placeholder files (still-downloading media).
function parseScan(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (/\.icloud$/i.test(line)) continue
    out.push(line)
  }
  return out
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

// Pick the next index after `index` in a list of `count` items, honoring
// shuffle mode.
function nextIndex(index, count, shuffle) {
  if (count === 0) return -1
  if (count === 1) return 0
  if (!shuffle) return (index + 1) % count
  var n = index
  while (n === index) n = Math.floor(Math.random() * count)
  return n
}