import Foundation
import SwiftUI

/// Library/launch preferences: whether a cold launch reopens the last browsed
/// folder, and a one-shot "forget" for the saved folder bookmark. The bookmark
/// itself is persisted by `LastLibraryRootStore`; this view is just its UI.
@MainActor
struct LibrarySettingsView: View {
    let viewModel: ReaderViewModel

    /// Snapshot of the remembered folder for display. Loaded on appear and
    /// cleared in place when the user forgets it, so the row updates without a
    /// round-trip through the store on every render.
    @State private var rememberedRoot: URL?
    @State private var didLoad = false

    private var reopenOnLaunch: Binding<Bool> {
        Binding(
            get: { viewModel.reopenLastFolderOnLaunch },
            set: { viewModel.reopenLastFolderOnLaunch = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Library") {
                Toggle("Reopen last folder on launch", isOn: reopenOnLaunch)

                if let root = rememberedRoot {
                    LabeledContent("Last opened") {
                        Text(displayPath(root))
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root.path)
                    }

                    Button("Forget Now", role: .destructive) {
                        viewModel.forgetLastLibraryRoot()
                        rememberedRoot = nil
                    }
                } else {
                    Text("No folder remembered yet — it's saved the first time you browse one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 12)
        .task {
            // Resolve once per appearance (a bookmark resolve isn't free).
            guard !didLoad else { return }
            didLoad = true
            rememberedRoot = viewModel.rememberedLibraryRoot
        }
    }

    /// Home-relative, e.g. `~/Comics/Sample Library`, so the row stays readable
    /// without leaking the full sandbox/absolute prefix.
    private func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

#Preview {
    LibrarySettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
