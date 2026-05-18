struct SidebarMode: Equatable {
    var pinned: Bool = false
    private(set) var overlayVisible: Bool = false

    var visible: Bool { pinned || overlayVisible }

    mutating func togglePin() {
        pinned.toggle()
        if !pinned {
            overlayVisible = false
        }
    }

    mutating func revealOverlay() {
        guard !pinned else { return }
        overlayVisible = true
    }

    mutating func dismissOverlay() {
        overlayVisible = false
    }
}
