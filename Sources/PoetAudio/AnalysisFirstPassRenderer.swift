import AVFoundation
import Foundation
import os

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
              candidate.length > 0,
              targetFormat.commonFormat == .pcmFormatFloat32,
              !targetFormat.isInterleaved else {
            throw AudioRenderError.unsupportedPCMFormat
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let targetFrames = source.length
        if candidate.processingFormat == targetFormat {
            try copy(
                candidate: candidate,
                output: output,
                format: targetFormat,
                targetFrames: targetFrames
            )
        } else {
            try convert(
                candidate: candidate,
                output: output,
                targetFormat: targetFormat,
                targetFrames: targetFrames
            )
        }
        try pad(output: output, format: targetFormat, to: targetFrames)

        let sourceDuration = Double(source.length) / targetFormat.sampleRate
        let outputDuration = Double(output.length) / targetFormat.sampleRate
        return Alignment(sourceDuration: sourceDuration, outputDuration: outputDuration)
    }

    private static func copy(
        candidate: AVAudioFile,
        output: AVAudioFile,
        format: AVAudioFormat,
        targetFrames: AVAudioFramePosition
    ) throws {
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioRenderError.unsupportedPCMFormat
        }
        while candidate.framePosition < candidate.length, output.length < targetFrames {
            try Task.checkCancellation()
            let remaining = targetFrames - output.length
            let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
            try candidate.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    private static func convert(
        candidate: AVAudioFile,
        output: AVAudioFile,
        targetFormat: AVAudioFormat,
        targetFrames: AVAudioFramePosition
    ) throws {
        guard let converter = AVAudioConverter(from: candidate.processingFormat, to: targetFormat) else {
            throw AudioRenderError.unsupportedPCMFormat
        }
        let inputCapacity: AVAudioFrameCount = 16_384
        let outputCapacity: AVAudioFrameCount = 16_384
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: candidate.processingFormat,
            frameCapacity: inputCapacity
        ), let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { throw AudioRenderError.unsupportedPCMFormat }

        nonisolated(unsafe) let capturedInput = inputBuffer
        let reachedEnd = OSAllocatedUnfairLock(initialState: false)
        let readError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if reachedEnd.withLock({ $0 }) {
                status.pointee = .endOfStream
                return nil
            }
            do {
                let remaining = max(0, candidate.length - candidate.framePosition)
                let count = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remaining))
                if count > 0 {
                    try candidate.read(into: capturedInput, frameCount: count)
                } else {
                    capturedInput.frameLength = 0
                }
            } catch {
                readError.withLock { $0 = error }
                capturedInput.frameLength = 0
            }
            guard capturedInput.frameLength > 0 else {
                reachedEnd.withLock { $0 = true }
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return capturedInput
        }

        while output.length < targetFrames {
            try Task.checkCancellation()
            let remaining = targetFrames - output.length
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError,
                withInputFrom: inputBlock
            )
            if let readError = readError.withLock({ $0 }) { throw readError }
            guard status != .error, conversionError == nil else {
                throw conversionError ?? AudioRenderError.renderFailed
            }
            if outputBuffer.frameLength > 0 {
                if AVAudioFramePosition(outputBuffer.frameLength) > remaining {
                    outputBuffer.frameLength = AVAudioFrameCount(remaining)
                }
                try output.write(from: outputBuffer)
            }
            if status == .endOfStream { break }
        }
    }

    private static func pad(
        output: AVAudioFile,
        format: AVAudioFormat,
        to targetFrames: AVAudioFramePosition
    ) throws {
        let capacity: AVAudioFrameCount = 16_384
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channels = silence.floatChannelData else {
            throw AudioRenderError.unsupportedPCMFormat
        }
        for channel in 0..<Int(format.channelCount) {
            channels[channel].initialize(repeating: 0, count: Int(capacity))
        }
        while output.length < targetFrames {
            try Task.checkCancellation()
            silence.frameLength = AVAudioFrameCount(
                min(AVAudioFramePosition(capacity), targetFrames - output.length)
            )
            try output.write(from: silence)
        }
    }
}
