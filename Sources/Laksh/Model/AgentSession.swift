import Foundation
import SwiftTerm
import AppKit

enum AgentActivity: String {
    case idle = "Idle"
    case working = "Working"
    case waitingForInput = "Waiting"
    case terminated = "Terminated"
}

/// A single running agent session — wraps a SwiftTerm LocalProcessTerminalView.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let agent: Agent
    let workingDirectory: String
    let initialPrompt: String?
    let createdAt = Date()

    /// If this session was spawned from a task, link back to it.
    var taskID: UUID?

    @Published var title: String
    @Published var isRunning: Bool = false
    @Published var exitCode: Int32? = nil

    /// Live output capture for inspector
    @Published var lastOutputLines: [String] = []
    @Published var activity: AgentActivity = .idle
    @Published var lastActivityTime: Date = Date()

    private let maxCapturedLines = 20
    private var activityTimer: Timer?

    let terminalView: AgentShellView

    private let delegateProxy: SessionDelegateProxy

    init(agent: Agent, workingDirectory: String, initialPrompt: String?) {
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.initialPrompt = initialPrompt
        self.title = agent.name

        let view = AgentShellView(frame: .zero)
        self.terminalView = view
        let proxy = SessionDelegateProxy()
        self.delegateProxy = proxy
        // Only processDelegate — terminalDelegate stays as self so keyboard → PTY works.
        view.processDelegate = proxy
        proxy.session = self
        view.session = self
    }

    deinit {
        // Timer targets the proxy weakly, but clean up to stop callbacks sooner.
        // Nonisolated deinit — safe to touch non-isolated properties.
        activityTimer?.invalidate()
        activityTimer = nil
        delegateProxy.session = nil
    }

    /// Start the child process. Safe to call once after the view is in a window.
    func start() {
        guard !isRunning else { return }
        guard let exe = agent.executablePath else { return }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PWD"] = workingDirectory

        let envStrings = env.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(executable: exe,
                                  args: [],
                                  environment: envStrings,
                                  execName: nil,
                                  currentDirectory: workingDirectory)
        isRunning = true
        activity = .working
        lastActivityTime = Date()

        startActivityMonitor()

        if let prompt = initialPrompt, !prompt.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sendInput(prompt + "\n")
            }
        }
    }

    private func startActivityMonitor() {
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateActivityStatus()
        }
    }

    private func updateActivityStatus() {
        guard isRunning else {
            activity = .terminated
            return
        }

        let timeSinceActivity = Date().timeIntervalSince(lastActivityTime)

        if timeSinceActivity > 5.0 {
            activity = .waitingForInput
        } else if timeSinceActivity > 2.0 {
            activity = .idle
        }
    }

    /// Called from the delegate proxy on the main thread to record terminal output.
    func updateOutputLines(_ lines: [String]) {
        lastOutputLines = lines.suffix(maxCapturedLines).map { String($0) }
        lastActivityTime = Date()
        activity = .working
    }

    /// Get the last N lines of visible terminal content
    func getVisibleContent(lines: Int = 10) -> String {
        return lastOutputLines.suffix(lines).joined(separator: "\n")
    }

    func sendInput(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Notify that the child process has terminated (called by delegate proxy).
    func processDidTerminate(exitCode: Int32?) {
        activityTimer?.invalidate()
        activityTimer = nil
        isRunning = false
        self.exitCode = exitCode
        activity = .terminated
    }

    func terminate() {
        activityTimer?.invalidate()
        activityTimer = nil
        terminalView.send(txt: "\u{03}") // Ctrl-C
        isRunning = false
        activity = .terminated
    }
}

/// LocalProcessTerminalView subclass for agent sessions.
/// Overrides output/lifecycle hooks without touching terminalDelegate,
/// so keyboard input flows through the parent's send() → PTY.
final class AgentShellView: LocalProcessTerminalView {
    weak var session: AgentSession?

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        guard let s = session else { return }
        let terminal = source.getTerminal()
        let rows = terminal.rows
        var lines: [String] = []
        for row in max(0, rows - 20)..<rows {
            if let line = terminal.getLine(row: row) {
                let t = line.translateToString().trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(t) }
            }
        }
        Task { @MainActor in s.updateOutputLines(lines) }
    }

}

/// ObjC bridge for LocalProcessTerminalViewDelegate (process lifecycle only).
final class SessionDelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: AgentSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let s = session else { return }
        Task { @MainActor in
            s.title = title.isEmpty ? s.agent.name : title
        }
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        guard let s = session else { return }
        Task { @MainActor in
            s.processDidTerminate(exitCode: exitCode)
        }
    }
}
