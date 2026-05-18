import SwiftUI

struct EditingView: View {
    let asset: ImmichAsset
    @StateObject private var viewModel = EditingViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showingOriginal = false
    @State private var histogramMode: HistogramMode = .rgb
    @State private var cropPanelActive = false
    @State private var showCancelConfirm = false
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var isSaving = false
    @State private var zoomScale: CGFloat = 1
    @State private var showSaveConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.phosphorBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    imageArea
                    HistogramView(image: viewModel.previewImage, mode: $histogramMode)
                    EditingToolbar(viewModel: viewModel, cropPanelActive: $cropPanelActive)
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
        }
        .task { await viewModel.loadImage(asset: asset) }
        .interactiveDismissDisabled(viewModel.adjustments != .identity)
        .alert("Discard edits?", isPresented: $showCancelConfirm) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive) { dismiss() }
        }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) { presetName = "" }
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { viewModel.saveCurrentAsPreset(name: name) }
                presetName = ""
            }
        }
        .alert("Save as new photo?", isPresented: $showSaveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Save as New") { Task { await performSave() } }
        } message: {
            Text("Your edits will be saved as a new photo in your Immich library. The original is not changed.")
        }
        .fullScreenCover(isPresented: $cropPanelActive) {
            CropEditView(
                asset: asset,
                cropRect: $viewModel.adjustments.cropRect,
                angle: $viewModel.adjustments.straightenAngle
            )
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Image area

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = showingOriginal ? viewModel.originalImage : viewModel.previewImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoomScale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { v in
                                    zoomScale = min(max(v.magnification, 1), 6)
                                }
                                .onEnded { _ in
                                    if zoomScale < 1.05 {
                                        withAnimation(.spring) { zoomScale = 1 }
                                    }
                                }
                        )
                } else {
                    ProgressView().tint(.phosphorAccent)
                }
                if showingOriginal {
                    Text("BEFORE")
                        .font(Typography.captionBold)
                        .foregroundStyle(.white)
                        .padding(Spacing.sm)
                        .background(.black.opacity(0.5), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Spacing.md)
                } else if viewModel.adjustments != .identity {
                    Text("AFTER")
                        .font(Typography.captionBold)
                        .foregroundStyle(.white)
                        .padding(Spacing.sm)
                        .background(.black.opacity(0.5), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Spacing.md)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .accessibilityLabel("Undo")

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)
            .accessibilityLabel("Redo")

            Button {
                if viewModel.adjustments != .identity {
                    showCancelConfirm = true
                } else {
                    dismiss()
                }
            } label: {
                Text("Cancel")
            }
            .foregroundStyle(.phosphorAccent)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {} label: {
                Image(systemName: "rectangle.lefthalf.inset.filled")
            }
            .accessibilityLabel("Compare with original")
            .accessibilityHint("Press and hold to show the original. Release to return to the edited version.")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0)
                    .onChanged { _ in
                        if !showingOriginal {
                            withAnimation(.easeInOut(duration: 0.12)) { showingOriginal = true }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeInOut(duration: 0.12)) { showingOriginal = false }
                    }
            )

            Button {
                Task { await viewModel.autoEnhance() }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel("Auto enhance")

            Menu {
                Button("Save as Preset") { showSavePreset = true }
                Button("Reset All", role: .destructive) { viewModel.reset() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }

            Button {
                Task { await done() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small).tint(.phosphorAccent)
                } else {
                    Text("Done").bold()
                }
            }
            .disabled(isSaving)
            .foregroundStyle(.phosphorAccent)
        }
    }

    private func done() async {
        // Show confirmation before persisting — the user needs to know the
        // edit creates a new asset rather than modifying the original.
        showSaveConfirm = true
    }

    private func performSave() async {
        isSaving = true
        defer { isSaving = false }
        guard let edited = await viewModel.exportEdited(asset: asset) else {
            HapticManager.notification(.error)
            return
        }
        let ok = await viewModel.saveToImmich(image: edited, originalAsset: asset)
        if ok {
            HapticManager.notification(.success)
            dismiss()
        } else {
            HapticManager.notification(.error)
        }
    }
}
