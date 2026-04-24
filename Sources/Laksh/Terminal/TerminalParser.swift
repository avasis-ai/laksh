import Foundation

/// VT100/xterm escape sequence parser
/// Parses terminal output and generates structured events
final class TerminalParser {
    
    enum Event {
        case print(Character)
        case printString(String)
        case execute(ControlCode)
        case csi(CSI)
        case osc(OSC)
        case sgr([SGRAttribute])
        case cursorPosition(row: Int, col: Int)
        case cursorUp(Int)
        case cursorDown(Int)
        case cursorForward(Int)
        case cursorBack(Int)
        case eraseInDisplay(EraseMode)
        case eraseInLine(EraseMode)
        case setScrollRegion(top: Int, bottom: Int)
        case setMode(Mode)
        case resetMode(Mode)
        case saveCursor
        case restoreCursor
        case bell
        case lineFeed
        case carriageReturn
        case tab
        case backspace
        case setTitle(String)
    }
    
    enum ControlCode: UInt8 {
        case nul = 0x00
        case bel = 0x07
        case bs = 0x08
        case ht = 0x09
        case lf = 0x0A
        case vt = 0x0B
        case ff = 0x0C
        case cr = 0x0D
        case so = 0x0E
        case si = 0x0F
        case esc = 0x1B
    }
    
    enum EraseMode {
        case toEnd
        case toBeginning
        case all
        case scrollback
    }
    
    enum Mode {
        case cursorKeys
        case ansi
        case column132
        case smoothScroll
        case reverseVideo
        case origin
        case autoWrap
        case autoRepeat
        case interlace
        case lineFeedNewLine
        case cursorVisible
        case altScreen
        case altScreenClear
        case bracketedPaste
        case mouseTracking
        case mouseX10
        case mouseCellMotion
        case mouseAllMotion
        case mouseSGR
        case focusEvents
    }
    
    struct CSI {
        var params: [Int]
        var intermediates: [UInt8]
        var final: UInt8
        
        var param0: Int { params.first ?? 0 }
        var param1: Int { params.count > 1 ? params[1] : 0 }
    }
    
    struct OSC {
        var command: Int
        var data: String
    }
    
    enum SGRAttribute {
        case reset
        case bold
        case dim
        case italic
        case underline
        case blink
        case inverse
        case hidden
        case strikethrough
        case normal
        case noBold
        case noItalic
        case noUnderline
        case noBlink
        case noInverse
        case noHidden
        case noStrikethrough
        case foreground(Color)
        case background(Color)
        case defaultForeground
        case defaultBackground
    }
    
    enum Color {
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
        case `default`
    }
    
    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
    }
    
    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: Int = 0
    private var intermediates: [UInt8] = []
    private var oscData: [UInt8] = []
    private var oscCommand: Int = 0
    
    var onEvent: ((Event) -> Void)?
    
    func parse(_ data: Data) {
        for byte in data {
            parseByte(byte)
        }
    }
    
    func parse(_ string: String) {
        if let data = string.data(using: .utf8) {
            parse(data)
        }
    }
    
    private func parseByte(_ byte: UInt8) {
        switch state {
        case .ground:
            parseGround(byte)
        case .escape:
            parseEscape(byte)
        case .escapeIntermediate:
            parseEscapeIntermediate(byte)
        case .csiEntry:
            parseCSIEntry(byte)
        case .csiParam:
            parseCSIParam(byte)
        case .csiIntermediate:
            parseCSIIntermediate(byte)
        case .csiIgnore:
            parseCSIIgnore(byte)
        case .oscString:
            parseOSCString(byte)
        case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough, .dcsIgnore:
            parseDCS(byte)
        }
    }
    
    private func parseGround(_ byte: UInt8) {
        switch byte {
        case 0x00...0x1A, 0x1C...0x1F:
            executeControl(byte)
        case 0x1B:
            state = .escape
        case 0x20...0x7E:
            emit(.print(Character(UnicodeScalar(byte))))
        case 0x7F:
            break // DEL, ignore
        case 0x80...0xFF:
            // UTF-8 lead byte - simplified handling
            emit(.print(Character(UnicodeScalar(byte))))
        default:
            break
        }
    }
    
    private func parseEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // [
            state = .csiEntry
            params = []
            currentParam = 0
            intermediates = []
        case 0x5D: // ]
            state = .oscString
            oscData = []
            oscCommand = 0
        case 0x50: // P - DCS
            state = .dcsEntry
        case 0x37: // 7 - DECSC
            emit(.saveCursor)
            state = .ground
        case 0x38: // 8 - DECRC
            emit(.restoreCursor)
            state = .ground
        case 0x44: // D - IND
            emit(.cursorDown(1))
            state = .ground
        case 0x45: // E - NEL
            emit(.lineFeed)
            emit(.carriageReturn)
            state = .ground
        case 0x4D: // M - RI
            emit(.cursorUp(1))
            state = .ground
        case 0x63: // c - RIS
            // Full reset
            state = .ground
        case 0x20...0x2F:
            intermediates.append(byte)
            state = .escapeIntermediate
        default:
            state = .ground
        }
    }
    
    private func parseEscapeIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x30...0x7E:
            state = .ground
        default:
            state = .ground
        }
    }
    
    private func parseCSIEntry(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // 0-9
            currentParam = Int(byte - 0x30)
            state = .csiParam
        case 0x3B: // ;
            params.append(0)
            state = .csiParam
        case 0x3C...0x3F: // < = > ?
            intermediates.append(byte)
        case 0x20...0x2F:
            intermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E:
            executeCSI(byte)
            state = .ground
        default:
            state = .ground
        }
    }
    
    private func parseCSIParam(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            currentParam = currentParam * 10 + Int(byte - 0x30)
        case 0x3B:
            params.append(currentParam)
            currentParam = 0
        case 0x20...0x2F:
            params.append(currentParam)
            intermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E:
            params.append(currentParam)
            executeCSI(byte)
            state = .ground
        case 0x3A:
            // Subparameter separator - simplified handling
            break
        default:
            state = .ground
        }
    }
    
    private func parseCSIIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20...0x2F:
            intermediates.append(byte)
        case 0x40...0x7E:
            executeCSI(byte)
            state = .ground
        default:
            state = .csiIgnore
        }
    }
    
    private func parseCSIIgnore(_ byte: UInt8) {
        if byte >= 0x40 && byte <= 0x7E {
            state = .ground
        }
    }
    
    private func parseOSCString(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL
            executeOSC()
            state = .ground
        case 0x1B:
            // Check for ST (ESC \)
            state = .escape
        case 0x30...0x39 where oscData.isEmpty:
            oscCommand = oscCommand * 10 + Int(byte - 0x30)
        case 0x3B where oscData.isEmpty:
            break // Separator between command and data
        default:
            oscData.append(byte)
        }
    }
    
    private func parseDCS(_ byte: UInt8) {
        // Simplified DCS handling - just ignore until ST
        if byte == 0x1B {
            state = .escape
        }
    }
    
    private func executeControl(_ byte: UInt8) {
        guard let code = ControlCode(rawValue: byte) else { return }
        
        switch code {
        case .bel:
            emit(.bell)
        case .bs:
            emit(.backspace)
        case .ht:
            emit(.tab)
        case .lf, .vt, .ff:
            emit(.lineFeed)
        case .cr:
            emit(.carriageReturn)
        default:
            emit(.execute(code))
        }
    }
    
    private func executeCSI(_ final: UInt8) {
        let csi = CSI(params: params, intermediates: intermediates, final: final)
        
        // Check for private mode (?)
        let isPrivate = intermediates.contains(0x3F)
        
        switch final {
        case 0x41: // A - CUU
            emit(.cursorUp(max(1, csi.param0)))
        case 0x42: // B - CUD
            emit(.cursorDown(max(1, csi.param0)))
        case 0x43: // C - CUF
            emit(.cursorForward(max(1, csi.param0)))
        case 0x44: // D - CUB
            emit(.cursorBack(max(1, csi.param0)))
        case 0x48, 0x66: // H, f - CUP
            let row = max(1, csi.param0)
            let col = max(1, csi.param1 == 0 ? 1 : csi.param1)
            emit(.cursorPosition(row: row, col: col))
        case 0x4A: // J - ED
            let mode: EraseMode = switch csi.param0 {
            case 0: .toEnd
            case 1: .toBeginning
            case 2: .all
            case 3: .scrollback
            default: .toEnd
            }
            emit(.eraseInDisplay(mode))
        case 0x4B: // K - EL
            let mode: EraseMode = switch csi.param0 {
            case 0: .toEnd
            case 1: .toBeginning
            case 2: .all
            default: .toEnd
            }
            emit(.eraseInLine(mode))
        case 0x6D: // m - SGR
            let attrs = parseSGR(params)
            emit(.sgr(attrs))
        case 0x72: // r - DECSTBM
            let top = max(1, csi.param0)
            let bottom = csi.param1 == 0 ? 0 : csi.param1
            emit(.setScrollRegion(top: top, bottom: bottom))
        case 0x68: // h - SM/DECSET
            if isPrivate {
                for param in params {
                    if let mode = decodePrivateMode(param) {
                        emit(.setMode(mode))
                    }
                }
            }
        case 0x6C: // l - RM/DECRST
            if isPrivate {
                for param in params {
                    if let mode = decodePrivateMode(param) {
                        emit(.resetMode(mode))
                    }
                }
            }
        default:
            emit(.csi(csi))
        }
    }
    
    private func executeOSC() {
        let data = String(bytes: oscData, encoding: .utf8) ?? ""
        
        switch oscCommand {
        case 0, 2: // Set window title
            emit(.setTitle(data))
        default:
            emit(.osc(OSC(command: oscCommand, data: data)))
        }
    }
    
    private func parseSGR(_ params: [Int]) -> [SGRAttribute] {
        var attrs: [SGRAttribute] = []
        var i = 0
        let p = params.isEmpty ? [0] : params
        
        while i < p.count {
            let param = p[i]
            switch param {
            case 0: attrs.append(.reset)
            case 1: attrs.append(.bold)
            case 2: attrs.append(.dim)
            case 3: attrs.append(.italic)
            case 4: attrs.append(.underline)
            case 5, 6: attrs.append(.blink)
            case 7: attrs.append(.inverse)
            case 8: attrs.append(.hidden)
            case 9: attrs.append(.strikethrough)
            case 22: attrs.append(.noBold)
            case 23: attrs.append(.noItalic)
            case 24: attrs.append(.noUnderline)
            case 25: attrs.append(.noBlink)
            case 27: attrs.append(.noInverse)
            case 28: attrs.append(.noHidden)
            case 29: attrs.append(.noStrikethrough)
            case 30...37:
                attrs.append(.foreground(.indexed(UInt8(param - 30))))
            case 38:
                if i + 2 < p.count && p[i + 1] == 5 {
                    attrs.append(.foreground(.indexed(UInt8(p[i + 2]))))
                    i += 2
                } else if i + 4 < p.count && p[i + 1] == 2 {
                    attrs.append(.foreground(.rgb(UInt8(p[i + 2]), UInt8(p[i + 3]), UInt8(p[i + 4]))))
                    i += 4
                }
            case 39: attrs.append(.defaultForeground)
            case 40...47:
                attrs.append(.background(.indexed(UInt8(param - 40))))
            case 48:
                if i + 2 < p.count && p[i + 1] == 5 {
                    attrs.append(.background(.indexed(UInt8(p[i + 2]))))
                    i += 2
                } else if i + 4 < p.count && p[i + 1] == 2 {
                    attrs.append(.background(.rgb(UInt8(p[i + 2]), UInt8(p[i + 3]), UInt8(p[i + 4]))))
                    i += 4
                }
            case 49: attrs.append(.defaultBackground)
            case 90...97:
                attrs.append(.foreground(.indexed(UInt8(param - 90 + 8))))
            case 100...107:
                attrs.append(.background(.indexed(UInt8(param - 100 + 8))))
            default:
                break
            }
            i += 1
        }
        
        return attrs
    }
    
    private func decodePrivateMode(_ param: Int) -> Mode? {
        switch param {
        case 1: return .cursorKeys
        case 3: return .column132
        case 4: return .smoothScroll
        case 5: return .reverseVideo
        case 6: return .origin
        case 7: return .autoWrap
        case 12: return .cursorVisible
        case 20: return .lineFeedNewLine
        case 25: return .cursorVisible
        case 1000: return .mouseTracking
        case 1002: return .mouseCellMotion
        case 1003: return .mouseAllMotion
        case 1006: return .mouseSGR
        case 1004: return .focusEvents
        case 1049: return .altScreenClear
        case 2004: return .bracketedPaste
        default: return nil
        }
    }
    
    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
