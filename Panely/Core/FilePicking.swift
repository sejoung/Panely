import AppKit
import UniformTypeIdentifiers

/// What to present in an open panel. A plain value so the view-model can
/// describe *what* it wants opened without owning the AppKit modal itself.
nonisolated struct FilePickerRequest {
    var canChooseFiles: Bool
    var canChooseDirectories: Bool
    /// Allowed types; empty means "no restriction".
    var allowedContentTypes: [UTType] = []
    var prompt: String
    var message: String? = nil
    var directoryURL: URL? = nil
}

/// Seam over the AppKit open panel. Keeps `NSOpenPanel` (a modal UI element)
/// out of the view-model so the open/folder-access flows are unit-testable and
/// the VM stays free of presentation — the last UI dependency to be inverted.
@MainActor
protocol FilePicking {
    /// Present the panel modally; returns the chosen URL, or `nil` if cancelled.
    func pickURL(_ request: FilePickerRequest) -> URL?
}

@MainActor
struct LiveFilePicker: FilePicking {
    func pickURL(_ request: FilePickerRequest) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.canChooseFiles
        panel.canChooseDirectories = request.canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = request.prompt
        if let message = request.message {
            panel.message = message
        }
        if !request.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = request.allowedContentTypes
        }
        if let directoryURL = request.directoryURL {
            panel.directoryURL = directoryURL
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
