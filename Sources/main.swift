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
    let scroll = NSScrollView()
    let list = NSTextView()
    var onToggle: (() -> Void)?

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
        let row = NSStackView(views: [chevron, title, NSView(), count])
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
    let workBox = NumberBox()
    let restBox = NumberBox()
    var workField: NSTextField { workBox.field }
    var restField: NSTextField { restBox.field }
    let runButton = FlatButton(title: "Start cycle", primary: true)
    let detachCheckbox = NSButton(checkboxWithTitle: "Detached window", target: nil, action: nil)
    let logBox = LogBoxView()
    var logView: NSTextView { logBox.list }
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
            popover.appearance = NSApp.appearance
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
        runButton.keyEquivalent = "\r"
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

        // Footer: secondary quit button, right aligned
        let quitButton = FlatButton(title: "Quit Siesta", primary: false)
        quitButton.target = self; quitButton.action = #selector(quit)
        quitButton.setAccessibilityLabel("Quit Siesta")
        let footer = NSStackView(views: [detachCheckbox, NSView(), quitButton])
        footer.orientation = .horizontal; footer.alignment = .centerY

        let column = NSStackView(views: [statusRow, progressWrap, divider(), settings, divider(), logBox, footer])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 19
        column.setCustomSpacing(19, after: progressWrap)
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false
        // the column does not stretch a stack with intrinsic width by itself: pin it to the edges
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 24),
            settings.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -24),
        ])

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

    /// Recomputes the panel size after a layout change (log toggled, mode switched).
    func layoutPanel() {
        logBox.expanded = logExpanded
        logBox.count.stringValue = logCount == 0 ? "no events yet" : "\(logCount) event\(logCount == 1 ? "" : "s")"
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
                window = w
            }
            window!.contentViewController = panelController
            layoutPanel()
            if !window!.isVisible { window!.center() }
            NSApp.activate(ignoringOtherApps: true)
            window!.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        } else {
            window?.orderOut(nil)
            window?.contentViewController = nil
            popover.contentViewController = panelController
            layoutPanel()
            popover.contentSize = panelController.view.fittingSize
            guard let button = statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in self?.panelController.view.window?.makeFirstResponder(nil) }
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
        guard let field = n.object as? NSTextField else { return }
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
        logBox.count.stringValue = "\(logCount) event\(logCount == 1 ? "" : "s")"
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
