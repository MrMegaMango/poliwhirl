#!/bin/bash
set -euo pipefail

root="$HOME/.codex/hooks/phonon"
source_dir=$(cd "$(dirname "$0")/../hooks/codex/phonon" && pwd)
model_url="https://huggingface.co/gradium/phonon-31m-en/resolve/8c64b55ec301728e2d1695bfea87a08a267d0c2d"
voices_url="https://huggingface.co/gradium/phonon-voices/resolve/0ee17205f254b5abc43b266c8a0f215565c352f7"

fail() {
  echo "restore-phonon: $*" >&2
  exit 1
}

matches_hash() {
  local actual
  actual=$(shasum -a 256 < "$1")
  [[ ${actual%% *} == "$2" ]]
}

runtime_matches() {
  "$1" -IB -c 'import sys, importlib.metadata as m; import ptts, numpy
assert sys.version_info[:2] == (3, 12)
assert m.version("ptts") == "0.4.2" and m.version("numpy") == "2.5.4"' 2>/dev/null
}

[[ $(uname -s) == Darwin ]] || fail "the pinned wheels are for macOS"
if [[ -e "$root/render.py" ]]; then
  cmp -s "$source_dir/render.py" "$root/render.py" || fail "an existing render.py differs from this checkout"
fi
if [[ -e "$root/venv" ]]; then
  runtime_matches "$root/venv/bin/python" || fail "the existing venv differs from the pinned Python and packages"
fi

mkdir -p "$root/model/voices"
stage=$(mktemp -d "$root/.restore.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT

if [[ ! -e "$root/venv" ]]; then
  command -v uv >/dev/null || fail "install uv to create the Python 3.12 environment"
  uv --no-config venv --no-project --relocatable --python 3.12 "$stage/venv"
  uv --no-config pip install --python "$stage/venv/bin/python" --require-hashes \
    --default-index https://pypi.org/simple --only-binary :all: --no-deps -r - <<'WHEELS'
ptts==0.4.2 \
    --hash=sha256:7a7ecdf1d86b39b0694e6d1acb60065aa3bbfde3dc8361a7b00d3543c305b1bd \
    --hash=sha256:c1147dfc547a7357ea557ff5ee269bd7a9227ee449cd61efa8429af9ada66eea
numpy==2.5.4 \
    --hash=sha256:b11e8fda06a7d69f15ebf542660b74466c2e51094800c1fb794f47ad4faeef17 \
    --hash=sha256:9cb18a327b49c5c337f972b03682f6a49855525faaf3c0d3e9c96cd0fd8880a8 \
    --hash=sha256:c6342f54c67093cae5c0227eb0eb772fdb79f2a2c37a6eb278b9909ee06aa356 \
    --hash=sha256:aec3fc4b32ff82421274f5d205c559c51c840c8df66a78efd7f3612dd005a26a
WHEELS
  runtime_matches "$stage/venv/bin/python" || fail "the newly installed speech runtime cannot load"
  # rename(2) refuses to replace another populated venv if two restores finish together.
  if ! "$stage/venv/bin/python" -I -c 'import os, sys; os.rename(*sys.argv[1:])' "$stage/venv" "$root/venv"; then
    runtime_matches "$root/venv/bin/python" || fail "could not install the speech runtime"
  fi
fi

asset() {
  local target="$root/model/$1" url="$2" sha="$3"
  if [[ ! -e "$target" ]]; then
    curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error --retry 2 \
      --output "$stage/download" "$url"
    matches_hash "$stage/download" "$sha" || fail "download checksum mismatch for $1"
    ln "$stage/download" "$target" 2>/dev/null || [[ -f "$target" ]] || fail "could not install $1"
    rm "$stage/download"
  fi
  matches_hash "$target" "$sha" || fail "existing $1 has a different checksum"
}

asset config.json "$model_url/config.json" 7062ea376e6b158543c8abec8e5af67df171c49ad70eb7e2a0fb25c16f265e06
asset tokenizer.json "$model_url/tokenizer.json" 691a00068fa7b989f2f3e5ae5daa2d1a5bb319f2d5360deafcfb19a8bb6e7936
asset default-voice.safetensors "$model_url/default-voice.safetensors" f739e8c4c76ee7f92e7c94a82002748c8cd22e99582ac49f7b9b94cd63786e18
asset model.q8.gguf "$model_url/model.q8.gguf" a7d9aad2cd6dc66473f24a08bc6d2939030ef4d751ef82349361fbef3272dbae
asset voices/Harper.safetensors "$voices_url/voices/4SZHfMpw-p46Ywgs.safetensors" 6b3da6e2d796a20c51af892c482bd6509fb88267a221aff83c870843dee2a123
asset voices/Zoey.safetensors "$voices_url/voices/NbpkqMVS3CJeq2j8.safetensors" 97c7f8c253413574406ab80dd23f49c3ebb2517163b00a9bf86b9c4cf43e7e23

if [[ ! -e "$root/render.py" ]]; then
  cp "$source_dir/render.py" "$stage/render.py"
  ln "$stage/render.py" "$root/render.py" 2>/dev/null || cmp -s "$source_dir/render.py" "$root/render.py"
fi
echo "Phonon is ready in $root."
