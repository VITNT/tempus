// Renders the DMG window background: usage `swift dmg-background.swift <out.tiff>`.
// Draws at 1× and 2× and combines them, so Retina Finder windows stay sharp.
import AppKit

let size = NSSize(width: 640, height: 400)
let output = URL(filePath: CommandLine.arguments[1])

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1),
                        NSColor(srgbRed: 0.90, green: 0.92, blue: 0.97, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Arrow from the app icon (x 170) to the Applications folder (x 470), icons centred at y 190 from the top.
    let y = size.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y))
    arrow.line(to: NSPoint(x: 370, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    let tint = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.55, alpha: 0.75)
    tint.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 356, y: y + 14))
    head.line(to: NSPoint(x: 376, y: y))
    head.line(to: NSPoint(x: 356, y: y - 14))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let title = NSAttributedString(string: "Drag Tempus into Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
        .paragraphStyle: style,
    ])
    title.draw(in: NSRect(x: 0, y: 62, width: size.width, height: 24))
    let note = NSAttributedString(string: "Then open Tempus from Launchpad or your Applications folder.", attributes: [
        .font: NSFont.systemFont(ofSize: 12.5),
        .foregroundColor: NSColor(srgbRed: 0.38, green: 0.41, blue: 0.48, alpha: 1),
        .paragraphStyle: style,
    ])
    note.draw(in: NSRect(x: 0, y: 40, width: size.width, height: 20))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
guard let tiff = image.tiffRepresentation(using: .lzw, factor: 0) else { fatalError("Could not encode the background") }
try tiff.write(to: output)
