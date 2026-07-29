import Foundation

public struct TerminalModeTracker: Sendable {
    public private(set) var bracketedPaste = false
    public private(set) var mouseMode: UInt16 = 0

    private enum State {
        case ground
        case escape
        case csi
    }

    private var state = State.ground
    private var csiBuffer = Data()

    public init() {}

    public mutating func process(_ data: Data) {
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B {
                    state = .escape
                }
            case .escape:
                if byte == 0x5B {
                    state = .csi
                    csiBuffer.removeAll(keepingCapacity: true)
                } else {
                    state = .ground
                }
            case .csi:
                if byte >= 0x40, byte <= 0x7E {
                    parseCSI(params: csiBuffer, terminator: byte)
                    csiBuffer.removeAll(keepingCapacity: true)
                    state = .ground
                } else if csiBuffer.count < 64 {
                    csiBuffer.append(byte)
                } else {
                    csiBuffer.removeAll(keepingCapacity: true)
                    state = .ground
                }
            }
        }
    }

    public func modeRestoreSequence() -> Data {
        var result = Data()
        if bracketedPaste {
            result.append(contentsOf: Array("\u{1B}[?2004h".utf8))
        }
        if mouseMode == 1000 {
            result.append(contentsOf: Array("\u{1B}[?1000h".utf8))
        } else if mouseMode == 1002 {
            result.append(contentsOf: Array("\u{1B}[?1002h".utf8))
        } else if mouseMode == 1003 {
            result.append(contentsOf: Array("\u{1B}[?1003h".utf8))
        }
        return result
    }

    private mutating func parseCSI(params: Data, terminator: UInt8) {
        guard !params.isEmpty, params[0] == 0x3F else { return }
        let numberBytes = params[1...]
        guard let numStr = String(bytes: numberBytes, encoding: .ascii) else { return }
        let numbers = numStr.split(separator: ";").compactMap { UInt16($0) }
        let enable = terminator == 0x68
        let disable = terminator == 0x6C
        guard enable || disable else { return }
        for num in numbers {
            switch num {
            case 2004:
                bracketedPaste = enable
            case 1000,
                 1002,
                 1003:
                mouseMode = enable ? num : 0
            default:
                break
            }
        }
    }
}
