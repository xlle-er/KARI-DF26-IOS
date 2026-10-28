import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Mechanical raster export of the approved Apple Icon Composer rendering.
// Usage: input.png output.png pixels [opaque|alpha|foreground] [artworkScale]
let args = CommandLine.arguments
guard args.count >= 4, let size = Int(args[3]), size > 0,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Expected input.png output.png pixels [opaque|alpha|foreground] [scale]")
}
let mode = args.count > 4 ? args[4] : "opaque"
let artworkScale = args.count > 5 ? Double(args[5])! : 1.0
let alpha = mode == "opaque" ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: alpha.rawValue) else { fatalError("No raster context") }
context.interpolationQuality = .high
if mode == "opaque" {
    context.setFillColor(CGColor(srgbRed: 0.973, green: 0.980, blue: 0.992, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
}
let side = Double(size) * artworkScale
let offset = (Double(size) - side) / 2
if mode == "foreground" {
    // Clip the official rendering to the approved geometric K for adaptive icons.
    // Coordinates match branding/AppIcon.icon/Assets/KARI-Mark.svg.
    let points: [(Double, Double)] = [(278,264),(402,264),(402,450),(588,264),
        (774,264),(526,512),(774,760),(588,760),(402,574),(402,760),(278,760)]
    let path = CGMutablePath()
    for (index, point) in points.enumerated() {
        let x = point.0 - 512, y = point.1 - 512
        let r = -Double.pi / 4
        let rx = cos(r) * x - sin(r) * y + 512
        let ry = sin(r) * x + cos(r) * y + 512
        let p = CGPoint(x: offset + rx * side / 1024, y: offset + (1024 - ry) * side / 1024)
        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    context.addPath(path)
    context.clip()
}
context.draw(image, in: CGRect(x: offset, y: offset, width: side, height: side))
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot create output PNG") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
