import AppKit
import CryptoKit
import ServiceManagement

// Siesta — a menu bar utility that gives a long-running encoder periodic rests.
// It counts minutes of real work, freezes the worker processes (SIGSTOP) for a
// rest period and resumes them (SIGCONT). Nothing is lost: the frozen process
// simply continues from where it was.

enum Phase { case stopped, working, resting }

/// The clock the panel texts and log read. `--debug-scene` pins it, so the README images show set times.
var sceneClock: Date?
func clockNow() -> Date { sceneClock ?? Date() }

/// Describes the application being watched. Only HandBrake for now; the
/// structure is here so other encoders can be added as profiles later.
struct Target {
    let name: String
    let bundleMarker: String     // substring of the executable path that identifies the app's processes
    let workerMarker: String     // substring identifying the processes that do the heavy work
}

// The encoder runs in HandBrakeXPCService(2…4).xpc; a bare "XPCServices" would also catch the
// Sparkle updater (Sparkle.framework/…/XPCServices/Downloader.xpc) and freeze it during a rest.
let target = Target(name: "HandBrake", bundleMarker: "HandBrake.app/", workerMarker: "XPCServices/HandBrakeXPCService")

let popoverWidth: CGFloat = 380
/// `--debug-window-width <pt>`: renders the detached window at another width (boards for the detach animation).
let windowWidth: CGFloat = {
    if let i = CommandLine.arguments.firstIndex(of: "--debug-window-width"), i + 1 < CommandLine.arguments.count,
       let w = Double(CommandLine.arguments[i + 1]) { return CGFloat(w) }
    return 455
}()

// MARK: - Temperature (hottest CPU core)
// Apple Silicon has no public API for core temperatures. The first source is the SMC, through
// the AppleSMC driver: the per-core keys that Stats shows as "Hottest CPU". When no SMC key
// answers, the private IOHID die sensors ("PMU tdie") are used; they read the whole package and
// stay about 20 °C below the hottest core under load. If neither works the chart simply shows
// no temperature line.
private typealias IOHIDEventSystemClientRef = CFTypeRef
private typealias IOHIDServiceClientRef = CFTypeRef
private typealias IOHIDEventRef = CFTypeRef
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> IOHIDEventSystemClientRef?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ c: IOHIDEventSystemClientRef, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ c: IOHIDEventSystemClientRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ s: IOHIDServiceClientRef, _ k: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ s: IOHIDServiceClientRef, _ t: Int64, _ o: Int32, _ ts: Int64) -> IOHIDEventRef?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ e: IOHIDEventRef, _ f: Int32) -> Double

/// Minimal reader for the SMC's float temperature keys.
private final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func name(_ c: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: c >> $0) }, encoding: .ascii) ?? "?"
    }

    // The driver's SMCKeyData_t, 80 bytes: key @0, dataSize @28, dataType @32, result @40,
    // command @42, index @44, data @48.
    private func call(command: UInt8, key: UInt32 = 0, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80), output = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            $0.storeBytes(of: command, toByteOffset: 42, as: UInt8.self)
            $0.storeBytes(of: index, toByteOffset: 44, as: UInt32.self)
        }
        var outSize = 80
        guard IOConnectCallStructMethod(conn, 2, &input, 80, &output, &outSize) == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }
    private func u32(_ b: [UInt8], _ at: Int) -> UInt32 { b.withUnsafeBytes { $0.load(fromByteOffset: at, as: UInt32.self) } }

    /// True when `key` exists and holds a 4-byte float.
    func isFloat(_ key: UInt32) -> Bool {
        guard let info = call(command: 9, key: key) else { return false }
        return u32(info, 28) == 4 && u32(info, 32) == SMC.code("flt ")
    }
    func float(_ key: UInt32) -> Double? {
        guard let out = call(command: 5, key: key, size: 4) else { return nil }
        return Double(out.withUnsafeBytes { $0.load(fromByteOffset: 48, as: Float32.self) })
    }
    /// Every key the SMC knows (a few thousand): used only to find sensors once, never per sample.
    func allKeys() -> [UInt32] {
        let countKey = SMC.code("#KEY")
        guard let info = call(command: 9, key: countKey), let out = call(command: 5, key: countKey, size: u32(info, 28)) else { return [] }
        let count = UInt32(out[48]) << 24 | UInt32(out[49]) << 16 | UInt32(out[50]) << 8 | UInt32(out[51])
        return (0..<count).compactMap { i in call(command: 8, index: i).map { u32($0, 0) } }
    }
}

final class TemperatureReader {
    /// The keys Stats lists as "CPU efficiency core 1-4" and "CPU performance core 1-8" on the M4
    /// family; the ones a given chip lacks are skipped. On other chips every Tp* (performance
    /// cluster) and Te* (efficiency cluster) float key is used.
    static let m4CoreKeys = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]

    private let smc = SMC()
    private(set) var coreKeys: [UInt32] = []
    private var client: IOHIDEventSystemClientRef?
    private var dieSensors: [IOHIDServiceClientRef] = []

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    init() {
        if let smc {
            if TemperatureReader.chip.contains("M4") {
                coreKeys = TemperatureReader.m4CoreKeys.map(SMC.code).filter { smc.isFloat($0) && smc.float($0) != nil }
            } else {
                coreKeys = smc.allKeys().filter {
                    let n = SMC.name($0)
                    return (n.hasPrefix("Tp") || n.hasPrefix("Te")) && smc.isFloat($0)
                }
            }
        }
        guard coreKeys.isEmpty, let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
        let services = IOHIDEventSystemClientCopyServices(c) as? [IOHIDServiceClientRef] ?? []
        dieSensors = services.filter {
            (IOHIDServiceClientCopyProperty($0, "Product" as CFString) as? String)?.lowercased().contains("tdie") == true
        }
    }

    /// Hottest CPU core in °C, nil when no sensor is readable.
    func hottest() -> Double? {
        var best: Double? = nil
        if let smc, !coreKeys.isEmpty {
            for k in coreKeys { if let v = smc.float(k), v > 0 && v < 150 { best = max(best ?? 0, v) } }
            return best
        }
        for s in dieSensors {
            guard let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0) else { continue }
            let v = IOHIDEventGetFloatValue(e, 15 << 16)
            if v > 0 && v < 150 { best = max(best ?? 0, v) }
        }
        return best
    }

    /// `--debug-sensors`: prints the source in use, then every SMC temperature key and every IOHID
    /// temperature sensor with its current value, for comparing against other monitors.
    static func dump() {
        let reader = TemperatureReader()
        print("Chip: \(chip)")
        if let smc = reader.smc, !reader.coreKeys.isEmpty {
            let values = reader.coreKeys.map { "\(SMC.name($0)) \(smc.float($0).map { String(format: "%.1f", $0) } ?? "–")" }
            print("Source: SMC core keys (\(reader.coreKeys.count)): " + values.joined(separator: "  "))
        } else {
            print("Source: IOHID PMU tdie (\(reader.dieSensors.count) sensors)")
        }
        print("Hottest: \(reader.hottest().map { String(format: "%.1f °C", $0) } ?? "none")")
        if let smc = SMC() {
            print("\nSMC temperature keys:")
            for k in smc.allKeys() where SMC.name(k).hasPrefix("T") && smc.isFloat(k) {
                if let v = smc.float(k), v > 0 && v < 150 { print(String(format: "  %@ %6.1f", SMC.name(k), v)) }
            }
        }
        print("\nIOHID temperature sensors:")
        if let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) {
            _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            for s in IOHIDEventSystemClientCopyServices(c) as? [IOHIDServiceClientRef] ?? [] {
                let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString) as? String ?? "?"
                guard let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0) else { continue }
                let v = IOHIDEventGetFloatValue(e, 15 << 16)
                if v > 0 && v < 150 { print(String(format: "  %6.1f  %@", v, name)) }
            }
        }
    }
}

// MARK: - Processes
struct Proc { let pid: pid_t; let cpu: Double; let path: String; let frozen: Bool }

/// Finds the target app's processes and their CPU straight from the kernel (libproc), with no
/// pgrep/ps child processes every second. CPU is the share of one core (100 = one core busy) over
/// the time since the previous call, like the %CPU column of `top`.
final class ProcessSampler {
    private let marker: String
    private var pids = [pid_t](repeating: 0, count: 2048)
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    /// Executable path of each pid seen so far, nil when it is not a target process. Reading the
    /// path is the costly call, so it happens once per pid; the cache is dropped every `rescanEvery`
    /// calls to catch a process that exec'd into the target after it was first seen.
    private var known: [pid_t: String?] = [:]
    private var calls = 0
    private let rescanEvery = 60
    /// CPU time (mach ticks, like mach_absolute_time) of each target pid at the previous call.
    private var previous: [pid_t: (cpu: UInt64, at: UInt64)] = [:]

    init(marker: String) { self.marker = marker }

    func sample() -> [Proc] {
        var n = 0
        while true {
            let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
            n = Int(pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) })
            if n < pids.count { break }
            pids = [pid_t](repeating: 0, count: pids.count * 2)   // more processes than room: grow and retry
        }
        calls += 1
        if calls % rescanEvery == 0 { known.removeAll(keepingCapacity: true) }
        let now = mach_absolute_time()
        var alive = Set<pid_t>(minimumCapacity: max(0, n))
        var seen: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
        var result: [Proc] = []
        for i in 0..<max(0, n) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            alive.insert(pid)
            let path: String
            if let cached = known[pid] {
                guard let p = cached else { continue }
                path = p
            } else {
                guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }   // gone, or not readable
                let p = String(cString: pathBuffer)
                let match = p.contains(marker)
                known[pid] = .some(match ? p : nil)   // .some(nil) remembers "not a target"; a bare nil would delete the key
                guard match else { continue }
                path = p
            }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }
            let cpuTicks = task.pti_total_user + task.pti_total_system
            var cpu = 0.0
            if let p = previous[pid], now > p.at, cpuTicks >= p.cpu {
                cpu = Double(cpuTicks - p.cpu) / Double(now - p.at) * 100
            }
            seen[pid] = (cpuTicks, now)
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let frozen = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize && bsd.pbi_status == UInt32(SSTOP)
            result.append(Proc(pid: pid, cpu: cpu, path: path, frozen: frozen))
        }
        previous = seen
        if known.count > alive.count + 64 { known = known.filter { alive.contains($0.key) } }
        return result
    }
}

/// GPU use of the whole Mac, the "Device Utilization %" the graphics driver publishes in the IORegistry
/// (the value Stats shows). No entitlement needed; a read costs about 27 µs. It is a system figure, not
/// HandBrake's: with a software encode it stays at the desktop's own 10–15%, with HandBrake's VideoToolbox
/// filters (which run on the GPU) it climbs to about 80%. The media engine that encodes with VideoToolbox
/// has no readable counter without root.
final class GPUReader {
    private var service: io_service_t = 0
    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        if service != 0 && read() == nil { IOObjectRelease(service); service = 0 }
    }
    deinit { if service != 0 { IOObjectRelease(service) } }
    /// False on a Mac whose graphics driver publishes no utilization: the GPU is then left out everywhere.
    var available: Bool { service != 0 }
    /// Percent of the GPU in use right now, 0–100, or nil when the driver gives no figure.
    func read() -> Double? {
        guard service != 0,
              let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let n = stats["Device Utilization %"] as? NSNumber else { return nil }
        return min(100, max(0, n.doubleValue))
    }
}

// MARK: - CPU, GPU & temperature chart
struct Sample {
    /// Where the sample sits on the chart: the wall clock, minus the idle stretches cut out while
    /// "Hold the chart while idle" is on, so the line carries on where it stopped.
    let t: TimeInterval
    let cpu: Double; let temp: Double?; let resting: Bool
    /// GPU use of the whole Mac in percent; nil where it was not read.
    let gpu: Double?
    /// The real time of the sample, shown on the axis and under the pointer.
    let clock: TimeInterval
    /// First sample after such a cut: the line breaks here and a hairline marks the seam.
    let cut: Bool
    init(t: TimeInterval, cpu: Double, temp: Double?, resting: Bool, clock: TimeInterval? = nil, cut: Bool = false, gpu: Double? = nil) {
        self.t = t; self.cpu = cpu; self.temp = temp; self.resting = resting; self.clock = clock ?? t; self.cut = cut; self.gpu = gpu
    }
}

final class ChartView: NSView, HandCursorView {
    var samples: [Sample] = []
    var cpuMax: Double = 100          // y scale for the CPU line (grows with observed load)
    let minWindow: TimeInterval = 5 * 60
    let maxWindow: TimeInterval = 6 * 3600
    let headerRow = ClickableRow()
    let chevron = NSImageView()
    let header = NSTextField(labelWithString: "CPU & temperature")
    /// A third lane for the GPU, between CPU and temperature; off where the Mac gives no GPU figure.
    var showsGPU = false {
        didSet {
            guard showsGPU != oldValue else { return }
            if heightConstraint != nil && !collapsed { heightConstraint.constant = fullHeight }
            needsDisplay = true
        }
    }
    var title: String { showsGPU ? "CPU, GPU & temperature" : "CPU & temperature" }
    /// Plain text (a disabled button would be drawn faded on the popover's translucent background).
    let legend = NSTextField(labelWithString: "")
    /// Shown only while the view is zoomed or panned: back to the automatic view.
    let resetButton = HoverIconButton(symbol: "arrow.counterclockwise", pointSize: 10, label: "Back to the automatic view")
    private var legendTrailing: NSLayoutConstraint!
    var onToggle: (() -> Void)?
    /// Manual zoom span (nil = automatic window). Pinch or scroll over the plot sets it; "Reset" clears it.
    /// Custom view set by zoom or pan: left edge and width. nil = automatic view.
    var view: (start: TimeInterval, span: TimeInterval)? { didSet { needsDisplay = true } }
    /// With a custom view: the right edge tracks the newest sample (or, while the data is
    /// narrower than the view, the left edge stays on the first sample).
    var followNow = true
    var isCustomView: Bool { view != nil }
    var collapsed = false { didSet { chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: collapsed ? "Expand chart" : "Collapse chart"); needsDisplay = true; if legendTrailing != nil { showReset(isCustomView, animated: false) } } }

    init() {
        super.init(frame: .zero)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        // fixed width, the wider of the two (down 13 pt, right 9 pt): the title must not shift when toggling
        chevron.widthAnchor.constraint(equalToConstant: 13).isActive = true
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        legend.setContentHuggingPriority(.required, for: .horizontal)
        resetButton.target = self; resetButton.action = #selector(resetZoom)
        resetButton.alphaValue = 0; resetButton.isHidden = true
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
        for v in [headerRow, legend, resetButton] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        legendTrailing = legend.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor), titleRow.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            titleRow.topAnchor.constraint(equalTo: headerRow.topAnchor), titleRow.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor), headerRow.topAnchor.constraint(equalTo: topAnchor),
            legendTrailing, legend.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor), resetButton.centerYAnchor.constraint(equalTo: legend.centerYAnchor, constant: 0.75),   // on the centre of the digits, measured
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
    /// The pointer's x over the plot, for the magnetic dotted lines.
    var hoverX: CGFloat?
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x
        hoveredArrow = leftArrowRect.contains(p) ? -1 : rightArrowRect.contains(p) ? 1 : 0
        guard !collapsed, let g = geom, let last = samples.last else { hoverT = nil; return }
        guard p.x >= g.left - 4, p.x <= g.right + 4, p.y >= g.bottom, p.y <= g.top else { hoverT = nil; return }
        guard let t = time(atX: p.x) else { return }
        hoverT = min(t, min(last.t, range.end))
    }
    override func mouseExited(with event: NSEvent) { hoverT = nil; hoverX = nil; hoveredArrow = 0 }

    /// Smooth lines when the chart holds more samples than pixels (straight segments when zoomed in).
    var smoothCurves = true
    static func polyline(_ pts: [NSPoint]) -> NSBezierPath {
        let p = NSBezierPath(); p.lineWidth = 1.5; p.lineJoinStyle = .round
        for (i, pt) in pts.enumerated() { if i == 0 { p.move(to: pt) } else { p.line(to: pt) } }
        return p
    }
    /// Monotone cubic through the points (Fritsch–Carlson): round, yet never above or below its
    /// neighbours, so a curve can't overshoot the lane or invent a peak the data doesn't have.
    static func monotoneCurve(_ pts: [NSPoint]) -> NSBezierPath {
        guard pts.count > 2 else { return polyline(pts) }
        let n = pts.count
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<n - 1 { d[i] = (pts[i + 1].y - pts[i].y) / max(0.0001, pts[i + 1].x - pts[i].x) }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<n - 1 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<n - 1 {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        let p = NSBezierPath(); p.lineWidth = 1.5; p.lineJoinStyle = .round
        p.move(to: pts[0])
        for i in 0..<n - 1 {
            let h = (pts[i + 1].x - pts[i].x) / 3
            p.curve(to: pts[i + 1], controlPoint1: NSPoint(x: pts[i].x + h, y: pts[i].y + m[i] * h),
                    controlPoint2: NSPoint(x: pts[i + 1].x - h, y: pts[i + 1].y - m[i + 1] * h))
        }
        return p
    }

    /// Longer than this between two samples (one every 5 s) is a gap, not a slope.
    static let gapSeconds: TimeInterval = 30
    /// Idle time cut out of the chart is marked by a strip this wide: a dotted line, 6 pt of empty
    /// space, a dotted line. The lines before and after it end right on the dotted lines.
    static let seamStrip: CGFloat = 8
    /// How many samples at the end were recorded after the encoder last worked (`lastBusy`, wall clock).
    /// When the chart starts holding they go: the cycle keeps counting HandBrake as working for `idleGrace`
    /// seconds (a gap between queue items), and after a rest it was frozen, so without this the break would
    /// sit 10 s of flat line after the real stop. The first sample after the stop stays: it carries the drop,
    /// or the end of the rest band.
    static func idleTail(_ samples: [Sample], lastBusy: TimeInterval) -> Int {
        guard let k = samples.lastIndex(where: { $0.clock <= lastBusy }) else { return 0 }
        return max(0, samples.count - (k + 2))
    }
    /// Set while "Hold the chart while idle" holds an idle stretch long enough to be cut out.
    var holding = false { didSet { if holding != oldValue { needsDisplay = true } } }
    /// The strips drawn last: the time of the first sample after each cut and the strip's left edge.
    private var strips: [(cut: TimeInterval, x0: CGFloat)] = []
    /// The time under a point of the plot, stepping over the strips (inside one: the sample after the cut).
    func time(atX px: CGFloat) -> TimeInterval? {
        guard let g = geom else { return nil }
        let p = min(max(px, g.left), g.right)
        var shift: CGFloat = 0
        for s in strips {
            if p >= s.x0 + ChartView.seamStrip { shift += ChartView.seamStrip } else if p >= s.x0 { return s.cut }
        }
        let dataW = (g.right - g.left) - CGFloat(strips.count) * ChartView.seamStrip
        return g.start + Double((p - g.left - shift) / max(1, dataW)) * g.span
    }

    /// Magnetic edges: near the edge of a rest band, or a dotted line of a break, the hover line sticks to it.
    var magneticBands = true
    static let magnetPixels: Double = 6
    /// Within `magnetPixels` of a change between work and rest, the sample the hover should show:
    /// always the last one before the change. At the start of a rest that is the encoder's CPU and
    /// temperature as the pause begins; at its end, the temperature the rest reached before work resumes.
    /// A band edge is drawn at the first sample of the new state: that is `edge`, where the hover line goes.
    static func magnet(_ samples: [Sample], at t: TimeInterval, secondsPerPixel: Double) -> (sample: Sample, edge: TimeInterval)? {
        guard samples.count > 1, secondsPerPixel > 0 else { return nil }
        var best: (px: Double, sample: Sample, edge: TimeInterval)? = nil
        for i in 1..<samples.count where samples[i].resting != samples[i - 1].resting {
            let px = abs(samples[i].t - t) / secondsPerPixel
            if px <= magnetPixels && px < (best?.px ?? .infinity) { best = (px, samples[i - 1], samples[i].t) }
        }
        return best.map { ($0.sample, $0.edge) }
    }

    func visibleSamples(_ a: TimeInterval, _ b: TimeInterval) -> [Sample] { samples.filter { $0.t >= a && $0.t <= b } }
    /// The real time at a point of the chart: the clock of the sample at or before it, plus the distance from it.
    func clock(at t: TimeInterval) -> TimeInterval {
        guard let first = samples.first else { return t }
        var lo = 0, hi = samples.count - 1
        if t <= first.t { return first.clock + (t - first.t) }
        while lo < hi { let mid = (lo + hi + 1) / 2; if samples[mid].t <= t { lo = mid } else { hi = mid - 1 } }
        return samples[lo].clock + (t - samples[lo].t)
    }
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
    private func markCustom() { showReset(true) }
    /// Fades the reset icon in or out, sliding the legend to make room for it.
    func showReset(_ show: Bool, animated: Bool = true) {
        let visible = show && !collapsed
        guard visible != !resetButton.isHidden || (visible && resetButton.alphaValue < 1) else { return }
        let room = resetButton.intrinsicContentSize.width + 5
        if visible { resetButton.isHidden = false }
        guard animated else {
            legendTrailing.constant = visible ? -room : 0
            resetButton.alphaValue = visible ? 1 : 0
            resetButton.isHidden = !visible
            window?.invalidateCursorRects(for: resetButton)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            legendTrailing.animator().constant = visible ? -room : 0
            resetButton.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self = self, !visible, self.resetButton.alphaValue == 0 else { return }
            self.resetButton.isHidden = true
            self.window?.invalidateCursorRects(for: self.resetButton)
        })
        window?.invalidateCursorRects(for: resetButton)
    }

    @objc func resetZoom() {
        guard let first = samples.first?.t, let last = samples.last?.t else { return }
        let autoSpan = last - first >= maxWindow ? maxWindow : max(minWindow, last - first)
        let autoStart = last - first >= maxWindow ? last - maxWindow : first
        animateView(toStart: autoStart, toSpan: autoSpan) { [weak self] in
            self?.view = nil; self?.followNow = true
            self?.showReset(false)
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
    func wantsHandCursor(at point: NSPoint) -> Bool { leftArrowRect.contains(point) || rightArrowRect.contains(point) }
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
        // back at the automatic view: drop the custom view, and with it the reset icon
        if abs(next - autoWidth) < 0.5 && tracksNow(start: newStart, span: next) {
            view = nil; followNow = true
            showReset(false)
            return
        }
        view = (newStart, next)
        followNow = tracksNow(start: newStart, span: next)
        markCustom()
    }
    private func timeAt(_ event: NSEvent) -> TimeInterval? {
        time(atX: convert(event.locationInWindow, from: nil).x)
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
    /// With the GPU the lanes go from 38 to 34 pt and the gaps from 14 to 12, and the chart grows by 36 pt.
    var fullHeight: CGFloat { showsGPU ? 176 : 140 }
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

    /// Width of the visible window in words: "6 minutes", "45 minutes", "1.5 hours", "6 hours".
    static func spanLabel(_ w: TimeInterval) -> String {
        if w < 90 * 60 {
            let m = max(1, Int((w / 60).rounded()))
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        let h = (w / 1800).rounded() / 2                       // to the half hour
        return h == h.rounded() ? "\(Int(h)) hour\(h == 1 ? "" : "s")" : String(format: "%.1f hours", h)
    }

    /// Series colours: the system ones in light appearance, lifted a little on the dark panel.
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var tempColor: NSColor { isDark ? NSColor.systemOrange.blended(withFraction: 0.15, of: .white) ?? .systemOrange : .systemOrange }
    var cpuColor: NSColor { panelBlue(for: self) }
    /// The system green, darkened a little on the light panel and lifted a little on the dark one, like the others.
    var gpuColor: NSColor {
        isDark ? NSColor.systemGreen.blended(withFraction: 0.1, of: .white) ?? .systemGreen
               : NSColor.systemGreen.blended(withFraction: 0.12, of: .black) ?? .systemGreen
    }

    /// Folded with the GPU, the readings take the title's place, at the title's 13 pt: the title and three
    /// readings do not fit side by side in the popover, and each reading carries its own name anyway.
    private func headerText() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        guard collapsed && showsGPU else { return NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor]) }
        let last = samples.last
        let a = NSMutableAttributedString()
        func part(_ label: String, _ value: String) {
            a.append(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            a.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        }
        func dot() { a.append(NSAttributedString(string: "   ·   ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])) }
        part("CPU ", last.map { "\(Int($0.cpu))%" } ?? "–"); dot()
        part("GPU ", last?.gpu.map { "\(Int($0.rounded()))%" } ?? "n/a"); dot()
        part("Temp ", last?.temp.map { "\(Int($0.rounded()))°C" } ?? "n/a")
        return a
    }
    /// Legend text: the live values while the plot is folded away, otherwise the rest key and the view's width.
    private func legendText() -> NSAttributedString {
        if collapsed && showsGPU { return NSAttributedString(string: "") }   // the readings are in the header
        if collapsed {
            let last = samples.last
            let a = NSMutableAttributedString()
            func part(_ label: String, _ value: String, _ color: NSColor) {
                a.append(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                a.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]))
            }
            part("CPU ", last.map { "\(Int($0.cpu))%" } ?? "–", .labelColor)
            a.append(NSAttributedString(string: "   ·   ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            part("Temp ", last?.temp.map { "\(Int($0.rounded()))°C" } ?? "n/a", .labelColor)
            return a
        }
        let a = NSMutableAttributedString(string: "■ Rest    ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        // a translucent grey glyph vanishes in light mode inside the live text field (popover and window
        // alike, not in offscreen renders): a solid grey there, the translucent one on the dark panel
        let swatch = isDark ? NSColor.labelColor.withAlphaComponent(0.18) : NSColor(white: 0.74, alpha: 1)
        a.addAttribute(.foregroundColor, value: swatch, range: NSRange(location: 0, length: 1))
        let (s0, e0) = range
        a.append(NSAttributedString(string: ChartView.spanLabel(e0 - s0), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return a
    }
    /// The legend is refreshed just before each redraw, the moment AppKit allows layout changes:
    /// set from inside draw() its new width would only be picked up by a later layout pass.
    override func viewWillDraw() {
        let head = headerText()
        if !header.attributedStringValue.isEqual(to: head) {
            header.attributedStringValue = head
            header.invalidateIntrinsicContentSize()
            layoutSubtreeIfNeeded()
        }
        let text = legendText()
        if !legend.attributedStringValue.isEqual(to: text) {
            legend.attributedStringValue = text
            legend.invalidateIntrinsicContentSize()
            layoutSubtreeIfNeeded()
        }
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        if collapsed { return }   // the legend alone carries the live values
        guard let last = samples.last else { return }
        let plotLeft: CGFloat = 46, plotRight = bounds.width - 48, top = bounds.height - 30, axisH: CGFloat = 20
        let plotW = plotRight - plotLeft
        let plotsTop = top, plotsBottom = axisH
        let lanes: CGFloat = showsGPU ? 3 : 2
        let gap: CGFloat = showsGPU ? 12 : 14
        let laneH = (plotsTop - plotsBottom - gap * (lanes - 1)) / lanes
        let cpuLane = NSRect(x: plotLeft, y: plotsBottom + (laneH + gap) * (lanes - 1), width: plotW, height: laneH)
        let gpuLane = NSRect(x: plotLeft, y: plotsBottom + laneH + gap, width: plotW, height: laneH)
        let tempLane = NSRect(x: plotLeft, y: plotsBottom, width: plotW, height: laneH)
        let (tStart, tEnd) = range
        let w = tEnd - tStart
        geom = (plotLeft, plotRight, tStart, w, plotsBottom, plotsTop)
        // where idle time was cut out, an empty strip is inserted between the samples either side:
        // everything after it moves right by the strip's width, so the strip never covers any data
        var cuts = samples.filter { $0.cut && $0.t > tStart && $0.t <= tEnd }.map { $0.t }
        // held right now: the strip of the stretch being cut out already stands after the last sample,
        // where it will stay when work comes back (nothing moves then)
        let pending = holding && last.t >= tStart && last.t <= tEnd + 0.5
        if pending { cuts.append(last.t + 0.001) }
        let strip = ChartView.seamStrip
        let dataW = plotW - CGFloat(cuts.count) * strip
        func x(_ t: TimeInterval) -> CGFloat {
            plotLeft + CGFloat((t - tStart) / w) * dataW + strip * CGFloat(cuts.filter { $0 <= t }.count)
        }
        // on the half point: whole device pixels at 2x, so the dots stay sharp, and never left of the line's end
        strips = cuts.enumerated().map { k, c in (c, ((plotLeft + CGFloat((c - tStart) / w) * dataW + strip * CGFloat(k)) * 2).rounded(.up) / 2) }
        // the sample under the cursor, if any: it takes over the right-hand values and the axis
        // (with magnetic bands, near a band edge: the last sample before the change, the line on the edge)
        // with magnetic edges, the dotted lines of a break pull the pointer too (they are places on the screen,
        // not times): the left one shows the last sample before the break, where work stopped; the right one
        // the first sample after it, where work resumed (before it there is only the stretch cut out)
        var seamX: CGFloat? = nil
        var seamHover: (sample: Sample, t: TimeInterval)? = nil
        if magneticBands, let px = hoverX, hoverT != nil {
            var best = CGFloat(ChartView.magnetPixels) + 0.01
            for s in strips {
                for (lx, smp) in [(s.x0 + 0.5, samples.last { $0.t < s.cut }), (s.x0 + strip - 0.5, samples.first { $0.t >= s.cut })] {
                    if let smp, abs(px - lx) < best { best = abs(px - lx); seamX = lx; seamHover = (smp, smp.t) }
                }
            }
        }
        let hover: (sample: Sample, t: TimeInterval)? = seamHover ?? hoverT.flatMap { ht in
            let near = visibleSamples(tStart, tEnd)
            if magneticBands, let snap = ChartView.magnet(near, at: ht, secondsPerPixel: w / Double(dataW)) { return (snap.sample, snap.edge) }
            return near.min { abs($0.t - ht) < abs($1.t - ht) }.flatMap { abs($0.t - ht) < 30 ? ($0, $0.t) : nil }
        }
        let hovered = hover?.sample

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: plotLeft, y: plotsBottom, width: plotW, height: plotsTop - plotsBottom)).addClip()
        // the strips get the axis-break sign: two dotted lines with nothing drawn between them,
        // not even the divider and the baseline
        if !strips.isEmpty {
            let clip = NSBezierPath(rect: NSRect(x: plotLeft - 1, y: 0, width: plotW + 2, height: bounds.height))
            for s in strips { clip.appendRect(NSRect(x: s.x0, y: plotsBottom - 1, width: strip, height: plotsTop - plotsBottom + 2)) }
            clip.windingRule = .evenOdd
            clip.addClip()
        }
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
        for y in (showsGPU ? [cpuLane.minY - gap / 2, gpuLane.minY - gap / 2, tempLane.minY] : [cpuLane.minY - gap / 2, tempLane.minY]) {
            let b = NSBezierPath(); b.move(to: NSPoint(x: plotLeft, y: y)); b.line(to: NSPoint(x: plotRight, y: y)); b.lineWidth = 1; b.stroke()
        }
        // lines: zoomed in, straight segments between the real samples; with more samples than pixels,
        // the means of buckets a few pixels wide joined by a smooth curve
        let visible = samples.filter { $0.t >= tStart && $0.t <= tEnd }
        let density = Double(visible.count) / Double(plotW)          // samples per pixel
        let smooth = smoothCurves && density > 1
        let bucketPx = smooth ? min(4, max(1, density.rounded())) : 1
        // buckets are anchored in time, not on the screen, so they hold still while the view scrolls; a bucket
        // never spans a change between work and rest, so even a short rest keeps its dip when zoomed far out
        let bucketSeconds = bucketPx * w / Double(plotW)
        // a gap in the data (the chart held still while idle, the Mac asleep) breaks the line: nothing is drawn across it
        func path(_ value: (Sample) -> Double?, lane: NSRect, maxV: Double, minV: Double) -> NSBezierPath {
            var runs: [[NSPoint]] = [[]]
            var bucket = Int.min, resting = false, accV = 0.0, accX = 0.0, n = 0
            var lastT: TimeInterval?
            func flush() {
                guard n > 0 else { return }
                let py = lane.minY + CGFloat((accV / Double(n) - minV) / max(1, maxV - minV)) * lane.height
                runs[runs.count - 1].append(NSPoint(x: CGFloat(accX / Double(n)), y: min(lane.maxY, max(lane.minY, py))))
            }
            for smp in visible {
                guard let v = value(smp) else { continue }
                let k = Int(floor(smp.t / bucketSeconds))
                let gap = (lastT.map { smp.t - $0 > ChartView.gapSeconds } ?? false) || (smp.cut && lastT != nil)
                if k != bucket || smp.resting != resting || gap {
                    flush(); bucket = k; resting = smp.resting; accV = 0; accX = 0; n = 0
                    if gap { runs.append([]) }
                }
                accV += v; accX += Double(x(smp.t)); n += 1
                lastT = smp.t
            }
            flush()
            let out = NSBezierPath(); out.lineWidth = 1.5; out.lineJoinStyle = .round
            for run in runs where !run.isEmpty { out.append(smooth ? ChartView.monotoneCurve(run) : ChartView.polyline(run)) }
            return out
        }
        cpuColor.setStroke()
        path({ $0.cpu }, lane: cpuLane, maxV: cpuMax, minV: 0).stroke()
        if showsGPU {
            gpuColor.setStroke()
            path({ $0.gpu }, lane: gpuLane, maxV: 100, minV: 0).stroke()
        }
        let temps = visible.compactMap { $0.temp }
        let tMin = floor(((temps.min() ?? 30) - 5) / 10) * 10, tMax = ceil(((temps.max() ?? 80) + 5) / 10) * 10
        tempColor.setStroke()
        path({ $0.temp }, lane: tempLane, maxV: tMax, minV: tMin).stroke()
        NSGraphicsContext.restoreGraphicsState()
        // dotted, not dashed: the "Now" line is the dashed one
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        for s in strips {
            for lx in [s.x0 + 0.5, s.x0 + strip - 0.5] {
                let l = NSBezierPath(); l.move(to: NSPoint(x: lx, y: plotsBottom)); l.line(to: NSPoint(x: lx, y: plotsTop))
                l.lineWidth = 1; l.setLineDash([1, 2], count: 2, phase: 0); l.stroke()
            }
        }
        // now line + end dots
        let nowVisible = last.t <= tEnd + 0.5
        // while held the last sample is not "now": no now line, no end dots, its time instead of "Now"
        let live = nowVisible && !pending
        let nx = x(last.t)
        if live {
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
        if live {
            dot(last.cpu, lane: cpuLane, maxV: cpuMax, minV: 0, cpuColor)
            if showsGPU, let g = last.gpu { dot(g, lane: gpuLane, maxV: 100, minV: 0, gpuColor) }
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
        if showsGPU {
            text("GPU", NSPoint(x: 0, y: gpuLane.midY), gpuColor, .semibold)
            text(shown.gpu.map { "\(Int($0.rounded()))%" } ?? "n/a", NSPoint(x: bounds.width, y: gpuLane.midY), gpuColor, .semibold, right: true)
        }
        text(shown.temp.map { "\(Int($0.rounded()))°C" } ?? "n/a", NSPoint(x: bounds.width, y: tempLane.midY), tempColor, .semibold, right: true)
        // hover cursor: solid line and dots at the hovered sample
        if let hv = hovered, let hoverAt = hover?.t {
            let hx = seamX ?? x(hoverAt)
            let line = NSBezierPath(); line.move(to: NSPoint(x: hx, y: plotsBottom)); line.line(to: NSPoint(x: hx, y: plotsTop))
            line.lineWidth = 1; NSColor.labelColor.withAlphaComponent(0.6).setStroke(); line.stroke()
            func hdot(_ v: Double, lane: NSRect, maxV: Double, minV: Double, _ color: NSColor) {
                let py = lane.minY + CGFloat((v - minV) / max(1, maxV - minV)) * lane.height
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: hx - 3, y: min(lane.maxY, max(lane.minY, py)) - 3, width: 6, height: 6)).fill()
            }
            hdot(hv.cpu, lane: cpuLane, maxV: cpuMax, minV: 0, cpuColor)
            if showsGPU, let g = hv.gpu { hdot(g, lane: gpuLane, maxV: 100, minV: 0, gpuColor) }
            if let t = hv.temp { hdot(t, lane: tempLane, maxV: tMax, minV: tMin, tempColor) }
        }
        // time axis: the start time flush left, "Now" at the right, the others spread evenly in between
        let labelCount = min(bounds.width > 420 ? 6 : 4, max(2, Int(w / 60)))   // never closer than a minute
        let f = DateFormatter(); f.dateFormat = w < 120 ? "HH:mm:ss" : "HH:mm"
        let hx: CGFloat? = hover.map { seamX ?? x($0.t) }
        // the right-hand label ("Now", or the time at the right edge) is drawn right aligned 14 pt past its anchor
        let rightText = live ? "Now" : f.string(from: Date(timeIntervalSinceReferenceDate: pending ? last.clock : clock(at: tEnd)))
        let rightLeftEdge = (nowVisible ? nx : plotRight) + 14
            - NSAttributedString(string: rightText, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).size().width
        var previous = ""
        for i in 0..<labelCount {
            let t = tStart + w * Double(i) / Double(labelCount)          // spread over the visible window
            let tx = x(t)
            let label = f.string(from: Date(timeIntervalSinceReferenceDate: clock(at: t)))
            let lw = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).size().width
            let lx = i == 0 ? plotLeft : tx - lw / 2
            let clearOfHover = hx.map { abs($0 - (lx + lw / 2)) > lw + 6 } ?? true
            guard t <= last.t, rightLeftEdge - (lx + lw) > 8, clearOfHover, label != previous else { continue }
            previous = label
            text(label, NSPoint(x: lx, y: 7), .secondaryLabelColor)
        }
        if let hoverAt = hover?.t, let hx = hx {
            let label = f.string(from: Date(timeIntervalSinceReferenceDate: clock(at: hoverAt)))
            let lw = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).size().width
            let lx = min(max(hx - lw / 2, 0), bounds.width - lw)   // centred on the line, kept inside the view
            text(label, NSPoint(x: lx, y: 7), .labelColor, .semibold)
            if (nowVisible ? nx : plotRight) - hx > 50 { rightLabel() }
        } else {
            rightLabel()
        }
        func rightLabel() {
            text(rightText, NSPoint(x: (nowVisible ? nx : plotRight) + 14, y: 7), .secondaryLabelColor, .medium, right: true)
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
    /// Light mode only: over a dark window the popover's translucency turns mid grey and the coloured
    /// text (temperature, CPU, update chip) loses its contrast. A near-opaque fill in the window colour
    /// makes the popover read like the detached window; dark mode keeps the plain translucency.
    static let lightFill: CGFloat = 0.88
    override func draw(_ dirtyRect: NSRect) {
        guard effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(BackgroundView.lightFill).setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
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
final class ClickableRow: NSView, HandCursorView {
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
    func wantsHandCursor(at point: NSPoint) -> Bool { true }
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
        clear.text = "Clear"
        // grey like the event count beside it, almost black (white on the dark panel) under the pointer
        clear.hoverColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : NSColor(white: 0.08, alpha: 1) }
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
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: LogBoxView.listHeight)
        scrollHeight.isActive = true
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
        reveal = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    private var separator: NSBox!
    private var scrollHeight: NSLayoutConstraint!
    static let listHeight: CGFloat = 120
    @objc func clearTapped() { onClear?() }

    /// Open or closed: the chevron. How much of the list shows is `reveal`, so it can be animated.
    var expanded = false {
        didSet {
            chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                    accessibilityDescription: expanded ? "Collapse activity log" : "Expand activity log")
        }
    }
    /// 0 = closed, 1 = fully open; in between the list grows from the header and fades in.
    var reveal: CGFloat = 1 {
        didSet {
            scrollHeight.constant = LogBoxView.listHeight * reveal
            scroll.alphaValue = reveal
            scroll.isHidden = reveal == 0
            separator.isHidden = reveal == 0
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
final class StyledCheckbox: NSView, HandCursorView {
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
    func wantsHandCursor(at point: NSPoint) -> Bool { true }
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
// MARK: - Pointing hand
// AppKit's cursor rects only work in the key window of the active app. Siesta's panel is often on
// screen without being either: the detached window floats over other apps, and the popover can open
// without Siesta becoming active. The tracker follows the mouse over the whole panel all the same and
// shows the pointing hand over every view that asks for it; the cursor rects stay for the active case.
protocol HandCursorView: AnyObject {
    /// `point` is in the view's own coordinates.
    func wantsHandCursor(at point: NSPoint) -> Bool
}

// An app that is not frontmost cannot change the cursor unless its window-server connection allows
// it: the same private switch menu bar utilities use. Without it the hand silently stays an arrow.
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty") private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

final class HandCursorTracker: NSResponder {
    private weak var root: NSView?
    private var showingHand = false
    private let debug = CommandLine.arguments.contains("--debug-cursor")
    func attach(to view: NSView) {
        let cid = _CGSDefaultConnection()
        let result = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if debug { print("SetsCursorInBackground → \(result)"); fflush(stdout) }
        root = view
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { update(event) }
    override func mouseMoved(with event: NSEvent) { update(event) }
    override func mouseExited(with event: NSEvent) { if showingHand { NSCursor.arrow.set(); showingHand = false } }
    private func update(_ event: NSEvent) {
        guard let root = root, root.window != nil, event.window === root.window else { return }
        let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        var want = false
        for view in sequence(first: hit, next: { $0?.superview }) {
            guard let view = view else { break }
            if let target = view as? HandCursorView { want = target.wantsHandCursor(at: view.convert(event.locationInWindow, from: nil)); break }
            if view === root { break }
        }
        if debug && want != showingHand { print("\(want ? "hand" : "arrow") · app active: \(NSApp.isActive)"); fflush(stdout) }
        if want { NSCursor.pointingHand.set(); showingHand = true }
        else if showingHand { NSCursor.arrow.set(); showingHand = false }   // only undo our own hand, never an I-beam
    }
}

/// Small underlined text link: secondary colour at rest, full label colour under the pointer, hand cursor.
final class LinkButton: NSButton, HandCursorView {
    var text = "" { didSet { restyle() } }
    var restColor: NSColor = .secondaryLabelColor { didSet { restyle() } }
    var hoverColor: NSColor = .labelColor { didSet { restyle() } }
    private var hovered = false { didSet { restyle() } }
    private func restyle() {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: hovered && isEnabled ? hoverColor : restColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func viewDidHide() { super.viewDidHide(); hovered = false }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    func wantsHandCursor(at point: NSPoint) -> Bool { isEnabled && !isHidden }
}

/// Small symbol button: secondary colour at rest, full label colour under the pointer, hand cursor.
final class HoverIconButton: NSButton, HandCursorView {
    var restColor: NSColor = .secondaryLabelColor { didSet { if !hovered { contentTintColor = restColor } } }
    var hovered = false { didSet { contentTintColor = hovered ? .labelColor : restColor } }
    init(symbol: String, pointSize: CGFloat, label: String, weight: NSFont.Weight = .semibold) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        isBordered = false; imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        toolTip = label
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    func wantsHandCursor(at point: NSPoint) -> Bool { isEnabled && !isHidden && alphaValue > 0 }
    // clicked away with its page (the gear opens the settings): no mouseExited comes, so forget the hover
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hovered = false } }
}

/// Pill shown above the status only while a new version is available: accent tint, hand cursor,
/// fuller fill under the pointer. While updating it greys out and ignores clicks.
final class UpdateChip: NSView, HandCursorView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var busy = false { didSet { restyle() } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        icon.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue) }
    }
    /// Yellow so it stands out from the grey and blue panel: yellow text on a yellow tint in dark mode,
    /// a yellow pill (75 %, full on hover) with near-black text in light mode, where yellow text would be unreadable.
    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static let tint = NSColor(name: nil) { isDark($0) ? .systemYellow : NSColor(white: 0.1, alpha: 1) }
    private func restyle() {
        let tint: NSColor = busy ? .secondaryLabelColor : UpdateChip.tint
        label.textColor = tint; icon.contentTintColor = tint
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let level = pressed ? 2 : hovered ? 1 : 0
        let fill: NSColor
        if busy { fill = NSColor.labelColor.withAlphaComponent(0.07) }
        else if UpdateChip.isDark(effectiveAppearance) { fill = NSColor.systemYellow.withAlphaComponent([0.16, 0.26, 0.34][level]) }
        else {   // light: yellow at 75 %, full under the pointer, a touch darker while pressed
            fill = level == 2 ? (NSColor.systemYellow.blended(withFraction: 0.08, of: .black) ?? .systemYellow)
                : NSColor.systemYellow.withAlphaComponent(level == 1 ? 1 : 0.75)
        }
        easeLayerColor(layer, "backgroundColor", to: fill.cgColor)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if !busy { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { if !busy { onClick?() }; return true }
    override func resetCursorRects() { if !busy { addCursorRect(bounds, cursor: .pointingHand) } }
    func wantsHandCursor(at point: NSPoint) -> Bool { !busy && !isHidden }
}

/// Flat button in the prototype style: rounded 8 pt, thin border, generous padding.
/// Primary = accent fill with white text; secondary = subtle fill with label text.
final class FlatButton: NSButton, HandCursorView {
    let primary: Bool
    var hoverFill: NSColor?          // e.g. red for a destructive action
    /// Smaller secondary button for a row of the settings page: 24 pt tall, 6 pt corners.
    var compact = false { didSet { layer?.cornerRadius = compact ? 6 : 8; invalidateIntrinsicContentSize() } }
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
        if compact { return NSSize(width: s.width + 18, height: 24) }
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
    func wantsHandCursor(at point: NSPoint) -> Bool { isEnabled }
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
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: compact ? 6 : 8, yRadius: compact ? 6 : 8).fill() }
}

// MARK: - Settings page controls
// Drawn in the panel's own style: labelColor 6 % fills, 16 % borders, the accent when on.

/// On/off switch, 30 × 18 pt: bordered grey track when off, accent when on; the knob glides over 0.15 s.
final class ToggleSwitch: NSView, HandCursorView {
    private(set) var isOn = false
    var onToggle: ((Bool) -> Void)?
    private var knob: CGFloat = 0 { didSet { needsDisplay = true } }   // 0 off … 1 on
    private var hovered = false { didSet { needsDisplay = true } }
    private var anim: Timer?
    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.checkBox); setAccessibilityLabel(label)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 18) }
    override var allowsVibrancy: Bool { false }
    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        setAccessibilityValue(on)
        anim?.invalidate()
        guard animated else { knob = on ? 1 : 0; return }
        let from = knob, to: CGFloat = on ? 1 : 0, start = Date()
        anim = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let p = min(1, Date().timeIntervalSince(start) / 0.15)
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            self?.knob = from + (to - from) * CGFloat(e)
            if p >= 1 { t.invalidate() }
        }
    }
    override func mouseDown(with event: NSEvent) { setOn(!isOn, animated: true); onToggle?(isOn) }
    override func accessibilityPerformPress() -> Bool { setOn(!isOn, animated: true); onToggle?(isOn); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    func wantsHandCursor(at point: NSPoint) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = NSRect(x: 0, y: (bounds.height - 18) / 2, width: 30, height: 18)
        let offFill = NSColor.labelColor.withAlphaComponent(hovered ? 0.11 : 0.06).usingColorSpace(.sRGB)!
        let accent = (hovered ? NSColor.controlAccentColor.blended(withFraction: 0.10, of: .white) ?? .controlAccentColor : .controlAccentColor).usingColorSpace(.sRGB)!
        // the off fill is translucent: draw it, then the accent over it at the knob's progress
        offFill.setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        accent.withAlphaComponent(knob).setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        if knob < 1 {
            NSColor.labelColor.withAlphaComponent(0.16 * (1 - knob)).setStroke()
            let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5); border.lineWidth = 1; border.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -0.5); shadow.shadowBlurRadius = 1.5
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
        // the knob: white when on and in light mode, a light grey while off on the dark panel
        let offKnob = dark ? NSColor(white: 0.81, alpha: 1) : .white
        (offKnob.blended(withFraction: knob, of: .white) ?? .white).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + 2 + 12 * knob, y: r.minY + 2, width: 14, height: 14)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Segmented choice (System / Light / Dark): a bordered track with the chosen segment raised.
final class SegmentedPicker: NSView, HandCursorView {
    let items: [String]
    private(set) var selected = 0
    var onChange: ((Int) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private let font = NSFont.systemFont(ofSize: 12), boldFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    init(items: [String], label: String) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel(label)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var allowsVibrancy: Bool { false }
    /// Each segment fits its widest weight, so the text never shifts when it becomes the chosen one.
    private var widths: [CGFloat] { items.map { ceil(NSAttributedString(string: $0, attributes: [.font: boldFont]).size().width) + 18 } }
    override var intrinsicContentSize: NSSize { NSSize(width: widths.reduce(0, +) + CGFloat(items.count - 1) + 2 * 2, height: 22) }
    private func segmentRects() -> [NSRect] {
        var x: CGFloat = 2, out: [NSRect] = []
        for w in widths { out.append(NSRect(x: x, y: 2, width: w, height: bounds.height - 4)); x += w + 1 }
        return out
    }
    func select(_ i: Int) { selected = i; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = segmentRects().firstIndex(where: { $0.contains(p) }), i != selected else { return }
        selected = i; needsDisplay = true; onChange?(i)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { let p = convert(event.locationInWindow, from: nil); hovered = segmentRects().firstIndex { $0.contains(p) } }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    func wantsHandCursor(at point: NSPoint) -> Bool { segmentRects().firstIndex { $0.contains(point) }.map { $0 != selected } ?? false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        NSColor.labelColor.withAlphaComponent(0.06).setFill(); track.fill()
        NSColor.labelColor.withAlphaComponent(0.16).setStroke(); track.lineWidth = 1; track.stroke()
        for (i, r) in segmentRects().enumerated() {
            let seg = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            if i == selected {
                // the chosen segment in the accent colour, like the menu bar chips: a grey one was lost
                // on the popover's translucent material in dark mode
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -0.5); shadow.shadowBlurRadius = 1.5
                shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.3 : 0.18); shadow.set()
                NSColor.controlAccentColor.setFill(); seg.fill()
                NSGraphicsContext.restoreGraphicsState()
            } else if i == hovered {
                NSColor.labelColor.withAlphaComponent(0.05).setFill(); seg.fill()
            }
            let color: NSColor = i == selected ? .white : .labelColor
            let text = NSAttributedString(string: items[i], attributes: [.font: i == selected ? boldFont : font, .foregroundColor: color])
            let size = text.size()
            text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
    }
}

/// Pill that switches one item on or off (what the menu bar shows): accent with white text when on.
final class ChipToggle: NSView, HandCursorView {
    let label = NSTextField(labelWithString: "")
    private(set) var isOn = false
    var onToggle: ((Bool) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        label.stringValue = title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.checkBox); setAccessibilityLabel(title)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var allowsVibrancy: Bool { false }
    func setOn(_ on: Bool) { isOn = on; setAccessibilityValue(on); restyle() }
    private func restyle() {
        label.font = .systemFont(ofSize: 12, weight: isOn ? .medium : .regular)
        label.textColor = isOn ? .white : .labelColor
        needsDisplay = true
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let fill: NSColor = isOn ? (hovered ? NSColor.controlAccentColor.blended(withFraction: 0.10, of: .white) ?? .controlAccentColor : .controlAccentColor)
                                 : NSColor.labelColor.withAlphaComponent(hovered ? 0.11 : 0.06)
        easeLayerColor(layer, "backgroundColor", to: fill.cgColor)
        easeLayerColor(layer, "borderColor", to: isOn ? NSColor.clear.cgColor : NSColor.labelColor.withAlphaComponent(0.16).cgColor)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { setOn(!isOn); onToggle?(isOn) }
    override func accessibilityPerformPress() -> Bool { setOn(!isOn); onToggle?(isOn); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    func wantsHandCursor(at point: NSPoint) -> Bool { true }
}

/// One-point line between the rows of a settings group.
final class HairlineView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor }
}

/// A settings group: a small title above a bordered box (the style of the activity log) holding rows.
final class SettingsGroup: NSView {
    let box = NSView()
    init(title: String, rows: [NSView]) {
        super.init(frame: .zero)
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        var views: [NSView] = []
        for (i, row) in rows.enumerated() { if i > 0 { views.append(HairlineView()) }; views.append(row) }
        let list = NSStackView(views: views)
        list.orientation = .vertical; list.alignment = .width; list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(list)
        let column = NSStackView(views: [caption, box])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor), list.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            list.topAnchor.constraint(equalTo: box.topAnchor), list.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.widthAnchor.constraint(equalTo: column.widthAnchor),
            caption.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 12),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        updateBox()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateBox() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBox() }
}

/// A settings row: title (and an optional grey line under it) on the left, the control on the right.
/// 34 pt tall, 44 pt with the second line.
final class SettingsRow: NSView {
    /// The grey of the second line: lighter than the system's secondary grey, which sits too close to the titles.
    /// (A dynamic colour: labelColor.withAlphaComponent would freeze the appearance current when it is made.)
    static let detailAlpha: CGFloat = {
        if let i = CommandLine.arguments.firstIndex(of: "--debug-detail-alpha"), i + 1 < CommandLine.arguments.count,
           let a = Double(CommandLine.arguments[i + 1]) { return CGFloat(a) }   // for comparing greys on a board
        return 0.32
    }()
    static let detailColor = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: detailAlpha) : NSColor(white: 0, alpha: detailAlpha)
    }
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let detailLine: NSStackView
    init(_ text: String, detail: String? = nil, link: LinkButton? = nil, control: NSView) {
        detailLine = NSStackView()
        super.init(frame: .zero)
        title.stringValue = text
        title.font = .systemFont(ofSize: 13)
        self.detail.font = .systemFont(ofSize: 11)
        self.detail.textColor = SettingsRow.detailColor
        self.detail.stringValue = detail ?? ""
        link?.restColor = SettingsRow.detailColor
        detailLine.setViews([self.detail] + (link.map { [$0] } ?? []), in: .leading)
        detailLine.orientation = .horizontal; detailLine.spacing = 0; detailLine.alignment = .firstBaseline
        let texts = NSStackView(views: [title, detailLine])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 1
        detailLine.isHidden = detail == nil && link == nil
        let row = NSStackView(views: [texts, NSView(), control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.setCustomSpacing(0, after: texts)   // the spacer between texts and control adds no gap of its own
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: detailLine.isHidden ? 34 : 44),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The back button of the settings page: a chevron in a square that lights up under the pointer.
final class BackButton: NSView, HandCursorView {
    let chevron = NSImageView()
    var onClick: (() -> Void)?
    private var hovered = false { didSet { chevron.contentTintColor = hovered ? .labelColor : .secondaryLabelColor; needsDisplay = true } }
    init() {
        super.init(frame: .zero)
        chevron.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor), chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Back")
        toolTip = "Back (Esc)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func viewDidHide() { super.viewDidHide(); hovered = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hovered = false } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    func wantsHandCursor(at point: NSPoint) -> Bool { true }
    /// `--debug-scene settings` shows the pointer on it, as on the board.
    func showHover() { hovered = true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}


final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    // MARK: UI
    var statusItem: NSStatusItem!
    let panelController = NSViewController()
    let handCursor = HandCursorTracker()
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
    let gpuMeter = GPUReader()
    let workBox = NumberBox()
    let restBox = NumberBox()
    var workField: NSTextField { workBox.field }
    var restField: NSTextField { restBox.field }
    let runButton = FlatButton(title: "Start cycle", primary: true)
    let panelModePicker = SegmentedPicker(items: ["Popover", "Window"], label: "Open the panel as")
    let attachButton = HoverIconButton(symbol: "menubar.arrow.up.rectangle", pointSize: 13, label: "Attach to the menu bar", weight: .regular)
    /// True while the panel travels between the popover and the window (drag to detach, attach button).
    var detaching = false
    let logBox = LogBoxView()
    let versionLabel = NSTextField(labelWithString: "")
    let settingsButton = HoverIconButton(symbol: "gearshape", pointSize: 14, label: "Settings", weight: .regular)
    let updateChip = UpdateChip()
    var updateRow: NSView!
    var panelColumn: NSStackView!
    var updateURL: URL?
    var updateZip: URL?
    var updateSha: URL?
    var updateVersion = ""
    var updating = false
    var announcedThisRun = ""
    var quitting = false
    var logView: NSTextView { logBox.list }
    // settings page
    var mainColumn: NSStackView!
    var settingsColumn: NSStackView!
    var showingSettings = false
    var pageTransition: Timer?
    let backButton = BackButton()
    let loginSwitch = ToggleSwitch(label: "Open at login")
    let appearancePicker = SegmentedPicker(items: ["System", "Light", "Dark"], label: "Appearance")
    let menuBarChips = [("time", ChipToggle(title: "Time")), ("cpu", ChipToggle(title: "CPU")), ("gpu", ChipToggle(title: "GPU")), ("temp", ChipToggle(title: "Temp"))]
    var menuBarRow: SettingsRow!
    let autoStartSwitch = ToggleSwitch(label: "Start automatically")
    let logFileSwitch = ToggleSwitch(label: "Save the activity log to a file")
    var logFileRow: SettingsRow!
    let showLogLink = LinkButton(title: "", target: nil, action: nil)
    let smoothSwitch = ToggleSwitch(label: "Smooth curves")
    let magnetSwitch = ToggleSwitch(label: "Magnetic edges")
    let holdSwitch = ToggleSwitch(label: "Hold the chart while idle")
    let checkSwitch = ToggleSwitch(label: "Check for updates automatically")
    let installSwitch = ToggleSwitch(label: "Install updates automatically")
    let checkNowButton = FlatButton(title: "Check now", primary: false)
    let gitHubLink = LinkButton(title: "", target: nil, action: nil)
    var versionRow: SettingsRow!
    var lastCheck: (date: Date, result: String)?
    var checking = false
    var pendingAutoInstall = false
    // automatic start: armed while the encoder has been seen idle since the cycle last stopped
    var autoStartArmed = true
    var autoBusySeconds: Double = 0, autoIdleSeconds: Double = 0
    /// The newest reading, for the menu bar: recorded even while the chart is held still.
    var latestReading: Sample?
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
    /// `--debug-scene <working|compact|resting> <png>`: the scene to stage for the README images.
    static let scene: String? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--debug-scene"), i + 2 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }()
    /// A staged scene keeps its settings in a throwaway domain, never in the user's own preferences.
    let defaults: UserDefaults = {
        guard let scene = App.scene else { return .standard }
        let name = "io.github.interstellar0verdrive.siesta.scene"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set(30, forKey: "work"); d.set(5, forKey: "rest")
        d.set(scene == "resting" || CommandLine.arguments.contains("--debug-window"), forKey: "window")   // `--debug-window`: any scene in the detached window
        d.set(scene != "working", forKey: "chartCollapsed")
        d.set(scene == "resting", forKey: "logExpanded")
        if scene == "settings" { d.set(["time"], forKey: "menuBarItems") }
        return d
    }()
    var threshold: Double { defaults.object(forKey: "threshold") == nil ? 50.0 : defaults.double(forKey: "threshold") }
    // the cycle uses the committed values, not what is being typed in the fields
    var committedWork = 60
    var committedRest = 5
    var workMinutes: Double { Double(max(1, committedWork)) }
    var restMinutes: Double { Double(max(1, committedRest)) }
    var detached: Bool { defaults.bool(forKey: "window") }
    /// A stored switch, or its default while the user has never touched it.
    func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
    var menuBarItems: [String] { defaults.stringArray(forKey: "menuBarItems") ?? ["time"] }
    var appearanceChoice: String { defaults.string(forKey: "appearance") ?? "system" }
    /// `--appearance light|dark` (tests and README renders) wins over the stored choice.
    let forcedAppearance = CommandLine.arguments.contains("--appearance")
    var logFileURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Siesta/Siesta.log") }

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
        statusItem.button?.imagePosition = .imageOnly   // the countdown and the readings are drawn into the image
        applyAppearance()
        // with "System", follow the Mac switching between light and dark
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncPopoverAppearance() }
        }
        chart.showsGPU = gpuMeter.available   // before the panel is built: the chart's height depends on it
        buildPanel()
        chart.smoothCurves = flag("smoothCurves", true)
        chart.magneticBands = flag("magneticBands", true)
        let w = defaults.integer(forKey: "work"), r = defaults.integer(forKey: "rest")
        workField.integerValue = w == 0 ? 60 : w
        restField.integerValue = r == 0 ? 5 : r
        committedWork = workField.integerValue
        committedRest = restField.integerValue
        logExpanded = defaults.bool(forKey: "logExpanded")   // collapsed the first time, then as last left
        if let scene = App.scene { stageScene(scene); return }   // no timer, no rescue of frozen workers, no network
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        rescueFrozen()
        installSignalHandlers()
        installPopoverGlide()
        installDetachDrag()
        installSettingsKeys()
        if let i = CommandLine.arguments.firstIndex(of: "--debug-update"), i + 1 < CommandLine.arguments.count {
            // shows the update chip for a made-up version without asking GitHub; "busy" shows it updating
            let v = CommandLine.arguments[i + 1]
            updateVersion = v == "busy" ? "9.9.9" : v
            showUpdate(version: updateVersion, url: URL(string: "https://github.com/\(App.repo)/releases")!)
            if v == "busy" { updateStatus("Updating…") }
        } else if flag("checkUpdates", true) { checkForUpdate() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            if self?.flag("checkUpdates", true) == true { self?.checkForUpdate() }
        }
        refresh()
        if CommandLine.arguments.contains("--start") { toggleRun() }
        if let i = CommandLine.arguments.firstIndex(of: "--debug-panel"), i + 1 < CommandLine.arguments.count {
            // renders the whole panel at popover width, off screen, into a PNG (2x), then quits
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.renderPanel(to: out) }
        }
        if debugLogAnimation {   // toggles the log twice (back to how it was), printing each frame, then quits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggleLog() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.toggleLog() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { NSApp.terminate(nil) }
        }
        if debugPageAnimation {   // slides to the settings page and back, printing each frame, then quits
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showSettings(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.showSettings(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { NSApp.terminate(nil) }
        }
        if CommandLine.arguments.contains("--auto-update") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.openUpdate() }
        }
        // The status item must be laid out before a popover can attach to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showPanel()
            if CommandLine.arguments.contains("--debug-settings") { self?.showSettings(true, animated: false) }
        }
    }

    func applicationWillTerminate(_ n: Notification) { resume() }

    /// Esc leaves the settings page; closing the popover always brings back the main page.
    func installSettingsKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.showingSettings, event.keyCode == 53,
                  event.window === self.panelController.view.window else { return event }
            self.showSettings(false)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            guard self?.detaching != true else { return }   // dragged out into the window: the page stays as it is
            self?.showSettings(false, animated: false)
        }
    }

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
        // `--debug-control`: drive the app from a shell while testing — SIGUSR1 presses Start/Stop cycle, SIGUSR2 Quit Siesta
        guard CommandLine.arguments.contains("--debug-control") else { return }
        for (sig, act) in [(SIGUSR1, { [weak self] in self?.toggleRun() }), (SIGUSR2, { [weak self] in self?.quit() })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: act)
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

    /// Renders the whole panel off screen into an sRGB PNG, on the panel colour, then quits.
    /// 2x by default; `--width <px>` draws it straight at that pixel width, so a page that shows
    /// the panel at that size never has to resample it (resampling blurs the text).
    func renderPanel(to out: URL) {
        layoutPanel()
        let view = panelController.view
        let size = view.fittingSize
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        host.appearance = NSApp.appearance
        popover.contentViewController = nil
        host.contentView = view
        view.layoutSubtreeIfNeeded()
        var scale: CGFloat = 2
        if let i = CommandLine.arguments.firstIndex(of: "--width"), i + 1 < CommandLine.arguments.count,
           let w = Double(CommandLine.arguments[i + 1]), w > 0 { scale = CGFloat(w) / size.width }
        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        let draw = { () -> NSBitmapImageRep in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep); return rep
        }
        _ = draw(); view.layoutSubtreeIfNeeded()
        let rep = draw()
        let dark = (NSApp.appearance ?? view.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // flatten onto the panel colour in an sRGB bitmap: the colours a browser shows without converting
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { NSApp.terminate(nil); return }
        cg.interpolationQuality = .none
        cg.setFillColor(NSColor(white: dark ? 0.17 : 0.93, alpha: 1).usingColorSpace(.sRGB)!.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        if let image = rep.cgImage { cg.draw(image, in: CGRect(x: 0, y: 0, width: pw, height: ph)) }
        if let image = cg.makeImage(), let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
        }
        print("Wrote \(out.path) \(size) at \(pw)×\(ph) px"); fflush(stdout)
        NSApp.terminate(nil)
    }

    /// `--debug-scene`: stages a 30/5 cycle at a fixed time with two hours of realistic history,
    /// renders the panel and quits. "working" and "compact" are at 17:40, 18 of 30 work minutes in;
    /// "resting" is the detached window at 17:45, two minutes into a five-minute rest.
    func stageScene(_ name: String) {
        guard let i = CommandLine.arguments.firstIndex(of: "--debug-scene") else { return }
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 2])
        refresh()   // the stopped state first, as at launch: starting the cycle then reveals the chart
        if name == "settings" {   // the settings page; `--debug-hover` puts the pointer on the back button, as on the board
            lastCheck = (Calendar.current.date(bySettingHour: 17, minute: 12, second: 0, of: Date())!, "ok")
            showSettings(true, animated: false)
            if CommandLine.arguments.contains("--debug-hover") { backButton.showHover() }
            layoutPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.renderPanel(to: out) }
            return
        }
        let resting = name == "resting"
        func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        let now = resting ? at(17, 45) : at(17, 40)
        // the cycle started before the history window, which opens inside a work interval; a rest every 35 minutes
        let start = resting ? at(14, 53) : at(15, 2)
        let rests = (0..<8).map { k -> (Date, Date) in
            let s = start.addingTimeInterval(Double(k) * 35 * 60 + 30 * 60); return (s, s.addingTimeInterval(5 * 60))
        }.filter { $0.0 < now }
        let samples = App.sceneSamples(from: now.addingTimeInterval(-120 * 60), to: now,
                                       rests: rests.map { ($0.0.timeIntervalSinceReferenceDate, $0.1.timeIntervalSinceReferenceDate) })
        chart.samples = samples
        func cpu(at d: Date) -> Int { Int((samples.last { $0.t <= d.timeIntervalSinceReferenceDate }?.cpu ?? 85).rounded()) }
        var events: [(Date, String)] = [(start, "Cycle started · 30 min work, 5 min rest"), (start, "\(target.name) is encoding")]
        for (s, e) in rests {
            events.append((s, "\(target.name) paused · CPU \(cpu(at: s.addingTimeInterval(-10)))%"))
            if e <= now { events.append((e, "\(target.name) resumed")) }
        }
        for (d, text) in events { sceneClock = d; log(text) }
        sceneClock = now
        if resting {
            phase = .resting; restStart = rests.last!.0; restEnd = rests.last!.1
        } else {
            phase = .working; isEncoding = true; workSeconds = 18 * 60; pausePlanned = at(17, 52)
        }
        refresh()
        layoutPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.renderPanel(to: out) }
    }

    /// Readings shaped like a real HandBrake encode on an M4 Pro: CPU near 86% of the Mac with a little
    /// wander while working, near zero at rest; the hottest core jumps to the high 70s within seconds and
    /// then creeps towards 100 °C, and during a rest drops fast, then slowly. One sample every 5 s, as the app records.
    static func sceneSamples(from t0: Date, to t1: Date, rests: [(TimeInterval, TimeInterval)]) -> [Sample] {
        var seed: UInt64 = 0x5135_7a
        func noise() -> Double {   // deterministic, -1...1
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }
        let a = t0.timeIntervalSinceReferenceDate, b = t1.timeIntervalSinceReferenceDate
        var fast = 28.0, slow = 27.0, load = 86.0, wander = 0.0, out: [Sample] = []
        var sumCpu = 0.0, n = 0
        var t = a - 40 * 60   // warm up first, so the history opens on settled readings
        while t <= b + 0.5 {
            let resting = rests.contains { t >= $0.0 && t < $0.1 }
            wander = wander * 0.985 + noise() * 0.35
            let target = resting ? 0.3 : 86 + 2.2 * sin(t / 53) + 1.3 * sin(t / 17) + wander
            load += (target - load) * (resting ? 0.6 : 0.45)
            fast += ((resting ? 0 : 28) - fast) / 15
            slow += ((resting ? 0 : 27) - slow) / 300
            sumCpu += max(0, load); n += 1
            if t >= a && Int(t - a) % 5 == 0 {
                let temp = 45 + fast + slow + noise() * 0.45 + (resting ? 0 : 0.6 * sin(t / 41))
                // GPU as during a software encode: the desktop's own 11–12%, now and then a short spike
                let spike = (Int(t) / 5) % 97 == 0 || (Int(t) / 5) % 131 == 0 ? 14.0 : 0
                out.append(Sample(t: t, cpu: sumCpu / Double(n), temp: temp, resting: resting, gpu: 11.5 + noise() * 1.2 + spike))
                sumCpu = 0; n = 0
            } else if t < a { sumCpu = 0; n = 0 }
            t += 1
        }
        return out
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
        // version (plain text) · settings gear · Quit
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.stringValue = "v\(currentVersion)"
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.restColor = .secondaryLabelColor   // lighter than the version: the version stays a detail
        settingsButton.target = self; settingsButton.action = #selector(openSettings)
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [NSView(), versionLabel, settingsButton, quitButton])
        footer.orientation = .horizontal; footer.alignment = .centerY
        footer.setCustomSpacing(App.versionToGear, after: versionLabel)
        footer.setCustomSpacing(App.gearToQuit, after: settingsButton)
        // update chip: its own row above the status, right aligned, only while an update exists
        updateChip.onClick = { [weak self] in self?.openUpdate() }
        let chipRow = NSStackView(views: [NSView(), updateChip])
        chipRow.orientation = .horizontal; chipRow.alignment = .centerY
        chipRow.isHidden = true
        updateRow = chipRow
        // Tab order: Work → Rest → Start/Stop → Quit → Work
        workField.nextKeyView = restField
        restField.nextKeyView = runButton
        runButton.nextKeyView = quitButton
        quitButton.nextKeyView = workField

        let column = NSStackView(views: [chipRow, statusRow, progressWrap, chart, divider(), settings, divider(), logBox, footer])
        panelColumn = column
        mainColumn = column
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 19
        column.setCustomSpacing(App.chipToStatus, after: chipRow)
        column.setCustomSpacing(19, after: progressWrap)
        column.setCustomSpacing(19, after: chart)
        column.edgeInsets = NSEdgeInsets(top: App.topInset, left: 24, bottom: 20, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false
        // the column does not reliably stretch children with an intrinsic width: pin every row to the edges
        for row in [chipRow, statusRow, progressWrap, chart, settings, logBox, footer] as [NSView] {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 24),
                row.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -24),
            ])
        }

        let background = BackgroundView()
        panelWidth = background.widthAnchor.constraint(equalToConstant: popoverWidth)
        panelWidth.priority = NSLayoutConstraint.Priority(999)
        panelWidth.isActive = true
        attachPage(column, in: background, offset: 0)
        settingsColumn = buildSettings()
        background.autoresizingMask = [.width, .height]   // follow the popover / window content area
        panelController.view = background
        handCursor.attach(to: background)
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
        if logAnimation == nil { logBox.reveal = logExpanded ? 1 : 0 }
        logBox.count.stringValue = logCount == 0 ? "No events yet" : "\(logCount) event\(logCount == 1 ? "" : "s")"
        guard !detaching else { return }   // the drag or the attach animation sizes the panel itself
        panelWidth.constant = detached ? windowWidth : popoverWidth
        panelController.view.layoutSubtreeIfNeeded()
        // the container sizes the view: never set its frame by hand. Whole points only: with fractional
        // heights the popover re-rounds its position on every animation frame and its top edge trembles
        guard pageTransition == nil else { return }   // the page slide sizes the panel itself
        let fitting = panelController.view.fittingSize
        setPanelSize(NSSize(width: fitting.width.rounded(), height: fitting.height.rounded()))
    }

    func setPanelSize(_ size: NSSize) {
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
    static let windowFrameName = "SiestaPanel"

    /// The detached window, made once: title bar with the button that attaches the panel to the menu bar again.
    func detachedWindow() -> NSWindow {
        if let w = window { return w }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Siesta"
        w.isReleasedWhenClosed = false
        w.autorecalculatesKeyViewLoop = false
        w.level = .floating          // stays visible above other apps' windows
        attachButton.target = self; attachButton.action = #selector(attachToMenuBar)
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        holder.addSubview(attachButton)
        NSLayoutConstraint.activate([
            attachButton.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            attachButton.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        w.addTitlebarAccessoryViewController(accessory)
        w.setFrameAutosaveName(App.windowFrameName)   // reopens where it was left
        window = w
        return w
    }

    /// Steps an animation at 60 Hz in every run loop mode (also while a menu or a drag is tracking).
    func animate(duration: TimeInterval, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        if duration <= 0 { step(1); done(); return }
        let start = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let p = min(1, CGFloat(Date().timeIntervalSince(start) / duration))
            step(p)
            if p >= 1 { timer.invalidate(); done() }
        }
        RunLoop.main.add(t, forMode: .common)
    }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where the popover's panel sits relative to the cat: measured each time the popover opens,
    /// so the attach animation lands exactly where the popover will appear.
    var popoverGap: CGFloat = 13.5, popoverDX: CGFloat = 0
    func measurePopoverPlacement() {
        guard let pw = popoverWindow, let button = statusItem.button, let bw = button.window else { return }
        let view = panelController.view
        let body = pw.convertToScreen(view.convert(view.bounds, to: nil))
        let anchor = bw.convertToScreen(button.convert(iconAnchor(), to: nil))
        popoverGap = anchor.minY - body.maxY
        popoverDX = body.midX - anchor.midX
        debugPrint("POPOVER gap \(popoverGap) dx \(popoverDX)")
    }

    /// A borderless, shadowed stand-in that carries the panel between the popover and the window.
    /// Its background is the window's, with the popover's material over it at `popoverLook` (0…1):
    /// fading that layer moves the colour from one container to the other without a jump.
    func makeLift(_ frame: NSRect, popoverLook: CGFloat) -> (NSPanel, NSVisualEffectView, NSVisualEffectView) {
        let lift = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        lift.isOpaque = false; lift.backgroundColor = .clear; lift.hasShadow = true
        lift.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)   // above the popover at the hand-over
        lift.appearance = NSApp.appearance
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        fx.material = .windowBackground; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 10; fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        let look = NSVisualEffectView(frame: fx.bounds)
        look.material = .popover; look.blendingMode = .behindWindow; look.state = .active
        look.autoresizingMask = [.width, .height]
        look.alphaValue = popoverLook
        fx.addSubview(look)
        lift.contentView = fx
        return (lift, fx, look)
    }

    /// A picture of the panel laid over it, so the panel itself can move to another container unseen.
    func coverWithSnapshot(_ fx: NSView) {
        let view = panelController.view
        let snapshot = NSImageView(frame: fx.bounds)
        snapshot.autoresizingMask = [.width, .height]
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(rep); snapshot.image = image
        }
        fx.addSubview(snapshot)
    }

    // MARK: Drag the popover out into a window
    // A drag that starts on the panel's background (the status, the gaps between the blocks; never on a
    // control, the chart or the log) lifts the panel out of the popover; it widens to the window's width
    // while it follows the pointer, and where the button comes up it becomes the detached window.
    func installDetachDrag() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, !self.detached, !self.detaching, self.popover.isShown,
                  let pw = self.popoverWindow, event.window === pw, self.isDragHandle(event) else { return event }
            pw.makeFirstResponder(nil)   // what a click on the background does
            self.trackDetachDrag()
            return nil
        }
    }

    func isDragHandle(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        var v = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        while let view = v {
            if view is ChartView || view is LogBoxView || view is NSTextView || view is NSScrollView { return false }
            if let field = view as? NSTextField {
                if field.isEditable || field.isSelectable { return false }
            } else if view is NSControl { return false }
            if let h = view as? HandCursorView, h.wantsHandCursor(at: view.convert(event.locationInWindow, from: nil)) { return false }
            if view === panelController.view { return true }
            v = view.superview
        }
        return false
    }

    func trackDetachDrag() {
        guard let pw = popoverWindow else { return }
        let start = NSEvent.mouseLocation
        // a click, or a few points of jitter, leaves the popover where it is
        while true {
            guard let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) else { continue }
            if e.type == .leftMouseUp { return }
            let p = NSEvent.mouseLocation
            if hypot(p.x - start.x, p.y - start.y) >= 4 { break }
        }
        detaching = true
        let view = panelController.view
        let body = pw.convertToScreen(view.convert(view.bounds, to: nil))
        // the grab point as a share of the width (the panel widens around it) and a distance from the top
        let grab = NSPoint(x: (start.x - body.minX) / body.width, y: body.maxY - start.y)
        measurePopoverPlacement()
        let (lift, fx, look) = makeLift(body, popoverLook: 1)
        pw.alphaValue = 0                 // the popover stays open underneath until the drop, so the drag keeps its events
        view.frame = fx.bounds
        fx.addSubview(view)
        func place(_ width: CGFloat) {
            panelWidth.constant = width
            view.layoutSubtreeIfNeeded()
            let h = view.fittingSize.height.rounded()
            let m = NSEvent.mouseLocation
            lift.setFrame(NSRect(x: (m.x - grab.x * width).rounded(), y: (m.y + grab.y - h).rounded(), width: width, height: h), display: true)
            view.frame = fx.bounds
            look.alphaValue = 1 - (width - popoverWidth) / (windowWidth - popoverWidth)
        }
        place(popoverWidth)
        lift.orderFront(nil)
        let t0 = Date(), duration: TimeInterval = reduceMotion ? 0 : 0.26
        func width() -> CGFloat {
            let p = duration == 0 ? 1 : min(1, Date().timeIntervalSince(t0) / duration)
            return popoverWidth + (windowWidth - popoverWidth) * CGFloat(1 - pow(1 - p, 3))   // ease out
        }
        while true {
            let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 1.0 / 60), inMode: .eventTracking, dequeue: true)
            place(width())
            if e?.type == .leftMouseUp { break }
        }
        // released before the panel reached its width: finish the widening in place
        while Date().timeIntervalSince(t0) < duration {
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 1.0 / 60))
            place(width())
        }
        place(windowWidth)
        // the window takes over: its title bar appears above the panel, which stays where it was dropped
        coverWithSnapshot(fx)
        let panelRect = lift.frame
        popover.animates = false; popover.close(); popover.animates = true
        popover.contentViewController = nil
        pw.alphaValue = 1
        defaults.set(true, forKey: "window")
        panelModePicker.select(1)
        let w = detachedWindow()
        w.contentViewController = panelController
        detaching = false; layoutPanel(); detaching = true   // the window's own size, now that the panel is in it
        let size = panelController.view.fittingSize
        w.setFrame(w.frameRect(forContentRect: NSRect(x: panelRect.minX, y: panelRect.maxY - size.height.rounded(), width: size.width.rounded(), height: size.height.rounded())), display: true)
        w.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)
        animate(duration: reduceMotion ? 0.15 : 0.18, step: { p in w.alphaValue = p }, done: { [weak self] in
            lift.orderOut(nil)
            self?.detaching = false
        })
    }

    /// The title bar button: the panel leaves the window (its title bar fades), narrows and glides up to
    /// exactly where the popover will be, and the popover takes over with a short crossfade: only its arrow appears.
    @objc func attachToMenuBar() {
        guard detached, !detaching, let w = window, let button = statusItem.button, let bw = button.window else { return }
        detaching = true
        let view = panelController.view
        let saved = w.frame
        let from = w.contentRect(forFrameRect: w.frame)
        let (lift, fx, look) = makeLift(from, popoverLook: 0)
        // a picture of the panel goes up first, exactly over it; only then the panel itself moves into the stand-in
        coverWithSnapshot(fx)
        lift.orderFront(nil)
        lift.display()
        let picture = fx.subviews.last
        view.frame = fx.bounds
        fx.addSubview(view)                // out of the window: the empty window only shows its fading title bar
        picture?.removeFromSuperview()
        let anchor = bw.convertToScreen(button.convert(iconAnchor(), to: nil))
        let toTop = anchor.minY - popoverGap, toMidX = anchor.midX + popoverDX
        animate(duration: reduceMotion ? 0 : 0.28, step: { [weak self] p in
            guard let self = self else { return }
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            let width = (windowWidth + (popoverWidth - windowWidth) * e).rounded()
            self.panelWidth.constant = width
            view.layoutSubtreeIfNeeded()
            let h = view.fittingSize.height.rounded()
            let midX = from.midX + (toMidX - from.midX) * e
            let top = from.maxY + (toTop - from.maxY) * e
            lift.setFrame(NSRect(x: (midX - width / 2).rounded(), y: (top - h).rounded(), width: width, height: h), display: true)
            view.frame = fx.bounds
            look.alphaValue = e
            w.alphaValue = max(0, 1 - p / 0.3)
        }, done: { [weak self] in
            guard let self = self else { return }
            w.orderOut(nil)
            w.alphaValue = 1
            w.setFrame(saved, display: false)      // next time the window opens where it was
            w.saveFrame(usingName: App.windowFrameName)
            self.defaults.set(false, forKey: "window")
            self.panelModePicker.select(0)
            self.coverWithSnapshot(fx)
            let animates = self.popover.animates
            self.popover.animates = false
            self.detaching = false
            self.showPanel()                       // the popover opens under the stand-in, identical: only its arrow shows
            self.detaching = true
            self.popover.animates = animates
            self.animate(duration: 0.1, step: { p in lift.alphaValue = 1 - p }, done: { [weak self] in
                lift.orderOut(nil)
                self?.detaching = false
                self?.measurePopoverPlacement()
            })
        })
    }

    @objc func statusItemClicked() {
        if detached { showPanel() }
        else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    func showPanel() {
        if detached {
            if popover.isShown { popover.performClose(nil) }
            popover.contentViewController = nil
            let w = detachedWindow()
            w.contentViewController = panelController
            layoutPanel()
            if !w.isVisible && !w.setFrameUsingName(App.windowFrameName) { w.center() }
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
            measurePopoverPlacement()
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
        guard let image = button.image, image.size.width > App.catSize + 1 else { return button.bounds }
        // the image is centred in the button: a rect from the left edge, symmetric about the cat's centre
        let catCentre = (button.bounds.width - image.size.width) / 2 + App.catSize / 2
        return NSRect(x: 0, y: 0, width: 2 * catCentre, height: button.bounds.height)
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

    /// Popover or window, from the settings: the stored choice is also how the panel opens next time.
    func setDetached(_ on: Bool) {
        guard on != detached, !detaching else { return }
        defaults.set(on, forKey: "window")
        panelModePicker.select(on ? 1 : 0)
        showPanel()
    }

    /// Opens or closes the activity log over 0.22 s with the chart's easing, the panel following.
    var logAnimation: Timer?
    @objc func toggleLog() {
        logExpanded.toggle()
        defaults.set(logExpanded, forKey: "logExpanded")
        logBox.expanded = logExpanded
        logAnimation?.invalidate()
        let from = logBox.reveal, to: CGFloat = logExpanded ? 1 : 0, opening = logExpanded
        let start = Date(), duration = 0.22
        logAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            self.logBox.reveal = from + (to - from) * CGFloat(eased)
            self.layoutPanel()
            if opening { self.logView.scrollToEndOfDocument(nil) }   // the newest lines stay in view as it grows
            if self.debugLogAnimation {
                let f = self.panelController.view.window?.frame ?? .zero
                self.debugPrint(String(format: "LOGANIM p %.2f reveal %.3f window x %.1f y %.1f w %.1f h %.1f top %.1f", p, self.logBox.reveal, f.minX, f.minY, f.width, f.height, f.maxY))
            }
            if p >= 1 { timer.invalidate(); self.logAnimation = nil }
        }
    }
    let debugLogAnimation = CommandLine.arguments.contains("--debug-log-animation")
    let debugPageAnimation = CommandLine.arguments.contains("--debug-page-animation")

    func clearLog() {
        logCount = 0
        showPlaceholder()
        logBox.count.stringValue = "No events yet"
        logBox.clear.isHidden = true
        logBox.dot.isHidden = true
    }

    @objc func quit() { quitting = true; NSApp.terminate(nil) }

    // MARK: Settings page
    // The gear in the footer slides the panel over to the settings page: same width, same container
    // (popover or detached window); the back chevron or Esc slides it back. Every change applies at once.
    var pageLeading: NSLayoutConstraint!
    var pageTrailing: NSLayoutConstraint!

    /// Pins a page (the main column or the settings column) to the top of the panel, shifted by `offset`.
    func attachPage(_ page: NSView, in background: NSView, offset: CGFloat) {
        page.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(page)
        // below required, so the slide can size the panel between the two pages' heights
        let bottom = page.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor)
        bottom.priority = NSLayoutConstraint.Priority(999)
        pageLeading = page.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: offset)
        pageTrailing = page.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: offset)
        NSLayoutConstraint.activate([page.topAnchor.constraint(equalTo: background.topAnchor), pageLeading, pageTrailing, bottom])
    }

    func buildSettings() -> NSStackView {
        backButton.onClick = { [weak self] in self?.showSettings(false) }
        let pageTitle = NSTextField(labelWithString: "Settings")
        pageTitle.font = .systemFont(ofSize: 16, weight: .medium)
        let head = NSStackView(views: [backButton, pageTitle])
        head.orientation = .horizontal; head.alignment = .centerY; head.spacing = 8
        head.heightAnchor.constraint(equalToConstant: 34).isActive = true   // as tall as the status row

        loginSwitch.onToggle = { [weak self] on in self?.setOpenAtLogin(on) }
        panelModePicker.onChange = { [weak self] i in self?.setDetached(i == 1) }
        appearancePicker.onChange = { [weak self] i in
            self?.defaults.set(["system", "light", "dark"][i], forKey: "appearance")
            self?.applyAppearance()
        }
        for (key, chip) in menuBarChips {
            chip.onToggle = { [weak self] on in
                guard let self = self else { return }
                var items = Set(self.menuBarItems)
                if on { items.insert(key) } else { items.remove(key) }
                self.defaults.set(self.menuBarChips.map { $0.0 }.filter { items.contains($0) }, forKey: "menuBarItems")
                self.updateMenuBarRow()
                self.refresh()
            }
        }
        // no GPU figure on this Mac: no GPU chip
        let chips = NSStackView(views: menuBarChips.filter { $0.0 != "gpu" || gpuMeter.available }.map { $0.1 })
        chips.orientation = .horizontal; chips.spacing = 5
        menuBarRow = SettingsRow("Menu bar", detail: "Next to the cat", control: chips)
        let general = SettingsGroup(title: "General", rows: [
            SettingsRow("Open at login", control: loginSwitch),
            SettingsRow("Appearance", control: appearancePicker),
            SettingsRow("Open the panel as", control: panelModePicker),
            menuBarRow,
        ])

        autoStartSwitch.onToggle = { [weak self] on in
            self?.defaults.set(on, forKey: "autoStart")
            self?.autoBusySeconds = 0
        }
        logFileSwitch.onToggle = { [weak self] on in
            self?.defaults.set(on, forKey: "logFile")
            self?.updateLogFileRow()
            if on { self?.log("Activity log saved to Library/Logs/Siesta") }
        }
        for link in [showLogLink, gitHubLink] { link.isBordered = false; link.font = .systemFont(ofSize: 11) }
        showLogLink.text = "Show in Finder"
        showLogLink.target = self; showLogLink.action = #selector(showLogFile)
        logFileRow = SettingsRow("Save the activity log to a file", detail: "", link: showLogLink, control: logFileSwitch)
        let cycle = SettingsGroup(title: "Cycle", rows: [
            SettingsRow("Start automatically", detail: "When \(target.name) starts working", control: autoStartSwitch),
            logFileRow,
        ])

        smoothSwitch.onToggle = { [weak self] on in
            self?.defaults.set(on, forKey: "smoothCurves"); self?.chart.smoothCurves = on; self?.chart.needsDisplay = true
        }
        magnetSwitch.onToggle = { [weak self] on in
            self?.defaults.set(on, forKey: "magneticBands"); self?.chart.magneticBands = on; self?.chart.needsDisplay = true
        }
        holdSwitch.onToggle = { [weak self] on in self?.defaults.set(on, forKey: "holdChart") }
        let chartGroup = SettingsGroup(title: "Chart", rows: [
            SettingsRow("Smooth curves", control: smoothSwitch),
            SettingsRow("Magnetic edges", detail: "Rests and breaks pull the pointer", control: magnetSwitch),
            SettingsRow("Hold the chart while idle", detail: "Stops scrolling while \(target.name) is not working", control: holdSwitch),
        ])

        checkSwitch.onToggle = { [weak self] on in
            self?.defaults.set(on, forKey: "checkUpdates")
            if on { self?.checkForUpdate() } else { self?.updateVersionRow() }
        }
        installSwitch.onToggle = { [weak self] on in self?.defaults.set(on, forKey: "autoInstall") }
        gitHubLink.text = "GitHub"
        gitHubLink.target = self; gitHubLink.action = #selector(openAbout)
        gitHubLink.toolTip = "Siesta on GitHub"
        checkNowButton.target = self; checkNowButton.action = #selector(checkNow)
        checkNowButton.compact = true
        versionRow = SettingsRow("Siesta \(currentVersion)", detail: "", control: checkNowButton)
        let updates = SettingsGroup(title: "Updates", rows: [
            SettingsRow("Check for updates automatically", control: checkSwitch),
            SettingsRow("Install updates automatically", control: installSwitch),
            versionRow,
        ])

        // a quiet credit under the last group, with the link to the project page
        let creditText: String = {
            if let i = CommandLine.arguments.firstIndex(of: "--debug-credit"), i + 1 < CommandLine.arguments.count { return CommandLine.arguments[i + 1] }
            return "Siesta is open source · "
        }()
        let credit = NSTextField(labelWithString: creditText)
        credit.font = .systemFont(ofSize: 11)
        credit.textColor = .tertiaryLabelColor
        gitHubLink.restColor = .tertiaryLabelColor
        let creditLine = NSStackView(views: [credit, gitHubLink])
        creditLine.orientation = .horizontal; creditLine.spacing = 0; creditLine.alignment = .firstBaseline
        let creditRow = NSStackView()
        creditRow.setViews([creditLine], in: .center)   // centred under the boxes
        creditRow.orientation = .horizontal; creditRow.alignment = .centerY
        let column = NSStackView(views: [head, general, cycle, chartGroup, updates, creditRow])
        column.orientation = .vertical; column.alignment = .width; column.spacing = 19
        column.setCustomSpacing(14, after: updates)
        column.edgeInsets = NSEdgeInsets(top: App.topInset, left: 24, bottom: 20, right: 24)
        for row in [general, cycle, chartGroup, updates, creditRow] as [NSView] {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 24),
                row.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -24),
            ])
        }
        // the chevron's square starts 6 pt left of the column edge, so the chevron itself lines up with the boxes
        head.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 18).isActive = true
        syncSettings()
        return column
    }

    /// Puts every control in the state stored in the defaults (and, for login, in the system's).
    func syncSettings() {
        if App.scene == nil { loginSwitch.setOn(SMAppService.mainApp.status == .enabled, animated: false) }
        appearancePicker.select(["system", "light", "dark"].firstIndex(of: appearanceChoice) ?? 0)
        panelModePicker.select(detached ? 1 : 0)
        for (key, chip) in menuBarChips { chip.setOn(menuBarItems.contains(key)) }
        updateMenuBarRow()
        autoStartSwitch.setOn(flag("autoStart", false), animated: false)
        logFileSwitch.setOn(flag("logFile", false), animated: false)
        updateLogFileRow()
        smoothSwitch.setOn(flag("smoothCurves", true), animated: false)
        magnetSwitch.setOn(flag("magneticBands", true), animated: false)
        holdSwitch.setOn(flag("holdChart", false), animated: false)
        checkSwitch.setOn(flag("checkUpdates", true), animated: false)
        installSwitch.setOn(flag("autoInstall", false), animated: false)
        updateVersionRow()
    }

    func updateMenuBarRow() { menuBarRow?.detail.stringValue = menuBarItems.isEmpty ? "Only the cat" : "Next to the cat" }

    func updateLogFileRow() {
        let on = flag("logFile", false)
        logFileRow?.detail.stringValue = on ? "In Library/Logs/Siesta · " : "In Library/Logs/Siesta"
        showLogLink.isHidden = !on
    }

    /// The second line of the version row: the last check and its result, then the GitHub link.
    func updateVersionRow() {
        guard let row = versionRow else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let text: String
        if updating { text = "Updating to \(updateVersion)" }
        else if checking { text = "Checking…" }
        else if updateURL != nil { text = "Version \(updateVersion) available" }
        else if let last = lastCheck {
            text = last.result == "failed" ? "Could not check at \(f.string(from: last.date))" : "Up to date · checked at \(f.string(from: last.date))"
        } else { text = flag("checkUpdates", true) ? "Not checked yet" : "Automatic checks off" }
        row.detail.stringValue = text
        // not isEnabled: a disabled NSButton redraws its title in the wrong appearance for a moment (black on dark)
        checkNowButton.alphaValue = checking || updating ? 0.5 : 1
    }

    @objc func openSettings() { showSettings(true) }
    @objc func checkNow() { checkForUpdate() }

    /// Slides between the main page and the settings page over 0.22 s, the panel growing or shrinking
    /// to the new page's height at the same pace. The outgoing page leaves as a snapshot.
    func showSettings(_ on: Bool, animated: Bool = true) {
        guard on != showingSettings, pageTransition == nil else { return }
        let bg = panelController.view
        if on { syncSettings() }
        bg.window?.makeFirstResponder(nil)
        let from: NSView = on ? mainColumn : settingsColumn
        let to: NSView = on ? settingsColumn : mainColumn
        let width = bg.bounds.width, dir: CGFloat = on ? 1 : -1
        let fromHeight = bg.bounds.height
        var snapshot: NSImageView?
        if animated, bg.window?.isVisible == true, let rep = from.bitmapImageRepForCachingDisplay(in: from.bounds) {
            from.cacheDisplay(in: from.bounds, to: rep)
            let image = NSImage(size: from.bounds.size); image.addRepresentation(rep)
            let v = NSImageView(frame: from.frame)
            v.image = image; v.imageScaling = .scaleNone
            v.autoresizingMask = [.minYMargin]   // keeps its place under the top edge while the panel resizes
            snapshot = v
        }
        from.removeFromSuperview()
        showingSettings = on
        attachPage(to, in: bg, offset: snapshot == nil ? 0 : dir * width)
        guard let snap = snapshot else { layoutPanel(); return }
        bg.addSubview(snap)
        bg.layoutSubtreeIfNeeded()
        let fitting = bg.fittingSize
        let target = NSSize(width: fitting.width.rounded(), height: fitting.height.rounded())
        let startX = snap.frame.minX, start = Date(), duration = 0.22
        pageTransition = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            let e = CGFloat(p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2)
            self.pageLeading.constant = dir * width * (1 - e)
            self.pageTrailing.constant = dir * width * (1 - e)
            snap.frame.origin.x = startX - dir * width * e
            snap.alphaValue = 1 - e
            self.setPanelSize(NSSize(width: target.width, height: (fromHeight + (target.height - fromHeight) * e).rounded()))
            if self.debugPageAnimation {
                let f = bg.window?.frame ?? .zero
                self.debugPrint(String(format: "PAGE p %.2f offset %.1f snapshot x %.1f window w %.0f h %.0f top %.1f", p, self.pageLeading.constant, snap.frame.minX, f.width, f.height, f.maxY))
            }
            if p >= 1 {
                timer.invalidate()
                self.pageTransition = nil
                snap.removeFromSuperview()
                self.pageLeading.constant = 0; self.pageTrailing.constant = 0
                self.layoutPanel()
                bg.window?.invalidateCursorRects(for: bg)
            }
        }
    }

    func applyAppearance() {
        guard !forcedAppearance else { return }
        let choice: NSAppearance? = appearanceChoice == "light" ? NSAppearance(named: .aqua)
            : appearanceChoice == "dark" ? NSAppearance(named: .darkAqua) : nil
        NSApp.appearance = choice
        syncPopoverAppearance()
    }

    /// The popover always gets a concrete appearance, also with "System": left to itself it turns
    /// vibrant, and vibrancy blends the text into the background, so the greys flatten out (hover
    /// states, group captions, the chosen segment). This way it looks like the renders and the window.
    func syncPopoverAppearance() {
        let dark = (NSApp.appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let wanted = NSAppearance(named: dark ? .darkAqua : .aqua)
        if popover.appearance?.name != wanted?.name { popover.appearance = wanted }
    }
    var appearanceObservation: NSKeyValueObservation?

    func setOpenAtLogin(_ on: Bool) {
        guard App.scene == nil else { return }
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
            log(on ? "Siesta opens at login" : "Siesta no longer opens at login")
        } catch {
            log("Open at login: \(error.localizedDescription)")
        }
        loginSwitch.setOn(service.status == .enabled, animated: true)
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// What the menu bar shows next to the cat: the countdown, then CPU and temperature as columns.
    func menuBarParts(time: String) -> (time: String?, columns: [(caption: String, value: String)]) {
        let items = menuBarItems
        var columns: [(String, String)] = []
        if items.contains("cpu"), let r = latestReading { columns.append(("CPU", "\(Int(r.cpu.rounded()))%")) }
        if items.contains("gpu"), let g = latestReading?.gpu { columns.append(("GPU", "\(Int(g.rounded()))%")) }
        if items.contains("temp"), let t = latestReading?.temp { columns.append(("TEMP", "\(Int(t.rounded()))°")) }
        return (items.contains("time") && !time.isEmpty ? time : nil, columns)
    }

    // The menu bar item is one template image, so macOS tints it like any menu bar icon: the cat,
    // the countdown in the menu bar font, then each reading as Stats shows it — a small caption over
    // the value, left aligned. Every gap is measured on the ink, not on the boxes: 7 pt between the cat and the
    // countdown, 10 pt before each reading (as Stats spaces its own), and after the last one the same margin the cat has on its left.
    // A column keeps room for two digits (the temperature for three), so the item only widens at 100%.
    static let menuBarHeight: CGFloat = 22, catSize: CGFloat = 20
    /// Ink after the cat when the countdown follows it (the two read as one icon); before a reading,
    /// after the cat as between the items, the wider gap Stats keeps.
    static let menuBarGap: CGFloat = 7, menuBarItemGap: CGFloat = 10
    /// Horizontal ink of a line of text, from its drawing origin.
    static func inkX(_ a: NSAttributedString) -> (min: CGFloat, max: CGFloat) {
        let b = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(a), .useGlyphPathBounds)
        return (b.minX, b.maxX)
    }
    /// Left and right edge of the cat's ink in its 20 pt box, read from the pixels once per state.
    static var catInkCache: [String: (min: CGFloat, max: CGFloat)] = [:]
    static func catInk(_ state: String, _ cat: NSImage) -> (min: CGFloat, max: CGFloat) {
        if let c = catInkCache[state] { return c }
        let scale = 4, side = Int(catSize) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return (0, catSize) }
        rep.size = NSSize(width: catSize, height: catSize)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cat.draw(in: NSRect(x: 0, y: 0, width: catSize, height: catSize))
        NSGraphicsContext.restoreGraphicsState()
        var lo = side, hi = -1
        for x in 0..<side { for y in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { lo = min(lo, x); hi = max(hi, x); break } }
        let ink = hi < 0 ? (0, catSize) : (CGFloat(lo) / CGFloat(scale), CGFloat(hi + 1) / CGFloat(scale))
        catInkCache[state] = ink
        return ink
    }
    static func menuBarImage(state: String, description: String, time: String?, columns: [(caption: String, value: String)]) -> NSImage? {
        guard let cat = stateIcon(state, panel: false, description: description) else { return nil }
        if time == nil && columns.isEmpty { return cat }
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        // regular, not semibold: at 7.5 pt the heavier strokes merged into a blur; this matches Stats pixel for pixel
        let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        func attr(_ s: String, _ f: NSFont) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.black]) }
        let h = menuBarHeight
        // each item: its strings with their baselines, and the ink edges of the whole item from its origin
        typealias Line = (text: NSAttributedString, font: NSFont, baseline: CGFloat)
        var items: [(lines: [Line], ink: (min: CGFloat, max: CGFloat))] = []
        if let t = time {
            let a = attr(t, timeFont)
            // capitals centred on the bar, like the system's own menu bar text
            items.append(([(a, timeFont, ((h - timeFont.capHeight) / 2).rounded())], inkX(a)))
        }
        for c in columns {
            let v = attr(c.value, valueFont), k = attr(c.caption, captionFont)
            let iv = inkX(v), ik = inkX(k)
            // a column keeps room for two digits (three for the temperature, which keeps crossing 100° while
            // encoding), so a reading going from 12% to 9% does not move the cat; only 100% widens it
            let room = inkX(attr(String(repeating: "8", count: c.caption == "TEMP" ? 3 : 2) + String(c.value.last ?? "%"), valueFont)).max
            items.append(([(v, valueFont, 3), (k, captionFont, 14)], (min(iv.min, ik.min), max(iv.max, ik.max, room))))
        }
        let catInk = catInk(state, cat)
        var cursor = catInk.max   // right edge of the ink so far
        var origins: [CGFloat] = []
        for (n, item) in items.enumerated() {
            let x = cursor + (n == 0 && time != nil ? menuBarGap : menuBarItemGap) - item.ink.min
            origins.append(x)
            cursor = x + item.ink.max
        }
        let width = ceil(cursor + catInk.min)
        let image = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            cat.draw(in: NSRect(x: 0, y: (h - catSize) / 2, width: catSize, height: catSize))
            for (item, x) in zip(items, origins) {
                // draw(at:) puts the line's bottom, the descender, at y
                for l in item.lines { l.text.draw(at: NSPoint(x: x, y: l.baseline + l.font.descender)) }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = ([description] + [time].compactMap { $0 } + columns.map { "\($0.caption) \($0.value)" }).joined(separator: ", ")
        return image
    }

    func appendToLogFile(_ s: String) {
        let url = logFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let data = "\(f.string(from: Date()))  \(s)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    @objc func showLogFile() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) { appendToLogFile("Log file created") }
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    // MARK: Version and update check
    static let repo = "Interstellar0verdrive/Siesta"
    var currentVersion: String {
        if let i = CommandLine.arguments.firstIndex(of: "--version-override"), i + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[i + 1]      // hidden switch for testing the update path
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static let versionToGear: CGFloat = 5, gearToQuit: CGFloat = 8   // frame gaps for 7 and 9 pt of ink, measured in the render
    static let chipToStatus: CGFloat = 16, chipTopInset: CGFloat = 14, topInset: CGFloat = 22

    @objc func openAbout() {
        if let url = URL(string: "https://github.com/\(App.repo)") { NSWorkspace.shared.open(url) }
    }

    /// Shows or hides the update row; the panel grows only while it is there.
    func setUpdateChip(visible: Bool) {
        guard let row = updateRow, row.isHidden == visible else { return }
        row.isHidden = !visible
        panelColumn.edgeInsets.top = visible ? App.chipTopInset : App.topInset
        layoutPanel()
    }

    func showVersion() {
        updateURL = nil
        updateChip.busy = false
        setUpdateChip(visible: false)
    }

    func showUpdate(version: String, url: URL) {
        updateURL = url
        updateChip.title = "Update to \(version)"
        updateChip.busy = false
        updateChip.toolTip = canSelfUpdate && updateZip != nil
            ? "Download and install Siesta \(version) in place, then relaunch"
            : "Open the release page"
        setUpdateChip(visible: true)
    }

    /// Mentions a new release once per version: the chip alone is easy to miss. The alert is a plain
    /// window, not `runModal`: a modal session would stop the cycle timer (an encoder frozen for a rest
    /// would stay frozen until the alert is answered) and swallow Quit, logout and kill.
    var updateAlert: NSAlert?
    func announceUpdate(_ version: String) {
        guard announcedThisRun != version else { return }   // once per launch; "Later" means next launch
        announcedThisRun = version
        let alert = NSAlert()
        alert.icon = App.appArtwork()
        alert.messageText = "Siesta \(version) is available"
        alert.informativeText = canSelfUpdate && updateZip != nil
            ? "Click “Update to \(version)” at the top of the panel. Siesta downloads the new version, replaces itself and relaunches; macOS will not ask for approval again."
            : "Click “Update to \(version)” at the top of the panel to open the release page."
        alert.addButton(withTitle: canSelfUpdate && updateZip != nil ? "Update now" : "Open release page")
        alert.addButton(withTitle: "Later")
        alert.buttons[0].target = self; alert.buttons[0].action = #selector(openUpdate)
        alert.buttons[1].target = self; alert.buttons[1].action = #selector(dismissUpdateAlert)
        alert.layout()
        updateAlert?.window.orderOut(nil)
        updateAlert = alert
        alert.window.level = .modalPanel
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc func dismissUpdateAlert() {
        updateAlert?.window.orderOut(nil)
        updateAlert = nil
    }

    @objc func openUpdate() {
        dismissUpdateAlert()
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
        updateVersionRow()
        updateChip.title = text
        updateChip.busy = true
        updateChip.toolTip = nil
    }

    func updateFailed(_ reason: String) {
        updating = false
        defer { updateVersionRow() }
        log("Update failed: \(reason)")
        if let url = updateURL { showUpdate(version: updateVersion, url: url) }
    }

    func performUpdate() {
        guard let zipURL = updateZip, let shaURL = updateSha, !updating else { return }
        updating = true
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
        guard !checking, !updating, let url = URL(string: "https://api.github.com/repos/\(App.repo)/releases/latest") else { return }
        checking = true
        updateVersionRow()
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                DispatchQueue.main.async {
                    self.checking = false
                    self.lastCheck = (Date(), "failed")
                    self.updateVersionRow()
                }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            func asset(_ suffix: String) -> URL? {
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            }
            let zip = asset(".zip"), sha = asset(".zip.sha256")
            DispatchQueue.main.async {
                self.checking = false
                self.lastCheck = (Date(), "ok")
                defer { self.updateVersionRow() }
                guard !self.updating else { return }
                if self.isNewer(latest, than: self.currentVersion) {
                    self.updateZip = zip; self.updateSha = sha; self.updateVersion = latest
                    self.showUpdate(version: latest, url: page)
                    if self.flag("autoInstall", false) && self.canSelfUpdate && zip != nil && sha != nil {
                        // never in the middle of a cycle: a relaunch would stop it; wait for the cycle to stop
                        if self.phase == .stopped { self.log("Installing Siesta \(latest) automatically"); self.performUpdate() }
                        else { self.pendingAutoInstall = true }
                    } else { self.announceUpdate(latest) }
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
            autoStartArmed = false   // stopped by hand while encoding: wait for the encoder to go idle first
            autoBusySeconds = 0; autoIdleSeconds = 0
            if pendingAutoInstall {
                pendingAutoInstall = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.performUpdate() }
            }
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
    let sampler = ProcessSampler(marker: target.bundleMarker)

    /// Every process belonging to the target app: the UI and the workers that do the real encoding.
    /// Called once per tick (and once at launch): the CPU of each call covers the time since the previous one.
    func targetProcesses() -> [Proc] { sampler.sample() }

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
        // each tick measures only its own second: a chart point is the mean of the ticks since the last one
        cpuSum += percentOfMachine(rawCpu); cpuTicks += 1
        if let g = gpuMeter.read() { gpuSum += g; gpuTicks += 1 }
        let t = Date.timeIntervalSinceReferenceDate
        if phase == .resting || rawCpu >= threshold { lastBusy = t }   // really working (or resting), not just within the grace
        let chartNow = t - heldTime
        // dense while the chart is still filling its first 5 minutes, then one point every 5 s
        let every: TimeInterval = (chart.samples.first.map { chartNow - $0.t } ?? 0) < chart.minWindow ? 1 : 5
        if let last = latestReading?.t, t - last < every - 0.5 { return }
        let cpu = cpuSum / Double(cpuTicks)
        cpuSum = 0; cpuTicks = 0
        let gpu: Double? = gpuTicks > 0 ? gpuSum / Double(gpuTicks) : nil
        gpuSum = 0; gpuTicks = 0
        let temp = thermometer.hottest()
        latestReading = Sample(t: t, cpu: cpu, temp: temp, resting: phase == .resting, gpu: gpu)
        // "Hold the chart while idle": no new points while the encoder is not working, so the chart stands
        // still; when work comes back the idle stretch is cut out and the line carries on where it stopped.
        // Working means busy now, whether or not a cycle runs (Start automatically waits a few seconds).
        let working = phase == .resting || (phase == .working && isEncoding) || rawCpu >= threshold
        if flag("holdChart", false) && !working {
            // the hold starts: the flat tail recorded after the real stop goes, the break sits where work stopped
            if !holding, let busy = lastBusy {
                let n = ChartView.idleTail(chart.samples, lastBusy: busy)
                if n > 0 {
                    chart.samples.removeLast(n); chart.needsDisplay = true
                    if debugSamples { debugPrint("TRIM \(n) idle sample\(n == 1 ? "" : "s") after the last work") }
                }
            }
            if let lastT = chart.samples.last?.t, chartNow - lastT > every + 5 { chart.holding = true }
            if debugSamples { debugPrint(String(format: "HELD cpu %.1f%% (raw %.0f, threshold %.0f)  phase %@", cpu, rawCpu, threshold, "\(phase)")) }
            holding = true; return
        }
        var cut = false
        if holding {
            holding = false
            // a held moment of a few seconds (a thawed encoder's first, low reading) is no stretch worth a seam
            // the first sample after the cut goes right after the last one before it: the strip
            // drawn between them then starts where the line ends and the line resumes where it ends
            if let lastT = chart.samples.last?.t, chartNow - lastT > every + 5 {
                heldTime += chartNow - lastT - 0.01
                cut = true
            }
        }
        chart.holding = false
        chart.samples.append(Sample(t: t - heldTime, cpu: cpu, temp: temp, resting: phase == .resting, clock: t, cut: cut, gpu: gpu))
        if debugSamples, let s = chart.samples.last {
            debugPrint(String(format: "SAMPLE cpu %.1f%% of the Mac (%.0f%% of one core)  gpu %@  temp %@  %@  phase %@  n %d  held %.0f s%@", s.cpu, s.cpu * coreCount,
                              s.gpu.map { String(format: "%.1f%%", $0) } ?? "n/a",
                              s.temp.map { String(format: "%.1f °C", $0) } ?? "n/a", s.resting ? "resting" : "working", "\(phase)",
                              chart.samples.count, heldTime, s.cut ? "  CUT" : ""))
        }
        chart.noteNewSample()
        if let first = chart.samples.first?.t, t - heldTime - first > chart.maxWindow + 60 {
            chart.samples.removeFirst(chart.samples.count / 10)   // trim in chunks, cheap
        }
        // folded: refresh the header values only every 5 s, the data keeps its own cadence
        if !chart.isHidden && (!chart.collapsed || t - lastCollapsedRefresh >= 5) {
            chart.needsDisplay = true
            lastCollapsedRefresh = t
        }
    }
    var lastCollapsedRefresh: TimeInterval = 0
    var cpuSum = 0.0, cpuTicks = 0
    var gpuSum = 0.0, gpuTicks = 0
    /// Idle time cut out of the chart so far, and whether an idle stretch is being held right now.
    var heldTime: TimeInterval = 0, holding = false
    /// Wall clock of the last tick the encoder was really working (or frozen in a rest).
    var lastBusy: TimeInterval?

    func tick() {
        let now = Date()
        let dt = min(5, now.timeIntervalSince(lastTick))
        lastTick = now
        switch phase {
        case .stopped:
            let total = targetProcesses().reduce(0) { $0 + $1.cpu }
            record(cpu: total)
            // "Start automatically": a few seconds of real work after the encoder was last seen idle
            if flag("autoStart", false) {
                // re-armed only by real idle time: the first reading after a frozen encoder is thawed is low
                // (it slept through most of the second), and a gap between queue items is not the end either
                if total >= threshold { autoBusySeconds += dt; autoIdleSeconds = 0 }
                else { autoBusySeconds = 0; autoIdleSeconds += dt; if autoIdleSeconds >= idleGrace { autoStartArmed = true } }
                if autoStartArmed && autoBusySeconds >= 3 {
                    autoStartArmed = false; autoBusySeconds = 0
                    log("\(target.name) started working · cycle started automatically")
                    toggleRun()
                    return
                }
            }
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

    /// `--debug-samples`: every log line and chart point also goes to stdout, for checking the numbers in a test run.
    let debugSamples = CommandLine.arguments.contains("--debug-samples")
    func debugPrint(_ s: String) {
        guard debugSamples || debugLogAnimation || debugPageAnimation else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        print("\(f.string(from: Date())) \(s)"); fflush(stdout)
    }

    func log(_ s: String) {
        debugPrint("LOG " + s)
        if App.scene == nil && flag("logFile", false) { appendToLogFile(s) }
        if logCount == 0 { logView.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 46)]
        para.headIndent = 46; para.paragraphSpacing = 4
        let line = NSMutableAttributedString(string: "\(f.string(from: clockNow()))\t\(s)\n", attributes: [
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
        let parts = menuBarParts(time: barTitle)
        statusItem.button?.image = App.menuBarImage(state: state, description: description, time: parts.time, columns: parts.columns)
        statusItem.button?.title = ""
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
            let untilPause = max(0, (pausePlanned ?? clockNow().addingTimeInterval(total - elapsed)).timeIntervalSince(clockNow()))
            progress.value = isEncoding ? elapsed / max(1, elapsed + untilPause) : progress.value
            progressLabel.stringValue = "Work interval"
            progressDetail.stringValue = "\(Int(elapsed / 60)) of \(Int(workMinutes)) min elapsed"
            if isEncoding {
                let eta = f.string(from: pausePlanned ?? clockNow().addingTimeInterval(total - elapsed))
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
            let elapsed = min(clockNow().timeIntervalSince(restStart), total)
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

if CommandLine.arguments.contains("--debug-sensors") { TemperatureReader.dump(); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--debug-menubar"), i + 1 < CommandLine.arguments.count {
    // the menu bar item for a few combinations, white on a dark bar and black on a light one, at 4x, into one PNG
    let rows: [(String?, [(caption: String, value: String)])] = [
        ("12m", []), ("12m", [("CPU", "83%"), ("TEMP", "99°")]), ("12m", [("CPU", "86%"), ("GPU", "12%"), ("TEMP", "98°")]), (nil, [("CPU", "0%"), ("TEMP", "44°")]),
        (nil, [("CPU", "0%")]), (nil, [("GPU", "78%")]), (nil, [("TEMP", "50°")]), ("4m", [("CPU", "100%")])]
    let scale: CGFloat = 4, rowH: CGFloat = 30, w: CGFloat = 220
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2 * scale), pixelsHigh: Int(rowH * CGFloat(rows.count) * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w * 2, height: rowH * CGFloat(rows.count))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (k, dark) in [true, false].enumerated() {
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        NSRect(x: CGFloat(k) * w, y: 0, width: w, height: rowH * CGFloat(rows.count)).fill()
        for (j, r) in rows.enumerated() {
            guard let img = App.menuBarImage(state: "working", description: "Working", time: r.0, columns: r.1) else { continue }
            let y = rowH * CGFloat(rows.count - 1 - j) + (rowH - App.menuBarHeight) / 2
            let tinted = NSImage(size: img.size, flipped: false) { rect in img.draw(in: rect); (dark ? NSColor.white : NSColor.black).set(); rect.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: CGFloat(k) * w + 10, y: y, width: img.size.width, height: img.size.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--debug-chart"), i + 1 < CommandLine.arguments.count {
    // renders the chart off screen on 6 hours of synthetic data (15 min work, 1 min rest), at several
    // zoom levels, straight lines on the left and smooth curves on the right, into one PNG
    var seed: UInt64 = 42
    func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) - 0.5 }
    let end = Date.timeIntervalSinceReferenceDate, start = end - 6 * 3600
    var samples: [Sample] = [], temp = 60.0, load = 80.0
    for t in stride(from: start, through: end, by: 5) {
        let resting = Int((t - start) / 60) % 16 == 15
        load = min(95, max(55, load + noise() * 8))
        temp += ((resting ? 53 : 104) - temp) * (resting ? 0.22 : 0.3) + noise() * 2.5
        samples.append(Sample(t: t, cpu: resting ? 0 : load, temp: temp, resting: resting))
    }
    let width: CGFloat = 380, spans: [TimeInterval] = [6 * 3600, 3600, 15 * 60, 3 * 60]
    let probe = ChartView()
    let cell = NSSize(width: width, height: probe.fullHeight), pad: CGFloat = 24
    let sheet = NSImage(size: NSSize(width: cell.width * 2 + pad * 3, height: (cell.height + pad) * CGFloat(spans.count) + pad))
    let dark = NSAppearance(named: .darkAqua)!
    sheet.lockFocus()
    NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
    for (row, span) in spans.enumerated() {
        for (col, smooth) in [false, true].enumerated() {
            let chart = ChartView()
            chart.appearance = dark
            chart.frame = NSRect(origin: .zero, size: cell)
            chart.samples = samples; chart.smoothCurves = smooth
            chart.view = (end - span, span); chart.followNow = true
            chart.layoutSubtreeIfNeeded()
            guard let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) else { continue }
            dark.performAsCurrentDrawingAppearance { chart.cacheDisplay(in: chart.bounds, to: rep) }
            let origin = NSPoint(x: pad + CGFloat(col) * (cell.width + pad), y: sheet.size.height - CGFloat(row + 1) * (cell.height + pad))
            NSColor(white: 0.17, alpha: 1).setFill(); NSRect(origin: origin, size: cell).fill()   // the dark popover
            rep.draw(in: NSRect(origin: origin, size: cell), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if let png = rep.representation(using: .png, properties: [:]) {   // each cell on its own too, transparent
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension()
                    .appendingPathExtension("\(Int(span / 60))min-\(smooth ? "smooth" : "straight").png"))
            }
            let label = "\(span >= 3600 ? "\(Int(span / 3600)) h" : "\(Int(span / 60)) min") · \(smooth ? "smooth curves" : "straight lines")"
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
                .draw(at: NSPoint(x: origin.x, y: origin.y + cell.height + 4))
        }
    }
    sheet.unlockFocus()
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: out); print("Wrote \(out.path)")
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--debug-legend"), i + 1 < CommandLine.arguments.count {
    // the chart in each legend state, light and dark, one PNG per state (2x)
    let end = Date.timeIntervalSinceReferenceDate
    let samples = stride(from: end - 6 * 3600, through: end, by: 5).map { t in
        Sample(t: t, cpu: 80 + 8 * sin(t / 300), temp: 100 + 4 * sin(t / 200), resting: Int(t / 60) % 16 == 15)
    }
    let states: [(String, (start: TimeInterval, span: TimeInterval)?, Bool)] = [
        ("auto", nil, false), ("zoomed", (end - 18 * 60, 18 * 60), false), ("zoomed-hover", (end - 18 * 60, 18 * 60), true),
        ("panned", (end - 3 * 3600, 90 * 60), false), ("collapsed", nil, false)]
    for (name, view, hover) in states {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let chart = ChartView()
            chart.appearance = appearance
            chart.frame = NSRect(x: 0, y: 0, width: 380, height: chart.fullHeight)
            chart.samples = samples
            chart.view = view; chart.followNow = view.map { $0.start + $0.span >= end - 1 } ?? true
            chart.collapsed = name == "collapsed"
            chart.showReset(view != nil, animated: false)
            chart.resetButton.hovered = hover
            // inside an off-screen window, as in the app: without one Auto Layout never updates the frames
            let host = NSWindow(contentRect: chart.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            host.appearance = appearance
            host.contentView = chart
            // a first pass sets the legend text; after layout, the real one on a clean bitmap
            appearance.performAsCurrentDrawingAppearance { chart.cacheDisplay(in: chart.bounds, to: chart.bitmapImageRepForCachingDisplay(in: chart.bounds)!) }
            chart.layoutSubtreeIfNeeded()
            let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds)!
            appearance.performAsCurrentDrawingAppearance { chart.cacheDisplay(in: chart.bounds, to: rep) }
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension()
                .appendingPathExtension("\(name)-\(dark ? "dark" : "light").png")
            let image = NSImage(size: chart.bounds.size)      // on the popover's own background
            image.lockFocus()
            NSColor(white: dark ? 0.17 : 0.93, alpha: 1).setFill(); chart.bounds.fill()
            rep.draw(in: chart.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            image.unlockFocus()
            if let tiff = image.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: out) }
            print(out.lastPathComponent, "title x", chart.header.convert(NSPoint.zero, to: chart).x, "intrinsic", chart.legend.intrinsicContentSize, "legend frame", chart.legend.frame, "reset frame", chart.resetButton.frame,
                  "legend text", chart.legend.attributedStringValue.string)
        }
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--debug-hold"), i + 1 < CommandLine.arguments.count {
    // "Hold the chart while idle": 105 s idle, held for 140 s, then work; the idle stretch is cut out,
    // the axis keeps the real times. Dark, as in the popover (add `light` for the light one).
    let t0 = Calendar.current.date(bySettingHour: 21, minute: 59, second: 0, of: Date())!.timeIntervalSinceReferenceDate
    var samples: [Sample] = []
    for k in 0...105 { let t = t0 + Double(k); samples.append(Sample(t: t, cpu: 3, temp: 62 + 8 * sin(Double(k) / 7), resting: false)) }
    let held = 140.0
    // `fresh`: work has only just come back (two seconds after the cut); `held`: still idle, nothing after it
    for k in 106...(CommandLine.arguments.contains("fresh") ? 107 : 130) where !CommandLine.arguments.contains("held") {
        samples.append(Sample(t: t0 + Double(k) - 0.99, cpu: 40 + Double(k - 106), temp: 90 + Double(k - 106) * 0.7, resting: false, clock: t0 + Double(k) + held, cut: k == 106)) }
    let chart = ChartView()
    chart.frame = NSRect(x: 0, y: 0, width: 380, height: chart.fullHeight)
    chart.samples = samples
    chart.holding = CommandLine.arguments.contains("held")
    // `--debug-hover-x <pt>`: the pointer at that x (`no-magnet`: with magnetic edges off)
    let hoverAtX = CommandLine.arguments.firstIndex(of: "--debug-hover-x").flatMap { Double(CommandLine.arguments[$0 + 1]) }.map { CGFloat($0) }
    chart.magneticBands = !CommandLine.arguments.contains("no-magnet")
    let light = CommandLine.arguments.contains("light")
    let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!
    let host = NSWindow(contentRect: chart.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    host.appearance = appearance; host.contentView = chart
    appearance.performAsCurrentDrawingAppearance { chart.cacheDisplay(in: chart.bounds, to: chart.bitmapImageRepForCachingDisplay(in: chart.bounds)!) }
    chart.layoutSubtreeIfNeeded()
    if let hx = hoverAtX { chart.hoverX = hx; chart.hoverT = chart.time(atX: hx) }
    let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds)!
    appearance.performAsCurrentDrawingAppearance { chart.cacheDisplay(in: chart.bounds, to: rep) }
    let image = NSImage(size: chart.bounds.size)
    image.lockFocus()
    NSColor(white: light ? 0.93 : 0.17, alpha: 1).setFill(); chart.bounds.fill()
    rep.draw(in: chart.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    image.unlockFocus()
    if let tiff = image.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}
if CommandLine.arguments.contains("--debug-trim") {
    // the idle tail dropped when the chart starts holding: one point every 5 s
    func run(_ name: String, rest: Range<Double>?, stop: Double, recordedUntil: Double, lastBusy: Double) {
        let samples = stride(from: 0.0, through: recordedUntil, by: 5).map { t in Sample(t: t, cpu: t <= stop ? 80 : 0, temp: 70, resting: rest?.contains(t) ?? false) }
        let n = ChartView.idleTail(samples, lastBusy: lastBusy)
        let kept = samples.dropLast(n)
        print(String(format: "%@: last busy %.0f s, recorded to %.0f s → drop %d, chart ends at %.0f s (%@)", name, lastBusy, recordedUntil, n,
                     kept.last!.t, kept.last!.resting ? "resting" : "working"))
    }
    run("HandBrake paused during a rest (rest 60–120 s)", rest: 60..<120, stop: 59, recordedUntil: 130, lastBusy: 119)
    run("HandBrake stops while working at 47 s", rest: nil, stop: 47, recordedUntil: 57, lastBusy: 47)
    run("stops on a sample (45 s)", rest: nil, stop: 45, recordedUntil: 55, lastBusy: 45)
    run("no tail (held right away)", rest: nil, stop: 50, recordedUntil: 55, lastBusy: 52)
    exit(0)
}
if CommandLine.arguments.contains("--debug-magnet") {
    // one point every 5 s: work 0–55 s, rest 60–115 s, work again from 120 s; 0.5 s per pixel
    let samples = stride(from: 0.0, through: 180, by: 5).map { t in
        Sample(t: t, cpu: (60..<120).contains(t) ? 0 : 80, temp: 70 + t / 10, resting: (60..<120).contains(t))
    }
    for t in [45.0, 56, 57, 58, 60, 62, 63, 64, 90, 115, 117, 118, 120, 123, 124, 140] {
        let s = ChartView.magnet(samples, at: t, secondsPerPixel: 0.5)
        print(String(format: "cursor %5.1f s (%+5.1f px from the nearest edge) → %@", t,
                     ([60.0, 120].map { ($0 - t) / -0.5 }.min { abs($0) < abs($1) })!,
                     s.map { String(format: "line on %.0f s, values of %.0f s (%@, CPU %.0f%%)", $0.edge, $0.sample.t, $0.sample.resting ? "resting" : "working", $0.sample.cpu) } ?? "no snap"))
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
