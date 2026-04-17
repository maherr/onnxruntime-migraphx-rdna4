#!/usr/bin/env bash
# build.sh, clone, patch, and build ONNX Runtime 1.24.2 + AMDMIGraphX 6.4.2
# for AMD RDNA 4 (gfx1201 / RX 9070).
#
# Overridable env vars:
#   BUILD_DIR                      Working dir for clones + builds  (default: ~/.local/share/gpu-diarization-build)
#   INSTALL_PREFIX                 Install prefix                    (default: $BUILD_DIR)
#   JOBS                           Parallel build jobs               (default: nproc)
#   GFX_TARGET                     AMDGPU target arch                (default: gfx1201)
#   ROCM_PREFIX                    ROCm install root                 (default: /usr on Fedora; use /opt/rocm on Ubuntu)
#   ORT_MIGRAPHX_MODEL_CACHE_PATH  Where the shipped .mxr is dropped (default: ~/.cache/migraphx-compiled)
#   SKIP_CHECKS                    Set to bypass sanity checks       (default: unset)
#
# Exit codes:
#   0   success
#   1   prerequisite check failed
#   2   clone / patch application failed
#   3   build failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"

BUILD_DIR="${BUILD_DIR:-$HOME/.local/share/gpu-diarization-build}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$BUILD_DIR}"
JOBS="${JOBS:-$(nproc)}"
GFX_TARGET="${GFX_TARGET:-gfx1201}"
ROCM_PREFIX="${ROCM_PREFIX:-/usr}"

# Pinned SHAs (verified working on Fedora 43 + ROCm 6.4.4 + RX 9070)
MIGRAPHX_REPO="https://github.com/ROCm/AMDMIGraphX.git"
MIGRAPHX_BRANCH="rocm-6.4.2"
MIGRAPHX_SHA="db302ae"

ORT_REPO="https://github.com/microsoft/onnxruntime.git"
ORT_TAG="v1.24.2"
ORT_SHA="058787c"

MIGRAPHX_DIR="$BUILD_DIR/AMDMIGraphX"
ORT_DIR="$BUILD_DIR/onnxruntime"
MIGRAPHX_INSTALL="$INSTALL_PREFIX/migraphx-install"
ORT_INSTALL="$INSTALL_PREFIX/ort-rocm-install"

MIGRAPHX_PATCHES=(
  01-migraphx-tf-subdir-disable
  02-migraphx-tf-stub-header
  03-migraphx-mlir-fuse-stub
  04-migraphx-mlir-introspection-stub
  05-migraphx-hipcc-device-guard
  06-migraphx-c-api-drop-tf-link
)
ORT_PATCHES=(
  07-ort-fp4x2-fallback
  08-ort-bf16-skip
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

check_prereqs() {
  if [ -n "${SKIP_CHECKS:-}" ]; then
    warn "Skipping sanity checks (SKIP_CHECKS set)"
    return
  fi

  log "Checking prerequisites"

  for tool in git cmake make rocminfo hipcc python3; do
    command -v "$tool" >/dev/null 2>&1 \
      || die "$tool not found. On Fedora 43: sudo dnf install git cmake make rocm-runtime-devel rocm-hip-devel python3" 1
  done

  local clang_major
  clang_major=$(clang --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || echo 0)
  if [ "$clang_major" -lt 19 ]; then
    die "clang $clang_major found, need >=19. On Fedora 43, the rocm-llvm package ships clang 19." 1
  fi

  if ! rocminfo 2>/dev/null | grep -q "$GFX_TARGET"; then
    warn "rocminfo does not report $GFX_TARGET, your GPU may not be the verified target."
    warn "Continuing anyway; override GFX_TARGET env var if you are on a different arch."
  fi

  local free_kb
  mkdir -p "$BUILD_DIR"
  free_kb=$(df -Pk "$BUILD_DIR" | awk 'NR==2 {print $4}')
  local free_gb=$((free_kb / 1024 / 1024))
  if [ "$free_gb" -lt 20 ]; then
    warn "Only ${free_gb} GB free at $BUILD_DIR, build wants ~25 GB. It may fail late."
  fi

  log "Prerequisites OK (clang $clang_major, $free_gb GB free at $BUILD_DIR)"
}

clone_pin() {
  local repo="$1" dir="$2" ref="$3" sha="$4"
  if [ -d "$dir/.git" ]; then
    log "Reusing existing clone at $dir"
    (cd "$dir" && git fetch --tags --quiet origin "$ref" 2>/dev/null || true)
  else
    log "Cloning $repo @ $ref"
    git clone --branch "$ref" --quiet "$repo" "$dir" \
      || die "Clone failed: $repo" 2
  fi
  (cd "$dir" && git checkout --quiet "$sha" 2>&1 | tail -3) \
    || die "Checkout $sha failed in $dir" 2
}

apply_patches() {
  local repo_dir="$1"; shift
  local patches=("$@")
  (
    cd "$repo_dir"
    for p in "${patches[@]}"; do
      local pfile="$PATCHES_DIR/$p.patch"
      [ -f "$pfile" ] || die "Missing patch file: $pfile" 2
      if git apply --check "$pfile" 2>/dev/null; then
        git apply "$pfile" || die "Apply failed: $p" 2
        log "Applied $p"
      elif git apply --reverse --check "$pfile" 2>/dev/null; then
        log "Already applied: $p"
      else
        die "Cannot apply $p, working tree may be dirty or base SHA wrong. Reset $repo_dir and retry." 2
      fi
    done
  )
}

build_migraphx() {
  log "Configuring MIGraphX → $GFX_TARGET"
  mkdir -p "$MIGRAPHX_DIR/build"
  (
    cd "$MIGRAPHX_DIR/build"
    cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DMIGRAPHX_GPU_TARGETS="$GFX_TARGET" \
      -DCMAKE_INSTALL_PREFIX="$MIGRAPHX_INSTALL" \
      -DCMAKE_PREFIX_PATH="$ROCM_PREFIX" \
      -DBUILD_TESTING=OFF \
      .. \
      || die "cmake MIGraphX failed" 3
    log "Building MIGraphX ($JOBS jobs, expect 20-40 min)"
    make -j"$JOBS" || die "make MIGraphX failed" 3
    log "Installing MIGraphX → $MIGRAPHX_INSTALL"
    make install || die "make install MIGraphX failed" 3
  )
}

build_ort() {
  log "Building ONNX Runtime with MIGraphX EP (expect 20-40 min)"
  (
    cd "$ORT_DIR"
    ./build.sh \
      --config Release \
      --use_migraphx \
      --migraphx_home "$MIGRAPHX_INSTALL" \
      --rocm_home "$ROCM_PREFIX" \
      --build_shared_lib \
      --parallel "$JOBS" \
      --skip_tests \
      --allow_running_as_root \
      || die "ORT build failed" 3

    # ORT doesn't have a clean --install_prefix; relocate the runtime artifacts explicitly.
    log "Installing ORT → $ORT_INSTALL"
    rm -rf "$ORT_INSTALL"
    mkdir -p "$ORT_INSTALL/lib"
    local rel="$ORT_DIR/build/Linux/Release"
    # libonnxruntime.so, .so.1, .so.1.24.2 (glob matches only .so variants, not providers)
    cp -a "$rel"/libonnxruntime.so* "$ORT_INSTALL/lib/" \
      || die "ORT install: core libonnxruntime copy failed" 3
    # Execution providers that ORT loads at runtime via dlopen
    cp -a "$rel/libonnxruntime_providers_shared.so" "$ORT_INSTALL/lib/" \
      || die "ORT install: providers_shared copy failed" 3
    cp -a "$rel/libonnxruntime_providers_migraphx.so" "$ORT_INSTALL/lib/" \
      || die "ORT install: providers_migraphx copy failed, check --use_migraphx build output" 3
  )
}

install_precompiled_mxr() {
  local mxr_src="$SCRIPT_DIR/artifacts/precompiled-mxr-gfx1201"
  local mxr_dest="${ORT_MIGRAPHX_MODEL_CACHE_PATH:-$HOME/.cache/migraphx-compiled}"

  if ! ls "$mxr_src"/*.mxr >/dev/null 2>&1; then
    log "No shipped .mxr found at $mxr_src (first witness call will cold-compile, ~46s)"
    return 0
  fi

  log "Installing shipped precompiled .mxr → $mxr_dest"
  mkdir -p "$mxr_dest"
  # cp -n: don't overwrite an existing .mxr with the same hash
  cp -n "$mxr_src"/*.mxr "$mxr_dest/" 2>/dev/null || true
  log "  If ORT/MIGraphX/driver/model hashes match, first witness call hits warm cache (~17s)"
  log "  If not, MIGraphX will cold-compile and write a new .mxr (harmless, just no speedup)"
}

main() {
  log "Witness / ORT 1.24.2 + MIGraphX 6.4.2 build for $GFX_TARGET"
  log "  BUILD_DIR      = $BUILD_DIR"
  log "  INSTALL_PREFIX = $INSTALL_PREFIX"
  log "  JOBS           = $JOBS"
  echo

  check_prereqs
  mkdir -p "$BUILD_DIR"

  clone_pin "$MIGRAPHX_REPO" "$MIGRAPHX_DIR" "$MIGRAPHX_BRANCH" "$MIGRAPHX_SHA"
  apply_patches "$MIGRAPHX_DIR" "${MIGRAPHX_PATCHES[@]}"
  build_migraphx

  clone_pin "$ORT_REPO" "$ORT_DIR" "$ORT_TAG" "$ORT_SHA"
  apply_patches "$ORT_DIR" "${ORT_PATCHES[@]}"
  build_ort

  install_precompiled_mxr

  echo
  log "Build complete."
  log "  MIGraphX: $MIGRAPHX_INSTALL"
  log "  ORT:      $ORT_INSTALL"
  echo
  log "Next: install speakrs-cli from maherr/speakrs and see witness/README.md."
}

main "$@"
