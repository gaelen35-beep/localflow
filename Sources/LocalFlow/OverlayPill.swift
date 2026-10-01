import AppKit

/// What the overlay is currently telling you.
enum OverlayPhase {
    case listening(raw: Bool)
    case transcribing
    case cleaning
    case message(String)

    var label: String {
        switch self {
        case .listening(let raw): return raw ? "Listening · raw" : "Listening"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .message(let text): return text
        }
    }
}

/// Floating "island" at the top-centre of the screen: a little Millennium Falcon whose engine exhaust is the live mic waveform.
/// Never takes focus.
@MainActor
final class OverlayPill {
    /// Supplies the current mic loudness (0...1) while listening.
    var levelProvider: (() -> Float)?

    private let panel: NSPanel
    private let view = FalconView(frame: NSRect(x: 0, y: 0, width: 330, height: 54))
    private var timer: Timer?
    private var phase: OverlayPhase = .transcribing
    private var smoothed: CGFloat = 0
    private var startedAt = Date()

    init() {
        panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
    }

    func show(_ phase: OverlayPhase) {
        self.phase = phase
        view.label = phase.label

        if !panel.isVisible {
            startedAt = Date()
            smoothed = 0
            view.reset()
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 12))
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        startTimer()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt)
        let target: CGFloat
        switch phase {
        case .listening:
            target = CGFloat(levelProvider?() ?? 0)
        case .transcribing, .cleaning:
            // Thrusters idling while the models work.
            target = 0.22 + 0.10 * CGFloat(sin(elapsed * 14))
        case .message:
            target = 0.08
        }
        smoothed = smoothed * 0.5 + target * 0.5
        view.push(max(0.06, smoothed))
    }
}

/// Draws the pill, a small top-down Falcon, and the exhaust trail (newest audio level nearest the engine).
final class FalconView: NSView {
    var label = ""
    private static let sampleCount = 46
    private var levels = [CGFloat](repeating: 0.06, count: FalconView.sampleCount)

    func reset() {
        levels = [CGFloat](repeating: 0.06, count: Self.sampleCount)
    }

    func push(_ level: CGFloat) {
        levels.insert(level, at: 0)
        levels.removeLast()
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let cy = bounds.midY

        // Pill
        NSColor(calibratedWhite: 0.04, alpha: 0.93).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let engineX: CGFloat = 150            // rear edge of the ship; exhaust streams left from here
        drawExhaust(engineX: engineX + 9, cy: cy)   // starts under the hull so the flare emerges from behind it
        drawFalcon(center: NSPoint(x: engineX + 23, y: cy + 2.5))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: engineX + 62, y: cy - size.height / 2), withAttributes: attrs)
    }

    // MARK: Exhaust = live waveform

    private func wavePath(engineX: CGFloat, cy: CGFloat, scale: CGFloat) -> NSBezierPath {
        let dx: CGFloat = 2.7
        let maxHalf: CGFloat = 19 * scale
        let p = NSBezierPath()
        p.move(to: NSPoint(x: engineX, y: cy))
        for (i, l) in levels.enumerated() {
            p.line(to: NSPoint(x: engineX - CGFloat(i) * dx, y: cy + l * maxHalf))
        }
        for (i, l) in levels.enumerated().reversed() {
            p.line(to: NSPoint(x: engineX - CGFloat(i) * dx, y: cy - l * maxHalf))
        }
        p.close()
        return p
    }

    private func drawExhaust(engineX: CGFloat, cy: CGFloat) {
        let outer = NSGradient(colors: [
            NSColor(calibratedRed: 0.35, green: 0.70, blue: 1.0, alpha: 0.95),
            NSColor(calibratedRed: 0.10, green: 0.35, blue: 1.0, alpha: 0.55),
            NSColor(calibratedRed: 0.05, green: 0.20, blue: 0.9, alpha: 0.0),
        ])
        outer?.draw(in: wavePath(engineX: engineX, cy: cy, scale: 1.0), angle: 180)

        let core = NSGradient(colors: [
            NSColor(calibratedRed: 0.90, green: 0.97, blue: 1.0, alpha: 1.0),
            NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 0.5),
            NSColor(calibratedRed: 0.30, green: 0.60, blue: 1.0, alpha: 0.0),
        ])
        core?.draw(in: wavePath(engineX: engineX, cy: cy, scale: 0.45), angle: 180)
    }

    // MARK: Falcon (top-down, after the classic plan view)

    /// Drawn in a local space where the ship points up (~65 wide x ~75 tall, origin near the hull centre),
    /// then rotated so the nose points right and the engines feed the exhaust on the left.
    /// One continuous hull outline (saucer + mandibles), shaded with a light source from the top-left.
    private func drawFalcon(center: NSPoint) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: -90)
        transform.scale(by: 0.66)
        transform.concat()

        func grey(_ w: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(calibratedWhite: w, alpha: a) }
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
        func stroke(_ p: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
            color.setStroke(); p.lineWidth = width; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke()
        }
        func line(_ a: NSPoint, _ b: NSPoint, _ color: NSColor, _ width: CGFloat) {
            let p = NSBezierPath(); p.move(to: a); p.line(to: b); stroke(p, color, width)
        }
        func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }

        let ink = grey(0.10)
        // Light comes from the top-left of the screen, which is the bottom-left in this rotated local space.
        let hullShading = NSGradient(colors: [grey(0.97), grey(0.80), grey(0.60)])!
        let armShading = NSGradient(colors: [grey(0.74), grey(0.50)])!
        let glass = NSGradient(colors: [NSColor(calibratedRed: 0.75, green: 0.95, blue: 1.0, alpha: 1),
                                        NSColor(calibratedRed: 0.20, green: 0.50, blue: 0.85, alpha: 1)])!
        let red = NSColor(calibratedRed: 0.86, green: 0.17, blue: 0.15, alpha: 1)

        let c = pt(0, -6)         // saucer centre
        let r: CGFloat = 29       // saucer radius

        // MARK: Cockpit (drawn first so the hull overlaps its stem)
        let cockpit = NSBezierPath()
        cockpit.move(to: pt(22, 2))
        cockpit.line(to: pt(28, 1))
        cockpit.curve(to: pt(36.5, 22), controlPoint1: pt(33, 8), controlPoint2: pt(36.5, 15))
        cockpit.line(to: pt(36, 34))
        cockpit.line(to: pt(33.6, 37.2))
        cockpit.line(to: pt(30.6, 37.2))
        cockpit.line(to: pt(28.6, 34))
        cockpit.line(to: pt(28.6, 23))
        cockpit.curve(to: pt(22, 10), controlPoint1: pt(28.6, 16), controlPoint2: pt(25, 12))
        cockpit.close()
        armShading.draw(in: cockpit, angle: 45)
        stroke(cockpit, ink, 1.1)
        line(pt(29, 19), pt(36, 19), grey(0.15, 0.55), 0.8)
        line(pt(29, 26), pt(36, 26), grey(0.15, 0.55), 0.8)
        let window = NSBezierPath(roundedRect: NSRect(x: 29.8, y: 30.4, width: 5.4, height: 3.6), xRadius: 1.2, yRadius: 1.2)
        glass.draw(in: window, angle: 90)
        stroke(window, ink, 0.7)

        // MARK: Hull silhouette: saucer and mandibles in a single outline
        let hull = NSBezierPath()
        hull.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: 24, clockwise: false)
        hull.curve(to: pt(13.5, 38), controlPoint1: pt(27.6, 16), controlPoint2: pt(20.5, 31))
        hull.line(to: pt(4.6, 38))
        hull.curve(to: pt(3, 16), controlPoint1: pt(4.1, 30), controlPoint2: pt(3, 22))
        hull.line(to: pt(-3, 16))
        hull.curve(to: pt(-4.6, 38), controlPoint1: pt(-3, 22), controlPoint2: pt(-4.1, 30))
        hull.line(to: pt(-13.5, 38))
        hull.curve(to: pt(-26.49, 5.8), controlPoint1: pt(-20.5, 31), controlPoint2: pt(-27.6, 16))
        hull.appendArc(withCenter: c, radius: r, startAngle: 156, endAngle: 270, clockwise: false)
        hull.close()
        hullShading.draw(in: hull, angle: 45)

        // Surface detail, clipped to the hull
        ctx.saveGraphicsState()
        hull.addClip()

        stroke(circle(c, 26.2), grey(0.30, 0.5), 0.9)            // raised rim
        stroke(circle(c, 19.5), grey(0.30, 0.22), 0.7)

        for side: CGFloat in [-1, 1] {
            // Recessed panel and turret on each mandible
            let panel = NSBezierPath()
            panel.move(to: pt(side * 7.5, 35)); panel.line(to: pt(side * 11.5, 35))
            panel.line(to: pt(side * 21, 9)); panel.line(to: pt(side * 8.5, 9)); panel.close()
            grey(0.35, 0.28).setFill(); panel.fill()
            stroke(panel, grey(0.25, 0.6), 0.7)
            line(pt(side * 9.5, 33), pt(side * 14.5, 12), grey(0.25, 0.5), 0.7)
            let turret = circle(pt(side * 9.6, 27), 2)
            grey(0.32).setFill(); turret.fill()
            stroke(circle(pt(side * 9.6, 27), 1.1), grey(0.85), 0.6)
        }

        // Slot between the mandibles
        grey(0.16).setFill(); NSBezierPath(rect: NSRect(x: -3, y: 6, width: 6, height: 10.5)).fill()
        line(pt(0, 7), pt(0, 15.5), NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 0.8), 0.8)

        // Radial panel lines
        let ringC = pt(0, -7)
        for deg in [35.0, 70, 110, 145, 215, 250, 290, 325] {
            let a = CGFloat(deg) * .pi / 180
            line(pt(cos(a) * 12.5, ringC.y + sin(a) * 12.5), pt(cos(a) * 25.5, ringC.y + sin(a) * 25.5), grey(0.35, 0.45), 0.8)
        }

        // Rear vents
        for side: CGFloat in [-1, 1] {
            for k in 0..<3 {
                let vent = NSBezierPath(roundedRect: NSRect(x: side * 13 - 2.5, y: -25.5 + CGFloat(k) * 2.6, width: 5, height: 1.4),
                                        xRadius: 0.6, yRadius: 0.6)
                grey(0.25, 0.65).setFill(); vent.fill()
            }
        }

        // Docking arms either side of the ring
        for side: CGFloat in [-1, 1] {
            let x0: CGFloat = side > 0 ? 10 : -29
            let arm = NSBezierPath(roundedRect: NSRect(x: x0, y: -11.5, width: 19, height: 9), xRadius: 1.6, yRadius: 1.6)
            armShading.draw(in: arm, angle: 45)
            stroke(arm, grey(0.12, 0.85), 0.8)
            for k in 0..<3 {
                let slot = NSBezierPath(rect: NSRect(x: x0 + 3 + CGFloat(k) * 4.4, y: -9.4, width: 2.6, height: 4.8))
                grey(0.16, 0.7).setFill(); slot.fill()
            }
            red.setFill()
            NSBezierPath(rect: NSRect(x: side > 0 ? x0 + 15 : x0 + 1.5, y: -4.8, width: 2.6, height: 1.6)).fill()
        }

        // Radar dish
        let dishC = pt(-16.5, 14.5)
        grey(0.30).setFill(); circle(dishC, 5.2).fill()
        stroke(circle(dishC, 5.2), ink, 0.8)
        stroke(circle(dishC, 3.2), grey(0.85), 0.8)
        grey(0.12).setFill(); circle(dishC, 1.1).fill()

        // Central ring
        grey(0.28).setFill(); circle(ringC, 11.2).fill()
        stroke(circle(ringC, 11.2), ink, 1.2)
        stroke(circle(ringC, 8.6), grey(0.75), 0.8)
        hullShading.draw(in: circle(ringC, 6.2), angle: 45)
        stroke(circle(ringC, 6.2), ink, 0.9)
        grey(0.12).setFill(); circle(ringC, 1.8).fill()

        // Red accents
        red.setFill()
        NSBezierPath(rect: NSRect(x: -12.5, y: 8.5, width: 4.2, height: 2.4)).fill()
        NSBezierPath(rect: NSRect(x: 9, y: 10, width: 4.2, height: 2.4)).fill()
        NSBezierPath(rect: NSRect(x: 5.5, y: -21, width: 3.6, height: 2.2)).fill()

        ctx.restoreGraphicsState()

        stroke(hull, ink, 1.1)

        // MARK: Rear engine: a curved grille with a glowing edge
        let engine = NSBezierPath()
        engine.appendArc(withCenter: c, radius: 28.4, startAngle: 236, endAngle: 304, clockwise: false)
        engine.appendArc(withCenter: c, radius: 21.5, startAngle: 304, endAngle: 236, clockwise: true)
        engine.close()
        grey(0.20).setFill(); engine.fill()
        stroke(engine, ink, 0.8)
        for deg in stride(from: 244.0, through: 296.0, by: 8.0) {
            let a = CGFloat(deg) * .pi / 180
            line(pt(cos(a) * 22.2, c.y + sin(a) * 22.2), pt(cos(a) * 27.8, c.y + sin(a) * 27.8), grey(0.62), 0.9)
        }

        ctx.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 0.95)
        glow.shadowBlurRadius = 6
        glow.shadowOffset = .zero
        glow.set()
        let slit = NSBezierPath()
        slit.appendArc(withCenter: c, radius: 29.3, startAngle: 238, endAngle: 302, clockwise: false)
        stroke(slit, NSColor(calibratedRed: 0.85, green: 0.97, blue: 1.0, alpha: 1), 2.4)
        ctx.restoreGraphicsState()
    }
}
