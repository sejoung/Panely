import SwiftUI

enum SettingsTab: Hashable {
    case general
    case library
    case storage
    case diagnostics
    case experimental
}

@MainActor
struct SettingsView: View {
    let viewModel: ReaderViewModel

    private var tab: Binding<SettingsTab> {
        Binding(
            get: { viewModel.settingsTab },
            set: { viewModel.settingsTab = $0 }
        )
    }

    var body: some View {
        TabView(selection: tab) {
            GeneralSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            LibrarySettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(SettingsTab.library)

            StorageSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }
                .tag(SettingsTab.storage)

            DiagnosticsSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .tag(SettingsTab.diagnostics)

            ExperimentalSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Experimental", systemImage: "flask")
                }
                .tag(SettingsTab.experimental)
        }
        .frame(minWidth: 560, minHeight: 280)
    }
}

#Preview {
    SettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
