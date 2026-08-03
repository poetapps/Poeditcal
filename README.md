# Poet Audio

Poet Audio is a local-first macOS voice editor. Drop in a recording, edit it by crossing words out of a Parakeet transcript, apply a conservative adaptive voice chain, and export a lossless WAV with optional TXT, SRT, and WebVTT sidecars.

## Requirements

- Apple silicon Mac
- macOS 15 or newer
- Internet access on first transcription only, for the approximately 450 MB Parakeet model download

The English Parakeet TDT v2 Core ML model is cached under `~/Library/Application Support/FluidAudio/Models`. The DPDFNet2 denoiser ships inside the app and runs locally. Recordings and transcripts are not uploaded.

## Build and run

### Xcode

Open `PoetAudio.xcodeproj`, select the shared **PoetAudio** scheme and **My Mac**, then use:

- **⌘R** to build and run the app
- **⌘U** to run the XCTest suite
- **Product → Archive** for a release archive

Xcode resolves FluidAudio automatically through Swift Package Manager. The project targets Apple-silicon Macs and keeps `Package.swift` available for command-line and CI builds.

### Command line

```sh
swift run
```

To create a release app bundle:

```sh
./Scripts/package-app.sh
open .build/PoetAudio.app
```

The local bundle is ad-hoc signed. Public distribution will additionally require an Apple Developer ID signature and notarization.

## Tests

```sh
swift test --disable-sandbox
POET_RUN_TRANSCRIPTION_TEST=1 POET_TEST_RECORDING="$PWD/test_42.m4a" swift test --disable-sandbox --filter LocalTranscriptionIntegrationTests
POET_RUN_DENOISE_FIXTURE=1 swift test --disable-sandbox --filter DenoiseIntegrationTests
```

The regular suite covers retake suggestions, edit planning, synchronized subtitle remapping, adaptive voice processing, subtle breath attenuation, and a complete package export using `short_Test Recording.m4a`. The opt-in transcription test exercises the real cached Parakeet model and validates intentional repeated takes in `test_42.m4a`.

## Architecture

- **FluidAudio + Parakeet TDT v2/Core ML:** high-recall local English transcription with word timestamps and a one-time model download
- **DPDFNet2 48 kHz HR + sherpa-onnx:** bundled, full-band local speech enhancement that removes room and fan noise underneath speech
- **Transcript edit plan:** reversible word removals and configurable pause compaction
- **AVFoundation:** non-destructive preview, offline rendering, resampling, EQ, de-essing, conservative compression, subtle breath control, and optional mono downmix
- **Measured mastering:** gated K-weighted integrated-loudness analysis, selectable LUFS delivery presets, soft peak limiting, and iterative normalization
- **Post-polish quality check:** compares the dry and rendered audio for breath lift and retained dynamics, then automatically retries over-compressed material with a gentler compressor
- **Sidecar renderer:** edited transcript plus SRT/WebVTT timestamps remapped to the exported audio timeline

FluidAudio, Parakeet, sherpa-onnx, ONNX Runtime, and the DPDFNet model are covered in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
