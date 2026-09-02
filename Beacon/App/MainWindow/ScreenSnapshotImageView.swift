import AppKit
import ImageIO
import SwiftUI

/// Decodes a potentially large PNG away from the main actor and keeps the result across
/// unrelated controller updates so an open Privacy or Inspector view stays responsive.
struct ScreenSnapshotImageView: View {
    let snapshot: ScreenSnapshot
    let variant: String
    let maximumHeight: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maximumHeight)
        .task(id: identity) {
            image = nil
            guard let decoded = await Task.detached(priority: .utility, operation: {
                guard let source = CGImageSourceCreateWithData(snapshot.pngData as CFData, nil) else {
                    return nil as CGImage?
                }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }).value, !Task.isCancelled else { return }
            image = NSImage(cgImage: decoded, size: .zero)
        }
    }

    private var identity: SnapshotImageIdentity {
        SnapshotImageIdentity(
            capturedAt: snapshot.capturedAt,
            pixelWidth: snapshot.pixelWidth,
            pixelHeight: snapshot.pixelHeight,
            byteCount: snapshot.pngData.count,
            redactionCount: snapshot.redactionCount,
            variant: variant
        )
    }
}

private struct SnapshotImageIdentity: Hashable {
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let redactionCount: Int
    let variant: String
}
