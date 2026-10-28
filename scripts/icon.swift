import AppKit

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.07, y: p * 0.07, width: p * 0.86, height: p * 0.86)
        let background = NSBezierPath(roundedRect: rect, xRadius: p * 0.20, yRadius: p * 0.20)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.61, blue: 0.62, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.03, green: 0.30, blue: 0.40, alpha: 1))!
        gradient.draw(in: background, angle: -70)
        let sail = NSBezierPath()
        sail.move(to: NSPoint(x: p * 0.47, y: p * 0.72))
        sail.line(to: NSPoint(x: p * 0.47, y: p * 0.40))
        sail.line(to: NSPoint(x: p * 0.23, y: p * 0.40))
        sail.close()
        NSColor.white.setFill(); sail.fill()
        let smallSail = NSBezierPath()
        smallSail.move(to: NSPoint(x: p * 0.53, y: p * 0.65))
        smallSail.line(to: NSPoint(x: p * 0.75, y: p * 0.40))
        smallSail.line(to: NSPoint(x: p * 0.53, y: p * 0.40))
        smallSail.close()
        NSColor.white.withAlphaComponent(0.76).setFill(); smallSail.fill()
        let hull = NSBezierPath()
        hull.move(to: NSPoint(x: p * 0.23, y: p * 0.35))
        hull.line(to: NSPoint(x: p * 0.77, y: p * 0.35))
        hull.curve(to: NSPoint(x: p * 0.63, y: p * 0.24), controlPoint1: NSPoint(x: p * 0.72, y: p * 0.27), controlPoint2: NSPoint(x: p * 0.69, y: p * 0.24))
        hull.line(to: NSPoint(x: p * 0.37, y: p * 0.24))
        hull.close()
        NSColor.white.setFill(); hull.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
}

// ICNS permits PNG payloads. Write the container directly so this build does not
// depend on iconutil's helper processes being available in a sandboxed session.
if CommandLine.arguments.count > 2 {
    let representations = [
        ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png")
    ]
    func integer(_ value: Int) -> Data {
        var bigEndian = UInt32(value).bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    var chunks = Data()
    for (type, filename) in representations {
        let payload = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(filename))
        chunks.append(Data(type.utf8))
        chunks.append(integer(payload.count + 8))
        chunks.append(payload)
    }
    var icon = Data("icns".utf8)
    icon.append(integer(chunks.count + 8))
    icon.append(chunks)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
