import AppKit
import Foundation

nonisolated struct CacheMaintenance: Sendable {
    private let extractionCache: any ExtractionCacheManaging

    init(extractionCache: any ExtractionCacheManaging = LiveExtractionCacheManager()) {
        self.extractionCache = extractionCache
    }

    var cacheBudgetBytes: UInt64 {
        extractionCache.cacheBudgetBytes
    }

    func cacheRoot() -> URL {
        extractionCache.cacheRoot()
    }

    func cacheSizes(in root: URL, excluding activeURL: URL?) -> (total: UInt64, clearable: UInt64) {
        (
            total: extractionCache.cacheSizeBytes(in: root, excluding: nil),
            clearable: extractionCache.cacheSizeBytes(in: root, excluding: activeURL)
        )
    }

    @discardableResult
    func clearExtractionCache(in root: URL? = nil, excluding activeURL: URL?) -> UInt64 {
        let targetRoot = root ?? extractionCache.cacheRoot()
        AppLog.info(
            .cache,
            "Clear extraction cache started",
            metadata: [
                "activeURL": "\(DiagnosticRedactor.describe(activeURL))",
                "root": "\(DiagnosticRedactor.describe(targetRoot))",
            ]
        )
        let removed = extractionCache.clearCache(in: targetRoot, excluding: activeURL)
        AppLog.info(
            .cache,
            "Clear extraction cache finished",
            metadata: ["removedBytes": "\(removed)"]
        )
        return removed
    }

    func formattedBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    @MainActor
    func presentClearResult(removedBytes: UInt64) {
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
