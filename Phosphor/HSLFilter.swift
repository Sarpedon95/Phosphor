import CoreImage

/// Wraps `HSLKernel.metal`'s `hslAdjust` colour kernel as a reusable filter.
///
/// If the Metal library can't be loaded (e.g. the `.metal` file wasn't
/// compiled into the bundle) the filter degrades to a pass-through so the
/// editing pipeline never crashes — the rest of the adjustments still apply.
final class HSLFilter {

    /// 24 floats: 8 channels × (hue −0.5…+0.5, sat −1…+1, lum −1…+1).
    var hslValues: [Float] = Array(repeating: 0, count: 24)
    var inputImage: CIImage?

    private static let kernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            return loadFromDefaultLibrary()
        }
        return try? CIColorKernel(functionName: "hslAdjust", fromMetalLibraryData: data)
    }()

    private static func loadFromDefaultLibrary() -> CIColorKernel? {
        // Fallback: the kernel may be linked into the app's default metallib.
        guard let data = try? Data(
            contentsOf: Bundle.main.bundleURL
                .appendingPathComponent("default.metallib")
        ) else { return nil }
        return try? CIColorKernel(functionName: "hslAdjust", fromMetalLibraryData: data)
    }

    var outputImage: CIImage? {
        guard let inputImage else { return nil }
        guard let kernel = Self.kernel else {
            // Metal kernel unavailable — pass through untouched.
            return inputImage
        }
        // Pack 24 floats into 6 CIVectors (float4 each) in the order the
        // kernel unpacks them.
        var vectors: [CIVector] = []
        vectors.reserveCapacity(6)
        for group in 0..<6 {
            let base = group * 4
            vectors.append(CIVector(
                x: CGFloat(hslValues[base]),
                y: CGFloat(hslValues[base + 1]),
                z: CGFloat(hslValues[base + 2]),
                w: CGFloat(hslValues[base + 3])
            ))
        }
        return kernel.apply(
            extent: inputImage.extent,
            roiCallback: { _, rect in rect },
            arguments: [inputImage] + vectors
        )
    }
}
