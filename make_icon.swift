import AppKit

// 用 SF Symbol 画一个 1024x1024 的应用图标
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 80, dy: 80)
let path = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.45, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.40, alpha: 1)])!
    .draw(in: path, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
