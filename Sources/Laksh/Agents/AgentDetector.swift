import Foundation

/// Scans PATH (and common extra bin dirs) for known agent CLIs.
enum AgentDetector {
    static func detect(_ agents: [Agent]) -> [Agent] {
        let searchDirs = cachedSearchDirs
        let fm = FileManager.default
        return agents.map { agent in
            var a = agent
            // shell fallback: treat absolute path as installed if file exists
            if agent.command.hasPrefix("/") {
                a.executablePath = fm.isExecutableFile(atPath: agent.command) ? agent.command : nil
                return a
            }
            for dir in searchDirs {
                let candidate = (dir as NSString).appendingPathComponent(agent.command)
                if fm.isExecutableFile(atPath: candidate) {
                    a.executablePath = candidate
                    break
                }
            }
            return a
        }
    }

    // MARK: - PATH Resolution (cached)

    /// Lazily resolved search directories — shells out once per launch, then cached.
    /// `loginShellPath()` blocks the calling thread for ~100ms, so caching matters.
    private static let cachedSearchDirs: [String] = {
        var dirs: [String] = []
        var seen = Set<String>()
        if let shellPath = loginShellPath() {
            for component in shellPath.split(separator: ":") {
                let dir = String(component)
                if seen.insert(dir).inserted {
                    dirs.append(dir)
                }
            }
        }
        let home = NSHomeDirectory()
        let extras: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            home + "/.local/bin",
            home + "/.bun/bin",
            home + "/.cargo/bin",
            home + "/go/bin"
        ]
        for e in extras {
            if seen.insert(e).inserted {
                dirs.append(e)
            }
        }
        return dirs
    }()

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }

        // Read data *before* waitUntilExit to avoid deadlock if the child
        // writes more than the pipe buffer (64 KB). For `echo $PATH` the
        // output is tiny, but correctness matters more than assumptions.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        // Timeout guard — prevent a hanging login shell from blocking the app forever.
        let timeout: TimeInterval = 5
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if task.isRunning { task.terminate() }
        }

        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
