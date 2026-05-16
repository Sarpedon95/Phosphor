import WidgetKit
import SwiftUI

struct PhosphorWidget: Widget {
    let kind = "PhosphorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PhosphorProvider()) { entry in
            PhosphorWidgetView(entry: entry)
        }
        .configurationDisplayName("Phosphor")
        .description("A glimpse of your photo library.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular
        ])
    }
}

@main
struct PhosphorWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PhosphorWidget()
    }
}
