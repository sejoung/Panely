import Testing
import Foundation
@testable import Panely

/// Explicit "next / previous book" requests (`[` / `]`, toolbar, Go menu):
/// they either step, or say why they can't — and a book opened on its own
/// reuses a folder grant the user already gave.
@MainActor
struct ReaderViewModelVolumeSteppingTests {

    // MARK: - Notices

    @Test func steppingPastTheLastVolumeExplainsInsteadOfNoOp() {
        let vm = makeLoadedViewModel(siblingCount: 2, currentIndex: 1)

        vm.stepToNextVolume()

        #expect(vm.volumeNotice == .noNextVolume)
        #expect(vm.canStepToNextVolume == false)
    }

    @Test func steppingBeforeTheFirstVolumeExplainsInsteadOfNoOp() {
        let vm = makeLoadedViewModel(siblingCount: 2, currentIndex: 0)

        vm.stepToPreviousVolume()

        #expect(vm.volumeNotice == .noPreviousVolume)
    }

    @Test func steppingWithUnreadableFolderOffersFolderAccess() {
        let vm = makeLoadedViewModel(siblingCount: 1, currentIndex: 0)
        vm.siblingFolderUnreadable = true

        #expect(vm.volumeNavigationNeedsFolderAccess)
        // The controls stay live so using one can surface the grant prompt.
        #expect(vm.canStepToNextVolume)
        #expect(vm.canStepToPreviousVolume)
        #expect(vm.toolbarState().showVolumeNav)

        vm.stepToNextVolume()
        #expect(vm.volumeNotice == .needsFolderAccess)

        vm.dismissVolumeNotice()
        #expect(vm.volumeNotice == nil)
    }

    @Test func aGenuinelyLoneBookDoesNotAskForFolderAccess() {
        let vm = makeLoadedViewModel(siblingCount: 1, currentIndex: 0)
        vm.siblingFolderUnreadable = false

        #expect(vm.volumeNavigationNeedsFolderAccess == false)
        #expect(vm.toolbarState().showVolumeNav == false)

        vm.stepToNextVolume()
        #expect(vm.volumeNotice == .noNextVolume)
    }

    @Test func steppingWithoutABookDoesNothing() {
        let vm = makeTestViewModel()
        vm.stepToNextVolume()
        vm.stepToPreviousVolume()
        #expect(vm.volumeNotice == nil)
    }

    @Test func stepToNextVolumeLoadsTheNextSibling() async throws {
        let series = try makeSeries(volumes: ["Vol01", "Vol02"])
        defer { try? FileManager.default.removeItem(at: series) }
        let vm = makeTestViewModel()
        await vm.load(url: series)
        #expect(vm.currentSourceURL?.lastPathComponent == "Vol01.cbz")

        vm.stepToNextVolume()
        try await waitUntil { vm.currentSourceURL?.lastPathComponent == "Vol02.cbz" && !vm.isLoading }

        #expect(vm.volumeNotice == nil)
        #expect(vm.canStepToNextVolume == false)
    }

    @Test func aNewLoadClearsAStaleNotice() async throws {
        let series = try makeSeries(volumes: ["Vol01", "Vol02"])
        defer { try? FileManager.default.removeItem(at: series) }
        let vm = makeTestViewModel()
        await vm.load(url: series)
        vm.stepToPreviousVolume()
        #expect(vm.volumeNotice == .noPreviousVolume)

        await vm.load(url: vm.siblings[1], knownSiblings: vm.siblings, intent: .nextVolumeFromEnd)

        #expect(vm.volumeNotice == nil)
    }

    // MARK: - Reusing a folder grant

    @Test func bookOpenedOnItsOwnReusesAnEarlierFolderGrant() async throws {
        let series = try makeSeries(volumes: ["Vol01", "Vol02", "Vol03"])
        defer { try? FileManager.default.removeItem(at: series) }
        let vm = makeScopedViewModel()
        // The user browsed this folder before, so it is a recent with a
        // folder-level bookmark.
        vm.recentItems.record(series, title: "Series")

        // Now a single volume arrives by itself (Finder double-click).
        await vm.load(url: series.appendingPathComponent("Vol02.cbz"))

        #expect(vm.libraryScope.url?.standardizedFileURL == series.standardizedFileURL)
        #expect(vm.libraryRootURL?.standardizedFileURL == series.standardizedFileURL)
        #expect(vm.siblings.map(\.lastPathComponent) == ["Vol01.cbz", "Vol02.cbz", "Vol03.cbz"])
        #expect(vm.canGoPreviousVolume && vm.canGoNextVolume)
        #expect(vm.volumeNavigationNeedsFolderAccess == false)
    }

    @Test func deepestGrantedFolderWins() async throws {
        let library = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let series = library.appendingPathComponent("Series", isDirectory: true)
        try writeVolumes(["Vol01", "Vol02"], in: series)
        let vm = makeScopedViewModel()
        vm.recentItems.record(library, title: "Library")
        vm.recentItems.record(series, title: "Series")

        let grant = vm.rememberedFolderGrant(containing: series.appendingPathComponent("Vol01.cbz"))

        #expect(grant?.standardizedFileURL == series.standardizedFileURL)
    }

    @Test func rememberedLibraryRootCountsAsAGrant() async throws {
        let series = try makeSeries(volumes: ["Vol01", "Vol02"])
        defer { try? FileManager.default.removeItem(at: series) }
        let vm = makeScopedViewModel()
        vm.lastLibraryRoot.save(series)

        let grant = vm.rememberedFolderGrant(containing: series.appendingPathComponent("Vol01.cbz"))

        #expect(grant?.standardizedFileURL == series.standardizedFileURL)
    }

    @Test func noGrantMeansTheBookKeepsItsOwnScope() async throws {
        let series = try makeSeries(volumes: ["Vol01", "Vol02"])
        defer { try? FileManager.default.removeItem(at: series) }
        let vm = makeScopedViewModel()
        let book = series.appendingPathComponent("Vol01.cbz")

        #expect(vm.rememberedFolderGrant(containing: book) == nil)
        await vm.load(url: book)

        #expect(vm.libraryScope.url?.standardizedFileURL == book.standardizedFileURL)
        #expect(vm.explicitLibraryRootURL == nil)
    }

    @Test func openingAFolderIgnoresGrantsAboveIt() async throws {
        let library = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let series = library.appendingPathComponent("Series", isDirectory: true)
        try writeVolumes(["Vol01", "Vol02"], in: series)
        let vm = makeScopedViewModel()
        vm.recentItems.record(library, title: "Library")

        // Opening a folder is an explicit "this is my root" choice.
        await vm.load(url: series)

        #expect(vm.libraryScope.url?.standardizedFileURL == series.standardizedFileURL)
        #expect(vm.libraryRootURL?.standardizedFileURL == series.standardizedFileURL)
    }

    @Test func grantingFolderAccessFindsTheSiblings() async throws {
        let series = try makeSeries(volumes: ["Vol01", "Vol02"])
        defer { try? FileManager.default.removeItem(at: series) }
        let picker = TestFilePicker(urlToReturn: series)
        let vm = makeScopedViewModel(filePicker: picker)
        await vm.load(url: series.appendingPathComponent("Vol01.cbz"))
        // Simulate the sandbox having hidden the neighbours.
        vm.siblings = [series.appendingPathComponent("Vol01.cbz")]
        vm.siblingFolderUnreadable = true
        vm.stepToNextVolume()
        #expect(vm.volumeNotice == .needsFolderAccess)

        vm.requestFolderAccess(forVolumeNavigation: true)
        try await waitUntil { vm.siblings.count == 2 }

        #expect(picker.lastRequest?.canChooseDirectories == true)
        #expect(picker.lastRequest?.directoryURL?.standardizedFileURL == series.standardizedFileURL)
        #expect(vm.volumeNotice == nil)
        #expect(vm.canGoNextVolume)
        #expect(vm.volumeNavigationNeedsFolderAccess == false)
    }

    // MARK: helpers

    private func makeLoadedViewModel(siblingCount: Int, currentIndex: Int) -> ReaderViewModel {
        let vm = makeTestViewModel()
        vm.source = ComicSource(title: "Test", pages: Fixture.makeImagePages(count: 3))
        vm.siblings = (1...siblingCount).map {
            URL(fileURLWithPath: String(format: "/series/Vol%02d.cbz", $0))
        }
        vm.currentSourceURL = vm.siblings[currentIndex]
        return vm
    }

    /// A view model whose library scope always "acquires", standing in for
    /// the sandbox honouring a security-scoped bookmark.
    private func makeScopedViewModel(filePicker: TestFilePicker = TestFilePicker()) -> ReaderViewModel {
        let scope = ReaderLibraryScope(
            accessor: TestSecurityScopedResourceAccessor(shouldStart: true)
        )
        return ReaderViewModel(
            dependencies: makeTestDependencies(
                filePicker: filePicker,
                readerLibraryScopeFactory: { scope }
            )
        )
    }

    private func makeSeries(volumes: [String]) throws -> URL {
        let series = try Fixture.makeTempDir()
        try writeVolumes(volumes, in: series)
        return series
    }

    private func writeVolumes(_ names: [String], in series: URL) throws {
        let staging = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        try Fixture.makePNG(width: 10, height: 10).write(to: staging.appendingPathComponent("001.png"))
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        for name in names {
            try Fixture.zipDirectory(staging, to: series.appendingPathComponent("\(name).cbz"))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
