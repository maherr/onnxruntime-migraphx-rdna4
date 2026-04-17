# Witness — speaker-aware transcription pipeline

Whisper (via whisper.cpp on Vulkan) + speaker diarization (via speakrs on ROCm/MIGraphX) running concurrently on the same AMD GPU. Two independent driver stacks, one physical card.

- **~20s wall time for a 3-minute call** on an RX 9070 (parallel pipeline).
- **15× realtime diarization-only; ~20× realtime for the full pipeline** on long files.
- **10.65% strict DER / 7.85% under VoxConverse paper convention** on full VoxConverse test (232 files, 43.5 h).

## Requirements

| Dependency   | Source | Role |
|--------------|--------|------|
| AMDMIGraphX + ONNX Runtime (patched) | This repo — run `build.sh` in the parent dir | GPU diarization backend |
| `speakrs-cli` | `maherr/speakrs` fork — build with `cargo build --release` | Rust diarization binary (MIGraphX execution mode) |
| `whisper-cli` | `ggerganov/whisper.cpp` with Vulkan support | Transcription binary |
| Whisper large-v3 ggml model | Hugging Face `ggerganov/whisper.cpp` repo | Model weights (~2.9 GB) |
| `ffmpeg`     | Distro package | Internal audio format conversion |
| Python 3.10+ | Distro package | Script runtime |

Default install paths (matching what `build.sh` in the parent repo produces):

- Whisper model: `~/.local/share/voxtype/models/ggml-large-v3.bin`
- `whisper-cli`: `~/.local/share/whisper-cpp/src/build/bin/whisper-cli`
- `speakrs-cli`: `~/.local/bin/speakrs-cli`
- ORT library: `~/.local/share/gpu-diarization-build/ort-rocm-install/lib/libonnxruntime.so.1.24.2`
- MIGraphX compiled-model cache: `~/.cache/migraphx-compiled/`

## Usage

```sh
witness input.m4a                                    # default: auto language, parallel pipeline
witness input.m4a --output transcript.md             # custom output path
witness input.m4a --language fr                      # force French (skips auto-detect)
witness input.m4a --serial                           # run Whisper and speakrs sequentially (low-VRAM fallback)
```

The script preflight-checks free VRAM and falls back to serial mode automatically if less than 4 GiB is free at launch.

## Output format

Markdown with speaker-labeled segments and timestamps:

```markdown
# Transcript: example.m4a

**Duration:** 180.3s
**Speakers:** 2 (detected)
**Language:** en (auto-detected)
**Pipeline:** parallel | transcription 11.8s | diarization 14.2s | wall 20.0s

---

[00:00:00 → 00:00:12] SPEAKER_00: Alright, let's get started...
[00:00:12 → 00:00:21] SPEAKER_01: Sure. So what I wanted to ask is...
```

For solo content, the `SPEAKER_00` label is just strippable noise.

## Known limitations

- **`--turbo` flag crashes** with a UTF-8 decode error in Whisper post-processing. Stay on the default large-v3 model.
- **Long cold-start** on first run (~86s) while MIGraphX compiles the embedding graph. Every subsequent call reuses the cached `.mxr` artifact (~17s warm). Precompiled `.mxr` bundles for gfx1201 are in the parent project's `precompiled/` directory and cut first-run to 17s.
- **Not a packaged binary yet** — ships as a single Python script. Package-as-binary may come in a future release if demand signals it.

## License

MIT, same as the parent repo.
