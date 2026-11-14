import AppKit

// The menu bar icon: a glyph per account (or one for them all), each up to
// three concentric rings that fill clockwise, outermost first, in the same
// order the popover lists the limits. Which limits get a ring is a
// preference; the default is the session then the weekly cap, which is what
// the icon has always shown. MenuBarRings works out what each ring shows.
//
// Each ring is coloured INDEPENDENTLY by its own metric — orange at 60%, red at
// 80%, or red if that metric's forecast is alerting. So a fine session with a
// red weekly shows a neutral outer ring and a red inner ring, not both red. An
// account's own color goes on the track, the unfilled part of each ring, so
// it never competes with those three.
//
// A notch cut across each ring marks how much of that limit's window has
// passed. A fill that runs past its notch is quota spent faster than time is
// passing. A ring whose limit has reset since it was read is drawn faintly,
// since its number is known to be wrong.
//
// A digit in the middle counts the account's banked resets that clear the
// weekly limit, as quotabar shows them, sized to the space the innermost ring
// leaves; more than nine reads "+".
//
// When claude.ai itself is unwell the rings stay put and a small badge appears in
// the corner. Replacing the rings with a status dot — which is what this used to
// do — threw away the number you still needed: degraded service doesn't stop you
// burning quota, and that's exactly when you want to see where you stand.
@MainActor
enum ProgressRingImage {

    // The space between two accounts' glyphs.
    static let glyphGap: CGFloat = 4

    // Geometry per ring count. Two rings reproduce the original icon exactly, so
    // nobody's menu bar shifts when this ships. Three needs a slightly larger
    // canvas and thinner outer strokes to leave the innermost room — and the
    // innermost gets a *thicker* stroke, because it has the least circumference
    // and needs the weight to stay readable at menu bar size.
    private static func geometry(_ count: Int) -> (size: CGFloat, rings: [(r: CGFloat, w: CGFloat)]) {
        switch count {
        case 0, 1: return (20, [(8.0, 2.0)])
        case 2:    return (20, [(8.0, 2.0), (4.6, 2.0)])
        default:   return (22, [(9.4, 1.3), (6.5, 1.3), (3.5, 1.7)])
        }
    }

    static func make(glyphs: [MenuBarGlyph], status: ClaudeStatus = .operational) -> NSImage {
        let shown = glyphs.isEmpty ? [MenuBarGlyph(rings: [])] : glyphs
        let sizes = shown.map { geometry(min($0.rings.count, 3)).size }
        let width = sizes.reduce(0, +) + glyphGap * CGFloat(shown.count - 1)
        let height = sizes.max() ?? 20

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            var x: CGFloat = 0
            for (glyph, size) in zip(shown, sizes) {
                ctx.saveGState()
                ctx.translateBy(x: x, y: (height - size) / 2)
                draw(glyph, in: ctx)
                ctx.restoreGState()
                x += size + glyphGap
            }
            if !status.isHealthy { drawStatusBadge(ctx, width: width, status: status) }
            return true
        }
    }

    private static func draw(_ glyph: MenuBarGlyph, in ctx: CGContext) {
        let rings = Array(glyph.rings.prefix(3))
        let geo = geometry(rings.count)
        let center = CGPoint(x: geo.size / 2, y: geo.size / 2)
        let track = glyph.tint.flatMap(NSColor.init(hex:))?.withAlphaComponent(0.4)
            ?? NSColor.secondaryLabelColor.withAlphaComponent(0.35)

        // Drawn as one layer so a signed-out account fades as a whole, and so
        // the notches cut through this glyph only.
        ctx.setAlpha(glyph.dimmed ? 0.35 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if rings.isEmpty {
            // Nothing to report yet — draw the empty outer track so the icon
            // holds its place instead of flickering in and out.
            drawRing(ctx, center: center, radius: geo.rings[0].r, lineWidth: geo.rings[0].w,
                     ring: MenuBarRing(percent: nil), track: track)
        }
        for (ring, g) in zip(rings, geo.rings) {
            drawRing(ctx, center: center, radius: g.r, lineWidth: g.w, ring: ring, track: track)
        }
        if glyph.banked > 0 {
            let innermost = geo.rings[max(rings.count, 1) - 1]
            drawCount(glyph.banked, in: ctx, center: center, room: 2 * (innermost.r - innermost.w / 2))
        }
        ctx.endTransparencyLayer()
    }

    // A count centred in a hole `room` points across, its digit's height
    // centred rather than its line's. A thin gap is cut around it so it never
    // runs into the ring around it; a lone ring's large hole still gets a
    // digit no bigger than the others'.
    private static func drawCount(_ count: Int, in ctx: CGContext, center: CGPoint, room: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: min(room * 0.9, 8), weight: .bold)
        let string = count > 9 ? "+" : "\(count)"
        let fill = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        // A positive stroke width draws the outline only, in percent of the font size.
        let halo = NSAttributedString(string: string, attributes: [.font: font, .strokeWidth: 24,
                                                                   .strokeColor: NSColor.black])
        let origin = CGPoint(x: center.x - fill.size().width / 2,
                             y: center.y - font.capHeight / 2 + font.descender)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        halo.draw(at: origin)
        ctx.restoreGState()
        fill.draw(at: origin)
    }

    private static func color(for s: Severity) -> NSColor {
        switch s {
        case .ok:     return .labelColor      // neutral (adapts to the menu bar)
        case .warn:   return .systemOrange
        case .danger: return .systemRed
        }
    }

    // A badge in the bottom-right corner.
    //
    // The gap around it is punched through to transparency rather than filled
    // with a background colour: the menu bar is whatever the wallpaper and
    // appearance make it, so any colour we picked would be wrong somewhere.
    private static func drawStatusBadge(_ ctx: CGContext, width: CGFloat, status: ClaudeStatus) {
        let d: CGFloat = 6.5

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: width - d - 2, y: -1, width: d + 2, height: d + 2))
        ctx.restoreGState()

        if case .outage = status { NSColor.systemRed.setFill() } else { NSColor.systemOrange.setFill() }
        NSBezierPath(ovalIn: NSRect(x: width - d - 1, y: 0, width: d, height: d)).fill()
    }

    private static func drawRing(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                                 lineWidth: CGFloat, ring: MenuBarRing, track: NSColor) {
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        track.setStroke()
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Progress arc — starts at top, sweeps clockwise.
        let start = CGFloat.pi / 2
        if let p = ring.percent, p > 0 {
            let fraction = CGFloat(min(max(p, 0), 100)) / 100.0
            (ring.stale ? NSColor.labelColor.withAlphaComponent(0.35) : color(for: ring.severity)).setStroke()
            ctx.addArc(center: center, radius: radius, startAngle: start,
                       endAngle: start - fraction * .pi * 2, clockwise: true)
            ctx.strokePath()
        }

        // The notch: a cut across the ring where the window stands now.
        guard let elapsed = ring.elapsed else { return }
        let angle = start - CGFloat(elapsed) * .pi * 2
        let inner = radius - lineWidth / 2 - 0.5, outer = radius + lineWidth / 2 + 0.5
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1)
        ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
        ctx.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

extension NSColor {
    // "#RRGGBB" → a color; nil for anything else.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
