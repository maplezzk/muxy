import Foundation
import MuxyDaemonKit
import Testing

@Suite("MuxyDaemonWire")
struct MuxyDaemonWireTests {
    @Test("frame codec round trip")
    func frameRoundTrip() throws {
        let frame = DaemonFrame(type: .sessionOutput, payload: Data("terminal-bytes".utf8))
        let encoded = DaemonFrameCodec.encode(frame)
        var reader = DaemonFrameReader()
        reader.append(encoded)
        let decoded = try #require(try reader.nextFrame())
        #expect(decoded.type == .sessionOutput)
        #expect(decoded.payload == Data("terminal-bytes".utf8))
        #expect(try reader.nextFrame() == nil)
    }

    @Test("reader handles split header and payload")
    func splitReads() throws {
        let frame = DaemonFrame(type: .sessionInput, payload: Data("chunked".utf8))
        let encoded = DaemonFrameCodec.encode(frame)
        var reader = DaemonFrameReader()
        for index in encoded.indices {
            reader.append(encoded.subdata(in: index ..< encoded.index(after: index)))
        }
        let decoded = try #require(try reader.nextFrame())
        #expect(decoded.payload == Data("chunked".utf8))
    }

    @Test("reader handles concatenated frames")
    func concatenatedFrames() throws {
        var reader = DaemonFrameReader()
        reader.append(DaemonFrameCodec.encode(DaemonFrame(type: .sessionInput, payload: Data("one".utf8))))
        reader.append(DaemonFrameCodec.encode(DaemonFrame(type: .sessionOutput, payload: Data("two".utf8))))
        let first = try #require(try reader.nextFrame())
        let second = try #require(try reader.nextFrame())
        #expect(first.payload == Data("one".utf8))
        #expect(second.payload == Data("two".utf8))
    }

    @Test("reader rejects oversized frames")
    func oversizedFrame() {
        var reader = DaemonFrameReader()
        var length = UInt32(MuxyDaemonProtocol.maximumFramePayload + 1).littleEndian
        var encoded = Data(bytes: &length, count: 4)
        encoded.append(DaemonFrameType.sessionOutput.rawValue)
        reader.append(encoded)
        #expect(throws: DaemonWireError.frameTooLarge) {
            _ = try reader.nextFrame()
        }
    }

    @Test("control message round trip preserves payload")
    func controlRoundTrip() throws {
        let sessionID = UUID()
        let messages: [DaemonControlMessage] = [
            .hello(version: 1, role: "shim"),
            .helloOK(version: 1),
            .attach(DaemonAttachRequest(
                sessionID: sessionID,
                cols: 120,
                rows: 40,
                create: DaemonCreateParams(workingDirectory: "/tmp", command: "exec zsh -l", environment: ["A": "B"])
            )),
            .attached(DaemonAttachedResponse(sessionID: sessionID, created: false, exited: true, exitStatus: 3)),
            .resize(cols: 100, rows: 30),
            .exited(status: -15),
            .query(sessionID: sessionID),
            .metadata(DaemonSessionMetadata(
                sessionID: sessionID,
                childPID: 42,
                foregroundPID: 43,
                exited: false,
                exitStatus: nil,
                cols: 80,
                rows: 24,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )),
            .kill(sessionID: sessionID),
            .killed(sessionID: sessionID),
            .list,
            .sessionList([]),
            .error("boom"),
        ]
        for message in messages {
            let frame = try DaemonFrame.control(message)
            #expect(frame.type == .control)
            let decoded = try frame.decodeControl()
            #expect(decoded == message)
        }
    }
}
