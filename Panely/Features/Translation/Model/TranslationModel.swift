import CryptoKit
import Foundation

/// The model that translates the balloons: Google's Gemma 4 E2B, instruction
/// tuned, QAT 4-bit, as the GGUF file Google publishes — run in the app by
/// llama.cpp (`GemmaTranslator`).
///
/// One model for every language pair and no modes: it reads a page's
/// balloons together with the lines before them, so names, who's speaking
/// and their speech level carry over, which Apple Translation's sentence at a
/// time couldn't do (it needed a second model to put casual lines back into
/// casual speech). Measured on an M1 Pro: ~0.24 s a balloon on the GPU, a
/// 16-balloon prompt in under 4 s.
///
/// Not part of the app: downloaded once, from the translation panel or
/// Settings, by `TranslationModelStore`. Pinned to one revision, size and
/// hash — the same file the Windows version uses.
nonisolated struct TranslationModel: Sendable, Equatable {
    let id: String
    let displayName: String
    let revision: String
    let fileName: String
    let bytes: Int64
    let sha256: String
    let url: URL
    let license: String

    static let gemma4E2B = TranslationModel(
        id: "gemma-4-e2b-it-q4_0",
        displayName: "Gemma 4 E2B",
        revision: "675cff42a74c774d6cb76f76d8eacb49b48c9b93",
        fileName: "gemma-4-E2B_q4_0-it.gguf",
        bytes: 3_349_516_256,
        sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634",
        url: URL(string: "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/675cff42a74c774d6cb76f76d8eacb49b48c9b93/gemma-4-E2B_q4_0-it.gguf")!,
        license: "Apache-2.0"
    )

    static let current = gemma4E2B

    /// Bump when the prompt changes how balloons come out: it's part of
    /// `cacheRevision`, so books are translated again the new way.
    static let promptVersion = 1

    /// What the cache keys on: translations from another model, revision or
    /// prompt (or from Apple Translation, before this) aren't reused.
    static var cacheRevision: String {
        "\(current.id)@\(current.revision.prefix(12))+p\(promptVersion)"
    }
}

/// Where the model file lives and whether it's there.
///
/// Application Support, not Caches: it's 3.3 GB to download again, and the
/// system may empty Caches when space runs low.
nonisolated struct TranslationModelFiles: Sendable {
    let root: URL
    let model: TranslationModel

    init(root: URL = TranslationModelFiles.defaultRoot(), model: TranslationModel = .current) {
        self.root = root
        self.model = model
    }

    static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("panely-models", isDirectory: true)
    }

    var directory: URL { root.appendingPathComponent(model.id, isDirectory: true) }
    var fileURL: URL { directory.appendingPathComponent(model.fileName) }

    /// Present at the pinned size. The hash is checked once, when the file
    /// is downloaded — hashing 3.3 GB on every launch would take seconds.
    var isInstalled: Bool {
        Self.size(of: fileURL) == model.bytes
    }

    /// Check a downloaded file against the pinned size and hash and move it
    /// into place, replacing any earlier copy.
    func install(downloadedFile file: URL) throws {
        let size = Self.size(of: file) ?? -1
        guard size == model.bytes else {
            throw TranslationModelError.sizeMismatch(expected: model.bytes, actual: size)
        }
        let digest = try Self.sha256(of: file)
        guard digest == model.sha256 else { throw TranslationModelError.hashMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: file, to: fileURL)
    }

    /// Remove the model; returns the bytes freed.
    @discardableResult
    func remove() -> Int64 {
        let size = Self.size(of: fileURL) ?? 0
        try? FileManager.default.removeItem(at: directory)
        return size
    }

    /// From the file system each time — a URL's resource values are cached.
    private static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    /// Lowercase hex SHA-256, read in 8 MB pieces so a 3.3 GB file never
    /// sits in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum TranslationModelError: LocalizedError, Equatable {
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case notInstalled
    case loadFailed
    case promptTooLong(tokens: Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .sizeMismatch, .hashMismatch:
            String(localized: "The downloaded model file is damaged. Download it again.", bundle: .localized)
        case .notInstalled:
            String(localized: "The translation model isn't downloaded.", bundle: .localized)
        case .loadFailed:
            String(localized: "The translation model couldn't be loaded.", bundle: .localized)
        case let .promptTooLong(tokens):
            "Prompt too long for the model context (\(tokens) tokens)."
        case let .decodeFailed(code):
            "llama.cpp decode failed (\(code))."
        }
    }
}
