import Foundation

enum ArchiveReaderError: LocalizedError, Equatable {
    case cannotOpen(URL)
    case entryNotFound(String)
    case passwordProtected
    /// Internal sentinel — thrown by the partial-read consumer to stop
    /// ZIPFoundation's extract loop once enough bytes have been buffered.
    /// Caller swallows it.
    case prefixComplete

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return String(localized: "The archive could not be opened.")
        case .entryNotFound(let path):
            return String(localized: "The archive has no entry named \"\(path)\".")
        case .passwordProtected:
            return String(localized: "Password-protected archives are not supported.")
        case .prefixComplete:
            return nil
        }
    }
}

/// Random access to the entries of a comic archive. One actor per open
/// archive; pages address their bytes through it via
/// `ComicPageSource.archiveEntry`.
protocol ArchiveReader: Actor {
    /// Identifies the archive — `ComicPage` ids are derived from it, so it
    /// must be readable without hopping onto the actor.
    nonisolated var archiveURL: URL { get }

    /// Unique paths of every file entry (directories excluded), in archive order.
    func entryPaths() throws -> [String]

    func loadData(at path: String) throws -> Data

    /// Reads at least the first `maxBytes` of an entry (or the whole entry if
    /// it is smaller) without necessarily decompressing all of it.
    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data
}

/// Container format, identified by the file's leading magic bytes rather than
/// its extension: `.cbr` files that are really ZIPs (and vice versa) are
/// common in the wild, since many tools only rename the extension.
nonisolated enum ArchiveFormat: Sendable {
    case zip
    case rar

    private static let zipSignatures: [[UInt8]] = [
        [0x50, 0x4B, 0x03, 0x04],  // local file header
        [0x50, 0x4B, 0x05, 0x06],  // empty archive (end of central directory)
    ]
    /// `Rar!\x1A\x07` — shared prefix of the RAR 1.5–4.x and RAR 5 signatures.
    private static let rarSignature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]

    static func detect(at url: URL) -> ArchiveFormat? {
        if let header = readHeader(of: url) {
            if zipSignatures.contains(where: { header.starts(with: $0) }) { return .zip }
            if header.starts(with: rarSignature) { return .rar }
        }
        // Unreadable or unrecognised header — let the extension decide so the
        // reader surfaces a real "cannot open" error instead of silently
        // skipping the file.
        switch url.pathExtension.lowercased() {
        case "zip", "cbz": return .zip
        case "rar", "cbr": return .rar
        default: return nil
        }
    }

    static func openReader(for url: URL) throws -> any ArchiveReader {
        switch detect(at: url) {
        case .zip: return try ZIPArchiveReader(url: url)
        case .rar: return try RARArchiveReader(url: url)
        case nil: throw ArchiveReaderError.cannotOpen(url)
        }
    }

    private static func readHeader(of url: URL) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: rarSignature.count) else { return nil }
        return Array(data)
    }
}
