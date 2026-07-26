import Darwin
import Foundation

public enum MuxyDaemonServerError: Error, Equatable {
    case socketFailed(String)
    case bindFailed(String)
    case listenFailed(String)
}

public final class MuxyDaemonServer {
    public static let idleExitInterval: TimeInterval = 60
    public static let reaperInterval: TimeInterval = 0.25

    private final class ClientConnection {
        let fd: Int32
        var role: String?
        var attachedSessionID: UUID?
        var reader = DaemonFrameReader()
        var outbound = Data()

        init(fd: Int32) {
            self.fd = fd
        }
    }

    private let socketPath: String
    private let log: (String) -> Void
    private var listenFD: Int32 = -1
    private var instanceLockFD: Int32 = -1
    private var boundSocketIdentity: (device: dev_t, inode: ino_t)?
    private var clients: [Int32: ClientConnection] = [:]
    private var sessions: [UUID: MuxyDaemonSession] = [:]
    private var running = false
    private var lastActivity = Date()
    private var lastReap = Date.distantPast
    private let idleExitEnabled: Bool

    public init(
        socketPath: String,
        idleExitEnabled: Bool = true,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.socketPath = socketPath
        self.idleExitEnabled = idleExitEnabled
        self.log = log
    }

    public var sessionCount: Int {
        sessions.count
    }

    public func metadata(for sessionID: UUID) -> DaemonSessionMetadata? {
        sessions[sessionID]?.metadata()
    }

    public func run() throws {
        try MuxyDaemonPaths.ensureDirectory()
        guard acquireInstanceLock() else {
            log("another muxyd instance holds the lock, exiting")
            return
        }
        try openListener()
        running = true
        lastActivity = Date()
        log("muxyd listening at \(socketPath)")

        var pollBuffer = [UInt8](repeating: 0, count: 65536)
        while running {
            let clientList = Array(clients.values)
            var descriptors = [pollfd]()
            descriptors.append(pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0))
            for client in clientList {
                var events = Int16(POLLIN)
                if !client.outbound.isEmpty {
                    events |= Int16(POLLOUT)
                }
                descriptors.append(pollfd(fd: client.fd, events: events, revents: 0))
            }
            let sessionList = sessions.values.filter { $0.isRunning && !$0.isExited }
            for session in sessionList {
                descriptors.append(pollfd(fd: session.masterFileDescriptor, events: Int16(POLLIN), revents: 0))
            }

            let ready = poll(&descriptors, nfds_t(descriptors.count), 250)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw MuxyDaemonServerError.socketFailed(String(cString: strerror(errno)))
            }

            if ready > 0 {
                var index = 0
                if descriptors[index].revents != 0 {
                    acceptClient()
                }
                index += 1
                for client in clientList {
                    let revents = descriptors[index].revents
                    index += 1
                    guard clients[client.fd] != nil else { continue }
                    if revents & Int16(POLLIN) != 0 {
                        readClient(client)
                    }
                    guard clients[client.fd] != nil else { continue }
                    if revents & Int16(POLLOUT) != 0 {
                        flushClient(client)
                    }
                    if revents & Int16(POLLHUP | POLLERR) != 0 {
                        removeClient(client)
                    }
                }
                for session in sessionList {
                    let revents = descriptors[index].revents
                    index += 1
                    guard revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
                    pumpSession(session, into: &pollBuffer)
                }
            }

            reapChildrenIfDue()
            exitIfIdle()
        }

        shutdown()
    }

    public func stop() {
        running = false
    }

    private var instanceLockPath: String {
        socketPath + ".lock"
    }

    private func acquireInstanceLock() -> Bool {
        let fd = open(instanceLockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    private func openListener() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MuxyDaemonServerError.socketFailed(String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            throw MuxyDaemonServerError.bindFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = socketPath.withCString { source in
                    strncpy(destination, source, capacity - 1)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw MuxyDaemonServerError.bindFailed(message)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw MuxyDaemonServerError.listenFailed(message)
        }
        _ = chmod(socketPath, 0o600)
        var socketStat = stat()
        if stat(socketPath, &socketStat) == 0 {
            boundSocketIdentity = (socketStat.st_dev, socketStat.st_ino)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenFD = fd
    }

    private func acceptClient() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    return
                }
                return
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            clients[fd] = ClientConnection(fd: fd)
            lastActivity = Date()
        }
    }

    private func readClient(_ client: ClientConnection) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client.fd, &buffer, buffer.count)
            if count > 0 {
                client.reader.append(Data(buffer[0 ..< count]))
                do {
                    while let frame = try client.reader.nextFrame() {
                        handle(frame: frame, from: client)
                    }
                } catch {
                    log("frame error from fd \(client.fd): \(error)")
                    removeClient(client)
                    return
                }
                continue
            }
            if count == 0 {
                removeClient(client)
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            removeClient(client)
            return
        }
    }

    private func flushClient(_ client: ClientConnection) {
        while !client.outbound.isEmpty {
            let written = client.outbound.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(client.fd, baseAddress, rawBuffer.count)
            }
            if written > 0 {
                client.outbound.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            removeClient(client)
            return
        }
    }

    private func send(_ message: DaemonControlMessage, to client: ClientConnection) {
        do {
            let frame = try DaemonFrame.control(message)
            client.outbound.append(DaemonFrameCodec.encode(frame))
        } catch {
            log("encode error: \(error)")
        }
    }

    private func sendOutput(_ data: Data, to client: ClientConnection) {
        let frame = DaemonFrame(type: .sessionOutput, payload: data)
        client.outbound.append(DaemonFrameCodec.encode(frame))
    }

    private func removeClient(_ client: ClientConnection) {
        guard clients.removeValue(forKey: client.fd) != nil else { return }
        close(client.fd)
        lastActivity = Date()
    }

    private func handle(frame: DaemonFrame, from client: ClientConnection) {
        switch frame.type {
        case .control:
            do {
                let message = try frame.decodeControl()
                handle(control: message, from: client)
            } catch {
                send(.error("malformed control message"), to: client)
            }
        case .sessionInput:
            guard let sessionID = client.attachedSessionID, let session = sessions[sessionID], !session.isExited else { return }
            _ = session.write(frame.payload)
        case .sessionOutput:
            break
        }
    }

    private func handle(control message: DaemonControlMessage, from client: ClientConnection) {
        lastActivity = Date()
        switch message {
        case let .hello(version, role):
            guard version == MuxyDaemonProtocol.version else {
                send(.error("protocol version mismatch"), to: client)
                return
            }
            client.role = role
            send(.helloOK(version: MuxyDaemonProtocol.version), to: client)
        case let .attach(request):
            handleAttach(request, from: client)
        case let .resize(cols, rows):
            guard let sessionID = client.attachedSessionID, let session = sessions[sessionID] else { return }
            session.resize(cols: cols, rows: rows)
        case let .query(sessionID):
            guard let session = sessions[sessionID] else {
                send(.error("unknown session"), to: client)
                return
            }
            send(.metadata(session.metadata()), to: client)
        case let .kill(sessionID):
            guard let session = sessions.removeValue(forKey: sessionID) else {
                send(.error("unknown session"), to: client)
                return
            }
            session.terminate()
            send(.killed(sessionID: sessionID), to: client)
        case .list:
            send(.sessionList(sessions.values.map { $0.metadata() }), to: client)
        case .helloOK,
             .attached,
             .exited,
             .metadata,
             .killed,
             .sessionList,
             .error:
            break
        }
    }

    private func handleAttach(_ request: DaemonAttachRequest, from client: ClientConnection) {
        if client.role != MuxyDaemonProtocol.shimRole {
            send(.error("only shim clients may attach"), to: client)
            return
        }
        if let existing = sessions[request.sessionID] {
            existing.resize(cols: request.cols, rows: request.rows)
            client.attachedSessionID = existing.id
            send(.attached(DaemonAttachedResponse(
                sessionID: existing.id,
                created: false,
                exited: existing.isExited,
                exitStatus: existing.exitStatus
            )), to: client)
            let replay = existing.scrollback.contents()
            if !replay.isEmpty {
                sendOutput(replay, to: client)
            }
            if existing.isExited, let status = existing.exitStatus {
                send(.exited(status: status), to: client)
            }
            log("session \(request.sessionID) reattached")
            return
        }

        guard let create = request.create else {
            send(.error("unknown session"), to: client)
            return
        }
        let session = MuxyDaemonSession(id: request.sessionID)
        do {
            try session.start(
                cols: request.cols,
                rows: request.rows,
                workingDirectory: create.workingDirectory,
                command: create.command,
                environment: create.environment
            )
        } catch {
            send(.error("session start failed: \(error)"), to: client)
            return
        }
        sessions[session.id] = session
        client.attachedSessionID = session.id
        send(.attached(DaemonAttachedResponse(sessionID: session.id, created: true, exited: false, exitStatus: nil)), to: client)
        log("session \(session.id) created pid \(session.childPID)")
    }

    private func pumpSession(_ session: MuxyDaemonSession, into buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while true {
                let count = session.readAvailable(into: baseAddress, capacity: rawBuffer.count)
                if count > 0 {
                    let data = Data(bytes: baseAddress, count: count)
                    session.appendScrollback(data)
                    for client in clients.values where client.attachedSessionID == session.id {
                        sendOutput(data, to: client)
                    }
                    continue
                }
                if count < 0 {
                    session.markExited(status: session.exitStatus ?? -1)
                }
                return
            }
        }
    }

    private func reapChildrenIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastReap) >= Self.reaperInterval else { return }
        lastReap = now
        for session in sessions.values where !session.isExited {
            var status: Int32 = 0
            let result = waitpid(session.childPID, &status, WNOHANG)
            guard result == session.childPID else { continue }
            let exitStatus: Int32 = if status & 0x7F == 0 {
                (status >> 8) & 0xFF
            } else {
                -(status & 0x7F)
            }
            session.markExited(status: exitStatus)
            log("session \(session.id) exited status \(exitStatus)")
            for client in clients.values where client.attachedSessionID == session.id {
                send(.exited(status: exitStatus), to: client)
            }
        }
    }

    private func exitIfIdle() {
        guard idleExitEnabled else { return }
        guard sessions.isEmpty, clients.isEmpty else {
            lastActivity = Date()
            return
        }
        if Date().timeIntervalSince(lastActivity) >= Self.idleExitInterval {
            log("idle exit")
            running = false
        }
    }

    private func shutdown() {
        for session in sessions.values {
            session.terminate()
        }
        sessions.removeAll()
        for client in clients.values {
            close(client.fd)
        }
        clients.removeAll()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let identity = boundSocketIdentity {
            var current = stat()
            if stat(socketPath, &current) == 0, current.st_dev == identity.device, current.st_ino == identity.inode {
                unlink(socketPath)
            }
        }
        if instanceLockFD >= 0 {
            close(instanceLockFD)
            instanceLockFD = -1
        }
    }
}
