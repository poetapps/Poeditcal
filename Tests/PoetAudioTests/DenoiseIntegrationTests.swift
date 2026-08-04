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

    func testNewTestFanNoiseFixture() throws {
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

        let renderReport = try VoicePolisher.render(
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
}
