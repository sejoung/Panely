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
    private static let fitModeKey = "panely.fitMode"

    private(set) var source: ComicSource = .empty
    private(set) var currentPageIndex: Int = 0 {
        didSet { savePosition() }
    }
    private(set) var currentImages: [NSImage] = []
    private(set) var errorMessage: String?

    private(set) var currentSourceURL: URL?
    private(set) var siblings: [URL] = []

    let recentItems: RecentItemsStore

    private var rootScopedURL: URL?
    private var currentTempDir: URL?
    private var openedSourceURL: URL?
    private(set) var libraryRefreshToken: UUID = UUID()
    private var explicitLibraryRootURL: URL?

    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 10
        return cache
    }()
    private var preloadTask: Task<Void, Never>?
    private let preloadRadius = 2

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

    var fitMode: FitMode = .fitScreen {
        didSet {
            UserDefaults.standard.set(fitMode.rawValue, forKey: Self.fitModeKey)
        }
    }

    init() {
        self.recentItems = RecentItemsStore()

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
        if let raw = UserDefaults.standard.string(forKey: Self.fitModeKey),
           let stored = FitMode(rawValue: raw) {
            fitMode = stored
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
        explicitLibraryRootURL ?? currentSourceURL?.deletingLastPathComponent()
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
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    func openURL(_ url: URL) {
        recentItems.record(url, title: displayTitle(for: url))
        Task { await load(url: url) }
    }

    func requestFolderAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select a folder to browse books from."
        if let parent = currentSourceURL?.deletingLastPathComponent() {
            panel.directoryURL = parent
        }

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        rootScopedURL?.stopAccessingSecurityScopedResource()
        rootScopedURL = nil
        if folderURL.startAccessingSecurityScopedResource() {
            rootScopedURL = folderURL
        }

        recentItems.record(folderURL, title: displayTitle(for: folderURL))
        explicitLibraryRootURL = folderURL

        Task {
            let volumes = await Self.enumerateVolumes(in: folderURL)
            if let current = currentSourceURL, isInsideRootScope(current) {
                siblings = volumes.isEmpty ? [current] : volumes
            }
            libraryRefreshToken = UUID()
        }
    }

    private func displayTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
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

    func toggleFitMode() {
        fitMode = fitMode == .fitScreen ? .fitWidth : .fitScreen
    }

    private func handleLayoutChange() {
        UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
        let step = navigationStep
        currentPageIndex = (currentPageIndex / step) * step
        Task { await refreshImages() }
    }

    private func load(url: URL, knownSiblings: [URL]? = nil) async {
        preloadTask?.cancel()

        if !isInsideCurrentTree(url) {
            cleanupTempDir()
            rootScopedURL?.stopAccessingSecurityScopedResource()
            rootScopedURL = nil
            if url.startAccessingSecurityScopedResource() {
                rootScopedURL = url
            }
            explicitLibraryRootURL = nil
            openedSourceURL = url
        }

        var targetURL = url
        var siblingsToUse = knownSiblings

        if currentTempDir == nil {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir && CBZLoader.supportedExtensions.contains(ext) {
                if let hasNested = try? await CBZLoader.hasNestedArchives(at: url), hasNested {
                    let tempDir = Self.makeTempDir()
                    do {
                        try await CBZLoader.extractAll(from: url, to: tempDir)
                        currentTempDir = tempDir
                        targetURL = tempDir
                    } catch {
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                }
            }
        }

        let isDirectory = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            let (hasImages, volumes) = await Self.analyzeFolder(targetURL)

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

    private func isInsideRootScope(_ url: URL) -> Bool {
        guard let root = rootScopedURL else { return false }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    private func isInsideCurrentTree(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path

        if let temp = currentTempDir {
            let tempPath = temp.standardizedFileURL.path
            if target == tempPath || target.hasPrefix(tempPath + "/") {
                return true
            }
        }

        return isInsideRootScope(url)
    }

    private func cleanupTempDir() {
        guard let dir = currentTempDir else { return }
        try? FileManager.default.removeItem(at: dir)
        currentTempDir = nil
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-\(UUID().uuidString)", isDirectory: true)
    }

    private func savePosition() {
        guard let url = currentSourceURL else { return }
        let key = positionKey(for: url)
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        positions[key] = currentPageIndex
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    private func restoredIndex(for url: URL) -> Int {
        let key = positionKey(for: url)
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        return positions[key] ?? 0
    }

    private func positionKey(for url: URL) -> String {
        let sourcePath = url.standardizedFileURL.path

        guard
            let opened = openedSourceURL,
            let tempDir = currentTempDir
        else {
            return sourcePath
        }

        let tempPath = tempDir.standardizedFileURL.path
        let openedPath = opened.standardizedFileURL.path

        if sourcePath == tempPath {
            return openedPath
        }

        if sourcePath.hasPrefix(tempPath + "/") {
            let relative = String(sourcePath.dropFirst(tempPath.count + 1))
            return openedPath + "#" + relative
        }

        return sourcePath
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
            if let image = await loadVisibleImage(page) {
                images.append(image)
            }
        }
        currentImages = images

        schedulePreload()
    }

    private func cachedImage(for page: ComicPage) -> NSImage? {
        imageCache.object(forKey: page.id.uuidString as NSString)
    }

    private func cacheImage(_ image: NSImage, for page: ComicPage) {
        imageCache.setObject(image, forKey: page.id.uuidString as NSString)
    }

    private func loadVisibleImage(_ page: ComicPage) async -> NSImage? {
        if let cached = cachedImage(for: page) {
            return cached
        }
        do {
            let image = try await ImageLoader.load(page)
            cacheImage(image, for: page)
            return image
        } catch {
            errorMessage = "Failed to load \(page.displayName)"
            return nil
        }
    }

    private func preloadIfNeeded(_ page: ComicPage) async {
        if cachedImage(for: page) != nil { return }
        guard let image = try? await ImageLoader.load(page) else { return }
        cacheImage(image, for: page)
    }

    private func pagesToPreload() -> [ComicPage] {
        guard !source.pages.isEmpty else { return [] }
        let step = navigationStep
        let visibleEnd = min(currentPageIndex + step, source.pageCount)
        let start = max(0, currentPageIndex - preloadRadius * step)
        let end = min(source.pageCount, visibleEnd + preloadRadius * step)

        var result: [ComicPage] = []
        let visibleRange = currentPageIndex..<visibleEnd
        for i in start..<end where !visibleRange.contains(i) {
            result.append(source.pages[i])
        }
        return result
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        let pages = pagesToPreload()
        guard !pages.isEmpty else { return }

        preloadTask = Task { [weak self] in
            for page in pages {
                if Task.isCancelled { return }
                await self?.preloadIfNeeded(page)
            }
        }
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
