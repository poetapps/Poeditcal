# Poet Audio

Poet Audio is a local-first macOS voice editor. Drop in a recording, edit it by crossing words out of a Parakeet transcript, apply a conservative adaptive voice chain, and export a lossless WAV with optional TXT, SRT, and WebVTT sidecars.

## Requirements

- Apple silicon Mac
- macOS 15 or newer
- Internet access for optional local model downloads

The English Parakeet TDT v2 Core ML model is cached under `~/Library/Application Support/FluidAudio/Models`. Poet offers the 10.6 MB DPDFNet2 noise-reduction model as a verified one-time download and stores it under `~/Library/Application Support/Poet Audio/Models`. Noise reduction stays disabled until that model is installed. Recordings and transcripts are not uploaded.

## Build and run

### Xcode

Open `PoetAudio.xcodeproj`, select the shared **PoetAudio** scheme and **My Mac**, then use:

- **⌘R** to build and run the app
- **⌘U** to run the XCTest suite
- **Product → Archive** for a release archive

Xcode resolves FluidAudio and Sparkle automatically through Swift Package Manager. The project targets Apple-silicon Macs and keeps `Package.swift` available for command-line and CI builds.

### Command line

```sh
swift run
```

To create a release app bundle:

```sh
./Scripts/package-app.sh
open .build/PoetAudio.app
```

The local bundle is ad-hoc signed. Public releases are Developer ID signed, Apple-notarized, distributed as a DMG, and updated through Sparkle. See [RELEASING.md](RELEASING.md) for the release workflow and one-time credential setup.

## Tests

```sh
./Scripts/test.sh
```

The wrapper places Sparkle's binary framework on SwiftPM's test runtime path before launching the suite. Tests cover retake suggestions, edit planning, synchronized subtitle remapping, adaptive voice processing, subtle breath attenuation, audio rendering, and project persistence. Tests that require local audio fixtures or downloaded models are skipped automatically when those resources are unavailable.

## Architecture

- **FluidAudio + Parakeet TDT v2/Core ML:** high-recall local English transcription with word timestamps and a one-time model download
- **DPDFNet2 48 kHz HR + sherpa-onnx:** optional, downloadable full-band local speech enhancement that removes room and fan noise underneath speech
- **Transcript edit plan:** reversible word removals and configurable pause compaction
- **AVFoundation:** non-destructive preview, offline rendering, resampling, EQ, de-essing, conservative compression, subtle breath control, and optional mono downmix
- **Measured mastering:** gated K-weighted integrated-loudness analysis, selectable LUFS delivery presets, soft peak limiting, and iterative normalization
- **Post-polish quality check:** compares the dry and rendered audio for breath lift and retained dynamics, then automatically retries over-compressed material with a gentler compressor
- **Sidecar renderer:** edited transcript plus SRT/WebVTT timestamps remapped to the exported audio timeline

FluidAudio, Parakeet, sherpa-onnx, ONNX Runtime, and the DPDFNet model are covered in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
