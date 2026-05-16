import SwiftUI
import Charts

struct InsightsView: View {
    @StateObject private var viewModel = InsightsViewModel()

    var body: some View {
        ZStack {
            Color.phosphorBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.photosByMonth.isEmpty {
            skeleton
        } else if let error = viewModel.error, viewModel.photosByMonth.isEmpty {
            VStack(spacing: Spacing.md) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.phosphorSecondary)
                Text(error.localizedDescription)
                    .font(Typography.subheadline)
                    .foregroundStyle(.phosphorSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
                Button("Retry") { Task { await viewModel.load() } }
                    .foregroundStyle(.phosphorAccent)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    activitySection
                    storageSection
                    locationsSection
                    camerasSection
                    peopleSection
                    heatmapSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Sections

    private var activitySection: some View {
        sectionCard(title: "Activity") {
            Chart(viewModel.photosByMonth) { stat in
                BarMark(
                    x: .value("Month", stat.month, unit: .month),
                    y: .value("Photos", stat.count)
                )
                .foregroundStyle(.phosphorAccent)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 3)) { value in
                    AxisGridLine().foregroundStyle(.phosphorSeparator)
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .foregroundStyle(.phosphorSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(.phosphorSeparator)
                    AxisValueLabel().foregroundStyle(.phosphorSecondary)
                }
            }
            .frame(height: 200)
        }
    }

    private var storageSection: some View {
        sectionCard(title: "Storage") {
            let breakdown = viewModel.storageBreakdown
            VStack(spacing: Spacing.sm) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        storageBar(.phosphorAccent, breakdown.photos, breakdown.total, in: geo.size.width)
                        storageBar(.blue, breakdown.videos, breakdown.total, in: geo.size.width)
                        storageBar(.orange, breakdown.raw, breakdown.total, in: geo.size.width)
                        storageBar(.gray, breakdown.other, breakdown.total, in: geo.size.width)
                    }
                }
                .frame(height: 14)
                .clipShape(Capsule())

                HStack(spacing: Spacing.md) {
                    legend(.phosphorAccent, "Photos", breakdown.photos)
                    legend(.blue, "Videos", breakdown.videos)
                    legend(.orange, "RAW", breakdown.raw)
                    legend(.gray, "Other", breakdown.other)
                }
                .font(Typography.caption)
            }
        }
    }

    private func storageBar(_ color: Color, _ value: Int64, _ total: Int64, in width: CGFloat) -> some View {
        let fraction = total > 0 ? CGFloat(value) / CGFloat(total) : 0
        return Rectangle().fill(color).frame(width: width * fraction)
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).foregroundStyle(.phosphorSecondary)
            }
            Text(StorageFormatter.string(fromBytes: bytes))
                .foregroundStyle(.phosphorAccent)
        }
    }

    private var locationsSection: some View {
        sectionCard(title: "Top Locations") {
            if viewModel.topLocations.isEmpty {
                Text("No locations found").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(viewModel.topLocations) { stat in
                        HStack {
                            Image(systemName: "mappin.circle")
                                .foregroundStyle(.phosphorSecondary)
                            Text(stat.city).foregroundStyle(.phosphorAccent)
                            Spacer()
                            Text("\(stat.count)").foregroundStyle(.phosphorSecondary)
                        }
                        .font(Typography.subheadline)
                    }
                }
            }
        }
    }

    private var camerasSection: some View {
        sectionCard(title: "Cameras") {
            if viewModel.topCameras.isEmpty {
                Text("No camera EXIF data").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            } else {
                let maxCount = viewModel.topCameras.first?.count ?? 1
                VStack(spacing: Spacing.sm) {
                    ForEach(viewModel.topCameras) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(stat.makeModel).foregroundStyle(.phosphorAccent)
                                Spacer()
                                Text("\(stat.count)").foregroundStyle(.phosphorSecondary)
                            }
                            .font(Typography.subheadline)
                            GeometryReader { geo in
                                let frac = CGFloat(stat.count) / CGFloat(maxCount)
                                Capsule().fill(Color.phosphorAccent.opacity(0.7))
                                    .frame(width: geo.size.width * frac, height: 3)
                            }
                            .frame(height: 3)
                        }
                    }
                }
            }
        }
    }

    private var peopleSection: some View {
        sectionCard(title: "Most Photographed") {
            if viewModel.topPeople.isEmpty {
                Text("No people identified yet").font(Typography.caption).foregroundStyle(.phosphorSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.md) {
                        ForEach(viewModel.topPeople) { stat in
                            VStack(spacing: Spacing.xs) {
                                PersonAvatar(personId: stat.person.id)
                                    .frame(width: 56, height: 56)
                                Text(stat.person.displayName)
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorAccent)
                                    .lineLimit(1)
                                Text("\(stat.count)")
                                    .font(Typography.caption)
                                    .foregroundStyle(.phosphorSecondary)
                            }
                            .frame(width: 72)
                        }
                    }
                }
            }
        }
    }

    private var heatmapSection: some View {
        sectionCard(title: "Last 365 Days") {
            HeatmapGrid(data: viewModel.heatmapData)
        }
    }

    // MARK: - Helpers

    private func sectionCard<C: View>(title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(Typography.title3)
                .foregroundStyle(.phosphorAccent)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(Spacing.md)
        .background(Color.phosphorSurface, in: RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous))
    }

    private var skeleton: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: CornerRadius.large)
                        .fill(Color.phosphorSurface)
                        .frame(height: 180)
                        .overlay(ShimmerView())
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large))
                }
            }
            .padding(Spacing.md)
        }
    }
}

// MARK: - Heatmap

private struct HeatmapGrid: View {
    let data: [Date: Int]

    private let columns = 52
    private let rows = 7

    var body: some View {
        let cells = generateCells()
        let maxCount = max(1, cells.map(\.count).max() ?? 1)
        GeometryReader { geo in
            let cellSize = (geo.size.width - CGFloat(columns - 1) * 2) / CGFloat(columns)
            VStack(spacing: 2) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<columns, id: \.self) { col in
                            let idx = col * rows + row
                            if cells.indices.contains(idx) {
                                heatCell(cells[idx], maxCount: maxCount, size: cellSize)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 7 * 12 + 6 * 2)
        .accessibilityLabel("Photo activity heatmap for the past year")
    }

    private struct Cell { let date: Date; let count: Int }

    private func generateCells() -> [Cell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let total = columns * rows
        var result: [Cell] = []
        for offset in stride(from: total - 1, through: 0, by: -1) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                let key = calendar.startOfDay(for: day)
                result.append(Cell(date: key, count: data[key] ?? 0))
            }
        }
        return result
    }

    private func heatCell(_ cell: Cell, maxCount: Int, size: CGFloat) -> some View {
        let intensity = Double(cell.count) / Double(maxCount)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.phosphorAccent.opacity(0.10 + intensity * 0.85))
            .frame(width: size, height: size)
    }
}
