import Foundation

// Non-isolated shell runner for background execution
enum ShellRunner {
    static func run(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            // Read data *before* waitUntilExit to avoid deadlock if the child
            // writes more than the pipe buffer (64 KB).  For `ps | grep` the
            // output is typically small, but correctness beats assumptions.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

/// Represents an agent process found running on the system
struct ExternalAgent: Identifiable, Hashable, Sendable {
    let id: Int32
    var pid: Int32 { id }
    let command: String
    let fullCommand: String
    var workingDirectory: String?
    let user: String
    let startTime: Date?
    let cpuUsage: Double
    let memoryMB: Double
    let tty: String?
    let contextSummary: String?

    // Identity-based: only PID determines equality & hash.
    // Runtime details (cpuUsage, memoryMB) change between scans
    // and should not affect identity in Sets/ForEach.
    static func == (lhs: ExternalAgent, rhs: ExternalAgent) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    var agentType: String {
        let cmd = command.lowercased()
        if cmd.contains("cursor") { return "Cursor" }
        if cmd.contains("claude") { return "Claude" }
        if cmd.contains("aider") { return "Aider" }
        if cmd.contains("codex") { return "Codex" }
        if cmd.contains("copilot") { return "Copilot" }
        if cmd.contains("cody") { return "Cody" }
        if cmd.contains("continue") { return "Continue" }
        if cmd.contains("tabby") { return "Tabby" }
        if cmd.contains("openclaw") { return "OpenClaw" }
        if cmd.contains("goose") { return "Goose" }
        if cmd.contains("mentat") { return "Mentat" }
        return "Agent"
    }
    
    var runtimeFormatted: String {
        guard let start = startTime else { return "—" }
        let seconds = Int(Date().timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    
    /// Indicates if process appears idle (low CPU for extended time)
    var appearsIdle: Bool {
        cpuUsage < 1.0
    }
}

/// Optimized system agent scanner
/// - Single piped shell command (ps | grep) instead of Swift filtering
/// - Background queue execution
/// - Debounced scanning
/// - NOT @MainActor — publishes updates from background; callers forward to main.
final class SystemAgentScanner: ObservableObject {
    @Published var externalAgents: [ExternalAgent] = []
    @Published var isScanning: Bool = false
    @Published var lastScanTime: Date?
    
    // Debounce
    private var scanTask: Task<Void, Never>?
    private var lastScanStart: Date?
    private static let minScanInterval: TimeInterval = 1.0
    
    // Background queue
    private let scanQueue = DispatchQueue(label: "laksh.scanner", qos: .utility)
    
    // Single grep pattern for efficiency — static, never changes per instance.
    private static let grepPattern = "cursor|claude|aider|codex|copilot|cody|openclaw|goose|mentat|tabby"
    
    func scan() {
        // Debounce: skip if too recent
        if let lastStart = lastScanStart, Date().timeIntervalSince(lastStart) < Self.minScanInterval {
            return
        }
        
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.performScan()
        }
    }
    
    /// Kill a process by PID
    func kill(pid: Int32) {
        scanQueue.async { [pid] in
            _ = ShellRunner.run("/bin/kill -15 \(pid) 2>/dev/null")
        }
        // Optimistic remove for responsive UI
        DispatchQueue.main.async { [weak self] in
            self?.externalAgents.removeAll { $0.pid == pid }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastScanStart = nil
            self?.scan()
        }
    }

    func forceKill(pid: Int32) {
        scanQueue.async { [pid] in
            _ = ShellRunner.run("/bin/kill -9 \(pid) 2>/dev/null")
        }
        DispatchQueue.main.async { [weak self] in
            self?.externalAgents.removeAll { $0.pid == pid }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.lastScanStart = nil
            self?.scan()
        }
    }
    
    private func performScan() async {
        guard !Task.isCancelled else { return }
        
        // Write lastScanStart on main to avoid data race with scan() reader.
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = true
            self?.lastScanStart = Date()
        }

        let agents = await withCheckedContinuation { (continuation: CheckedContinuation<[ExternalAgent], Never>) in
            scanQueue.async {
                let result = Self.scanForAgents(pattern: Self.grepPattern)
                continuation.resume(returning: result)
            }
        }

        guard !Task.isCancelled else { return }

        DispatchQueue.main.async { [weak self] in
            self?.externalAgents = agents
            self?.lastScanTime = Date()
            self?.isScanning = false
        }
    }
    
    // Static + nonisolated — runs on background queue, no MainActor issues
    nonisolated private static func scanForAgents(pattern: String) -> [ExternalAgent] {
        // Single piped command - much faster than Swift-side filtering
        let script = "/bin/ps -eo pid,user,pcpu,rss,tty,etime,command | /usr/bin/grep -iE '\(pattern)' | /usr/bin/grep -v 'grep\\|Laksh'"
        let output = ShellRunner.run(script)
        
        guard !output.isEmpty else { return [] }
        
        var found: [ExternalAgent] = []
        var seenPIDs = Set<Int32>()
        
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Skip helper/subprocess patterns - these are components, not main agents
            if isSubprocess(trimmed) {
                continue
            }
            
            if let agent = parseProcessLine(trimmed) {
                if seenPIDs.insert(agent.pid).inserted {
                    found.append(agent)
                }
            }
        }
        
        return found.sorted { $0.cpuUsage > $1.cpuUsage }
    }
    
    /// Detect if a process is a subprocess/helper (not a main agent)
    nonisolated private static func isSubprocess(_ line: String) -> Bool {
        let lower = line.lowercased()
        
        // Cursor - only keep the main agent process with --resume
        if lower.contains("cursor") || lower.contains("cursor-agent") {
            if lower.contains("--resume=") { return false }
            return true
        }
        
        // Claude desktop - skip entirely, it's not a CLI agent
        if lower.contains("claude.app") || lower.contains("/claude/") || lower.contains("claude-mem") {
            return true
        }
        
        // OpenClaw - only keep gateway (the main service)
        if lower.contains("openclaw") {
            if lower.contains("gateway") { return false }
            return true
        }
        
        // Skip generic infrastructure
        if lower.contains("chroma") { return true }
        if lower.contains("mcp-server") { return true }
        if lower.contains("worker-service") { return true }
        if lower.contains("shishu") { return true }
        
        // Generic Electron/Chromium helpers
        if lower.contains("helper") { return true }
        if lower.contains("crashpad") { return true }
        if lower.contains("renderer") { return true }
        if lower.contains("chrome-native") { return true }
        
        return false
    }
    
    nonisolated private static func parseProcessLine(_ line: String) -> ExternalAgent? {
        // Format: PID USER %CPU RSS TTY ELAPSED COMMAND...
        let components = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard components.count >= 7 else { return nil }
        
        guard let pid = Int32(components[0]) else { return nil }
        let user = String(components[1])
        let cpu = Double(components[2]) ?? 0.0
        let rssKB = Double(components[3]) ?? 0.0
        let tty = String(components[4])
        let elapsed = String(components[5])
        let command = String(components[6...].joined(separator: " "))
        
        let startTime = parseElapsedTime(elapsed)
        let shortCommand = extractShortCommand(from: command)
        let context = extractContext(from: command)
        
        return ExternalAgent(
            id: pid,
            command: shortCommand,
            fullCommand: command,
            workingDirectory: nil,
            user: user,
            startTime: startTime,
            cpuUsage: cpu,
            memoryMB: rssKB / 1024.0,
            tty: tty == "??" ? nil : tty,
            contextSummary: context
        )
    }
    
    /// Extract meaningful context from command line args
    nonisolated private static func extractContext(from command: String) -> String? {
        let cmd = command.lowercased()
        
        // Cursor agent session
        if cmd.contains("cursor") && cmd.contains("agent") {
            if let match = command.range(of: #"--resume=([a-f0-9-]+)"#, options: .regularExpression) {
                let sessionID = String(command[match]).replacingOccurrences(of: "--resume=", with: "")
                return "Session \(sessionID.prefix(8))…"
            }
            return "Agent Session"
        }
        
        // OpenClaw
        if cmd.contains("openclaw") {
            if cmd.contains("gateway") { return "Gateway — routing messages" }
            if cmd.contains("agent") { return "Agent Session" }
            return nil
        }
        
        // Aider
        if cmd.contains("aider") {
            var parts: [String] = []
            if let modelMatch = command.range(of: #"--model[= ]([^\s]+)"#, options: .regularExpression) {
                let model = String(command[modelMatch])
                    .replacingOccurrences(of: "--model=", with: "")
                    .replacingOccurrences(of: "--model ", with: "")
                parts.append(model)
            }
            let tokens = command.split(separator: " ")
            let files = tokens.filter { $0.hasSuffix(".py") || $0.hasSuffix(".js") || $0.hasSuffix(".ts") || $0.hasSuffix(".swift") }
            if let firstFile = files.first {
                parts.append(String(firstFile.split(separator: "/").last ?? firstFile))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        }
        
        // Codex
        if cmd.contains("codex") {
            return "Codex Session"
        }
        
        // Goose
        if cmd.contains("goose") {
            return "Goose Session"
        }
        
        // Mentat
        if cmd.contains("mentat") {
            return "Mentat Session"
        }
        
        // Copilot CLI
        if cmd.contains("copilot") {
            return "Copilot CLI"
        }
        
        return nil
    }
    
    nonisolated private static func extractShortCommand(from command: String) -> String {
        if let lastSlash = command.lastIndex(of: "/") {
            let afterSlash = command[command.index(after: lastSlash)...]
            if let space = afterSlash.firstIndex(of: " ") {
                return String(afterSlash[..<space])
            }
            return String(afterSlash)
        }
        return command.components(separatedBy: " ").first ?? command
    }
    
    nonisolated private static func parseElapsedTime(_ elapsed: String) -> Date? {
        guard !elapsed.isEmpty else { return nil }
        
        var totalSeconds = 0
        
        if elapsed.contains("-") {
            let parts = elapsed.split(separator: "-")
            if parts.count == 2, let days = Int(parts[0]) {
                totalSeconds += days * 86400
                totalSeconds += parseTimeComponents(String(parts[1]))
            }
        } else {
            totalSeconds = parseTimeComponents(elapsed)
        }
        
        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(-Double(totalSeconds))
    }
    
    nonisolated private static func parseTimeComponents(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}
