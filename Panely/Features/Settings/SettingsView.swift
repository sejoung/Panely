import SwiftUI

@MainActor
struct SettingsView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            LibrarySettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            StorageSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }

            DiagnosticsSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }

            ExperimentalSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Experimental", systemImage: "flask")
                }
        }
        .frame(minWidth: 560, minHeight: 280)
    }
}

#Preview {
    SettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
