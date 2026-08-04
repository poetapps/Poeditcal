import SwiftUI

struct DenoiseModelSetupView: View {
    @EnvironmentObject private var denoiseModel: DenoiseModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(PoetTheme.sageDark)
                    .frame(width: 82, height: 82)
                Image(systemName: "waveform.badge.minus")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(PoetTheme.sage)
            }

            VStack(spacing: 9) {
                Text("Add AI noise reduction")
                    .font(PoetTheme.editorial(30, weight: .regular))
                Text("Download Poet’s local noise-removal model to reduce steady room tone and fan noise. Audio stays on this Mac.")
                    .font(PoetTheme.utility(12))
                    .foregroundStyle(PoetTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: 9) {
                Label("10.6 MB one-time download", systemImage: "arrow.down.circle")
                Label("Stored in Application Support", systemImage: "internaldrive")
                Label("Cryptographically verified before installation", systemImage: "checkmark.shield")
            }
            .font(PoetTheme.utility(10, weight: .medium))
            .foregroundStyle(PoetTheme.muted)
            .frame(maxWidth: 330, alignment: .leading)

            if let error = denoiseModel.errorMessage {
                Text(error)
                    .font(PoetTheme.utility(11, weight: .medium))
                    .foregroundStyle(PoetTheme.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            HStack(spacing: 12) {
                Button("Not now") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(denoiseModel.isDownloading)

                Button {
                    Task {
                        await denoiseModel.install()
                        if denoiseModel.isInstalled { dismiss() }
                    }
                } label: {
                    if denoiseModel.isDownloading {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Downloading…")
                        }
                    } else {
                        Label(denoiseModel.errorMessage == nil ? "Download & install" : "Try again", systemImage: "arrow.down")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(denoiseModel.isDownloading)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(34)
        .frame(width: 570)
        .frame(minHeight: 520)
        .background(PoetTheme.background)
    }
}
