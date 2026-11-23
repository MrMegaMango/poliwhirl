import Cocoa
enum SpeechIconState: String {
    case ready = "Ready", speaking = "Speaking", paused = "Paused", muted = "Muted"
}

let glyph = NSSize(width: 24, height: 20)
let bounceFrameCount = 40
let bouncePeriod: TimeInterval = 0.85

func compose(state: SpeechIconState, bounce: CGFloat = 0) -> NSImage {
    let img = NSImage(size: glyph, flipped: false) { _ in
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: bounce)
        transform.concat()

        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        let ink = color(0.09, 0.14, 0.22)
        let blue = color(0.19, 0.48, 0.87)
        let shadow = color(0.13, 0.35, 0.70)
        let white = color(0.97, 0.98, 0.96)
        let rim = color(0.70, 0.83, 0.94)

        func ellipse(_ rect: NSRect, fill: NSColor, outline: Bool = true) {
            let path = NSBezierPath(ovalIn: rect)
            if outline {
                rim.setStroke(); path.lineWidth = 1.05; path.stroke()
            }
            fill.setFill(); path.fill()
            if outline {
                ink.setStroke(); path.lineWidth = 0.45; path.stroke()
            }
        }

        // Poliwhirl's round blue body, raised eyes, little gloves, and large
        // spiral stay recognizable without facial detail at menu-bar size.
        ellipse(NSRect(x: 3.4, y: 1.4, width: 5, height: 2.5), fill: shadow)
        ellipse(NSRect(x: 11, y: 1.4, width: 5, height: 2.5), fill: shadow)
        ellipse(NSRect(x: 1.4, y: 7.3, width: 4.6, height: 3), fill: blue)
        ellipse(NSRect(x: 13.4, y: 7.3, width: 4.6, height: 3), fill: blue)
        ellipse(NSRect(x: 3, y: 3, width: 13.4, height: 12), fill: blue)
        ellipse(NSRect(x: 4.2, y: 12.5, width: 4.5, height: 4.5), fill: blue)
        ellipse(NSRect(x: 10.7, y: 12.5, width: 4.5, height: 4.5), fill: blue)

        // Eye whites nest inside the blue bumps; sleeping eyelids mark pause.
        for x: CGFloat in [5.1, 11.6] {
            if state == .paused {
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: x, y: 14.5))
                lid.curve(to: NSPoint(x: x + 2.4, y: 14.5),
                          controlPoint1: NSPoint(x: x + 0.6, y: 14),
                          controlPoint2: NSPoint(x: x + 1.8, y: 14))
                ink.setStroke(); lid.lineWidth = 0.7; lid.lineCapStyle = .round; lid.stroke()
            } else {
                ellipse(NSRect(x: x, y: 13.35, width: 2.55, height: 3.05), fill: white, outline: false)
                ellipse(NSRect(x: x + 0.9, y: 13.55, width: 1, height: 2.4), fill: ink, outline: false)
            }
        }

        ellipse(NSRect(x: 4.05, y: 3.75, width: 11.3, height: 9.1), fill: white, outline: false)
        let spiral = NSBezierPath()
        for index in 0...160 {
            let progress = Double(index) / 160
            let angle = progress * 3.8 * Double.pi
            let radius = 0.2 + 3.8 * progress
            let point = NSPoint(x: 9.7 + CGFloat(cos(angle) * radius),
                                y: 8.3 + CGFloat(sin(angle) * radius * 0.83))
            if index == 0 { spiral.move(to: point) } else { spiral.line(to: point) }
        }
        ink.setStroke()
        spiral.lineWidth = 0.95
        spiral.lineCapStyle = .round
        spiral.lineJoinStyle = .round
        spiral.stroke()

        // The raised glove pose accompanies speech without changing its timing.
        let gloveLift: CGFloat = state == .speaking ? 0.6 : 0
        ellipse(NSRect(x: 0.75, y: 7.15 + gloveLift, width: 3.65, height: 4.15), fill: white)
        ellipse(NSRect(x: 15.15, y: 7.15 + gloveLift, width: 3.65, height: 4.15), fill: white)
        let thumbs = NSBezierPath()
        thumbs.move(to: NSPoint(x: 2.75, y: 9.6 + gloveLift))
        thumbs.line(to: NSPoint(x: 3.25, y: 8.8 + gloveLift))
        thumbs.move(to: NSPoint(x: 16.75, y: 9.6 + gloveLift))
        thumbs.line(to: NSPoint(x: 16.25, y: 8.8 + gloveLift))
        ink.setStroke(); thumbs.lineWidth = 0.45; thumbs.lineCapStyle = .round; thumbs.stroke()

        if state == .paused || state == .muted {
            // A pale backing keeps the status badge clear on either theme.
            white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 17.2, y: 1.7, width: 6.6, height: 6.8),
                         xRadius: 1.5, yRadius: 1.5).fill()
            if state == .paused {
                ink.setFill()
                for x: CGFloat in [18.6, 21] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 3, width: 1.3, height: 4.2),
                                 xRadius: 0.3, yRadius: 0.3).fill()
                }
            } else {
                let badge = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
                badge?.draw(in: NSRect(x: 17.7, y: 2.5, width: 5.7, height: 5.3),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
        } else {
            // A small glint keeps the AI cue beside the mascot.
            let glint = NSBezierPath()
            glint.move(to: NSPoint(x: 21.25, y: 11.25))
            for point in [NSPoint(x: 21.9, y: 9.75), NSPoint(x: 23.4, y: 9.1),
                          NSPoint(x: 21.9, y: 8.45), NSPoint(x: 21.25, y: 6.95),
                          NSPoint(x: 20.6, y: 8.45), NSPoint(x: 19.1, y: 9.1),
                          NSPoint(x: 20.6, y: 9.75)] { glint.line(to: point) }
            glint.close()
            rim.setStroke(); glint.lineWidth = 0.45; glint.stroke()
            color(0.44, 0.73, 0.98).setFill(); glint.fill()
        }
        return true
    }
    img.isTemplate = false
    return img
}


let readyImg = compose(state: .ready)
let pausedImg = compose(state: .paused)
let mutedImg = compose(state: .muted)
let speakingFrames = (0..<bounceFrameCount).map { index in
    let phase = Double(index) / Double(bounceFrameCount)
    let lift = 2 * pow(sin(.pi * phase), 2)
    return compose(state: .speaking, bounce: CGFloat(lift))
}

let canvas = NSImage(size: NSSize(width: 480, height: 260), flipped: false) { bounds in
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSRect(x: 0, y: 130, width: 480, height: 130).fill()
    NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 480, height: 130).fill()
    let states: [SpeechIconState] = [.ready, .speaking, .paused, .muted]
    for (i, state) in states.enumerated() {
        let img = compose(state: state, bounce: state == .speaking ? 2 : 0)
        let x = CGFloat(i) * 120 + 12
        img.draw(in: NSRect(x: x, y: 168, width: 96, height: 80))
        img.draw(in: NSRect(x: x, y: 38, width: 96, height: 80))
        (state.rawValue as NSString).draw(at: NSPoint(x: x + 13, y: 143), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        (state.rawValue as NSString).draw(at: NSPoint(x: x + 13, y: 13), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
    }
    return true
}
guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Rendered actual icon artwork in light and dark treatments")
