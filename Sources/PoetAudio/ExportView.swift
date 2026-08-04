import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        PoetCard(padding: 22) {
                            VStack(alignment: .leading, spacing: 18) {
                                SectionLabel(text: "Files to include")
                                ExportToggle(title: "Finished audio", detail: "The edited and polished recording", icon: "waveform", isOn: $model.exportAudio)
                                if model.audioURL != nil {
                                    ExportToggle(
                                        title: "Unmodified original",
                                        detail: "An exact copy with no edits or processing",
                                        icon: "waveform.path",
                                        isOn: $model.exportOriginal
                                    )
                                }
                                Rectangle().fill(PoetTheme.divider).frame(height: 1)
                                ExportToggle(title: "Plain transcript", detail: "Readable .txt without timestamps", icon: "doc.plaintext", isOn: $model.exportTXT)
                                ExportToggle(title: "SRT subtitles", detail: "Timed captions for most video platforms", icon: "captions.bubble", isOn: $model.exportSRT)
                                ExportToggle(title: "WebVTT subtitles", detail: "Timed captions for web players", icon: "text.bubble", isOn: $model.exportVTT)
                            }
                        }

                        PoetCard(padding: 22) {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionLabel(text: "Audio finish")
                                HStack(spacing: 10) {
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
                                    .font(PoetTheme.utility(11))
                                    .foregroundStyle(PoetTheme.muted)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    PoetCard(padding: 24) {
                        VStack(alignment: .leading, spacing: 20) {
                            SectionLabel(text: "What changed")

                            HStack(spacing: 20) {
                                SummaryNumber(value: "\(model.removedWords)", label: "words removed")
                                SummaryNumber(value: shortDuration(model.duration - model.estimatedEditedDuration), label: "time saved")
                                SummaryNumber(value: "\(model.enabledPolishCount)", label: "polish steps")
                            }

                            Rectangle().fill(PoetTheme.divider).frame(height: 1)

                            VStack(alignment: .leading, spacing: 9) {
                                Text(model.fileName)
                                    .font(PoetTheme.utility(14, weight: .semibold))
                                HStack(spacing: 8) {
                                    Image(systemName: "clock")
                                    Text("\(shortDuration(model.duration)) → \(shortDuration(model.estimatedEditedDuration))")
                                }
                                .font(PoetTheme.utility(11))
                                .foregroundStyle(PoetTheme.muted)
                            }

                            Spacer()

                            if let status = model.exportStatus {
                                HStack(spacing: 8) {
                                    Image(systemName: status.hasPrefix("Couldn’t") ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    Text(status)
                                }
                                .font(PoetTheme.utility(11, weight: .medium))
                                .foregroundStyle(status.hasPrefix("Couldn’t") ? PoetTheme.error : PoetTheme.sage)
                            }

                            Button {
                                model.exportPackage()
                            } label: {
                                HStack {
                                    Image(systemName: model.isExporting ? "hourglass" : "arrow.down.circle.fill")
                                    Text(model.isExporting ? "Rendering…" : "Export package")
                                    Spacer()
                                    if model.isExporting {
                                        ProgressView().controlSize(.small).tint(PoetTheme.background)
                                    } else {
                                        Image(systemName: "arrow.right")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.isExporting || !model.hasExportSelection)

                            if !model.hasExportSelection {
                                Text("Choose at least one file to export.")
                                    .font(PoetTheme.utility(9, weight: .medium))
                                    .foregroundStyle(PoetTheme.amber)
                            }

                            Text(model.isDemoTranscript ? "The interface sample can export transcript sidecars. Choose a recording to render finished audio." : "Finished audio is rendered as a lossless WAV. The optional original is copied byte-for-byte in its source format.")
                                .font(PoetTheme.utility(9))
                                .foregroundStyle(PoetTheme.faint)
                                .lineSpacing(2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 500)
            }
            .padding(.horizontal, 38)
            .padding(.top, 62)
            .padding(.bottom, 42)
        }
    }

    private func shortDuration(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", max(0, Int(value)) / 60, max(0, Int(value)) % 60)
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
                Circle().fill(isOn ? PoetTheme.sageDark : PoetTheme.elevated).frame(width: 38, height: 38)
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(isOn ? PoetTheme.sage : PoetTheme.muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PoetTheme.utility(13, weight: .semibold))
                Text(detail).font(PoetTheme.utility(10)).foregroundStyle(PoetTheme.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(PoetTheme.sage)
        }
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
        .font(PoetTheme.utility(10, weight: .semibold))
        .foregroundStyle(enabled ? PoetTheme.sage : PoetTheme.faint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(enabled ? PoetTheme.sageDark : PoetTheme.elevated)
        .clipShape(Capsule())
    }
}

private struct SummaryNumber: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(PoetTheme.editorial(25)).foregroundStyle(PoetTheme.cream)
            Text(label).font(PoetTheme.utility(9, weight: .medium)).foregroundStyle(PoetTheme.muted)
        }
    }
}
