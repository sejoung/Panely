import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class ReaderViewModel {
    private static let layoutKey = "panely.layout"
    private static let directionKey = "panely.direction"
    private static let sidebarVisibleKey = "panely.sidebarVisible"
    private static let positionsKey = "panely.positions"

    private(set) var source: ComicSource = .empty
    private(set) var currentPageIndex: Int = 0 {
        didSet { savePosition() }
    }
    private(set) var currentImages: [NSImage] = []
    private(set) var errorMessage: String?

    private(set) var currentSourceURL: URL?
    private(set) var siblings: [URL] = []

    var layout: PageLayout = .single {
        didSet { handleLayoutChange() }
    }

    var direction: ReadingDirection = .leftToRight {
        didSet {
            UserDefaults.standard.set(direction.rawValue, forKey: Self.directionKey)
        }
    }

    var sidebarVisible: Bool = true {
        didSet {
            UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarVisibleKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
           let stored = PageLayout(rawValue: raw) {
            layout = stored
        }
        if let raw = UserDefaults.standard.string(forKey: Self.directionKey),
           let stored = ReadingDirection(rawValue: raw) {
            direction = stored
        }
        if UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) != nil {
            sidebarVisible = UserDefaults.standard.bool(forKey: Self.sidebarVisibleKey)
        }
    }

    var totalPages: Int { source.pageCount }
    var hasSource: Bool { !source.isEmpty }

    var navigationStep: Int {
        layout == .double ? 2 : 1
    }

    var visiblePages: [ComicPage] {
        let start = currentPageIndex
        guard source.pages.indices.contains(start) else { return [] }
        let end = min(start + navigationStep, source.pageCount)
        return Array(source.pages[start..<end])
    }

    var pageCounterLabel: String {
        guard !source.isEmpty else { return "" }
        let count = totalPages
        let first = currentPageIndex + 1
        let last = min(currentPageIndex + navigationStep, count)
        return first == last ? "\(first) / \(count)" : "\(first)-\(last) / \(count)"
    }

    var currentSiblingIndex: Int? {
        guard let current = currentSourceURL else { return nil }
        let target = current.standardizedFileURL
        return siblings.firstIndex { $0.standardizedFileURL == target }
    }

    var hasMultipleVolumes: Bool { siblings.count > 1 }

    var canGoPreviousVolume: Bool {
        guard let idx = currentSiblingIndex else { return false }
        return idx > 0
    }

    var canGoNextVolume: Bool {
        guard let idx = currentSiblingIndex else { return false }
        return idx + 1 < siblings.count
    }

    var volumeCounterLabel: String? {
        guard hasMultipleVolumes, let idx = currentSiblingIndex else { return nil }
        return "Vol \(idx + 1) / \(siblings.count)"
    }

    var combinedCounterLabel: String {
        guard let vol = volumeCounterLabel else { return pageCounterLabel }
        return "\(vol) · \(pageCounterLabel)"
    }

    var libraryRootURL: URL? {
        currentSourceURL?.deletingLastPathComponent()
    }

    func openSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        var types: [UTType] = [.folder, .zip]
        if let cbz = UTType(filenameExtension: "cbz") {
            types.append(cbz)
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url: url) }
    }

    func openURL(_ url: URL) {
        Task { await load(url: url) }
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func next() {
        let target = currentPageIndex + navigationStep
        guard target < source.pageCount else { return }
        currentPageIndex = target
        Task { await refreshImages() }
    }

    func previous() {
        let target = currentPageIndex - navigationStep
        guard target >= 0 else {
            guard currentPageIndex > 0 else { return }
            currentPageIndex = 0
            Task { await refreshImages() }
            return
        }
        currentPageIndex = target
        Task { await refreshImages() }
    }

    func jump(to index: Int) {
        let step = navigationStep
        let snapped = (index / step) * step
        let clamped = min(max(snapped, 0), max(0, source.pageCount - 1))
        guard clamped != currentPageIndex else { return }
        currentPageIndex = clamped
        Task { await refreshImages() }
    }

    func nextVolume() {
        guard canGoNextVolume, let idx = currentSiblingIndex else { return }
        let target = siblings[idx + 1]
        let preservedSiblings = siblings
        Task { await load(url: target, knownSiblings: preservedSiblings) }
    }

    func previousVolume() {
        guard canGoPreviousVolume, let idx = currentSiblingIndex else { return }
        let target = siblings[idx - 1]
        let preservedSiblings = siblings
        Task { await load(url: target, knownSiblings: preservedSiblings) }
    }

    func toggleLayout() {
        layout = layout == .single ? .double : .single
    }

    func toggleDirection() {
        direction = direction.isRTL ? .leftToRight : .rightToLeft
    }

    private func handleLayoutChange() {
        UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
        let step = navigationStep
        currentPageIndex = (currentPageIndex / step) * step
        Task { await refreshImages() }
    }

    private func load(url: URL, knownSiblings: [URL]? = nil) async {
        var targetURL = url
        var siblingsToUse = knownSiblings

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            let (hasImages, volumes) = await Self.analyzeFolder(url)

            if !hasImages && !volumes.isEmpty {
                guard let first = volumes.first else { return }
                targetURL = first
                siblingsToUse = volumes
            } else if !hasImages && volumes.isEmpty {
                source = .empty
                currentImages = []
                currentSourceURL = nil
                siblings = []
                errorMessage = "Folder is empty or has no supported content"
                return
            }
        }

        let finalIsDirectory = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        do {
            let loaded: ComicSource
            if finalIsDirectory {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try FolderLoader.load(from: targetURL)
                }.value
            } else {
                loaded = try await CBZLoader.load(from: targetURL)
            }

            source = loaded
            currentSourceURL = targetURL
            if let siblingsToUse {
                siblings = siblingsToUse
            } else {
                siblings = await Self.scanSiblings(of: targetURL)
            }
            currentPageIndex = clampedRestoredIndex(for: targetURL, pageCount: loaded.pageCount)
            errorMessage = loaded.isEmpty ? "No images found" : nil
            await refreshImages()
        } catch {
            errorMessage = error.localizedDescription
            source = .empty
            currentImages = []
            currentSourceURL = nil
            siblings = []
        }
    }

    private func savePosition() {
        guard let url = currentSourceURL else { return }
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        positions[url.path] = currentPageIndex
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    private func restoredIndex(for url: URL) -> Int {
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        return positions[url.path] ?? 0
    }

    private func clampedRestoredIndex(for url: URL, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let restored = restoredIndex(for: url)
        let snapped = (restored / navigationStep) * navigationStep
        return min(max(snapped, 0), pageCount - 1)
    }

    private func refreshImages() async {
        let pages = visiblePages
        guard !pages.isEmpty else {
            currentImages = []
            return
        }

        var images: [NSImage] = []
        for page in pages {
            do {
                images.append(try await ImageLoader.load(page))
            } catch {
                errorMessage = "Failed to load \(page.displayName)"
            }
        }
        currentImages = images
    }

    nonisolated private static func scanSiblings(of url: URL) async -> [URL] {
        let volumes = await enumerateVolumes(in: url.deletingLastPathComponent())
        return volumes.isEmpty ? [url] : volumes
    }

    nonisolated private static func enumerateVolumes(in directory: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            let volumes = contents.filter { candidate in
                let isDir = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { return true }
                let ext = candidate.pathExtension.lowercased()
                return CBZLoader.supportedExtensions.contains(ext)
            }

            return volumes.sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    nonisolated private static func analyzeFolder(_ url: URL) async -> (hasImages: Bool, volumes: [URL]) {
        await Task.detached(priority: .userInitiated) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return (false, [])
            }

            var hasImages = false
            var volumes: [URL] = []

            for entry in contents {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let ext = entry.pathExtension.lowercased()

                if isDir {
                    volumes.append(entry)
                } else if CBZLoader.supportedExtensions.contains(ext) {
                    volumes.append(entry)
                } else if FolderLoader.supportedExtensions.contains(ext) {
                    hasImages = true
                }
            }

            let sorted = volumes.sorted { a, b in
                a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }

            return (hasImages, sorted)
        }.value
    }
}
