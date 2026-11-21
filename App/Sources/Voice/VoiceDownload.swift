import AppleArchive
import CryptoKit
import Foundation
import Observation
import System

/// Downloads the natural voices (Kyutai Pocket TTS as converted for MB Books,
/// about 150 MB) once, from a button in Settings, instead of shipping them in
/// every update. Each file is pinned by SHA-256. They live in Application
/// Support, outside backups, and updates never touch them.
@Observable
final class VoiceDownload {
    static let shared = VoiceDownload()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case failed(String)
        case ready
    }

    struct File {
        let name: String
        let sha256: String
        let bytes: Int64
    }

    nonisolated static let release = "pocket-tts-2026-09-v2"
    private static let base = URL(string: "https://github.com/Marginally-Better-Apps/mb-books/releases/download/\(release)/")!

    // From the release; licenses in THIRD_PARTY_NOTICES.md.
    static let files: [File] = [
        File(name: "FlowLM.mlmodelc.aar", sha256: "439f66a2d9f4e6b7153e6c29a6caf5b67481353065d6cae7fd3ebcf10de421d3", bytes: 78_425_264),
        File(name: "Mimi.mlmodelc.aar", sha256: "4a256260f1140501e6a37380e2f4f6c4a0f831cc906f331c5a21e56dc5180bda", bytes: 19_087_174),
        File(name: "george.bin", sha256: "9b06e8d3646331636a84c24845c1593d9eb246bd0da7840747d3b36031bc5151", bytes: 3_121_156),
        File(name: "mary.bin", sha256: "1740b9d73afa4a0529776497e46be8c7915663fabf5a18f3a7c526e6d9bef109", bytes: 3_096_580),
        File(name: "jane.bin", sha256: "e59573117c9691d678b8e33a06dc8b9aa0d144bbce053e484130318c44a12268", bytes: 3_686_404),
        File(name: "eve.bin", sha256: "365e49642468345193c24d1a2ab9983dc2aac753c758d1fb8cb681742906f93e", bytes: 3_268_612),
        File(name: "anna.bin", sha256: "f3ad084cdc6205763760c2dad0c0412a02cc6000ae3daee1786c7b86a79229cd", bytes: 3_907_588),
        File(name: "eponine.bin", sha256: "f0e93f1f629a6bed3b69d589d209cf1d4d9a9458cc17838b293f38e52fdf675e", bytes: 3_465_220),
        File(name: "vera.bin", sha256: "7a3ebbf5dfd9e5460421d4b0f4e79c9a7e84d82bc2b7e8a90c8336fa3bd817b4", bytes: 3_366_916),
        File(name: "michael.bin", sha256: "abe2e708f6ce6c940e1a033e71337bf622a5619d8c749e79858fc9e8703f6731", bytes: 3_637_252),
        File(name: "fantine.bin", sha256: "6a5dabb9ca3734942e996b28ec851bebfcaecfb53543331fc1204a7d5de8b002", bytes: 3_268_612),
        File(name: "azelma.bin", sha256: "cef7ae49ac00f04bdfb087182092cd8364662c8df452cfad9c56496b37e24715", bytes: 3_981_316),
        File(name: "bill_boerst.bin", sha256: "e8363bb705847a0749aad4a40eb612c4eea6b47fe26dafd6ea37815a0e470857", bytes: 3_366_916),
        File(name: "caro_davy.bin", sha256: "ffcac16ad0324f1c7d1b3bd4453ee10023929841bf085e2813b9429d5c4b61be", bytes: 2_629_636),
        File(name: "peter_yearsley.bin", sha256: "7f31598e4f199c4f9df2af532ac0ad29cdd2d92c78f9bd6b32f46e1e388e8684", bytes: 1_867_780),
        File(name: "alba.bin", sha256: "1e42a1b340f766e3d60c9e9a8db255f98e8b2846bae4c508a4a67dbe111e5a00", bytes: 3_096_580),
        File(name: "charles.bin", sha256: "3200cd37013513b8c6ba1b722366429224a30dfaa5bd49036365a3e782297d34", bytes: 3_096_580),
        File(name: "paul.bin", sha256: "fa84e90f5ee9c83a44ee156f48a3187f544be45aae97b3a1dc5df2232509e183", bytes: 3_489_796),
        File(name: "stuart_bell.bin", sha256: "b270ede3ecc0003d3ccce67174a691e61ae520d539c4e7ad98001d46263b3665", bytes: 2_629_636),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Holds FlowLM.mlmodelc, Mimi.mlmodelc and voices/ once installed.
    nonisolated static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Voices/\(release)", directoryHint: .isDirectory)
    }

    private nonisolated static var marker: URL { directory.appending(path: ".complete") }
    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    private(set) var state: State
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {
        state = Self.isInstalled ? .ready : .missing
    }

    func start() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        task = Task {
            do {
                try await install()
                state = .ready
                NaturalVoiceEngine.shared.prewarm()
            } catch _ where Task.isCancelled {
                // Cancel: URLSession reports it as URLError.cancelled, not a failure.
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Frees the space; iPhone voices take over.
    func remove() {
        cancel()
        try? FileManager.default.removeItem(at: Self.directory)
        state = .missing
    }

    // MARK: Install

    private func install() async throws {
        let fileManager = FileManager.default
        let root = Self.directory
        let downloads = root.appending(path: "downloads", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "voices"), withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var rootURL = root
        try rootURL.setResourceValues(excluded)

        var done: Int64 = 0
        for file in Self.files {
            try Task.checkCancellation()
            let local = downloads.appending(path: file.name)
            // A file kept from an interrupted attempt is reused if it checks out.
            if !(fileManager.fileExists(atPath: local.path) && (try? Self.sha256(of: local)) == file.sha256) {
                try? fileManager.removeItem(at: local)
                try await download(Self.base.appending(path: file.name), to: local) { fraction in
                    self.state = .downloading(Double(done + Int64(Double(file.bytes) * fraction)) / Double(Self.totalBytes))
                }
                guard try Self.sha256(of: local) == file.sha256 else {
                    try? fileManager.removeItem(at: local)
                    throw DownloadError.checksum(file.name)
                }
            }
            if file.name.hasSuffix(".mlmodelc.aar") {
                try Self.unpack(local, model: String(file.name.dropLast(".aar".count)), into: root)
            } else {
                let destination = root.appending(path: "voices/\(file.name)")
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: local, to: destination)
            }
            try? fileManager.removeItem(at: local)
            done += file.bytes
            state = .downloading(Double(done) / Double(Self.totalBytes))
        }
        try? fileManager.removeItem(at: downloads)
        try Data().write(to: Self.marker)
    }

    /// Downloads one file, reporting progress, and moves it into place.
    private func download(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                    do {
                        if let error { throw error }
                        guard let temporary, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                        }
                        // The temporary file is deleted when this handler returns.
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                Task { @MainActor in
                    while task.state == .running {
                        progress(task.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks an Apple Archive holding `model` (a compiled Core ML model) into `root`.
    nonisolated static func unpack(_ archive: URL, model: String, into root: URL) throws {
        let fileManager = FileManager.default
        let staging = root.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)) else {
            throw DownloadError.unpack(model)
        }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw DownloadError.unpack(model) }
        defer { try? decompressed.close() }
        guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw DownloadError.unpack(model) }
        defer { try? decoded.close() }
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(staging.path), flags: [.ignoreOperationNotPermitted]) else {
            throw DownloadError.unpack(model)
        }
        defer { try? extractor.close() }
        _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extractor)

        let candidates = [staging.appending(path: model)] + ((try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: model) }
        guard let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw DownloadError.unpack(model)
        }
        let destination = root.appending(path: model)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: found, to: destination)
    }

    enum DownloadError: LocalizedError {
        case http(Int)
        case checksum(String)
        case unpack(String)

        var errorDescription: String? {
            switch self {
            case .http(let status): "The download failed (HTTP \(status)). Try again."
            case .checksum(let name): "\(name) didn't match its checksum. Try again."
            case .unpack(let name): "Couldn't unpack \(name)."
            }
        }
    }
}

nonisolated private final class TaskBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
}
