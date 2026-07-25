import Foundation
import MuxyDaemonKit
import Testing

@Suite("MuxyDaemonRingBuffer")
struct MuxyDaemonRingBufferTests {
    @Test("empty buffer returns empty contents")
    func emptyContents() {
        let buffer = MuxyDaemonRingBuffer(capacity: 16)
        #expect(buffer.isEmpty)
        #expect(buffer.contents().isEmpty)
    }

    @Test("append and read back within capacity")
    func appendWithinCapacity() {
        var buffer = MuxyDaemonRingBuffer(capacity: 16)
        buffer.append(Data("hello".utf8))
        #expect(buffer.length == 5)
        #expect(buffer.contents() == Data("hello".utf8))
    }

    @Test("overflow drops oldest bytes")
    func overflowDropsOldest() {
        var buffer = MuxyDaemonRingBuffer(capacity: 8)
        buffer.append(Data("abcdefgh".utf8))
        buffer.append(Data("ijkl".utf8))
        #expect(buffer.length == 8)
        #expect(buffer.contents() == Data("efghijkl".utf8))
    }

    @Test("multiple wraps preserve most recent bytes")
    func multipleWraps() {
        var buffer = MuxyDaemonRingBuffer(capacity: 4)
        for byte in UInt8(ascii: "a") ... UInt8(ascii: "z") {
            buffer.append([byte])
        }
        #expect(buffer.contents() == Data("wxyz".utf8))
    }

    @Test("capacity of zero is clamped to one")
    func zeroCapacityClamped() {
        var buffer = MuxyDaemonRingBuffer(capacity: 0)
        buffer.append(Data("ab".utf8))
        #expect(buffer.contents() == Data("b".utf8))
    }
}
