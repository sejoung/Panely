import SwiftUI

@MainActor
struct SettingsView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        TabView {
            StorageSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }

            DiagnosticsSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
        }
        .frame(minWidth: 560, minHeight: 280)
    }
}

#Preview {
    SettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
