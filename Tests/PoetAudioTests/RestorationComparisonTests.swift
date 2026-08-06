import AVFoundation
import XCTest
@testable import PoetAudio

final class RestorationComparisonTests: XCTestCase {
    func testRenderMatchedRestorationComparison() async throws {
        guard ProcessInfo.processInfo.environment["POET_RUN_RESTORATION_COMPARISON"] == "1" else {
            throw XCTSkip("Set POET_RUN_RESTORATION_COMPARISON=1 to render the external restoration comparison.")
        }

        let folderPath = ProcessInfo.processInfo.environment["POET_RESTORATION_ARTIFACTS"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Artifacts/RestorationComparison", isDirectory: true).path
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let candidates = [
            ("original-no-restoration", "newTest-original-48k-mono.wav"),
            ("clear", "newTest-clear-raw.wav"),
            ("resemble", "newTest-resemble-raw.wav"),
            ("voicefixer", "newTest-voicefixer-raw.wav"),
        ]
        let options = AudioRenderOptions(
            pacing: .natural,
            reduceNoise: false,
            voiceEQ: true,
            deEss: true,
            compression: true,
            forceMono: true,
            breathControl: true,
            normalizeLoudness: true,
            loudnessPreset: .podcast
        )

        for candidate in candidates {
            let source = folder.appendingPathComponent(candidate.1)
            let destination = folder.appendingPathComponent("newTest-\(candidate.0)-polished.wav")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Missing \(source.path)")

            let started = ContinuousClock.now
            let report = try await VoicePolisher.render(
                sourceURL: source,
                destinationURL: destination,
                options: options
            )
            let elapsed = started.duration(to: .now)
            let signal = try AudioSignalAnalyzer.analyze(url: destination)
            let loudness = try LoudnessAnalyzer.measure(url: destination)
            let file = try AVAudioFile(forReading: destination)

            print(
                "RESTORATION_RESULT name=\(candidate.0) " +
                "seconds=\(elapsed) sampleRate=\(Int(file.processingFormat.sampleRate)) " +
                "channels=\(file.processingFormat.channelCount) " +
                String(format: "lufs=%.2f peak=%.2f noiseFloor=%.2f speech=%.2f dynamics=%.2f sibilance=%.3f presence=%.3f ",
                       loudness.integratedLUFS, loudness.peakDBFS, signal.noiseFloorDB,
                       signal.speechLevelDB, signal.dynamicRangeDB, signal.sibilanceScore,
                       signal.presenceScore) +
                "quality=\(report.quality.summary) breaths=\(report.breathControl?.count ?? 0)"
            )

            XCTAssertTrue(report.quality.passed, report.quality.summary)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            XCTAssertEqual(loudness.integratedLUFS, LoudnessPreset.podcast.targetLUFS, accuracy: 1.0)
        }
    }
}
