import AppKit

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

let popoverWidth: CGFloat = 430
let windowWidth: CGFloat = 570

/// Panel background: a click on empty space drops focus from a text field and commits its value.
final class BackgroundView: NSView {
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

/// Fully clickable header of the activity log: chevron, title, event count, with its own fill and border.
final class LogHeaderView: NSView {
    let chevron = NSImageView()
    let title = NSTextField(labelWithString: "Activity log")
    let count = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        title.font = .systemFont(ofSize: 13, weight: .medium)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        let row = NSStackView(views: [chevron, title, NSView(), count])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    var expanded = false {
        didSet {
            chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                    accessibilityDescription: expanded ? "Collapse activity log" : "Expand activity log")
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Secondary button with a subtle fill and border, as in the prototype footer.
final class SecondaryButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        font = .systemFont(ofSize: 12, weight: .medium)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 24, height: 30)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.08).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
    }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
}

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    // MARK: UI
    var statusItem: NSStatusItem!
    let panelController = NSViewController()
    let popover = NSPopover()
    var window: NSWindow?
    var panelWidth: NSLayoutConstraint!

    let statusSymbol = NSImageView()
    let statusTitle = NSTextField(labelWithString: "")
    let statusSubtitle = NSTextField(labelWithString: "")
    let countdown = NSTextField(labelWithString: "")
    let progressWrap = NSStackView()
    let progress = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")
    let progressDetail = NSTextField(labelWithString: "")
    let workField = NSTextField()
    let restField = NSTextField()
    let runButton = NSButton(title: "Start cycle", target: nil, action: nil)
    let detachCheckbox = NSButton(checkboxWithTitle: "Detached window", target: nil, action: nil)
    let activityHeader = LogHeaderView()
    let logScroll = NSScrollView()
    let logView = NSTextView()
    var logExpanded = false
    var logCount = 0

    // MARK: State
    var timer: Timer?
    var phase: Phase = .stopped
    var lastTick = Date()
    var workSeconds: Double = 0      // seconds of real encoding accumulated
    var idleSeconds: Double = 0      // consecutive seconds without encoding
    var restStart = Date()
    var isEncoding = false
    var frozenPids: [pid_t] = []
    let defaults = UserDefaults.standard
    var threshold: Double { defaults.object(forKey: "threshold") == nil ? 50.0 : defaults.double(forKey: "threshold") }
    var workMinutes: Double { max(1, Double(workField.integerValue)) }
    var restMinutes: Double { max(1, Double(restField.integerValue)) }
    var detached: Bool { defaults.bool(forKey: "window") }

    static let standbyIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "SiestaStandby", withExtension: "pdf"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.accessibilityDescription = "Siesta in standby"
        return img
    }()

    static let inactiveIcon: NSImage? = {
        let img = NSImage(named: "SiestaInactive")
        img?.isTemplate = true
        img?.accessibilityDescription = "Siesta inactive"
        return img
    }()

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ n: Notification) {
        // Hidden switch for checking both appearances: --appearance light|dark
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.imagePosition = .imageLeft
        buildPanel()
        let w = defaults.integer(forKey: "work"), r = defaults.integer(forKey: "rest")
        workField.integerValue = w == 0 ? 60 : w
        restField.integerValue = r == 0 ? 5 : r
        detachCheckbox.state = detached ? .on : .off
        logExpanded = detached
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        refresh()
        if CommandLine.arguments.contains("--start") { toggleRun() }
        // The status item must be laid out before a popover can attach to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel() }
    }

    func applicationWillTerminate(_ n: Notification) { resume() }

    // MARK: Panel construction
    func divider() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    func buildPanel() {
        // Status row: symbol, title + subtitle, big countdown on the right
        statusSymbol.imageScaling = .scaleProportionallyUpOrDown
        statusSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
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
        progressWrap.orientation = .vertical; progressWrap.alignment = .width; progressWrap.spacing = 4

        // Settings grid: labels on the left, field + unit flush right
        func numberField(_ field: NSTextField, _ label: String) -> NSView {
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
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
            let s = NSStackView(views: [field, unit]); s.orientation = .horizontal; s.spacing = 9
            return s
        }
        let workLabel = NSTextField(labelWithString: "Work"); workLabel.font = .systemFont(ofSize: 14)
        let restLabel = NSTextField(labelWithString: "Rest"); restLabel.font = .systemFont(ofSize: 14)
        let grid = NSGridView(views: [[workLabel, numberField(workField, "Work minutes")],
                                      [restLabel, numberField(restField, "Rest minutes")]])
        grid.rowSpacing = 13; grid.columnSpacing = 12
        grid.column(at: 1).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        // Actions: primary run button, detach checkbox on the right
        runButton.target = self; runButton.action = #selector(toggleRun)
        runButton.bezelStyle = .rounded; runButton.keyEquivalent = "\r"
        runButton.controlSize = .large
        detachCheckbox.target = self; detachCheckbox.action = #selector(toggleDetached)
        let actions = NSStackView(views: [runButton, NSView(), detachCheckbox])
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 12

        // Activity log: fully clickable header with chevron, collapsible list
        activityHeader.onClick = { [weak self] in self?.toggleLog() }
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        logView.textContainerInset = NSSize(width: 2, height: 6)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logScroll.documentView = logView

        // Footer: secondary quit button, right aligned
        let quitButton = SecondaryButton(frame: .zero)
        quitButton.title = "Quit Siesta"
        quitButton.target = self; quitButton.action = #selector(quit)
        quitButton.setAccessibilityLabel("Quit Siesta")
        let footer = NSStackView(views: [NSView(), quitButton])
        footer.orientation = .horizontal

        let column = NSStackView(views: [statusRow, progressWrap, divider(), grid, actions, divider(), activityHeader, logScroll, footer])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 19
        column.setCustomSpacing(19, after: progressWrap)
        column.setCustomSpacing(23, after: grid)
        column.setCustomSpacing(19, after: actions)
        column.setCustomSpacing(10, after: activityHeader)
        column.setCustomSpacing(16, after: logScroll)
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false
        let background = BackgroundView()
        background.addSubview(column)
        panelWidth = background.widthAnchor.constraint(equalToConstant: popoverWidth)
        panelWidth.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: background.topAnchor),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            panelWidth,
        ])
        background.autoresizingMask = [.width, .height]   // follow the popover / window content area
        panelController.view = background
        showPlaceholder()
        popover.behavior = .transient
        popover.animates = true
    }

    /// Recomputes the panel size after a layout change (log toggled, mode switched).
    func layoutPanel() {
        logScroll.isHidden = !logExpanded
        activityHeader.expanded = logExpanded
        activityHeader.count.stringValue = logCount == 0 ? "no events yet" : "\(logCount) event\(logCount == 1 ? "" : "s")"
        panelWidth.constant = detached ? windowWidth : popoverWidth
        let size = panelController.view.fittingSize
        panelController.view.frame = NSRect(origin: .zero, size: size)
        if detached, let w = window, w.contentViewController === panelController {
            w.setContentSize(size)
        } else {
            popover.contentSize = size
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
                window = w
            }
            window!.contentViewController = panelController
            layoutPanel()
            if !window!.isVisible { window!.center() }
            NSApp.activate(ignoringOtherApps: true)
            window!.makeKeyAndOrderFront(nil)
        } else {
            window?.orderOut(nil)
            window?.contentViewController = nil
            popover.contentViewController = panelController
            layoutPanel()
            popover.contentSize = panelController.view.fittingSize
            guard let button = statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleRun() {
        panelController.view.window?.makeFirstResponder(nil)
        if phase == .stopped {
            defaults.set(workField.integerValue, forKey: "work")
            defaults.set(restField.integerValue, forKey: "rest")
            phase = .working
            workSeconds = 0; idleSeconds = 0; isEncoding = false
            lastTick = Date()
            log("Cycle started · \(Int(workMinutes)) min work, \(Int(restMinutes)) min rest")
        } else {
            resume()
            phase = .stopped
            log("Cycle stopped")
        }
        refresh()
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField else { return }
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
    struct Proc { let pid: pid_t; let cpu: Double; let path: String }

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
        let out = run("/bin/ps", ["-o", "pid=,%cpu=,comm=", "-p", pids.joined(separator: ",")])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]),
                  parts[2].contains(target.bundleMarker) else { return nil }
            return Proc(pid: pid, cpu: cpu, path: parts[2])
        }
    }

    func resume() {
        for pid in frozenPids { kill(pid, SIGCONT) }
        frozenPids = []
    }

    // MARK: Loop
    func tick() {
        let now = Date()
        let dt = min(5, now.timeIntervalSince(lastTick))
        lastTick = now
        switch phase {
        case .stopped:
            break
        case .working:
            let procs = targetProcesses()
            let totalCpu = procs.reduce(0) { $0 + $1.cpu }
            let encoding = !procs.isEmpty && totalCpu >= threshold
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
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]))
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
        activityHeader.count.stringValue = "\(logCount) event\(logCount == 1 ? "" : "s")"
    }

    func setStatus(symbol: NSImage?, panelSymbol: NSImage? = nil, title: String, subtitle: String, count: String, tooltip: String, barTitle: String) {
        statusSymbol.image = panelSymbol ?? symbol
        statusSymbol.contentTintColor = panelSymbol == nil ? nil : NSColor.labelColor.withAlphaComponent(0.82)
        statusTitle.stringValue = title
        statusSubtitle.stringValue = subtitle
        countdown.stringValue = count
        statusItem.button?.image = symbol
        statusItem.button?.title = barTitle.isEmpty ? "" : " " + barTitle
        statusItem.button?.toolTip = "Siesta — " + tooltip
    }

    func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    func refresh() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let hideProgress = phase == .stopped
        if progressWrap.isHidden != hideProgress {
            progressWrap.isHidden = hideProgress
            layoutPanel()          // the panel height changed
        }
        switch phase {
        case .stopped:
            setStatus(symbol: App.inactiveIcon, panelSymbol: App.standbyIcon, title: "Cycle stopped",
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
                setStatus(symbol: symbol("play.circle.fill", "Working"), title: "\(target.name) is working",
                          subtitle: "Next pause", count: "\(left)m",
                          tooltip: "\(target.name) is working, pause in \(left) min", barTitle: "\(left)m")
            } else {
                setStatus(symbol: symbol("hourglass", "Waiting"), title: "Waiting for \(target.name)",
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
            setStatus(symbol: symbol("pause.circle.fill", "Resting"), title: "\(target.name) is resting",
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
