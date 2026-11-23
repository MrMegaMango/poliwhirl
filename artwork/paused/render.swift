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
        let muteRed = color(0.95, 0.10, 0.16)
        let pauseYellow = color(1.0, 0.80, 0.08)

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
        // spiral stay recognizable alongside its expressive little mouth.
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

        // Leave a blue strip above the belly for expressions, without covering
        // the spiral or putting separate controls beside the character.
        ellipse(NSRect(x: 4.05, y: 3.75, width: 11.3, height: 8), fill: white, outline: false)
        let spiral = NSBezierPath()
        for index in 0...160 {
            let progress = Double(index) / 160
            let angle = progress * 3.8 * Double.pi
            let radius = 0.2 + 3.8 * progress
            let point = NSPoint(x: 9.7 + CGFloat(cos(angle) * radius),
                                y: 7.8 + CGFloat(sin(angle) * radius * 0.72))
            if index == 0 { spiral.move(to: point) } else { spiral.line(to: point) }
        }
        ink.setStroke()
        spiral.lineWidth = 0.95
        spiral.lineCapStyle = .round
        spiral.lineJoinStyle = .round
        spiral.stroke()

        let mouth = NSBezierPath()
        mouth.lineWidth = 0.75
        mouth.lineCapStyle = .round
        ink.setStroke()
        switch state {
        case .ready:
            mouth.move(to: NSPoint(x: 8.1, y: 12.8))
            mouth.curve(to: NSPoint(x: 11.3, y: 12.8),
                        controlPoint1: NSPoint(x: 8.8, y: 11.8),
                        controlPoint2: NSPoint(x: 10.6, y: 11.8))
            mouth.stroke()
        case .speaking:
            ellipse(NSRect(x: 8.5, y: 11.9, width: 2.4, height: 1.9), fill: ink, outline: false)
            ellipse(NSRect(x: 9, y: 12.05, width: 1.4, height: 0.55),
                    fill: color(0.99, 0.58, 0.65), outline: false)
        case .paused:
            // A broad yellow closed mouth makes pause visible at menu-bar size.
            let restingMouth = NSBezierPath(
                roundedRect: NSRect(x: 6.5, y: 10.8, width: 6.4, height: 2.4),
                xRadius: 0.8, yRadius: 0.8)
            white.setStroke(); restingMouth.lineWidth = 0.6; restingMouth.stroke()
            pauseYellow.setFill(); restingMouth.fill()
            mouth.move(to: NSPoint(x: 7.5, y: 12))
            mouth.line(to: NSPoint(x: 11.9, y: 12))
            ink.setStroke(); mouth.lineWidth = 0.65
            mouth.stroke()
        case .muted:
            // A broad red mouth stays visible at menu-bar size; white zipper
            // teeth also distinguish mute from the paused expression by shape.
            let sealedMouth = NSBezierPath(
                roundedRect: NSRect(x: 6.5, y: 10.8, width: 6.4, height: 2.4),
                xRadius: 0.8, yRadius: 0.8)
            white.setStroke(); sealedMouth.lineWidth = 0.6; sealedMouth.stroke()
            muteRed.setFill(); sealedMouth.fill()
            mouth.move(to: NSPoint(x: 7.3, y: 12))
            mouth.line(to: NSPoint(x: 12.1, y: 12))
            white.setStroke(); mouth.lineWidth = 0.55
            for x: CGFloat in [8.1, 9.7, 11.3] {
                mouth.move(to: NSPoint(x: x, y: 11.55))
                mouth.line(to: NSPoint(x: x, y: 12.45))
            }
            mouth.stroke()
        }

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

        if state == .muted {
            // Replace the blue sparkle with a bold red cross for an extra cue
            // that remains legible without relying on the mouth's color alone.
            let muteMark = NSBezierPath()
            muteMark.move(to: NSPoint(x: 19.5, y: 7.35))
            muteMark.line(to: NSPoint(x: 22.7, y: 10.85))
            muteMark.move(to: NSPoint(x: 19.5, y: 10.85))
            muteMark.line(to: NSPoint(x: 22.7, y: 7.35))
            muteMark.lineCapStyle = .round
            white.setStroke(); muteMark.lineWidth = 2.4; muteMark.stroke()
            muteRed.setStroke(); muteMark.lineWidth = 1.6; muteMark.stroke()
        } else if state == .paused {
            // Yellow pause bars give a clear shape cue on light and dark bars.
            let pauseMark = NSBezierPath()
            for x: CGFloat in [19.6, 22.5] {
                pauseMark.move(to: NSPoint(x: x, y: 7.35))
                pauseMark.line(to: NSPoint(x: x, y: 10.85))
            }
            pauseMark.lineCapStyle = .round
            white.setStroke(); pauseMark.lineWidth = 2.6; pauseMark.stroke()
            ink.setStroke(); pauseMark.lineWidth = 2; pauseMark.stroke()
            pauseYellow.setStroke(); pauseMark.lineWidth = 1.4; pauseMark.stroke()
        } else {
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

let output = CommandLine.arguments[1]
let canvas = NSImage(size: NSSize(width: 480, height: 300), flipped: false) { bounds in
    let states: [SpeechIconState] = [.ready, .speaking, .paused, .muted]
    for (dark, yBase) in [(false, CGFloat(150)), (true, CGFloat(0))] {
        NSColor(calibratedWhite: dark ? 0.10 : 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: yBase, width: 480, height: 150).fill()
        for (i, state) in states.enumerated() {
            let img = compose(state: state)
            let x = CGFloat(i) * 120 + 12
            img.draw(in: NSRect(x: x, y: yBase + 58, width: 96, height: 80))
            img.draw(in: NSRect(x: x + 36, y: yBase + 30, width: 24, height: 20))
            (state.rawValue as NSString).draw(at: NSPoint(x: x + 14, y: yBase + 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: dark ? NSColor.white : NSColor.black])
        }
    }
    return true
}
guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
try png.write(to: URL(fileURLWithPath: output))
