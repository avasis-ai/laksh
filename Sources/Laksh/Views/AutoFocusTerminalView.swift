import AppKit
import SwiftTerm

/// NSView container that ensures LocalProcessTerminalView always holds keyboard focus.
///
/// Root causes fixed here:
/// 1. SwiftTerm's mouseDown never calls makeFirstResponder — fixed via NSClickGestureRecognizer.
/// 2. SwiftUI toolbar above the terminal settles AFTER viewDidMoveToWindow fires, stealing focus back.
///    Fixed by using a 0.15s delay (after SwiftUI layout completes) + NSWindow.didBecomeKeyNotification.
/// 3. Frame resize forwarded to SwiftTerm so the terminal grid reflows on window resize.
final class TerminalContainerView: NSView {
    let terminalView: LocalProcessTerminalView
    private var windowObserver: NSObjectProtocol?

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        addSubview(terminalView)

        // Fire makeFirstResponder on every click inside the terminal.
        // delaysPrimaryMouseButtonEvents=false means SwiftTerm still gets
        // the undelayed mouseDown for text selection etc.
        let click = NSClickGestureRecognizer(target: self, action: #selector(focusTerminal))
        click.delaysPrimaryMouseButtonEvents = false
        terminalView.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = windowObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        terminalView.frame = NSRect(origin: .zero, size: newSize)
        terminalView.needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Clean up previous observer when moving between windows.
        if let obs = windowObserver {
            NotificationCenter.default.removeObserver(obs)
            windowObserver = nil
        }

        guard let window else { return }

        // 0.15s delay gives SwiftUI time to finish its layout pass and
        // resolve any toolbar button focus before we claim the terminal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.window != nil else { return }
            window.makeFirstResponder(self.terminalView)
        }

        // Re-claim focus whenever the window becomes key again
        // (e.g. user switches away and back).
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window != nil else { return }
            window.makeFirstResponder(self.terminalView)
        }
    }

    /// Clicking anywhere on the container border/padding also gives focus.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
        super.mouseDown(with: event)
    }

    @objc private func focusTerminal(_ recognizer: NSClickGestureRecognizer) {
        recognizer.view?.window?.makeFirstResponder(terminalView)
    }

    override var acceptsFirstResponder: Bool { true }
}
