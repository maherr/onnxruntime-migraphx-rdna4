# Precompiled MIGraphX model cache (gfx1201)

One pre-compiled artifact:

```
20c00-7b5fe8349483435c-bfda5b8c4aa930d4-3415bab9e424192.mxr    ~27 MB
```

This is the WeSpeaker ResNet34 embedding model, compiled by MIGraphX against the exact versions I used for the VoxConverse numbers in the blog.

## What it pins

| Component | Value |
|---|---|
| GPU target | `gfx1201` (RDNA 4, Navi 48, RX 9070) |
| MIGraphX | `rocm-6.4.2` branch @ `db302ae` (lib SONAME 2.12.0) |
| ONNX Runtime | `v1.24.2` @ `058787c` |
| ROCm | 6.4.4 (Fedora 43, `rocm-core-6.4.4-1.fc43`) |
| Model | WeSpeaker ResNet34 (`wespeaker-voxceleb-resnet34-LM`) |

The `.mxr` filename is content-addressed. MIGraphX hashes over (ORT version, MIGraphX version, driver/runtime, model SHA, target arch) and encodes the result in the filename. At runtime, ORT's MIGraphX EP looks for `$ORT_MIGRAPHX_MODEL_CACHE_PATH/<hash>.mxr`. If the hash matches your environment, compile is skipped.

Numbers I measured on the dev box:

- First run, cold (no cache): **~45.7 s**
- First run, warm (this artifact applies): **~17.5 s**
- So a ~28-second saving when the hash matches, which is within 1.4% of warm steady-state.

## How to use

If you ran `bash build.sh` in the repo root, the artifact is already copied into `~/.cache/migraphx-compiled/` for you. Nothing to do.

If you already have a compatible ORT + MIGraphX + ROCm + driver stack and just want to drop the cache in manually:

```sh
mkdir -p ~/.cache/migraphx-compiled
cp artifacts/precompiled-mxr-gfx1201/*.mxr ~/.cache/migraphx-compiled/
```

## When it will not help you

If any of (ORT build, MIGraphX build, ROCm/driver version, model version, GPU target) differ from the pinned values above, the filename hash won't match. MIGraphX re-compiles on first run (cold cost, ~45 s) and writes a new `.mxr` with a different hash. This is harmless; the old `.mxr` just sits unused.

Most likely cases for a miss:

- Different ROCm point release (6.4.3, 6.4.5, 7.x, etc.)
- You modified any of the ORT or MIGraphX patches
- You're targeting a different ISA (`gfx1200`, `gfx1100`, etc.)
- You're on Ubuntu / Arch / NixOS with a different libstdc++ / clang ABI

## Regenerate

Run any `witness` job against any WAV file. MIGraphX cold-compiles into its cache, and the resulting `.mxr` filename is the new content-addressed hash. Copy it back here to update the shipped artifact.
