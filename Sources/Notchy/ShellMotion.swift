import CoreGraphics
import Foundation

/// Shell body plus its two concave top shoulders. `width` excludes the shoulders.
struct ShellGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var shoulder: CGFloat
    var bottom: CGFloat
    var neckWidth: CGFloat
    var neckHeight: CGFloat

    var totalWidth: CGFloat { width + 2 * shoulder }

    fileprivate var vector: SIMD8<Double> {
        SIMD8(Double(width), Double(height), Double(shoulder), Double(bottom), Double(neckWidth), Double(neckHeight), 0, 0)
    }
    fileprivate init(_ v: SIMD8<Double>) {
        self.init(width: CGFloat(v[0]), height: CGFloat(v[1]), shoulder: CGFloat(v[2]), bottom: CGFloat(v[3]),
                  neckWidth: CGFloat(v[4]), neckHeight: CGFloat(v[5]))
    }
    init(width: CGFloat, height: CGFloat, shoulder: CGFloat, bottom: CGFloat,
         neckWidth: CGFloat? = nil, neckHeight: CGFloat = 0) {
        self.width = width; self.height = height; self.shoulder = shoulder; self.bottom = bottom
        self.neckWidth = neckWidth ?? width + 2 * shoulder
        self.neckHeight = neckHeight
    }
}

/// Screen facts the profile needs, in points. `cameraWidth` 0 means no notch.
struct ShellScreen: Equatable {
    var frame: CGRect
    /// Height from the screen top down to the usable bottom edge.
    var usableHeight: CGFloat
    var cameraWidth: CGFloat
    /// Safe-area top on a notched screen, else 0.
    var top: CGFloat
    var centerX: CGFloat
    var scale: CGFloat
    var menuBarHeight: CGFloat

    var notched: Bool { cameraWidth > 0 }
    /// Expanded header row: beside the camera on a notched screen, a 30 pt row otherwise.
    var header: CGFloat { notched ? top : 30 }
}

/// Deduplicated geometry inputs. Content-only changes (battery, clock, artwork, text) never reach this.
struct ShellProfile: Equatable {
    enum Presentation: Equatable { case minimal, resting, closed, transient, expanded, lyrics, taskEditor }
    var presentation: Presentation
    var noticeStrip = false
    var bodyWidth: CGFloat = 440

    static func make(expanded: Bool, lyrics: Bool, tab: String, taskEditor: Bool, notice: Bool,
                     idleStage: Int, waking: Bool, playing: Bool, mascot: Bool, minimal: Bool) -> ShellProfile {
        if expanded {
            if lyrics && tab == ShellTab.musik.rawValue { return ShellProfile(presentation: .lyrics, noticeStrip: notice) }
            if taskEditor && tab == ShellTab.tugas.rawValue { return ShellProfile(presentation: .taskEditor, noticeStrip: notice) }
            let width: CGFloat
            switch ShellTab(rawValue: tab) {
            case .fokus: width = 360
            case .widgets: width = 400
            case .air, .sholat: width = 480
            default: width = 440
            }
            return ShellProfile(presentation: .expanded, noticeStrip: notice, bodyWidth: width)
        }
        if notice { return ShellProfile(presentation: .transient) }
        if minimal && !playing { return ShellProfile(presentation: .minimal) }
        if mascot && !playing && (idleStage > 0 || waking) { return ShellProfile(presentation: .resting) }
        return ShellProfile(presentation: .closed)
    }

    static let noticeStripHeight: CGFloat = 44

    func geometry(on s: ShellScreen) -> ShellGeometry {
        let cam = s.cameraWidth, c = s.top, n = s.notched
        var g: ShellGeometry
        switch presentation {
        case .minimal:
            g = n ? .init(width: cam, height: c, shoulder: 0, bottom: 0, neckWidth: cam, neckHeight: c)
                : .init(width: 72, height: 6, shoulder: 3, bottom: 3)
        case .resting, .closed:
            g = n ? .init(width: cam + 80, height: c, shoulder: 4, bottom: 10)
                : .init(width: 160, height: 30, shoulder: 0, bottom: 12)
        case .transient:
            g = .init(width: max(340, cam + 24), height: c + 60, shoulder: 12, bottom: 18,
                      neckWidth: n ? cam : nil, neckHeight: c)
        case .expanded: g = .init(width: bodyWidth, height: s.header + 164, shoulder: 18, bottom: 28)
        case .lyrics: g = .init(width: 680, height: s.header + 220, shoulder: 18, bottom: 28)
        case .taskEditor: g = .init(width: 440, height: s.header + 204, shoulder: 18, bottom: 28)
        }
        if noticeStrip { g.height += Self.noticeStripHeight }
        // 8 pt clearance on both sides and at the bottom; never narrower than the camera it covers.
        g.width = max(cam, min(g.width, s.frame.width - 16 - 2 * g.shoulder))
        g.height = max(c, min(g.height, max(0, s.usableHeight - (n ? 0 : s.menuBarHeight) - 8)))
        g.neckHeight = min(max(0, g.neckHeight), g.height)
        let lowerHeight = g.height - g.neckHeight
        g.shoulder = min(g.shoulder, lowerHeight / 2)
        g.bottom = min(g.bottom, lowerHeight - g.shoulder, g.width / 2)
        g.neckWidth = g.neckHeight == 0 ? g.totalWidth : min(g.neckWidth, g.totalWidth)
        return g
    }

    /// Window rectangle (body + shoulders), top-anchored, centered on the camera, kept inside the screen, pixel aligned.
    static func frame(for g: ShellGeometry, on s: ShellScreen) -> CGRect {
        func align(_ v: CGFloat) -> CGFloat { (v * s.scale).rounded() / s.scale }
        let total = align(g.totalWidth)
        var x = s.centerX - total / 2
        x = min(max(x, s.frame.minX + 8), s.frame.maxX - 8 - total)
        let h = align(g.height)
        return CGRect(x: align(x), y: align(s.frame.maxY - (s.notched ? 0 : s.menuBarHeight)) - h, width: total, height: h)
    }
}

/// Critically damped spring per geometry component. Retargeting keeps position and velocity,
/// so reversals never reset to an endpoint or queue a second animation.
struct ShellMotion {
    static let growOmega = 26.0, shrinkOmega = 32.0
    static let maxDuration = 0.8
    /// A frame gap longer than this (sleep, occlusion, stalled run loop) snaps instead of replaying.
    static let maxFrameGap = 0.25

    static func shouldAnimate(requested: Bool, reduceMotion: Bool, visible: Bool) -> Bool {
        requested && !reduceMotion && visible
    }

    private(set) var target: ShellGeometry
    /// Lower bound while moving: never narrower or shorter than the camera cover.
    var floor = SIMD8<Double>.zero
    private var offset = SIMD8<Double>.zero    // position - target at `start`
    private var velocity = SIMD8<Double>.zero  // at `start`
    private var start: TimeInterval = 0
    private var omega = growOmega
    private(set) var settled = true

    init(at g: ShellGeometry) { target = g }

    struct Sample { var geometry: ShellGeometry; var velocity: SIMD8<Double>; var settled: Bool }

    func sample(at t: TimeInterval) -> Sample {
        let tg = target.vector
        if settled { return Sample(geometry: target, velocity: .zero, settled: true) }
        let dt = max(0, t - start)
        let e = exp(-omega * dt)
        let a = velocity + omega * offset
        let y = (offset + a * dt) * e
        let v = (velocity - a * (omega * dt)) * e
        let resting = abs(y).max() <= 0.25 && abs(v).max() <= 2
        if resting || dt >= Self.maxDuration { return Sample(geometry: target, velocity: .zero, settled: true) }
        return Sample(geometry: ShellGeometry(simd_max(tg + y, floor)), velocity: v, settled: false)
    }

    mutating func retarget(_ g: ShellGeometry, at t: TimeInterval) {
        guard g != target else { return }
        let now = sample(at: t)
        let p = now.geometry
        omega = g.height > p.height || (g.height == p.height && g.width >= p.width) ? Self.growOmega : Self.shrinkOmega
        offset = p.vector - g.vector
        velocity = now.velocity
        start = t
        target = g
        settled = false
    }

    mutating func snap(_ g: ShellGeometry) {
        target = g
        offset = .zero
        velocity = .zero
        settled = true
    }

    mutating func settle(at t: TimeInterval) -> Sample {
        let s = sample(at: t)
        if s.settled { snap(target) }
        return s
    }
}

private func simd_max(_ a: SIMD8<Double>, _ b: SIMD8<Double>) -> SIMD8<Double> {
    SIMD8(max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]),
          max(a[4], b[4]), max(a[5], b[5]), max(a[6], b[6]), max(a[7], b[7]))
}

private func abs(_ v: SIMD8<Double>) -> SIMD8<Double> {
    SIMD8(Swift.abs(v[0]), Swift.abs(v[1]), Swift.abs(v[2]), Swift.abs(v[3]),
          Swift.abs(v[4]), Swift.abs(v[5]), Swift.abs(v[6]), Swift.abs(v[7]))
}

/// One AppKit y-up outline shared by drawing, clipping, drag highlighting and hit testing.
enum NotchShape {
    static func path(in rect: CGRect, geometry: ShellGeometry) -> CGPath {
        let neckHeight = max(0, min(geometry.neckHeight, rect.height))
        let neckWidth = max(0, min(geometry.neckWidth, rect.width))
        let lowerHeight = rect.height - neckHeight
        let neckLeft = rect.midX - neckWidth / 2, neckRight = rect.midX + neckWidth / 2
        let p = CGMutablePath()
        if lowerHeight <= 0 {
            p.addRect(CGRect(x: neckLeft, y: rect.minY, width: neckWidth, height: rect.height))
            return p
        }
        let s = max(0, min(geometry.shoulder, lowerHeight / 2, rect.width / 4))
        let body = rect.width - 2 * s
        let b = max(0, min(geometry.bottom, lowerHeight - s, body / 2))
        let (minX, maxX, minY) = (rect.minX, rect.maxX, rect.minY)
        let joinY = rect.maxY - neckHeight
        p.move(to: CGPoint(x: neckLeft, y: rect.maxY))
        p.addLine(to: CGPoint(x: neckRight, y: rect.maxY))
        p.addLine(to: CGPoint(x: neckRight, y: joinY))
        p.addLine(to: CGPoint(x: maxX, y: joinY))
        p.addArc(center: CGPoint(x: maxX, y: joinY - s), radius: s, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: maxX - s, y: minY + b))
        p.addArc(center: CGPoint(x: maxX - s - b, y: minY + b), radius: b, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: minX + s + b, y: minY))
        p.addArc(center: CGPoint(x: minX + s + b, y: minY + b), radius: b, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
        p.addLine(to: CGPoint(x: minX + s, y: joinY - s))
        p.addArc(center: CGPoint(x: minX, y: joinY - s), radius: s, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: neckLeft, y: joinY))
        p.closeSubpath()
        return p
    }
}

extension ShellMotion {
    static func selftest() throws {
        func check(_ ok: Bool, _ msg: String) throws {
            if !ok { throw NSError(domain: "ShellMotionSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
        }
        try check(!ShellMotion.shouldAnimate(requested: true, reduceMotion: true, visible: true), "reduce motion is direct")
        try check(!ShellMotion.shouldAnimate(requested: true, reduceMotion: false, visible: false), "occluded is direct")
        try check(ShellMotion.shouldAnimate(requested: true, reduceMotion: false, visible: true), "visible normal transition animates")
        let mac = ShellScreen(frame: CGRect(x: 0, y: 0, width: 1470, height: 956), usableHeight: 956,
                              cameraWidth: 179, top: 32, centerX: 735.5, scale: 2, menuBarHeight: 32)
        let plain = ShellScreen(frame: CGRect(x: -223, y: 956, width: 1920, height: 1080), usableHeight: 1080,
                                cameraWidth: 0, top: 0, centerX: 737, scale: 1, menuBarHeight: 24)
        func profile(_ p: ShellProfile.Presentation, strip: Bool = false) -> ShellProfile { ShellProfile(presentation: p, noticeStrip: strip) }
        func bounds(_ g: ShellGeometry) -> CGRect { CGRect(x: 0, y: 0, width: g.totalWidth, height: g.height) }
        func cameraCovered(_ g: ShellGeometry) -> Bool {
            let rect = bounds(g), path = NotchShape.path(in: rect, geometry: g)
            for depth in stride(from: CGFloat(0.5), to: mac.top, by: 1) {
                for x in stride(from: -mac.cameraWidth / 2 + 0.5, to: mac.cameraWidth / 2, by: 1) {
                    if !path.contains(CGPoint(x: rect.midX + x, y: rect.maxY - depth)) { return false }
                }
            }
            return true
        }

        let closed = profile(.closed).geometry(on: mac)
        try check(closed.height == mac.top && closed.totalWidth < 279 && cameraCovered(closed),
                  "idle stays at camera height with shorter status wings")
        try check(profile(.resting).geometry(on: mac) == closed, "resting does not add a lower apron")
        let cr = bounds(closed), cp = NotchShape.path(in: cr, geometry: closed)
        try check(cp.contains(CGPoint(x: cr.midX, y: cr.midY)), "closed camera cover")
        let minimal = profile(.minimal).geometry(on: mac)
        try check(minimal == ShellGeometry(width: 179, height: 32, shoulder: 0, bottom: 0, neckWidth: 179, neckHeight: 32)
                  && cameraCovered(minimal), "minimal is only camera rectangle")
        try check(NotchShape.path(in: bounds(minimal), geometry: minimal).boundingBoxOfPath == bounds(minimal), "zero apron rectangle bounds")
        try check(profile(.expanded).geometry(on: plain).height == 194, "no-notch header row")
        try check(profile(.expanded, strip: true).geometry(on: mac).height == 32 + 164 + 44, "notice strip")
        try check(profile(.minimal).geometry(on: plain) == ShellGeometry(width: 72, height: 6, shoulder: 3, bottom: 3), "minimal no-notch")
        try check(profile(.closed).geometry(on: plain).height == 30, "no-notch status row")
        let notice = profile(.transient).geometry(on: mac)
        try check(notice.width == 340 && notice.height == 92 && notice.neckWidth == 179 && notice.neckHeight == 32,
                  "standalone notice uses camera neck")
        let make = ShellProfile.make(expanded: false, lyrics: false, tab: "Musik", taskEditor: true, notice: false,
                                     idleStage: 2, waking: false, playing: true, mascot: true, minimal: true)
        try check(make.presentation == .closed, "playing overrides minimal and resting")
        try check(ShellProfile.make(expanded: true, lyrics: false, tab: "Musik", taskEditor: true, notice: false,
                                    idleStage: 0, waking: false, playing: false, mascot: true, minimal: false).presentation == .expanded,
                  "task editor size only on Tugas")
        func pageGeometry(_ tab: ShellTab, editing: Bool = false) -> ShellGeometry {
            ShellProfile.make(expanded: true, lyrics: false, tab: tab.rawValue, taskEditor: editing, notice: false,
                              idleStage: 0, waking: false, playing: false, mascot: true, minimal: false).geometry(on: mac)
        }
        try check(pageGeometry(.fokus).width < pageGeometry(.musik).width
                  && pageGeometry(.widgets).width < pageGeometry(.air).width, "short pages do not inherit chart width")
        try check(pageGeometry(.tugas, editing: true).width == pageGeometry(.tugas).width,
                  "entering task editor does not widen the page")

        // Screen-edge clamping reserves the no-notch menu bar before the bottom clearance.
        let narrow = ShellScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 300), usableHeight: 200,
                                 cameraWidth: 0, top: 0, centerX: 30, scale: 2, menuBarHeight: 24)
        let lyr = profile(.lyrics).geometry(on: narrow)
        let f = ShellProfile.frame(for: lyr, on: narrow)
        try check(lyr.width == 400 - 16 - 36 && lyr.height == 168, "clamped size \(lyr)")
        try check(f.minX >= 8 && f.maxX <= 392 && f.maxY == 276 && f.minY >= 108, "clamped frame \(f)")
        for p in [ShellProfile.Presentation.minimal, .resting, .closed, .transient, .expanded, .lyrics, .taskEditor] {
            let g = profile(p).geometry(on: plain)
            try check(ShellProfile.frame(for: g, on: plain).maxY == plain.frame.maxY - plain.menuBarHeight,
                      "every no-notch profile starts below menu bar")
            try check(g.shoulder >= 0 && g.bottom >= 0 && g.shoulder + g.bottom <= g.height - g.neckHeight,
                      "radii fit lower body")
        }
        let cf = ShellProfile.frame(for: closed, on: mac)
        try check(abs(cf.midX - 735.5) <= 0.5 && cf.maxY == 956, "closed centered on camera \(cf)")

        // Exact settled endpoint.
        let open = profile(.expanded).geometry(on: mac)
        var m = ShellMotion(at: closed)
        m.floor = SIMD8(179, 32, 0, 0, 179, 0, 0, 0)
        m.retarget(open, at: 0)
        try check(!m.sample(at: 0.05).settled, "moving midway")
        try check(m.sample(at: 0.8).geometry == open && m.sample(at: 0.8).settled, "cap snaps exactly")

        // All six components retain position and velocity through mixed mid-flight reversals.
        let editor = profile(.taskEditor).geometry(on: mac)
        let destinations = [closed, notice, open, editor, minimal, open, notice, closed, editor, closed]
        var t = 0.0
        for (i, destination) in destinations.enumerated() {
            t += 0.07
            let before = m.sample(at: t)
            m.retarget(destination, at: t)
            let after = m.sample(at: t)
            try check(abs(before.geometry.vector - after.geometry.vector).max() < 1e-6, "six-component position continuity \(i)")
            try check(abs(before.velocity - after.velocity).max() < 1e-6, "six-component velocity continuity \(i)")
            var u = t
            while u < t + 0.07 {
                let s = m.sample(at: u)
                try check(s.geometry.width >= 179 && s.geometry.height >= 32 && s.geometry.neckWidth >= 179,
                          "camera dimension floors \(s.geometry)")
                try check(cameraCovered(s.geometry), "presented path covers full camera during reversal \(i)")
                u += 1.0 / 120
            }
        }
        let end = m.settle(at: t + 1)
        try check(end.settled && end.geometry == m.target && m.settled, "settles on final target")

        for component in 0..<6 {
            var target = closed.vector
            target[component] += 100
            var spring = ShellMotion(at: closed)
            spring.retarget(ShellGeometry(target), at: 0)
            let s = spring.sample(at: 0.32)
            try check(abs(s.geometry.vector - target).max() <= 0.25 && abs(s.velocity[component]) > 2 && !s.settled,
                      "component \(component) velocity prevents premature settling")
            try check(spring.sample(at: 0.8).geometry.vector == target && spring.sample(at: 0.8).settled,
                      "component \(component) settles exactly")
        }
        for (reduceMotion, visible) in [(true, true), (false, false)] {
            var direct = ShellMotion(at: closed)
            if !shouldAnimate(requested: true, reduceMotion: reduceMotion, visible: visible) { direct.snap(notice) }
            try check(direct.sample(at: 0).geometry == notice && direct.settled, "direct target has no replay")
        }

        // Zero neck height preserves the original expanded shoulder and corner silhouette.
        let rect = bounds(open)
        let path = NotchShape.path(in: rect, geometry: open)
        try check(open.neckHeight == 0 && open.neckWidth == rect.width, "expanded full-width join")
        try check(path.contains(CGPoint(x: rect.midX, y: rect.midY)), "body inside")
        try check(path.contains(CGPoint(x: open.shoulder - 2, y: rect.maxY - 1)), "shoulder flare near the top edge inside")
        try check(!path.contains(CGPoint(x: 2, y: rect.maxY - 16)), "concave shoulder cutout outside")
        try check(!path.contains(CGPoint(x: open.shoulder + 2, y: 2)), "rounded bottom corner outside")
        try check(path.contains(CGPoint(x: open.shoulder + 2, y: rect.midY)), "side wall inside")
        let original = CGMutablePath()
        let s = open.shoulder, b = open.bottom
        original.move(to: CGPoint(x: 0, y: rect.maxY))
        original.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        original.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY - s), radius: s, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        original.addLine(to: CGPoint(x: rect.maxX - s, y: b))
        original.addArc(center: CGPoint(x: rect.maxX - s - b, y: b), radius: b, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        original.addLine(to: CGPoint(x: s + b, y: 0))
        original.addArc(center: CGPoint(x: s + b, y: b), radius: b, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
        original.addLine(to: CGPoint(x: s, y: rect.maxY - s))
        original.addArc(center: CGPoint(x: 0, y: rect.maxY - s), radius: s, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        original.closeSubpath()
        for y in stride(from: CGFloat(0.5), to: rect.height, by: 2) {
            for x in stride(from: CGFloat(0.5), to: rect.width, by: 2) {
                let point = CGPoint(x: x, y: y)
                try check(path.contains(point) == original.contains(point), "expanded silhouette unchanged")
            }
        }
        let extreme = ShellGeometry(width: 100, height: 40, shoulder: 100, bottom: 100, neckWidth: 1000, neckHeight: 100)
        let smallRect = CGRect(x: 11, y: 17, width: 80, height: 40)
        try check(NotchShape.path(in: smallRect, geometry: extreme).boundingBoxOfPath == smallRect,
                  "oversized neck clamps to actual presented bounds")
        let shallow = ShellGeometry(width: 80, height: 40, shoulder: 100, bottom: 100, neckWidth: 60, neckHeight: 32)
        let shallowPath = NotchShape.path(in: smallRect, geometry: shallow)
        try check(shallowPath.boundingBoxOfPath == smallRect && shallowPath.contains(CGPoint(x: smallRect.midX, y: 18)),
                  "oversized radii stay inside shallow lower body")
    }
}
