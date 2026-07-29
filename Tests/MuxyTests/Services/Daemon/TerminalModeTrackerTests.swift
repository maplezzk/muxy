@testable import MuxyDaemonKit
import Foundation
import Testing

@Suite("TerminalModeTracker")
struct TerminalModeTrackerTests {
    @Test("tracks bracketed paste enable")
    func bracketedPasteEnable() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?2004h".utf8))
        #expect(tracker.bracketedPaste == true)
    }

    @Test("tracks bracketed paste disable")
    func bracketedPasteDisable() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?2004h".utf8))
        tracker.process(Data("\u{1B}[?2004l".utf8))
        #expect(tracker.bracketedPaste == false)
    }

    @Test("tracks mouse mode 1003")
    func mouseMode1003() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?1003h".utf8))
        #expect(tracker.mouseMode == 1003)
    }

    @Test("mouse mode disable resets to zero")
    func mouseModeDisable() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?1003h".utf8))
        tracker.process(Data("\u{1B}[?1003l".utf8))
        #expect(tracker.mouseMode == 0)
    }

    @Test("handles split across multiple data chunks")
    func splitChunks() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?20".utf8))
        tracker.process(Data("04h".utf8))
        #expect(tracker.bracketedPaste == true)
    }

    @Test("mode restore sequence includes active modes")
    func modeRestoreSequence() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?2004h\u{1B}[?1003h".utf8))
        let restore = tracker.modeRestoreSequence()
        #expect(restore.contains(Data("\u{1B}[?2004h".utf8)))
        #expect(restore.contains(Data("\u{1B}[?1003h".utf8)))
    }

    @Test("mode restore empty when no modes active")
    func modeRestoreEmpty() {
        let tracker = TerminalModeTracker()
        #expect(tracker.modeRestoreSequence().isEmpty)
    }

    @Test("handles combined mode set")
    func combinedModeSet() {
        var tracker = TerminalModeTracker()
        tracker.process(Data("\u{1B}[?2004;1003h".utf8))
        #expect(tracker.bracketedPaste == true)
        #expect(tracker.mouseMode == 1003)
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool {
        guard other.count <= count else { return false }
        for i in 0 ... (count - other.count) {
            if self[i ..< i + other.count] == other {
                return true
            }
        }
        return false
    }
}
