import CoreGraphics
import Foundation
import ImageIO
import ZIPFoundation

/// How an exported book is saved.
nonisolated enum TranslationExportFormat: String, Codable, CaseIterable, Sendable {
    /// One `.cbz` (a zip of the pages) — what comic readers open.
    case cbz
    /// The same archive as `.zip`, for apps and services that only take that.
    case zip
    /// A folder of page images.
    case folder

    /// The pages go into one archive file.
    var isArchive: Bool { self != .folder }
}

/// Writes a translated copy of a book: each page with its translations
/// painted in, in reading order, as a CBZ, a ZIP or a folder of images. Pages with
/// nothing to paint are copied byte for byte. The book itself is never
/// touched.
///
/// Written under a hidden partial name and moved into place at the end, so a
/// cancelled or failed export leaves nothing behind that looks finished.
nonisolated struct TranslationExportWriter {
    let pages: [ComicPage]
    /// Translations by `ComicPage.id`, edits already applied.
    let translations: [String: TranslatedPage]
    let scope: TranslationScope
    let format: TranslationExportFormat

    struct Result: Sendable {
        let url: URL
        let bytes: Int64
    }

    /// Writes the book into `folder` as `name` (extension added for CBZ),
    /// numbering the name if it's taken. `progress` gets pages done and the
    /// total after each page.
    func write(
        into folder: URL,
        name: String,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> Result {
        let fileManager = FileManager.default
        let destination = Self.availableURL(in: folder, name: name, format: format)
        let partial = folder.appendingPathComponent("." + destination.lastPathComponent + ".partial")
        try? fileManager.removeItem(at: partial)

        let byIndex = pages.map { translations[$0.id] }
        let digits = max(3, String(pages.count).count)
        do {
            switch format {
            case .cbz, .zip:
                let archive = try Archive(url: partial, accessMode: .create)
                for index in pages.indices {
                    try Task.checkCancellation()
                    let (data, ext) = try await pageData(index, byIndex: byIndex)
                    let entry = Self.entryName(index, digits: digits, ext: ext)
                    // Images are compressed already; storing them is as small
                    // and much faster.
                    try archive.addEntry(with: entry, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                        data.subdata(in: Int(position)..<Int(position) + size)
                    }
                    await progress(index + 1, pages.count)
                }
            case .folder:
                try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
                for index in pages.indices {
                    try Task.checkCancellation()
                    let (data, ext) = try await pageData(index, byIndex: byIndex)
                    try data.write(to: partial.appendingPathComponent(Self.entryName(index, digits: digits, ext: ext)))
                    await progress(index + 1, pages.count)
                }
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        return Result(url: destination, bytes: Self.size(of: destination))
    }

    /// The page as it goes into the export, and its file extension.
    private func pageData(_ index: Int, byIndex: [TranslatedPage?]) async throws -> (Data, String) {
        let page = pages[index]
        let original = try await Self.originalData(of: page)
        let ext = Self.originalExtension(of: page)
        let bubbles = TranslatedPageRenderer.bubbles(for: index, in: byIndex, scope: scope)
        guard !bubbles.isEmpty else { return (original, ext) }

        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageLoaderError.decodingFailed }
        let pageSize = byIndex[index]?.imageSize ?? CGSize(width: image.width, height: image.height)
        let asPNG = ext == "png"
        guard let rendered = TranslatedPageRenderer.render(image, bubbles: bubbles, pageSize: pageSize),
              let data = TranslatedPageRenderer.encode(rendered, asPNG: asPNG)
        else { throw ImageLoaderError.decodingFailed }
        return (data, asPNG ? "png" : "jpg")
    }

    private static func originalData(of page: ComicPage) async throws -> Data {
        switch page.source {
        case .file(let url):
            return try Data(contentsOf: url, options: .mappedIfSafe)
        case .archiveEntry(let reader, let path):
            return try await reader.loadData(at: path)
        }
    }

    private static func originalExtension(of page: ComicPage) -> String {
        let name: String
        switch page.source {
        case .file(let url): name = url.lastPathComponent
        case .archiveEntry(_, let path): name = path
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "jpg" : ext
    }

    /// "001.jpg": numbered in reading order, so every reader sorts them right
    /// whatever the book's own file names were.
    static func entryName(_ index: Int, digits: Int, ext: String) -> String {
        let number = String(index + 1)
        return String(repeating: "0", count: max(0, digits - number.count)) + number + "." + ext
    }

    /// `name` in `folder`, or "name 2", "name 3"… if it's taken.
    static func availableURL(in folder: URL, name: String, format: TranslationExportFormat) -> URL {
        let fileManager = FileManager.default
        func candidate(_ base: String) -> URL {
            switch format {
            case .cbz: folder.appendingPathComponent(base + ".cbz")
            case .zip: folder.appendingPathComponent(base + ".zip")
            case .folder: folder.appendingPathComponent(base, isDirectory: true)
            }
        }
        var url = candidate(name)
        var number = 2
        while fileManager.fileExists(atPath: url.path) {
            url = candidate("\(name) \(number)")
            number += 1
        }
        return url
    }

    /// File names can't hold "/" or ":"; the rest of a title is kept.
    static func safeFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Panely" : cleaned
    }

    private static func size(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        let files = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
