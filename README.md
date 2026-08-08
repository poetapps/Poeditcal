# Poeditcal

Poeditcal is a local-first macOS audio and talking-head video editor. Drop in a recording or single-camera video, edit it by crossing words out of a Parakeet transcript, apply a conservative adaptive voice chain, and export finished media or a reversible Premiere Pro/DaVinci Resolve timeline with optional TXT, SRT, and WebVTT sidecars.

## Requirements

- Apple silicon Mac
- macOS 15 or newer
- Internet access for optional local model downloads

The English Parakeet TDT v2 Core ML model is cached under `~/Library/Application Support/FluidAudio/Models`. Poeditcal offers the 10.6 MB DPDFNet2 noise-reduction model as a verified one-time download and stores it under `~/Library/Application Support/Poet Audio/Models`. That legacy support-directory name is intentionally retained so existing installations keep their downloaded models. Noise reduction stays disabled until that model is installed. Recordings and transcripts are not uploaded.

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
open .build/Poeditcal.app
```

The local bundle is ad-hoc signed. Public releases are Developer ID signed, Apple-notarized, distributed as a DMG, and updated through Sparkle. See [RELEASING.md](RELEASING.md) for the release workflow and one-time credential setup.

## Tests

```sh
./Scripts/test.sh
```

The wrapper places Sparkle's binary framework on SwiftPM's test runtime path before launching the suite. Tests cover retake suggestions, edit planning, synchronized subtitle remapping, adaptive voice processing, subtle breath attenuation, audio and video rendering, editable timeline interchange, and project persistence. Tests that require local audio fixtures or downloaded models are skipped automatically when those resources are unavailable.

## Architecture

- **FluidAudio + Parakeet TDT v2/Core ML:** high-recall local English transcription with word timestamps and a one-time model download
- **DPDFNet2 48 kHz HR + sherpa-onnx:** optional, downloadable full-band local speech enhancement that removes room and fan noise underneath speech
- **Transcript edit plan:** reversible word removals and configurable pause compaction
- **Video source workflow:** MOV/MP4/M4V inspection, full-length audio extraction, synchronized cut preview, and optional finished MOV rendering
- **Editable timeline interchange:** Final Cut Pro 7 XML for Premiere Pro and OpenTimelineIO for DaVinci Resolve; both reference full-length source video and polished audio so every edit edge remains extendable
- **AVFoundation:** non-destructive preview, offline audio/video rendering, resampling, EQ, de-essing, conservative compression, subtle breath control, and optional mono downmix
- **Measured mastering:** gated K-weighted integrated-loudness analysis, selectable LUFS delivery presets, soft peak limiting, and iterative normalization
- **Post-polish quality check:** compares the dry and rendered audio for breath lift and retained dynamics, then automatically retries over-compressed material with a gentler compressor
- **Sidecar renderer:** edited transcript plus SRT/WebVTT timestamps remapped to the exported audio timeline

FluidAudio, Parakeet, sherpa-onnx, ONNX Runtime, and the DPDFNet model are covered in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
