import AVFoundation
import Foundation

struct AnalysisFirstPassReport: Sendable, Equatable {
    let usedNoiseReduction: Bool
    let sourceDuration: TimeInterval
    let outputDuration: TimeInterval
    let frameAlignmentError: TimeInterval
}

/// Produces the conservative, full-length listening/transcription reference.
/// This pass deliberately avoids creative EQ, compression, de-essing, breath
/// control, and every timeline edit. Final polish is always rendered later from
/// the immutable source recording.
enum AnalysisFirstPassRenderer {
    static func render(sourceURL: URL, destinationURL: URL) throws -> AnalysisFirstPassReport {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetAnalysisPass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let cleaned = folder.appendingPathComponent("cleaned.wav")
        let leveled = folder.appendingPathComponent("leveled.wav")
        let usedNoiseReduction = DenoiseModelStore.installedModelIsValid()

        if usedNoiseReduction {
            try AIDenoiser.render(
                sourceURL: sourceURL,
                destinationURL: cleaned,
                intensity: PolishIntensity.balanced.amount
            )
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: cleaned)
        }

        // -18 LUFS is intentionally gentler than the delivery master. It gives
        // the recognizer a consistent signal without turning this cache into a
        // creative or final polish pass.
        _ = try LoudnessNormalizer.normalize(
            sourceURL: cleaned,
            destinationURL: leveled,
            preset: .audiobook
        )
        let alignment = try TimelineAlignedAudioRenderer.conform(
            candidateURL: leveled,
            toSourceURL: sourceURL,
            destinationURL: destinationURL
        )
        return AnalysisFirstPassReport(
            usedNoiseReduction: usedNoiseReduction,
            sourceDuration: alignment.sourceDuration,
            outputDuration: alignment.outputDuration,
            frameAlignmentError: abs(alignment.outputDuration - alignment.sourceDuration)
        )
    }
}

enum TimelineAlignedAudioRenderer {
    struct Alignment: Sendable, Equatable {
        let sourceDuration: TimeInterval
        let outputDuration: TimeInterval
    }

    /// Conforms a full-length processed candidate back onto the source sample
    /// grid. Padding or truncating by the final fractional resampling frame keeps
    /// A/B playback and transcript timestamps stable.
    static func conform(
        candidateURL: URL,
        toSourceURL sourceURL: URL,
        destinationURL: URL
    ) throws -> Alignment {
        let source = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let candidate = try AVAudioFile(
            forReading: candidateURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let targetFormat = source.processingFormat
        guard source.length > 0,
              source.length <= AVAudioFramePosition(UInt32.max),
              candidate.length > 0,
              candidate.length <= AVAudioFramePosition(UInt32.max),
              let input = AVAudioPCMBuffer(
                pcmFormat: candidate.processingFormat,
                frameCapacity: AVAudioFrameCount(candidate.length)
              ) else {
            throw AudioRenderError.unsupportedPCMFormat
        }
        try candidate.read(into: input)

        let targetFrames = AVAudioFrameCount(source.length)
        guard let aligned = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrames),
              let outputChannels = aligned.floatChannelData else {
            throw AudioRenderError.unsupportedPCMFormat
        }

        if candidate.processingFormat == targetFormat {
            let copiedFrames = min(Int(input.frameLength), Int(targetFrames))
            guard let inputChannels = input.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            for channel in 0..<Int(targetFormat.channelCount) {
                outputChannels[channel].update(from: inputChannels[channel], count: copiedFrames)
            }
            aligned.frameLength = AVAudioFrameCount(copiedFrames)
        } else {
            guard let converter = AVAudioConverter(from: candidate.processingFormat, to: targetFormat) else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: aligned, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error else {
                throw conversionError ?? AudioRenderError.renderFailed
            }
        }

        let producedFrames = Int(aligned.frameLength)
        if producedFrames < Int(targetFrames) {
            for channel in 0..<Int(targetFormat.channelCount) {
                outputChannels[channel].advanced(by: producedFrames)
                    .initialize(repeating: 0, count: Int(targetFrames) - producedFrames)
            }
        }
        aligned.frameLength = targetFrames

        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try output.write(from: aligned)

        let sourceDuration = Double(source.length) / targetFormat.sampleRate
        let outputDuration = Double(output.length) / targetFormat.sampleRate
        return Alignment(sourceDuration: sourceDuration, outputDuration: outputDuration)
    }
}
