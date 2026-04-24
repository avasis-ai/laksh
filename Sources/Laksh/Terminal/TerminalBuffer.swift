import Foundation

/// Terminal screen buffer - stores character grid and attributes
/// Similar to Ghostty's Screen.zig
final class TerminalBuffer: ObservableObject {
    
    struct Cell {
        var character: Character = " "
        var foreground: Color = .default
        var background: Color = .default
        var attributes: Attributes = []
        var dirty: Bool = true
        
        struct Attributes: OptionSet {
            let rawValue: UInt8
            
            static let bold = Attributes(rawValue: 1 << 0)
            static let dim = Attributes(rawValue: 1 << 1)
            static let italic = Attributes(rawValue: 1 << 2)
            static let underline = Attributes(rawValue: 1 << 3)
            static let blink = Attributes(rawValue: 1 << 4)
            static let inverse = Attributes(rawValue: 1 << 5)
            static let hidden = Attributes(rawValue: 1 << 6)
            static let strikethrough = Attributes(rawValue: 1 << 7)
        }
        
        enum Color: Equatable {
            case `default`
            case indexed(UInt8)
            case rgb(UInt8, UInt8, UInt8)
        }
    }
    
    struct CursorState {
        var row: Int = 0
        var col: Int = 0
        var visible: Bool = true
        var style: CursorStyle = .block
        
        enum CursorStyle {
            case block
            case underline
            case bar
        }
    }
    
    private(set) var rows: Int
    private(set) var cols: Int
    private var cells: [[Cell]]
    private var altCells: [[Cell]]?
    private var isAltScreen = false
    
    @Published private(set) var cursor = CursorState()
    private var savedCursor: CursorState?
    
    private var currentForeground: Cell.Color = .default
    private var currentBackground: Cell.Color = .default
    private var currentAttributes: Cell.Attributes = []
    
    private var scrollTop: Int = 0
    private var scrollBottom: Int
    
    private(set) var dirty = true
    private(set) var dirtyRows: Set<Int> = []
    
    @Published var title: String = ""
    
    init(rows: Int = 24, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.cells = Self.createGrid(rows: rows, cols: cols)
    }
    
    private static func createGrid(rows: Int, cols: Int) -> [[Cell]] {
        (0..<rows).map { _ in
            [Cell](repeating: Cell(), count: cols)
        }
    }
    
    func resize(rows: Int, cols: Int) {
        guard rows != self.rows || cols != self.cols else { return }
        
        let oldRows = self.rows
        let oldCols = self.cols
        
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        
        // Resize main buffer
        cells = resizeGrid(cells, oldRows: oldRows, oldCols: oldCols, newRows: rows, newCols: cols)
        
        // Resize alt buffer if exists
        if var alt = altCells {
            alt = resizeGrid(alt, oldRows: oldRows, oldCols: oldCols, newRows: rows, newCols: cols)
            altCells = alt
        }
        
        // Clamp cursor
        cursor.row = min(cursor.row, rows - 1)
        cursor.col = min(cursor.col, cols - 1)
        
        markAllDirty()
    }
    
    private func resizeGrid(_ grid: [[Cell]], oldRows: Int, oldCols: Int, newRows: Int, newCols: Int) -> [[Cell]] {
        var newGrid = Self.createGrid(rows: newRows, cols: newCols)
        
        let copyRows = min(oldRows, newRows)
        let copyCols = min(oldCols, newCols)
        
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newGrid[r][c] = grid[r][c]
            }
        }
        
        return newGrid
    }
    
    // MARK: - Cell Access
    
    func cell(at row: Int, col: Int) -> Cell {
        guard row >= 0 && row < rows && col >= 0 && col < cols else {
            return Cell()
        }
        return cells[row][col]
    }
    
    private func setCell(_ cell: Cell, at row: Int, col: Int) {
        guard row >= 0 && row < rows && col >= 0 && col < cols else { return }
        cells[row][col] = cell
        cells[row][col].dirty = true
        dirtyRows.insert(row)
        dirty = true
    }
    
    // MARK: - Cursor Movement
    
    func moveCursor(to row: Int, col: Int) {
        cursor.row = clamp(row, min: 0, max: rows - 1)
        cursor.col = clamp(col, min: 0, max: cols - 1)
    }
    
    func moveCursorUp(_ n: Int = 1) {
        cursor.row = max(scrollTop, cursor.row - n)
    }
    
    func moveCursorDown(_ n: Int = 1) {
        cursor.row = min(scrollBottom, cursor.row + n)
    }
    
    func moveCursorForward(_ n: Int = 1) {
        cursor.col = min(cols - 1, cursor.col + n)
    }
    
    func moveCursorBack(_ n: Int = 1) {
        cursor.col = max(0, cursor.col - n)
    }
    
    func carriageReturn() {
        cursor.col = 0
    }
    
    func lineFeed() {
        if cursor.row >= scrollBottom {
            scrollUp()
        } else {
            cursor.row += 1
        }
    }
    
    func tab() {
        let nextTab = ((cursor.col / 8) + 1) * 8
        cursor.col = min(nextTab, cols - 1)
    }
    
    func saveCursor() {
        savedCursor = cursor
    }
    
    func restoreCursor() {
        if let saved = savedCursor {
            cursor = saved
        }
    }
    
    // MARK: - Scrolling
    
    func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, top - 1) // Convert to 0-indexed
        let b = bottom == 0 ? rows - 1 : min(rows - 1, bottom - 1)
        
        if t < b {
            scrollTop = t
            scrollBottom = b
        }
    }
    
    func scrollUp(_ n: Int = 1) {
        for _ in 0..<n {
            // Move rows up
            for r in scrollTop..<scrollBottom {
                cells[r] = cells[r + 1]
            }
            // Clear bottom row
            cells[scrollBottom] = [Cell](repeating: Cell(), count: cols)
        }
        markAllDirty()
    }
    
    func scrollDown(_ n: Int = 1) {
        for _ in 0..<n {
            // Move rows down
            for r in stride(from: scrollBottom, to: scrollTop, by: -1) {
                cells[r] = cells[r - 1]
            }
            // Clear top row
            cells[scrollTop] = [Cell](repeating: Cell(), count: cols)
        }
        markAllDirty()
    }
    
    // MARK: - Writing
    
    func write(_ char: Character) {
        var cell = Cell()
        cell.character = char
        cell.foreground = currentForeground
        cell.background = currentBackground
        cell.attributes = currentAttributes
        
        setCell(cell, at: cursor.row, col: cursor.col)
        
        cursor.col += 1
        if cursor.col >= cols {
            cursor.col = 0
            lineFeed()
        }
    }
    
    func write(_ string: String) {
        for char in string {
            write(char)
        }
    }
    
    // MARK: - Erasing
    
    func eraseInDisplay(_ mode: TerminalParser.EraseMode) {
        switch mode {
        case .toEnd:
            eraseInLine(.toEnd)
            for r in (cursor.row + 1)..<rows {
                clearRow(r)
            }
        case .toBeginning:
            eraseInLine(.toBeginning)
            for r in 0..<cursor.row {
                clearRow(r)
            }
        case .all, .scrollback:
            for r in 0..<rows {
                clearRow(r)
            }
        }
    }
    
    func eraseInLine(_ mode: TerminalParser.EraseMode) {
        switch mode {
        case .toEnd:
            for c in cursor.col..<cols {
                setCell(Cell(), at: cursor.row, col: c)
            }
        case .toBeginning:
            for c in 0...cursor.col {
                setCell(Cell(), at: cursor.row, col: c)
            }
        case .all, .scrollback:
            clearRow(cursor.row)
        }
    }
    
    private func clearRow(_ row: Int) {
        for c in 0..<cols {
            setCell(Cell(), at: row, col: c)
        }
    }
    
    // MARK: - Attributes
    
    func applyAttributes(_ attrs: [TerminalParser.SGRAttribute]) {
        for attr in attrs {
            switch attr {
            case .reset:
                currentForeground = .default
                currentBackground = .default
                currentAttributes = []
            case .bold:
                currentAttributes.insert(.bold)
            case .dim:
                currentAttributes.insert(.dim)
            case .italic:
                currentAttributes.insert(.italic)
            case .underline:
                currentAttributes.insert(.underline)
            case .blink:
                currentAttributes.insert(.blink)
            case .inverse:
                currentAttributes.insert(.inverse)
            case .hidden:
                currentAttributes.insert(.hidden)
            case .strikethrough:
                currentAttributes.insert(.strikethrough)
            case .normal, .noBold:
                currentAttributes.remove(.bold)
                currentAttributes.remove(.dim)
            case .noItalic:
                currentAttributes.remove(.italic)
            case .noUnderline:
                currentAttributes.remove(.underline)
            case .noBlink:
                currentAttributes.remove(.blink)
            case .noInverse:
                currentAttributes.remove(.inverse)
            case .noHidden:
                currentAttributes.remove(.hidden)
            case .noStrikethrough:
                currentAttributes.remove(.strikethrough)
            case .foreground(let color):
                currentForeground = convertColor(color)
            case .background(let color):
                currentBackground = convertColor(color)
            case .defaultForeground:
                currentForeground = .default
            case .defaultBackground:
                currentBackground = .default
            }
        }
    }
    
    private func convertColor(_ color: TerminalParser.Color) -> Cell.Color {
        switch color {
        case .indexed(let idx):
            return .indexed(idx)
        case .rgb(let r, let g, let b):
            return .rgb(r, g, b)
        case .default:
            return .default
        }
    }
    
    // MARK: - Modes
    
    func setMode(_ mode: TerminalParser.Mode) {
        switch mode {
        case .cursorVisible:
            cursor.visible = true
        case .altScreen, .altScreenClear:
            enterAltScreen()
        default:
            break
        }
    }
    
    func resetMode(_ mode: TerminalParser.Mode) {
        switch mode {
        case .cursorVisible:
            cursor.visible = false
        case .altScreen, .altScreenClear:
            exitAltScreen()
        default:
            break
        }
    }
    
    private func enterAltScreen() {
        guard !isAltScreen else { return }
        altCells = cells
        cells = Self.createGrid(rows: rows, cols: cols)
        isAltScreen = true
        savedCursor = cursor
        cursor = CursorState()
        markAllDirty()
    }
    
    private func exitAltScreen() {
        guard isAltScreen else { return }
        if let alt = altCells {
            cells = alt
            altCells = nil
        }
        isAltScreen = false
        restoreCursor()
        markAllDirty()
    }
    
    // MARK: - Dirty Tracking
    
    func markAllDirty() {
        dirty = true
        dirtyRows = Set(0..<rows)
        for r in 0..<rows {
            for c in 0..<cols {
                cells[r][c].dirty = true
            }
        }
    }
    
    func clearDirty() {
        dirty = false
        dirtyRows.removeAll()
        for r in 0..<rows {
            for c in 0..<cols {
                cells[r][c].dirty = false
            }
        }
    }
    
    // MARK: - Text Extraction
    
    /// Returns all visible lines as strings (for command detection)
    func getVisibleLines() -> [String] {
        var lines: [String] = []
        for r in 0..<rows {
            var line = ""
            for c in 0..<cols {
                line.append(cells[r][c].character)
            }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        return lines
    }
    
    /// Returns the text content of a specific row
    func getLine(_ row: Int) -> String {
        guard row >= 0 && row < rows else { return "" }
        var line = ""
        for c in 0..<cols {
            line.append(cells[row][c].character)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
    
    // MARK: - Helpers
    
    private func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }
}
