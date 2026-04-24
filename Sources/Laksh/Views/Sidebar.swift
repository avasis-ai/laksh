import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var perfMonitor = PerformanceMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    agentsSection
                    sessionsSection
                    shellsSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Spacer(minLength: 0)

            Rectangle().fill(Color.clayDivider).frame(height: 1)
            performanceBar
            Rectangle().fill(Color.clayDivider).frame(height: 1)
            footer
        }
        .frame(minWidth: 240, idealWidth: 270, maxWidth: 320)
        .background(Color.clayBackground)
        .onAppear { perfMonitor.start() }
        .onDisappear { perfMonitor.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BlueprintMark()
            Text("Laksh")
                .font(ClayFont.title)
                .foregroundStyle(Color.clayText)
            Spacer()
            
            // Scan system agents
            Button {
                store.scanSystemAgents()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.clayTextMuted)
            }
            .buttonStyle(.plain)
            .help("Scan system agents")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
    
    private var performanceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.low")
                .font(.system(size: 9))
                .foregroundStyle(Color.clayTextDim)
            PerformanceIndicator(monitor: perfMonitor)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel(1, "Agents")
            ForEach(store.detectedAgents) { agent in
                AgentRow(agent: agent) {
                    guard agent.isInstalled else { return }
                    store.openSession(agent: agent, cwd: store.defaultWorkingDirectory)
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel(2, "Sessions")
            if store.sessions.isEmpty {
                Text("No sessions yet.\nTap an installed agent to start one,\nor ⌘T for a new task.")
                    .font(ClayFont.tiny)
                    .foregroundStyle(Color.clayTextMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                ForEach(store.sessions) { session in
                    SessionRow(session: session,
                               isActive: session.id == store.activeSessionID,
                               onTap: {
                                   store.activeSessionID = session.id
                                   store.activeNativeSessionID = nil
                               },
                               onClose: { store.closeSession(session) })
                }
            }
        }
    }
    
    private var shellsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel(3, "Shells")
            if store.nativeSessions.isEmpty {
                Text("No shell sessions.\nClick + to open a new shell.")
                    .font(ClayFont.tiny)
                    .foregroundStyle(Color.clayTextMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                ForEach(store.nativeSessions) { session in
                    ShellRow(session: session,
                             isActive: session.id == store.activeNativeSessionID,
                             onTap: {
                                 store.activeNativeSessionID = session.id
                                 store.activeSessionID = nil
                             },
                             onClose: { store.closeNativeSession(session) })
                }
            }
            
            // Add shell button
            Button {
                store.openNativeShell()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .medium))
                    Text("New Shell")
                        .font(ClayFont.tiny)
                }
                .foregroundStyle(Color.clayTextMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.claySurface)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var footer: some View {
        Button {
            store.requestNewTaskSheet()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                Text("New Task")
                    .font(ClayFont.bodyMedium)
            }
            .foregroundStyle(Color.clayText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.claySurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.clayBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private func sectionLabel(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 6) {
            GhostNumber(number)
            Text(text.uppercased())
                .font(ClayFont.sectionLabel)
                .tracking(1)
                .foregroundStyle(Color.clayTextMuted)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct AgentRow: View {
    let agent: Agent
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(agent.isInstalled ? Color.clayText.opacity(0.4) : Color.clayTextDim)
                    .frame(width: 6, height: 6)
                Text(agent.name)
                    .font(ClayFont.body)
                    .foregroundStyle(agent.isInstalled ? Color.clayText : Color.clayTextDim)
                Spacer()
                if agent.isInstalled && hover {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.clayTextMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hover && agent.isInstalled ? Color.clayHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(!agent.isInstalled)
    }
}

private struct SessionRow: View {
    @ObservedObject var session: AgentSession
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isRunning ? Color.agentRunning : Color.agentIdle)
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(ClayFont.body)
                .foregroundStyle(Color.clayText)
                .lineLimit(1)
            Spacer()
            if hover {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.clayTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.clayActive : (hover ? Color.clayHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.clayBorder : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
    }
}

private struct ShellRow: View {
    @ObservedObject var session: NativeSession
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(session.isRunning ? Color.agentRunning : Color.agentIdle)
            Text(session.title)
                .font(ClayFont.body)
                .foregroundStyle(Color.clayText)
                .lineLimit(1)
            Spacer()
            if hover {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.clayTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.clayActive : (hover ? Color.clayHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.clayBorder : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
    }
}
