import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let poetProject = UTType(exportedAs: "com.poetaudio.project", conformingTo: .package)
}

struct PoetProjectSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var projectName: String
    var sourceAudioFile: String
    var sourceDisplayName: String
    var phase: WorkflowPhase
    var editingMode: EditingMode
    var autoEditConfiguration: AutoEditConfiguration
    var pacing: PacingPreset
    var pauseDuration: Double? = nil
    var duration: TimeInterval
    var words: [TranscriptWord]
    var polishSelections: Set<PolishOption>
    var polishIntensities: [PolishOption: PolishIntensity]? = nil
    var usePolish: Bool
    var loudnessPreset: LoudnessPreset
    var exportAudio: Bool
    var exportTXT: Bool
    var exportSRT: Bool
    var exportVTT: Bool
}

enum PoetProjectError: LocalizedError {
    case unsupportedVersion(Int)
    case missingManifest
    case missingAudio(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This project was made by a newer version of Poet Audio (format \(version))."
        case .missingManifest:
            "This .poe project does not contain a project manifest."
        case .missingAudio(let name):
            "The project’s source recording is missing (\(name))."
        }
    }
}

enum PoetProjectStore {
    static let manifestName = "project.json"

    static func save(
        snapshot: PoetProjectSnapshot,
        sourceAudioURL: URL,
        to requestedURL: URL
    ) throws -> URL {
        let destination = requestedURL.pathExtension.lowercased() == "poe"
            ? requestedURL
            : requestedURL.appendingPathExtension("poe")
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).saving",
            isDirectory: true
        )
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let audioDestination = staging.appendingPathComponent(snapshot.sourceAudioFile)
            try manager.copyItem(at: sourceAudioURL, to: audioDestination)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: staging.appendingPathComponent(manifestName), options: .atomic)

            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }

        return destination
    }

    static func load(from packageURL: URL) throws -> (snapshot: PoetProjectSnapshot, audioURL: URL) {
        let manifestURL = packageURL.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PoetProjectError.missingManifest
        }
        let snapshot = try JSONDecoder().decode(PoetProjectSnapshot.self, from: Data(contentsOf: manifestURL))
        guard snapshot.version <= PoetProjectSnapshot.currentVersion else {
            throw PoetProjectError.unsupportedVersion(snapshot.version)
        }
        let audioURL = packageURL.appendingPathComponent(snapshot.sourceAudioFile)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw PoetProjectError.missingAudio(snapshot.sourceAudioFile)
        }
        return (snapshot, audioURL)
    }
}
