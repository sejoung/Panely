import Foundation
import ZIPFoundation

enum ArchiveReaderError: Error {
    case cannotOpen(URL)
    case entryNotFound(String)
    /// Internal sentinel — thrown by the partial-read consumer to stop
    /// ZIPFoundation's extract loop once enough bytes have been buffered.
    /// Caller swallows it.
    case prefixComplete
}

actor ArchiveReader {
    let archiveURL: URL
    private let archive: Archive

    init(url: URL) throws {
        self.archiveURL = url
        do {
            self.archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ArchiveReaderError.cannotOpen(url)
        }
    }

    func entryPaths() -> [String] {
        archive.compactMap { entry in
            entry.type == .file ? entry.path : nil
        }
    }

    func loadData(at path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw ArchiveReaderError.entryNotFound(path)
        }
        var buffer = Data()
        _ = try archive.extract(entry) { chunk in
            buffer.append(chunk)
        }
        return buffer
    }

    /// Reads at most `maxBytes` of an entry by stopping the extract early.
    /// Used by `ImageLoader.dimensions` to decode the image header without
    /// decompressing the whole entry (a 5 MB image otherwise costs the full
    /// 5 MB of disk + decompression just to read width/height).
    /// `skipCRC32: true` because we're not reading the whole stream and
    /// the checksum can't be validated.
    func loadDataPrefix(at path: String, maxBytes: Int) throws -> Data {
        guard let entry = archive[path] else {
            throw ArchiveReaderError.entryNotFound(path)
        }
        var buffer = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                buffer.append(chunk)
                if buffer.count >= maxBytes {
                    throw ArchiveReaderError.prefixComplete
                }
            }
        } catch ArchiveReaderError.prefixComplete {
            // expected — we got our prefix and bailed early
        }
        return buffer
    }
}
