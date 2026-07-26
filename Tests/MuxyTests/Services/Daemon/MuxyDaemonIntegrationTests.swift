import Foundation
import MuxyDaemonKit
import Testing

@Suite("MuxyDaemon integration", .serialized)
struct MuxyDaemonIntegrationTests {
    private func makeSocketPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muxyd-test-\(UUID().uuidString).sock")
            .path
    }

    private func startServer(socketPath: String) -> (MuxyDaemonServer, Thread) {
        let server = MuxyDaemonServer(socketPath: socketPath, idleExitEnabled: false, log: { _ in })
        let thread = Thread {
            try? server.run()
        }
        thread.start()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (server, thread)
    }

    private func stopServer(_ server: MuxyDaemonServer, thread: Thread, socketPath: String) {
        server.stop()
        thread.cancel()
        _ = try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func attachShim(
        socketPath: String,
        sessionID: UUID,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        create: DaemonCreateParams? = nil
    ) throws -> (MuxyDaemonClient, DaemonFrameReader, DaemonAttachedResponse) {
        let client = MuxyDaemonClient()
        try client.connect(socketPath: socketPath)
        let reader = DaemonFrameReader()
        try client.handshake(role: MuxyDaemonProtocol.shimRole, reader: reader)
        try client.send(control: .attach(DaemonAttachRequest(sessionID: sessionID, cols: cols, rows: rows, create: create)))
        guard let frame = try client.receiveFrame(reader: reader, timeout: 10) else {
            Issue.record("attach response timed out")
            return (client, reader, DaemonAttachedResponse(sessionID: sessionID, created: false, exited: false, exitStatus: nil))
        }
        guard case let .attached(response) = try frame.decodeControl() else {
            Issue.record("unexpected attach response")
            return (client, reader, DaemonAttachedResponse(sessionID: sessionID, created: false, exited: false, exitStatus: nil))
        }
        return (client, reader, response)
    }

    private func readUntil(reader: DaemonFrameReader, client: MuxyDaemonClient, timeout: TimeInterval = 10, matches: (DaemonFrame) -> Bool) -> DaemonFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = try? client.receiveFrame(reader: reader, timeout: 0.5) {
                if matches(frame) {
                    return frame
                }
            }
        }
        return nil
    }

    @Test("create attach reattach preserves session and replays scrollback")
    func createReattachReplay() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let sessionID = UUID()
        let create = DaemonCreateParams(
            workingDirectory: "/tmp",
            command: "echo muxy-daemon-integration-marker; exec cat",
            environment: ["TERM": "xterm-256color"]
        )

        let (clientA, readerA, responseA) = try attachShim(socketPath: socketPath, sessionID: sessionID, create: create)
        #expect(responseA.created)
        #expect(!responseA.exited)

        let output = readUntil(reader: readerA, client: clientA) { frame in
            frame.type == .sessionOutput && frame.payload.contains(Data("muxy-daemon-integration-marker".utf8))
        }
        #expect(output != nil)
        clientA.close()

        let (clientB, readerB, responseB) = try attachShim(socketPath: socketPath, sessionID: sessionID)
        defer { clientB.close() }
        #expect(!responseB.created)
        #expect(!responseB.exited)

        let replay = readUntil(reader: readerB, client: clientB) { frame in
            frame.type == .sessionOutput && frame.payload.contains(Data("muxy-daemon-integration-marker".utf8))
        }
        #expect(replay != nil)
    }

    @Test("input sent after reattach reaches the session")
    func inputAfterReattach() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let sessionID = UUID()
        let create = DaemonCreateParams(
            workingDirectory: "/tmp",
            command: "exec cat",
            environment: ["TERM": "xterm-256color"]
        )

        let (clientA, readerA, _) = try attachShim(socketPath: socketPath, sessionID: sessionID, create: create)
        _ = readUntil(reader: readerA, client: clientA, timeout: 3) { $0.type == .sessionOutput }
        clientA.close()

        let (clientB, readerB, _) = try attachShim(socketPath: socketPath, sessionID: sessionID)
        defer { clientB.close() }
        try clientB.send(frame: DaemonFrame(type: .sessionInput, payload: Data("ping-after-reattach\n".utf8)))

        let echo = readUntil(reader: readerB, client: clientB) { frame in
            frame.type == .sessionOutput && frame.payload.contains(Data("ping-after-reattach".utf8))
        }
        #expect(echo != nil)
    }

    @Test("session exit is propagated and reattach reports exited")
    func exitPropagation() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let sessionID = UUID()
        let create = DaemonCreateParams(
            workingDirectory: "/tmp",
            command: "exit 42",
            environment: ["TERM": "xterm-256color"]
        )

        let (clientA, readerA, _) = try attachShim(socketPath: socketPath, sessionID: sessionID, create: create)
        let exited = readUntil(reader: readerA, client: clientA) { frame in
            guard frame.type == .control, let message = try? frame.decodeControl(),
                  case let .exited(status) = message
            else { return false }
            return status == 42
        }
        #expect(exited != nil)
        clientA.close()

        let (clientB, readerB, responseB) = try attachShim(socketPath: socketPath, sessionID: sessionID)
        defer { clientB.close() }
        #expect(responseB.exited)
        #expect(responseB.exitStatus == 42)
    }

    @Test("resize updates session metadata")
    func resizeUpdatesMetadata() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let sessionID = UUID()
        let create = DaemonCreateParams(
            workingDirectory: "/tmp",
            command: "exec cat",
            environment: ["TERM": "xterm-256color"]
        )
        let (clientA, _, _) = try attachShim(socketPath: socketPath, sessionID: sessionID, cols: 80, rows: 24, create: create)
        try clientA.send(control: .resize(cols: 132, rows: 43))

        let deadline = Date().addingTimeInterval(5)
        var metadata = server.metadata(for: sessionID)
        while Date() < deadline, metadata?.cols != 132 {
            Thread.sleep(forTimeInterval: 0.05)
            metadata = server.metadata(for: sessionID)
        }
        #expect(metadata?.cols == 132)
        #expect(metadata?.rows == 43)
        clientA.close()
    }

    @Test("metadata reports foreground process of session")
    func metadataForegroundProcess() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let sessionID = UUID()
        let create = DaemonCreateParams(
            workingDirectory: "/tmp",
            command: "exec cat",
            environment: ["TERM": "xterm-256color"]
        )
        let (clientA, _, _) = try attachShim(socketPath: socketPath, sessionID: sessionID, create: create)
        defer { clientA.close() }

        let deadline = Date().addingTimeInterval(5)
        var foreground = server.metadata(for: sessionID)?.foregroundPID
        while Date() < deadline, foreground == nil {
            Thread.sleep(forTimeInterval: 0.05)
            foreground = server.metadata(for: sessionID)?.foregroundPID
        }
        #expect(foreground != nil)
        #expect(foreground == server.metadata(for: sessionID)?.childPID)
    }

    @Test("kill terminates session and removes it")
    func killSession() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let sessionID = UUID()
        let create = DaemonCreateParams(
            workingDirectory: "/tmp",
            command: "exec cat",
            environment: ["TERM": "xterm-256color"]
        )
        let (clientA, _, _) = try attachShim(socketPath: socketPath, sessionID: sessionID, create: create)
        clientA.close()

        let admin = MuxyDaemonClient()
        try admin.connect(socketPath: socketPath)
        try admin.killSession(sessionID: sessionID)
        admin.close()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, server.metadata(for: sessionID) != nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(server.metadata(for: sessionID) == nil)
    }

    @Test("client role cannot attach sessions")
    func clientRoleRejected() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let client = MuxyDaemonClient()
        try client.connect(socketPath: socketPath)
        defer { client.close() }
        let reader = DaemonFrameReader()
        try client.handshake(role: MuxyDaemonProtocol.clientRole, reader: reader)
        try client.send(control: .attach(DaemonAttachRequest(sessionID: UUID(), cols: 80, rows: 24, create: nil)))
        guard let frame = try client.receiveFrame(reader: reader, timeout: 5),
              case let .error(message) = try frame.decodeControl()
        else {
            Issue.record("expected error response")
            return
        }
        #expect(message.contains("shim"))
    }

    @Test("second server instance exits without stealing the socket")
    func singleInstanceLock() throws {
        let socketPath = makeSocketPath()
        let (first, firstThread) = startServer(socketPath: socketPath)
        defer { stopServer(first, thread: firstThread, socketPath: socketPath) }

        let second = MuxyDaemonServer(socketPath: socketPath, idleExitEnabled: false, log: { _ in })
        try second.run()

        let sessionID = UUID()
        let (client, reader, attached) = try attachShim(
            socketPath: socketPath,
            sessionID: sessionID,
            create: DaemonCreateParams(workingDirectory: "/tmp", command: "/bin/cat", environment: [:])
        )
        defer { client.close() }
        #expect(attached.created)
        #expect(first.sessionCount == 1)
    }

    @Test("protocol version mismatch is rejected")
    func versionMismatch() throws {
        let socketPath = makeSocketPath()
        let (server, thread) = startServer(socketPath: socketPath)
        defer { stopServer(server, thread: thread, socketPath: socketPath) }

        let client = MuxyDaemonClient()
        try client.connect(socketPath: socketPath)
        defer { client.close() }
        let reader = DaemonFrameReader()
        try client.send(control: .hello(version: 999, role: MuxyDaemonProtocol.clientRole))
        guard let frame = try client.receiveFrame(reader: reader, timeout: 5),
              case let .error(message) = try frame.decodeControl()
        else {
            Issue.record("expected error response")
            return
        }
        #expect(message.contains("version"))
    }
}
