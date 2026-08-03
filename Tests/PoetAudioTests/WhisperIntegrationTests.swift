import AVFoundation
import Foundation
import XCTest
@testable import PoetAudio

@MainActor
final class LocalTranscriptionIntegrationTests: XCTestCase {
    func testSuppliedRecordingProducesTimedWords() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["POET_RUN_TRANSCRIPTION_TEST"] == "1" ||
                environment["POET_RUN_WHISPER_TEST"] == "1" else {
            throw XCTSkip("Set POET_RUN_TRANSCRIPTION_TEST=1 to run the local model integration test.")
        }

        let recording: URL
        if let override = ProcessInfo.processInfo.environment["POET_TEST_RECORDING"] {
            recording = URL(fileURLWithPath: override)
        } else {
            let workspaceRecording = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("short_Test Recording.m4a")
            recording = FileManager.default.fileExists(atPath: workspaceRecording.path)
                ? workspaceRecording
                : Bundle(for: Self.self).url(forResource: "short_Test Recording", withExtension: "m4a")!
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))

        let transcriber = LocalSpeechTranscriber()
        let tokens = try await transcriber.transcribe(url: recording) { _, _ in }

        XCTAssertGreaterThan(tokens.count, 2)
        XCTAssertTrue(tokens.allSatisfy { $0.startTime >= 0 && $0.duration > 0 })
        XCTAssertEqual(tokens.map(\.startTime), tokens.map(\.startTime).sorted())
        let recordingDuration = try AVAudioFile(forReading: recording).duration
        XCTAssertLessThanOrEqual(tokens.map { $0.startTime + $0.duration }.max() ?? 0, recordingDuration + 0.5)
        let transcript = tokens.map(\.text).joined(separator: " ")
        print("Local transcript: \(transcript)")
        print("Timed words: \(tokens.map { String(format: "%.2f–%.2f:%@", $0.startTime, $0.startTime + $0.duration, $0.text) }.joined(separator: " | "))")
        if recording.lastPathComponent == "test_42.m4a" {
            let normalized = tokens.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let repeatedTake = ["there's", "a", "subtle", "vagueness"]
            let repeatedTakeStarts = occurrenceStarts(of: repeatedTake, in: normalized)
            XCTAssertTrue(transcript.contains("LLMs"), transcript)
            XCTAssertTrue(transcript.contains("humanity wasn't prepared"), transcript)
            XCTAssertTrue(transcript.contains("words didn't originate from the people speaking"), transcript)
            XCTAssertGreaterThanOrEqual(repeatedTakeStarts.count, 2, transcript)
            XCTAssertGreaterThanOrEqual(occurrences(of: ["signs", "that", "the", "words", "didn't", "work"], in: normalized), 2, transcript)
            XCTAssertFalse(transcript.contains(".O .O"), transcript)

            let suggested = Set(AutoEditAnalyzer.suggestions(for: tokens).flatMap { Array($0.range) })
            XCTAssertTrue(suggested.contains(repeatedTakeStarts[0]), "The earlier repeated take should be suggested.")
            XCTAssertFalse(suggested.contains(repeatedTakeStarts[1]), "The later repeated take should be retained.")
        } else if recording.lastPathComponent == "newTest.m4a" {
            let normalized = tokens.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let phrase = ["i", "just", "wanted", "to", "see"]
            let occurrences = (0...max(0, normalized.count - phrase.count)).filter { start in
                normalized.count >= start + phrase.count && Array(normalized[start..<(start + phrase.count)]) == phrase
            }
            XCTAssertGreaterThanOrEqual(occurrences.count, 2, transcript)
            XCTAssertFalse(transcript.contains("[BLANK"))
            let suggestions = AutoEditAnalyzer.suggestions(for: tokens)
            let removed = Set(suggestions.flatMap { Array($0.range) })
            XCTAssertFalse(removed.contains(0), "The opening should remain protected.")
            XCTAssertTrue(removed.contains(occurrences[0]), "The earlier repeated take should be suggested.")
            XCTAssertFalse(removed.contains(occurrences[1]), "The later repeated take should be retained.")
        }
    }

    private func occurrences(of phrase: [String], in words: [String]) -> Int {
        occurrenceStarts(of: phrase, in: words).count
    }

    private func occurrenceStarts(of phrase: [String], in words: [String]) -> [Int] {
        guard words.count >= phrase.count else { return [] }
        return (0...(words.count - phrase.count)).filter { start in
            Array(words[start..<(start + phrase.count)]) == phrase
        }
    }
}

private extension AVAudioFile {
    var duration: TimeInterval {
        Double(length) / processingFormat.sampleRate
    }
}
