import Foundation
import UIKit
import Accelerate

/// Computes RGB histograms via Accelerate's vImage and renders them as a
/// SwiftUI `Canvas`. The compute step is `nonisolated` so callers run it
/// off-main via `Task.detached`.
enum Histogram {

    struct Data: Equatable {
        let red: [UInt]
        let green: [UInt]
        let blue: [UInt]
    }

    /// 256-bucket per-channel histogram. Returns nil if the image's pixel data
    /// cannot be obtained.
    nonisolated static func compute(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        var pixels = [UInt8](repeating: 0, count: byteCount)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var redHist = [vImagePixelCount](repeating: 0, count: 256)
        var greenHist = [vImagePixelCount](repeating: 0, count: 256)
        var blueHist = [vImagePixelCount](repeating: 0, count: 256)
        var alphaHist = [vImagePixelCount](repeating: 0, count: 256)

        let result = pixels.withUnsafeMutableBytes { pixelBytes in
            var buffer = vImage_Buffer(
                data: pixelBytes.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            return redHist.withUnsafeMutableBufferPointer { rPtr in
                greenHist.withUnsafeMutableBufferPointer { gPtr in
                    blueHist.withUnsafeMutableBufferPointer { bPtr in
                        alphaHist.withUnsafeMutableBufferPointer { aPtr in
                            var pointers: [UnsafeMutablePointer<vImagePixelCount>?] = [
                                rPtr.baseAddress, gPtr.baseAddress, bPtr.baseAddress, aPtr.baseAddress
                            ]
                            return pointers.withUnsafeMutableBufferPointer { p in
                                guard let baseAddress = p.baseAddress else {
                                    return vImage_Error(kvImageNullPointerArgument)
                                }
                                return vImageHistogramCalculation_ARGB8888(&buffer, baseAddress, vImage_Flags(kvImageNoFlags))
                            }
                        }
                    }
                }
            }
        }
        guard result == kvImageNoError else { return nil }

        return Data(
            red: redHist.map { UInt($0) },
            green: greenHist.map { UInt($0) },
            blue: blueHist.map { UInt($0) }
        )
    }
}
