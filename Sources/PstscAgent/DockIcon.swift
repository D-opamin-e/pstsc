import AppKit

/// A generic "window with four panes" icon for the Dock button.
enum DockIcon {
    static func make() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 100, yRadius: 100)
            NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.47, blue: 0.95, alpha: 1),
                       ending: NSColor(calibratedRed: 0.02, green: 0.25, blue: 0.70, alpha: 1))?
                .draw(in: background, angle: -90)

            NSColor.white.setFill()
            let pane: CGFloat = 130, gap: CGFloat = 16
            let originX = rect.midX - pane - gap / 2, originY = rect.midY - pane - gap / 2
            for row in 0..<2 {
                for col in 0..<2 {
                    let paneRect = NSRect(x: originX + CGFloat(col) * (pane + gap),
                                          y: originY + CGFloat(row) * (pane + gap), width: pane, height: pane)
                    NSBezierPath(roundedRect: paneRect, xRadius: 10, yRadius: 10).fill()
                }
            }
            return true
        }
    }
}
