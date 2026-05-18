import SwiftUI
import MapKit

@MainActor
final class MapViewModel: ObservableObject {
    @Published private(set) var markers: [MapMarker] = []
    @Published private(set) var isLoading = false
    @Published var error: ImmichError?

    /// Optional client-side date filter. Markers carry no date, so filtering
    /// resolves each marker's asset date lazily (cached) when a range is set.
    @Published var dateFrom: Date?
    @Published var dateTo: Date?
    private var assetDateCache: [String: Date] = [:]

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

    var hasDateFilter: Bool { dateFrom != nil || dateTo != nil }

    /// Markers passing the active date filter. When no filter is set this is
    /// the full set. Date resolution is best-effort and cached per asset.
    func filteredMarkers() async -> [MapMarker] {
        guard hasDateFilter else { return markers }
        var result: [MapMarker] = []
        for marker in markers {
            let date = await resolveDate(for: marker.id)
            guard let date else { continue }
            if let from = dateFrom, date < from { continue }
            if let to = dateTo, date > to { continue }
            result.append(marker)
        }
        return result
    }

    private func resolveDate(for assetId: String) async -> Date? {
        if let cached = assetDateCache[assetId] { return cached }
        guard let asset = try? await ImmichAPI.shared.fetchAsset(id: assetId) else { return nil }
        assetDateCache[assetId] = asset.localDateTime
        return asset.localDateTime
    }

    func clearDateFilter() {
        dateFrom = nil
        dateTo = nil
    }
}

struct MapView: View {
    @StateObject private var viewModel = MapViewModel()
    @State private var selectedAsset: PhotoSelection?
    @State private var displayedMarkers: [MapMarker] = []
    @State private var showTimeFilter = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ClusterMap(markers: displayedMarkers) { id in
                Task { await openAsset(id) }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            loadingOverlay
        }
        .overlay(alignment: .topTrailing) {
            timeFilterButton
        }
        .overlay {
            statusOverlay
        }
        .task { await viewModel.load() }
        .task(id: viewModel.markers.count) { await refreshDisplayed() }
        .onChange(of: viewModel.dateFrom) { _, _ in Task { await refreshDisplayed() } }
        .onChange(of: viewModel.dateTo) { _, _ in Task { await refreshDisplayed() } }
        .sheet(isPresented: $showTimeFilter) {
            TimeFilterSheet(
                from: $viewModel.dateFrom,
                to: $viewModel.dateTo,
                onClear: { viewModel.clearDateFilter() }
            )
            .presentationDetents([.height(320)])
            .presentationBackground(.black)
        }
        .fullScreenCover(item: $selectedAsset) { sel in
            PhotoDetailView(assets: sel.assets, selectedIndex: sel.index)
        }
    }

    private func refreshDisplayed() async {
        displayedMarkers = await viewModel.filteredMarkers()
    }

    private var timeFilterButton: some View {
        Button {
            showTimeFilter = true
        } label: {
            Image(systemName: viewModel.hasDateFilter ? "calendar.badge.checkmark" : "calendar")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.phosphorPrimary)
                .padding(Spacing.s)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(Spacing.m)
        .accessibilityLabel("Filter by date")
        .accessibilityHint("Show only photos taken in a date range.")
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
        } else if !viewModel.isLoading && displayedMarkers.isEmpty && viewModel.hasDateFilter {
            statusCard(
                symbol: "calendar.badge.exclamationmark",
                title: "No photos in the selected date range",
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

    private func openAsset(_ id: String) async {
        do {
            let asset = try await ImmichAPI.shared.fetchAsset(id: id)
            selectedAsset = PhotoSelection(assets: [asset], index: 0)
        } catch {
            HapticManager.notification(.error)
        }
    }
}

// MARK: - Time filter sheet

private struct TimeFilterSheet: View {
    @Binding var from: Date?
    @Binding var to: Date?
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "From",
                        selection: Binding(
                            get: { from ?? Date(timeIntervalSince1970: 0) },
                            set: { from = $0 }
                        ),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "To",
                        selection: Binding(
                            get: { to ?? Date() },
                            set: { to = $0 }
                        ),
                        displayedComponents: .date
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Filter by date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        onClear()
                        dismiss()
                    }
                    .foregroundStyle(.phosphorSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.phosphorAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Clustering MKMapView wrapper

private struct ClusterMap: UIViewRepresentable {
    let markers: [MapMarker]
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .hybrid
        map.pointOfInterestFilter = .excludingAll
        map.register(
            MarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MarkerAnnotationView.reuseID
        )
        map.register(
            ClusterAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: ClusterAnnotationView.reuseID
        )
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let existing = map.annotations.compactMap { $0 as? PhotoAnnotation }
        let existingIDs = Set(existing.map(\.assetId))
        let newIDs = Set(markers.map(\.id))

        guard existingIDs != newIDs else { return }

        map.removeAnnotations(existing)
        let annotations = markers.map { marker in
            PhotoAnnotation(
                assetId: marker.id,
                title: marker.city,
                coordinate: CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon)
            )
        }
        map.addAnnotations(annotations)
        if !annotations.isEmpty, existing.isEmpty {
            map.showAnnotations(annotations, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: ClusterAnnotationView.reuseID,
                    for: cluster
                ) as? ClusterAnnotationView
                view?.annotation = cluster
                return view
            }
            guard let photo = annotation as? PhotoAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MarkerAnnotationView.reuseID,
                for: photo
            ) as? MarkerAnnotationView
            view?.annotation = photo
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                // Zoom to fit the cluster's members.
                let rect = cluster.memberAnnotations.reduce(MKMapRect.null) { partial, ann in
                    let point = MKMapPoint(ann.coordinate)
                    let pointRect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
                    return partial.union(pointRect)
                }
                mapView.setVisibleMapRect(
                    rect,
                    edgePadding: UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
                    animated: true
                )
                mapView.deselectAnnotation(cluster, animated: false)
            } else if let photo = view.annotation as? PhotoAnnotation {
                onSelect(photo.assetId)
                mapView.deselectAnnotation(photo, animated: false)
            }
        }
    }
}

private final class PhotoAnnotation: NSObject, MKAnnotation {
    let assetId: String
    let title: String?
    let coordinate: CLLocationCoordinate2D

    init(assetId: String, title: String?, coordinate: CLLocationCoordinate2D) {
        self.assetId = assetId
        self.title = title
        self.coordinate = coordinate
    }
}

private final class MarkerAnnotationView: MKAnnotationView {
    static let reuseID = "PhotoMarker"

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        clusteringIdentifier = "photo"
        canShowCallout = false
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        let symbol = UIImage(
            systemName: "photo.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)
        )
        let imageView = UIImageView(image: symbol)
        imageView.frame = bounds
        imageView.tintColor = .white
        imageView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        imageView.layer.cornerRadius = 15
        imageView.clipsToBounds = true
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(imageView)
    }
}

private final class ClusterAnnotationView: MKAnnotationView {
    static let reuseID = "PhotoCluster"

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let count = cluster.memberAnnotations.count
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        subviews.forEach { $0.removeFromSuperview() }

        let circle = UIView(frame: bounds)
        circle.backgroundColor = UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.9)
        circle.layer.cornerRadius = 20
        circle.clipsToBounds = true

        let label = UILabel(frame: bounds)
        label.text = count > 99 ? "99+" : "\(count)"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textAlignment = .center
        circle.addSubview(label)
        addSubview(circle)
    }
}
