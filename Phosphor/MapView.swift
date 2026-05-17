import SwiftUI
import MapKit

@MainActor
final class MapViewModel: ObservableObject {
    @Published private(set) var markers: [MapMarker] = []
    @Published private(set) var isLoading = false
    @Published var error: ImmichError?

    func load() async {
        guard markers.isEmpty else { return }
        await fetch()
    }

    func reload() async {
        await fetch()
    }

    private func fetch() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            markers = try await ImmichAPI.shared.fetchMapMarkers()
        } catch let caught {
            error = (caught as? ImmichError) ?? .networkError(caught)
        }
    }

    func nearby(to region: MKCoordinateRegion, limit: Int = 30) -> [MapMarker] {
        let latMin = region.center.latitude - region.span.latitudeDelta / 2
        let latMax = region.center.latitude + region.span.latitudeDelta / 2
        let lonMin = region.center.longitude - region.span.longitudeDelta / 2
        let lonMax = region.center.longitude + region.span.longitudeDelta / 2
        return markers
            .filter { $0.lat >= latMin && $0.lat <= latMax && $0.lon >= lonMin && $0.lon <= lonMax }
            .prefix(limit)
            .map { $0 }
    }
}

struct MapView: View {
    @StateObject private var viewModel = MapViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
    )
    @State private var selectedAsset: PhotoSelection?

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            nearbyTray
        }
        .overlay(alignment: .top) {
            loadingOverlay
        }
        .overlay {
            statusOverlay
        }
        .task { await viewModel.load() }
        .fullScreenCover(item: $selectedAsset) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
        }
    }

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(viewModel.markers) { marker in
                Annotation(
                    marker.city ?? "",
                    coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon)
                ) {
                    markerButton(for: marker)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .ignoresSafeArea()
        .onMapCameraChange { context in
            visibleRegion = context.region
        }
    }

    private func markerButton(for marker: MapMarker) -> some View {
        Button {
            Task { await openAsset(marker.id) }
        } label: {
            Image(systemName: "photo.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.phosphorPrimary)
                .background(Circle().fill(.black.opacity(0.4)))
        }
        .accessibilityLabel(marker.city.map { "Photo in \($0)" } ?? "Photo location")
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if viewModel.isLoading {
            ProgressView()
                .tint(.phosphorPrimary)
                .padding(Spacing.s)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, Spacing.s)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let error = viewModel.error, viewModel.markers.isEmpty {
            statusCard(
                symbol: "exclamationmark.triangle",
                title: error.localizedDescription,
                showRetry: true
            )
        } else if !viewModel.isLoading && viewModel.markers.isEmpty {
            statusCard(
                symbol: "mappin.slash",
                title: "No photos with location data",
                showRetry: false
            )
        }
    }

    private func statusCard(symbol: String, title: String, showRetry: Bool) -> some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.phosphorSecondary)
            Text(title)
                .font(Typography.subheadline)
                .foregroundStyle(.phosphorPrimary)
                .multilineTextAlignment(.center)
            if showRetry {
                Button("Retry") { Task { await viewModel.reload() } }
                    .foregroundStyle(.phosphorPrimary)
                    .accessibilityHint("Tries loading map locations again.")
            }
        }
        .padding(Spacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        .padding(Spacing.xl)
        .accessibilityElement(children: .combine)
    }

    private var nearbyTray: some View {
        let nearby = viewModel.nearby(to: visibleRegion)
        return Group {
            if !nearby.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(nearby) { marker in
                            Button {
                                Task { await openAsset(marker.id) }
                            } label: {
                                MapThumbnail(assetId: marker.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(marker.city.map { "Photo in \($0)" } ?? "Photo")
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.m)
                }
                .frame(height: 120)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func openAsset(_ id: String) async {
        do {
            let asset = try await ImmichAPI.shared.fetchAsset(id: id)
            selectedAsset = PhotoSelection(assets: [asset], index: 0)
        } catch {
            HapticManager.notification(.error)
        }
    }
}

private struct MapThumbnail: View {
    let assetId: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ShimmerView()
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        .task(id: assetId) {
            image = await ImageLoader.shared.thumbnail(for: assetId, size: .thumbnail)
        }
    }
}
