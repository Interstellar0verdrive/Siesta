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
let windowWidth: CGFloat = 490

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
    let legend = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?
    var collapsed = false { didSet { chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: collapsed ? "Expand chart" : "Collapse chart"); needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        legend.font = .systemFont(ofSize: 11); legend.textColor = .secondaryLabelColor
        legend.alignment = .right
        let titleRow = NSStackView(views: [chevron, header]); titleRow.orientation = .horizontal; titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(titleRow)
        headerRow.onClick = { [weak self] in self?.onToggle?() }
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
        if last - first >= maxWindow { return (last - maxWindow, last) }
        return (first, first + max(minWindow, last - first))
    }

    func windowLabel() -> String {
        let w = span
        if w < 3600 { return "Past \(Int((w / 60).rounded())) min" }
        let h = w / 3600
        return h == h.rounded() ? "Past \(Int(h)) hours" : String(format: "Past %.1f hours", h)
    }

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
            legend.attributedStringValue = a
            return
        }
        legend.attributedStringValue = {
            let a = NSMutableAttributedString(string: "■ Rest    " + windowLabel(), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            a.addAttribute(.foregroundColor, value: NSColor.labelColor.withAlphaComponent(0.18), range: NSRange(location: 0, length: 1))
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
        func x(_ t: TimeInterval) -> CGFloat { plotLeft + CGFloat((t - tStart) / w) * plotW }

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
        let visible = samples.filter { $0.t >= tStart }
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
        NSColor.controlAccentColor.setStroke()
        path({ $0.cpu }, lane: cpuLane, maxV: cpuMax, minV: 0).stroke()
        let temps = visible.compactMap { $0.temp }
        let tMin = floor(((temps.min() ?? 30) - 5) / 10) * 10, tMax = ceil(((temps.max() ?? 80) + 5) / 10) * 10
        NSColor.systemOrange.setStroke()
        path({ $0.temp }, lane: tempLane, maxV: tMax, minV: tMin).stroke()
        // now line + end dots
        let nx = x(last.t)
        let now = NSBezierPath(); now.move(to: NSPoint(x: nx, y: plotsBottom)); now.line(to: NSPoint(x: nx, y: plotsTop))
        now.setLineDash([3, 3], count: 2, phase: 0); now.lineWidth = 1; NSColor.labelColor.withAlphaComponent(0.45).setStroke(); now.stroke()
        func dot(_ v: Double, lane: NSRect, maxV: Double, minV: Double, _ color: NSColor) {
            let py = lane.minY + CGFloat((v - minV) / max(1, maxV - minV)) * lane.height
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: nx - 3, y: min(lane.maxY, max(lane.minY, py)) - 3, width: 6, height: 6)).fill()
        }
        dot(last.cpu, lane: cpuLane, maxV: cpuMax, minV: 0, .controlAccentColor)
        if let t = last.temp { dot(t, lane: tempLane, maxV: tMax, minV: tMin, .systemOrange) }
        // labels
        func text(_ s: String, _ pt: NSPoint, _ color: NSColor, _ weight: NSFont.Weight = .regular, right: Bool = false) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight), .foregroundColor: color])
            let sz = a.size(); a.draw(at: NSPoint(x: right ? pt.x - sz.width : pt.x, y: pt.y - sz.height / 2))
        }
        text("CPU", NSPoint(x: 0, y: cpuLane.midY), .controlAccentColor, .semibold)
        text("Temp", NSPoint(x: 0, y: tempLane.midY), .systemOrange, .semibold)
        text("\(Int(last.cpu))%", NSPoint(x: bounds.width, y: cpuLane.midY), .controlAccentColor, .semibold, right: true)
        text(last.temp.map { "\(Int($0.rounded()))°C" } ?? "n/a", NSPoint(x: bounds.width, y: tempLane.midY), .systemOrange, .semibold, right: true)
        // time axis: at most 4 labels (6 in the wider window) plus "Now"; a label never overlaps "Now"
        let maxTicks = bounds.width > 420 ? 6 : 4
        let steps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200]
        let step = steps.first { w / $0 <= Double(maxTicks) } ?? 7200
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        var tick = (floor(tStart / step) + 1) * step
        while tick <= tEnd {
            let tx = x(tick)
            if abs(tx - nx) > 44 { text(f.string(from: Date(timeIntervalSinceReferenceDate: tick)), NSPoint(x: tx - 16, y: 7), .secondaryLabelColor) }
            tick += step
        }
        text("Now", NSPoint(x: nx + 14, y: 7), .secondaryLabelColor, .medium, right: true)
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

/// Row that reports clicks to a closure.
final class ClickableRow: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
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
            chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                                    accessibilityDescription: expanded ? "Collapse activity log" : "Expand activity log")
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }
}

/// Bordered container for a number field: clear border in both appearances, accent border while editing.
final class NumberBox: NSView {
    let field = NSTextField()
    var editing = false { didSet { needsDisplay = true } }
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
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = editing ? NSColor.controlAccentColor.cgColor : NSColor.labelColor.withAlphaComponent(0.35).cgColor
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
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font!, .foregroundColor: primary ? NSColor.white : NSColor.labelColor])
    }
    override var title: String { didSet { if wantsLayer { updateTitleColor() } } }
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + (primary ? 28 : 24), height: primary ? 34 : 30)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if primary {
            layer?.backgroundColor = (isHighlighted ? NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) : NSColor.controlAccentColor)?.cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.08).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        }
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
    let progress = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")
    let progressDetail = NSTextField(labelWithString: "")
    let chart = ChartView()
    let thermometer = TemperatureReader()
    let workBox = NumberBox()
    let restBox = NumberBox()
    var workField: NSTextField { workBox.field }
    var restField: NSTextField { restBox.field }
    let runButton = FlatButton(title: "Start cycle", primary: true)
    let detachCheckbox = NSButton(checkboxWithTitle: "Detached window", target: nil, action: nil)
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
    var isEncoding = false
    var frozenPids: [pid_t] = []
    let defaults = UserDefaults.standard
    var threshold: Double { defaults.object(forKey: "threshold") == nil ? 50.0 : defaults.double(forKey: "threshold") }
    var workMinutes: Double { max(1, Double(workField.integerValue)) }
    var restMinutes: Double { max(1, Double(restField.integerValue)) }
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
        detachCheckbox.state = detached ? .on : .off
        logExpanded = detached
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
        progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1; progress.controlSize = .small
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
        detachCheckbox.target = self; detachCheckbox.action = #selector(toggleDetached)

        // Activity log box
        logBox.onToggle = { [weak self] in self?.toggleLog() }
        logBox.onClear = { [weak self] in self?.clearLog() }
        logBox.clear.isHidden = true
        logBox.dot.isHidden = true

        // Footer: secondary quit button, right aligned
        let quitButton = FlatButton(title: "Quit Siesta", primary: false)
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
        let on = detachCheckbox.state == .on
        defaults.set(on, forKey: "window")
        logExpanded = on          // the prototype opens the log in the window, closes it in the popover
        showPanel()
    }

    @objc func toggleLog() {
        logExpanded.toggle()
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
            defaults.set(workField.integerValue, forKey: "work")
            defaults.set(restField.integerValue, forKey: "rest")
            phase = .working
            workSeconds = 0; idleSeconds = 0; lowSeconds = 0; isEncoding = false
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
    func record(cpu: Double) {
        let t = Date.timeIntervalSinceReferenceDate
        // dense while the chart is still filling its first 5 minutes, then one point every 5 s
        let every: TimeInterval = (chart.samples.first.map { t - $0.t } ?? 0) < chart.minWindow ? 1 : 5
        if let last = chart.samples.last?.t, t - last < every - 0.5 { return }
        chart.samples.append(Sample(t: t, cpu: cpu, temp: thermometer.hottest(), resting: phase == .resting))
        chart.cpuMax = max(chart.cpuMax, ceil(cpu / 100) * 100)
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
                    (procs.isEmpty ? "\(target.name) is not running" : "\(target.name) is idle · CPU \(Int(totalCpu))%"))
            }
            if encoding {
                workSeconds += dt; idleSeconds = 0
                if workSeconds >= workMinutes * 60 {
                    // Freeze the workers; fall back to every process if none is identifiable.
                    let workers = procs.filter { $0.path.contains(target.workerMarker) }
                    let toFreeze = workers.isEmpty ? procs : workers
                    for p in toFreeze { kill(p.pid, SIGSTOP) }
                    frozenPids = toFreeze.map { $0.pid }
                    phase = .resting
                    restStart = now
                    log("\(target.name) paused · CPU \(Int(totalCpu))%")
                }
            } else {
                idleSeconds += dt
                if workSeconds > 0 && idleSeconds >= restMinutes * 60 {
                    workSeconds = 0
                    log("Idle for \(Int(restMinutes)) min · work counter reset")
                }
            }
        case .resting:
            record(cpu: 0)   // the worker is frozen
            if now.timeIntervalSince(restStart) >= restMinutes * 60 {
                resume()
                phase = .working
                workSeconds = 0; idleSeconds = 0
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
            progress.doubleValue = elapsed / total
            progressLabel.stringValue = "Work interval"
            progressDetail.stringValue = "\(Int(elapsed / 60)) of \(Int(workMinutes)) min elapsed"
            if isEncoding {
                setStatus(state: "working", description: "Working", title: "\(target.name) is working",
                          subtitle: "Next pause", count: "\(left)m",
                          tooltip: "\(target.name) is working, pause in \(left) min", barTitle: "\(left)m")
            } else {
                setStatus(state: "waiting", description: "Waiting", title: "Waiting for \(target.name)",
                          subtitle: "\(target.name) is not encoding", count: "\(left)m",
                          tooltip: "waiting, \(target.name) is not encoding", barTitle: "")
            }
            runButton.title = "Stop cycle"
        case .resting:
            let total = restMinutes * 60
            let elapsed = min(Date().timeIntervalSince(restStart), total)
            let left = Int(ceil((total - elapsed) / 60))
            progress.doubleValue = elapsed / total
            progressLabel.stringValue = "Rest interval"
            progressDetail.stringValue = "\(Int(elapsed / 60)) of \(Int(restMinutes)) min elapsed"
            setStatus(state: "resting", description: "Resting", title: "\(target.name) is resting",
                      subtitle: "Resumes at \(f.string(from: restStart.addingTimeInterval(total)))", count: "\(left)m",
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
