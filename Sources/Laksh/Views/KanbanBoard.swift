import SwiftUI
import UniformTypeIdentifiers

struct KanbanBoard: View {
    @EnvironmentObject var store: SessionStore
    
    // Drop target highlighting
    @State private var idleIsTargeted = false
    @State private var runningIsTargeted = false
    @State private var doneIsTargeted = false
    
    // Split system agents into active vs idle
    private var activeAgents: [ExternalAgent] {
        store.externalAgents.filter { !$0.appearsIdle }
    }
    
    private var idleAgents: [ExternalAgent] {
        store.externalAgents.filter { $0.appearsIdle }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            idleColumn
            Rectangle().fill(Color.clayDivider).frame(width: 1)
            runningColumn
            Rectangle().fill(Color.clayDivider).frame(width: 1)
            doneColumn
        }
        .background(Color.clayCanvas)
        .onAppear {
            store.scanSystemAgents()
        }
    }

    // MARK: - Idle Column (queued tasks + idle system agents)
    
    private var idleColumn: some View {
        let totalCount = store.queuedTasks.count + idleAgents.count + store.nativeSessions.filter { !$0.isRunning }.count
        
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(title: "Idle", number: 1, count: totalCount, color: .clayTextMuted)
            
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Queued Laksh tasks
                    if !store.queuedTasks.isEmpty {
                        ForEach(store.queuedTasks) { task in
                            DraggableTaskCard(task: task)
                        }
                    }
                    
                    // Idle native shells
                    let idleShells = store.nativeSessions.filter { !$0.isRunning }
                    if !idleShells.isEmpty {
                        ForEach(idleShells) { session in
                            ShellCard(session: session, onKill: { store.closeNativeSession(session) })
                        }
                    }
                    
                    // Idle system agents
                    if !idleAgents.isEmpty {
                        if !store.queuedTasks.isEmpty || !idleShells.isEmpty {
                            sectionDivider(label: "SYSTEM IDLE")
                        }
                        ForEach(idleAgents) { agent in
                            SystemAgentCard(agent: agent) {
                                store.killExternalAgent(pid: agent.pid)
                            }
                        }
                    }
                    
                    // Empty state / drop zone
                    if store.queuedTasks.isEmpty && idleAgents.isEmpty && idleShells.isEmpty {
                        dropZone("Drop here to pause task", isTargeted: idleIsTargeted)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 280, idealWidth: 320)
        .background(idleIsTargeted ? Color.clayText.opacity(0.05) : Color.clear)
        .onDrop(of: [UTType.plainText], isTargeted: $idleIsTargeted) { providers in
            handleDrop(providers: providers, targetStatus: .queued)
        }
    }
    
    // MARK: - Running Column (active Laksh + active system agents)
    
    private var runningColumn: some View {
        let runningShells = store.nativeSessions.filter { $0.isRunning }
        let totalCount = store.runningTasks.count + activeAgents.count + runningShells.count
        
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(title: "Running", number: 2, count: totalCount, color: .clayRunning)
            
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Laksh-managed running tasks
                    if !store.runningTasks.isEmpty {
                        ForEach(store.runningTasks) { task in
                            DraggableTaskCard(task: task)
                        }
                    }
                    
                    // Running native shells
                    if !runningShells.isEmpty {
                        ForEach(runningShells) { session in
                            ShellCard(session: session, onKill: { store.closeNativeSession(session) })
                        }
                    }
                    
                    // Active system agents (not idle)
                    if !activeAgents.isEmpty {
                        if !store.runningTasks.isEmpty || !runningShells.isEmpty {
                            sectionDivider(label: "SYSTEM")
                        }
                        ForEach(activeAgents) { agent in
                            SystemAgentCard(agent: agent) {
                                store.killExternalAgent(pid: agent.pid)
                            }
                        }
                    }
                    
                    // Empty state
                    if store.runningTasks.isEmpty && activeAgents.isEmpty && runningShells.isEmpty {
                        emptyState("No active agents.\nIdle agents appear in the Idle column.")
                            .padding(.top, 20)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 320, idealWidth: 380)
        .background(runningIsTargeted ? Color.clayText.opacity(0.05) : Color.clear)
        .onDrop(of: [UTType.plainText], isTargeted: $runningIsTargeted) { providers in
            handleDrop(providers: providers, targetStatus: .running)
        }
    }
    
    // MARK: - Done Column
    
    private var doneColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader(title: "Done", number: 3, count: store.doneTasks.count, color: .clayTextDim)
            
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.doneTasks) { task in
                        DraggableTaskCard(task: task)
                    }
                    // Always show drop zone — even when done tasks exist
                    dropZone(store.doneTasks.isEmpty ? "Drop here to stop task" : "Drop here to mark done",
                             isTargeted: doneIsTargeted)
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 280, idealWidth: 320)
        .background(doneIsTargeted ? Color.clayText.opacity(0.05) : Color.clear)
        .onDrop(of: [UTType.plainText], isTargeted: $doneIsTargeted) { providers in
            handleDrop(providers: providers, targetStatus: .done)
        }
    }
    
    // MARK: - Shared section divider
    
    private func sectionDivider(label: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.clayDivider)
                .frame(height: 1)
            Text(label)
                .font(ClayFont.tiny)
                .foregroundStyle(Color.clayTextDim)
            Rectangle()
                .fill(Color.clayDivider)
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider], targetStatus: TaskStatus) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let raw = reading as? String else { return }
            Task { @MainActor in
                // Format: "type:id" — task:UUID | shell:UUID | agent:PID
                let parts = raw.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                let kind = String(parts[0])
                let id   = String(parts[1])

                switch kind {
                case "task":
                    guard let uuid = UUID(uuidString: id),
                          let task = self.store.tasks.first(where: { $0.id == uuid }) else { return }
                    switch targetStatus {
                    case .queued:  self.store.pauseTask(task)
                    case .done:    self.store.stopTask(task)
                    case .running: if task.status == .queued { self.store.startTask(task) }
                    }
                case "shell":
                    guard let uuid = UUID(uuidString: id),
                          let session = self.store.nativeSessions.first(where: { $0.id == uuid }) else { return }
                    switch targetStatus {
                    case .done:   self.store.closeNativeSession(session)
                    case .queued: session.terminate()
                    default: break
                    }
                case "agent":
                    if targetStatus == .done, let pid = Int32(id) {
                        self.store.killExternalAgent(pid: pid)
                    }
                default: break
                }
            }
        }
        return true
    }
    
    private func dropZone(_ message: String, isTargeted: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24))
                .foregroundStyle(isTargeted ? Color.clayText : Color.clayTextDim)
            Text(message)
                .font(ClayFont.caption)
                .foregroundStyle(isTargeted ? Color.clayText : Color.clayTextDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.clayText : Color.clayTextDim.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
    
    // MARK: - Shared Components

    private func columnHeader(title: String, number: Int, count: Int, color: Color) -> some View {
        HStack(spacing: 10) {
            GhostNumber(number)
            Text(title.uppercased())
                .font(ClayFont.sectionLabel)
                .kerning(1.6)
                .foregroundStyle(color)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(ClayFont.tiny)
                    .foregroundStyle(Color.clayTextDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.claySurface)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.clayCanvas)
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(ClayFont.caption)
                .foregroundStyle(Color.clayTextDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - System Agent Card

struct SystemAgentCard: View {
    let agent: ExternalAgent
    let onKill: () -> Void
    @EnvironmentObject var store: SessionStore
    @State private var isHovered = false
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 10) {
                Circle()
                    .fill(agent.appearsIdle ? Color.clayTextDim : Color.clayRunning)
                    .frame(width: 6, height: 6)
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.agentType)
                            .font(ClayFont.bodyMedium)
                            .foregroundStyle(Color.clayText)
                        if agent.appearsIdle {
                            Text("IDLE")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.clayTextDim)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.claySurface)
                                .cornerRadius(3)
                        }
                    }
                    
                    if let context = agent.contextSummary {
                        Text(context)
                            .font(ClayFont.caption)
                            .foregroundStyle(Color.clayTextMuted)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 6) {
                        Text("\(String(format: "%.0f", agent.cpuUsage))%")
                            .font(ClayFont.monoSmall)
                            .foregroundStyle(cpuColor)
                        Text("•")
                            .foregroundStyle(Color.clayTextDim)
                        Text("\(String(format: "%.0f", agent.memoryMB))MB")
                            .font(ClayFont.monoSmall)
                            .foregroundStyle(Color.clayTextDim)
                        Text("•")
                            .foregroundStyle(Color.clayTextDim)
                        Text(agent.runtimeFormatted)
                            .font(ClayFont.monoSmall)
                            .foregroundStyle(Color.clayTextDim)
                    }
                }
                
                Spacer()
                
                if isHovered {
                    Button(action: onKill) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(agent.appearsIdle ? Color(red: 0.9, green: 0.4, blue: 0.3) : Color.clayTextMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Kill process")
                }
                
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.clayTextMuted)
                        .padding(5)
                        .background(Color.claySurface)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("PID")
                            .font(ClayFont.tiny)
                            .foregroundStyle(Color.clayTextDim)
                        Text("\(agent.pid)")
                            .font(ClayFont.monoSmall)
                            .foregroundStyle(Color.clayTextMuted)
                    }
                    
                    Text(agent.fullCommand)
                        .font(ClayFont.monoSmall)
                        .foregroundStyle(Color.clayTextDim)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.clayHover : Color.claySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(agent.appearsIdle ? Color.clayTextDim.opacity(0.3) : Color.clayRunning.opacity(0.3), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(object: "agent:\(agent.pid)" as NSString)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                let cwd = agent.workingDirectory ?? NSHomeDirectory()
                store.openNativeShell(cwd: cwd)
            }
        )
    }

    private var cpuColor: Color {
        if agent.cpuUsage > 50 { return Color(red: 0.9, green: 0.5, blue: 0.3) }
        if agent.cpuUsage > 20 { return Color(red: 0.9, green: 0.7, blue: 0.3) }
        if agent.cpuUsage < 1 { return Color.clayTextDim }
        return .clayTextMuted
    }
}

/// Draggable + double-clickable wrapper for TaskCard
struct DraggableTaskCard: View {
    let task: AgentTask
    @EnvironmentObject var store: SessionStore

    var body: some View {
        TaskCard(task: task)
            .onDrag {
                NSItemProvider(object: "task:\(task.id.uuidString)" as NSString)
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    store.openTerminal(for: task)
                }
            )
    }
}

struct TaskCard: View {
    let task: AgentTask
    @EnvironmentObject var store: SessionStore
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if task.status != .done {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.clayTextDim.opacity(isHovered ? 0.8 : 0.25))
                }
                statusIndicator
                Text(task.title)
                    .font(ClayFont.bodyMedium)
                    .foregroundStyle(Color.clayText)
                    .lineLimit(2)
                Spacer()
            }

            if !task.prompt.isEmpty {
                Text(task.prompt)
                    .font(ClayFont.caption)
                    .foregroundStyle(Color.clayTextMuted)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }

            HStack(spacing: 8) {
                agentBadge
                Spacer()
                directoryLabel
                actions
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.clayHover : Color.claySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.clayHighlight, lineWidth: 1)
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: 1)
                        Spacer()
                    }
                )
        )
        .onHover { isHovered = $0 }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: Color {
        switch task.status {
        case .queued: return .clayTextMuted
        case .running: return .clayRunning
        case .done: return .clayTextDim
        }
    }

    private var agentBadge: some View {
        let agent = store.detectedAgents.first { $0.id == task.agentID }
        return Text(agent?.name ?? task.agentID)
            .font(ClayFont.tiny)
            .foregroundStyle(Color.clayTextMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.claySurface)
            .cornerRadius(4)
    }

    private var directoryLabel: some View {
        let short = task.workingDirectory
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .split(separator: "/").suffix(2).joined(separator: "/")
        return Text(short)
            .font(ClayFont.tiny)
            .foregroundStyle(Color.clayTextDim)
            .lineLimit(1)
    }

    @ViewBuilder
    private var actions: some View {
        switch task.status {
        case .queued:
            Button { store.startTask(task) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.clayText)
                    .padding(6)
                    .background(Color.claySurface)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        case .running:
            HStack(spacing: 4) {
                if let session = store.session(forTaskID: task.id) {
                    Button {
                        store.activeNativeSessionID = nil
                        store.activeSessionID = session.id
                    } label: {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.clayRunning)
                            .padding(6)
                            .background(Color.claySurface)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Button { store.pauseTask(task) } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.clayTextMuted)
                        .padding(6)
                        .background(Color.claySurface)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
            }
        case .done:
            Button { store.deleteTask(task) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.clayTextDim)
                    .padding(6)
                    .background(Color.claySurface)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.5)
        }
    }
}

/// Card for native shell sessions — supports double-tap to open terminal
struct ShellCard: View {
    @ObservedObject var session: NativeSession
    let onKill: () -> Void
    @EnvironmentObject var store: SessionStore
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.isRunning ? Color.clayRunning : Color.clayTextMuted)
                    .frame(width: 6, height: 6)
                
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.clayTextMuted)
                
                Text(session.title)
                    .font(ClayFont.bodyMedium)
                    .foregroundStyle(Color.clayText)
                
                Spacer()
                
                if isHovered {
                    Button {
                        store.activeNativeSessionID = session.id
                        store.activeSessionID = nil
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.clayTextMuted)
                            .padding(5)
                            .background(Color.claySurface)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onKill) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.clayTextMuted)
                            .padding(5)
                            .background(Color.claySurface)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Text(shortPath(session.workingDirectory))
                .font(ClayFont.tiny)
                .foregroundStyle(Color.clayTextDim)
                .padding(.leading, 16)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.clayHover : Color.claySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.clayHighlight, lineWidth: 1)
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: 1)
                        Spacer()
                    }
                )
        )
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(object: "shell:\(session.id.uuidString)" as NSString)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                store.activeNativeSessionID = session.id
                store.activeSessionID = nil
            }
        )
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .split(separator: "/").suffix(2).joined(separator: "/")
    }
}
