# onnxruntime-migraphx-rdna4

Eight small patches that let ONNX Runtime 1.24.2 + AMDMIGraphX (`rocm-6.4.2` branch) build and run on AMD RDNA 4 consumer GPUs (specifically the RX 9070 / Navi 48 / gfx1201) on Fedora 43.

ONNX Runtime's MIGraphX path already works on RDNA 2 and RDNA 3. RDNA 4 was the missing rung. These patches fill it. The [Witness](witness/README.md) speaker-diarization pipeline that lives in `witness/` is the first thing I used to prove the stack end-to-end; any ONNX model that runs on ORT's CUDA EP should be attemptable on consumer AMD via this build.

What I actually measured, on a $550 RX 9070:

- VoxConverse TEST (232 files, 43.5 h): **10.65% strict DER / 7.85% at c=0.25 / 6.90% lenient**, 15.47× realtime. The lowest open-source numbers I've found on this benchmark.
- VoxConverse DEV (216 files, 20.3 h): **6.84% / 4.64% / 3.61%** under the same three conventions.
- Hypothesis RTTMs are saved on disk; anyone with `pyannote.metrics` can re-score from them.

Blog write-up: [maherr.dev](https://maherr.dev) (pending publication).

## Quickstart

Prerequisites on Fedora 43:

```sh
sudo dnf install git cmake make rocm-runtime-devel rocm-hip-devel rocm-llvm-devel python3
```

That pulls in ROCm 6.4.4, `hipcc`, and clang 19. On Ubuntu 22.04 with AMD's ROCm repos the equivalent is `rocm-dev` plus the `rocm-llvm` meta-package; pass `ROCM_PREFIX=/opt/rocm` to the build script.

Build ORT + MIGraphX with the eight patches:

```sh
git clone https://github.com/maherr/onnxruntime-migraphx-rdna4.git
cd onnxruntime-migraphx-rdna4
bash build.sh
```

Expect ~45–75 min on a 16-thread machine and ~25 GB of free disk. The script clones MIGraphX at `rocm-6.4.2` (`db302ae`) and ORT at `v1.24.2` (`058787c`), applies the eight patches, builds both, and installs to `~/.local/share/gpu-diarization-build/` by default. Override via `BUILD_DIR`, `INSTALL_PREFIX`, `JOBS`, `GFX_TARGET`, `ROCM_PREFIX`.

At the end of the build, the precompiled `.mxr` shipped in `artifacts/` is copied into `~/.cache/migraphx-compiled/`. If your ORT + MIGraphX + driver hashes match the pinned build, your first Witness call hits the warm cache (~17 s) instead of cold-compiling (~46 s). If they don't match, MIGraphX transparently re-compiles on first run.

To run Witness itself (optional, if you want the speaker-diarization demo):

```sh
bash scripts/install-witness-stack.sh
./witness/witness path/to/audio.m4a
```

That script installs the pieces Witness needs on top of ORT + MIGraphX: `whisper.cpp` built with Vulkan, the `speakrs-cli` fork with MIGraphX support, and the Whisper large-v3 ggml model (~2.9 GB, one-time download). Adds ~5 min of build time plus the model download.

Heads-up: the speakrs fork is a personal one that adds MIGraphX execution mode on top of upstream `avencera/speakrs`. If the clone 404s, it hasn't been pushed yet. Set `SPEAKRS_REPO` to point at your own fork.

## What's in the repo

```
patches/                              The eight patches + per-patch rationale
├── 01-migraphx-tf-subdir-disable.patch
├── 02-migraphx-tf-stub-header.patch
├── 03-migraphx-mlir-fuse-stub.patch
├── 04-migraphx-mlir-introspection-stub.patch
├── 05-migraphx-hipcc-device-guard.patch
├── 06-migraphx-c-api-drop-tf-link.patch
├── 07-ort-fp4x2-fallback.patch
└── 08-ort-bf16-skip.patch
artifacts/precompiled-mxr-gfx1201/    27 MB pre-compiled WeSpeaker ResNet34 .mxr
                                      (SHA-pinned; see that dir's README)
scripts/install-witness-stack.sh      whisper.cpp + speakrs + Whisper model installer
build.sh                              ORT + MIGraphX + patches, reproducible
witness/                              Speaker-aware transcription pipeline
LICENSE                               MIT
THIRD_PARTY_LICENSES.md               Dependency license catalogue
```

`build.sh` is strictly the ORT + MIGraphX layer. `scripts/install-witness-stack.sh` is the Witness runtime layer on top. Split this way so anyone who just wants the patches for *their* ONNX work doesn't have to install the diarization stack.

## What this was verified on

| Component  | Version / spec |
|------------|---------------|
| GPU        | AMD Radeon RX 9070 (RDNA 4, Navi 48, gfx1201) |
| CPU        | AMD Ryzen 7 5800X3D |
| OS         | Fedora 43 KDE, kernel 6.19.11 |
| ROCm       | 6.4.4 (Fedora packages: `rocm-core-6.4.4-1.fc43`, `rocm-runtime-6.4.2`, `rocm-hip-6.4.2`) |
| LLVM/clang | 19 (from `rocm-llvm-19-14.rocm6.4.2.fc43`) |
| MIGraphX   | `rocm-6.4.2` branch at `db302ae` + the six MIGraphX patches here |
| ORT        | `v1.24.2` at `058787c` + the two ORT patches here |

Other RDNA 4 parts (RX 9070 XT, RX 9060 series) should inherit support via the same gfx1200/gfx1201 ISA family, but I haven't tested them. PRs and issue reports from other cards very welcome.

On RDNA 3 (RX 7900 XT/XTX, gfx1100), Patch 5 (`no_device.cpp` guard) is likely still useful and the MLIR stubs (Patches 3 and 4) should still apply on Fedora, but I haven't verified it. File an issue if you try.

## Known issues

- **Rare heap-corruption race during process teardown.** I saw one crash in 232 sequential runs (binomial 95% CI roughly 0.01–2.4%, so "rare, not pinned down"). Surfaces as `corrupted double-linked list` from glibc, fires during `_dl_fini` after `main()` returns cleanly, so diarization output has already been written by then. Mitigation: for batch processing, retry the failed file once in a fresh subprocess. Single calls haven't hit it in my usage. Filed upstream at [`ROCm/AMDMIGraphX#4792`](https://github.com/ROCm/AMDMIGraphX/issues/4792) and [`microsoft/onnxruntime#28087`](https://github.com/microsoft/onnxruntime/issues/28087). Probably resolves when ROCm 7.x lands gfx1201 as officially supported.

## Sunset window

These patches target ROCm 6.4 + ORT 1.24.2. Useful shelf life is probably 2–6 months:

- **Patches 7, 8** become no-ops once ROCm 7.x ships native `fp4x2` and `bf16` quantization.
- **Patches 1, 2, 6** are Fedora-packaging workarounds (TF protobuf ABI, stub header, C-API link). They persist until Fedora packages protobuf / MIGraphX at matching ABIs.
- **Patches 3, 4** are MLIR toolchain workarounds. MLIR version drift is recurring, so these are the most durable.
- **Patch 5** depends on whether AMD cleans up the `#error` in `no_device.cpp` for the gfx12xx device-compile path.

The best-case outcome is that ROCm's consumer story gets good enough that this repo becomes obsolete.

## License

MIT. See [`LICENSE`](LICENSE). Upstream AMDMIGraphX and onnxruntime are also MIT. See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for the full dependency tree.

## Contributing

Issues and PRs welcome. The most useful things anyone could add:

- Reports from other AMD consumer GPUs (other RDNA 4 variants, RDNA 3, Fedora vs Ubuntu vs Arch).
- ONNX models beyond diarization that compile on MIGraphX with these patches (YOLO, sentence-transformers, ArcFace, Silero VAD; see the blog's "what else these patches unlock" list).
- Cleaner fixes that would be upstream-friendly. Some of my stubs are graceful-degradation, not correct fixes. PRs that replace a stub with the real thing are welcome.

Solo project, no sponsor, no employer. Just publishing what worked in case it saves someone else the same thirty hours.
