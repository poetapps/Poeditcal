import CryptoKit
import Combine
import Foundation

@MainActor
final class DenoiseModelStore: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading
        case installed
        case failed(String)
    }

    nonisolated static let modelFileName = "dpdfnet2_48khz_hr.onnx"
    nonisolated static let modelDisplayName = "Poet AI Noise Reduction"
    nonisolated static let downloadSize = 10_596_848
    nonisolated static let expectedSHA256 = "0b399f8a58dc4d70d8cd97541f5c39869406145193b957d00a03b66070944928"
    nonisolated static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/poetapps/PoetAudio/8e67a45bbd269bb530ff88a5c0fb69a7fd43db15/Resources/Models/dpdfnet2_48khz_hr.onnx"
    )!

    @Published private(set) var state: State

    private let installationDirectoryURL: URL
    private let downloadURL: URL
    private let requiredSHA256: String

    var isInstalled: Bool { state == .installed }
    var isDownloading: Bool { state == .downloading }

    var errorMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    init(
        installationDirectoryURL: URL = DenoiseModelStore.modelsDirectoryURL,
        downloadURL: URL = DenoiseModelStore.remoteURL,
        requiredSHA256: String = DenoiseModelStore.expectedSHA256
    ) {
        self.installationDirectoryURL = installationDirectoryURL
        self.downloadURL = downloadURL
        self.requiredSHA256 = requiredSHA256
        let modelURL = installationDirectoryURL.appendingPathComponent(Self.modelFileName)
        state = Self.modelIsValid(at: modelURL, expectedSHA256: requiredSHA256) ? .installed : .notInstalled
    }

    func install() async {
        guard !isDownloading else { return }
        state = .downloading

        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw InstallError.badServerResponse
            }
            guard try Self.sha256Digest(of: downloadedURL) == requiredSHA256 else {
                throw InstallError.checksumMismatch
            }

            let directory = installationDirectoryURL
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let stagedURL = directory.appendingPathComponent(".\(Self.modelFileName).download")
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.copyItem(at: downloadedURL, to: stagedURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)

            let destinationURL = modelURL
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
            }

            guard Self.modelIsValid(at: destinationURL, expectedSHA256: requiredSHA256) else {
                throw InstallError.checksumMismatch
            }
            state = .installed
        } catch is CancellationError {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        await install()
    }

    func refresh() {
        state = Self.modelIsValid(at: modelURL, expectedSHA256: requiredSHA256)
            ? .installed
            : .notInstalled
    }

    var modelURL: URL {
        installationDirectoryURL.appendingPathComponent(Self.modelFileName)
    }

    nonisolated static var modelsDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Poet Audio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static var installedModelURL: URL {
        modelsDirectoryURL.appendingPathComponent(modelFileName)
    }

    nonisolated static var installedModelExists: Bool {
        FileManager.default.fileExists(atPath: installedModelURL.path)
    }

    nonisolated static func installedModelIsValid() -> Bool {
        modelIsValid(at: installedModelURL, expectedSHA256: expectedSHA256)
    }

    nonisolated static func modelIsValid(at url: URL, expectedSHA256: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? sha256Digest(of: url)) == expectedSHA256
    }

    nonisolated static func sha256Digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum InstallError: LocalizedError {
    case badServerResponse
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .badServerResponse:
            "Poet couldn’t reach the noise-reduction download. Check your connection and try again."
        case .checksumMismatch:
            "The noise-reduction download could not be verified. Nothing was installed."
        }
    }
}
