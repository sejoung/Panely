import AppKit
import Foundation

nonisolated enum CacheMaintenance {
    static func cacheSizes(in root: URL, excluding activeURL: URL?) -> (total: UInt64, clearable: UInt64) {
        (
            total: ReaderTempDirectory.cacheSizeBytes(in: root),
            clearable: ReaderTempDirectory.cacheSizeBytes(in: root, excluding: activeURL)
        )
    }

    @discardableResult
    static func clearExtractionCache(in root: URL = ReaderTempDirectory.cacheRoot(), excluding activeURL: URL?) -> UInt64 {
        ReaderTempDirectory.clearCache(in: root, excluding: activeURL)
    }

    static func formattedBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    @MainActor
    static func presentClearResult(removedBytes: UInt64) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if removedBytes > 0 {
            alert.messageText = "Extraction Cache Cleared"
            alert.informativeText = "\(formattedBytes(removedBytes)) was removed."
        } else {
            alert.messageText = "No Extraction Cache Cleared"
            alert.informativeText = "There is no inactive extraction cache to remove."
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
