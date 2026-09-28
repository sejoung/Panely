import Testing
@testable import Panely

struct LoaderExtensionTests {
    @Test func folderLoaderSupportsCommonImageFormats() {
        let exts = FolderLoader.supportedExtensions
        #expect(exts.contains("jpg"))
        #expect(exts.contains("png"))
        #expect(exts.contains("webp"))
        #expect(exts.contains("heic"))
        #expect(exts.contains("gif"))
    }

    @Test func cbzLoaderSupportsArchiveExtensions() {
        let exts = ArchiveLoader.supportedExtensions
        #expect(exts.contains("cbz"))
        #expect(exts.contains("zip"))
        #expect(exts.contains("cbr"))
        #expect(exts.contains("rar"))
    }
}
