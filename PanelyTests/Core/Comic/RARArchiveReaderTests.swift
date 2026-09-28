import Testing
import Foundation
import ImageIO
@testable import Panely

struct RARArchiveReaderTests {

    private func pixelSize(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Non-solid RAR 5

    @Test func listsEntriesOfRAR5Archive() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        let paths = try await reader.entryPaths()

        #expect(Set(paths) == ["01.png", "02.png", "10.png"])
        #expect(reader.isSolid == false)
    }

    @Test func loadDataReturnsDecodableEntry() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        let data = try await reader.loadData(at: "10.png")

        #expect(pixelSize(of: data) == CGSize(width: 90, height: 120))
    }

    /// The prefix must be a true prefix of the entry — the early stop is done
    /// by cancelling UnrarKit's `NSProgress`, which must not leak as an error.
    @Test func loadDataPrefixReturnsLeadingBytes() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        let full = try await reader.loadData(at: "10.png")
        let prefix = try await reader.loadDataPrefix(at: "10.png", maxBytes: 64)

        #expect(prefix.count >= 64)
        #expect(full.starts(with: prefix))
    }

    @Test func loadDataPrefixReturnsWholeEntryWhenSmallerThanMax() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        let full = try await reader.loadData(at: "01.png")
        let prefix = try await reader.loadDataPrefix(at: "01.png", maxBytes: 10_000_000)

        #expect(prefix == full)
    }

    @Test func missingEntryThrowsEntryNotFound() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        await #expect(throws: ArchiveReaderError.self) {
            _ = try await reader.loadData(at: "missing.png")
        }
        await #expect(throws: ArchiveReaderError.self) {
            _ = try await reader.loadDataPrefix(at: "missing.png", maxBytes: 10)
        }
    }

    // MARK: - Solid RAR 5

    /// Solid archives are served from a one-time extraction; every entry,
    /// including the last one in the solid stream, must still read correctly.
    @Test func solidArchiveServesEntriesFromExtraction() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5-solid.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        #expect(reader.isSolid)

        let last = try await reader.loadData(at: "10.png")
        let first = try await reader.loadData(at: "01.png")
        let prefix = try await reader.loadDataPrefix(at: "10.png", maxBytes: 64)

        #expect(pixelSize(of: last) == CGSize(width: 90, height: 120))
        #expect(pixelSize(of: first) == CGSize(width: 12, height: 34))
        #expect(prefix.count == 64)
        #expect(last.starts(with: prefix))
    }

    @Test func solidArchiveMissingEntryThrowsEntryNotFound() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5-solid.cbr", in: workDir)

        let reader = try RARArchiveReader(url: url)
        await #expect(throws: ArchiveReaderError.self) {
            _ = try await reader.loadData(at: "../01.png")
        }
    }

    // MARK: - RAR 4

    @Test func readsRAR4Archive() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar4.rar", in: workDir)

        let reader = try RARArchiveReader(url: url)
        let paths = try await reader.entryPaths()
        #expect(Set(paths) == ["Test File A.txt", "Test File B.jpg", "Test File C.m4a"])

        let data = try await reader.loadData(at: "Test File B.jpg")
        #expect(pixelSize(of: data) != nil)
    }

    // MARK: - Passwords

    @Test func encryptedEntryDataThrowsPasswordProtected() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5-password.rar", in: workDir)

        let reader = try RARArchiveReader(url: url)
        let paths = try await reader.entryPaths()
        let first = try #require(paths.first)

        await #expect(throws: ArchiveReaderError.passwordProtected) {
            _ = try await reader.loadData(at: first)
        }
    }

    @Test func encryptedHeadersThrowPasswordProtected() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar4-header-password.rar", in: workDir)

        let reader = try RARArchiveReader(url: url)
        await #expect(throws: ArchiveReaderError.passwordProtected) {
            _ = try await reader.entryPaths()
        }
    }

    // MARK: - Opening

    @Test func nonRARFileCannotBeOpened() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.writeFile(workDir.appendingPathComponent("junk.cbr"), bytes: [1, 2, 3, 4, 5, 6, 7, 8])

        #expect(throws: ArchiveReaderError.self) {
            _ = try RARArchiveReader(url: url)
        }
    }
}

struct ArchiveFormatTests {

    @Test func detectsZIPByContentDespiteCBRExtension() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let src = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: src) }
        try Fixture.writeFile(src.appendingPathComponent("001.png"))
        let url = workDir.appendingPathComponent("mislabeled.cbr")
        try Fixture.zipDirectory(src, to: url)

        #expect(ArchiveFormat.detect(at: url) == .zip)
    }

    @Test func detectsRARByContentDespiteCBZExtension() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar5.cbr", in: workDir, as: "mislabeled.cbz")

        #expect(ArchiveFormat.detect(at: url) == .rar)
    }

    @Test func detectsRAR4Signature() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Fixture.bundledArchive("panely-rar4.rar", in: workDir, as: "book.bin")

        #expect(ArchiveFormat.detect(at: url) == .rar)
    }

    @Test func fallsBackToExtensionForUnrecognisedContent() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let cbr = try Fixture.writeFile(workDir.appendingPathComponent("junk.cbr"), bytes: [0, 1, 2])
        let cbz = try Fixture.writeFile(workDir.appendingPathComponent("junk.cbz"), bytes: [0, 1, 2])
        let txt = try Fixture.writeFile(workDir.appendingPathComponent("junk.txt"), bytes: [0, 1, 2])

        #expect(ArchiveFormat.detect(at: cbr) == .rar)
        #expect(ArchiveFormat.detect(at: cbz) == .zip)
        #expect(ArchiveFormat.detect(at: txt) == nil)
    }
}
