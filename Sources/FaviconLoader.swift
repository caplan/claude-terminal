import AppKit

enum FaviconLoader {
    private static var cache: [String: NSImage?] = [:]

    static func favicon(for directory: String?, size: CGFloat = 16) -> NSImage? {
        guard let directory else { return nil }
        if let cached = cache[directory] { return cached }
        let image = findFavicon(in: directory, size: size)
        cache[directory] = image
        return image
    }

    private static let relativePaths: [String] = [
        "favicon.ico", "favicon.png", "icon.png", "icon.ico",
        "public/favicon.ico", "public/favicon.png", "public/icon.png",
        "static/favicon.ico", "static/favicon.png",
        "app/favicon.ico", "app/icon.png",
        "assets/favicon.ico",
        "src/main/resources/static/favicon.ico",
        "src/main/webapp/favicon.ico",
        "wwwroot/favicon.ico",
        "build/icon.png",
        "src-tauri/icons/32x32.png",
    ]

    private static func findFavicon(in directory: String, size: CGFloat) -> NSImage? {
        let fm = FileManager.default

        for rel in relativePaths {
            let path = (directory as NSString).appendingPathComponent(rel)
            if fm.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                return scaled(img, to: size)
            }
        }

        if let img = findAppIcon(in: directory) {
            return scaled(img, to: size)
        }

        if let img = findAndroidIcon(in: directory) {
            return scaled(img, to: size)
        }

        return nil
    }

    private static func findAppIcon(in directory: String) -> NSImage? {
        let fm = FileManager.default
        let knownPaths = [
            "Assets.xcassets/AppIcon.appiconset",
            "Resources/Assets.xcassets/AppIcon.appiconset",
            "Sources/Assets.xcassets/AppIcon.appiconset",
            "App/Assets.xcassets/AppIcon.appiconset",
            "ios/App/Assets.xcassets/AppIcon.appiconset",
        ]
        for base in knownPaths {
            let iconDir = (directory as NSString).appendingPathComponent(base)
            guard fm.fileExists(atPath: iconDir) else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: iconDir) else { continue }
            if let png = contents.first(where: { $0.hasSuffix(".png") }) {
                let full = (iconDir as NSString).appendingPathComponent(png)
                if let img = NSImage(contentsOfFile: full) { return img }
            }
        }
        return nil
    }

    private static func findAndroidIcon(in directory: String) -> NSImage? {
        let fm = FileManager.default
        let densities = ["mipmap-xxxhdpi", "mipmap-xxhdpi", "mipmap-xhdpi", "mipmap-hdpi", "mipmap-mdpi"]
        let resPaths = [
            "app/src/main/res",
            "src/main/res",
        ]
        for resPath in resPaths {
            for density in densities {
                let iconDir = (directory as NSString).appendingPathComponent("\(resPath)/\(density)")
                guard fm.fileExists(atPath: iconDir) else { continue }
                guard let contents = try? fm.contentsOfDirectory(atPath: iconDir) else { continue }
                if let icon = contents.first(where: { $0.contains("ic_launcher") && ($0.hasSuffix(".webp") || $0.hasSuffix(".png")) }) {
                    let full = (iconDir as NSString).appendingPathComponent(icon)
                    if let img = NSImage(contentsOfFile: full) { return img }
                }
            }
        }
        return nil
    }

    private static var dominantColorCache: [String: NSColor] = [:]

    static func dominantColor(for directory: String?) -> NSColor? {
        guard let directory else { return nil }
        if let cached = dominantColorCache[directory] { return cached }
        guard let img = favicon(for: directory, size: 32) else { return nil }
        guard let color = extractDominantColor(from: img) else { return nil }
        dominantColorCache[directory] = color
        return color
    }

    private static func extractDominantColor(from image: NSImage) -> NSColor? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        let w = bitmap.pixelsWide
        let h = bitmap.pixelsHigh
        guard w > 0, h > 0 else { return nil }

        var totalR = 0.0, totalG = 0.0, totalB = 0.0
        var count = 0.0
        let step = max(1, min(w, h) / 8)

        for x in stride(from: 0, to: w, by: step) {
            for y in stride(from: 0, to: h, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                let a = color.alphaComponent
                guard a > 0.3 else { continue }
                totalR += color.redComponent
                totalG += color.greenComponent
                totalB += color.blueComponent
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let avg = NSColor(
            red: totalR / count,
            green: totalG / count,
            blue: totalB / count,
            alpha: 1
        )
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alp: CGFloat = 0
        avg.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
        guard sat > 0.05 else { return nil }
        return avg
    }

    private static func scaled(_ image: NSImage, to size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        scaled.unlockFocus()
        return scaled
    }
}
