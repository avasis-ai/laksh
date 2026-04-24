import Foundation
import SwiftUI
import SwiftTerm
import AppKit
import Combine

/// Known agent commands to detect when typed in a shell
private let knownAgentPatterns: [(pattern: String, agentID: String)] = [
    ("claude", "claude"),
    ("cursor-agent", "cursor-agent"),
    ("aider", "aider"),
    ("codex", "codex"),
    ("gemini", "gemini"),
    ("openclaw", "openclaw"),
    ("opencode", "opencode"),
]

/// Pre-compiled regex cache — built once at launch, never recompiled.
private let agentRegexCache: [(regex: NSRegularExpression, agentID: String)] = {
    var cache: [(regex: NSRegularExpression, agentID: String)] = []
    for (pattern, agentID) in knownAgentPatterns {
        let patterns = [
            "[$%>\u{276F}]\\s+\(pattern)(\\s|$)",
            "^\\s*\(pattern)(\\s|$)",
        ]
        for rx in patterns {
            if let regex = try? NSRegularExpression(pattern: rx, options: .caseInsensitive) {
                cache.append((regex: regex, agentID: agentID))
            }
        }
    }
    return cache
}()

struct DetectedAgentInvocation: Sendable {
    let agentID: String
    let command: String
    let workingDirectory: String
    let timestamp: Date
}

/// LocalProcessTerminalView subclass — overrides only output/lifecycle hooks,
/// never touches terminalDelegate so keyboard input flows through the parent's send().
final class NativeShellView: LocalProcessTerminalView {
    weak var session: NativeSession?

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

/// A plain shell session backed by SwiftTerm — same engine as AgentSession, no custom renderer.
@MainActor
final class NativeSession: ObservableObject, Identifiable {
    let id = UUID()
    let workingDirectory: String
    let createdAt = Date()

    var taskID: UUID?

    @Published var title: String
    @Published var isRunning = false
    @Published var exitCode: Int32?
    @Published var activity: AgentActivity = .idle
    @Published var lastActivityTime = Date()
    @Published var detectedAgentInvocation: DetectedAgentInvocation?

    /// The SwiftTerm view — created once, persists across tab switches.
    /// NativeShellView subclass so we get rangeChanged without overriding terminalDelegate.
    let terminalView: NativeShellView

    private let delegateProxy: ShellDelegateProxy
    private var activityTimer: Timer?
    private var lastDetectedCommand: String?

    init(title: String, workingDirectory: String) {
        self.workingDirectory = workingDirectory
        self.title = title

        let view = NativeShellView(frame: .zero)
        self.terminalView = view
        let proxy = ShellDelegateProxy()
        self.delegateProxy = proxy
        // Only set processDelegate — terminalDelegate stays as self (set in LocalProcessTerminalView.setup())
        // so that keyboard input correctly flows through send() → PTY.
        view.processDelegate = proxy
        proxy.session = self
        view.session = self
    }

    deinit {
        activityTimer?.invalidate()
        activityTimer = nil
        delegateProxy.session = nil
    }

    func start() {
        guard !isRunning else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PWD"] = workingDirectory

        let envStrings = env.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: envStrings,
            execName: nil,
            currentDirectory: workingDirectory
        )

        isRunning = true
        activity = .working
        lastActivityTime = Date()
        startActivityMonitor()
    }

    func sendInput(_ text: String) {
        terminalView.send(txt: text)
        lastActivityTime = Date()
        activity = .working
    }

    /// Called by delegate proxy on termination.
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

    // MARK: - Activity

    private func startActivityMonitor() {
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateActivity()
        }
    }

    private func updateActivity() {
        guard isRunning else { activity = .terminated; return }
        let age = Date().timeIntervalSince(lastActivityTime)
        if age > 5 { activity = .waitingForInput }
        else if age > 2 { activity = .idle }
    }

    /// Called by delegate proxy on the main thread with parsed terminal lines.
    func updateOutputLines(_ lines: [String]) {
        lastActivityTime = Date()
        activity = .working
        checkForAgentCommands(in: lines)
    }

    private func checkForAgentCommands(in lines: [String]) {
        for line in lines.suffix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            for (regex, agentID) in agentRegexCache {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, range: range) != nil,
                   lastDetectedCommand != trimmed
                {
                    lastDetectedCommand = trimmed
                    detectedAgentInvocation = DetectedAgentInvocation(
                        agentID: agentID,
                        command: trimmed,
                        workingDirectory: workingDirectory,
                        timestamp: Date()
                    )
                    return
                }
            }
        }
    }
}

// MARK: - Delegate

/// ObjC bridge for LocalProcessTerminalViewDelegate (process lifecycle events only).
/// terminalDelegate is NOT overridden — keyboard input flows through the parent's send() → PTY.
final class ShellDelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: NativeSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let s = session, !title.isEmpty else { return }
        Task { @MainActor in s.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let s = session else { return }
        Task { @MainActor in s.processDidTerminate(exitCode: exitCode) }
    }
}
