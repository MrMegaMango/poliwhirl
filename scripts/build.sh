#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
menu="$root/Sources/caps-mute-menubar.swift"
build="$root/build"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/poliwhirl-build.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$build"
swiftc -swift-version 5 -framework Cocoa -framework CoreGraphics -framework Network \
    "$menu" -o "$scratch/caps-mute-menubar"
codesign --force --sign - --identifier com.zwang.capsmute "$scratch/caps-mute-menubar"
swiftc -swift-version 5 -framework AVFoundation -framework AppKit \
    "$root/Sources/speak-play.swift" -o "$scratch/speak-play"

# Test the installed-source declarations without starting the menu or its local server.
{
    printf '%s\n' 'import Darwin' 'import Foundation'
    sed -n -e '/^final class MusicPauseState {$/,/^}$/p' \
        -e '/^struct SpeechSettingsStore {$/,/^}$/p' "$menu"
} > "$scratch/TestSubjects.swift"
swiftc -swift-version 5 "$scratch/TestSubjects.swift" "$root/Sources/tests/main.swift" \
    -o "$scratch/native-tests"
"$scratch/native-tests"
python3 "$root/Sources/tests/run-controls.py" "$menu"
node --test "$root/Sources/tests/state-machine.test.cjs" "$root/Sources/tests/extension.integration.test.cjs"

mv -f "$scratch/caps-mute-menubar" "$scratch/speak-play" "$build/"
