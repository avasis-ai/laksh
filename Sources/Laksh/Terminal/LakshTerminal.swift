import Foundation
import SwiftUI
import MetalKit
import Combine

/// High-performance terminal emulator for Laksh
/// Inspired by Ghostty's architecture: PTY + Parser + Buffer + Metal Renderer
final class LakshTerminal: ObservableObject {
    
    private var pty: PTY?
    private let parser = TerminalParser()
    @Published private(set) var buffer: TerminalBuffer
    
    private(set) var childPID: pid_t?
    private var processMonitor: DispatchSourceProcess?
    
    @Published var isRunning = false
    @Published var exitCode: Int32?
    
    var onExit: ((Int32) -> Void)?
    
    let rows: Int
    let cols: Int
    
    init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.buffer = TerminalBuffer(rows: rows, cols: cols)
        
        setupParser()
    }
    
    deinit {
        stop()
    }
    
    private func setupParser() {
        parser.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
    }
    
    // MARK: - Session Management
    
    func start(
        shell: String? = nil,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) throws {
        guard !isRunning else { return }
        
        // Determine shell
        let shellPath = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        
        // Create PTY
        let pty = try PTY(size: PTY.Size(rows: UInt16(rows), cols: UInt16(cols)))
        self.pty = pty
        
        // Setup output handler
        pty.onOutput = { [weak self] data in
            self?.handleOutput(data)
        }
        
        // Spawn shell
        let pid = try pty.spawn(
            executable: shellPath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        
        childPID = pid
        isRunning = true
        
        // Start reading from PTY
        pty.startReading()
        
        // Monitor child process
        monitorProcess(pid)
    }
    
    func stop() {
        processMonitor?.cancel()
        processMonitor = nil
        
        if let pid = childPID {
            kill(pid, SIGTERM)
        }
        
        pty?.stopReading()
        pty = nil
        childPID = nil
        isRunning = false
    }
    
    private func monitorProcess(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            
            // WIFEXITED and WEXITSTATUS macros reimplemented
            let wstatus = Int32(bitPattern: UInt32(bitPattern: status))
            let exited = (wstatus & 0x7F) == 0
            let code = exited ? ((wstatus >> 8) & 0xFF) : -1
            self?.handleExit(code)
        }
        
        source.setCancelHandler { [weak self] in
            self?.processMonitor = nil
        }
        
        self.processMonitor = source
        source.resume()
    }
    
    private func handleExit(_ code: Int32) {
        isRunning = false
        exitCode = code
        onExit?(code)
    }
    
    // MARK: - Input
    
    func write(_ string: String) {
        pty?.write(string)
    }
    
    func write(_ data: Data) {
        pty?.write(data)
    }
    
    func sendKey(_ key: TerminalKey) {
        write(key.sequence)
    }
    
    // MARK: - Resize
    
    func resize(rows: Int, cols: Int) {
        buffer.resize(rows: rows, cols: cols)
        pty?.setSize(PTY.Size(rows: UInt16(rows), cols: UInt16(cols)))
    }
    
    // MARK: - Output Processing
    
    private func handleOutput(_ data: Data) {
        parser.parse(data)
        objectWillChange.send()
    }
    
    private func handleEvent(_ event: TerminalParser.Event) {
        switch event {
        case .print(let char):
            buffer.write(char)
        case .printString(let str):
            buffer.write(str)
        case .execute:
            break
        case .bell:
            NSSound.beep()
        case .backspace:
            buffer.moveCursorBack()
        case .tab:
            buffer.tab()
        case .lineFeed:
            buffer.lineFeed()
        case .carriageReturn:
            buffer.carriageReturn()
        case .cursorPosition(let row, let col):
            buffer.moveCursor(to: row - 1, col: col - 1)
        case .cursorUp(let n):
            buffer.moveCursorUp(n)
        case .cursorDown(let n):
            buffer.moveCursorDown(n)
        case .cursorForward(let n):
            buffer.moveCursorForward(n)
        case .cursorBack(let n):
            buffer.moveCursorBack(n)
        case .eraseInDisplay(let mode):
            buffer.eraseInDisplay(mode)
        case .eraseInLine(let mode):
            buffer.eraseInLine(mode)
        case .setScrollRegion(let top, let bottom):
            buffer.setScrollRegion(top: top, bottom: bottom)
        case .sgr(let attrs):
            buffer.applyAttributes(attrs)
        case .setMode(let mode):
            buffer.setMode(mode)
        case .resetMode(let mode):
            buffer.resetMode(mode)
        case .saveCursor:
            buffer.saveCursor()
        case .restoreCursor:
            buffer.restoreCursor()
        case .setTitle(let title):
            buffer.title = title
        case .csi, .osc:
            break // Unhandled sequences
        }
    }
}

// MARK: - Key Mappings

enum TerminalKey {
    case enter
    case tab
    case backspace
    case escape
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case insert
    case f(Int)
    case character(Character)
    case characterWithControl(Character)
    case characterWithMeta(Character)
    
    var sequence: String {
        switch self {
        case .enter: return "\r"
        case .tab: return "\t"
        case .backspace: return "\u{7F}"
        case .escape: return "\u{1B}"
        case .delete: return "\u{1B}[3~"
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .right: return "\u{1B}[C"
        case .left: return "\u{1B}[D"
        case .home: return "\u{1B}[H"
        case .end: return "\u{1B}[F"
        case .pageUp: return "\u{1B}[5~"
        case .pageDown: return "\u{1B}[6~"
        case .insert: return "\u{1B}[2~"
        case .f(let n):
            let codes = ["", "OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~"]
            if n >= 1 && n <= 12 {
                return "\u{1B}" + codes[n]
            }
            return ""
        case .character(let c):
            return String(c)
        case .characterWithControl(let c):
            // Control sequences: Ctrl+A = 0x01, etc.
            let code = c.asciiValue ?? 0
            if code >= 64 && code < 96 {
                return String(UnicodeScalar(code - 64))
            } else if code >= 97 && code < 123 {
                return String(UnicodeScalar(code - 96))
            }
            return String(c)
        case .characterWithMeta(let c):
            return "\u{1B}" + String(c)
        }
    }
}

// MARK: - SwiftUI View

struct LakshTerminalView: NSViewRepresentable {
    @ObservedObject var terminal: LakshTerminal
    
    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.031, green: 0.031, blue: 0.031, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        
        if let renderer = MetalTerminalRenderer(device: device, buffer: terminal.buffer) {
            context.coordinator.renderer = renderer
            mtkView.delegate = renderer
        }
        
        // Setup keyboard handling
        let keyView = KeyInputView(terminal: terminal)
        keyView.frame = mtkView.bounds
        keyView.autoresizingMask = [.width, .height]
        mtkView.addSubview(keyView)
        context.coordinator.keyView = keyView
        
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.updateBuffer(terminal.buffer)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var renderer: MetalTerminalRenderer?
        var keyView: KeyInputView?
    }
}

// MARK: - Key Input View

class KeyInputView: NSView {
    weak var terminal: LakshTerminal?
    
    init(terminal: LakshTerminal) {
        self.terminal = terminal
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    override func becomeFirstResponder() -> Bool {
        true
    }
    
    override func keyDown(with event: NSEvent) {
        guard let terminal = terminal else { return }
        
        let flags = event.modifierFlags
        let hasControl = flags.contains(.control)
        let hasMeta = flags.contains(.option)
        let hasCommand = flags.contains(.command)
        
        // Handle special keys
        switch event.keyCode {
        case 36: // Return
            terminal.sendKey(.enter)
        case 48: // Tab
            terminal.sendKey(.tab)
        case 51: // Delete/Backspace
            terminal.sendKey(.backspace)
        case 53: // Escape
            terminal.sendKey(.escape)
        case 117: // Forward Delete
            terminal.sendKey(.delete)
        case 126: // Up
            terminal.sendKey(.up)
        case 125: // Down
            terminal.sendKey(.down)
        case 123: // Left
            terminal.sendKey(.left)
        case 124: // Right
            terminal.sendKey(.right)
        case 115: // Home
            terminal.sendKey(.home)
        case 119: // End
            terminal.sendKey(.end)
        case 116: // Page Up
            terminal.sendKey(.pageUp)
        case 121: // Page Down
            terminal.sendKey(.pageDown)
        case 122: terminal.sendKey(.f(1))
        case 120: terminal.sendKey(.f(2))
        case 99: terminal.sendKey(.f(3))
        case 118: terminal.sendKey(.f(4))
        case 96: terminal.sendKey(.f(5))
        case 97: terminal.sendKey(.f(6))
        case 98: terminal.sendKey(.f(7))
        case 100: terminal.sendKey(.f(8))
        case 101: terminal.sendKey(.f(9))
        case 109: terminal.sendKey(.f(10))
        case 103: terminal.sendKey(.f(11))
        case 111: terminal.sendKey(.f(12))
        default:
            // Regular character input
            if let chars = event.characters, !chars.isEmpty {
                for char in chars {
                    if hasCommand {
                        // Let system handle Cmd shortcuts
                        super.keyDown(with: event)
                    } else if hasControl {
                        terminal.sendKey(.characterWithControl(char))
                    } else if hasMeta {
                        terminal.sendKey(.characterWithMeta(char))
                    } else {
                        terminal.sendKey(.character(char))
                    }
                }
            }
        }
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Could handle modifier-only events if needed
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}
