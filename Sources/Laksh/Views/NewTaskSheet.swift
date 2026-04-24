import SwiftUI
import AppKit

struct NewTaskSheet: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAgentID: String = ""
    @State private var workingDirectory: String = NSHomeDirectory()
    @State private var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header — blueprint mark + title (no ghost number to avoid
            // colliding with the field indices 1/2/3 below).
            HStack(spacing: 10) {
                BlueprintMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("DISPATCH")
                        .font(ClayFont.sectionLabel)
                        .kerning(1.6)
                        .foregroundStyle(Color.clayTextMuted)
                    Text("New task")
                        .font(ClayFont.title)
                        .foregroundStyle(Color.clayText)
                }
                Spacer()
            }

            field(index: 1, label: "Agent") {
                Menu {
                    ForEach(store.installedAgents) { agent in
                        Button(agent.name) { selectedAgentID = agent.id }
                    }
                } label: {
                    HStack {
                        Text(currentAgentName)
                            .font(ClayFont.body)
                            .foregroundStyle(Color.clayText)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.clayTextMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clayCard(radius: 8)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            field(index: 2, label: "Working Directory") {
                HStack(spacing: 8) {
                    TextField("", text: $workingDirectory)
                        .textFieldStyle(.plain)
                        .font(ClayFont.mono)
                        .foregroundStyle(Color.clayText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .clayCard(radius: 8)
                    Button("Choose") { pickFolder() }
                        .buttonStyle(ClayButtonStyle(prominent: false))
                }
            }

            field(index: 3, label: "Initial Prompt") {
                TextEditor(text: $prompt)
                    .font(ClayFont.mono)
                    .foregroundStyle(Color.clayText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 140)
                    .clayCard(radius: 8)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(ClayButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Dispatch") { spawn() }
                    .buttonStyle(ClayButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedAgentID.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.clayBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            if selectedAgentID.isEmpty {
                selectedAgentID = store.installedAgents.first?.id ?? ""
            }
            workingDirectory = store.defaultWorkingDirectory
        }
    }

    private var currentAgentName: String {
        store.installedAgents.first(where: { $0.id == selectedAgentID })?.name ?? "Select agent…"
    }

    @ViewBuilder
    private func field<Content: View>(index: Int, label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GhostNumber(index)
                Text(label.uppercased())
                    .font(ClayFont.sectionLabel)
                    .kerning(1.2)
                    .foregroundStyle(Color.clayTextMuted)
            }
            content()
        }
    }

    private func spawn() {
        guard store.installedAgents.contains(where: { $0.id == selectedAgentID }) else { return }
        let title = prompt.isEmpty ? "Untitled task" : String(prompt.prefix(50))
        let task = AgentTask(
            title: title,
            prompt: prompt,
            agentID: selectedAgentID,
            workingDirectory: workingDirectory
        )
        store.addTask(task)
        dismiss()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        // panel.runModal() blocks main thread — acceptable for a folder picker.
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
}

/// Clay-styled button: no bright accent, just the clay card treatment.
struct ClayButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClayFont.bodyMedium)
            .kerning(0.3)
            .foregroundStyle(Color.clayText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? Color.clayActive : Color.claySurface)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(prominent ? Color.clayBorder : Color.clayHighlight, lineWidth: 1)
                }
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
