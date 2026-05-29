import Foundation
import SwiftUI

@MainActor
struct StorageSettingsView: View {
    let viewModel: ReaderViewModel
    let cacheMaintenance: CacheMaintenance
    let cacheRoot: URL

    @State private var totalCacheBytes: UInt64?
    @State private var clearableCacheBytes: UInt64?
    @State private var isRefreshing = false
    @State private var isClearing = false
    @State private var refreshGeneration = 0
    @State private var scanTask: Task<(total: UInt64, clearable: UInt64), Never>?

    init(
        viewModel: ReaderViewModel,
        cacheRoot: URL? = nil,
        cacheMaintenance: CacheMaintenance? = nil
    ) {
        self.viewModel = viewModel
        let cacheMaintenance = cacheMaintenance
            ?? CacheMaintenance(extractionCache: viewModel.dependencies.extractionCache)
        self.cacheMaintenance = cacheMaintenance
        self.cacheRoot = cacheRoot ?? cacheMaintenance.cacheRoot()
    }

    private var canClear: Bool {
        !viewModel.isLoading && !isClearing && (clearableCacheBytes ?? 0) > 0
    }

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Extraction cache") {
                    cacheValue(totalCacheBytes)
                }

                LabeledContent("Clearable cache") {
                    cacheValue(clearableCacheBytes)
                }

                LabeledContent("Cache limit") {
                    Text(cacheMaintenance.formattedBytes(cacheMaintenance.cacheBudgetBytes))
                        .monospacedDigit()
                }

                HStack {
                    Button("Clear Cache", role: .destructive) {
                        clearCache()
                    }
                    .disabled(!canClear)

                    if isClearing {
                        ProgressView()
                            .controlSize(.small)
                    } else if viewModel.isLoading {
                        Text("Available after loading finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if (totalCacheBytes ?? 0) > 0 && (clearableCacheBytes ?? 0) == 0 {
                        Text("Current book cache is kept while open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 12)
        .task {
            await refreshCacheSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelyExtractionCacheDidChange)) { _ in
            Task { await refreshCacheSize() }
        }
        .onDisappear { scanTask?.cancel() }
    }

    @ViewBuilder
    private func cacheValue(_ bytes: UInt64?) -> some View {
        if let bytes, !isRefreshing {
            Text(cacheMaintenance.formattedBytes(bytes))
                .monospacedDigit()
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func refreshCacheSize() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let activeURL = viewModel.tempDir.url
        let cacheMaintenance = cacheMaintenance
        let cacheRoot = cacheRoot
        // Cancel any in-flight scan so a burst of cache-change notifications
        // doesn't pile up overlapping full-directory walks. The walk checks
        // `Task.isCancelled` cooperatively, so the cancel actually stops it.
        scanTask?.cancel()
        let task = Task.detached(priority: .utility) {
            cacheMaintenance.cacheSizes(in: cacheRoot, excluding: activeURL)
        }
        scanTask = task
        let sizes = await task.value
        guard !Task.isCancelled, generation == refreshGeneration else {
            return
        }
        totalCacheBytes = sizes.total
        clearableCacheBytes = sizes.clearable
        isRefreshing = false
    }

    private func clearCache() {
        guard canClear else { return }
        isClearing = true
        let activeURL = viewModel.tempDir.url
        let cacheMaintenance = cacheMaintenance
        let cacheRoot = cacheRoot
        Task {
            let removedBytes = await Task.detached(priority: .utility) {
                cacheMaintenance.clearExtractionCache(in: cacheRoot, excluding: activeURL)
            }.value
            await refreshCacheSize()
            isClearing = false
            cacheMaintenance.presentClearResult(removedBytes: removedBytes)
        }
    }
}

#Preview {
    StorageSettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
