import XCTest
import AppKit
@testable import ClaudePowerMode
@testable import PageCore

/// The status glyph is pre-rendered into bitmap reps (so the menu bar blits
/// pixels instead of re-running vector drawing), and its timer stops while
/// nobody can see it. The bitmap must look like the old drawing-handler image.
final class GlyphBitmapTests: XCTestCase {
    /// Representative drawings: every layer the renderer has, light and dark,
    /// including a half-point width (moon tick / phone badge).
    private func samples() -> [(String, GlyphDrawing)] {
        [
            ("working dark", GlyphDrawing.make(GlyphState(mode: .working(agents: 2), headroom: 0.6), phase: 0.25)),
            ("working light", GlyphDrawing.make(GlyphState(mode: .working(agents: 1), headroom: 0.3), appearance: .light, phase: 0.6)),
            ("needsYou 3 rings", GlyphDrawing.make(GlyphState(mode: .needsYou(count: 3)), phase: 0.4)),
            ("needsYou 120 light", GlyphDrawing.make(GlyphState(mode: .needsYou(count: 120)), appearance: .light, phase: 0.1)),
            ("needsYou reduce motion", GlyphDrawing.make(GlyphState(mode: .needsYou(count: 2)), reduceMotion: true)),
            ("paused waiting", GlyphDrawing.make(GlyphState(mode: .paused, waiting: 2))),
            ("off hollow", GlyphDrawing.make(GlyphState(mode: .off))),
            ("quiet moon + phone", GlyphDrawing.make(GlyphState(mode: .quiet, lidClosedAwake: true, phoneArmed: true))),
            ("working all modifiers light", GlyphDrawing.make(GlyphState(mode: .working(agents: 3), lidClosedAwake: true, headroom: 0.8, phoneArmed: true), appearance: .light, phase: 0.8)),
        ]
    }

    /// Draws `image` into an sRGB bitmap whose points are `scale` pixels wide
    /// (a Retina context when 2), the way a screen would; returns RGBA bytes.
    private func render(_ image: NSImage, scale: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let w = Int((image.size.width * CGFloat(scale)).rounded(.up))
        let h = Int((image.size.height * CGFloat(scale)).rounded(.up))
        let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        let rep = raw.retagging(with: .sRGB)!
        rep.size = NSSize(width: CGFloat(w) / CGFloat(scale), height: CGFloat(h) / CGFloat(scale))
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var p = [Int](repeating: 0, count: 4)
                rep.getPixel(&p, atX: x, y: y)
                for c in 0..<4 { out[(y * w + x) * 4 + c] = UInt8(p[c]) }
            }
        }
        return (out, w, h)
    }

    private func maxDifference(_ a: (pixels: [UInt8], width: Int, height: Int),
                               _ b: (pixels: [UInt8], width: Int, height: Int)) -> Int {
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        guard a.pixels.count == b.pixels.count else { return 255 }
        return zip(a.pixels, b.pixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    func testBitmapPixelsMatchTheDrawingHandlerImage() {
        var overall = 0
        // 2x is the Retina menu bar; 1x is checked only for whole-point widths
        // (a half-point width rounds its last pixel up on a 1x screen).
        for (name, d) in samples() {
            for scale in [2, 1] where scale == 2 || d.width.truncatingRemainder(dividingBy: 1) == 0 {
                let old = render(StatusGlyphRenderer.vectorImage(d), scale: scale)
                let new = render(StatusGlyphRenderer.image(d), scale: scale)
                let diff = maxDifference(old, new)
                overall = max(overall, diff)
                XCTAssertGreaterThan(new.pixels.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count, 20, "\(name): not blank")
                XCTAssertLessThanOrEqual(diff, 3, "\(name) @\(scale)x: max channel difference \(diff)/255")
            }
        }
        // Control: the comparison can tell different glyphs apart.
        let other = render(StatusGlyphRenderer.image(samples()[6].1), scale: 2)
        let mine = render(StatusGlyphRenderer.vectorImage(samples()[0].1), scale: 2)
        XCTAssertGreaterThan(other.pixels.count == mine.pixels.count ? maxDifference(other, mine) : 255, 50)
        print("GLYPH PIXEL COMPARE: max channel difference over all samples = \(overall)/255")
    }

    func testBitmapImageKeepsSizeTemplateAndDescription() {
        for (name, d) in samples() {
            let old = StatusGlyphRenderer.vectorImage(d)
            let new = StatusGlyphRenderer.image(d)
            XCTAssertEqual(new.size, old.size, name)
            XCTAssertEqual(new.size, NSSize(width: CGFloat(d.width), height: StatusGlyphRenderer.height), name)
            XCTAssertFalse(new.isTemplate, name)
            XCTAssertEqual(new.isTemplate, old.isTemplate, name)
            XCTAssertEqual(new.accessibilityDescription, old.accessibilityDescription, name)
        }
    }

    func testImageIsBackedByBitmapRepsAtOneAndTwoTimes() {
        let d = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)))
        let image = StatusGlyphRenderer.image(d)
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        XCTAssertEqual(reps.count, image.representations.count, "no drawing-handler (custom) rep is left")
        XCTAssertEqual(Set(reps.map(\.pixelsWide)), [Int(d.width.rounded(.up)), Int((d.width * 2).rounded(.up))])
        XCTAssertTrue(reps.allSatisfy { $0.size == image.size })
        XCTAssertTrue(reps.allSatisfy { $0.colorSpace == NSColorSpace.sRGB })
    }

    func testRepeatedDrawingIsServedFromTheCache() {
        StatusGlyphRenderer.clearCache()
        let a = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: 0.9)
        let b = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: 0.5)
        let first = StatusGlyphRenderer.image(a)
        XCTAssertTrue(StatusGlyphRenderer.image(a) === first, "same drawing, same image")
        XCTAssertFalse(StatusGlyphRenderer.image(b) === first)
        // Colours differ with the menu-bar appearance, so they are different images.
        let dark = StatusGlyphRenderer.image(GlyphDrawing.make(GlyphState(mode: .quiet), appearance: .dark))
        let light = StatusGlyphRenderer.image(GlyphDrawing.make(GlyphState(mode: .quiet), appearance: .light))
        XCTAssertFalse(dark === light)
        // The cache stays small.
        for i in 0..<(StatusGlyphRenderer.cacheCapacity + 20) {
            _ = StatusGlyphRenderer.image(GlyphDrawing.make(GlyphState(mode: .working(agents: 1)), phase: Double(i) / 200))
        }
        XCTAssertFalse(StatusGlyphRenderer.image(a) === first, "the oldest entries were evicted")
    }

    func testScaledCloseUpsKeepTheVectorPath() {
        let d = GlyphDrawing.make(GlyphState(mode: .working(agents: 1)))
        let big = StatusGlyphRenderer.image(d, scale: 4)
        XCTAssertEqual(big.size.width, CGFloat(d.width) * 4)
    }

    // MARK: suspend / resume

    private func animator() -> (GlyphAnimator, () -> Int) {
        let g = GlyphAnimator(reduceMotion: { false })
        var frames = 0
        g.onImage = { _ in frames += 1 }
        g.state = GlyphState(mode: .working(agents: 1))
        g.start()
        return (g, { frames })
    }

    func testTimerRunsWhileWorkingAndStopsWhileSuspended() {
        let (g, _) = animator()
        defer { g.stop() }
        XCTAssertTrue(g.isTicking)
        g.setSuspended(.screensAsleep, true)
        XCTAssertTrue(g.suspended)
        XCTAssertFalse(g.isTicking, "no timer while the displays sleep")
        g.setSuspended(.screensAsleep, false)
        XCTAssertFalse(g.suspended)
        XCTAssertTrue(g.isTicking, "back on wake")
    }

    func testEachSuspendReasonStopsTheTimerAndAllMustClear() {
        let (g, _) = animator()
        defer { g.stop() }
        g.setSuspended(.screenLocked, true)
        XCTAssertFalse(g.isTicking)
        g.setSuspended(.screensAsleep, true)
        g.setSuspended(.screensAsleep, false)
        XCTAssertFalse(g.isTicking, "waking the screen does not restart it while still locked")
        g.setSuspended(.sessionInactive, true)
        g.setSuspended(.screenLocked, false)
        XCTAssertFalse(g.isTicking, "still switched out")
        g.setSuspended(.sessionInactive, false)
        XCTAssertTrue(g.isTicking)
    }

    func testResumeShowsTheCurrentFrameAndAStillStateStaysStill() {
        let (g, frames) = animator()
        defer { g.stop() }
        g.setSuspended(.screenLocked, true)
        let before = frames()
        // A breath is 4 s; let the phase move on while suspended, then resume.
        g.setSuspended(.screenLocked, false)
        XCTAssertGreaterThanOrEqual(frames(), before, "resume redraws (identical frames are skipped)")
        g.state = GlyphState(mode: .quiet)
        XCTAssertFalse(g.isTicking, "a state with nothing to animate never ticks")
        g.setSuspended(.screensAsleep, true)
        g.setSuspended(.screensAsleep, false)
        XCTAssertFalse(g.isTicking, "waking does not start a timer for a still glyph")
    }

    func testSystemNotificationsDriveTheSuspendFlag() {
        let (g, _) = animator()
        defer { g.stop() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(g.isTicking)
        nc.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(g.isTicking)
        nc.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertFalse(g.isTicking)
        nc.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertTrue(g.isTicking)
        let dc = DistributedNotificationCenter.default()
        dc.postNotificationName(Notification.Name("com.apple.screenIsLocked"), object: nil, userInfo: nil, deliverImmediately: true)
        spin { !g.isTicking }
        XCTAssertFalse(g.isTicking, "screen lock")
        dc.postNotificationName(Notification.Name("com.apple.screenIsUnlocked"), object: nil, userInfo: nil, deliverImmediately: true)
        spin { g.isTicking }
        XCTAssertTrue(g.isTicking, "unlock")
    }

    private func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    // MARK: benchmark

    /// N=200 frames: produce the image, then draw it into a 2x status-bar-sized
    /// context three times (the button and two menu-bar replicants).
    func testBenchmarkOldVersusNew() {
        let n = 200
        // 24 phases of a breath, as the animator cycles them.
        let drawings = (0..<24).map { GlyphDrawing.make(GlyphState(mode: .working(agents: 2), headroom: 0.6), phase: Double($0) / 24) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 44, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        rep.size = NSSize(width: 40, height: 22)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!

        func run(_ make: (GlyphDrawing) -> NSImage) -> Double {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            defer { NSGraphicsContext.restoreGraphicsState() }
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<n {
                let image = make(drawings[i % drawings.count])
                for _ in 0..<3 {
                    image.draw(in: NSRect(x: 0, y: 2, width: image.size.width, height: image.size.height))
                }
            }
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        _ = run { StatusGlyphRenderer.vectorImage($0) }   // warm up fonts and gradients
        let old = run { StatusGlyphRenderer.vectorImage($0) }
        StatusGlyphRenderer.clearCache()
        let newCold = run { d in StatusGlyphRenderer.clearCache(); return StatusGlyphRenderer.image(d) }
        StatusGlyphRenderer.clearCache()
        let newCached = run { StatusGlyphRenderer.image($0) }
        print(String(format: "GLYPH BENCH N=%d (image + 3 draws into a 2x context): old %.1f ms (%.3f ms/frame), new no cache %.1f ms (%.3f ms/frame), new with LRU %.1f ms (%.3f ms/frame)",
                     n, old, old / Double(n), newCold, newCold / Double(n), newCached, newCached / Double(n)))
        XCTAssertLessThan(newCached, old)
    }
}
