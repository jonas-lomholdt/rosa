// Turns the source logo into a macOS app icon.
// Usage: swift scripts/make-icon.swift <source.png> <output-1024.png>
//
// The source has a fake (baked-in) checkerboard background. We find the coloured
// rounded square by looking for saturated pixels (the checkerboard is grey), crop it,
// and redraw it on Apple's 1024px icon grid (824px artwork, ~185px corner radius),
// clipped to a rounded rect so no background survives at the corners.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("usage: make-icon.swift <source.png> <output.png>")
}

// Render into a known RGBA buffer so we can scan pixels.
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let scanContext = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
scanContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

// Bounding box of saturated (non-grey) pixels = the icon artwork. Rows are top-down in the buffer.
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        if max(r, g, b) - min(r, g, b) > 60 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// The artwork is square; its unsaturated bottom (the white browser card) can hide the
// lower edge from the colour scan, so take the size from the wider dimension.
let side = max(maxX - minX, maxY - minY) + 1
let crop = CGRect(x: minX, y: minY, width: side, height: side)
print("artwork bounds: \(crop)")
guard let artwork = image.cropping(to: crop) else { fatalError("crop failed") }

// Apple macOS icon grid: 1024 canvas, 824 artwork centred.
let canvas = 1024, artworkSize: CGFloat = 824
let origin = (CGFloat(canvas) - artworkSize) / 2

/// Superellipse |x|^n + |y|^n = 1 ("squircle"). n = 4 matches the source logo's corners
/// (measured); `shrink` pulls the edge in so no anti-aliased background survives.
func squircle(in rect: CGRect, exponent n: CGFloat = 4, shrink: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2 - shrink, b = rect.height / 2 - shrink
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        )
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}
let output = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
output.interpolationQuality = .high
let rect = CGRect(x: origin, y: origin, width: artworkSize, height: artworkSize)
output.addPath(squircle(in: rect))
output.clip()
output.draw(artwork, in: rect)

guard let result = output.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil
      ) else { fatalError("could not write output") }
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)
print("wrote \(arguments[2])")
