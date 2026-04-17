# Patches

Eight `.patch` files that let `onnxruntime 1.24.2` and `AMDMIGraphX` (`rocm-6.4.2` branch) build and run on the RX 9070 (gfx1201) on Fedora 43. Six against MIGraphX, two against ONNX Runtime.

These are what actually made the build go. Some of them are graceful-degradation stubs rather than "correct" fixes, so I wouldn't expect all eight to land upstream as-is, but the issues they solve are real, and publishing them documents the gaps in case anyone else hits the same walls.

Verified on: AMD Radeon RX 9070, Fedora 43, kernel 6.19.11, ROCm 6.4.4 packages.

## Apply order

| # | File | Target | Touches | Summary |
|---|------|--------|---------|---------|
| 01 | `01-migraphx-tf-subdir-disable.patch` | MIGraphX @ `rocm-6.4.2` | `src/CMakeLists.txt` | Skip `add_subdirectory(tf)` (protobuf ABI mismatch on Fedora 43) |
| 02 | `02-migraphx-tf-stub-header.patch` | MIGraphX @ `rocm-6.4.2` | `src/include/migraphx/tf/export.h` (new) | Tiny stub header so the ONNX path compiles after 01 |
| 03 | `03-migraphx-mlir-fuse-stub.patch` | MIGraphX @ `rocm-6.4.2` | `src/targets/gpu/fuse_mlir.cpp` | Stub the MLIR fusion pass (rocMLIR version drift on Fedora) |
| 04 | `04-migraphx-mlir-introspection-stub.patch` | MIGraphX @ `rocm-6.4.2` | `src/targets/gpu/mlir.cpp` | Stub rocMLIR introspection helpers; companion to 03 |
| 05 | `05-migraphx-hipcc-device-guard.patch` | MIGraphX @ `rocm-6.4.2` | `src/targets/gpu/no_device.cpp` | Remove the `#error` that hipcc's device-compile pass trips over on gfx1201 |
| 06 | `06-migraphx-c-api-drop-tf-link.patch` | MIGraphX @ `rocm-6.4.2` | `src/api/CMakeLists.txt` | Drop `-lmigraphx_tf` (companion to 01) |
| 07 | `07-ort-fp4x2-fallback.patch` | onnxruntime @ `v1.24.2` | `.../migraphx_execution_provider.cc` | Graceful CPU fallback for `fp4x2` ops ROCm 6.4 doesn't support |
| 08 | `08-ort-bf16-skip.patch` | onnxruntime @ `v1.24.2` | same file (hunk 2) | Skip `migraphx::quantize_bf16()` (not available in MIGraphX 6.4) |

Six MIGraphX + two ORT = eight patches. Total about 2,500 lines of diff, most of that in Patches 3 and 4, which are long only because the rocMLIR C-API surface is broad; each individual stub is a trivial no-op.

## Apply command

If you want to apply by hand without the parent `build.sh`:

```sh
# MIGraphX:
cd /path/to/AMDMIGraphX
git checkout rocm-6.4.2   # or the pinned SHA db302ae
for p in 01-migraphx-tf-subdir-disable \
         02-migraphx-tf-stub-header \
         03-migraphx-mlir-fuse-stub \
         04-migraphx-mlir-introspection-stub \
         05-migraphx-hipcc-device-guard \
         06-migraphx-c-api-drop-tf-link; do
  git apply /path/to/patches/$p.patch
done

# ONNX Runtime:
cd /path/to/onnxruntime
git checkout v1.24.2       # or the pinned SHA 058787c
for p in 07-ort-fp4x2-fallback 08-ort-bf16-skip; do
  git apply /path/to/patches/$p.patch
done

# Build MIGraphX with explicit gfx1201 target:
cd /path/to/AMDMIGraphX && cmake -B build -DMIGRAPHX_GPU_TARGETS=gfx1201 -DCMAKE_PREFIX_PATH=/usr
cmake --build build -j && sudo cmake --install build
```

## Per-patch notes

### 01. TF protobuf ABI disable

MIGraphX's optional TensorFlow import path links against a protobuf ABI that doesn't match Fedora 43's protobuf 26. This gives a link-time crash when building the `tf` reader. Since the ONNX-only workload doesn't need TF import, disabling the subdirectory avoids the problem entirely. No functionality lost for ONNX users.

### 02. TF stub header

Companion to 01. A new `src/include/migraphx/tf/export.h` defining `MIGRAPHX_TF_EXPORT` / `MIGRAPHX_TF_NO_EXPORT` visibility macros. The main ONNX codepath transitively includes this header; without the stub, compilation fails before Patch 01's disable takes effect.

### 03. MLIR fuse-pass stub (fuse_mlir.cpp)

Fedora 43 doesn't package the exact rocMLIR version MIGraphX expects, and mixing versions produces link errors. This patch replaces the MLIR fusion pass with a minimal stub that returns `mlir_enabled() == false` and makes `fuse_mlir::apply()` a no-op. The compiler falls back to its native path. On the diarization models I tested, this costs a single-digit percentage in performance, not orders of magnitude.

### 04. MLIR introspection stub (mlir.cpp)

Companion to 03. Stubs the rocMLIR introspection helpers `fuse_mlir.cpp` would otherwise call (`dump_mlir`, `compile_mlir`, `insert_mlir`, `get_tuning_config_mlir`). Same rationale: MLIR version drift makes linking against the full surface infeasible on distros that don't ship a version-matched rocMLIR.

### 05. `#error` device-compilation guard (no_device.cpp)

`no_device.cpp` contains a `#error "Device compilation not allowed for migraphx_gpu. Do not link with hip::device."` that fires under `__HIP_DEVICE_COMPILE__`. On gfx1201, hipcc's device-compile pass false-positives into this file during intermediate passes, killing the build. The patch removes the `#error` and rewrites the guard as a silent no-op for the host path. Despite the "hipcc" label this patch sometimes gets, the fix lives in MIGraphX's source tree, not in hipcc. As of the `rocm-6.4.2` branch the upstream `#error` is still present.

### 06. C-API link cleanup

With 01 disabling the TF target, `libmigraphx_tf.so` is never built. This removes `-lmigraphx_tf` from the C-API link line so the linker doesn't look for it.

### 07. ORT fp4x2 graceful fallback

`ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT4E2M1` (a.k.a. `fp4x2`) isn't supported by MIGraphX in ROCm 6.4. Default ORT behavior is to crash during `GetCapability` when it encounters the op. The patched behavior returns `false` so ORT assigns the op to CPU instead. Graceful degradation rather than hard failure.

### 08. ORT bf16 quantize skip

`migraphx::quantize_bf16()` isn't available in MIGraphX 6.4. The direct call is replaced with a warning log; bf16 models then run through whatever compatible kernels exist or fall back cleanly, rather than crashing at session creation.

## Upstream filings

- [`ROCm/AMDMIGraphX#4792`](https://github.com/ROCm/AMDMIGraphX/issues/4792): rare heap-corruption race during teardown (`_dl_fini`). See the blog post's "Measurement misadventures" section.
- [`microsoft/onnxruntime#28087`](https://github.com/microsoft/onnxruntime/issues/28087): the same race, filed on the ORT side since attribution between MIGraphX-proper and ORT's MIGraphX EP isn't obvious from the backtrace.

Both issues are open at time of publishing. Most likely resolves when ROCm 7.x lands gfx1201 as officially supported, but I'd be glad to be wrong.

## Licensing

Upstream AMDMIGraphX, upstream onnxruntime, and these patches are all MIT. See the parent repo's `THIRD_PARTY_LICENSES.md` for the full dependency tree.

## Sunset window

Useful shelf life is probably 2–6 months, tied to ROCm 6.4.x and ORT 1.24.2:

- Patches 7 and 8 become no-ops once ROCm 7.x ships native `fp4x2` and `bf16` quantization.
- Patches 1, 2, 6 are Fedora-packaging workarounds that might persist longer.
- Patches 3 and 4 are the most durable: rocMLIR version drift is a recurring problem.
- Patch 5 depends on whether AMD ever cleans up the `#error` in `no_device.cpp` and improves the device-compile filter for the gfx12xx family.
