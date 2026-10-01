import SwiftUI

/// General preferences — currently the interface language. Language names
/// are shown in their own language ("English", "한국어") so the right one is
/// recognizable whatever language the UI is in right now.
///
/// A choice applies immediately, including the standard macOS menus.
@MainActor
struct GeneralSettingsView: View {
    let viewModel: ReaderViewModel

    private var language: Binding<AppLanguage> {
        Binding(
            get: { viewModel.appLanguage },
            set: { viewModel.appLanguage = $0 }
        )
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Language", selection: language) {
                    ForEach(AppLanguage.allCases) { option in
                        name(of: option).tag(option)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 12)
    }

    private func name(of option: AppLanguage) -> Text {
        switch option {
        case .system: Text("System Default")
        case .english: Text(verbatim: "English")
        case .korean: Text(verbatim: "한국어")
        }
    }
}

#Preview {
    GeneralSettingsView(viewModel: ReaderViewModel())
        .preferredColorScheme(.dark)
}
