import SwiftUI

/// Bridges `Settings` (UserDefaults + change notification) to SwiftUI, so the window
/// stays in sync when settings change elsewhere (e.g. the View menu toggles).
@MainActor
final class SettingsModel: ObservableObject {
    @Published var tabLayout: TabLayout {
        didSet { if Settings.tabLayout != tabLayout { Settings.tabLayout = tabLayout } }
    }
    @Published var addressBarMode: AddressBarMode {
        didSet { if Settings.addressBarMode != addressBarMode { Settings.addressBarMode = addressBarMode } }
    }
    @Published var appearance: AppearanceMode {
        didSet { if Settings.appearance != appearance { Settings.appearance = appearance } }
    }
    @Published var searchEngine: SearchEngine {
        didSet { if Settings.searchEngine != searchEngine { Settings.searchEngine = searchEngine } }
    }

    private var observer: NSObjectProtocol?

    init() {
        tabLayout = Settings.tabLayout
        addressBarMode = Settings.addressBarMode
        appearance = Settings.appearance
        searchEngine = Settings.searchEngine
        observer = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        tabLayout = Settings.tabLayout
        addressBarMode = Settings.addressBarMode
        appearance = Settings.appearance
        searchEngine = Settings.searchEngine
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }

            Section("Tabs") {
                Picker("Tab layout", selection: $model.tabLayout) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical sidebar").tag(TabLayout.vertical)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Address bar", selection: $model.addressBarMode) {
                    Text("Per pane").tag(AddressBarMode.perPane)
                    Text("Shared").tag(AddressBarMode.shared)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Address Bar")
            } footer: {
                Text(model.addressBarMode == .perPane
                     ? "Every pane has its own slim address bar."
                     : "One address bar at the top follows the focused pane.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Search") {
                Picker("Search engine", selection: $model.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.name).tag(engine)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 400)
    }
}
