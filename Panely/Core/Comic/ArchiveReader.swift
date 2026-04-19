import Foundation
import ZIPFoundation

enum ArchiveReaderError: Error {
    case cannotOpen(URL)
    case entryNotFound(String)
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
}
