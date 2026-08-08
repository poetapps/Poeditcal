import AVKit
import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                filesPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                summaryPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 560)
            .padding(.horizontal, 48)
            .padding(.top, 72)
            .padding(.bottom, 38)
        }
    }

    private var filesPanel: some View {
        ExportPanel {
            VStack(alignment: .leading, spacing: 0) {
                ExportHeading(title: "Files to include")
                    .padding(.bottom, 14)

                ExportToggle(
                    title: "Finished audio",
                    detail: "The edited and polished recording",
                    icon: "waveform",
                    isOn: $model.exportAudio
                )
                ExportDivider()

                if model.audioURL != nil {
                    ExportToggle(
                        title: "Unmodified original",
                        detail: "An exact copy with no edits or processing",
                        icon: "waveform.path",
                        isOn: $model.exportOriginal
                    )
                    ExportDivider()
                }

                ExportToggle(
                    title: "Plain transcript",
                    detail: "Readable .txt without timestamps",
                    icon: "doc.plaintext",
                    isOn: $model.exportTXT
                )
                ExportDivider()

                ExportToggle(
                    title: "SRT subtitles",
                    detail: "Timed captions for most video platforms",
                    icon: "captions.bubble",
                    isOn: $model.exportSRT
                )
                ExportDivider()

                ExportToggle(
                    title: "WebVTT subtitles",
                    detail: "Timed captions for web players",
                    icon: "text.bubble",
                    isOn: $model.exportVTT
                )

                if model.isVideoProject {
                    ExportDivider()
                    ExportToggle(
                        title: "Editable Premiere + Resolve timelines",
                        detail: "Reversible cuts with full-length polished audio",
                        icon: "timeline.selection",
                        isOn: $model.exportEditableTimelines
                    )
                    ExportDivider()
                    ExportToggle(
                        title: "Finished video",
                        detail: "Rendered MOV with Poet's cuts and polished audio",
                        icon: "film",
                        isOn: $model.exportFinishedVideo
                    )
                }

                Spacer(minLength: 18)

                ExportDivider()
                    .padding(.bottom, 20)

                audioFinish
            }
        }
    }

    private var audioFinish: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExportHeading(title: "Audio finish", compact: true)

            HStack(spacing: 8) {
                FinishChip(label: "Transcript edit", enabled: true)
                FinishChip(label: String(format: "%.1fs pauses", model.pauseDuration), enabled: true)
                FinishChip(label: "Voice polish", enabled: model.usePolish)
            }

            if model.usePolish {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.polishSelections.map(\.rawValue).sorted().joined(separator: " · "))
                    Text("\(model.loudnessPreset.rawValue) delivery · \(model.loudnessPreset.detail)")
                        .foregroundStyle(PoetTheme.sage)
                }
                .font(PoetTheme.utility(10))
                .foregroundStyle(PoetTheme.muted)
                .lineSpacing(2)
            }
        }
    }

    private var summaryPanel: some View {
        ExportPanel {
            VStack(alignment: .leading, spacing: 0) {
                ExportHeading(title: "What changed")
                    .padding(.bottom, 22)

                HStack(spacing: 0) {
                    SummaryNumber(
                        value: "\(model.removedWords)",
                        label: "words removed",
                        icon: "textformat"
                    )
                    SummaryDivider()
                    SummaryNumber(
                        value: shortDuration(model.duration - model.estimatedEditedDuration),
                        label: "time saved",
                        icon: "clock"
                    )
                    SummaryDivider()
                    SummaryNumber(
                        value: "\(model.enabledPolishCount)",
                        label: "polish steps",
                        icon: "wand.and.stars"
                    )
                }

                ExportDivider()
                    .padding(.vertical, 22)

                sourceFile

                if let videoPlayer = model.videoPreviewPlayer {
                    ExportDivider()
                        .padding(.vertical, 22)

                    videoPreview(videoPlayer)
                }

                Spacer(minLength: 26)

                if let status = model.exportStatus {
                    ExportStatus(message: status)
                        .padding(.bottom, 12)
                }

                exportAction
            }
        }
    }

    private var sourceFile: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(PoetTheme.elevated)
                Image(systemName: model.isVideoProject ? "film" : "waveform")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(PoetTheme.sage)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 7) {
                Text(model.fileName)
                    .font(PoetTheme.utility(14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Image(systemName: "clock")
                    Text(shortDuration(model.duration))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(PoetTheme.faint)
                    Text(shortDuration(model.estimatedEditedDuration))
                        .foregroundStyle(PoetTheme.sage)
                }
                .font(PoetTheme.utility(10, weight: .medium))
                .foregroundStyle(PoetTheme.muted)
            }

            Spacer(minLength: 0)
        }
    }

    private func videoPreview(_ player: AVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edited video preview")
                    .font(PoetTheme.utility(10, weight: .semibold))
                Spacer()
                Text(shortDuration(model.estimatedEditedDuration))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(PoetTheme.muted)
            }

            ZStack {
                VideoPlayer(player: player)
                    .aspectRatio(
                        model.videoInfo.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? (16 / 9),
                        contentMode: .fit
                    )
                    .frame(maxHeight: 230)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)

                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PoetTheme.background)
                        .frame(width: 48, height: 48)
                        .background(PoetTheme.sage)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.38), radius: 14, y: 5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var exportAction: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                model.exportPackage()
            } label: {
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .stroke(PoetTheme.background.opacity(0.65), lineWidth: 1.3)
                            .frame(width: 32, height: 32)
                        Image(systemName: model.isExporting ? "hourglass" : "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(model.isExporting ? "Rendering…" : "Export package")
                    Spacer()
                    if model.isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(PoetTheme.background)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ExportButtonStyle())
            .disabled(model.isExporting || !model.hasExportSelection)

            Text(model.hasExportSelection ? exportExplanation : "Choose at least one file to export.")
                .font(PoetTheme.utility(9, weight: .medium))
                .foregroundStyle(model.hasExportSelection ? PoetTheme.muted : PoetTheme.amber)
                .lineSpacing(2)
        }
        .padding(16)
        .background(PoetTheme.sageDark.opacity(0.52))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PoetTheme.sage.opacity(0.2), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func shortDuration(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", max(0, Int(value)) / 60, max(0, Int(value)) % 60)
    }

    private var exportExplanation: String {
        if model.isDemoTranscript {
            return "The interface sample can export transcript sidecars. Choose media to render finished audio."
        }
        if model.isVideoProject && model.exportEditableTimelines {
            return "Timeline export includes the full source video and a full-length polished WAV. Every cut remains extendable in Premiere or Resolve."
        }
        return "Finished audio is rendered as a lossless WAV. The optional original is copied byte-for-byte in its source format."
    }
}

private struct ExportPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PoetTheme.card)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }
}

private struct ExportHeading: View {
    let title: String
    var compact = false

    var body: some View {
        Text(title)
            .font(PoetTheme.utility(compact ? 15 : 17, weight: .bold))
            .foregroundStyle(PoetTheme.cream)
    }
}

private struct ExportDivider: View {
    var body: some View {
        Rectangle()
            .fill(PoetTheme.divider)
            .frame(height: 1)
    }
}

private struct ExportToggle: View {
    let title: String
    let detail: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(isOn ? PoetTheme.sageDark : PoetTheme.elevated)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? PoetTheme.sage : PoetTheme.muted)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PoetTheme.utility(12, weight: .semibold))
                    .foregroundStyle(PoetTheme.cream)
                Text(detail)
                    .font(PoetTheme.utility(9))
                    .foregroundStyle(PoetTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(PoetTheme.sage)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 11)
    }
}

private struct FinishChip: View {
    let label: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: enabled ? "checkmark" : "minus")
            Text(label)
        }
        .font(PoetTheme.utility(9, weight: .semibold))
        .foregroundStyle(enabled ? PoetTheme.sage : PoetTheme.faint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(enabled ? PoetTheme.sageDark : PoetTheme.elevated)
        .clipShape(Capsule())
    }
}

private struct SummaryNumber: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(PoetTheme.sageDark)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PoetTheme.sage)
            }
            .frame(width: 27, height: 27)

            Text(value)
                .font(PoetTheme.utility(24, weight: .bold))
                .foregroundStyle(PoetTheme.cream)
            Text(label)
                .font(PoetTheme.utility(9, weight: .medium))
                .foregroundStyle(PoetTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SummaryDivider: View {
    var body: some View {
        Rectangle()
            .fill(PoetTheme.divider)
            .frame(width: 1, height: 72)
    }
}

private struct ExportStatus: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle.fill")
            Text(message)
        }
        .font(PoetTheme.utility(10, weight: .medium))
        .foregroundStyle(isError ? PoetTheme.error : PoetTheme.sage)
    }

    private var isError: Bool { message.hasPrefix("Couldn’t") }
}

private struct ExportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoetTheme.utility(14, weight: .semibold))
            .foregroundStyle(PoetTheme.background)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(PoetTheme.sage.opacity(configuration.isPressed ? 0.76 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.988 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
