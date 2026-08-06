import AVFoundation
import XCTest
@testable import PoetAudio

final class DenoiseIntegrationTests: XCTestCase {
    @MainActor
    func testModelDownloadsAndInstallsFromPinnedGitHubURL() async throws {
        guard ProcessInfo.processInfo.environment["POET_RUN_MODEL_DOWNLOAD_TEST"] == "1" else {
            throw XCTSkip("Set POET_RUN_MODEL_DOWNLOAD_TEST=1 to verify the real model download.")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetModelDownload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = DenoiseModelStore(installationDirectoryURL: folder)
        XCTAssertFalse(store.isInstalled)
        await store.install()

        XCTAssertTrue(store.isInstalled, store.errorMessage ?? "Model was not installed")
        XCTAssertEqual(
            try DenoiseModelStore.sha256Digest(of: store.modelURL),
            DenoiseModelStore.expectedSHA256
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: store.modelURL.path)[.size] as? Int,
            DenoiseModelStore.downloadSize
        )
    }

    func testNewTestFanNoiseFixture() async throws {
        guard ProcessInfo.processInfo.environment["POET_RUN_DENOISE_FIXTURE"] == "1" else {
            throw XCTSkip("Set POET_RUN_DENOISE_FIXTURE=1 to run the supplied fan-noise regression fixture.")
        }
        guard DenoiseModelStore.installedModelIsValid() else {
            throw XCTSkip("Install Poet AI Noise Reduction in the app before running this integration test.")
        }

        let source = URL(fileURLWithPath: "/Users/jonah/Downloads/newTest.m4a")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("newTest.m4a is not present in Downloads.")
        }

        let denoised = URL(fileURLWithPath: "/private/tmp/poet-newTest-dpdfnet2.wav")
        let polished = URL(fileURLWithPath: "/private/tmp/poet-newTest-polished.wav")
        let sourceAnalysis = try AudioSignalAnalyzer.analyze(url: source)
        let sourceFile = try AVAudioFile(forReading: source)
        let sourceDuration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate

        let aiReport = try AIDenoiser.render(sourceURL: source, destinationURL: denoised)
        let denoisedAnalysis = try AudioSignalAnalyzer.analyze(url: denoised)
        let denoisedFile = try AVAudioFile(forReading: denoised)
        let denoisedDuration = Double(denoisedFile.length) / denoisedFile.processingFormat.sampleRate

        let renderReport = try await VoicePolisher.render(
            sourceURL: source,
            destinationURL: polished,
            options: AudioRenderOptions(
                pacing: .untouched,
                reduceNoise: true,
                voiceEQ: true,
                deEss: true,
                compression: true,
                forceMono: true,
                breathControl: true,
                normalizeLoudness: true,
                loudnessPreset: .podcast
            )
        )
        let finishedLoudness = try LoudnessAnalyzer.measure(url: polished)

        print(String(format: "DPDFNet fixture: noise %.1f → %.1f dB; speech %.1f → %.1f dB; %.2fs processing; finish %.1f LUFS / %.1f dB peak", sourceAnalysis.noiseFloorDB, denoisedAnalysis.noiseFloorDB, sourceAnalysis.speechLevelDB, denoisedAnalysis.speechLevelDB, aiReport.processingTime, finishedLoudness.integratedLUFS, finishedLoudness.peakDBFS))
        if let deEssing = renderReport.deEssing {
            print(String(format: "Adaptive de-esser: %d regions at %.0f Hz; measured average %.1f dB / peak %.1f dB reduction; ordinary voice %+.2f dB; post-check %@", deEssing.count, deEssing.detectedFrequencyHz, deEssing.averageReductionDB, deEssing.peakReductionDB, deEssing.ordinaryVoiceChangeDB, deEssing.passedPostAnalysis ? "passed" : "failed"))
        }
        print("Listen: \(denoised.path) and \(polished.path)")

        XCTAssertLessThan(denoisedAnalysis.noiseFloorDB, sourceAnalysis.noiseFloorDB - 8)
        XCTAssertGreaterThan(denoisedAnalysis.speechLevelDB, sourceAnalysis.speechLevelDB - 5)
        XCTAssertEqual(denoisedDuration, sourceDuration, accuracy: 0.03)
        XCTAssertEqual(finishedLoudness.integratedLUFS, LoudnessPreset.podcast.targetLUFS, accuracy: 1.0)
        XCTAssertLessThanOrEqual(finishedLoudness.peakDBFS, LoudnessPreset.podcast.peakCeilingDBFS + 0.1)
        XCTAssertTrue(renderReport.quality.passed, renderReport.quality.summary)
    }

    func testLongRecordingUsesSeamSafeChunkedDenoise() throws {
        guard ProcessInfo.processInfo.environment["POET_RUN_LONG_DENOISE_TEST"] == "1" else {
            throw XCTSkip("Set POET_RUN_LONG_DENOISE_TEST=1 to run the long chunked-denoise test.")
        }
        guard DenoiseModelStore.installedModelIsValid() else {
            throw XCTSkip("Install Poet AI Noise Reduction before running this integration test.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetLongDenoise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("long-source.wav")
        let output = folder.appendingPathComponent("long-output.wav")
        try makeLongDenoiseFixture(at: source)

        let report = try AIDenoiser.render(sourceURL: source, destinationURL: output)
        let sourceFile = try AVAudioFile(forReading: source)
        let outputFile = try AVAudioFile(forReading: output)
        let sourceDuration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate

        XCTAssertEqual(report.outputSampleRate, 48_000)
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: 1 / 48_000)
        XCTAssertLessThan(try maximumAdjacentSampleDelta(in: output), 0.25)
    }

    private func makeLongDenoiseFixture(at url: URL) throws {
        let sampleRate = 48_000.0
        let duration = 96.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = AVAudioFramePosition(duration * sampleRate)
        let capacity: AVAudioFrameCount = 16_384
        var position: AVAudioFramePosition = 0
        while position < totalFrames {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), totalFrames - position))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let samples = buffer.floatChannelData!.pointee
            for frame in 0..<Int(count) {
                let absolute = position + AVAudioFramePosition(frame)
                let time = Double(absolute) / sampleRate
                let isBoundarySilence = (56.0 ... 64.0).contains(time)
                samples[frame] = isBoundarySilence
                    ? 0.000_1
                    : Float(0.16 * sin(2 * .pi * 190 * Double(absolute) / sampleRate))
            }
            try file.write(from: buffer)
            position += AVAudioFramePosition(count)
        }
    }

    private func maximumAdjacentSampleDelta(in url: URL) throws -> Float {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity: AVAudioFrameCount = 16_384
        var maximum: Float = 0
        var previous: Float?
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?.pointee else { break }
            for frame in 0..<Int(buffer.frameLength) {
                if let previous { maximum = max(maximum, abs(samples[frame] - previous)) }
                previous = samples[frame]
            }
        }
        return maximum
    }
}
