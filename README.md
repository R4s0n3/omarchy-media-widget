# Media Widget

A floating slideshow widget for the omarchy desktop: a draggable square that
plays photos, GIFs and videos from a folder you pick, always on top of your
desktop.

Originally a standalone C++/Qt desktop app, this is the omarchy plugin
rewrite. It is pure QML + shell scripts and needs no separate runtime.

![Media widget on the desktop](assets/widget-screenshot.png)

## Features

- Plays photos, GIFs and videos (mp4, mov, m4v, webm, mkv, avi, jpg, png,
  gif, webp, bmp, avif) from any folder, recursively.
- The folder is picked from the context menu with the normal folder picker
  (zenity, kdialog fallback).
- Draggable: grab the square with the left button and move it anywhere;
  the position persists in `shell.json`.
- Hover controls: previous / pause-play / next, plus a slideshow interval
  slider (300 s max).
- Live folder watching (inotify): dropping or removing files rescans
  immediately, no restart needed.
- Bar toggle button (photo-frame icon) shows/hides the widget.
- Optional iCloud photo library sync — see `scripts/sync_icloud.sh`.

## Install

```
omarchy plugin install <path-or-url-to-this-plugin>
omarchy plugin enable io.github.ras.mediawidget
```

## Settings

Stored in the `bar.layout.right` entry of `~/.config/omarchy/shell.json`:

| Key            | Default                    | Meaning                          |
| -------------- | -------------------------- | -------------------------------- |
| `folder`       | `~/Pictures/mediawidget`   | Media folder (recursive)         |
| `interval`     | `300`                      | Slideshow interval in seconds    |
| `size`         | `360`                      | Widget size in pixels            |
| `shuffle`      | `false`                    | Random order                     |
| `effects`      | `true`                     | Fade transition between items    |
| `marginRight`  | `48`                       | Distance from right screen edge  |
| `marginBottom` | `48`                       | Distance from bottom screen edge |

## Controls

- Left-drag: move the widget.
- Right-click: context menu (Pick a folder…, Open folder, shuffle, effects,
  controls, close).
- Hover the widget: previous / pause-play / next buttons and interval slider.
- Keyboard (widget focused): `Space` pause, `Left`/`Right` previous/next,
  `Esc` hide.
- Bar button: show / hide.

## Development

```
omarchy plugin validate ~/.config/omarchy/plugins/io.github.ras.mediawidget
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell MediaWidget.qml
```

Debug IPC (while the shell runs):

```
omarchy-shell shell call io.github.ras.mediawidget widgetState ''
omarchy-shell shell call io.github.ras.mediawidget mediaCount ''
omarchy-shell shell call io.github.ras.mediawidget mediaFolder ''
```

## iCloud sync (optional)

`scripts/sync_icloud.sh` runs the `boredazfcuk/icloudpd` docker container and
downloads an iCloud photo library into the widget's folder every 24 h:

```
scripts/sync_icloud.sh init   # first login (Apple ID password + 2FA code)
scripts/sync_icloud.sh sync   # manual sync
```

Edit `~/.config/mediawidget/icloudpd.env` to point `apple_id` (and, if you
have several libraries, `photo_library`) at your library. The widget itself
has no iCloud code — it just watches whatever folder it is pointed at.

## License

GPL-3.0-or-later