// Run from the repository root:
// swiftc -O -module-cache-path /tmp/opaline-icon-cache OpalineTV/Scripts/generate_app_icons.swift -o /tmp/opaline-tv-icons
// /tmp/opaline-tv-icons
// Reuses the upstream transparent mark without changing iOS artwork.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Opaline/Assets.xcassets/SplashMark.imageset/SplashMark@3x.png")
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let mark = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("Cannot read the transparent logo")
}
let assets = root.appendingPathComponent("OpalineTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

func render(width: Int, height: Int, foreground: Bool) -> CGImage {
    let alpha: CGImageAlphaInfo = foreground ? .premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: alpha.rawValue)!
    if foreground {
        let markWidth = Double(height) * 0.55
        let markHeight = markWidth * Double(mark.height) / Double(mark.width)
        context.interpolationQuality = .high
        context.draw(mark, in: CGRect(x: (Double(width) - markWidth) / 2,
                                     y: (Double(height) - markHeight) / 2,
                                     width: markWidth, height: markHeight))
    } else {
        // Match the light iOS icon background.
        context.setFillColor(CGColor(red: 245 / 255.0, green: 248 / 255.0,
                                     blue: 250 / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return context.makeImage()!
}

for (stack, scale, width, height) in [
    ("App Icon - Small", 1, 400, 240),
    ("App Icon - Small", 2, 800, 480),
    ("App Icon - App Store", 1, 1280, 768)
] {
    for foreground in [false, true] {
        let layer = foreground ? "Front" : "Back"
        let filename = foreground ? "icon" : "back"
        let url = assets.appendingPathComponent("\(stack).imagestack/\(layer).imagestacklayer/Content.imageset/\(filename)@\(scale)x.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, render(width: width, height: height, foreground: foreground), nil)
        precondition(CGImageDestinationFinalize(destination), "Cannot write \(url.path)")
        print(url.lastPathComponent, width, height, layer)
    }
}
