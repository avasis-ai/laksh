import Foundation

/// A known CLI agent Laksh can manage.
struct Agent: Identifiable, Hashable, Sendable {
    let id: String          // stable key, e.g. "claude"
    let name: String        // display name
    let command: String     // binary name on PATH
    let tagline: String     // short description
    let color: AgentColor

    var executablePath: String?
    var isInstalled: Bool { executablePath != nil }

    // Identity-based: only `id` determines equality & hash.
    // `executablePath` is a mutable runtime detail that should not
    // affect identity (e.g. in Set, Dict keys, ForEach).
    static func == (lhs: Agent, rhs: Agent) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static let known: [Agent] = [
        Agent(id: "claude",       name: "Claude Code",  command: "claude",       tagline: "Anthropic's coding agent",          color: .orange),
        Agent(id: "codex",        name: "Codex",        command: "codex",        tagline: "OpenAI Codex CLI",                  color: .green),
        Agent(id: "cursor-agent", name: "Cursor Agent", command: "cursor-agent", tagline: "Cursor background agent",           color: .blue),
        Agent(id: "gemini",       name: "Gemini",       command: "gemini",       tagline: "Google Gemini CLI",                 color: .cyan),
        Agent(id: "opencode",     name: "OpenCode",     command: "opencode",     tagline: "Open-source coding agent",          color: .purple),
        Agent(id: "openclaw",     name: "OpenClaw",     command: "openclaw",     tagline: "Open coding agent",                 color: .pink),
        Agent(id: "hermes",       name: "Hermes",       command: "hermes",       tagline: "Hermes agent",                      color: .yellow),
        Agent(id: "pi",           name: "Pi",           command: "pi",           tagline: "Pi agent",                          color: .mint),
        Agent(id: "aider",        name: "Aider",        command: "aider",        tagline: "AI pair programmer",                color: .red),
        Agent(id: "shell",        name: "Shell",        command: "/bin/zsh",     tagline: "Plain shell (always available)",    color: .gray)
    ]
}

enum AgentColor: String, Hashable, Sendable {
    case orange, green, blue, cyan, purple, pink, yellow, mint, red, gray
}
