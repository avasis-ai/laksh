import SwiftUI

/// Demo view for testing the native Laksh terminal
struct TerminalDemo: View {
    @StateObject private var terminal = LakshTerminal(rows: 30, cols: 100)
    @State private var isRunning = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Native Terminal Demo")
                    .font(ClayFont.title)
                    .foregroundStyle(Color.clayText)
                
                Spacer()
                
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(terminal.isRunning ? Color.agentRunning : Color.agentIdle)
                        .frame(width: 8, height: 8)
                    Text(terminal.isRunning ? "Running" : "Stopped")
                        .font(ClayFont.caption)
                        .foregroundStyle(Color.clayTextMuted)
                }
                
                if !terminal.isRunning {
                    Button("Start Shell") {
                        startShell()
                    }
                    .buttonStyle(ClayButtonStyle())
                } else {
                    Button("Stop") {
                        terminal.stop()
                    }
                    .buttonStyle(ClayButtonStyle())
                }
            }
            .padding()
            .background(Color.claySurface)
            
            Rectangle()
                .fill(Color.clayDivider)
                .frame(height: 1)
            
            // Terminal view
            LakshTerminalView(terminal: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clayCanvas)
    }
    
    private func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        
        do {
            try terminal.start(
                shell: shell,
                environment: env,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        } catch {
            print("Failed to start shell: \(error)")
        }
    }
}

#Preview {
    TerminalDemo()
        .frame(width: 800, height: 600)
}
