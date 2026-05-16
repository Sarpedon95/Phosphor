import SwiftUI

/// Library toolbar dropdowns: view mode, group by, sort order, plus a button
/// to open the Years overview.
struct GridLayoutControls: View {
    @ObservedObject var viewModel: LibraryViewModel
    @AppStorage(AppSettings.Keys.timelineViewMode) private var viewModeRaw: String = AppSettings.Defaults.timelineViewMode.rawValue
    let onShowYears: () -> Void

    private var viewMode: TimelineViewMode {
        get { TimelineViewMode(rawValue: viewModeRaw) ?? .grid }
    }

    var body: some View {
        Menu {
            Section("View") {
                Button {
                    viewModeRaw = TimelineViewMode.grid.rawValue
                } label: {
                    Label("Grid", systemImage: viewMode == .grid ? "checkmark" : "square.grid.2x2")
                }
                Button {
                    viewModeRaw = TimelineViewMode.list.rawValue
                } label: {
                    Label("List", systemImage: viewMode == .list ? "checkmark" : "list.bullet")
                }
                Button {
                    viewModeRaw = TimelineViewMode.justified.rawValue
                } label: {
                    Label("Justified", systemImage: viewMode == .justified ? "checkmark" : "rectangle.grid.1x2")
                }
            }

            Section("Group by") {
                Button("Day") { viewModel.groupBy = .day }
                Button("Month") { viewModel.groupBy = .month }
                Button("Year") { viewModel.groupBy = .year }
            }

            Section("Sort") {
                Button("Newest first") { viewModel.sortOrder = .newest }
                Button("Oldest first") { viewModel.sortOrder = .oldest }
                Button("Recently added") { viewModel.sortOrder = .recentlyAdded }
                Button("File name") { viewModel.sortOrder = .fileName }
            }

            Section {
                Button {
                    onShowYears()
                } label: {
                    Label("Years overview", systemImage: "square.grid.3x3.square")
                }
            }
        } label: {
            Image(systemName: symbolForMode)
        }
        .accessibilityLabel("Library layout")
        .accessibilityHint("Change view mode, grouping, or sort order.")
    }

    private var symbolForMode: String {
        switch viewMode {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .justified: return "rectangle.grid.1x2"
        }
    }
}
