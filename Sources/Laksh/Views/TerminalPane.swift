import SwiftUI
import SwiftTerm
import AppKit

/// Terminal pane for an AgentSession.
/// Uses NSViewControllerRepresentable so viewDidAppear fires after SwiftUI layout settles.
struct TerminalPane: NSViewControllerRepresentable {
    let session: AgentSession

    func makeNSViewController(context: Context) -> AgentTerminalVC {
        AgentTerminalVC(session: session)
    }

    func updateNSViewController(_ vc: AgentTerminalVC, context: Context) {}
}

final class AgentTerminalVC: NSViewController {
    private let session: AgentSession
    private var windowObserver: NSObjectProtocol?

    init(session: AgentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let tv: AgentShellView = session.terminalView
        tv.nativeBackgroundColor = NSColor(srgbRed: 0x08/255, green: 0x08/255, blue: 0x08/255, alpha: 1)
        tv.nativeForegroundColor = NSColor(srgbRed: 0xED/255, green: 0xE8/255, blue: 0xDF/255, alpha: 1)
        tv.font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont(name: "Menlo", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        self.view = tv
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        session.start()

        if windowObserver == nil, let window = view.window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.view.window != nil else { return }
                self.view.window?.makeFirstResponder(self.view)
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let obs = windowObserver {
            NotificationCenter.default.removeObserver(obs)
            windowObserver = nil
        }
    }
}
