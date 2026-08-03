import Foundation

enum AutoEditIntensity: String, CaseIterable, Identifiable, Codable, Sendable {
    case conservative = "Conservative"
    case balanced = "Balanced"
    case thorough = "Thorough"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .conservative: "Only high-confidence cleanups"
        case .balanced: "Clear fillers and repeated takes"
        case .thorough: "More conversational cleanup"
        }
    }
}

struct AutoEditConfiguration: Codable, Sendable, Equatable {
    var intensity: AutoEditIntensity = .balanced
    var removeFillers = true
    var detectRetakes = true
    var detectRestarts = true
    var protectOpening = false
}

struct AutoEditSuggestion: Sendable {
    enum Reason: String, Sendable {
        case filler = "Filler word"
        case earlierTake = "Earlier take"
        case restart = "Restart phrase"
    }

    let range: ClosedRange<Int>
    let reason: Reason
}

enum AutoEditAnalyzer {
    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "erm", "er", "hmm"
    ]
    private static let restartWords: Set<String> = [
        "sorry", "again", "restart", "redo"
    ]

    static func suggestions(
        for tokens: [TranscribedToken],
        configuration: AutoEditConfiguration = AutoEditConfiguration()
    ) -> [AutoEditSuggestion] {
        guard !tokens.isEmpty else { return [] }
        let normalized = tokens.map { normalize($0.text) }
        var suggestions: [AutoEditSuggestion] = []

        if configuration.removeFillers {
            let singleFillers = fillers.union(configuration.intensity == .thorough ? ["like", "basically", "actually"] : [])
            for index in normalized.indices where singleFillers.contains(normalized[index]) {
                suggestions.append(AutoEditSuggestion(range: index...index, reason: .filler))
            }
            if configuration.intensity != .conservative {
                let phrases = [["i", "mean"], ["you", "know"], ["yeah", "yeah"]] +
                    (configuration.intensity == .thorough ? [["kind", "of"], ["sort", "of"]] : [])
                for phrase in phrases {
                    for range in occurrences(of: phrase, in: normalized) {
                        suggestions.append(AutoEditSuggestion(range: range, reason: .filler))
                    }
                }
            }
        }

        // A repeated four-word (or longer) phrase nearby is strong evidence of a retake.
        // Expand the earlier match to its local utterance boundary and include common
        // restart language between the two takes.
        var bestRepeatedRanges: [ClosedRange<Int>] = []
        let minimumMatch = switch configuration.intensity {
        case .conservative: 6
        case .balanced: 4
        case .thorough: 3
        }
        if configuration.detectRetakes {
            for laterStart in normalized.indices {
                let searchStart = max(0, laterStart - 80)
                guard laterStart - searchStart >= minimumMatch else { continue }
                for earlierStart in searchStart..<(laterStart - minimumMatch + 1) {
                var matchLength = 0
                while laterStart + matchLength < normalized.count,
                      earlierStart + matchLength < laterStart,
                      normalized[earlierStart + matchLength] == normalized[laterStart + matchLength],
                      !normalized[laterStart + matchLength].isEmpty {
                    matchLength += 1
                }
                    guard matchLength >= minimumMatch else { continue }

                    let earlierMatchEnd = earlierStart + matchLength - 1
                    let hasRestartCue = (earlierMatchEnd + 1..<laterStart)
                        .contains(where: { restartWords.contains(normalized[$0]) })
                    let endsAtBoundary = tokens[earlierMatchEnd].text.hasSuffix(".") ||
                        tokens[earlierMatchEnd].text.hasSuffix("?") ||
                        tokens[earlierMatchEnd].text.hasSuffix("!") ||
                        (earlierMatchEnd + 1 < tokens.count &&
                         tokens[earlierMatchEnd + 1].startTime -
                            (tokens[earlierMatchEnd].startTime + tokens[earlierMatchEnd].duration) > 0.55)
                    if configuration.intensity == .balanced,
                       matchLength == minimumMatch,
                       !hasRestartCue,
                       !endsAtBoundary {
                        continue
                    }

                    let expandedStart = utteranceStart(before: earlierStart, tokens: tokens)
                    if configuration.protectOpening,
                       tokens[expandedStart].startTime < 1.5,
                       !hasRestartCue {
                        continue
                    }
                    var expandedEnd = earlierStart + matchLength - 1
                    if let cue = (expandedEnd + 1..<laterStart).first(where: { restartWords.contains(normalized[$0]) }) {
                        expandedEnd = min(laterStart - 1, utteranceEnd(after: cue, before: laterStart, tokens: tokens))
                    }
                    bestRepeatedRanges.append(expandedStart...expandedEnd)
                }
            }
        }

        for range in merge(bestRepeatedRanges) {
            suggestions.append(AutoEditSuggestion(range: range, reason: .earlierTake))
        }

        // Restart cues that weren't captured by a repeated phrase are still useful,
        // but stay conservative: remove only the cue phrase itself.
        if configuration.detectRestarts {
            for index in normalized.indices where restartWords.contains(normalized[index]) {
                if suggestions.contains(where: { $0.range.contains(index) }) { continue }
                let end = utteranceEnd(after: index, before: min(index + 7, tokens.count), tokens: tokens)
                suggestions.append(AutoEditSuggestion(range: index...end, reason: .restart))
            }
        }

        return suggestions
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func occurrences(of phrase: [String], in words: [String]) -> [ClosedRange<Int>] {
        guard !phrase.isEmpty, words.count >= phrase.count else { return [] }
        return (0...(words.count - phrase.count)).compactMap { start in
            Array(words[start..<(start + phrase.count)]) == phrase
                ? start...(start + phrase.count - 1)
                : nil
        }
    }

    private static func utteranceStart(before index: Int, tokens: [TranscribedToken]) -> Int {
        var cursor = index
        while cursor > 0 && index - cursor < 10 {
            let prior = tokens[cursor - 1]
            let gap = tokens[cursor].startTime - (prior.startTime + prior.duration)
            if gap > 0.75 || prior.text.hasSuffix(".") || prior.text.hasSuffix("?") || prior.text.hasSuffix("!") { break }
            cursor -= 1
        }
        return cursor
    }

    private static func utteranceEnd(after index: Int, before limit: Int, tokens: [TranscribedToken]) -> Int {
        var cursor = index
        let upper = min(limit, tokens.count - 1)
        while cursor < upper {
            if tokens[cursor].text.hasSuffix(".") || tokens[cursor].text.hasSuffix("?") || tokens[cursor].text.hasSuffix("!") { break }
            let gap = tokens[cursor + 1].startTime - (tokens[cursor].startTime + tokens[cursor].duration)
            if gap > 0.75 { break }
            cursor += 1
        }
        return cursor
    }

    private static func merge(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Int>] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
