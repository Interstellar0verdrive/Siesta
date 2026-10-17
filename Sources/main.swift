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

/// Panel background: a click on empty space drops focus from a text field and commits its value.
final class BackgroundView: NSView {
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    // UI
    var statusItem: NSStatusItem!
    let panelController = NSViewController()
    let popover = NSPopover()
    var window: NSWindow?
    let workField = NSTextField()
    let restField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "Stopped")
    let startButton = NSButton(title: "Start", target: nil, action: nil)
    let windowCheckbox = NSButton(checkboxWithTitle: "Detached window", target: nil, action: nil)
    let logView = NSTextView()

    // State
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
    var detachedWindow: Bool { defaults.bool(forKey: "window") }

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.imagePosition = .imageLeft
        buildPanel()
        let w = defaults.integer(forKey: "work"), r = defaults.integer(forKey: "rest")
        workField.integerValue = w == 0 ? 60 : w
        restField.integerValue = r == 0 ? 5 : r
        windowCheckbox.state = detachedWindow ? .on : .off
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        refresh()
        if CommandLine.arguments.contains("--start") { toggleStart() }
        // The status item must be laid out before a popover can attach to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel() }
    }

    func applicationWillTerminate(_ n: Notification) { resume() }

    // MARK: Panel
    func buildPanel() {
        func row(_ text: String, _ field: NSTextField) -> NSStackView {
            let label = NSTextField(labelWithString: text)
            label.widthAnchor.constraint(equalToConstant: 130).isActive = true
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
            field.alignment = .right
            let f = NumberFormatter(); f.minimum = 1; f.maximum = 1440; f.allowsFloats = false
            field.formatter = f
            field.delegate = self
            let s = NSStackView(views: [label, field, NSTextField(labelWithString: "min")])
            s.orientation = .horizontal; s.spacing = 8
            return s
        }

        startButton.target = self; startButton.action = #selector(toggleStart)
        startButton.bezelStyle = .rounded; startButton.keyEquivalent = "\r"
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        windowCheckbox.target = self; windowCheckbox.action = #selector(toggleWindowMode)
        let buttons = NSStackView(views: [startButton, quitButton, NSView(), windowCheckbox])
        buttons.orientation = .horizontal; buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: 320).isActive = true

        statusLabel.font = .boldSystemFont(ofSize: 13)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        logView.isEditable = false
        logView.backgroundColor = .textBackgroundColor
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = logView

        let column = NSStackView(views: [row("Work minutes", workField),
                                         row("Rest minutes", restField),
                                         statusLabel, buttons, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .gravityAreas
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false

        let background = BackgroundView()
        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: background.topAnchor),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        background.widthAnchor.constraint(equalToConstant: 360).isActive = true
        background.heightAnchor.constraint(equalToConstant: 300).isActive = true
        background.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        panelController.view = background
        popover.behavior = .transient
        popover.animates = true
    }

    // MARK: Popover / window
    @objc func statusItemClicked() {
        if detachedWindow { showPanel() }
        else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    func showPanel() {
        if detachedWindow {
            if popover.isShown { popover.performClose(nil) }
            popover.contentViewController = nil
            if window == nil {
                let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Siesta"
                w.isReleasedWhenClosed = false
                window = w
            }
            window!.contentViewController = panelController
            window!.setContentSize(NSSize(width: 360, height: 300))
            if !window!.isVisible { window!.center() }
            NSApp.activate(ignoringOtherApps: true)
            window!.makeKeyAndOrderFront(nil)
        } else {
            window?.orderOut(nil)
            window?.contentViewController = nil
            popover.contentViewController = panelController
            popover.contentSize = NSSize(width: 360, height: 300)
            guard let button = statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func toggleWindowMode() {
        defaults.set(windowCheckbox.state == .on, forKey: "window")
        showPanel()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleStart() {
        panelController.view.window?.makeFirstResponder(nil)
        if phase == .stopped {
            defaults.set(workField.integerValue, forKey: "work")
            defaults.set(restField.integerValue, forKey: "rest")
            phase = .working
            workSeconds = 0; idleSeconds = 0; isEncoding = false
            lastTick = Date()
            log("Started: \(Int(workMinutes)) min work, \(Int(restMinutes)) min rest")
        } else {
            resume()
            phase = .stopped
            log("Stopped")
        }
        refresh()
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField else { return }
        let key = field === workField ? "work" : "rest"
        let name = field === workField ? "Work minutes" : "Rest minutes"
        let old = defaults.integer(forKey: key)
        let new = max(1, field.integerValue)
        field.integerValue = new
        if new != old {
            defaults.set(new, forKey: key)
            log("\(name): \(old) → \(new)")
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
                    (procs.isEmpty ? "\(target.name) is not running" : "\(target.name) is idle (CPU \(Int(totalCpu))%)"))
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
                    log("CPU \(Int(totalCpu))%: resting for \(Int(restMinutes)) min")
                }
            } else {
                idleSeconds += dt
                if workSeconds > 0 && idleSeconds >= restMinutes * 60 {
                    workSeconds = 0
                    log("Idle for \(Int(restMinutes)) min: work counter reset")
                }
            }
        case .resting:
            if now.timeIntervalSince(restStart) >= restMinutes * 60 {
                resume()
                phase = .working
                workSeconds = 0; idleSeconds = 0
                log("Resumed")
            }
        }
        refresh()
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let line = "\(f.string(from: Date()))  \(s)\n"
        logView.textStorage?.append(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]))
        logView.scrollToEndOfDocument(nil)
    }

    func setStatusItem(symbol: String, fallback: String, title: String, tooltip: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: tooltip)
        statusItem.button?.image = image
        statusItem.button?.title = title.isEmpty ? "" : " " + title
        statusItem.button?.toolTip = "Siesta — " + tooltip
    }

    func refresh() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        switch phase {
        case .stopped:
            setStatusItem(symbol: "cat.fill", fallback: "zzz", title: "", tooltip: "stopped")
            statusLabel.stringValue = "Stopped"
            startButton.title = "Start"
        case .working:
            let left = Int(ceil(max(0, workMinutes * 60 - workSeconds) / 60))
            if isEncoding {
                setStatusItem(symbol: "play.circle.fill", fallback: "play.fill", title: "\(left)m",
                              tooltip: "\(target.name) is encoding, rest in \(left) min")
                statusLabel.stringValue = "Working: rest after \(left) more min of encoding"
            } else {
                setStatusItem(symbol: "hourglass", fallback: "clock", title: "",
                              tooltip: "waiting, \(target.name) is not encoding")
                statusLabel.stringValue = "Waiting: \(target.name) is not encoding"
            }
            startButton.title = "Stop"
        case .resting:
            let end = restStart.addingTimeInterval(restMinutes * 60)
            let left = Int(ceil(max(0, end.timeIntervalSinceNow) / 60))
            setStatusItem(symbol: "pause.circle.fill", fallback: "pause.fill", title: "\(left)m",
                          tooltip: "resting, \(target.name) resumes in \(left) min")
            statusLabel.stringValue = "Resting until \(f.string(from: end))"
            startButton.title = "Stop"
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
