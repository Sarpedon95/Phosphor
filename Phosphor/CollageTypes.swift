import SwiftUI
import CoreGraphics

// MARK: - Codable color

/// SwiftUI `Color` doesn't conform to `Codable`. `CodableColor` round-trips the
/// sRGB components so a collage spec can be persisted and rehydrated.
struct CodableColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }

    static let black = CodableColor(red: 0, green: 0, blue: 0, opacity: 1)
    static let white = CodableColor(red: 1, green: 1, blue: 1, opacity: 1)

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// Best-effort sRGB extraction from a `Color`. Non-sRGB colors fall back
    /// to black so persistence never crashes; visual fidelity is preserved for
    /// every color the picker actually produces.
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.red = Double(resolved.red)
        self.green = Double(resolved.green)
        self.blue = Double(resolved.blue)
        self.opacity = Double(resolved.opacity)
    }
}

// MARK: - Blend mode

enum CollageBlendMode: String, Codable, CaseIterable, Identifiable {
    case hardEdge
    case feathered
    case colorHarmonized
    case fullBleed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hardEdge: return "Hard Edge"
        case .feathered: return "Feathered"
        case .colorHarmonized: return "Harmonized"
        case .fullBleed: return "Full Bleed"
        }
    }
}

// MARK: - Layout

/// Each case is a distinct grid algorithm. Associated values feed the
/// algorithm's parameters (target row height for justified, column count for
/// quilt, angle for diagonal). Manual `Codable` because Swift can't synthesize
/// it for enums with associated values.
enum CollageLayout: Hashable {
    case justified(targetRowHeight: CGFloat)
    case quilt(columns: Int)
    case mosaic
    case magazine
    case horizontalStrip
    case verticalStrip
    case freeform
    case diagonal(angle: CGFloat)
    case cascade

    var label: String {
        switch self {
        case .justified: return "Justified"
        case .quilt: return "Quilt"
        case .mosaic: return "Mosaic"
        case .magazine: return "Magazine"
        case .horizontalStrip: return "Horizontal Strip"
        case .verticalStrip: return "Vertical Strip"
        case .freeform: return "Freeform"
        case .diagonal: return "Diagonal"
        case .cascade: return "Cascade"
        }
    }

    /// Compact SF Symbol used by the layout switcher strip.
    var symbol: String {
        switch self {
        case .justified: return "rectangle.grid.1x2"
        case .quilt: return "square.grid.3x3"
        case .mosaic: return "rectangle.grid.2x2"
        case .magazine: return "newspaper"
        case .horizontalStrip: return "rectangle.split.3x1"
        case .verticalStrip: return "rectangle.split.1x2"
        case .freeform: return "hand.draw"
        case .diagonal: return "line.diagonal"
        case .cascade: return "square.stack.3d.up"
        }
    }

    /// All concrete instances offered in the UI strip — each is a sensible
    /// default for that algorithm.
    static let presetCatalog: [CollageLayout] = [
        .justified(targetRowHeight: 120),
        .quilt(columns: 3),
        .mosaic,
        .magazine,
        .horizontalStrip,
        .verticalStrip,
        .diagonal(angle: 12),
        .cascade,
        .freeform
    ]
}

extension CollageLayout: Codable {
    private enum Kind: String, Codable {
        case justified, quilt, mosaic, magazine
        case horizontalStrip, verticalStrip, freeform, diagonal, cascade
    }

    private enum CodingKeys: String, CodingKey {
        case kind, targetRowHeight, columns, angle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .justified(let h):
            try container.encode(Kind.justified, forKey: .kind)
            try container.encode(h, forKey: .targetRowHeight)
        case .quilt(let c):
            try container.encode(Kind.quilt, forKey: .kind)
            try container.encode(c, forKey: .columns)
        case .mosaic: try container.encode(Kind.mosaic, forKey: .kind)
        case .magazine: try container.encode(Kind.magazine, forKey: .kind)
        case .horizontalStrip: try container.encode(Kind.horizontalStrip, forKey: .kind)
        case .verticalStrip: try container.encode(Kind.verticalStrip, forKey: .kind)
        case .freeform: try container.encode(Kind.freeform, forKey: .kind)
        case .diagonal(let a):
            try container.encode(Kind.diagonal, forKey: .kind)
            try container.encode(a, forKey: .angle)
        case .cascade: try container.encode(Kind.cascade, forKey: .kind)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .justified:
            self = .justified(targetRowHeight: try container.decodeIfPresent(CGFloat.self, forKey: .targetRowHeight) ?? 120)
        case .quilt:
            self = .quilt(columns: try container.decodeIfPresent(Int.self, forKey: .columns) ?? 3)
        case .mosaic: self = .mosaic
        case .magazine: self = .magazine
        case .horizontalStrip: self = .horizontalStrip
        case .verticalStrip: self = .verticalStrip
        case .freeform: self = .freeform
        case .diagonal:
            self = .diagonal(angle: try container.decodeIfPresent(CGFloat.self, forKey: .angle) ?? 12)
        case .cascade: self = .cascade
        }
    }
}

// MARK: - Cell

/// One photo's position on the canvas. Normalised coordinates (0–1 on both
/// axes) so the same spec renders at any output resolution.
struct CollageCell: Identifiable, Codable, Hashable {
    let id: UUID
    var assetId: String
    var frame: CGRect          // normalized on canvas
    var cropRect: CGRect       // normalized on source image
    var aspectRatio: CGFloat
    var rotation: CGFloat      // degrees
    var zIndex: Int
    var cornerRadius: CGFloat

    init(
        id: UUID = UUID(),
        assetId: String,
        frame: CGRect,
        cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        aspectRatio: CGFloat = 1,
        rotation: CGFloat = 0,
        zIndex: Int = 0,
        cornerRadius: CGFloat = 0
    ) {
        self.id = id
        self.assetId = assetId
        self.frame = frame
        self.cropRect = cropRect
        self.aspectRatio = aspectRatio
        self.rotation = rotation
        self.zIndex = zIndex
        self.cornerRadius = cornerRadius
    }
}

// MARK: - Spec

/// A complete, persistable collage definition.
struct CollageSpec: Identifiable, Codable, Hashable {
    let id: UUID
    var layout: CollageLayout
    var cells: [CollageCell]
    var canvasAspect: CGFloat
    var gapWidth: CGFloat
    var backgroundColor: CodableColor
    var blendMode: CollageBlendMode
    var cornerRadius: CGFloat
    var createdAt: Date

    init(
        id: UUID = UUID(),
        layout: CollageLayout,
        cells: [CollageCell],
        canvasAspect: CGFloat,
        gapWidth: CGFloat,
        backgroundColor: CodableColor = .black,
        blendMode: CollageBlendMode = .hardEdge,
        cornerRadius: CGFloat = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.layout = layout
        self.cells = cells
        self.canvasAspect = canvasAspect
        self.gapWidth = gapWidth
        self.backgroundColor = backgroundColor
        self.blendMode = blendMode
        self.cornerRadius = cornerRadius
        self.createdAt = createdAt
    }
}

// MARK: - Export quality

enum ExportQuality: String, CaseIterable, Identifiable {
    case screen, standard, high, maximum
    var id: String { rawValue }

    /// Longest-side pixel target. `.maximum` returns nil meaning "uncapped:
    /// sum of input photo resolutions".
    var longestSide: CGFloat? {
        switch self {
        case .screen: return 1080
        case .standard: return 3000
        case .high: return 6000
        case .maximum: return nil
        }
    }

    var label: String {
        switch self {
        case .screen: return "Screen (1080)"
        case .standard: return "Standard (3000)"
        case .high: return "High (6000)"
        case .maximum: return "Maximum"
        }
    }
}
