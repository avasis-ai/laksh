# Laksh Codebase Guide — for OpenClaw

## App Summary
macOS SwiftUI app (no Electron, no web). Manages CLI agents (claude, cursor, aider, codex, openclaw) via real terminal sessions. Kanban board + system-wide agent scanner.

## Critical Patterns — Follow These Exactly

### 1. Actor Isolation
- `SessionStore` is `@MainActor final class`. ALL mutations go through it.
- `SystemAgentScanner` is NOT @MainActor — it has @Published props modified via `Task { }` and Combine sinks that receive on main. DO NOT add @MainActor to it.
- `AgentSession` and `NativeSession` are `final class: ObservableObject` — NOT actors. Their @Published mutations must be on main thread. Use `Task { @MainActor in }` or `DispatchQueue.main.async` in delegate callbacks.
- `PerformanceMonitor` samples on `bgQueue: DispatchQueue(label: "laksh.perfmon", qos: .utility)` and publishes to main via `DispatchQueue.main.async`.

### 2. SwiftUI ↔ AppKit Bridge
- `TerminalPane` and `NativeTerminalPane` are `NSViewRepresentable` returning `TerminalContainerView`.
- `TerminalContainerView: NSView` wraps `LocalProcessTerminalView` (SwiftTerm).
- Focus is handled by `TerminalContainerView` via `NSClickGestureRecognizer` + `viewDidMoveToWindow`.
- `makeNSView` uses a `Coordinator { var didStart = false }` to prevent double-starting the process.
- NEVER call `makeFirstResponder` in `updateNSView` — it breaks text selection.

### 3. Design System — Use These, Never Hardcode Colors/Fonts
```swift
// Colors
Color.clayBackground   // #080808 — main canvas
Color.clayCanvas       // alias for clayBackground
Color.clayText         // #EDE8DF cream
Color.clayTextMuted    // cream @ 55%
Color.clayTextDim      // alias for clayTextMuted
Color.claySurface      // white @ 3% — card backgrounds
Color.clayActive       // cream @ 8% — selected state
Color.clayBorder       // cream @ 14% — borders
Color.clayDivider      // alias for clayBorder
Color.clayHighlight    // white @ 6% — top inset on cards
Color.clayHover        // white @ 5% — hover state
Color.agentRunning     // #7FB069 desaturated green
Color.agentIdle        // #555 gray
Color.clayRunning      // alias for agentRunning

// Typography
ClayFont.title         // 15pt semibold
ClayFont.body          // 13pt
ClayFont.bodyMedium    // 13pt medium
ClayFont.caption       // 12pt
ClayFont.mono          // 12pt monospaced
ClayFont.monoSmall     // 11pt monospaced
ClayFont.tiny          // 11pt
ClayFont.ghost         // 11pt medium monospaced (for ghost numbers)
ClayFont.sectionLabel  // 10pt semibold monospaced (for SECTION HEADERS)

// Components
GhostNumber(_ n: Int)           // renders "01", "02", etc. in ghostNumber color
BlueprintMark()                 // decorative SVG line mark for header
ClayCard(isActive: Bool)        // ViewModifier: surface + top-inset highlight + optional active state
.clayCard(isActive: Bool)       // convenience extension on View
```

### 4. Key Types
```swift
// Models
struct AgentTask: Identifiable, Codable     // persisted to UserDefaults
enum TaskStatus: queued | running | done
final class AgentSession: ObservableObject  // wraps LocalProcessTerminalView for an agent process
final class NativeSession: ObservableObject // wraps LocalProcessTerminalView for a plain shell
struct ExternalAgent: Identifiable, Hashable // system-detected agent from ps aux

// Store
@MainActor final class SessionStore: ObservableObject
  var tasks: [AgentTask]          // persisted — use addTask/startTask/pauseTask/stopTask/deleteTask
  var sessions: [AgentSession]    // in-memory only
  var nativeSessions: [NativeSession]
  var externalAgents: [ExternalAgent]  // forwarded from SystemAgentScanner via Combine
  var activeSessionID: UUID?           // nil = show KanbanBoard
  var activeNativeSessionID: UUID?     // takes priority over activeSessionID
  var isSidebarCollapsed: Bool
  var isScanning: Bool

// Scanner
final class SystemAgentScanner: ObservableObject  // NOT @MainActor
  func scan()       // debounced, runs on background queue
  func kill(pid:)   // SIGTERM then rescan
  func forceKill(pid:)  // SIGKILL
```

### 5. View Hierarchy
```
LakshApp (WindowGroup)
  └─ RootView
      ├─ Sidebar (if !isSidebarCollapsed)
      │   ├─ header (BlueprintMark + title + scan button)
      │   ├─ agentsSection (detected CLI agents)
      │   ├─ sessionsSection (active AgentSessions)
      │   ├─ shellsSection (NativeSessions + New Shell button)
      │   ├─ performanceBar (PerformanceIndicator)
      │   └─ footer (New Task button)
      └─ content area
          ├─ alwaysVisibleToolbar (sidebar toggle + back/session info when in terminal)
          └─ KanbanBoard | TerminalPane | NativeTerminalPane
```

### 6. Kanban Columns
- **Idle**: `queuedTasks` + idle `NativeSessions` + idle `ExternalAgents` (appearsIdle = cpuUsage < 1.0)
- **Running**: `runningTasks` + running `NativeSessions` + active `ExternalAgents`
- **Done**: `doneTasks`
- Drag `UTType.plainText` with task UUID as string via `NSItemProvider(object: uuid as NSString)`
- Drop handlers: Idle → `pauseTask`, Done → `stopTask`

### 7. Agent Detection in Shells
`NativeSession` monitors SwiftTerm output via `ShellDelegateProxy.rangeChanged`.
Static `agentRegexCache` (pre-compiled NSRegularExpressions) checks each line.
On match → sets `detectedAgentInvocation`.
`SessionStore.setupAgentDetection` subscribes via Combine and auto-creates an `AgentTask`.

### 8. Common Anti-Patterns to Fix
- `DispatchQueue.main.async { }` in delegate callbacks → prefer `Task { @MainActor in }`
- NSRegularExpression compiled inside loops → use `agentRegexCache` pattern (static let)
- `session.start()` called in `makeNSView` without `Coordinator.didStart` guard → double-start
- `updateNSView` doing work other than pure UI sync → should usually be empty
- Missing `[weak self]` in Timer callbacks, Combine sinks, DispatchQueue.async closures
- `removeAll { }` on @Published arrays without being on main thread
- `Color(red:green:blue:)` hardcoded instead of DesignSystem colors
- Ghost step numbers called as `GhostNumber(n: x)` — use `GhostNumber(x)` (positional init)
