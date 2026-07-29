import Darwin
import Foundation
import MuxyDaemonC

public enum MuxyDaemonShimError: Error, Equatable {
    case daemonUnavailable(String)
    case attachRejected(String)
}

public struct MuxyDaemonShim {
    public static let spawnRetryCount = 1200
    public static let spawnRetryDelay: useconds_t = 50000
    public static let spawnProgressLogInterval = 100

    public let socketPath: String
    public let daemonExecutablePath: String
    private let log: (String) -> Void

    public init(
        socketPath: String,
        daemonExecutablePath: String,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(("muxyd-shim: " + $0 + "\r\n").utf8)) }
    ) {
        self.socketPath = socketPath
        self.daemonExecutablePath = daemonExecutablePath
        self.log = log
    }

    public func run(sessionID: UUID, workingDirectory: String, command: String, environment: [String: String]) -> Int32 {
        var savedTermios = termios()
        let rawModeApplied = isatty(STDIN_FILENO) == 1
            && tcgetattr(STDIN_FILENO, &savedTermios) == 0
        if rawModeApplied {
            var raw = savedTermios
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer {
            if rawModeApplied {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            }
        }

        installSignalHandlers()

        let client = MuxyDaemonClient()
        do {
            try connectWithSpawn(client: client)
        } catch {
            FileHandle.standardError.write(Data("muxyd shim: daemon unavailable: \(error)\r\n".utf8))
            return 1
        }
        defer { client.close() }

        let size = currentTerminalSize()
        let reader = DaemonFrameReader()
        var modeRestore = Data()
        do {
            try client.handshake(role: MuxyDaemonProtocol.shimRole, reader: reader)
            try client.send(control: .attach(DaemonAttachRequest(
                sessionID: sessionID,
                cols: size.cols,
                rows: size.rows,
                create: DaemonCreateParams(workingDirectory: workingDirectory, command: command, environment: environment)
            )))
            guard let frame = try client.receiveFrame(reader: reader, timeout: 10) else {
                FileHandle.standardError.write(Data("muxyd shim: attach timed out\r\n".utf8))
                return 1
            }
            let message = try frame.decodeControl()
            switch message {
            case let .attached(response):
                log("attached session \(response.sessionID) created \(response.created) exited \(response.exited)")
                if !response.created {
                    modeRestore = Self.buildModeRestore(bracketedPaste: response.bracketedPaste, mouseMode: response.mouseMode)
                }
            case let .error(reason):
                FileHandle.standardError.write(Data("muxyd shim: \(reason)\r\n".utf8))
                return 1
            default:
                FileHandle.standardError.write(Data("muxyd shim: unexpected attach response\r\n".utf8))
                return 1
            }
        } catch {
            FileHandle.standardError.write(Data("muxyd shim: attach failed: \(error)\r\n".utf8))
            return 1
        }

        return pumpLoop(client: client, reader: reader, modeRestore: modeRestore)
    }

    private func connectWithSpawn(client: MuxyDaemonClient) throws {
        do {
            try client.connect(socketPath: socketPath)
            return
        } catch {
            log("daemon not reachable, spawning")
        }
        try spawnDaemon()
        var lastError: (any Error)?
        for attempt in 0 ..< Self.spawnRetryCount {
            do {
                try client.connect(socketPath: socketPath)
                return
            } catch {
                lastError = error
                if attempt > 0, attempt % Self.spawnProgressLogInterval == 0 {
                    log("still waiting for daemon (\(attempt / 20)s)")
                }
                usleep(Self.spawnRetryDelay)
            }
        }
        throw MuxyDaemonShimError.daemonUnavailable(lastError.map { "\($0)" } ?? "unknown")
    }

    private func spawnDaemon() throws {
        let pid = muxy_spawn_detached(daemonExecutablePath, "daemon")
        guard pid >= 0 else {
            throw MuxyDaemonShimError.daemonUnavailable(String(cString: strerror(errno)))
        }
        log("spawned daemon pid \(pid)")
    }

    private func currentTerminalSize() -> (cols: UInt16, rows: UInt16) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            return (size.ws_col, size.ws_row)
        }
        if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            return (size.ws_col, size.ws_row)
        }
        return (80, 24)
    }

    private func installSignalHandlers() {
        signal(SIGWINCH) { _ in
            MuxyDaemonShimSharedState.winChReceived = true
        }
        signal(SIGPIPE, SIG_IGN)
    }

    private func pumpLoop(client: MuxyDaemonClient, reader: DaemonFrameReader, modeRestore: Data = Data()) -> Int32 {
        client.setBlocking(false)
        let originalStdoutFlags = fcntl(STDOUT_FILENO, F_GETFL)
        _ = fcntl(STDOUT_FILENO, F_SETFL, originalStdoutFlags | O_NONBLOCK)
        defer { _ = fcntl(STDOUT_FILENO, F_SETFL, originalStdoutFlags) }

        var stdinBuffer = [UInt8](repeating: 0, count: 65536)
        var socketBuffer = [UInt8](repeating: 0, count: 65536)
        var outbound = Data()
        var exitStatus: Int32 = 0
        var shouldExit = false
        var stdinClosed = false
        var drainDeadline = Date.distantFuture

        do {
            while let frame = try reader.nextFrame() {
                if handleIncoming(frame: frame, outbound: &outbound, exitStatus: &exitStatus) {
                    flushBlocking(outbound)
                    return exitStatus
                }
            }
        } catch {
            flushBlocking(outbound)
            return exitStatus
        }

        if !modeRestore.isEmpty {
            outbound.append(modeRestore)
        }

        while !shouldExit {
            if MuxyDaemonShimSharedState.winChReceived {
                MuxyDaemonShimSharedState.winChReceived = false
                let size = currentTerminalSize()
                try? client.send(control: .resize(cols: size.cols, rows: size.rows))
            }

            if stdinClosed, outbound.isEmpty, Date() >= drainDeadline {
                break
            }

            flushOutbound(&outbound)

            var descriptors = [
                pollfd(fd: STDIN_FILENO, events: Int16(stdinClosed ? 0 : POLLIN), revents: 0),
                pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: STDOUT_FILENO, events: Int16(outbound.isEmpty ? 0 : POLLOUT), revents: 0),
            ]
            let ready = poll(&descriptors, 3, 100)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            guard ready > 0 else { continue }

            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let count = read(STDIN_FILENO, &stdinBuffer, stdinBuffer.count)
                if count > 0 {
                    let frame = DaemonFrame(type: .sessionInput, payload: Data(stdinBuffer[0 ..< count]))
                    try? client.send(frame: frame)
                } else if count == 0 {
                    stdinClosed = true
                    drainDeadline = Date().addingTimeInterval(0.5)
                }
            }
            if descriptors[0].revents & Int16(POLLHUP) != 0, !stdinClosed {
                stdinClosed = true
                drainDeadline = Date().addingTimeInterval(0.5)
            }

            if descriptors[1].revents & Int16(POLLIN) != 0 {
                let count = read(client.fileDescriptor, &socketBuffer, socketBuffer.count)
                if count > 0 {
                    reader.append(Data(socketBuffer[0 ..< count]))
                    do {
                        while let frame = try reader.nextFrame() {
                            if handleIncoming(frame: frame, outbound: &outbound, exitStatus: &exitStatus) {
                                shouldExit = true
                                break
                            }
                        }
                    } catch {
                        shouldExit = true
                    }
                } else if count == 0 {
                    shouldExit = true
                } else if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                    shouldExit = true
                }
            }
            if descriptors[1].revents & Int16(POLLHUP) != 0, descriptors[1].revents & Int16(POLLIN) == 0 {
                shouldExit = true
            }
        }

        flushBlocking(outbound)
        return exitStatus
    }

    private func flushOutbound(_ outbound: inout Data) {
        while !outbound.isEmpty {
            let written = outbound.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return write(STDOUT_FILENO, baseAddress, rawBuffer.count)
            }
            if written > 0 {
                outbound.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            outbound.removeAll()
            return
        }
    }

    private func flushBlocking(_ outbound: Data) {
        guard !outbound.isEmpty else { return }
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        _ = fcntl(STDOUT_FILENO, F_SETFL, flags & ~O_NONBLOCK)
        writeAllStdout(outbound)
    }

    private func handleIncoming(frame: DaemonFrame, outbound: inout Data, exitStatus: inout Int32) -> Bool {
        switch frame.type {
        case .sessionOutput:
            outbound.append(frame.payload)
            return false
        case .control:
            if let message = try? frame.decodeControl(), case let .exited(status) = message {
                exitStatus = status
                return true
            }
            return false
        case .sessionInput:
            return false
        }
    }

    private func writeAllStdout(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(STDOUT_FILENO, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                return
            }
        }
    }
}

enum MuxyDaemonShimSharedState {
    nonisolated(unsafe) static var winChReceived = false
}

extension MuxyDaemonShim {
    static func buildModeRestore(bracketedPaste: Bool, mouseMode: UInt16) -> Data {
        var result = Data()
        if bracketedPaste {
            result.append(contentsOf: Array("\u{1B}[?2004h".utf8))
        }
        switch mouseMode {
        case 1000:
            result.append(contentsOf: Array("\u{1B}[?1000h".utf8))
        case 1002:
            result.append(contentsOf: Array("\u{1B}[?1002h".utf8))
        case 1003:
            result.append(contentsOf: Array("\u{1B}[?1003h".utf8))
        default:
            break
        }
        return result
    }
}
