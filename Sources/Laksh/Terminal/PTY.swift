import Foundation

/// Low-level PTY (pseudo-terminal) management
/// Inspired by Ghostty's pty.zig but in Swift
final class PTY {
    let master: Int32
    let slave: Int32
    let slavePath: String
    
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "laksh.pty.read", qos: .userInteractive)
    
    var onOutput: ((Data) -> Void)?
    
    struct Size {
        var rows: UInt16
        var cols: UInt16
        var xPixel: UInt16
        var yPixel: UInt16
        
        init(rows: UInt16 = 24, cols: UInt16 = 80, xPixel: UInt16 = 0, yPixel: UInt16 = 0) {
            self.rows = rows
            self.cols = cols
            self.xPixel = xPixel
            self.yPixel = yPixel
        }
        
        var winsize: winsize {
            Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: xPixel, ws_ypixel: yPixel)
        }
    }
    
    enum PTYError: Error {
        case openptFailed
        case grantptFailed
        case unlockptFailed
        case ptsnameFailed
        case slaveopenFailed
        case forkFailed
        case execFailed
    }
    
    init(size: Size = Size()) throws {
        // Open master PTY
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError.openptFailed }
        
        // Grant access to slave
        guard grantpt(master) == 0 else {
            close(master)
            throw PTYError.grantptFailed
        }
        
        // Unlock slave
        guard unlockpt(master) == 0 else {
            close(master)
            throw PTYError.unlockptFailed
        }
        
        // Get slave path
        guard let slaveName = ptsname(master) else {
            close(master)
            throw PTYError.ptsnameFailed
        }
        let slavePath = String(cString: slaveName)
        
        // Open slave
        let slave = open(slavePath, O_RDWR)
        guard slave >= 0 else {
            close(master)
            throw PTYError.slaveopenFailed
        }
        
        self.master = master
        self.slave = slave
        self.slavePath = slavePath
        
        // Set initial size
        setSize(size)
        
        // Set non-blocking on master for async reads
        var flags = fcntl(master, F_GETFL)
        flags |= O_NONBLOCK
        fcntl(master, F_SETFL, flags)
    }
    
    deinit {
        stopReading()
        close(slave)
        close(master)
    }
    
    func setSize(_ size: Size) {
        var ws = size.winsize
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }
    
    func getSize() -> Size {
        var ws = winsize()
        _ = ioctl(master, TIOCGWINSZ, &ws)
        return Size(rows: ws.ws_row, cols: ws.ws_col, xPixel: ws.ws_xpixel, yPixel: ws.ws_ypixel)
    }
    
    /// Write data to the PTY (sends to child process)
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = Darwin.write(master, ptr, buffer.count)
        }
    }
    
    /// Write string to the PTY
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
    
    /// Start async reading from PTY
    func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        
        source.setEventHandler { [weak self] in
            self?.handleRead()
        }
        
        source.setCancelHandler { [weak self] in
            self?.readSource = nil
        }
        
        self.readSource = source
        source.resume()
    }
    
    func stopReading() {
        readSource?.cancel()
        readSource = nil
    }
    
    private func handleRead() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(master, &buffer, buffer.count)
        
        if bytesRead > 0 {
            let data = Data(bytes: buffer, count: bytesRead)
            DispatchQueue.main.async { [weak self] in
                self?.onOutput?(data)
            }
        }
    }
    
    /// Spawn a child process in this PTY
    func spawn(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        
        // Child: dup slave to stdin/stdout/stderr, close master
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        
        // Start new session (become session leader, get controlling terminal)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))
        
        // Build environment
        var env = environment ?? ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        if let cwd = workingDirectory {
            env["PWD"] = cwd
        }
        
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { key, value in
            strdup("\(key)=\(value)")
        } + [nil]
        defer { envp.forEach { $0.map { free($0) } } }
        
        // Build argv
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable)] + arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { $0.map { free($0) } } }
        
        // Change to working directory before spawn
        let originalDir = FileManager.default.currentDirectoryPath
        if let cwd = workingDirectory {
            FileManager.default.changeCurrentDirectoryPath(cwd)
        }
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDir)
        }
        
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &fileActions, &attrs, argv, envp)
        
        guard result == 0 else {
            throw PTYError.execFailed
        }
        
        return pid
    }
}
