import AVFoundation
import Foundation
import PoetDenoise

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
