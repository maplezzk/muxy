import Foundation
import Testing

@testable import Muxy

private final class SendableArray: @unchecked Sendable {
    private var values: [String] = []
    private let lock = NSLock()

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var count: Int {
        lock.withLock { values.count }
    }
}

@Suite("NotificationSocketServer")
struct NotificationSocketServerTests {
    @Test("processes command when client closes write side immediately")
    func processesCommandAfterClientEOF() async throws {
        let tempPath = "/tmp/muxy-test-\(UUID().uuidString).sock"
        let server = NotificationSocketServer()
        server.socketPath = tempPath

        server.commandHandler = { message, _ in
            if message.hasPrefix("split-right") {
                return UUID().uuidString
            }
            return "error:unknown"
        }

        server.start()

        try await waitForSocket(at: tempPath)

        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(clientFD >= 0)
        defer { close(clientFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = tempPath.withCString { strncpy(&addr.sun_path, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(clientFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0, "Failed to connect to test socket: \(String(cString: strerror(errno)))")

        let message = "split-right\n"
        let written = message.withCString { ptr in
            Darwin.write(clientFD, ptr, message.utf8.count)
        }
        #expect(written == message.utf8.count)

        shutdown(clientFD, SHUT_WR)

        var responseBuffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = read(clientFD, &responseBuffer, responseBuffer.count)
        #expect(bytesRead > 0, "Expected response but got EOF or error: \(String(cString: strerror(errno)))")

        let response = String(bytes: responseBuffer[0 ..< bytesRead], encoding: .utf8) ?? ""
        #expect(!response.isEmpty)
        #expect(response.hasSuffix("\n"))

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(UUID(uuidString: trimmed) != nil, "Expected valid UUID, got: \(trimmed)")

        server.stop()
        unlink(tempPath)
    }

    @Test("processes multiple commands before client disconnects")
    func processesMultipleCommandsBeforeEOF() async throws {
        let tempPath = "/tmp/muxy-test-\(UUID().uuidString).sock"
        let server = NotificationSocketServer()
        server.socketPath = tempPath

        let handledCommands = SendableArray()
        server.commandHandler = { message, _ in
            handledCommands.append(message)
            if message.hasPrefix("split-right") {
                return UUID().uuidString
            }
            return "ok"
        }

        server.start()

        try await waitForSocket(at: tempPath)

        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(clientFD >= 0)
        defer { close(clientFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = tempPath.withCString { strncpy(&addr.sun_path, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(clientFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)

        let messages = "split-right\nlist-panes\nlist-tabs\n"
        let written = messages.withCString { ptr in
            Darwin.write(clientFD, ptr, messages.utf8.count)
        }
        #expect(written == messages.utf8.count)

        shutdown(clientFD, SHUT_WR)

        var allResponses = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            allResponses.append(contentsOf: buffer[0 ..< bytesRead])
        }

        let responseString = String(data: allResponses, encoding: .utf8) ?? ""
        let lines = responseString.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3, "Expected 3 responses, got \(lines.count): \(lines)")

        let count = handledCommands.count
        #expect(count == 3, "Expected 3 commands handled, got \(count)")

        server.stop()
        unlink(tempPath)
    }

    @Test("sends error when no handler registered")
    func sendsErrorWhenNoHandler() async throws {
        let tempPath = "/tmp/muxy-test-\(UUID().uuidString).sock"
        let server = NotificationSocketServer()
        server.socketPath = tempPath

        server.start()

        try await waitForSocket(at: tempPath)

        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(clientFD >= 0)
        defer { close(clientFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = tempPath.withCString { strncpy(&addr.sun_path, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(clientFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)

        let message = "list-panes\n"
        _ = message.withCString { ptr in
            Darwin.write(clientFD, ptr, message.utf8.count)
        }
        shutdown(clientFD, SHUT_WR)

        var responseBuffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = read(clientFD, &responseBuffer, responseBuffer.count)
        #expect(bytesRead > 0)

        let response = String(bytes: responseBuffer[0 ..< bytesRead], encoding: .utf8) ?? ""
        #expect(response.contains("error:no handler"))

        server.stop()
        unlink(tempPath)
    }

    private func waitForSocket(at path: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if access(path, F_OK) == 0 {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket did not appear at \(path)"])
    }
}
