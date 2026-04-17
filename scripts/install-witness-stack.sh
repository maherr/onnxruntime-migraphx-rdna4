#!/usr/bin/env bash
# install-witness-stack.sh
#
# Installs the runtime deps Witness needs on top of ORT + MIGraphX:
#   - whisper.cpp (built with Vulkan)
#   - speakrs-cli (maherr fork with MIGraphX execution mode)
#   - Whisper large-v3 ggml model (~2.9 GB, one-time download)
#
# Run this after `bash build.sh` in the repo root has succeeded.
#
# Note on speakrs: this script clones from `maherr/speakrs` by default, which
# is a personal fork that adds a MIGraphX execution mode on top of upstream
# `avencera/speakrs`. If the clone 404s, the fork isn't published yet. Point
# SPEAKRS_REPO at your own fork or a mirror that provides the MIGraphX EP.
#
# Overridable env vars:
#   WHISPER_CPP_DIR     Clone/build dir for whisper.cpp   (default: ~/.local/share/whisper-cpp)
#   SPEAKRS_DIR         Clone/build dir for speakrs       (default: ~/.local/share/speakrs-cli)
#   WHISPER_MODEL_DIR   Where to drop the Whisper model   (default: ~/.local/share/voxtype/models)
#   SPEAKRS_REPO        speakrs fork URL                  (default: https://github.com/maherr/speakrs.git)
#   WHISPER_CPP_REPO    whisper.cpp upstream URL          (default: https://github.com/ggerganov/whisper.cpp.git)
#   JOBS                Parallel build jobs               (default: nproc)
#   SKIP_CHECKS         Skip distro-dep sanity checks     (default: unset)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WHISPER_CPP_DIR="${WHISPER_CPP_DIR:-$HOME/.local/share/whisper-cpp}"
SPEAKRS_DIR="${SPEAKRS_DIR:-$HOME/.local/share/speakrs-cli}"
WHISPER_MODEL_DIR="${WHISPER_MODEL_DIR:-$HOME/.local/share/voxtype/models}"
SPEAKRS_REPO="${SPEAKRS_REPO:-https://github.com/maherr/speakrs.git}"
WHISPER_CPP_REPO="${WHISPER_CPP_REPO:-https://github.com/ggerganov/whisper.cpp.git}"
JOBS="${JOBS:-$(nproc)}"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

check_prereqs() {
  if [ -n "${SKIP_CHECKS:-}" ]; then
    warn "Skipping sanity checks (SKIP_CHECKS set)"
    return
  fi

  log "Checking prerequisites"

  local missing=()
  for tool in git cmake make ffmpeg ffprobe curl vulkaninfo; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
    missing+=("rust-toolchain")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing tools: ${missing[*]}"
    warn ""
    warn "On Fedora 43:"
    warn "  sudo dnf install git cmake make ffmpeg vulkan-tools mesa-vulkan-drivers curl"
    warn "On Ubuntu 22.04+:"
    warn "  sudo apt install git cmake make ffmpeg vulkan-tools mesa-vulkan-drivers curl"
    warn "Rust (all distros, user install):"
    warn "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    die "Install the missing tools and re-run" 1
  fi

  log "Prerequisites OK"
}

build_whisper_cpp() {
  local bin="$WHISPER_CPP_DIR/src/build/bin/whisper-cli"
  if [ -x "$bin" ]; then
    log "whisper-cli already at $bin"
    return
  fi
  mkdir -p "$WHISPER_CPP_DIR"
  if [ ! -d "$WHISPER_CPP_DIR/src/.git" ]; then
    log "Cloning whisper.cpp → $WHISPER_CPP_DIR/src"
    git clone --quiet "$WHISPER_CPP_REPO" "$WHISPER_CPP_DIR/src" \
      || die "whisper.cpp clone failed" 2
  else
    log "Reusing existing whisper.cpp clone at $WHISPER_CPP_DIR/src (pulling latest)"
    git -C "$WHISPER_CPP_DIR/src" pull --ff-only --quiet 2>/dev/null \
      || warn "git pull failed (dirty tree or detached HEAD?); building current state"
  fi
  log "Building whisper.cpp with Vulkan ($JOBS jobs, ~3-5 min)"
  (
    cd "$WHISPER_CPP_DIR/src"
    cmake -B build -DGGML_VULKAN=1 -DCMAKE_BUILD_TYPE=Release >/dev/null \
      || die "cmake whisper.cpp failed" 3
    cmake --build build -j "$JOBS" --target whisper-cli >/dev/null \
      || die "build whisper.cpp failed" 3
  )
  log "whisper-cli → $bin"
}

build_speakrs() {
  local bin="$HOME/.local/bin/speakrs-cli"
  if [ -x "$bin" ]; then
    log "speakrs-cli already at $bin"
    return
  fi
  if [ ! -d "$SPEAKRS_DIR/.git" ]; then
    log "Cloning speakrs → $SPEAKRS_DIR"
    git clone --quiet "$SPEAKRS_REPO" "$SPEAKRS_DIR" \
      || die "speakrs clone from $SPEAKRS_REPO failed. If this 404'd, the maherr fork may not be published yet. Point SPEAKRS_REPO at your own fork (needs the MIGraphX execution mode on top of upstream avencera/speakrs)." 2
  else
    log "Reusing existing speakrs clone at $SPEAKRS_DIR (pulling latest)"
    git -C "$SPEAKRS_DIR" pull --ff-only --quiet 2>/dev/null \
      || warn "git pull failed (dirty tree or detached HEAD?); building current state"
  fi
  log "Building speakrs-cli ($JOBS jobs, ~2-4 min)"
  (
    cd "$SPEAKRS_DIR"
    cargo build --release --bin speakrs-cli --jobs "$JOBS" \
      || die "cargo build failed" 3
  )
  mkdir -p "$HOME/.local/bin"
  cp "$SPEAKRS_DIR/target/release/speakrs-cli" "$bin"
  log "speakrs-cli → $bin"
}

download_whisper_model() {
  local model_file="$WHISPER_MODEL_DIR/ggml-large-v3.bin"
  if [ -f "$model_file" ]; then
    local size_mb=$(($(stat -c%s "$model_file") / 1024 / 1024))
    log "Whisper large-v3 already at $model_file (${size_mb} MB)"
    return
  fi
  log "Downloading Whisper large-v3 (~2.9 GB) → $model_file"
  mkdir -p "$WHISPER_MODEL_DIR"
  curl -L --fail --progress-bar --continue-at - \
    -o "$model_file" "$WHISPER_MODEL_URL" \
    || { rm -f "$model_file"; die "Download failed. Re-run to resume." 2; }
  log "Whisper model downloaded"
}

summary() {
  echo
  log "Witness runtime stack installed."
  log "  whisper-cli:    $WHISPER_CPP_DIR/src/build/bin/whisper-cli"
  log "  speakrs-cli:    $HOME/.local/bin/speakrs-cli"
  log "  Whisper model:  $WHISPER_MODEL_DIR/ggml-large-v3.bin"
  echo
  log "Try it:"
  log "  $SCRIPT_DIR/../witness/witness path/to/audio.m4a"
}

main() {
  log "Installing the Witness runtime stack"
  check_prereqs
  build_whisper_cpp
  build_speakrs
  download_whisper_model
  summary
}

main "$@"
