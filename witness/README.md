# Witness

A speaker-aware transcription pipeline for audio files. Whisper does the words (via `whisper.cpp` on Vulkan), `speakrs` does the speakers (via its ONNX Runtime + MIGraphX backend on ROCm). Both run on the same physical AMD GPU at the same time. Vulkan and ROCm use independent driver stacks on RDNA 4, and in my measurements they schedule on the card without meaningful contention.

Concretely, what I observed on an RX 9070:

- 20 s wall-clock for a 3-minute phone call (parallel mode), 32 s serial. About 36% faster than serial; longer calls save more (up to ~50% on 18-minute files).
- Diarization alone: 15.47× realtime on VoxConverse TEST; 10.65% strict DER.

Witness is the first thing I used to prove the ORT + MIGraphX patch stack end-to-end. If you care about the patches more than the pipeline, you can ignore this directory; `build.sh` in the repo root handles the patches without touching anything here.

## Installing the runtime stack

Witness needs more than the patched ORT + MIGraphX to run. Specifically:

| Piece | What | Where it ends up |
|---|---|---|
| `whisper.cpp` | Vulkan-accelerated transcription binary | `~/.local/share/whisper-cpp/src/build/bin/whisper-cli` |
| `speakrs-cli` | Rust diarizer with MIGraphX execution mode (`maherr/speakrs` fork) | `~/.local/bin/speakrs-cli` |
| Whisper large-v3 ggml model | Model weights, ~2.9 GB | `~/.local/share/voxtype/models/ggml-large-v3.bin` |
| `ffmpeg` | Audio format conversion | Distro package |
| Rust toolchain | Build `speakrs-cli` | `rustup` (user install) or distro |

The install script at `../scripts/install-witness-stack.sh` handles all of this. Run it after the parent directory's `build.sh` has finished:

```sh
bash ../scripts/install-witness-stack.sh
```

It checks for `ffmpeg`, `cargo`, `vulkaninfo` etc. first and tells you the right `dnf install` / `apt install` line if they're missing. Clone paths, model paths, and the `speakrs` fork URL are all overridable via env vars. See the script header.

The precompiled `.mxr` that ships in `../artifacts/precompiled-mxr-gfx1201/` is auto-installed into `~/.cache/migraphx-compiled/` at the end of `build.sh`, so your first Witness call should hit the warm cache (~17 s) instead of cold-compiling (~46 s). If the hashes don't match your environment, MIGraphX transparently re-compiles (no harm, just no speedup).

## Usage

```sh
witness input.m4a                          # default: auto language, parallel pipeline
witness input.m4a --output transcript.md   # custom output path
witness input.m4a --language fr            # force French (skips Whisper's auto-detect)
witness input.m4a --serial                 # run Whisper then speakrs sequentially (fallback)
```

On launch, Witness reads AMD VRAM sysfs to check free memory. If less than 4 GiB is free (a desktop with many open apps) it auto-falls-back to `--serial` to avoid OOM. Headless servers basically always stay in parallel mode.

## Output

Markdown with speaker labels and timestamps:

```markdown
# Diarized Transcript, example.m4a

**Duration:** 3:00
**Speakers detected:** 2
**Language:** en (auto-detected)
**Pipeline wall time:** 20.0s (parallel)

---

**SPEAKER_00** [0:00]
Alright, let's get started...

**SPEAKER_01** [0:12]
Sure. So what I wanted to ask is...
```

Solo content obviously just gets a single `SPEAKER_00` label that you can strip. The pipeline doesn't know whether the audio is monologue or multi-speaker ahead of time.

## Customising paths

If you install the deps anywhere other than the defaults, set these env vars:

| Variable | Purpose |
|---|---|
| `WITNESS_WHISPER_CLI` | Path to the `whisper-cli` binary |
| `WITNESS_WHISPER_MODEL` | Path to the Whisper ggml model |
| `WITNESS_SPEAKRS_CLI` | Path to the `speakrs-cli` binary |
| `WITNESS_ORT_LIB` | Path to the patched `libonnxruntime.so.1.24.2` |
| `WITNESS_ORT_LIB_DIR` / `WITNESS_MIGRAPHX_LIB_DIR` / `WITNESS_MIGRAPHX_EXTRA_LIB_DIR` | Dirs prepended to `LD_LIBRARY_PATH` so `speakrs-cli` finds the patched MIGraphX shared libs |
| `ORT_MIGRAPHX_MODEL_CACHE_PATH` | Where MIGraphX writes / reads the `.mxr` cache (honored directly by ORT's MIGraphX EP) |
| `WITNESS_AMD_CARD` | Override auto-detected AMD card (e.g. `card1`). Normally not needed. The script scans `/sys/class/drm/card*/device/vendor` for vendor `0x1002`. |

## Known limitations

- `--turbo` (large-v3-turbo model) crashes with a UTF-8 decode error during Whisper post-processing. Stay on the default large-v3 for now. Haven't had time to debug whether it's a model issue or a whisper.cpp issue on my install.
- No binary release. Witness ships as a single Python script. Packaging is possible but hasn't paid off relative to "clone and run" for me yet.
- Speaker labels are `SPEAKER_00`, `SPEAKER_01`, etc. No speaker re-identification across files. If you record the same two people on Monday and Wednesday, Monday's `SPEAKER_00` is Wednesday's `SPEAKER_01` with probability ~0.5.
- **iGPU + dGPU systems.** The AMD-card auto-detect grabs the first `/sys/class/drm/card*` whose vendor is `0x1002`. On a Ryzen APU + AMD dGPU box (e.g. a 5700G paired with a 9070), the iGPU is usually `card0` and the dGPU is `card1`, so the auto-detect locks onto the iGPU's sysfs and the VRAM preflight forces `--serial` mode even though the dGPU has plenty of free memory. Fix: `export WITNESS_AMD_CARD=card1` (or whichever card your dGPU is) before running.

## License

MIT, same as the parent repo.
