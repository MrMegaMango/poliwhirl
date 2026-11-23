#!/usr/bin/env python3
"""Restore the project into the current macOS user's home directory."""
import json
import os
import plistlib
import re
import secrets
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()
CLAUDE = HOME / ".claude/hooks"
CODEX = HOME / ".codex/hooks"
EXTENSION = HOME / "Library/Application Support/Poliwhirl/chrome-extension"
AGENT = "com.zwang.capsmute.plist"


def write_new(path, content, mode):
    """Publish a complete file exclusively. Accept an identical earlier restore."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent) as temporary:
        temporary.write(content)
        temporary.flush()
        os.fchmod(temporary.fileno(), mode)
        try:
            os.link(temporary.name, path)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != content:
                raise SystemExit(f"Existing file differs: {path}")


def native_pairing():
    path = CLAUDE / "music-pause.json"
    if not path.exists():
        data = {"token": secrets.token_hex(32), "port": 49753}
        write_new(path, (json.dumps(data) + "\n").encode(), 0o600)
    config = json.loads(path.read_bytes())
    if config.get("port") != 49753 or not re.fullmatch("[a-fA-F0-9]{64}", config.get("token", "")):
        raise SystemExit(f"Expected a 64-digit hex token and port 49753 in {path}")
    return config["token"]


def restore():
    if sys.platform != "darwin":
        raise SystemExit("Poliwhirl requires macOS.")
    files = []
    for name in ("caps-mute-menubar", "speak-play"):
        binary = ROOT / "build" / name
        if not binary.is_file():
            raise SystemExit("Build the binaries with ./scripts/build.sh first.")
        files.append((CLAUDE / name, binary.read_bytes(), 0o755))
        files.append((CLAUDE / (name + ".swift"), (ROOT / "Sources" / (name + ".swift")).read_bytes(), 0o644))
    for client, dest, names in (
        ("claude", CLAUDE, ["muted.sh", "speak-pause.sh", "speak-response.sh"]),
        ("codex", CODEX, ["speak-response.sh", "phonon/render.py"]),
    ):
        for name in names:
            files.append((dest / name, (ROOT / "hooks" / client / name).read_bytes(), 0o755))
    for name in ("manifest.json", "background.js", "content.js", "state-machine.js",
                 "popup.html", "popup.js", "popup.css"):
        files.append((EXTENSION / name, (ROOT / "chrome-extension" / name).read_bytes(), 0o644))

    agent = plistlib.loads((ROOT / "templates" / AGENT).read_bytes())
    agent["ProgramArguments"] = [str(CLAUDE / "caps-mute-menubar")]
    dest = HOME / "Library/LaunchAgents" / AGENT
    if not dest.exists() or plistlib.loads(dest.read_bytes()) != agent:
        files.append((dest, plistlib.dumps(agent, sort_keys=False), 0o644))
    if not (CLAUDE / "voice.env").exists():
        files.append((CLAUDE / "voice.env", (ROOT / "templates/voice.env.example").read_bytes(), 0o600))

    # Check for different existing hooks before creating a new browser pairing.
    for path, content, _mode in files:
        if path.is_symlink() or (path.exists() and path.read_bytes() != content):
            raise SystemExit(f"Existing file differs: {path}")
    template = (ROOT / "chrome-extension/config.js").read_text()
    if template.count("VOICE_MUSIC_PAUSE_TOKEN") != 1:
        raise SystemExit("Missing Chrome pairing placeholder.")
    paired = template.replace("VOICE_MUSIC_PAUSE_TOKEN", native_pairing()).encode()
    write_new(EXTENSION / "config.js", paired, 0o600)
    for path, content, mode in files:
        write_new(path, content, mode)
    print("Restored the menu app, speech helpers and login agent.")
    print(f"Load this unpacked extension in Chrome: {EXTENSION}")


if __name__ == "__main__":
    restore()
