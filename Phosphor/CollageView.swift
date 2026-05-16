import SwiftUI

/// Full-screen sheet presented from the various collage entry points (bulk
/// toolbar, album toolbar, photo More menu, memories).
struct CollageView: View {
    @StateObject private var viewModel: CollageViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showExport = false

    init(assets: [ImmichAsset]) {
        _viewModel = StateObject(wrappedValue: CollageViewModel(assets: assets))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                CollageCanvas(viewModel: viewModel)
                if viewModel.isGenerating && viewModel.spec == nil {
                    ProgressView()
                        .tint(.phosphorAccent)
                        .scaleEffect(1.5)
                }
            }
            .navigationTitle("Collage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Spacing.sm) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Collage settings")
                        Button("Export") {
                            showExport = true
                        }
                        .foregroundStyle(.phosphorAccent)
                        .disabled(viewModel.spec == nil)
                    }
                }
            }
        }
        .task {
            if viewModel.spec == nil {
                await viewModel.generate()
            }
        }
        .sheet(isPresented: $showSettings) {
            CollageSettingsSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showExport) {
            CollageExportView(viewModel: viewModel)
                .presentationBackground(.black)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings sheet

private struct CollageSettingsSheet: View {
    @ObservedObject var viewModel: CollageViewModel
    @Environment(\.dismiss) private var dismiss

    private let aspects: [(String, CGFloat)] = [
        ("Square", 1.0),
        ("Portrait 4:5", 4.0 / 5.0),
        ("Landscape 16:9", 16.0 / 9.0),
        ("Story 9:16", 9.0 / 16.0),
        ("A4", 210.0 / 297.0),
        ("Wide 2:1", 2.0)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                Form {
                    Section("Spacing") {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Gap").foregroundStyle(.phosphorSecondary)
                                Spacer()
                                Text("\(Int(viewModel.gapWidth))pt").foregroundStyle(.phosphorAccent)
                            }
                            Slider(value: $viewModel.gapWidth, in: 0...20, step: 1)
                                .tint(.phosphorAccent)
                        }
                        .listRowBackground(Color.phosphorSurface)
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Corner radius").foregroundStyle(.phosphorSecondary)
                                Spacer()
                                Text("\(Int(viewModel.cornerRadius))pt").foregroundStyle(.phosphorAccent)
                            }
                            Slider(value: $viewModel.cornerRadius, in: 0...20, step: 1)
                                .tint(.phosphorAccent)
                        }
                        .listRowBackground(Color.phosphorSurface)
                    }
                    Section("Background") {
                        ColorPicker("Background colour", selection: $viewModel.backgroundColor, supportsOpacity: false)
                            .listRowBackground(Color.phosphorSurface)
                    }
                    Section("Blend") {
                        Picker("Blend mode", selection: $viewModel.blendMode) {
                            ForEach(CollageBlendMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.phosphorSurface)
                    }
                    Section("Canvas") {
                        Picker("Aspect", selection: $viewModel.canvasAspect) {
                            ForEach(aspects, id: \.1) { entry in
                                Text(entry.0).tag(entry.1)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.phosphorAccent)
                        .listRowBackground(Color.phosphorSurface)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .onChange(of: viewModel.canvasAspect) { _, _ in
            Task { await viewModel.switchLayout(viewModel.currentLayout) }
        }
        .onChange(of: viewModel.gapWidth) { _, _ in
            // Re-apply layout: layout maths are gap-agnostic but the spec
            // carries the gap so renderer + cell views consume the new value.
            Task { await viewModel.switchLayout(viewModel.currentLayout) }
        }
        .preferredColorScheme(.dark)
    }
}
