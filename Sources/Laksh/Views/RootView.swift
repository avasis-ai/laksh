import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            if !store.isSidebarCollapsed {
                Sidebar()
                    .transition(.move(edge: .leading))

                Rectangle()
                    .fill(Color.clayDivider)
                    .frame(width: 1)
            }

            VStack(spacing: 0) {
                alwaysVisibleToolbar

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.clayBackground)
        }
        .background(Color.clayBackground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.showNewTaskSheet) {
            NewTaskSheet().environmentObject(store)
        }
        .animation(.easeInOut(duration: 0.2), value: store.isSidebarCollapsed)
    }

    /// Always visible thin toolbar with sidebar toggle + scan.
    private var alwaysVisibleToolbar: some View {
        HStack(spacing: 12) {
            Button {
                store.isSidebarCollapsed.toggle()
            } label: {
                Image(systemName: store.isSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.clayTextMuted)
            }
            .buttonStyle(.plain)
            .help(store.isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            if store.isSidebarCollapsed {
                Text("Laksh")
                    .font(ClayFont.bodyMedium)
                    .foregroundStyle(Color.clayText)
            }

            if let id = store.activeNativeSessionID,
               let session = store.nativeSessions.first(where: { $0.id == id }) {
                Button {
                    store.activeNativeSessionID = nil
                    store.activeSessionID = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Board")
                    }
                    .font(ClayFont.body)
                    .foregroundStyle(Color.clayTextMuted)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(session.isRunning ? Color.agentRunning : Color.agentIdle)
                        .frame(width: 6, height: 6)
                    Text(session.title)
                        .font(ClayFont.body)
                        .foregroundStyle(Color.clayText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.claySurface)
                .cornerRadius(6)

                Button {
                    store.closeNativeSession(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.clayTextMuted)
                }
                .buttonStyle(.plain)

            } else if let id = store.activeSessionID,
                      store.sessions.contains(where: { $0.id == id }) {
                Button {
                    store.activeSessionID = nil
                    store.activeNativeSessionID = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Board")
                    }
                    .font(ClayFont.body)
                    .foregroundStyle(Color.clayTextMuted)
                }
                .buttonStyle(.plain)

                Spacer()

                TabBar()

            } else {
                Spacer()
            }

            if store.activeSessionID == nil && store.activeNativeSessionID == nil {
                Button {
                    store.scanSystemAgents()
                } label: {
                    HStack(spacing: 4) {
                        if store.isScanning {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        Text("Scan")
                            .font(ClayFont.tiny)
                    }
                    .foregroundStyle(Color.clayTextMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.claySurface)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.clayCanvas)
    }

    @ViewBuilder
    private var content: some View {
        if let id = store.activeNativeSessionID,
           let session = store.nativeSessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.clayDivider).frame(height: 1)
                NativeTerminalPane(session: session)
                    .id(session.id)
            }
        } else if let id = store.activeSessionID,
                  let session = store.sessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.clayDivider).frame(height: 1)
                TerminalPane(session: session)
                    .id(session.id)
            }
        } else {
            KanbanBoard()
        }
    }
}

private struct TabBar: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.sessions) { session in
                    TabItem(
                        session: session,
                        isActive: session.id == store.activeSessionID,
                        onSelect: {
                            store.activeSessionID = session.id
                            store.activeNativeSessionID = nil
                        },
                        onClose: { store.closeSession(session) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.clayBackground)
    }
}

private struct TabItem: View {
    @ObservedObject var session: AgentSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Color.agentRunning : Color.agentIdle)
                .frame(width: 5, height: 5)
            Text(session.title)
                .font(ClayFont.body)
                .foregroundStyle(isActive ? Color.clayText : Color.clayTextMuted)
                .lineLimit(1)
            if hover || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.clayTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.clayActive : (hover ? Color.clayHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.clayBorder : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hover = $0 }
    }
}
