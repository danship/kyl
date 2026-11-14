import AppKit

/// An image drawn into a bitmap at `scale` pixels per point, for reading its
/// pixels. Points are measured from the bottom left, as AppKit draws.
struct Drawn {
    let rep: NSBitmapImageRep
    let scale: CGFloat
    let size: NSSize

    init(_ image: NSImage, scale: CGFloat = 4) {
        self.scale = scale
        size = image.size
        rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The color at a point, in sRGB.
    func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
        let px = Int(x * scale), py = rep.pixelsHigh - 1 - Int(y * scale)
        return rep.colorAt(x: px, y: py)!.usingColorSpace(.sRGB)!
    }

    /// The point at `angle` degrees clockwise from the top of a circle of
    /// `radius` centered in the image.
    func point(radius: CGFloat, clockwiseFromTop angle: CGFloat) -> (CGFloat, CGFloat) {
        let radians = angle * .pi / 180
        return (size.width / 2 + radius * sin(radians), size.height / 2 + radius * cos(radians))
    }

    func color(radius: CGFloat, clockwiseFromTop angle: CGFloat) -> NSColor {
        let (x, y) = point(radius: radius, clockwiseFromTop: angle)
        return color(x, y)
    }
}

func isRed(_ c: NSColor) -> Bool { c.alphaComponent > 0.8 && c.redComponent > 0.8 && c.greenComponent < 0.4 }
func isOrange(_ c: NSColor) -> Bool {
    c.alphaComponent > 0.8 && c.redComponent > 0.8 && c.greenComponent > 0.4 && c.greenComponent < 0.75
        && c.blueComponent < 0.3
}

func isClear(_ c: NSColor) -> Bool { c.alphaComponent < 0.15 }

func ringImageTests() {
    // Two rings: outer at radius 8, inner at radius 4.6, on a 20-point canvas.
    let image = ProgressRingImage.make(glyphs: [MenuBarGlyph(rings: [
        MenuBarRing(percent: 50, severity: .danger),
        MenuBarRing(percent: 25, severity: .warn),
    ])])
    expectEqual(image.size, NSSize(width: 20, height: 20), "two rings fit the original canvas")
    let drawn = Drawn(image)

    // The outer ring fills clockwise from the top to half way: the right side.
    expect(isRed(drawn.color(radius: 8, clockwiseFromTop: 90)), "outer ring at 3 o'clock is filled")
    expect(isRed(drawn.color(radius: 8, clockwiseFromTop: 150)), "outer ring at 5 o'clock is filled")
    expect(!isRed(drawn.color(radius: 8, clockwiseFromTop: 270)), "outer ring at 9 o'clock is not")
    // The inner ring fills a quarter: up to 3 o'clock and no further.
    expect(isOrange(drawn.color(radius: 4.6, clockwiseFromTop: 45)), "inner ring at half past 1 is filled")
    expect(!isOrange(drawn.color(radius: 4.6, clockwiseFromTop: 180)), "inner ring at 6 o'clock is not")
    expect(!isRed(drawn.color(radius: 4.6, clockwiseFromTop: 45)), "each ring has its own color")

    // An empty ring draws only its faint track.
    let empty = Drawn(ProgressRingImage.make(glyphs: [MenuBarGlyph(rings: [MenuBarRing(percent: 0, severity: .danger)])]))
    expect(!isRed(empty.color(radius: 8, clockwiseFromTop: 90)), "an empty ring has no arc")
    expect(!isClear(empty.color(radius: 8, clockwiseFromTop: 90)), "the track is drawn")

    // The notch: a cut across the ring where the window stands, through the
    // fill and the track alike.
    let notched = Drawn(ProgressRingImage.make(glyphs: [MenuBarGlyph(rings: [
        MenuBarRing(percent: 50, severity: .danger, elapsed: 0.25),
        MenuBarRing(percent: 10, severity: .danger, elapsed: 0.5),
    ])]))
    expect(isClear(notched.color(radius: 8, clockwiseFromTop: 90)), "the outer notch at 3 o'clock cuts the fill")
    expect(isRed(notched.color(radius: 8, clockwiseFromTop: 80)), "the fill either side of it stays")
    expect(isRed(notched.color(radius: 8, clockwiseFromTop: 100)), "on both sides")
    expect(isClear(notched.color(radius: 4.6, clockwiseFromTop: 180)), "the inner notch at 6 o'clock cuts the track")
    expect(!isClear(notched.color(radius: 4.6, clockwiseFromTop: 160)), "the track beside it stays")
    expect(!isClear(drawn.color(radius: 8, clockwiseFromTop: 90)), "no notch without a window")

    // A ring whose limit has reset is faint, not red.
    let stale = Drawn(ProgressRingImage.make(glyphs: [MenuBarGlyph(rings: [
        MenuBarRing(percent: 90, severity: .danger, stale: true),
    ])]))
    expect(!isRed(stale.color(radius: 8, clockwiseFromTop: 90)), "a stale ring is not red")
    expect(stale.color(radius: 8, clockwiseFromTop: 90).alphaComponent < 0.6, "a stale ring is faint")

    // Several accounts sit side by side, each with its own track color.
    let pair = ProgressRingImage.make(glyphs: [
        MenuBarGlyph(rings: [MenuBarRing(percent: 0)], tint: "#0000FF"),
        MenuBarGlyph(rings: [MenuBarRing(percent: 0)], tint: "#00FF00", dimmed: true),
    ])
    expectEqual(pair.size, NSSize(width: 44, height: 20), "two glyphs and the gap between")
    let pairDrawn = Drawn(pair)
    let left = pairDrawn.color(10 + 8, 10), right = pairDrawn.color(34 + 8, 10)
    expect(left.blueComponent > 0.8 && left.greenComponent < 0.3, "the first glyph's track wears its color: \(left)")
    expect(right.greenComponent > 0.8 && right.blueComponent < 0.3, "the second wears its own: \(right)")
    expect(right.alphaComponent < left.alphaComponent, "a signed-out account's glyph is fainter")
}
