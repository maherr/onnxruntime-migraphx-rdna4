# Third-Party Licenses

This project builds on the following open-source components. All licenses are
permissive and compatible with the MIT license used for our patches.

## Code Dependencies

### ONNX Runtime
- **License**: MIT
- **Copyright**: Microsoft Corporation
- **Source**: https://github.com/microsoft/onnxruntime
- **Usage**: inference runtime; our 2 RDNA 4 enablement patches are applied on top

### AMDMIGraphX
- **License**: MIT
- **Copyright**: Advanced Micro Devices, Inc.
- **Source**: https://github.com/ROCm/AMDMIGraphX
- **Usage**: MIGraphX Execution Provider backend; our 6 RDNA 4 enablement patches are applied on top

### speakrs
- **License**: Apache-2.0
- **Copyright**: Praveen Perera
- **Source**: https://github.com/avencera/speakrs
- **Usage**: speaker diarization pipeline (segmentation, embedding, clustering); our fork adds MIGraphX execution mode and accuracy optimizations

## Model Weights

Model weights are NOT bundled in this repository. They are downloaded at
runtime from HuggingFace via speakrs' built-in ModelManager (from
[avencera/speakrs-models](https://huggingface.co/avencera/speakrs-models)).
Users must accept HuggingFace's terms for gated models.

### pyannote segmentation-3.0
- **License**: MIT
- **Copyright**: Herve Bredin / IRIT / pyannote.audio
- **Source**: https://huggingface.co/pyannote/segmentation-3.0
- **Usage**: speaker segmentation model (speech activity detection + speaker change detection)
- **Access**: gated on HuggingFace; users must accept the form to download
- **Note**: pyannote.ai offers premium commercial models at https://www.pyannote.ai

### WeSpeaker ResNet34 (VoxCeleb)
- **License**: CC-BY-4.0 (Creative Commons Attribution 4.0 International)
- **Copyright**: WeNet / VoxCeleb authors
- **Source**: https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM
- **Training data**: VoxCeleb (CC-BY-4.0, https://mm.kaist.ac.kr/datasets/voxceleb/)
- **Usage**: speaker embedding extraction
- **Attribution requirement**: CC-BY-4.0 requires attribution. See below.

## Required Attribution (CC-BY-4.0)

The WeSpeaker ResNet34 embedding model is trained on the VoxCeleb dataset,
licensed under CC-BY-4.0. Per the license terms, we acknowledge:

> VoxCeleb: A Large-scale Speaker Verification Dataset.
> A. Nagrani, J. S. Chung, A. Zisserman.
> INTERSPEECH, 2017.
>
> VoxCeleb2: Deep Speaker Recognition.
> J. S. Chung, A. Nagrani, A. Zisserman.
> INTERSPEECH, 2018.
>
> WeSpeaker: A Research and Production oriented Speaker Embedding Learning Toolkit.
> https://github.com/wenet-e2e/wespeaker

Any redistribution of this project or derivative works that include or invoke
the WeSpeaker model must include this attribution.
