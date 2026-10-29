// Draws the DMG window background: an arrow from the app (left) to Applications (right).
// 사용법: swift scripts/dmg-background.swift <output.png>
import AppKit

let size = NSSize(width: 600, height: 380)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// Arrow between the two icons (icons sit at x 150 and 450, y 190 from the top).
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 245, y: 190))
arrow.line(to: NSPoint(x: 345, y: 190))
arrow.move(to: NSPoint(x: 325, y: 206))
arrow.line(to: NSPoint(x: 347, y: 190))
arrow.line(to: NSPoint(x: 325, y: 174))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
arrow.stroke()

let text = "Drag Pstsc to Applications  ·  Pstsc를 응용 프로그램 폴더로 끌어 놓으세요"
let style = NSMutableParagraphStyle()
style.alignment = .center
text.draw(in: NSRect(x: 20, y: 40, width: size.width - 40, height: 24), withAttributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1),
    .paragraphStyle: style,
])
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
