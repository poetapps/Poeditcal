import SwiftUI

struct TranscriptEditView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TranscriptPanel()
        .padding(.horizontal, 30)
        .padding(.top, 62)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity)
    }
}

private struct ChangesPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PoetCard(padding: 18) {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel(text: "Changes")

                Rectangle().fill(PoetTheme.divider).frame(height: 1)

                ChangeMetric(icon: "text.badge.minus", value: "\(model.removedWords)", label: "words removed", color: PoetTheme.amber)
                ChangeMetric(icon: "arrow.uturn.backward", value: "\(model.restoredWords)", label: "suggestions restored", color: PoetTheme.sage)
                ChangeMetric(icon: "pause", value: model.pacing.rawValue, label: "pause treatment", color: PoetTheme.sage)

                Rectangle().fill(PoetTheme.divider).frame(height: 1)

                VStack(spacing: 9) {
                    Button("Apply suggestions") { model.applySuggestions() }
                        .buttonStyle(.plain)
                        .foregroundStyle(PoetTheme.sage)
                    Button("Restore everything") { model.restoreAll() }
                        .buttonStyle(.plain)
                        .foregroundStyle(PoetTheme.muted)
                }
                .font(PoetTheme.utility(11, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
        }
    }
}

private struct ChangeMetric: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(color.opacity(0.13)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(PoetTheme.utility(13, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text(label).font(PoetTheme.utility(10)).foregroundStyle(PoetTheme.muted)
            }
        }
    }
}

private struct TranscriptPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenFrames: [UUID: CGRect] = [:]
    @State private var dragAnchorID: UUID?
    @State private var highlightedPauseID: UUID?

    private let selectionSpace = "transcript-selection"

    private var paragraphs: [TranscriptParagraph] {
        guard !model.words.isEmpty else { return [] }
        var result: [TranscriptParagraph] = []
        var current: [TranscriptWord] = []
        var sentences = 0
        for (index, word) in model.words.enumerated() {
            current.append(word)
            if word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") { sentences += 1 }
            let nextGap = index + 1 < model.words.count ? model.words[index + 1].startTime - word.endTime : 0
            if index == model.words.count - 1 || nextGap > 1.35 || sentences >= 2 {
                result.append(TranscriptParagraph(id: current[0].id, startTime: current[0].startTime, words: current))
                current = []
                sentences = 0
            }
        }
        return result
    }

    var body: some View {
        PoetCard(padding: 0) {
            ScrollViewReader { transcriptProxy in
                VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Transcript").font(PoetTheme.editorial(22, weight: .regular))
                    Circle().fill(model.isDemoTranscript ? PoetTheme.amber : PoetTheme.sage).frame(width: 5, height: 5)
                    Text(model.isDemoTranscript ? "Sample" : "Local")
                        .font(PoetTheme.utility(9, weight: .semibold))
                        .foregroundStyle(PoetTheme.muted)
                    Spacer()
                    HeaderMetric(value: "\(model.removedWords)", label: "removed", color: PoetTheme.amber)
                    HeaderMetric(value: "\(model.compactedPauses)", label: "pauses", color: PoetTheme.sage)
                    Text("\(model.editedWordCount) / \(model.originalWordCount) words")
                        .font(PoetTheme.utility(9, weight: .semibold)).foregroundStyle(PoetTheme.faint)
                    Button("Apply suggestions") { model.applySuggestions() }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                    Button("Restore all") { model.restoreAll() }
                        .buttonStyle(.plain)
                        .font(PoetTheme.utility(10, weight: .semibold))
                        .foregroundStyle(PoetTheme.muted)
                    Button { model.undoRestoreAll() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .font(PoetTheme.utility(10, weight: .semibold))
                    .foregroundStyle(model.canUndoRestoreAll ? PoetTheme.cream : PoetTheme.faint)
                    .disabled(!model.canUndoRestoreAll)
                }
                .padding(20)

                Rectangle().fill(PoetTheme.divider).frame(height: 1)

                if !model.pauseDecisions.isEmpty {
                    PauseReviewStrip(highlightedPauseID: $highlightedPauseID) { pause in
                        guard let pause else { return }
                        let target = pause.beforeWordID ?? pause.afterWordID
                        if let target {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                transcriptProxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    Rectangle().fill(PoetTheme.divider).frame(height: 1)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(paragraphs) { paragraph in
                            HStack(alignment: .top, spacing: 18) {
                                Text(clock(paragraph.startTime))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(PoetTheme.faint)
                                    .frame(width: 42, alignment: .leading)
                                    .padding(.top, 7)
                                FlowLayout(spacing: 3) {
                                    ForEach(paragraph.words) { word in
                                        TranscriptToken(
                                            word: word,
                                            isSelected: model.selectedWordIDs.contains(word.id),
                                            pauseEdge: pauseEdge(for: word.id),
                                            coordinateSpace: selectionSpace
                                        )
                                        .id(word.id)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(24)
                    .padding(.bottom, model.selectedWordCount > 0 ? 54 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: selectionSpace)
                .onPreferenceChange(TranscriptTokenFrameKey.self) { tokenFrames = $0 }
                .simultaneousGesture(selectionGesture)
                .overlay(alignment: .bottom) {
                    if model.selectedWordCount > 0 {
                        SelectionActionBar()
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: model.selectedWordCount)

                Rectangle().fill(PoetTheme.divider).frame(height: 1)

                PlayerBar()
                    .padding(18)
                }
            }
        }
    }

    private func pauseEdge(for wordID: UUID) -> PauseHighlightEdge? {
        guard let pause = model.pauseDecisions.first(where: { $0.id == highlightedPauseID }) else { return nil }
        if pause.afterWordID == wordID { return .after }
        if pause.beforeWordID == wordID { return .before }
        return nil
    }

    private func clock(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d", max(0, Int(value)) / 60, max(0, Int(value)) % 60)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(selectionSpace))
            .onChanged { value in
                if dragAnchorID == nil {
                    dragAnchorID = wordID(at: value.startLocation)
                }
                guard let dragAnchorID,
                      let currentID = wordID(at: value.location) else { return }
                model.selectWords(from: dragAnchorID, through: currentID)
            }
            .onEnded { _ in dragAnchorID = nil }
    }

    private func wordID(at point: CGPoint) -> UUID? {
        tokenFrames.first(where: { $0.value.insetBy(dx: -2, dy: -2).contains(point) })?.key
    }
}

private struct TranscriptParagraph: Identifiable {
    let id: UUID
    let startTime: TimeInterval
    let words: [TranscriptWord]
}

private struct HeaderMetric: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(value).foregroundStyle(color).contentTransition(.numericText())
            Text(label).foregroundStyle(PoetTheme.faint)
        }
        .font(PoetTheme.utility(9, weight: .semibold))
    }
}

private struct TranscriptToken: View {
    @EnvironmentObject private var model: AppModel
    @State private var isHovered = false
    @State private var isPopping = false
    let word: TranscriptWord
    let isSelected: Bool
    let pauseEdge: PauseHighlightEdge?
    let coordinateSpace: String

    private var active: Bool {
        model.currentTime >= word.startTime && model.currentTime <= word.endTime
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                model.toggleWord(word)
                isPopping = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { isPopping = false }
            }
        } label: {
            StableTranscriptWordText(
                text: word.text,
                emphasized: active || isHovered,
                isRemoved: word.isRemoved
            )
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background {
                    if pauseEdge != nil {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: 0xCDBFEF).opacity(0.2))
                    } else if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PoetTheme.sage.opacity(0.3))
                    } else if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PoetTheme.sageDark)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PoetTheme.sageDark.opacity(0.9))
                    } else if word.isRemoved {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PoetTheme.amberDark.opacity(0.45))
                    }
                }
                .overlay {
                    if pauseEdge != nil {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(hex: 0xCDBFEF).opacity(0.82), lineWidth: 1)
                    }
                }
                .overlay(alignment: pauseEdge == .after ? .trailing : .leading) {
                    if pauseEdge != nil {
                        Capsule()
                            .fill(Color(hex: 0xF0D58A))
                            .frame(width: 3, height: 22)
                            .offset(x: pauseEdge == .after ? 5 : -5)
                            .shadow(color: Color(hex: 0xCDBFEF).opacity(0.45), radius: 5)
                    }
                }
                .overlay {
                    if isPopping {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((word.isRemoved ? PoetTheme.amber : PoetTheme.sage).opacity(0.12))
                            .scaleEffect(1.24)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if word.wasSuggested && !word.isRemoved {
                        Circle().fill(PoetTheme.sage).frame(width: 4, height: 4).offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPopping ? 1.12 : (isHovered ? 1.055 : 1))
        .offset(y: isHovered ? -2 : 0)
        .shadow(color: isHovered ? PoetTheme.sage.opacity(0.13) : .clear, radius: 10, y: 4)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: pauseEdge)
        .onHover { isHovered = $0 }
        .help(word.reason ?? (word.isRemoved ? "Restore word" : "Remove word"))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TranscriptTokenFrameKey.self,
                    value: [word.id: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }
}

private enum PauseHighlightEdge: Equatable {
    case before
    case after
}

/// Keeps the token's measured size constant while its visual weight changes.
/// Without this, each active-word transition reflows the layout, updates every
/// geometry preference, and can starve subsequent playback highlight updates.
private struct StableTranscriptWordText: View {
    let text: String
    let emphasized: Bool
    let isRemoved: Bool

    var body: some View {
        ZStack {
            label(weight: .regular)
                .opacity(emphasized ? 0 : 1)
            label(weight: .semibold)
                .opacity(emphasized ? 1 : 0)
        }
    }

    private func label(weight: Font.Weight) -> some View {
        Text(text)
            .font(PoetTheme.editorial(17, weight: weight))
            .strikethrough(isRemoved, color: PoetTheme.amber)
            .foregroundStyle(isRemoved ? PoetTheme.amber.opacity(0.72) : PoetTheme.cream)
    }
}

private struct TranscriptTokenFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SelectionActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("\(model.selectedWordCount) selected")
                .font(PoetTheme.utility(11, weight: .semibold))
                .foregroundStyle(PoetTheme.cream)
                .fixedSize()

            Rectangle().fill(PoetTheme.divider).frame(width: 1, height: 18)

            Button {
                model.setSelectedWordsRemoved(true)
            } label: {
                Label("Remove", systemImage: "strikethrough")
                    .fixedSize()
            }
            .foregroundStyle(PoetTheme.amber)

            Button {
                model.setSelectedWordsRemoved(false)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .fixedSize()
            }
            .foregroundStyle(PoetTheme.sage)

            Button {
                model.clearWordSelection()
            } label: {
                Image(systemName: "xmark")
                    .accessibilityLabel("Clear selection")
            }
            .foregroundStyle(PoetTheme.muted)
        }
        .font(PoetTheme.utility(11, weight: .semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .fixedSize(horizontal: true, vertical: false)
        .background(PoetTheme.elevated.opacity(0.98))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.48), radius: 20, y: 9)
    }
}

private struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PoetTheme.background)
                    .frame(width: 38, height: 38)
                    .background(PoetTheme.sage)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(time(model.currentTime))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PoetTheme.muted)

            if model.firstPassAudioURL != nil {
                HStack(spacing: 2) {
                    ForEach(EditPreviewMode.allCases) { mode in
                        Button(mode.rawValue) { model.selectEditPreview(mode) }
                            .buttonStyle(EditPreviewChoiceStyle(selected: model.editPreviewMode == mode))
                    }
                }
                .padding(3)
                .background(PoetTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .help(model.firstPassStatus ?? "Compare the untouched source with the timing-aligned first pass")
            }

            WaveformScrubber()
                .frame(height: 38)

            Text(time(model.duration))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PoetTheme.muted)
        }
    }

    private func time(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

private struct PauseReviewStrip: View {
    @EnvironmentObject private var model: AppModel
    @Binding var highlightedPauseID: UUID?
    let onHighlight: (PauseEditDecision?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("Confirmed pauses", systemImage: "waveform.badge.magnifyingglass")
                .font(PoetTheme.utility(9, weight: .semibold))
                .foregroundStyle(PoetTheme.muted)
                .fixedSize()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.pauseDecisions) { pause in
                        Button { model.togglePauseProtection(pause) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: pause.isProtected ? "lock.fill" : "arrow.right")
                                Text(pause.isProtected
                                     ? String(format: "Keep %.1fs", pause.originalDuration)
                                     : String(format: "%.1fs → %.1fs", pause.originalDuration, min(pause.originalDuration, model.pauseDuration)))
                            }
                            .font(PoetTheme.utility(9, weight: .semibold))
                            .foregroundStyle(pause.isProtected ? PoetTheme.muted : PoetTheme.sage)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background((pause.isProtected ? PoetTheme.elevated : PoetTheme.sageDark).opacity(0.95))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            highlightedPauseID = isHovering ? pause.id : nil
                            onHighlight(isHovering ? pause : nil)
                        }
                        .help("\(pause.reason) · \(Int(pause.confidence * 100))% confidence. Click to \(pause.isProtected ? "compact" : "protect") this pause.")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct EditPreviewChoiceStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoetTheme.utility(9, weight: .semibold))
            .foregroundStyle(selected ? PoetTheme.background : PoetTheme.muted)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(selected ? PoetTheme.sage : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct WaveformScrubber: View {
    @EnvironmentObject private var model: AppModel
    private let levels: [CGFloat] = [0.22, 0.42, 0.76, 0.38, 0.58, 0.9, 0.52, 0.34, 0.68, 0.84, 0.46, 0.64, 0.3, 0.7, 0.48, 0.8, 0.38, 0.56, 0.88, 0.44, 0.62, 0.28, 0.72, 0.52, 0.82, 0.35, 0.58, 0.74, 0.42, 0.68, 0.32, 0.6]

    var body: some View {
        GeometryReader { geometry in
            let progress = model.duration > 0 ? model.currentTime / model.duration : 0
            HStack(spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Double(index) / Double(levels.count) <= progress ? PoetTheme.sage : PoetTheme.faint.opacity(0.48))
                        .frame(maxWidth: .infinity)
                        .frame(height: 5 + 28 * level)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let ratio = min(max(value.location.x / geometry.size.width, 0), 1)
                model.seek(to: ratio * model.duration)
            })
        }
    }
}

private struct RecordingInfoPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PoetCard(padding: 18) {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel(text: "Recording")
                Rectangle().fill(PoetTheme.divider).frame(height: 1)
                InfoRow(label: "Original", value: duration(model.duration))
                InfoRow(label: "Edited", value: duration(model.estimatedEditedDuration), accent: true)
                InfoRow(label: "Words", value: "\(model.originalWordCount)")
                InfoRow(label: "Mode", value: model.editingMode.rawValue)
                InfoRow(label: "Pacing", value: model.pacing.rawValue)
                Rectangle().fill(PoetTheme.divider).frame(height: 1)
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(PoetTheme.sage)
                    Text("Edits are non-destructive. Your original recording is never changed.")
                        .font(PoetTheme.utility(10))
                        .foregroundStyle(PoetTheme.muted)
                        .lineSpacing(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func duration(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var accent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(PoetTheme.utility(11)).foregroundStyle(PoetTheme.muted)
            Spacer()
            Text(value)
                .font(PoetTheme.utility(11, weight: .semibold))
                .foregroundStyle(accent ? PoetTheme.sage : PoetTheme.cream)
                .lineLimit(1)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
