#!/usr/bin/env bash
set -euo pipefail
# GODOT is an installed, checksum-verified editor on the build runner ONLY.
: "${GODOT:?}" "${GAME_SOURCE:?}" "${GAME_OUTPUT:?}"
[[ "$($GODOT --version)" == 4.7.2.stable.official.* ]]
mkdir -p "$GAME_OUTPUT"
"$GODOT" --headless --path "$GAME_SOURCE" --editor --import
for target in windows linux macos server; do
  mkdir -p "$GAME_OUTPUT/$target"
done
"$GODOT" --headless --path "$GAME_SOURCE" --export-release 'Native Windows' "$GAME_OUTPUT/windows/voltron.exe"
"$GODOT" --headless --path "$GAME_SOURCE" --export-release 'Native Linux' "$GAME_OUTPUT/linux/voltron.x86_64"
"$GODOT" --headless --path "$GAME_SOURCE" --export-release 'Native macOS' "$GAME_OUTPUT/macos/Voltron.zip"
"$GODOT" --headless --path "$GAME_SOURCE" --export-release 'Dedicated Linux' "$GAME_OUTPUT/server/voltron-server.x86_64"
chmod +x "$GAME_OUTPUT/linux/voltron.x86_64" "$GAME_OUTPUT/server/voltron-server.x86_64"
(cd "$GAME_OUTPUT/windows" && zip -q -r ../windows-x86_64.zip .)
(cd "$GAME_OUTPUT/linux" && tar czf ../linux-x86_64.tar.gz ./*)
(cd "$GAME_OUTPUT/server" && tar czf ../linux-server-x86_64.tar.gz ./*)
cp "$GAME_OUTPUT/macos/Voltron.zip" "$GAME_OUTPUT/macos-universal.zip"
