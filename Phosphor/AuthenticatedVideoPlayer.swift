import AVFoundation

/// Creates an AVPlayerItem that sends `x-api-key` as a request header instead
/// of appending the key as a query parameter (which would leak it in logs and
/// server-side access records).
func makeAuthenticatedPlayerItem(for url: URL, apiKey: String) -> AVPlayerItem {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetHTTPHeaderFieldsKey: ["x-api-key": apiKey]]
    )
    return AVPlayerItem(asset: asset)
}
