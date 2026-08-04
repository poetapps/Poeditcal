import Combine
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum SmartEditModelChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast
    case reliable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .reliable: "Reliable"
        }
    }

    var modelName: String {
        switch self {
        case .fast: "Qwen3 0.6B · 4-bit"
        case .reliable: "Qwen3 1.7B · 4-bit"
        }
    }

    var detail: String {
        switch self {
        case .fast: "Smallest download and quickest transcript pass"
        case .reliable: "Better judgment for corrections and ambiguous phrasing"
        }
    }

    var repoID: String {
        switch self {
        case .fast: "mlx-community/Qwen3-0.6B-4bit"
        case .reliable: "mlx-community/Qwen3-1.7B-4bit"
        }
    }
}

struct ContextualEditDeletion: Codable, Sendable, Equatable {
    let startToken: Int
    let endToken: Int
    let kind: String
    let reason: String
    let confidence: Double
}

private struct ContextualEditResponse: Codable {
    let deletions: [ContextualEditDeletion]
}

@MainActor
final class SmartEditModelStore: ObservableObject {
    static let shared = SmartEditModelStore()

    @Published var selectedChoice: SmartEditModelChoice {
        didSet { UserDefaults.standard.set(selectedChoice.rawValue, forKey: Self.selectionKey) }
    }
    @Published private(set) var installedChoices: Set<SmartEditModelChoice>
    @Published private(set) var downloadingChoice: SmartEditModelChoice?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var errorMessage: String?

    private static let selectionKey = "smartEditModelChoiceV1"
    private var loadedChoice: SmartEditModelChoice?
    private var loadedContainer: ModelContainer?

    private init() {
        selectedChoice = UserDefaults.standard.string(forKey: Self.selectionKey)
            .flatMap(SmartEditModelChoice.init(rawValue:)) ?? .fast
        installedChoices = Set(SmartEditModelChoice.allCases.filter(Self.isInstalled))
    }

    func isInstalled(_ choice: SmartEditModelChoice) -> Bool {
        installedChoices.contains(choice)
    }

    func select(_ choice: SmartEditModelChoice) {
        selectedChoice = choice
        errorMessage = nil
    }

    func install(_ choice: SmartEditModelChoice) async {
        guard downloadingChoice == nil else { return }
        selectedChoice = choice
        downloadingChoice = choice
        downloadProgress = 0
        errorMessage = nil
        do {
            _ = try await load(choice, allowsDownload: true)
            try FileManager.default.createDirectory(
                at: Self.modelDirectory(for: choice),
                withIntermediateDirectories: true
            )
            try Data(choice.repoID.utf8).write(to: Self.markerURL(for: choice), options: .atomic)
            installedChoices.insert(choice)
            downloadProgress = 1
        } catch is CancellationError {
            errorMessage = nil
        } catch {
            errorMessage = "Poet couldn’t install (choice.modelName). \(error.localizedDescription)"
        }
        downloadingChoice = nil
    }

    func contextualSuggestions(
        for tokens: [TranscribedToken],
        configuration: AutoEditConfiguration
    ) async throws -> [AutoEditSuggestion] {
        guard isInstalled(selectedChoice), !tokens.isEmpty else { return [] }
        let container = try await load(selectedChoice, allowsDownload: false)
        let chunks = Self.chunkRanges(tokenCount: tokens.count)
        var deletions: [ContextualEditDeletion] = []
        for range in chunks {
            try Task.checkCancellation()
            let chunk = Array(tokens[range])
            deletions += try await Self.analyze(
                container: container,
                tokens: chunk,
                globalOffset: range.lowerBound,
                configuration: configuration
            )
        }
        return Self.validatedSuggestions(
            deletions,
            tokenCount: tokens.count,
            configuration: configuration
        )
    }

    private func load(
        _ choice: SmartEditModelChoice,
        allowsDownload: Bool
    ) async throws -> ModelContainer {
        if loadedChoice == choice, let loadedContainer { return loadedContainer }
        guard allowsDownload || Self.isInstalled(choice) else {
            throw SmartEditModelError.notInstalled
        }

        let cache = HubCache(cacheDirectory: Self.modelDirectory(for: choice))
        let hub = HubClient(cache: cache)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: .init(id: choice.repoID),
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard self?.downloadingChoice == choice else { return }
                    self?.downloadProgress = progress.fractionCompleted
                }
            }
        )
        loadedChoice = choice
        loadedContainer = container
        return container
    }

    nonisolated private static func analyze(
        container: ModelContainer,
        tokens: [TranscribedToken],
        globalOffset: Int,
        configuration: AutoEditConfiguration
    ) async throws -> [ContextualEditDeletion] {
        let transcript = tokens.enumerated().map { localIndex, token in
            let globalIndex = globalOffset + localIndex
            return "[\(globalIndex)] \(token.text) {\(String(format: "%.2f", token.startTime))s}"
        }.joined(separator: " ")
        let system = """
        You are Poet Audio's conservative spoken-word editor. Identify only words the speaker clearly intended to replace or abandon: self-corrections, false starts, accidental adjacent repetitions, and genuine verbal fillers. Preserve meaning, style, emphasis, quotations, and intentional discourse phrases. "I mean" is not automatically a filler. If it introduces a correction, delete the abandoned earlier wording together with the correction cue and keep the corrected wording. If it begins or naturally belongs to the intended sentence, keep it. Return token IDs from the supplied transcript only. Never delete the final corrected take. /no_think
        """
        let preferences = """
        Enabled categories: fillers=\(configuration.removeFillers), retakes=\(configuration.detectRetakes), restarts=\(configuration.detectRestarts). Intensity=\(configuration.intensity.rawValue). If no clear edit is needed, return an empty deletions array.
        """
        let prompt = "\(preferences)\nTranscript:\n\(transcript)"
        let responseShape = #"Return JSON only: {"deletions":[{"startToken":0,"endToken":0,"kind":"filler|correction|retake|restart|repetition","reason":"brief explanation","confidence":0.0}]}. Do not add fields or prose."#
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: .init(
                maxTokens: 384,
                temperature: 0.1,
                repetitionPenalty: 1.05
            )
        )
        let rawOutput = try await session.respond(to: "\(responseShape)\n\n\(prompt)")
        guard let firstBrace = rawOutput.firstIndex(of: "{"),
              let lastBrace = rawOutput.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            throw SmartEditModelError.invalidResponse
        }
        let output = String(rawOutput[firstBrace...lastBrace])
        return try JSONDecoder().decode(
            ContextualEditResponse.self,
            from: Data(output.utf8)
        ).deletions
    }

    nonisolated static func validatedSuggestions(
        _ deletions: [ContextualEditDeletion],
        tokenCount: Int,
        configuration: AutoEditConfiguration
    ) -> [AutoEditSuggestion] {
        guard tokenCount > 0 else { return [] }
        let threshold: Double = switch configuration.intensity {
        case .conservative: 0.92
        case .balanced: 0.82
        case .thorough: 0.72
        }
        let permittedKinds = Set([
            configuration.removeFillers ? "filler" : nil,
            configuration.detectRetakes ? "correction" : nil,
            configuration.detectRetakes ? "retake" : nil,
            configuration.detectRetakes ? "repetition" : nil,
            configuration.detectRestarts ? "restart" : nil
        ].compactMap { $0 })

        return deletions.compactMap { deletion in
            guard permittedKinds.contains(deletion.kind),
                  deletion.confidence.isFinite,
                  deletion.confidence >= threshold,
                  deletion.startToken >= 0,
                  deletion.endToken >= deletion.startToken,
                  deletion.endToken < tokenCount,
                  deletion.endToken - deletion.startToken < 60,
                  deletion.endToken - deletion.startToken + 1 < tokenCount else { return nil }
            let reason: AutoEditSuggestion.Reason = switch deletion.kind {
            case "filler": .filler
            case "restart": .restart
            case "correction": .correction
            case "repetition": .repetition
            default: .earlierTake
            }
            return AutoEditSuggestion(
                range: deletion.startToken...deletion.endToken,
                reason: reason,
                confidence: min(1, deletion.confidence)
            )
        }
    }

    nonisolated static func chunkRanges(tokenCount: Int) -> [Range<Int>] {
        guard tokenCount > 0 else { return [] }
        let size = 140
        let overlap = 28
        var ranges: [Range<Int>] = []
        var start = 0
        while start < tokenCount {
            let end = min(tokenCount, start + size)
            ranges.append(start..<end)
            if end == tokenCount { break }
            start = end - overlap
        }
        return ranges
    }

    nonisolated private static var modelsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Poet Audio", isDirectory: true)
            .appendingPathComponent("Smart Edit Models", isDirectory: true)
    }

    nonisolated private static func modelDirectory(for choice: SmartEditModelChoice) -> URL {
        modelsDirectoryURL.appendingPathComponent(choice.rawValue, isDirectory: true)
    }

    nonisolated private static func markerURL(for choice: SmartEditModelChoice) -> URL {
        modelDirectory(for: choice).appendingPathComponent(".installed")
    }

    nonisolated private static func isInstalled(_ choice: SmartEditModelChoice) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(for: choice).path)
    }
}

private enum SmartEditModelError: LocalizedError {
    case notInstalled
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The selected Smart Edit model has not been downloaded."
        case .invalidResponse:
            "The Smart Edit model returned an unreadable response."
        }
    }
}
