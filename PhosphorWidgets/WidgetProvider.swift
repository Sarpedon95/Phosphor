import WidgetKit
import SwiftUI

struct PhosphorEntry: TimelineEntry {
    let date: Date
    /// JPEG/PNG-encoded thumbnails, already downloaded so the widget view is
    /// pure rendering (no async in the View body).
    let images: [Data]
    let isConfigured: Bool
}

struct PhosphorProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhosphorEntry {
        PhosphorEntry(date: Date(), images: [], isConfigured: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PhosphorEntry) -> Void) {
        // Widget gallery / previews must return instantly — no network.
        if context.isPreview {
            completion(PhosphorEntry(date: Date(), images: [], isConfigured: true))
            return
        }
        Task {
            let entry = await makeEntry(for: context.family)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhosphorEntry>) -> Void) {
        Task {
            let entry = await makeEntry(for: context.family)
            // Refresh roughly hourly; WidgetKit coalesces aggressively anyway.
            let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func makeEntry(for family: WidgetFamily) async -> PhosphorEntry {
        let client = WidgetNetworkClient()
        guard client.isConfigured else {
            return PhosphorEntry(date: Date(), images: [], isConfigured: false)
        }

        let count: Int
        switch family {
        case .systemSmall, .accessoryRectangular: count = 1
        case .systemMedium: count = 4
        case .systemLarge: count = 9
        default: count = 1
        }

        let ids: [String]
        if family == .systemSmall {
            let favs = await client.favoriteAssetIDs(limit: 20)
            ids = favs.isEmpty ? await client.recentAssetIDs(limit: 1) : [favs.randomElement()].compactMap { $0 }
        } else {
            ids = await client.recentAssetIDs(limit: count)
        }

        var datas: [Data] = []
        for id in ids.prefix(count) {
            if let image = await client.thumbnail(assetID: id),
               let data = image.jpegData(compressionQuality: 0.8) {
                datas.append(data)
            }
        }
        return PhosphorEntry(date: Date(), images: datas, isConfigured: true)
    }
}
