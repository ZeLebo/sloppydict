# Third-party notices

SloppyDict uses [FluidAudio 0.18.0](https://github.com/FluidInference/FluidAudio/tree/v0.18.0), distributed under the [Apache License 2.0](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/LICENSE). Its exact source revision is recorded in `Package.resolved`. The TTS, diarization and NeMo text processing traits are disabled.

The separately downloaded [Parakeet Ultra Core ML model](https://huggingface.co/FluidInference/parakeet-ultra-coreml) is converted by FluidInference from [Moondream Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), a post-trained version of [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). The upstream weights are licensed under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/). Attribution: Moondream, NVIDIA and FluidInference. SloppyDict does not modify or bundle the model weights.

The model download is a separate action. Redistributed binaries must retain applicable dependency licenses and notices. The dependency checkout contains its full license; see the linked upstream repositories for additional notices.

Pinned Core ML model revision: `95eaa59a39d4394f047a4dc5cce480388a60d1b6`.
