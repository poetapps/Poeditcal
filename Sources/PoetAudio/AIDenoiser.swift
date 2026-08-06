import AVFoundation
import Dispatch
import Foundation
import PoetDenoise
import os

enum AIDenoiserError: LocalizedError {
    case modelUnavailable
    case couldNotCreateEngine
    case unsupportedRecording
    case conversionFailed(String)
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            "Poet’s AI noise reduction isn’t installed yet."
        case .couldNotCreateEngine:
            "Poet couldn’t start its local AI noise-removal engine."
        case .unsupportedRecording:
            "This recording is too large or uses an unsupported audio layout."
        case .conversionFailed(let detail):
            "Poet couldn’t prepare this recording for noise removal. \(detail)"
        case .processingFailed:
            "AI noise removal couldn’t finish this recording."
        }
    }
}

struct AIDenoiseReport: Sendable {
    let modelName: String
    let processingTime: TimeInterval
    let inputSampleRate: Double
    let outputSampleRate: Double
    let channelCount: Int
}

/// Full-band, local speech enhancement backed by DPDFNet2 and sherpa-onnx.
///
/// The model works at 48 kHz. Audio is decoded and resampled once, each channel
/// is enhanced independently, and the original channel layout is preserved.
enum AIDenoiser {
    static let modelName = "DPDFNet2 48 kHz HR"
    static let modelFileName = "dpdfnet2_48khz_hr"
    static let modelSampleRate = 48_000.0
    private static let chunkDuration: TimeInterval = 60
    private static let chunkingThreshold: TimeInterval = 90
    private static let chunkContextDuration: TimeInterval = 1
    private static let seamCrossfadeDuration: TimeInterval = 0.12
    private static let maximumConcurrentChunks = 2

    private struct Chunk: Sendable {
        let coreStart: AVAudioFramePosition
        let coreEnd: AVAudioFramePosition
        let paddedStart: AVAudioFramePosition
        let paddedEnd: AVAudioFramePosition
        let inputURL: URL
        let outputURL: URL
    }

    @discardableResult
    static func render(
        sourceURL: URL,
        destinationURL: URL,
        modelURL suppliedModelURL: URL? = nil,
        intensity: Double = 1
    ) throws -> AIDenoiseReport {
        let started = CFAbsoluteTimeGetCurrent()
        let source = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputRate = source.processingFormat.sampleRate
        let duration = Double(source.length) / inputRate
        if duration > chunkingThreshold {
            return try renderChunked(
                sourceURL: sourceURL,
                source: source,
                destinationURL: destinationURL,
                modelURL: suppliedModelURL,
                intensity: intensity,
                started: started
            )
        }
        let prepared = try prepare(source)
        guard let channels = prepared.floatChannelData,
              prepared.frameLength > 0,
              prepared.format.channelCount > 0,
              prepared.frameLength <= AVAudioFrameCount(Int32.max) else {
            throw AIDenoiserError.unsupportedRecording
        }

        guard let modelURL = suppliedModelURL ?? installedModelURL() else {
            throw AIDenoiserError.modelUnavailable
        }

        var config = SherpaOnnxOfflineSpeechDenoiserConfig()
        let denoiser: OpaquePointer? = modelURL.path.withCString { modelPath in
            "cpu".withCString { provider in
                config.model.dpdfnet.model = modelPath
                config.model.num_threads = 2
                config.model.debug = 0
                config.model.provider = provider
                return SherpaOnnxCreateOfflineSpeechDenoiser(&config)
            }
        }
        guard let denoiser else { throw AIDenoiserError.couldNotCreateEngine }
        defer { SherpaOnnxDestroyOfflineSpeechDenoiser(denoiser) }

        let expectedRate = Double(SherpaOnnxOfflineSpeechDenoiserGetSampleRate(denoiser))
        guard abs(expectedRate - modelSampleRate) < 1 else {
            throw AIDenoiserError.processingFailed
        }

        let inputCount = Int(prepared.frameLength)
        var enhancedChannels: [[Float]] = []
        enhancedChannels.reserveCapacity(Int(prepared.format.channelCount))

        for channelIndex in 0..<Int(prepared.format.channelCount) {
            let denoised = SherpaOnnxOfflineSpeechDenoiserRun(
                denoiser,
                channels[channelIndex],
                Int32(inputCount),
                Int32(modelSampleRate)
            )
            guard let denoised else { throw AIDenoiserError.processingFailed }
            defer { SherpaOnnxDestroyDenoisedAudio(denoised) }

            let count = Int(denoised.pointee.n)
            guard count > 0, let samples = denoised.pointee.samples else {
                throw AIDenoiserError.processingFailed
            }
            enhancedChannels.append(Array(UnsafeBufferPointer(start: samples, count: count)))
        }

        guard let outputCount = enhancedChannels.map(\.count).min(),
              outputCount > 0,
              outputCount <= Int(UInt32.max),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: modelSampleRate,
                channels: prepared.format.channelCount,
                interleaved: false
              ),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(outputCount)
              ),
              let outputChannels = outputBuffer.floatChannelData else {
            throw AIDenoiserError.unsupportedRecording
        }

        outputBuffer.frameLength = AVAudioFrameCount(outputCount)
        let wetMix = Float(min(max(intensity, 0), 1))
        for channelIndex in 0..<enhancedChannels.count {
            let enhanced = enhancedChannels[channelIndex]
            let dry = channels[channelIndex]
            for frame in 0..<outputCount {
                outputChannels[channelIndex][frame] = dry[frame] + (enhanced[frame] - dry[frame]) * wetMix
            }
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try output.write(from: outputBuffer)

        return AIDenoiseReport(
            modelName: modelName,
            processingTime: CFAbsoluteTimeGetCurrent() - started,
            inputSampleRate: inputRate,
            outputSampleRate: modelSampleRate,
            channelCount: enhancedChannels.count
        )
    }

    private static func renderChunked(
        sourceURL: URL,
        source: AVAudioFile,
        destinationURL: URL,
        modelURL: URL?,
        intensity: Double,
        started: CFAbsoluteTime
    ) throws -> AIDenoiseReport {
        let format = source.processingFormat
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetDenoiseChunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let boundaries = try quietBoundaries(in: sourceURL, length: source.length, format: format)
        let contextFrames = AVAudioFramePosition(chunkContextDuration * format.sampleRate)
        let chunks = zip(boundaries, boundaries.dropFirst()).enumerated().map { index, pair in
            Chunk(
                coreStart: pair.0,
                coreEnd: pair.1,
                paddedStart: max(0, pair.0 - contextFrames),
                paddedEnd: min(source.length, pair.1 + contextFrames),
                inputURL: folder.appendingPathComponent("chunk-\(index)-input.wav"),
                outputURL: folder.appendingPathComponent("chunk-\(index)-output.wav")
            )
        }
        guard !chunks.isEmpty else { throw AIDenoiserError.processingFailed }

        let firstError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let workerCount = min(maximumConcurrentChunks, chunks.count)
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            for index in stride(from: worker, to: chunks.count, by: workerCount) {
                if firstError.withLock({ $0 != nil }) { return }
                do {
                    let chunk = chunks[index]
                    try extract(
                        sourceURL: sourceURL,
                        destinationURL: chunk.inputURL,
                        startFrame: chunk.paddedStart,
                        endFrame: chunk.paddedEnd
                    )
                    _ = try render(
                        sourceURL: chunk.inputURL,
                        destinationURL: chunk.outputURL,
                        modelURL: modelURL,
                        intensity: intensity
                    )
                    try? FileManager.default.removeItem(at: chunk.inputURL)
                } catch {
                    firstError.withLock { stored in
                        if stored == nil { stored = error }
                    }
                    return
                }
            }
        }
        if let error = firstError.withLock({ $0 }) { throw error }

        try stitch(
            chunks: chunks,
            sourceFormat: format,
            sourceLength: source.length,
            destinationURL: destinationURL
        )
        return AIDenoiseReport(
            modelName: modelName,
            processingTime: CFAbsoluteTimeGetCurrent() - started,
            inputSampleRate: format.sampleRate,
            outputSampleRate: modelSampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    private static func quietBoundaries(
        in sourceURL: URL,
        length: AVAudioFramePosition,
        format: AVAudioFormat
    ) throws -> [AVAudioFramePosition] {
        let nominalFrames = AVAudioFramePosition(chunkDuration * format.sampleRate)
        guard length > nominalFrames else { return [0, length] }
        let searchRadius = AVAudioFramePosition(5 * format.sampleRate)
        let windowFrames = max(1, AVAudioFramePosition(0.02 * format.sampleRate))
        var boundaries: [AVAudioFramePosition] = [0]
        var target = nominalFrames

        while target < length {
            let searchStart = max(boundaries.last! + nominalFrames / 2, target - searchRadius)
            let searchEnd = min(length, target + searchRadius)
            let count = searchEnd - searchStart
            guard count > windowFrames, count <= AVAudioFramePosition(UInt32.max) else { break }
            let file = try AVAudioFile(
                forReading: sourceURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            file.framePosition = searchStart
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(count)
            ), let channels = buffer.floatChannelData else {
                throw AIDenoiserError.unsupportedRecording
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let available = Int(buffer.frameLength)
            var bestOffset = Int(min(max(target - searchStart, 0), AVAudioFramePosition(available - 1)))
            var bestEnergy = Double.greatestFiniteMagnitude
            var offset = 0
            while offset + Int(windowFrames) <= available {
                var energy = 0.0
                for frame in offset..<(offset + Int(windowFrames)) {
                    var mono = 0.0
                    for channel in 0..<Int(format.channelCount) {
                        mono += Double(channels[channel][frame])
                    }
                    mono /= Double(max(Int(format.channelCount), 1))
                    energy += mono * mono
                }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestOffset = offset + Int(windowFrames / 2)
                }
                offset += Int(windowFrames)
            }
            let boundary = min(length, searchStart + AVAudioFramePosition(bestOffset))
            guard boundary > boundaries.last! else { break }
            boundaries.append(boundary)
            target = boundary + nominalFrames
        }
        if boundaries.last != length { boundaries.append(length) }
        return boundaries
    }

    private static func extract(
        sourceURL: URL,
        destinationURL: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) throws {
        let input = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        input.framePosition = startFrame
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AIDenoiserError.unsupportedRecording
        }
        while input.framePosition < endFrame {
            let count = AVAudioFrameCount(
                min(AVAudioFramePosition(capacity), endFrame - input.framePosition)
            )
            try input.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    private static func stitch(
        chunks: [Chunk],
        sourceFormat: AVAudioFormat,
        sourceLength: AVAudioFramePosition,
        destinationURL: URL
    ) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: modelSampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ) else { throw AIDenoiserError.unsupportedRecording }
        let ratio = modelSampleRate / sourceFormat.sampleRate
        let targetLength = AVAudioFramePosition((Double(sourceLength) * ratio).rounded())
        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let fadeFrames = AVAudioFramePosition(seamCrossfadeDuration * modelSampleRate)
        var cursor: AVAudioFramePosition = 0

        for index in 1..<chunks.count {
            let seam = AVAudioFramePosition((Double(chunks[index].coreStart) * ratio).rounded())
            let blendStart = max(cursor, seam - fadeFrames)
            let blendEnd = min(targetLength, seam + fadeFrames)
            try writeRange(
                chunk: chunks[index - 1],
                globalStart: cursor,
                globalEnd: blendStart,
                ratio: ratio,
                output: output,
                format: outputFormat
            )
            try writeBlend(
                left: chunks[index - 1],
                right: chunks[index],
                globalStart: blendStart,
                globalEnd: blendEnd,
                ratio: ratio,
                output: output,
                format: outputFormat
            )
            cursor = blendEnd
        }
        try writeRange(
            chunk: chunks[chunks.count - 1],
            globalStart: cursor,
            globalEnd: targetLength,
            ratio: ratio,
            output: output,
            format: outputFormat
        )
    }

    private static func writeRange(
        chunk: Chunk,
        globalStart: AVAudioFramePosition,
        globalEnd: AVAudioFramePosition,
        ratio: Double,
        output: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        guard globalEnd > globalStart else { return }
        let input = try AVAudioFile(
            forReading: chunk.outputURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let paddedStart = AVAudioFramePosition((Double(chunk.paddedStart) * ratio).rounded())
        input.framePosition = max(0, globalStart - paddedStart)
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AIDenoiserError.unsupportedRecording
        }
        var remaining = globalEnd - globalStart
        var lastSamples: [Float]?
        while remaining > 0 {
            let available = max(0, input.length - input.framePosition)
            guard available > 0 else {
                try writeConstant(
                    frames: remaining,
                    samples: lastSamples,
                    output: output,
                    format: format
                )
                return
            }
            let count = AVAudioFrameCount(
                min(AVAudioFramePosition(capacity), min(remaining, available))
            )
            try input.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else {
                try writeConstant(
                    frames: remaining,
                    samples: lastSamples,
                    output: output,
                    format: format
                )
                return
            }
            if let channels = buffer.floatChannelData {
                let lastFrame = Int(buffer.frameLength) - 1
                lastSamples = (0..<Int(format.channelCount)).map { channels[$0][lastFrame] }
            }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private static func writeConstant(
        frames: AVAudioFramePosition,
        samples: [Float]?,
        output: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channels = buffer.floatChannelData else {
            throw AIDenoiserError.unsupportedRecording
        }
        for channel in 0..<Int(format.channelCount) {
            let sample = samples.flatMap { channel < $0.count ? $0[channel] : nil } ?? 0
            channels[channel].initialize(repeating: sample, count: Int(capacity))
        }
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private static func writeBlend(
        left: Chunk,
        right: Chunk,
        globalStart: AVAudioFramePosition,
        globalEnd: AVAudioFramePosition,
        ratio: Double,
        output: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        guard globalEnd > globalStart else { return }
        let leftFile = try AVAudioFile(forReading: left.outputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rightFile = try AVAudioFile(forReading: right.outputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let leftStart = AVAudioFramePosition((Double(left.paddedStart) * ratio).rounded())
        let rightStart = AVAudioFramePosition((Double(right.paddedStart) * ratio).rounded())
        leftFile.framePosition = max(0, globalStart - leftStart)
        rightFile.framePosition = max(0, globalStart - rightStart)
        let total = globalEnd - globalStart
        let capacity: AVAudioFrameCount = 16_384
        guard let leftBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let rightBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let blended = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AIDenoiserError.unsupportedRecording
        }
        var written: AVAudioFramePosition = 0
        while written < total {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), total - written))
            try leftFile.read(into: leftBuffer, frameCount: count)
            try rightFile.read(into: rightBuffer, frameCount: count)
            guard leftBuffer.frameLength == count,
                  rightBuffer.frameLength == count,
                  let leftChannels = leftBuffer.floatChannelData,
                  let rightChannels = rightBuffer.floatChannelData,
                  let outputChannels = blended.floatChannelData else {
                throw AIDenoiserError.processingFailed
            }
            blended.frameLength = count
            for frame in 0..<Int(count) {
                let mix = Float(Double(written + AVAudioFramePosition(frame)) / Double(max(total - 1, 1)))
                for channel in 0..<Int(format.channelCount) {
                    outputChannels[channel][frame] =
                        leftChannels[channel][frame] * (1 - mix) + rightChannels[channel][frame] * mix
                }
            }
            try output.write(from: blended)
            written += AVAudioFramePosition(count)
        }
    }

    static func installedModelURL() -> URL? {
        DenoiseModelStore.installedModelIsValid() ? DenoiseModelStore.installedModelURL : nil
    }

    private static func prepare(_ source: AVAudioFile) throws -> AVAudioPCMBuffer {
        let sourceFormat = source.processingFormat
        guard source.length > 0,
              source.length <= AVAudioFramePosition(UInt32.max),
              let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(source.length)
              ) else {
            throw AIDenoiserError.unsupportedRecording
        }
        try source.read(into: input)

        if abs(sourceFormat.sampleRate - modelSampleRate) < 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           !sourceFormat.isInterleaved {
            return input
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: modelSampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AIDenoiserError.unsupportedRecording
        }

        let ratio = modelSampleRate / sourceFormat.sampleRate
        let estimatedFrames = Int(ceil(Double(input.frameLength) * ratio)) + 512
        guard estimatedFrames > 0,
              estimatedFrames <= Int(UInt32.max),
              let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(estimatedFrames)
              ) else {
            throw AIDenoiserError.unsupportedRecording
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw AIDenoiserError.conversionFailed(conversionError?.localizedDescription ?? "Unknown conversion error.")
        }
        guard converted.frameLength > 0 else { throw AIDenoiserError.processingFailed }
        return converted
    }
}
