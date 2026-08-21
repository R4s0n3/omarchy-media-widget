#!/usr/bin/env bash
# Lints every QML file in the plugin with qmllint.
#
# The Omarchy shell modules resolve as `qs.*` URIs even though they live in a
# plain `Commons`/`Ui` directory layout that qmllint cannot map directly, so
# this script builds a temporary `qs/` layout (real copies; the plugin
# validator rejects symlinks inside the plugin folder) and passes it via -I.
#
# Known-cosmetic warnings (same classes the Omarchy shell's own plugins emit
# with the shipped Quickshell qmltypes): PanelWindow is marked uncreatable, so
# its subtree resolves loosely; `Color.menu.*`/`Color.tooltip.*` go through a
# QtObject-typed property qmllint cannot introspect; DragHandler's
# `pressedChanged`/`pressed` come from a base class qmllint does not resolve;
# QProcess::ExitStatus is not declared in the Quickshell.Io qmltypes. None of
# these affect the runtime. The script fails only on qmllint exit status.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$(mktemp -d)"
trap 'rm -rf "$SHIM"' EXIT

mkdir -p "$SHIM/qs"
cp -rL /usr/share/omarchy/shell/Commons "$SHIM/qs/Commons"
cp -rL /usr/share/omarchy/shell/Ui "$SHIM/qs/Ui"

for f in MediaWidget.qml BarWidget.qml IconButton.qml MenuRow.qml MenuSliderRow.qml; do
  /usr/lib/qt6/bin/qmllint -I "$SHIM" "$DIR/$f"
done

echo "qmllint: OK"