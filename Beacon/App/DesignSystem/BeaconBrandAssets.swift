import AppKit
import SwiftUI

enum BeaconBrandAssets {
    static let appIcon = image(named: "AppIcon")
    static let logo: NSImage? = {
        let loadedImage = image(named: "BeaconLogo")
        loadedImage?.isTemplate = true
        return loadedImage
    }()
    static let menuBarLogo: NSImage? = {
        guard let logo, let menuBarImage = logo.copy() as? NSImage else { return nil }
        let height: CGFloat = 14
        menuBarImage.size = NSSize(width: height * logo.size.width / logo.size.height, height: height)
        menuBarImage.isTemplate = true
        return menuBarImage
    }()

    private static func image(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct BeaconLogo: View {
    enum Appearance {
        case brand
        case white
    }

    var appearance: Appearance = .brand

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .brand:
            logo.foregroundStyle(BeaconPalette.blueViolet)
        case .white:
            logo.foregroundStyle(.white)
        }
    }

    private var logo: some View {
        Image(nsImage: sourceImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }

    private var sourceImage: NSImage {
        BeaconBrandAssets.logo
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Beacon")
            ?? NSImage(size: NSSize(width: 1, height: 1))
    }
}

struct BeaconMenuBarLogo: View {
    var body: some View {
        Image(nsImage: sourceImage)
            .renderingMode(.template)
            .accessibilityLabel("Beacon")
    }

    private var sourceImage: NSImage {
        BeaconBrandAssets.menuBarLogo
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Beacon")
            ?? NSImage(size: NSSize(width: 14, height: 14))
    }
}
