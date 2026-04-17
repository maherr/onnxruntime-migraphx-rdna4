# Patches for ONNX Runtime + MIGraphX on AMD RDNA 4 (gfx1201)

This directory contains the 8-patch series that enables `onnxruntime 1.24.2` + `AMDMIGraphX rocm-6.4.2` to build and run on AMD RDNA 4 consumer GPUs (RX 9070 / Navi 48 / gfx1201) on Fedora 43.

**Verified on:** AMD Radeon RX 9070, Fedora 43, kernel 6.19.11, ROCm 6.4.4 packages.

## Apply order

| # | File | Target repo | Touches | Summary |
|---|------|-------------|---------|---------|
| 01 | `01-migraphx-tf-subdir-disable.patch` | AMDMIGraphX@rocm-6.4.2 | `src/CMakeLists.txt` | Skip `add_subdirectory(tf)` — protobuf ABI mismatch on Fedora 43 |
| 02 | `02-migraphx-tf-stub-header.patch` | AMDMIGraphX@rocm-6.4.2 | `src/include/migraphx/tf/export.h` (new) | Minimal `tf/export.h` providing visibility macros that the ONNX path still references transitively |
| 03 | `03-migraphx-mlir-fuse-stub.patch` | AMDMIGraphX@rocm-6.4.2 | `src/targets/gpu/fuse_mlir.cpp` | Stub the MLIR fusion pass — MLIR toolchain not consistently packaged on Fedora |
| 04 | `04-migraphx-mlir-introspection-stub.patch` | AMDMIGraphX@rocm-6.4.2 | `src/targets/gpu/mlir.cpp` | Stub the MLIR introspection helpers (`dump_mlir`, `compile_mlir`, `insert_mlir`, `get_tuning_config_mlir`) — companion to Patch 03 |
| 05 | `05-migraphx-hipcc-device-guard.patch` | AMDMIGraphX@rocm-6.4.2 | `src/targets/gpu/no_device.cpp` | Remove the `#error "Device compilation not allowed…"` directive that hipcc's device-compile pass triggers on gfx1201 |
| 06 | `06-migraphx-c-api-drop-tf-link.patch` | AMDMIGraphX@rocm-6.4.2 | `src/api/CMakeLists.txt` | Remove `migraphx_tf` from `target_link_libraries` (companion to Patch 01) |
| 07 | `07-ort-fp4x2-fallback.patch` | onnxruntime@v1.24.2 | `…/migraphx_execution_provider.cc` | Return "unsupported" for `fp4x2` operands — graceful CPU fallback |
| 08 | `08-ort-bf16-skip.patch` | onnxruntime@v1.24.2 | same file (hunk 2) | Skip `migraphx::quantize_bf16()` call — not available in MIGraphX 6.4 |

Total: **6 MIGraphX + 2 ORT = 8 patches.**

## Apply command

```sh
# MIGraphX (from repo root):
cd /path/to/AMDMIGraphX
git checkout rocm-6.4.2
for p in 01-migraphx-tf-subdir-disable \
         02-migraphx-tf-stub-header \
         03-migraphx-mlir-fuse-stub \
         04-migraphx-mlir-introspection-stub \
         05-migraphx-hipcc-device-guard \
         06-migraphx-c-api-drop-tf-link; do
  git apply /path/to/patches/$p.patch
done

# ONNX Runtime (from repo root):
cd /path/to/onnxruntime
git checkout v1.24.2
for p in 07-ort-fp4x2-fallback 08-ort-bf16-skip; do
  git apply /path/to/patches/$p.patch
done

# Build MIGraphX with explicit gfx1201 target:
cd /path/to/AMDMIGraphX && mkdir -p build && cd build
cmake -DMIGRAPHX_GPU_TARGETS=gfx1201 -DCMAKE_PREFIX_PATH=/usr ..
make -j && make install
```

## Per-patch notes

### 01 — TF protobuf ABI disable
MIGraphX's optional TF import path links against a protobuf ABI that doesn't match what Fedora 43 ships (protobuf 26). Disabling the `tf` subdirectory avoids a link-time crash; the ONNX-only workload doesn't need TF import.

### 02 — TF stub header
A new `src/include/migraphx/tf/export.h` providing `MIGRAPHX_TF_EXPORT` / `MIGRAPHX_TF_NO_EXPORT` visibility macros. The main ONNX codepath still includes this header transitively; without the stub, compilation fails before Patch 01's disable takes effect.

### 03 — MLIR fuse-pass stub (fuse_mlir.cpp)
Fedora doesn't package the MLIR version MIGraphX expects, and mixing versions produces link errors. The fuse pass is replaced with a minimal stub that returns `mlir_enabled() == false` and makes `fuse_mlir::apply()` a no-op. The compiler falls back to its native path — single-digit percentage cost on diarization workloads, not orders of magnitude.

### 04 — MLIR introspection stub (mlir.cpp)
Companion to Patch 03. Stubs the introspection/codegen helpers that `fuse_mlir.cpp` would otherwise call — `dump_mlir`, `compile_mlir`, `insert_mlir`, `get_tuning_config_mlir`. Same rationale: MLIR version drift on Fedora makes linking against the full surface infeasible.

### 05 — hipcc device-compilation guard (no_device.cpp)
`no_device.cpp` contains a `#error "Device compilation not allowed for migraphx_gpu. Do not link with hip::device."` that fires under `__HIP_DEVICE_COMPILE__`. On gfx1201, hipcc's device-side compile pass false-positives into this file during intermediate passes, killing the build with the `#error`. The patch removes the `#error` (and rewrites the guard to a silent no-op for the host path) so the build completes. Despite the ship-plan label calling this a "hipcc device compilation guard," the fix lives in MIGraphX's source tree, not in hipcc itself. As of ROCm 6.4.2, the upstream `#error` is still present.

### 06 — C API link cleanup
With Patch 01 disabling the TF target, `libmigraphx_tf.so` is never built. Remove `-lmigraphx_tf` from the C API link line so the linker doesn't look for it.

### 07 — ORT fp4x2 graceful fallback
`ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT4E2M1` (aka `fp4x2`) isn't supported by MIGraphX in ROCm 6.4. Default ORT behavior: crash during `GetCapability`. Patched behavior: return `false` so the op is assigned to CPU instead. Graceful degradation rather than hard failure.

### 08 — ORT bf16 quantize skip
`migraphx::quantize_bf16()` isn't available in MIGraphX 6.4. The direct call is replaced with a warning log — bf16 models run through compatible kernels where they exist, or fall back cleanly rather than crashing at session creation.

## Upstream filings

- `ROCm/AMDMIGraphX#4792` — rare heap-corruption race during teardown (`_dl_fini`), documented in the blog post.
- `microsoft/onnxruntime#28087` — same race, filed on the ORT side.

Both tracked at convergence time. Expected resolution when ROCm 7.x ships gfx1201 as officially supported.

## Licensing

- Upstream AMDMIGraphX: MIT
- Upstream onnxruntime: MIT
- These patches: MIT (inherited; intended for upstream-friendly contribution)

See the parent repo's `THIRD_PARTY_LICENSES.md` for the full dependency tree.

## Sunset window

Expect a useful window of 2–6 months on this exact patch set, tied to ROCm 6.4.x. Patches 07 and 08 specifically become no-ops once ROCm 7.x ships native `fp4x2` and `bf16` quantization. Patches 01, 02, 06 are Fedora-packaging workarounds that may persist longer. Patches 03, 04 are more durable — MLIR toolchain version drift is a recurring issue in the ML ecosystem. Patch 05 depends on whether AMD ever cleans up the `#error` in `no_device.cpp` and improves the device-compile filter for gfx12xx.
