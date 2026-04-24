import Foundation
import SwiftUI
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published var detectedAgents: [Agent] = Agent.known
    @Published var sessions: [AgentSession] = []
    @Published var activeSessionID: UUID?

    // Native shell sessions (Metal terminal)
    @Published var nativeSessions: [NativeSession] = []
    @Published var activeNativeSessionID: UUID?
    
    // System agent scanner (shared) - published for UI updates
    @Published var externalAgents: [ExternalAgent] = []
    @Published var isScanning: Bool = false
    private let systemScanner = SystemAgentScanner()
    private var scannerCancellable: AnyCancellable?
    private var isScanningCancellable: AnyCancellable?

    // Task-centric model
    @Published var tasks: [AgentTask] = [] {
        didSet {
            guard !isLoadingTasks else { return }
            saveTasks()
        }
    }

    // Sheet state
    @Published var showNewTaskSheet = false
    
    // Sidebar state
    @Published var isSidebarCollapsed = false

    // Default working dir — home directory (user can override in sheet).
    @Published var defaultWorkingDirectory: String = NSHomeDirectory()
    
    // Monotonic shell counter so titles never repeat after close/reopen.
    private var shellCounter = 0

    // Guard against re-encoding on init load.
    private var isLoadingTasks = false

    // Per-session agent detection subscriptions, cleaned up on close.
    private var agentDetectionCancellables: [UUID: AnyCancellable] = [:]
    
    // MARK: - Persistence
    
    private static let tasksKey = "com.laksh.tasks.v1"
    
    init() {
        isLoadingTasks = true
        loadTasks()
        isLoadingTasks = false
        
        // Forward scanner state to published properties
        scannerCancellable = systemScanner.$externalAgents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agents in
                self?.externalAgents = agents
            }

        isScanningCancellable = systemScanner.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scanning in
                self?.isScanning = scanning
            }
    }
    
    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: Self.tasksKey) else { return }
        guard let decoded = try? JSONDecoder().decode([AgentTask].self, from: data) else { return }
        // Reset any tasks that were running when app quit — they're dead now.
        tasks = decoded.map { task in
            var t = task
            if t.status == .running {
                t.status = .queued
                t.startedAt = nil
            }
            return t
        }
    }
    
    private func saveTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: Self.tasksKey)
    }

    func refreshDetectedAgents() {
        let detected = AgentDetector.detect(Agent.known)
        self.detectedAgents = detected
    }
    
    func scanSystemAgents() {
        systemScanner.scan()
    }
    
    func killExternalAgent(pid: Int32) {
        systemScanner.kill(pid: pid)
    }

    var installedAgents: [Agent] { detectedAgents.filter(\.isInstalled) }

    // MARK: - Tasks

    var queuedTasks: [AgentTask] { tasks.filter { $0.status == .queued } }
    var runningTasks: [AgentTask] { tasks.filter { $0.status == .running } }
    var doneTasks: [AgentTask] { tasks.filter { $0.status == .done } }

    func addTask(_ task: AgentTask) {
        tasks.append(task)
    }

    func startTask(_ task: AgentTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard let agent = detectedAgents.first(where: { $0.id == task.agentID }),
              agent.isInstalled else { return }

        tasks[idx].status = .running
        tasks[idx].startedAt = Date()

        let session = openSession(agent: agent, cwd: task.workingDirectory, prompt: task.prompt)
        session.taskID = task.id
    }

    func completeTask(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = .done
        tasks[idx].completedAt = Date()
    }

    func deleteTask(_ task: AgentTask) {
        tasks.removeAll { $0.id == task.id }
    }
    
    /// Pause a task (move to idle/queued)
    func pauseTask(_ task: AgentTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        
        // If running, terminate the session and move to queued
        if task.status == .running {
            if let session = session(forTaskID: task.id) {
                session.terminate()
                sessions.removeAll { $0.id == session.id }
            }
            tasks[idx].status = .queued
            tasks[idx].startedAt = nil
        }
    }
    
    /// Stop a task completely (move to done)
    func stopTask(_ task: AgentTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard tasks[idx].status != .done else { return }
        
        // Terminate session if running
        if let session = session(forTaskID: task.id) {
            session.terminate()
            sessions.removeAll { $0.id == session.id }
        }
        
        tasks[idx].status = .done
        tasks[idx].completedAt = Date()
    }

    // MARK: - Sessions (legacy + task-linked)

    func requestNewTaskSheet() { showNewTaskSheet = true }

    @discardableResult
    func openSession(agent: Agent, cwd: String, prompt: String? = nil) -> AgentSession {
        let session = AgentSession(agent: agent, workingDirectory: cwd, initialPrompt: prompt)
        sessions.append(session)
        activeSessionID = session.id
        activeNativeSessionID = nil // Switch away from native
        return session
    }

    func closeActiveSession() {
        if let id = activeNativeSessionID,
           let nativeSession = nativeSessions.first(where: { $0.id == id }) {
            closeNativeSession(nativeSession)
            return
        }
        guard let id = activeSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[idx]
        session.terminate()
        if let taskID = session.taskID {
            completeTask(id: taskID)
        }
        sessions.remove(at: idx)
        activeSessionID = sessions.last?.id
    }

    func closeSession(_ session: AgentSession) {
        session.terminate()
        if let taskID = session.taskID {
            completeTask(id: taskID)
        }
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
    }

    func session(forTaskID taskID: UUID) -> AgentSession? {
        sessions.first { $0.taskID == taskID }
    }
    
    // MARK: - Native Shell Sessions

    func openNativeShell(cwd: String? = nil) {
        shellCounter += 1
        let session = NativeSession(
            title: "Shell \(shellCounter)",
            workingDirectory: cwd ?? defaultWorkingDirectory
        )
        setupAgentDetection(for: session)
        nativeSessions.append(session)
        activeNativeSessionID = session.id
        activeSessionID = nil
    }

    // MARK: - Open or Focus a Terminal for a Task

    /// Double-click handler: if a session already exists for this task, focus it.
    /// If the task is queued, start it then focus. If done, reopen.
    func openTerminal(for task: AgentTask) {
        // 1. Existing AgentSession linked to this task?
        if let existing = session(forTaskID: task.id) {
            activeSessionID = existing.id
            activeNativeSessionID = nil
            return
        }

        // 2. Existing NativeSession linked to this task?
        if let existing = nativeSessions.first(where: { $0.taskID == task.id }) {
            activeNativeSessionID = existing.id
            activeSessionID = nil
            return
        }

        // 3. Start the task (creates an AgentSession) if queued or done
        guard let agent = detectedAgents.first(where: { $0.id == task.agentID }),
              agent.isInstalled else {
            // Agent not installed — open a shell in the task's directory instead
            openNativeShell(cwd: task.workingDirectory)
            return
        }

        // Mark running and open session
        if task.status != .running {
            guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
            tasks[idx].status = .running
            tasks[idx].startedAt = Date()
        }
        let s = openSession(agent: agent, cwd: task.workingDirectory, prompt: task.prompt)
        s.taskID = task.id
    }
    
    private func setupAgentDetection(for session: NativeSession) {
        let cancellable = session.$detectedAgentInvocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invocation in
                self?.handleDetectedAgent(invocation, from: session)
            }
        agentDetectionCancellables[session.id] = cancellable
    }
    
    private func handleDetectedAgent(_ invocation: DetectedAgentInvocation, from session: NativeSession) {
        // Don't create duplicate tasks for same command
        let alreadyExists = tasks.contains { task in
            task.agentID == invocation.agentID &&
            task.workingDirectory == invocation.workingDirectory &&
            task.status == .running
        }
        guard !alreadyExists else { return }
        
        // Create a new task for the detected agent (already running)
        var task = AgentTask(
            title: "\(invocation.agentID.capitalized) (from shell)",
            prompt: invocation.command,
            agentID: invocation.agentID,
            workingDirectory: invocation.workingDirectory,
            status: .running
        )
        task.startedAt = invocation.timestamp
        
        // Link the session to this task
        session.taskID = task.id
        
        tasks.append(task)
    }
    
    func closeNativeSession(_ session: NativeSession) {
        session.terminate()
        agentDetectionCancellables.removeValue(forKey: session.id)
        nativeSessions.removeAll { $0.id == session.id }
        if activeNativeSessionID == session.id {
            activeNativeSessionID = nativeSessions.last?.id
        }
    }
}
