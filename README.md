# onnxruntime-migraphx-rdna4

**8 patches that unlock ONNX Runtime 1.24.2 + AMDMIGraphX 6.4.2 on AMD RDNA 4 (RX 9070 / Navi 48 / gfx1201), on Fedora 43.**

ONNX Runtime's MIGraphX path already supports RDNA 2 and RDNA 3. RDNA 4 was the missing rung. These 8 patches fill the gap — and [**Witness**](witness/README.md), a 15× realtime speaker-aware transcription pipeline, is Exhibit A.

Verified: **10.65% strict DER / 7.85% under VoxConverse paper convention** on the full 232-file VoxConverse test set (43.5 h). Beats pyannote.audio 3.1's 11.24% strict by −0.59pp on apples-to-apples scoring.

## Quickstart

```sh
git clone https://github.com/maherr/onnxruntime-migraphx-rdna4.git
cd onnxruntime-migraphx-rdna4
bash build.sh
```

`build.sh` clones pinned SHAs of AMDMIGraphX (`rocm-6.4.2`) and onnxruntime (`v1.24.2`), applies the 8 patches, builds both, and installs to `~/.local/share/gpu-diarization-build/` by default. Override paths via `BUILD_DIR` and `INSTALL_PREFIX` env vars. Build takes ~45–75 min total on a 16-thread machine and needs ~25 GB free disk.

Once built, see [`witness/README.md`](witness/README.md) for the speaker-aware transcription pipeline.

## What's in the repo

```
patches/                      8 patches + README with per-patch rationale
├── 01-migraphx-tf-subdir-disable.patch
├── 02-migraphx-tf-stub-header.patch
├── 03-migraphx-mlir-fuse-stub.patch
├── 04-migraphx-mlir-introspection-stub.patch
├── 05-migraphx-hipcc-device-guard.patch
├── 06-migraphx-c-api-drop-tf-link.patch
├── 07-ort-fp4x2-fallback.patch
└── 08-ort-bf16-skip.patch
build.sh                      Reproducible end-to-end build
witness/                      Speaker-aware transcription pipeline (Python)
LICENSE                       MIT
THIRD_PARTY_LICENSES.md       Dependency license catalogue
```

## Verified on

| Component  | Version / spec |
|------------|---------------|
| GPU        | AMD Radeon RX 9070 (RDNA 4, Navi 48, gfx1201) |
| CPU        | AMD Ryzen 7 5800X3D |
| OS         | Fedora 43 KDE, kernel 6.19.11 |
| ROCm       | 6.4.4 (Fedora packages) |
| LLVM/clang | 19 (shipped with rocm-llvm-19-14.rocm6.4.2.fc43) |
| MIGraphX   | rocm-6.4.2 branch + 6 patches from this repo |
| ORT        | v1.24.2 + 2 patches from this repo |

Other RDNA 4 parts (RX 9070 XT / RX 9060 series) should inherit support via the same gfx1201/gfx1200 family ISA. Untested — PRs and issue reports welcome.

On RDNA 3 (RX 7900 XT/XTX / gfx1100), Patch 5 (hipcc device guard) is likely still useful and the MLIR stubs (Patches 3/4) should still apply. If you test, file an issue.

## Known issues

- **Rare heap-corruption race during process teardown** (~0.4% rate). Surfaces as `corrupted double-linked list` from glibc after `main()` returns cleanly, inside `_dl_fini`. All diarization output has already been written by then. Mitigation: for batch processing, retry the failed file once in a fresh subprocess. Single calls have not hit it in practice. Filed upstream at [`ROCm/AMDMIGraphX#4792`](https://github.com/ROCm/AMDMIGraphX/issues/4792) and [`microsoft/onnxruntime#28087`](https://github.com/microsoft/onnxruntime/issues/28087). Expected to resolve when ROCm 7.x ships gfx1201 as officially supported.

## Sunset window

These patches target ROCm 6.4 + ORT 1.24.2. Expect a useful window of 2–6 months:

- Patches 07 + 08 become no-ops once ROCm 7.x ships native `fp4x2` and `bf16` quantization.
- Patches 01, 02, 06 are Fedora-packaging workarounds that may persist longer.
- Patches 03, 04 depend on MLIR toolchain drift — recurring issue across distros and versions.
- Patch 05 depends on whether AMD cleans up the `#error` in `no_device.cpp` under gfx12xx device-compile.

The goal is for ROCm's consumer story to get good enough that this repo becomes obsolete.

## License

MIT. See [`LICENSE`](LICENSE). Upstream AMDMIGraphX and onnxruntime are also MIT. See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for the full dependency tree.

## Blog post

Full write-up coming soon at [maherr.dev](https://maherr.dev).

## Contributing

Issues and PRs welcome. Especially useful:
- Reports from other AMD consumer GPUs (RDNA 3, RDNA 4 variants, Fedora vs Ubuntu)
- Verified ONNX models beyond diarization (YOLO, sentence-transformers, ArcFace, etc.)
- Cleaner fixes that would be upstream-friendly for AMD/Microsoft to adopt

No sponsor, no employer, no hidden angle. Fixes published in public so the next person doesn't have to repeat them.
