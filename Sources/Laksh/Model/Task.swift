import Foundation

enum TaskStatus: String, Codable, CaseIterable {
    case queued
    case running
    case done
}

struct AgentTask: Identifiable, Codable {
    let id: UUID
    var title: String
    var prompt: String
    var agentID: String
    var workingDirectory: String
    var status: TaskStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        agentID: String,
        workingDirectory: String,
        status: TaskStatus = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.agentID = agentID
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
    }
}
