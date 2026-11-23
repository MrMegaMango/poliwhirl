# Speech on another Mac

The Claude Stop hook reads the most recent assistant reply from the turn’s transcript. The Codex notification hook reads the final reply from the notification on standard input. Both use the same pause state and playback queue. Install the menu-bar app, playback helper and shell hooks as described in the [project README](../README.md).

| Source in this checkout | Installed location |
| --- | --- |
| `hooks/claude/{speak-response.sh,speak-pause.sh,muted.sh}` | `~/.claude/hooks/` |
| `Sources/speak-play.swift` | Compile to `~/.claude/hooks/speak-play` with the project build script |
| `hooks/codex/speak-response.sh` | `~/.codex/hooks/speak-response.sh` |
| `hooks/codex/phonon/render.py` | `~/.codex/hooks/phonon/render.py` |

The shell hooks require Bash and `jq`. When Phonon is unavailable they can synthesize speech with macOS `say`. Chinese text uses the selected macOS Chinese voice. Install that voice in macOS if needed.

## Install the local English voices

Run this from the checkout on a Mac with `uv` available. It installs a Python 3.12 virtual environment, checks the wheel and model hashes, and verifies existing assets on a repeat run.

```sh
./scripts/restore-phonon.sh
```

The installer uses `ptts` 0.4.2 with NumPy 2.5.4, the Q8 English 31M model, and the Harper and Zoey voices. Weights and Python dependencies are downloaded during setup. Rendering runs locally. [ptts on PyPI](https://pypi.org/project/ptts/0.4.2/) · [Pinned model](https://huggingface.co/gradium/phonon-31m-en/tree/8c64b55ec301728e2d1695bfea87a08a267d0c2d) · [Pinned voice catalogue](https://huggingface.co/gradium/phonon-voices/tree/0ee17205f254b5abc43b266c8a0f215565c352f7)

To check a voice without playing sound, render a short phrase into a temporary directory.

```sh
audio_dir=$(mktemp -d)
phonon="$HOME/.codex/hooks/phonon"
printf '%s' 'Local speech check.' | "$phonon/venv/bin/python" "$phonon/render.py" Harper "$audio_dir/check.wav"
afinfo "$audio_dir/check.wav"
```

## Choose what leaves the Mac

The installed hooks default to requesting a spoken summary of the final reply when a provider key is available. Their default model order is `gpt-6-astra` through the OpenAI Responses API, followed by `claude-opus-5` through the Anthropic Messages API. They can use credentials already available to the caller, including an API key stored by Codex. Unavailable models or keys fall back to a locally shortened reply.

For local-only speech, set the following in the Mac’s private `~/.claude/hooks/voice.env` before enabling the hooks. Both hooks source that file. If `~/.codex/hooks/voice.env` already exists, make sure its settings also select local-only speech because Codex loads it afterward.

```sh
SUMMARIZE=0
CODEX_SUMMARIZE=0
```

Restrict private voice configuration to its owner with `chmod 600`. Claude’s local speech log can include excerpts of replies. Keep voice configuration, logs, transcripts and client authentication outside the source checkout.

## Register the hooks

In Claude Code, append the command below to a `hooks` array inside `hooks.Stop` in `~/.claude/settings.json`. For a fresh settings file the full shape is shown below. Retain existing Stop commands and other event handlers. One registration is sufficient.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.claude/hooks/speak-response.sh\"",
            "async": true
          }
        ]
      }
    ]
  }
}
```

Codex passes notification JSON as its final argument. The speech hook expects that JSON on standard input. On a fresh install with no existing `notify` setting, add this top-level line to `~/.codex/config.toml`, above any TOML section header.

```toml
notify = ["/bin/sh", "-c", "printf '%s' \"$1\" | \"$HOME/.codex/hooks/speak-response.sh\"", "poliwhirl-notify"]
```

If Codex already has a notification dispatcher, retain its existing `notify` setting and other handlers. If it already invokes `speak-response.sh`, installing the executable at that path is enough. Otherwise add the following inside the dispatcher's existing turn-completion handler, after any root-chat filter. Here `payload` is the JSON string the dispatcher already received.

```sh
if [ -x "$HOME/.codex/hooks/speak-response.sh" ]; then
  printf '%s' "$payload" | "$HOME/.codex/hooks/speak-response.sh" >/dev/null 2>&1 &
fi
```
