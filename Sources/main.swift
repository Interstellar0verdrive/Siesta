import AppKit
import CryptoKit

// Siesta — a menu bar utility that gives a long-running encoder periodic rests.
// It counts minutes of real work, freezes the worker processes (SIGSTOP) for a
// rest period and resumes them (SIGCONT). Nothing is lost: the frozen process
// simply continues from where it was.

enum Phase { case stopped, working, resting }

/// Describes the application being watched. Only HandBrake for now; the
/// structure is here so other encoders can be added as profiles later.
struct Target {
    let name: String
    let bundleMarker: String     // substring of the executable path that identifies the app's processes
    let workerMarker: String     // substring identifying the processes that do the heavy work
}

let target = Target(name: "HandBrake", bundleMarker: "HandBrake.app/", workerMarker: "XPCServices")

let popoverWidth: CGFloat = 380
let windowWidth: CGFloat = 455

// MARK: - Temperature (hottest CPU die sensor)
// Apple Silicon exposes no public API for die temperatures; this is the private IOHID
// sensor interface used by the usual menu bar monitors. If it ever stops working the
// chart simply shows no temperature line.
private typealias IOHIDEventSystemClientRef = CFTypeRef
private typealias IOHIDServiceClientRef = CFTypeRef
private typealias IOHIDEventRef = CFTypeRef
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> IOHIDEventSystemClientRef?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ c: IOHIDEventSystemClientRef, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ c: IOHIDEventSystemClientRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ s: IOHIDServiceClientRef, _ k: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ s: IOHIDServiceClientRef, _ t: Int64, _ o: Int32, _ ts: Int64) -> IOHIDEventRef?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ e: IOHIDEventRef, _ f: Int32) -> Double

final class TemperatureReader {
    private var client: IOHIDEventSystemClientRef?
    private var dieSensors: [IOHIDServiceClientRef] = []
    init() {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
        let services = IOHIDEventSystemClientCopyServices(c) as? [IOHIDServiceClientRef] ?? []
        dieSensors = services.filter {
            (IOHIDServiceClientCopyProperty($0, "Product" as CFString) as? String)?.lowercased().contains("tdie") == true
        }
    }
    /// Hottest CPU die in °C, nil when no sensor is readable.
    func hottest() -> Double? {
        var best: Double? = nil
        for s in dieSensors {
            guard let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0) else { continue }
            let v = IOHIDEventGetFloatValue(e, 15 << 16)
            if v > 0 && v < 150 { best = max(best ?? 0, v) }
        }
        return best
    }
}

// MARK: - CPU & temperature chart
struct Sample { let t: TimeInterval; let cpu: Double; let temp: Double?; let resting: Bool }

final class ChartView: NSView {
    var samples: [Sample] = []
    var cpuMax: Double = 100          // y scale for the CPU line (grows with observed load)
    let minWindow: TimeInterval = 5 * 60
    let maxWindow: TimeInterval = 6 * 3600
    let headerRow = ClickableRow()
    let chevron = NSImageView()
    let header = NSTextField(labelWithString: "CPU & temperature")
    let legend = LinkButton(title: "", target: nil, action: nil)
    var onToggle: (() -> Void)?
    /// Manual zoom span (nil = automatic window). Pinch or scroll over the plot sets it; "Reset" clears it.
    /// Custom view set by zoom or pan: left edge and width. nil = automatic view.
    var view: (start: TimeInterval, span: TimeInterval)? { didSet { needsDisplay = true } }
    /// With a custom view: the right edge tracks the newest sample (or, while the data is
    /// narrower than the view, the left edge stays on the first sample).
    var followNow = true
    var isCustomView: Bool { view != nil }
    var collapsed = false { didSet { chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: collapsed ? "Expand chart" : "Collapse chart"); needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        legend.isBordered = false
        legend.isEnabled = false
        legend.target = self; legend.action = #selector(resetZoom)
        legend.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = NSStackView(views: [chevron, header]); titleRow.orientation = .horizontal; titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(titleRow)
        headerRow.onClick = { [weak self] in self?.onToggle?() }
        headerRow.highlightsBackground = false
        headerRow.onHover = { [weak self] on in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self?.chevron.animator().alphaValue = on ? 0.6 : 1
                self?.header.animator().alphaValue = on ? 0.6 : 1
            }
        }
        for v in [headerRow, legend] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor), titleRow.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            titleRow.topAnchor.constraint(equalTo: headerRow.topAnchor), titleRow.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor), headerRow.topAnchor.constraint(equalTo: topAnchor),
            legend.trailingAnchor.constraint(equalTo: trailingAnchor), legend.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: fullHeight)
        heightConstraint.isActive = true
        collapsed = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var allowsVibrancy: Bool { false }   // keep real colours inside the popover

    // hover: time under the cursor, or nil
    var hoverT: TimeInterval? { didSet { if hoverT != oldValue { needsDisplay = true } } }
    private var geom: (left: CGFloat, right: CGFloat, start: TimeInterval, span: TimeInterval, bottom: CGFloat, top: CGFloat)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredArrow = leftArrowRect.contains(p) ? -1 : rightArrowRect.contains(p) ? 1 : 0
        guard !collapsed, let g = geom, let last = samples.last else { hoverT = nil; return }
        guard p.x >= g.left - 4, p.x <= g.right + 4, p.y >= g.bottom, p.y <= g.top else { hoverT = nil; return }
        let t = g.start + Double((min(max(p.x, g.left), g.right) - g.left) / (g.right - g.left)) * g.span
        hoverT = min(t, min(last.t, range.end))
    }
    override func mouseExited(with event: NSEvent) { hoverT = nil; hoveredArrow = 0 }
    func visibleSamples(_ a: TimeInterval, _ b: TimeInterval) -> [Sample] { samples.filter { $0.t >= a && $0.t <= b } }
    /// The left edge may sit anywhere from the first sample up to a few seconds before the newest one:
    /// empty space on the right is fine (the view fills up as time passes), empty space on the left is not.
    func clampStart(_ start: TimeInterval, span: TimeInterval) -> TimeInterval {
        guard let first = samples.first?.t, let last = samples.last?.t else { return start }
        return min(max(first, last - 5), max(first, start))
    }
    /// Does a view placed at `start` naturally track now? Yes when its right edge sits on the newest sample,
    /// or when it is left-anchored while the data is still narrower than it (it fills up like the automatic view).
    func tracksNow(start: TimeInterval, span: TimeInterval) -> Bool {
        guard let first = samples.first?.t, let last = samples.last?.t else { return true }
        return abs(start + span - last) <= 0.5 || (span > last - first && start <= first + 0.5)
    }
    private func markCustom() { legend.isEnabled = true; window?.invalidateCursorRects(for: legend) }

    @objc func resetZoom() {
        guard let first = samples.first?.t, let last = samples.last?.t else { return }
        let autoSpan = last - first >= maxWindow ? maxWindow : max(minWindow, last - first)
        let autoStart = last - first >= maxWindow ? last - maxWindow : first
        animateView(toStart: autoStart, toSpan: autoSpan) { [weak self] in
            self?.view = nil; self?.followNow = true
            self?.legend.isEnabled = false; self?.window?.invalidateCursorRects(for: self!.legend)
        }
    }
    private var viewTween: Timer?
    /// Glides the view to a target over 0.8 s with ease-in-out, then runs `done`.
    private func animateView(toStart: TimeInterval, toSpan: TimeInterval, done: @escaping () -> Void) {
        viewTween?.invalidate()
        let (s0, e0) = range
        let fromStart = s0, fromSpan = e0 - s0, t0 = Date()
        followNow = false
        markCustom()
        viewTween = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(t0) / 0.8)
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            self.view = (fromStart + (toStart - fromStart) * e, fromSpan + (toSpan - fromSpan) * e)
            if p >= 1 { t.invalidate(); done() }
        }
    }

    /// Called for every new sample: a fixed view whose right edge "now" has just reached starts tracking it,
    /// exactly like the automatic view does; a view deliberately panned back (now already beyond) stays put.
    func noteNewSample() {
        guard let v = view, !followNow, samples.count >= 2 else { return }
        let last = samples[samples.count - 1].t, previous = samples[samples.count - 2].t
        let edge = v.start + v.span
        if previous < edge - 0.5 && last >= edge - 0.5 { followNow = true }
    }

    /// Shifts the view in time; back at the newest sample it tracks now again.
    private func pan(by dt: TimeInterval) {
        let (start, end) = range
        let span = end - start
        let newStart = clampStart(start + dt, span: span)
        view = (newStart, span)
        followNow = tracksNow(start: newStart, span: span)
        markCustom()
    }
    private var dragLastX: CGFloat?
    private var leftArrowRect = NSRect.zero, rightArrowRect = NSRect.zero
    private var hoveredArrow: Int = 0 { didSet { if hoveredArrow != oldValue { needsDisplay = true } } }   // -1 left, 1 right
    override func resetCursorRects() {
        if !leftArrowRect.isEmpty { addCursorRect(leftArrowRect, cursor: .pointingHand) }
        if !rightArrowRect.isEmpty { addCursorRect(rightArrowRect, cursor: .pointingHand) }
    }
    /// Jump to the newest data keeping the current zoom.
    func goToNow() {
        guard let last = samples.last?.t else { return }
        let span = range.end - range.start
        animateView(toStart: clampStart(last - span, span: span), toSpan: span) { [weak self] in self?.followNow = true; self?.markCustom() }
    }
    /// Jump to the beginning of the recorded history keeping the current zoom.
    func goToStart() {
        guard let first = samples.first?.t else { return }
        let span = range.end - range.start
        animateView(toStart: first, toSpan: span) { [weak self] in
            guard let self = self else { return }
            self.followNow = self.tracksNow(start: first, span: span); self.markCustom()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if rightArrowRect.contains(p) { goToNow(); return }
        if leftArrowRect.contains(p) { goToStart(); return }
        if event.clickCount == 2 { resetZoom(); return }
        guard let g = geom, !collapsed, p.x >= g.left, p.x <= g.right, p.y >= g.bottom, p.y <= g.top else { super.mouseDown(with: event); return }
        dragLastX = p.x
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let lastX = dragLastX, let g = geom else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dt = -Double((p.x - lastX) / (g.right - g.left)) * g.span   // drag right = go back in time
        dragLastX = p.x
        pan(by: dt)
        hoverT = nil
    }
    override func mouseUp(with event: NSEvent) {
        if dragLastX != nil { NSCursor.pop(); dragLastX = nil }
    }

    /// Longest span that has data: nothing to zoom into beyond what was recorded.
    let minZoom: TimeInterval = 60
    var availableSpan: TimeInterval {
        guard let first = samples.first?.t, let last = samples.last?.t else { return 0 }
        return min(maxWindow, last - first)
    }
    /// Zooms around `anchor` (a time): the point under the cursor keeps its place on screen.
    private func zoom(by factor: Double, at anchor: TimeInterval?) {
        guard !collapsed, let first = samples.first?.t, let last = samples.last?.t, last - first > 5 else { return }
        let (start, end) = range
        let current = end - start
        let autoWidth = last - first >= maxWindow ? maxWindow : max(minWindow, last - first)
        let widest = max(availableSpan, autoWidth)                // zoom out up to what the automatic view shows
        let next = min(widest, max(minZoom, current * factor))
        let pivot = anchor ?? end
        let frac = (pivot - start) / current
        let newStart = clampStart(pivot - frac * next, span: next)
        // back at the automatic view: drop the custom view, so "Reset" gives way to "Past …"
        if abs(next - autoWidth) < 0.5 && tracksNow(start: newStart, span: next) {
            view = nil; followNow = true
            legend.isEnabled = false; window?.invalidateCursorRects(for: legend)
            return
        }
        view = (newStart, next)
        followNow = tracksNow(start: newStart, span: next)
        markCustom()
    }
    private func timeAt(_ event: NSEvent) -> TimeInterval? {
        guard let g = geom else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return g.start + Double((min(max(p.x, g.left), g.right) - g.left) / (g.right - g.left)) * g.span
    }
    override func scrollWheel(with event: NSEvent) {
        guard let g = geom, !collapsed else { return }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if abs(dx) > abs(dy) {
            guard abs(dx) > 0.5 else { return }
            pan(by: -Double(dx / (g.right - g.left)) * g.span)
        } else if !event.hasPreciseScrollingDeltas {
            guard abs(dy) > 0.5 else { return }
            zoom(by: dy > 0 ? 1.04 : 1 / 1.04, at: timeAt(event))
        }
    }
    override func magnify(with event: NSEvent) { zoom(by: 1 / max(0.2, 1 + event.magnification), at: timeAt(event)) }
    let fullHeight: CGFloat = 140
    let collapsedHeight: CGFloat = 18
    var targetHeight: CGFloat { collapsed ? collapsedHeight : fullHeight }
    var heightConstraint: NSLayoutConstraint!

    var span: TimeInterval {
        guard let first = samples.first?.t, let last = samples.last?.t else { return minWindow }
        return min(maxWindow, max(minWindow, last - first))
    }
    /// Visible time range: starts at the first sample and grows (5 min minimum) until it
    /// reaches 6 hours, then slides so the newest sample stays at the right edge.
    var range: (start: TimeInterval, end: TimeInterval) {
        guard let first = samples.first?.t, let last = samples.last?.t else { let n = Date.timeIntervalSinceReferenceDate; return (n - minWindow, n) }
        if let v = view {
            // following: right edge on the newest sample once the data is wide enough, left-anchored before that
            let start = followNow ? (v.span <= last - first ? last - v.span : first) : clampStart(v.start, span: v.span)
            return (start, start + v.span)
        }
        if last - first >= maxWindow { return (last - maxWindow, last) }
        return (first, first + max(minWindow, last - first))
    }

    func windowLabel() -> String {
        let w = span
        if w < 3600 { return "Past \(Int((w / 60).rounded())) min" }
        let h = w / 3600
        return h == h.rounded() ? "Past \(Int(h)) hours" : String(format: "Past %.1f hours", h)
    }

    /// Series colours: the system ones in light appearance, lifted a little on the dark panel.
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var tempColor: NSColor { isDark ? NSColor.systemOrange.blended(withFraction: 0.15, of: .white) ?? .systemOrange : .systemOrange }
    var cpuColor: NSColor { panelBlue(for: self) }

    override func draw(_ dirtyRect: NSRect) {
        if collapsed {
            // the header carries the live values while the plot is folded away
            let last = samples.last
            let a = NSMutableAttributedString()
            func part(_ label: String, _ value: String, _ color: NSColor) {
                a.append(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                a.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]))
            }
            part("CPU ", last.map { "\(Int($0.cpu))%" } ?? "–", .labelColor)
            a.append(NSAttributedString(string: "   ·   ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            part("Temp ", last?.temp.map { "\(Int($0.rounded()))°C" } ?? "n/a", .labelColor)
            legend.attributedTitle = a
            return
        }
        legend.attributedTitle = {
            let a = NSMutableAttributedString(string: "■ Rest    ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            a.addAttribute(.foregroundColor, value: NSColor.labelColor.withAlphaComponent(0.18), range: NSRange(location: 0, length: 1))
            if isCustomView {
                a.append(NSAttributedString(string: "Reset", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue]))
            } else {
                a.append(NSAttributedString(string: windowLabel(), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            return a
        }()
        guard let last = samples.last else { return }
        let plotLeft: CGFloat = 46, plotRight = bounds.width - 48, top = bounds.height - 30, axisH: CGFloat = 20
        let plotW = plotRight - plotLeft
        let plotsTop = top, plotsBottom = axisH
        let gap: CGFloat = 14
        let laneH = (plotsTop - plotsBottom - gap) / 2
        let cpuLane = NSRect(x: plotLeft, y: plotsBottom + laneH + gap, width: plotW, height: laneH)
        let tempLane = NSRect(x: plotLeft, y: plotsBottom, width: plotW, height: laneH)
        let (tStart, tEnd) = range
        let w = tEnd - tStart
        geom = (plotLeft, plotRight, tStart, w, plotsBottom, plotsTop)
        func x(_ t: TimeInterval) -> CGFloat { plotLeft + CGFloat((t - tStart) / w) * plotW }
        // the sample under the cursor, if any: it takes over the right-hand values and the axis
        let hovered: Sample? = hoverT.flatMap { ht in visibleSamples(tStart, tEnd).min { abs($0.t - ht) < abs($1.t - ht) } }
            .flatMap { abs($0.t - hoverT!) < 30 ? $0 : nil }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: plotLeft, y: plotsBottom, width: plotW, height: plotsTop - plotsBottom)).addClip()
        // rest shading
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        var restStart: TimeInterval? = nil
        for (i, smp) in samples.enumerated() where smp.t >= tStart - 1 {
            if smp.resting && restStart == nil { restStart = smp.t }
            let ends = !smp.resting || i == samples.count - 1
            if let rs = restStart, ends {
                NSRect(x: x(max(rs, tStart)), y: plotsBottom, width: max(1, x(smp.t) - x(max(rs, tStart))), height: plotsTop - plotsBottom).fill()
                restStart = nil
            }
        }
        // divider between the lanes and baseline above the time axis
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        for y in [cpuLane.minY - gap / 2, tempLane.minY] {
            let b = NSBezierPath(); b.move(to: NSPoint(x: plotLeft, y: y)); b.line(to: NSPoint(x: plotRight, y: y)); b.lineWidth = 1; b.stroke()
        }
        // lines, one point per pixel column (mean of the samples in that column)
        let visible = samples.filter { $0.t >= tStart && $0.t <= tEnd }
        func path(_ value: (Sample) -> Double?, lane: NSRect, maxV: Double, minV: Double) -> NSBezierPath {
            let p = NSBezierPath(); p.lineWidth = 1.5; p.lineJoinStyle = .round
            var col = -1, acc = 0.0, n = 0, started = false
            func flush(_ c: Int) {
                guard n > 0 else { return }
                let v = acc / Double(n)
                let py = lane.minY + CGFloat((v - minV) / max(1, maxV - minV)) * lane.height
                let pt = NSPoint(x: plotLeft + CGFloat(c), y: min(lane.maxY, max(lane.minY, py)))
                if started { p.line(to: pt) } else { p.move(to: pt); started = true }
            }
            for smp in visible {
                guard let v = value(smp) else { continue }
                let c = Int(x(smp.t) - plotLeft)
                if c != col { flush(col); col = c; acc = 0; n = 0 }
                acc += v; n += 1
            }
            flush(col)
            return p
        }
        cpuColor.setStroke()
        path({ $0.cpu }, lane: cpuLane, maxV: cpuMax, minV: 0).stroke()
        let temps = visible.compactMap { $0.temp }
        let tMin = floor(((temps.min() ?? 30) - 5) / 10) * 10, tMax = ceil(((temps.max() ?? 80) + 5) / 10) * 10
        tempColor.setStroke()
        path({ $0.temp }, lane: tempLane, maxV: tMax, minV: tMin).stroke()
        NSGraphicsContext.restoreGraphicsState()
        // now line + end dots
        let nowVisible = last.t <= tEnd + 0.5
        let nx = x(last.t)
        if nowVisible {
            let now = NSBezierPath(); now.move(to: NSPoint(x: nx, y: plotsBottom)); now.line(to: NSPoint(x: nx, y: plotsTop))
            now.setLineDash([3, 3], count: 2, phase: 0); now.lineWidth = 1; NSColor.labelColor.withAlphaComponent(0.45).setStroke(); now.stroke()
        }
        // edge chevrons: newer data to the right, older data to the left (click to jump)
        func chevron(at cx: CGFloat, pointingRight: Bool) -> NSRect {
            let cy = (plotsTop + plotsBottom) / 2, d: CGFloat = pointingRight ? 1 : -1
            let hot = hoveredArrow == (pointingRight ? 1 : -1)
            let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: cx - 2 * d, y: cy + 4)); arrow.line(to: NSPoint(x: cx + 2 * d, y: cy)); arrow.line(to: NSPoint(x: cx - 2 * d, y: cy - 4))
            arrow.lineWidth = hot ? 2 : 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            (hot ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke(); arrow.stroke()
            return NSRect(x: cx - 10, y: plotsBottom, width: 20, height: plotsTop - plotsBottom)
        }
        let oldL = leftArrowRect, oldR = rightArrowRect
        rightArrowRect = nowVisible ? .zero : chevron(at: plotRight + 7, pointingRight: true)
        let firstT = samples.first?.t ?? tStart
        leftArrowRect = tStart > firstT + 0.5 ? chevron(at: plotLeft - 7, pointingRight: false) : .zero
        if oldL != leftArrowRect || oldR != rightArrowRect { window?.invalidateCursorRects(for: self) }
        func dot(_ v: Double, lane: NSRect, maxV: Double, minV: Double, _ color: NSColor) {
            let py = lane.minY + CGFloat((v - minV) / max(1, maxV - minV)) * lane.height
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: nx - 3, y: min(lane.maxY, max(lane.minY, py)) - 3, width: 6, height: 6)).fill()
        }
        if nowVisible {
            dot(last.cpu, lane: cpuLane, maxV: cpuMax, minV: 0, cpuColor)
            if let t = last.temp { dot(t, lane: tempLane, maxV: tMax, minV: tMin, tempColor) }
        }
        // labels
        func text(_ s: String, _ pt: NSPoint, _ color: NSColor, _ weight: NSFont.Weight = .regular, right: Bool = false) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight), .foregroundColor: color])
            let sz = a.size(); a.draw(at: NSPoint(x: right ? pt.x - sz.width : pt.x, y: pt.y - sz.height / 2))
        }
        text("CPU", NSPoint(x: 0, y: cpuLane.midY), cpuColor, .semibold)
        text("Temp", NSPoint(x: 0, y: tempLane.midY), tempColor, .semibold)
        let shown = hovered ?? last
        text("\(Int(shown.cpu))%", NSPoint(x: bounds.width, y: cpuLane.midY), cpuColor, .semibold, right: true)
        text(shown.temp.map { "\(Int($0.rounded()))°C" } ?? "n/a", NSPoint(x: bounds.width, y: tempLane.midY), tempColor, .semibold, right: true)
        // hover cursor: solid line and dots at the hovered sample
        if let hv = hovered {
            let hx = x(hv.t)
            let line = NSBezierPath(); line.move(to: NSPoint(x: hx, y: plotsBottom)); line.line(to: NSPoint(x: hx, y: plotsTop))
            line.lineWidth = 1; NSColor.labelColor.withAlphaComponent(0.6).setStroke(); line.stroke()
            func hdot(_ v: Double, lane: NSRect, maxV: Double, minV: Double, _ color: NSColor) {
                let py = lane.minY + CGFloat((v - minV) / max(1, maxV - minV)) * lane.height
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: hx - 3, y: min(lane.maxY, max(lane.minY, py)) - 3, width: 6, height: 6)).fill()
            }
            hdot(hv.cpu, lane: cpuLane, maxV: cpuMax, minV: 0, cpuColor)
            if let t = hv.temp { hdot(t, lane: tempLane, maxV: tMax, minV: tMin, tempColor) }
        }
        // time axis: the start time flush left, "Now" at the right, the others spread evenly in between
        let labelCount = min(bounds.width > 420 ? 6 : 4, max(2, Int(w / 60)))   // never closer than a minute
        let f = DateFormatter(); f.dateFormat = w < 120 ? "HH:mm:ss" : "HH:mm"
        let hx: CGFloat? = hovered.map { x($0.t) }
        var previous = ""
        for i in 0..<labelCount {
            let t = tStart + w * Double(i) / Double(labelCount)          // spread over the visible window
            let tx = x(t)
            let rightX = nowVisible ? nx : plotRight
            let label = f.string(from: Date(timeIntervalSinceReferenceDate: t))
            let lw = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).size().width
            let lx = i == 0 ? plotLeft : tx - lw / 2
            let clearOfHover = hx.map { abs($0 - (lx + lw / 2)) > lw + 6 } ?? true
            guard t <= last.t, rightX - (lx + lw) > 8, clearOfHover, label != previous else { continue }
            previous = label
            text(label, NSPoint(x: lx, y: 7), .secondaryLabelColor)
        }
        if let hv = hovered, let hx = hx {
            let label = f.string(from: Date(timeIntervalSinceReferenceDate: hv.t))
            let lw = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).size().width
            let lx = min(max(hx - lw / 2, 0), bounds.width - lw)   // centred on the line, kept inside the view
            text(label, NSPoint(x: lx, y: 7), .labelColor, .semibold)
            if (nowVisible ? nx : plotRight) - hx > 50 { rightLabel() }
        } else {
            rightLabel()
        }
        func rightLabel() {
            if nowVisible { text("Now", NSPoint(x: nx + 14, y: 7), .secondaryLabelColor, .medium, right: true) }
            else { text(f.string(from: Date(timeIntervalSinceReferenceDate: tEnd)), NSPoint(x: plotRight + 14, y: 7), .secondaryLabelColor, .medium, right: true) }
        }
    }
}

/// The accent blue, lifted on the dark panel so it reads the same everywhere (chart, progress, button).
func panelBlue(for view: NSView) -> NSColor {
    let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return dark ? NSColor.controlAccentColor.blended(withFraction: 0.15, of: .white) ?? .controlAccentColor : .controlAccentColor
}

/// Thin progress line drawn with the panel blue.
final class ProgressLine: NSView {
    /// Target value; the drawn value eases towards it over 300 ms (so the drop to zero is smooth too).
    var value: Double = 0 { didSet { if value != oldValue { animate(to: value) } } }
    private var shown: Double = 0 { didSet { needsDisplay = true } }
    private var tween: Timer?
    private func animate(to target: Double) {
        tween?.invalidate()
        let from = shown, start = Date()
        tween = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let p = min(1, Date().timeIntervalSince(start) / 0.3)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            self?.shown = from + (target - from) * eased
            if p >= 1 { t.invalidate() }
        }
    }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.labelColor.withAlphaComponent(0.12).setFill(); track.fill()
        let w = max(4, bounds.width * CGFloat(min(1, max(0, shown))))
        panelBlue(for: self).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

/// Image view that keeps its real colour inside a popover (no vibrancy blending).
final class SolidImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}

/// Panel background: a click on empty space drops focus from a text field and commits its value.
final class BackgroundView: NSView {
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

/// Read-only log text that stays out of the Tab loop.
final class LogTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
}

/// Eases a layer colour change over 150 ms (view-backed layers do not animate implicitly).
func easeLayerColor(_ layer: CALayer?, _ keyPath: String, to color: CGColor?) {
    guard let layer = layer else { return }
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
    anim.toValue = color
    anim.duration = 0.15
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(anim, forKey: keyPath)
    layer.setValue(color, forKeyPath: keyPath)
}

/// Row that reports clicks to a closure, with a light hover highlight and a hand cursor.
final class ClickableRow: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var highlightsBackground = true
    private var hoverAlpha: CGFloat = 0 { didSet { needsDisplay = true } }
    private var fade: Timer?
    private var hovered = false {
        didSet {
            onHover?(hovered)
            fade?.invalidate()
            let from = hoverAlpha, to: CGFloat = hovered ? 1 : 0, start = Date()
            fade = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                let p = min(1, Date().timeIntervalSince(start) / 0.15)
                self?.hoverAlpha = from + (to - from) * CGFloat(p)
                if p >= 1 { t.invalidate() }
            }
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        guard hoverAlpha > 0, highlightsBackground else { return }
        NSColor.labelColor.withAlphaComponent(0.05 * hoverAlpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// The activity log box: a bordered container with a fully clickable header row
/// (chevron, title, event count) that expands to show the list inside the same box.
final class LogBoxView: NSView {
    let header = ClickableRow()
    let chevron = NSImageView()
    let title = NSTextField(labelWithString: "Activity log")
    let count = NSTextField(labelWithString: "")
    let dot = NSTextField(labelWithString: "·")
    let clear = LinkButton(title: "Clear", target: nil, action: nil)
    let scroll = NSScrollView()
    let list = LogTextView()
    var onToggle: (() -> Void)?
    var onClear: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        title.font = .systemFont(ofSize: 13, weight: .medium)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11)
        clear.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        clear.target = self; clear.action = #selector(clearTapped)
        clear.setAccessibilityLabel("Clear activity log")
        dot.font = .systemFont(ofSize: 11); dot.textColor = .secondaryLabelColor
        let row = NSStackView(views: [chevron, title, NSView(), count, dot, clear])
        row.setCustomSpacing(5, after: count)
        row.setCustomSpacing(5, after: dot)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        header.onClick = { [weak self] in self?.onToggle?() }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor), row.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            row.topAnchor.constraint(equalTo: header.topAnchor), row.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
        ])

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        list.isEditable = false
        list.drawsBackground = false
        list.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        list.textContainerInset = NSSize(width: 12, height: 6)
        list.isVerticallyResizable = true
        list.isHorizontallyResizable = false
        list.autoresizingMask = [.width]
        list.textContainer?.widthTracksTextView = true
        list.minSize = NSSize(width: 0, height: 0)
        list.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = list

        let separator = NSBox(); separator.boxType = .separator
        let column = NSStackView(views: [header, separator, scroll])
        column.orientation = .vertical; column.alignment = .width; column.spacing = 0
        column.setCustomSpacing(4, after: separator)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.separator = separator
        expanded = false
    }
    required init?(coder: NSCoder) { fatalError() }
    private var separator: NSBox!
    @objc func clearTapped() { onClear?() }

    var expanded = false {
        didSet {
            scroll.isHidden = !expanded
            separator.isHidden = !expanded
            chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                    accessibilityDescription: expanded ? "Collapse activity log" : "Expand activity log")
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
    }
}

/// Bordered container for a number field: clear border in both appearances, accent border while editing.
final class NumberBox: NSView {
    let field = NSTextField()
    var editing = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 72),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        easeLayerColor(layer, "backgroundColor", to: NSColor.labelColor.withAlphaComponent(hovered && !editing ? 0.11 : 0.06).cgColor)
        easeLayerColor(layer, "borderColor", to: editing ? NSColor.controlAccentColor.cgColor : NSColor.labelColor.withAlphaComponent(0.16).cgColor)
    }
}

/// Checkbox drawn in the same style as the number fields: bordered box, eased hover, accent fill when on.
final class StyledCheckbox: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }
    private let boxSize: CGFloat = 18
    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: boxSize + 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { isOn.toggle(); onToggle?() }
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0, y: (bounds.height - boxSize) / 2, width: boxSize, height: boxSize)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        if isOn {
            (hovered ? NSColor.controlAccentColor.blended(withFraction: 0.10, of: .white) ?? .controlAccentColor : .controlAccentColor).setFill(); path.fill()
            let check = NSBezierPath(); check.lineWidth = 2; check.lineCapStyle = .round; check.lineJoinStyle = .round
            check.move(to: NSPoint(x: r.minX + 4.5, y: r.midY)); check.line(to: NSPoint(x: r.minX + 7.5, y: r.minY + 4.5)); check.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 5))
            NSColor.white.setStroke(); check.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(hovered ? 0.11 : 0.06).setFill(); path.fill()
            NSColor.labelColor.withAlphaComponent(0.16).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

/// Text link: hand cursor on hover, like a web link.
final class LinkButton: NSButton {
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Flat button in the prototype style: rounded 8 pt, thin border, generous padding.
/// Primary = accent fill with white text; secondary = subtle fill with label text.
final class FlatButton: NSButton {
    let primary: Bool
    var hoverFill: NSColor?          // e.g. red for a destructive action
    init(title: String, primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        font = .systemFont(ofSize: primary ? 14 : 12, weight: .medium)
        setContentHuggingPriority(.required, for: .horizontal)
        updateTitleColor()
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateTitleColor() {
        let white = primary || (hovered && hoverFill != nil)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font!, .foregroundColor: white ? NSColor.white : NSColor.labelColor])
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTitleColor() }
    override var title: String { didSet { if wantsLayer { updateTitleColor() } } }
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + (primary ? 28 : 24), height: primary ? 34 : 30)
    }
    private var hovered = false { didSet { updateTitleColor(); needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let fill: NSColor?, border: NSColor
        if primary {
            let base = NSColor.controlAccentColor
            fill = isHighlighted ? base.blended(withFraction: 0.2, of: .black) : hovered ? base.blended(withFraction: 0.10, of: .white) : base
            border = NSColor.white.withAlphaComponent(0.12)
        } else if hovered, let red = hoverFill {
            fill = isHighlighted ? red.blended(withFraction: 0.2, of: .black) : red
            border = NSColor.white.withAlphaComponent(0.12)
        } else {
            fill = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : hovered ? 0.11 : 0.06)
            border = NSColor.labelColor.withAlphaComponent(0.16)
        }
        easeLayerColor(layer, "backgroundColor", to: fill?.cgColor)
        easeLayerColor(layer, "borderColor", to: border.cgColor)
    }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    // always in the Tab loop, not only with Full Keyboard Access; focus must be visible
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
}

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    // MARK: UI
    var statusItem: NSStatusItem!
    let panelController = NSViewController()
    let popover = NSPopover()
    var window: NSWindow?
    var panelWidth: NSLayoutConstraint!

    let statusSymbol = SolidImageView()
    let statusTitle = NSTextField(labelWithString: "")
    let statusSubtitle = NSTextField(labelWithString: "")
    let countdown = NSTextField(labelWithString: "")
    let progressWrap = NSStackView()
    let progress = ProgressLine()
    let progressLabel = NSTextField(labelWithString: "")
    let progressDetail = NSTextField(labelWithString: "")
    let chart = ChartView()
    let thermometer = TemperatureReader()
    let workBox = NumberBox()
    let restBox = NumberBox()
    var workField: NSTextField { workBox.field }
    var restField: NSTextField { restBox.field }
    let runButton = FlatButton(title: "Start cycle", primary: true)
    let detachCheckbox = StyledCheckbox(title: "Detached window")
    let logBox = LogBoxView()
    let versionLink = LinkButton(title: "", target: nil, action: nil)
    var updateURL: URL?
    var updateZip: URL?
    var updateSha: URL?
    var updateVersion = ""
    var updating = false
    var announcedThisRun = ""
    var quitting = false
    var logView: NSTextView { logBox.list }
    var logExpanded = false
    var logCount = 0

    // MARK: State
    var timer: Timer?
    var phase: Phase = .stopped
    var lastTick = Date()
    var workSeconds: Double = 0      // seconds of real encoding accumulated
    var idleSeconds: Double = 0      // consecutive seconds without encoding
    var lowSeconds: Double = 0       // consecutive seconds below the CPU threshold
    let idleGrace: Double = 10       // seconds of low CPU before "idle" is declared
    var restStart = Date()
    var restEnd = Date()
    var pausePlanned: Date?          // set when the work minutes are done: the next whole minute
    var isEncoding = false
    var frozenPids: [pid_t] = []
    let defaults = UserDefaults.standard
    var threshold: Double { defaults.object(forKey: "threshold") == nil ? 50.0 : defaults.double(forKey: "threshold") }
    // the cycle uses the committed values, not what is being typed in the fields
    var committedWork = 60
    var committedRest = 5
    var workMinutes: Double { Double(max(1, committedWork)) }
    var restMinutes: Double { Double(max(1, committedRest)) }
    var detached: Bool { defaults.bool(forKey: "window") }

    /// Cat icons for the four states: black template PNGs (menu bar 20 pt, panel 48 pt)
    /// that follow the appearance like system symbols.
    static func stateIcon(_ state: String, panel: Bool, description: String) -> NSImage? {
        let img = NSImage(named: (panel ? "panel-" : "state-") + state)
        img?.size = NSSize(width: panel ? 48 : 20, height: panel ? 48 : 20)   // the PNG dpi metadata must not shrink it
        img?.isTemplate = true
        img?.accessibilityDescription = description
        return img
    }

    /// The app artwork in the variant matching the current appearance, for dialogs: the .icns
    /// Finder and the Dock use has a single variant on macOS versions without Icon Composer support.
    static func appArtwork() -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSImage(named: dark ? "Siesta-dark-512" : "Siesta-light-512") ?? NSApp.applicationIconImage
    }

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ n: Notification) {
        // Hidden switch for checking both appearances: --appearance light|dark
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
            popover.appearance = NSApp.appearance
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.imageHugsTitle = true
        buildPanel()
        let w = defaults.integer(forKey: "work"), r = defaults.integer(forKey: "rest")
        workField.integerValue = w == 0 ? 60 : w
        restField.integerValue = r == 0 ? 5 : r
        committedWork = workField.integerValue
        committedRest = restField.integerValue
        detachCheckbox.isOn = detached
        logExpanded = defaults.bool(forKey: "logExpanded")   // collapsed the first time, then as last left
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        rescueFrozen()
        installSignalHandlers()
        installPopoverGlide()
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        refresh()
        if CommandLine.arguments.contains("--start") { toggleRun() }
        if CommandLine.arguments.contains("--auto-update") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.openUpdate() }
        }
        // The status item must be laid out before a popover can attach to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel() }
    }

    func applicationWillTerminate(_ n: Notification) { resume() }

    var signalSources: [DispatchSourceSignal] = []
    /// kill / logout / Ctrl-C must never leave the encoder frozen.
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.quitting = true
                self?.resume()
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Panel construction
    func divider() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    func buildPanel() {
        // Status row: symbol, title + subtitle, big countdown on the right
        statusSymbol.imageScaling = .scaleProportionallyUpOrDown
        statusSymbol.widthAnchor.constraint(equalToConstant: 34).isActive = true
        statusSymbol.heightAnchor.constraint(equalToConstant: 34).isActive = true
        statusTitle.font = .systemFont(ofSize: 16, weight: .medium)
        statusSubtitle.font = .systemFont(ofSize: 13)
        statusSubtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [statusTitle, statusSubtitle])
        titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        countdown.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
        countdown.alignment = .right
        countdown.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = NSStackView(views: [statusSymbol, titles, NSView(), countdown])
        statusRow.orientation = .horizontal; statusRow.alignment = .centerY; statusRow.spacing = 13
        statusRow.setCustomSpacing(16, after: titles)

        // Thin progress line with caption
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        progressLabel.font = .systemFont(ofSize: 11); progressLabel.textColor = .secondaryLabelColor
        progressDetail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressDetail.textColor = .secondaryLabelColor
        let caption = NSStackView(views: [progressLabel, NSView(), progressDetail])
        caption.orientation = .horizontal; caption.spacing = 10
        progressWrap.setViews([progress, caption], in: .top)
        chart.isHidden = true
        chart.collapsed = defaults.bool(forKey: "chartCollapsed")
        chart.heightConstraint.constant = chart.targetHeight
        chart.onToggle = { [weak self] in self?.toggleChart() }
        progressWrap.orientation = .vertical; progressWrap.alignment = .width; progressWrap.spacing = 4

        // Settings grid: labels on the left, field + unit flush right
        func numberField(_ box: NumberBox, _ label: String) -> NSView {
            let field = box.field
            field.alignment = .right
            field.font = .systemFont(ofSize: 15)
            field.setAccessibilityLabel(label)
            let f = NumberFormatter(); f.minimum = 1; f.maximum = 1440; f.allowsFloats = false
            field.formatter = f
            field.delegate = self
            let unit = NSTextField(labelWithString: "min")
            unit.font = .systemFont(ofSize: 13); unit.textColor = .secondaryLabelColor
            unit.alignment = .right
            unit.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let s = NSStackView(views: [box, unit]); s.orientation = .horizontal; s.alignment = .centerY; s.spacing = 9
            return s
        }
        let workLabel = NSTextField(labelWithString: "Work"); workLabel.font = .systemFont(ofSize: 14)
        let restLabel = NSTextField(labelWithString: "Rest"); restLabel.font = .systemFont(ofSize: 14)
        let grid = NSGridView(views: [[workLabel, numberField(workBox, "Work minutes")],
                                      [restLabel, numberField(restBox, "Rest minutes")]])
        grid.rowSpacing = 13; grid.columnSpacing = 12
        grid.xPlacement = .leading
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.rowAlignment = .none
        grid.yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.required, for: .horizontal)
        grid.widthAnchor.constraint(equalToConstant: grid.fittingSize.width).isActive = true   // never stretch

        // Big run button filling the right half, as tall as the two rows
        runButton.target = self; runButton.action = #selector(toggleRun)
        runButton.font = .systemFont(ofSize: 15, weight: .medium)
        runButton.updateTitleColor()
        runButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        runButton.setContentHuggingPriority(.defaultLow, for: .vertical)
        // grid flush left, button flush right taking half the width
        let settings = NSStackView()
        settings.orientation = .horizontal; settings.alignment = .top; settings.spacing = 24
        settings.addView(grid, in: .leading)
        settings.addView(runButton, in: .trailing)
        NSLayoutConstraint.activate([
            runButton.heightAnchor.constraint(equalTo: grid.heightAnchor),
            runButton.widthAnchor.constraint(equalTo: settings.widthAnchor, multiplier: 0.5, constant: -12),
        ])
        detachCheckbox.onToggle = { [weak self] in self?.toggleDetached() }

        // Activity log box
        logBox.onToggle = { [weak self] in self?.toggleLog() }
        logBox.onClear = { [weak self] in self?.clearLog() }
        logBox.clear.isHidden = true
        logBox.dot.isHidden = true

        // Footer: secondary quit button, right aligned
        let quitButton = FlatButton(title: "Quit Siesta", primary: false)
        quitButton.hoverFill = .systemRed
        quitButton.target = self; quitButton.action = #selector(quit)
        quitButton.setAccessibilityLabel("Quit Siesta")
        versionLink.isBordered = false
        versionLink.target = self; versionLink.action = #selector(openUpdate)
        versionLink.setContentHuggingPriority(.required, for: .horizontal)
        showVersion()
        let footer = NSStackView(views: [detachCheckbox, NSView(), versionLink, quitButton])
        footer.orientation = .horizontal; footer.alignment = .centerY
        footer.setCustomSpacing(12, after: versionLink)
        detachCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)   // never truncate the label
        // Tab order: Work → Rest → Start/Stop → Quit → Work
        workField.nextKeyView = restField
        restField.nextKeyView = runButton
        runButton.nextKeyView = quitButton
        quitButton.nextKeyView = workField

        let column = NSStackView(views: [statusRow, progressWrap, chart, divider(), settings, divider(), logBox, footer])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 19
        column.setCustomSpacing(19, after: progressWrap)
        column.setCustomSpacing(19, after: chart)
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false
        // the column does not reliably stretch children with an intrinsic width: pin every row to the edges
        for row in [statusRow, progressWrap, chart, settings, logBox, footer] as [NSView] {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 24),
                row.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -24),
            ])
        }

        let background = BackgroundView()
        background.addSubview(column)
        panelWidth = background.widthAnchor.constraint(equalToConstant: popoverWidth)
        panelWidth.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: background.topAnchor),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
            panelWidth,
        ])
        background.autoresizingMask = [.width, .height]   // follow the popover / window content area
        panelController.view = background
        showPlaceholder()
        popover.behavior = .transient
        popover.animates = true
    }

    /// Grows or shrinks the chart (and the panel with it) over a quarter of a second.
    var chartAnimation: Timer?
    func animateChart(visible: Bool) {
        chartAnimation?.invalidate()
        let from = chart.isHidden ? 0 : chart.heightConstraint.constant
        let to: CGFloat = visible ? chart.targetHeight : 0
        if visible { chart.isHidden = false }
        let start = Date(), duration = 0.25
        chartAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            self.chart.heightConstraint.constant = from + (to - from) * CGFloat(eased)
            self.chart.alphaValue = visible ? CGFloat(p) : CGFloat(1 - p)
            self.layoutPanel()
            if p >= 1 {
                timer.invalidate()
                if !visible { self.chart.isHidden = true; self.chart.heightConstraint.constant = self.chart.targetHeight }
                self.chart.alphaValue = 1
                self.layoutPanel()
            }
        }
    }

    func toggleChart() {
        chart.collapsed.toggle()
        defaults.set(chart.collapsed, forKey: "chartCollapsed")
        chartAnimation?.invalidate()
        let from = chart.heightConstraint.constant, to = chart.targetHeight
        let start = Date(), duration = 0.22
        chartAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            self.chart.heightConstraint.constant = from + (to - from) * CGFloat(eased)
            self.layoutPanel()
            if p >= 1 { timer.invalidate() }
        }
    }

    /// Recomputes the panel size after a layout change (log toggled, mode switched).
    func layoutPanel() {
        logBox.expanded = logExpanded
        logBox.count.stringValue = logCount == 0 ? "No events yet" : "\(logCount) event\(logCount == 1 ? "" : "s")"
        panelWidth.constant = detached ? windowWidth : popoverWidth
        panelController.view.layoutSubtreeIfNeeded()
        let size = panelController.view.fittingSize   // the container sizes the view: never set its frame by hand
        if detached, let w = window, w.contentViewController === panelController {
            w.setContentSize(size)
        } else {
            // resize without the popover's own animation, which redraws the whole panel visibly
            let animates = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = animates
        }
    }

    // MARK: Popover / window
    @objc func statusItemClicked() {
        if detached { showPanel() }
        else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    func showPanel() {
        if detached {
            if popover.isShown { popover.performClose(nil) }
            popover.contentViewController = nil
            if window == nil {
                let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Siesta"
                w.isReleasedWhenClosed = false
                w.autorecalculatesKeyViewLoop = false
                w.level = .floating          // stays visible above other apps' windows
                window = w
            }
            window!.contentViewController = panelController
            layoutPanel()
            if !window!.isVisible { window!.center() }
            if !CommandLine.arguments.contains("--no-activate") { NSApp.activate(ignoringOtherApps: true) }   // tests stay in the background
            window!.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        } else {
            window?.orderOut(nil)
            window?.contentViewController = nil
            popover.contentViewController = panelController
            layoutPanel()
            popover.contentSize = panelController.view.fittingSize
            guard let button = statusItem.button else { return }
            if !CommandLine.arguments.contains("--no-activate") { NSApp.activate(ignoringOtherApps: true) }
            // anchor the arrow to the icon, not to the whole icon + countdown button
            lastPopoverFrame = .zero
            popover.show(relativeTo: iconAnchor(), of: button, preferredEdge: .minY)
            lastPopoverFrame = popoverWindow?.frame ?? .zero
            DispatchQueue.main.async { [weak self] in
                self?.panelController.view.window?.autorecalculatesKeyViewLoop = false
                self?.panelController.view.window?.makeFirstResponder(nil)
            }
        }
    }

    /// Rect of the icon inside the status button, so the popover arrow stays centred on it
    /// whatever the countdown next to it says.
    func iconAnchor() -> NSRect {
        guard let button = statusItem.button else { return .zero }
        guard let image = button.image, !button.title.isEmpty else { return button.bounds }
        let inset = (button.bounds.width - image.size.width - button.attributedTitle.size().width) / 2
        return NSRect(x: 0, y: 0, width: image.size.width + 2 * max(0, inset), height: button.bounds.height)
    }

    // MARK: Smooth popover follow
    // AppKit snaps the popover to the status item whenever the item moves (our countdown
    // changing width, other apps' items resizing). Catch the snap and glide instead.
    var popoverWindow: NSWindow? { popover.contentViewController?.view.window }
    var lastPopoverFrame: NSRect = .zero
    var glidingPopover = false

    func installPopoverGlide() {
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let w = n.object as? NSWindow, w === self.popoverWindow, self.popover.isShown, !self.glidingPopover else { return }
            let target = w.frame
            let from = self.lastPopoverFrame
            // first placement, vertical moves or tiny shifts: just remember the frame
            guard from != .zero, from.size == target.size, abs(from.minY - target.minY) < 1, abs(from.minX - target.minX) >= 2 else {
                self.lastPopoverFrame = target; return
            }
            self.glidingPopover = true
            w.setFrame(from, display: false)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                self?.lastPopoverFrame = target
                self?.glidingPopover = false
            })
        }
    }

    @objc func toggleDetached() {
        let on = detachCheckbox.isOn
        defaults.set(on, forKey: "window")
        showPanel()
    }

    @objc func toggleLog() {
        logExpanded.toggle()
        defaults.set(logExpanded, forKey: "logExpanded")
        layoutPanel()
        if logExpanded { logView.scrollToEndOfDocument(nil) }
    }

    func clearLog() {
        logCount = 0
        showPlaceholder()
        logBox.count.stringValue = "No events yet"
        logBox.clear.isHidden = true
        logBox.dot.isHidden = true
    }

    @objc func quit() { quitting = true; NSApp.terminate(nil) }

    // MARK: Version and update check
    static let repo = "Interstellar0verdrive/Siesta"
    var currentVersion: String {
        if let i = CommandLine.arguments.firstIndex(of: "--version-override"), i + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[i + 1]      // hidden switch for testing the update path
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func showVersion() {
        updateURL = nil
        versionLink.attributedTitle = NSAttributedString(string: "v\(currentVersion)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        versionLink.isEnabled = false
        versionLink.toolTip = nil
        versionLink.window?.invalidateCursorRects(for: versionLink)
    }

    func showUpdate(version: String, url: URL) {
        updateURL = url
        versionLink.attributedTitle = NSAttributedString(string: "Update to \(version)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        versionLink.isEnabled = true
        versionLink.toolTip = canSelfUpdate && updateZip != nil
            ? "Download and install Siesta \(version) in place, then relaunch"
            : "Open the release page"
        versionLink.window?.invalidateCursorRects(for: versionLink)
    }

    /// Mentions a new release once per version: the footer link alone is easy to miss.
    func announceUpdate(_ version: String) {
        guard announcedThisRun != version else { return }   // once per launch; "Later" means next launch
        announcedThisRun = version
        let alert = NSAlert()
        alert.icon = App.appArtwork()
        alert.messageText = "Siesta \(version) is available"
        alert.informativeText = canSelfUpdate && updateZip != nil
            ? "Click “Update to \(version)” next to the Quit button. Siesta downloads the new version, replaces itself and relaunches; macOS will not ask for approval again."
            : "Click “Update to \(version)” next to the Quit button to open the release page."
        alert.addButton(withTitle: canSelfUpdate && updateZip != nil ? "Update now" : "Open release page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openUpdate() }
    }

    @objc func openUpdate() {
        if updateZip != nil && updateSha != nil && canSelfUpdate { performUpdate() }
        else if let url = updateURL { NSWorkspace.shared.open(url) }
    }

    // MARK: In-app update
    // Downloads the release zip, checks its SHA-256, swaps the bundle in place and relaunches.
    // A bundle written by the app itself carries no quarantine flag, so Gatekeeper does not
    // ask again: only the very first installation needs the manual approval.
    var canSelfUpdate: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    func updateStatus(_ text: String) {
        versionLink.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }

    func updateFailed(_ reason: String) {
        updating = false
        log("Update failed: \(reason)")
        if let url = updateURL { showUpdate(version: updateVersion, url: url) }
    }

    func performUpdate() {
        guard let zipURL = updateZip, let shaURL = updateSha, !updating else { return }
        updating = true
        versionLink.isEnabled = false
        updateStatus("Updating…")
        log("Downloading Siesta \(updateVersion)")
        // 1) expected hash
        URLSession.shared.dataTask(with: shaURL) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data, let text = String(data: data, encoding: .utf8),
                  let expected = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init),
                  expected.count == 64 else {
                DispatchQueue.main.async { self.updateFailed("checksum file unreadable") }; return
            }
            // 2) the zip, with progress
            let task = URLSession.shared.downloadTask(with: zipURL) { tmp, _, error in
                guard let tmp = tmp, error == nil, let zipData = try? Data(contentsOf: tmp) else {
                    DispatchQueue.main.async { self.updateFailed(error?.localizedDescription ?? "download error") }; return
                }
                let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                guard digest == expected.lowercased() else {
                    DispatchQueue.main.async { self.updateFailed("checksum mismatch") }; return
                }
                DispatchQueue.main.async { self.install(zipData: zipData) }
            }
            task.resume()
        }.resume()
    }

    func install(zipData: Data) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("siesta-update-\(UUID().uuidString)")
        let zip = work.appendingPathComponent("update.zip")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try zipData.write(to: zip)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.path]
            try unzip.run(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { throw NSError(domain: "Siesta", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not unpack the archive"]) }
            let newApp = work.appendingPathComponent("Siesta.app")
            let plist = newApp.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: plist), let v = info["CFBundleShortVersionString"] as? String, v == updateVersion else {
                throw NSError(domain: "Siesta", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected package contents"])
            }
            // 3) swap: old bundle to the Trash, new one in place
            let current = Bundle.main.bundleURL
            let destination = current
            try fm.trashItem(at: current, resultingItemURL: nil)
            try fm.moveItem(at: newApp, to: destination)
            try? fm.removeItem(at: work)
            log("Installed Siesta \(updateVersion), relaunching")
            // 4) relaunch after this process has quit; a frozen worker is resumed on termination
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(destination.path)\""]
            try relaunch.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        } catch {
            try? fm.removeItem(at: work)
            updateFailed(error.localizedDescription)
        }
    }

    /// Compares dotted version strings numerically: 1.10.0 > 1.9.2.
    func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func checkForUpdate() {
        guard let url = URL(string: "https://api.github.com/repos/\(App.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            func asset(_ suffix: String) -> URL? {
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            }
            let zip = asset(".zip"), sha = asset(".zip.sha256")
            DispatchQueue.main.async {
                guard !self.updating else { return }
                if self.isNewer(latest, than: self.currentVersion) {
                    self.updateZip = zip; self.updateSha = sha; self.updateVersion = latest
                    self.showUpdate(version: latest, url: page)
                    self.announceUpdate(latest)
                } else { self.showVersion() }
            }
        }.resume()
    }

    @objc func toggleRun() {
        panelController.view.window?.makeFirstResponder(nil)
        if phase == .stopped {
            committedWork = max(1, workField.integerValue); committedRest = max(1, restField.integerValue)
            defaults.set(committedWork, forKey: "work")
            defaults.set(committedRest, forKey: "rest")
            phase = .working
            workSeconds = 0; idleSeconds = 0; lowSeconds = 0; isEncoding = false; pausePlanned = nil
            lastTick = Date()
            log("Cycle started · \(Int(workMinutes)) min work, \(Int(restMinutes)) min rest")
        } else {
            resume()
            phase = .stopped
            log("Cycle stopped")
        }
        refresh()
    }

    /// Return commits the field and drops focus; it must never reach the run button.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            control.window?.makeFirstResponder(nil)
            return true
        }
        // ↑ / ↓ step by 1, with Shift by 10, within 1…1440 minutes
        let up = selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveUpAndModifySelection(_:))
        let down = selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveDownAndModifySelection(_:))
        if up || down {
            let step = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
            let current = Int(textView.string) ?? 1
            let value = min(1440, max(1, current + (up ? step : -step)))
            textView.string = String(value)
            textView.selectAll(nil)
            return true
        }
        return false
    }

    func controlTextDidChange(_ n: Notification) {
        guard let field = n.object as? NSTextField, let editor = field.currentEditor() else { return }
        let digits = editor.string.filter { $0.isASCII && $0.isNumber }
        if digits != editor.string { editor.string = digits }
    }

    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        // empty, zero or out of range: fall back to the saved value
        if let field = control as? NSTextField {
            field.integerValue = max(1, defaults.integer(forKey: field === workField ? "work" : "rest"))
        }
        return true
    }

    func controlTextDidBeginEditing(_ n: Notification) {
        (n.object as? NSTextField)?.superview.flatMap { $0 as? NumberBox }?.editing = true
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard !quitting, let field = n.object as? NSTextField else { return }
        (field.superview as? NumberBox)?.editing = false
        let key = field === workField ? "work" : "rest"
        let name = field === workField ? "Work" : "Rest"
        let old = defaults.integer(forKey: key)
        let new = max(1, field.integerValue)
        field.integerValue = new
        if field === workField { committedWork = new } else { committedRest = new }
        if new != old {
            defaults.set(new, forKey: key)
            log("\(name) interval changed to \(new) min")
            refresh()
        }
    }

    // MARK: Processes
    struct Proc { let pid: pid_t; let cpu: Double; let path: String; let frozen: Bool }

    func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // read before waiting, or large output deadlocks
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Every process belonging to the target app: the UI and the workers that do the real encoding.
    func targetProcesses() -> [Proc] {
        let pids = run("/usr/bin/pgrep", ["-f", target.bundleMarker])
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !pids.isEmpty else { return [] }
        let out = run("/bin/ps", ["-o", "pid=,%cpu=,stat=,comm=", "-p", pids.joined(separator: ",")])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]),
                  parts[3].contains(target.bundleMarker) else { return nil }
            return Proc(pid: pid, cpu: cpu, path: parts[3], frozen: parts[2].hasPrefix("T"))
        }
    }

    func resume() {
        for pid in frozenPids { kill(pid, SIGCONT) }
        frozenPids = []
    }

    /// Unfreezes target processes left stopped by an earlier Siesta that did not exit cleanly.
    func rescueFrozen() {
        let stuck = targetProcesses().filter { $0.frozen }
        guard !stuck.isEmpty else { return }
        for p in stuck { kill(p.pid, SIGCONT) }
        log("Resumed \(stuck.count) \(target.name) process\(stuck.count == 1 ? "" : "es") left frozen")
    }

    // MARK: Loop
    /// Share of the whole CPU (all logical cores = 100%), the way activity monitors show it.
    let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
    func percentOfMachine(_ cpu: Double) -> Double { min(100, cpu / coreCount) }

    func record(cpu rawCpu: Double) {
        let cpu = percentOfMachine(rawCpu)
        let t = Date.timeIntervalSinceReferenceDate
        // dense while the chart is still filling its first 5 minutes, then one point every 5 s
        let every: TimeInterval = (chart.samples.first.map { t - $0.t } ?? 0) < chart.minWindow ? 1 : 5
        if let last = chart.samples.last?.t, t - last < every - 0.5 { return }
        chart.samples.append(Sample(t: t, cpu: cpu, temp: thermometer.hottest(), resting: phase == .resting))
        chart.noteNewSample()
        if let first = chart.samples.first?.t, t - first > chart.maxWindow + 60 {
            chart.samples.removeFirst(chart.samples.count / 10)   // trim in chunks, cheap
        }
        // folded: refresh the header values only every 5 s, the data keeps its own cadence
        if !chart.isHidden && (!chart.collapsed || t - lastCollapsedRefresh >= 5) {
            chart.needsDisplay = true
            lastCollapsedRefresh = t
        }
    }
    var lastCollapsedRefresh: TimeInterval = 0

    func tick() {
        let now = Date()
        let dt = min(5, now.timeIntervalSince(lastTick))
        lastTick = now
        switch phase {
        case .stopped:
            record(cpu: targetProcesses().reduce(0) { $0 + $1.cpu })
        case .working:
            let procs = targetProcesses()
            let totalCpu = procs.reduce(0) { $0 + $1.cpu }
            record(cpu: totalCpu)
            let busy = !procs.isEmpty && totalCpu >= threshold
            // Hysteresis: between two queue items HandBrake drops to 0% for a few seconds.
            // Only treat it as idle after `idleGrace` seconds of continuous low CPU.
            if busy { lowSeconds = 0 } else { lowSeconds += dt }
            let encoding = busy || (isEncoding && lowSeconds < idleGrace)
            if encoding != isEncoding {
                isEncoding = encoding
                log(encoding ? "\(target.name) is encoding" :
                    (procs.isEmpty ? "\(target.name) is not running" : "\(target.name) is idle · CPU \(Int(percentOfMachine(totalCpu)))%"))
            }
            if encoding {
                workSeconds += dt; idleSeconds = 0
                // The work would complete at `projected` (e.g. 18:52:33): pause at the start of
                // that minute (18:52:00), so the rest also ends on a whole minute.
                let projected = now.timeIntervalSinceReferenceDate + (workMinutes * 60 - workSeconds)
                let pauseAt = Date(timeIntervalSinceReferenceDate: floor(projected / 60) * 60)
                pausePlanned = pauseAt
                if now >= pauseAt {
                    let planned = Date(timeIntervalSinceReferenceDate: floor(now.timeIntervalSinceReferenceDate / 60) * 60)
                    // Freeze the workers; fall back to every process if none is identifiable.
                    let workers = procs.filter { $0.path.contains(target.workerMarker) }
                    let toFreeze = workers.isEmpty ? procs : workers
                    for p in toFreeze { kill(p.pid, SIGSTOP) }
                    frozenPids = toFreeze.map { $0.pid }
                    phase = .resting
                    pausePlanned = nil
                    restStart = planned
                    restEnd = planned.addingTimeInterval(restMinutes * 60)
                    log("\(target.name) paused · CPU \(Int(percentOfMachine(totalCpu)))%")
                }
            } else {
                idleSeconds += dt
                if workSeconds > 0 && idleSeconds >= restMinutes * 60 {
                    workSeconds = 0; pausePlanned = nil
                    log("Idle for \(Int(restMinutes)) min · work counter reset")
                }
            }
        case .resting:
            record(cpu: 0)   // the worker is frozen
            if now >= restEnd {
                resume()
                phase = .working
                workSeconds = 0; idleSeconds = 0; pausePlanned = nil
                log("\(target.name) resumed")
            }
        }
        refresh()
    }

    func showPlaceholder() {
        logView.textStorage?.setAttributedString(NSAttributedString(string: "No events yet.", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
    }

    func log(_ s: String) {
        if logCount == 0 { logView.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 46)]
        para.headIndent = 46; para.paragraphSpacing = 4
        let line = NSMutableAttributedString(string: "\(f.string(from: Date()))\t\(s)\n", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        line.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: 5))
        logView.textStorage?.append(line)
        logView.scrollToEndOfDocument(nil)
        logCount += 1
        logBox.count.stringValue = "\(logCount) event\(logCount == 1 ? "" : "s")"
        logBox.clear.isHidden = false
        logBox.dot.isHidden = false
    }

    func setStatus(state: String, description: String, title: String, subtitle: String, count: String, tooltip: String, barTitle: String) {
        statusSymbol.image = App.stateIcon(state, panel: true, description: description)
        statusSymbol.contentTintColor = .labelColor   // dynamic: follows appearance changes while shown
        statusSymbol.alphaValue = 0.92
        statusTitle.stringValue = title
        statusSubtitle.stringValue = subtitle
        countdown.stringValue = count
        statusItem.button?.image = App.stateIcon(state, panel: false, description: description)
        statusItem.button?.title = barTitle
        statusItem.button?.toolTip = "Siesta — " + tooltip
        if popover.isShown {
            // the button may have changed width: re-centre the arrow after layout
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.popover.isShown else { return }
                self.popover.positioningRect = self.iconAnchor()
            }
        }
    }

    func refresh() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let hideProgress = phase == .stopped
        if progressWrap.isHidden != hideProgress {
            progressWrap.isHidden = hideProgress
            animateChart(visible: !hideProgress)
        }
        switch phase {
        case .stopped:
            setStatus(state: "stopped", description: "Siesta inactive", title: "Cycle stopped",
                      subtitle: "\(target.name) is not managed by Siesta", count: "—",
                      tooltip: "inactive", barTitle: "")
            runButton.title = "Start cycle"
        case .working:
            let total = workMinutes * 60
            let elapsed = min(workSeconds, total)
            let left = Int(ceil((total - elapsed) / 60))
            // the bar runs until the planned pause, which comes early in the first cycle
            let untilPause = max(0, (pausePlanned ?? Date().addingTimeInterval(total - elapsed)).timeIntervalSinceNow)
            progress.value = isEncoding ? elapsed / max(1, elapsed + untilPause) : progress.value
            progressLabel.stringValue = "Work interval"
            progressDetail.stringValue = "\(Int(elapsed / 60)) of \(Int(workMinutes)) min elapsed"
            if isEncoding {
                let eta = f.string(from: pausePlanned ?? Date().addingTimeInterval(total - elapsed))
                setStatus(state: "working", description: "Working", title: "\(target.name) is working",
                          subtitle: "Next pause at \(eta)", count: "\(left)m",
                          tooltip: "\(target.name) is working, pause in \(left) min", barTitle: "\(left)m")
            } else {
                setStatus(state: "waiting", description: "Waiting", title: "Waiting for \(target.name)",
                          subtitle: "\(target.name) is not encoding", count: "\(left)m",
                          tooltip: "waiting, \(target.name) is not encoding", barTitle: "")
            }
            runButton.title = "Stop cycle"
        case .resting:
            let total = max(1, restEnd.timeIntervalSince(restStart))
            let elapsed = min(Date().timeIntervalSince(restStart), total)
            let left = Int(ceil((total - elapsed) / 60))
            progress.value = elapsed / total
            progressLabel.stringValue = "Rest interval"
            progressDetail.stringValue = "\(Int(elapsed / 60)) of \(Int(restMinutes)) min elapsed"
            setStatus(state: "resting", description: "Resting", title: "\(target.name) is resting",
                      subtitle: "Resumes at \(f.string(from: restEnd))", count: "\(left)m",
                      tooltip: "resting, \(target.name) resumes in \(left) min", barTitle: "\(left)m")
            runButton.title = "Stop cycle"
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
