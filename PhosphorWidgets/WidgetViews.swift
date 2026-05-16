import SwiftUI
import WidgetKit

struct PhosphorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhosphorEntry

    var body: some View {
        Group {
            if !entry.isConfigured {
                unconfigured
            } else {
                switch family {
                case .systemSmall: smallWidget
                case .systemMedium: gridWidget(columns: 2, rows: 2)
                case .systemLarge: gridWidget(columns: 3, rows: 3)
                case .accessoryRectangular: lockScreen
                default: smallWidget
                }
            }
        }
        .containerBackground(.black, for: .widget)
    }

    private var unconfigured: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
            Text("Open Phosphor to connect")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding()
    }

    private var smallWidget: some View {
        ZStack(alignment: .bottomLeading) {
            image(at: 0)
                .aspectRatio(contentMode: .fill)
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .center, endPoint: .bottom)
            Text("Phosphor")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(8)
        }
        .clipped()
    }

    private func gridWidget(columns: Int, rows: Int) -> some View {
        let capacity = columns * rows
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
            spacing: 2
        ) {
            ForEach(0..<capacity, id: \.self) { idx in
                image(at: idx)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            }
        }
        .padding(2)
    }

    private var lockScreen: some View {
        HStack(spacing: 8) {
            image(at: 0)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text("Phosphor").font(.headline)
                Text(entry.date, style: .date).font(.caption2)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func image(at index: Int) -> some View {
        if entry.images.indices.contains(index),
           let uiImage = UIImage(data: entry.images[index]) {
            Image(uiImage: uiImage).resizable()
        } else {
            Rectangle().fill(Color(white: 0.12))
        }
    }
}
