import SwiftUI
import SwiftTerm
import AppKit

/// Terminal pane for a native shell session.
/// Uses NSViewControllerRepresentable so we get viewDidAppear — the only reliable
/// place to call makeFirstResponder after SwiftUI has fully settled its layout.
struct NativeTerminalPane: NSViewControllerRepresentable {
    let session: NativeSession

    func makeNSViewController(context: Context) -> NativeTerminalVC {
        NativeTerminalVC(session: session)
    }

    func updateNSViewController(_ vc: NativeTerminalVC, context: Context) {}
}

final class NativeTerminalVC: NSViewController {
    private let session: NativeSession
    private var windowObserver: NSObjectProtocol?

    init(session: NativeSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let tv: NativeShellView = session.terminalView
        tv.nativeBackgroundColor = NSColor(srgbRed: 0x08/255, green: 0x08/255, blue: 0x08/255, alpha: 1)
        tv.nativeForegroundColor = NSColor(srgbRed: 0xED/255, green: 0xE8/255, blue: 0xDF/255, alpha: 1)
        tv.font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont(name: "Menlo", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        self.view = tv
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // viewDidAppear fires after ALL layout is settled — safe to claim focus.
        view.window?.makeFirstResponder(view)
        session.start()

        // Re-claim focus when window regains key status.
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
