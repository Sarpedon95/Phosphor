import SwiftUI

struct SavedSearchesView: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss
    /// Returns the saved query to the parent so its `@State searchText` updates.
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Saved Searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.savedSearches.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "bookmark")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text("Save searches you use often")
                    .font(Typography.phosphorHeadline)
                    .foregroundStyle(.phosphorAccent)
                Text("Tap the bookmark icon in Search to save the current filters.")
                    .font(Typography.phosphorCaption)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
            .accessibilityElement(children: .combine)
        } else {
            List {
                ForEach(viewModel.savedSearches) { entry in
                    Button {
                        let q = viewModel.loadSavedSearch(entry)
                        onSelect(q)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(entry.name)
                                .font(Typography.subheadline)
                                .foregroundStyle(.phosphorAccent)
                            if !entry.query.isEmpty {
                                Text("“\(entry.query)”")
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorSecondary)
                                    .lineLimit(1)
                            }
                            Text(entry.filterSummary)
                                .font(Typography.caption)
                                .foregroundStyle(.phosphorSecondary)
                        }
                    }
                    .listRowBackground(Color.phosphorSurface)
                    .swipeActions {
                        Button(role: .destructive) {
                            viewModel.deleteSavedSearch(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
