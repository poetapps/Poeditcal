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
        case weakerTake = "Weaker take"
        case restart = "Restart phrase"
        case correction = "Self-correction"
        case repetition = "Accidental repetition"
    }

    let range: ClosedRange<Int>
    let reason: Reason
    let confidence: Double
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
                let confidence = fillers.contains(normalized[index]) ? 0.98 : 0.72
                suggestions.append(AutoEditSuggestion(range: index...index, reason: .filler, confidence: confidence))
            }
            if configuration.intensity != .conservative {
                // Contextual phrases such as “I mean” are intentionally not removed
                // here. The Smart Edit model decides whether they introduce a real
                // correction or belong to the sentence the speaker intended to keep.
                let phrases = [["you", "know"], ["yeah", "yeah"]] +
                    (configuration.intensity == .thorough ? [["kind", "of"], ["sort", "of"]] : [])
                for phrase in phrases {
                    for range in occurrences(of: phrase, in: normalized) {
                        suggestions.append(AutoEditSuggestion(range: range, reason: .filler, confidence: 0.88))
                    }
                }
            }
        }

        // A repeated four-word (or longer) phrase nearby is strong evidence of a retake.
        // Expand the earlier match to its local utterance boundary and include common
        // restart language between the two takes.
        var repeatedCandidates: [(range: ClosedRange<Int>, confidence: Double)] = []
        let minimumMatch = switch configuration.intensity {
        case .conservative: 6
        case .balanced: 4
        case .thorough: 3
        }
        if configuration.detectRetakes {
            suggestions.append(contentsOf: explicitCorrectionSuggestions(
                normalized: normalized,
                tokens: tokens
            ))
            suggestions.append(contentsOf: interruptedRepetitionSuggestions(
                normalized: normalized
            ))
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
                    repeatedCandidates.append((expandedStart...expandedEnd, hasRestartCue ? 0.98 : 0.93))
                }
            }

            repeatedCandidates.append(contentsOf: fuzzyRepeatedCandidates(
                normalized: normalized,
                tokens: tokens,
                configuration: configuration,
                minimumMatch: minimumMatch
            ))
        }

        for range in merge(repeatedCandidates.map(\.range)) {
            let confidence = repeatedCandidates
                .filter { $0.range.overlaps(range) }
                .map(\.confidence)
                .max() ?? 0.8
            suggestions.append(AutoEditSuggestion(range: range, reason: .earlierTake, confidence: confidence))
        }

        // Restart cues that weren't captured by a repeated phrase are still useful,
        // but stay conservative: remove only the cue phrase itself.
        if configuration.detectRestarts {
            for index in normalized.indices where isContextualRestart(at: index, normalized: normalized, tokens: tokens) {
                if suggestions.contains(where: { $0.range.contains(index) }) { continue }
                let end = utteranceEnd(after: index, before: min(index + 7, tokens.count), tokens: tokens)
                let cue = normalized[index]
                let confidence = cue == "restart" || cue == "redo" ? 0.97 : 0.86
                suggestions.append(AutoEditSuggestion(range: index...end, reason: .restart, confidence: confidence))
            }
        }

        return suggestions
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// Detect a correction only when the wording after “I mean” clearly resumes
    /// an earlier clause. This protects intentional uses such as “I mean, what am
    /// I supposed to do?” while catching “It is eight—nope, sorry, I mean it is seven.”
    private static func explicitCorrectionSuggestions(
        normalized: [String],
        tokens: [TranscribedToken]
    ) -> [AutoEditSuggestion] {
        guard normalized.count >= 5 else { return [] }
        var result: [AutoEditSuggestion] = []
        for cueStart in normalized.indices where normalized[cueStart] == "i" {
            let cueEnd = cueStart + 1
            guard cueEnd < normalized.count, normalized[cueEnd] == "mean" else { continue }
            var correctedStart = cueEnd + 1
            while correctedStart < normalized.count, fillers.contains(normalized[correctedStart]) {
                correctedStart += 1
            }
            guard correctedStart < normalized.count else { continue }

            let earlierBoundary = utteranceStart(before: cueStart, tokens: tokens)
            guard earlierBoundary < cueStart else { continue }
            let explicitCue = normalized[earlierBoundary..<cueStart].contains { word in
                word == "no" || word == "nope" || word == "sorry" || word == "actually"
            }
            var bestStart: Int?
            var bestLength = 0
            for earlierStart in earlierBoundary..<cueStart {
                var length = 0
                while length < 4,
                      earlierStart + length < cueStart,
                      correctedStart + length < normalized.count,
                      normalized[earlierStart + length] == normalized[correctedStart + length],
                      !normalized[earlierStart + length].isEmpty {
                    length += 1
                }
                if length > bestLength {
                    bestStart = earlierStart
                    bestLength = length
                }
            }
            guard let bestStart,
                  bestLength >= 2 || (bestLength == 1 && explicitCue) else { continue }
            result.append(AutoEditSuggestion(
                range: bestStart...cueEnd,
                reason: .correction,
                confidence: explicitCue ? 0.99 : 0.95
            ))
        }
        return result
    }

    /// Catch a short take repeated immediately after a hesitation, such as
    /// “it is, um, it is about seven.” The earlier fragment and hesitation are
    /// removed together so the surviving sentence remains grammatical.
    private static func interruptedRepetitionSuggestions(
        normalized: [String]
    ) -> [AutoEditSuggestion] {
        guard normalized.count >= 5 else { return [] }
        var result: [AutoEditSuggestion] = []
        for laterStart in normalized.indices where laterStart >= 3 {
            for length in stride(from: 4, through: 2, by: -1) {
                guard laterStart + length <= normalized.count else { continue }
                let earliest = max(0, laterStart - length - 3)
                guard earliest <= laterStart - length else { continue }
                for earlierStart in earliest...(laterStart - length) {
                    let earlierEnd = earlierStart + length
                    let bridge = normalized[earlierEnd..<laterStart]
                    guard bridge.count <= 3,
                          bridge.allSatisfy({ fillers.contains($0) }),
                          Array(normalized[earlierStart..<earlierEnd]) == Array(normalized[laterStart..<(laterStart + length)]) else {
                        continue
                    }
                    result.append(AutoEditSuggestion(
                        range: earlierStart...(laterStart - 1),
                        reason: .repetition,
                        confidence: bridge.isEmpty ? 0.94 : 0.98
                    ))
                    break
                }
                if result.last?.range.upperBound == laterStart - 1 { break }
            }
        }
        return result
    }

    private static func occurrences(of phrase: [String], in words: [String]) -> [ClosedRange<Int>] {
        guard !phrase.isEmpty, words.count >= phrase.count else { return [] }
        return (0...(words.count - phrase.count)).compactMap { start in
            Array(words[start..<(start + phrase.count)]) == phrase
                ? start...(start + phrase.count - 1)
                : nil
        }
    }

    private static func fuzzyRepeatedCandidates(
        normalized: [String],
        tokens: [TranscribedToken],
        configuration: AutoEditConfiguration,
        minimumMatch: Int
    ) -> [(range: ClosedRange<Int>, confidence: Double)] {
        guard normalized.count >= minimumMatch * 2 else { return [] }
        let threshold: Double = switch configuration.intensity {
        case .conservative: 0.92
        case .balanced: 0.80
        case .thorough: 0.70
        }
        var result: [(range: ClosedRange<Int>, confidence: Double)] = []

        for laterStart in normalized.indices {
            let searchStart = max(0, laterStart - 80)
            guard laterStart - searchStart >= minimumMatch else { continue }
            for earlierStart in searchStart..<(laterStart - minimumMatch + 1) {
                // Cheap anchors keep this pass near-linear on long recordings;
                // the more expensive token alignment only runs on plausible
                // phrase starts and tolerates one leading insertion/deletion.
                let directAnchor = wordsAreSimilar(normalized[earlierStart], normalized[laterStart])
                let shiftedEarlierAnchor = earlierStart + 1 < laterStart &&
                    wordsAreSimilar(normalized[earlierStart + 1], normalized[laterStart])
                let shiftedLaterAnchor = laterStart + 1 < normalized.count &&
                    wordsAreSimilar(normalized[earlierStart], normalized[laterStart + 1])
                guard directAnchor || shiftedEarlierAnchor || shiftedLaterAnchor else { continue }

                let earlierLength = phraseLength(
                    from: earlierStart,
                    maximumEnd: laterStart,
                    tokens: tokens
                )
                let laterLength = phraseLength(
                    from: laterStart,
                    maximumEnd: normalized.count,
                    tokens: tokens
                )
                guard earlierLength >= minimumMatch, laterLength >= minimumMatch else { continue }
                let earlier = Array(normalized[earlierStart..<(earlierStart + earlierLength)])
                let later = Array(normalized[laterStart..<(laterStart + laterLength)])
                let similarity = sequenceSimilarity(earlier, later)
                guard similarity >= threshold, similarity < 0.999 else { continue }

                let earlierEnd = earlierStart + earlierLength - 1
                let hasRestartCue = (earlierEnd + 1..<laterStart)
                    .contains(where: { restartWords.contains(normalized[$0]) })
                let endsAtBoundary = isBoundary(after: earlierEnd, tokens: tokens)
                if configuration.intensity != .thorough,
                   !hasRestartCue,
                   !endsAtBoundary,
                   similarity < 0.9 {
                    continue
                }
                let expandedStart = utteranceStart(before: earlierStart, tokens: tokens)
                if configuration.protectOpening,
                   tokens[expandedStart].startTime < 1.5,
                   !hasRestartCue {
                    continue
                }
                let expandedEnd = earlierEnd
                result.append((expandedStart...expandedEnd, min(0.94, similarity + (hasRestartCue ? 0.08 : 0))))
            }
        }
        return result
    }

    private static func phraseLength(
        from start: Int,
        maximumEnd: Int,
        tokens: [TranscribedToken]
    ) -> Int {
        let hardEnd = min(maximumEnd, min(tokens.count, start + 10))
        guard start < hardEnd else { return 0 }
        var end = start
        while end + 1 < hardEnd {
            if isBoundary(after: end, tokens: tokens) { break }
            end += 1
        }
        return end - start + 1
    }

    private static func sequenceSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var prior = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                let substitution = prior[rightIndex] + (wordsAreSimilar(left, right) ? 0 : 1)
                current[rightIndex + 1] = min(
                    substitution,
                    min(prior[rightIndex + 1] + 1, current[rightIndex] + 1)
                )
            }
            prior = current
        }
        let distance = prior[rhs.count]
        return 1 - Double(distance) / Double(max(lhs.count, rhs.count))
    }

    private static func wordsAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard min(lhs.count, rhs.count) >= 4 else { return false }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
        return characterEditDistance(lhs, rhs) <= 1
    }

    private static func characterEditDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var prior = Array(0...right.count)
        for (leftIndex, character) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, other) in right.enumerated() {
                current[rightIndex + 1] = min(
                    prior[rightIndex] + (character == other ? 0 : 1),
                    min(prior[rightIndex + 1] + 1, current[rightIndex] + 1)
                )
            }
            prior = current
        }
        return prior[right.count]
    }

    private static func isContextualRestart(
        at index: Int,
        normalized: [String],
        tokens: [TranscribedToken]
    ) -> Bool {
        let cue = normalized[index]
        guard restartWords.contains(cue) else { return false }
        if cue == "restart" || cue == "redo" { return true }
        let nearbyEnd = min(normalized.count, index + 5)
        let following = Set(normalized[(index + 1)..<nearbyEnd])
        let explicitLanguage = !following.isDisjoint(with: ["redo", "restart", "again", "try", "take", "start"])
        if cue == "sorry" { return explicitLanguage }
        guard cue == "again" else { return false }
        let precedingStart = max(0, index - 4)
        let preceding = Set(normalized[precedingStart..<index])
        return !preceding.isDisjoint(with: ["try", "take", "start", "say", "that"])
            && (index == tokens.count - 1 || !tokens[index].text.hasSuffix("."))
    }

    private static func isBoundary(after index: Int, tokens: [TranscribedToken]) -> Bool {
        guard tokens.indices.contains(index) else { return false }
        if tokens[index].text.hasSuffix(".") || tokens[index].text.hasSuffix("?") || tokens[index].text.hasSuffix("!") {
            return true
        }
        guard index + 1 < tokens.count else { return true }
        return tokens[index + 1].startTime - (tokens[index].startTime + tokens[index].duration) > 0.55
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
