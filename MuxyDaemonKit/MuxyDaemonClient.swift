import Darwin
import Foundation

public enum MuxyDaemonClientError: Error, Equatable {
    case connectionFailed(String)
    case handshakeFailed(String)
    case socketPathTooLong
    case closed
}

public final class MuxyDaemonClient {
    public private(set) var fileDescriptor: Int32 = -1

    public init() {}

    deinit {
        close()
    }

    public func connect(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MuxyDaemonClientError.connectionFailed(String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else {
            Darwin.close(fd)
            throw MuxyDaemonClientError.socketPathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = socketPath.withCString { source in
                    strncpy(destination, source, capacity - 1)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MuxyDaemonClientError.connectionFailed(message)
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fileDescriptor = fd
    }

    public func close() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    public func setBlocking(_ blocking: Bool) {
        guard fileDescriptor >= 0 else { return }
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        if blocking {
            _ = fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
        } else {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    public func send(frame: DaemonFrame) throws {
        let data = DaemonFrameCodec.encode(frame)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw MuxyDaemonClientError.closed
            }
        }
    }

    public func send(control message: DaemonControlMessage) throws {
        try send(frame: DaemonFrame.control(message))
    }

    public func receiveFrame(reader: DaemonFrameReader, timeout: TimeInterval) throws -> DaemonFrame? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let frame = try reader.nextFrame() {
                return frame
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var event = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, Int32(min(remaining, 1.0) * 1000))
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw MuxyDaemonClientError.closed
            }
            if ready == 0 {
                continue
            }
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                reader.append(Data(buffer[0 ..< count]))
                continue
            }
            if count == 0 {
                throw MuxyDaemonClientError.closed
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            throw MuxyDaemonClientError.closed
        }
    }

    public func handshake(role: String, reader: DaemonFrameReader, timeout: TimeInterval = 5) throws {
        try send(control: .hello(version: MuxyDaemonProtocol.version, role: role))
        guard let frame = try receiveFrame(reader: reader, timeout: timeout),
              case let .helloOK(version) = try frame.decodeControl(),
              version == MuxyDaemonProtocol.version
        else {
            throw MuxyDaemonClientError.handshakeFailed("unexpected handshake response")
        }
    }

    public func queryMetadata(sessionID: UUID, timeout: TimeInterval = 5) throws -> DaemonSessionMetadata? {
        let reader = DaemonFrameReader()
        try handshake(role: MuxyDaemonProtocol.clientRole, reader: reader, timeout: timeout)
        try send(control: .query(sessionID: sessionID))
        guard let frame = try receiveFrame(reader: reader, timeout: timeout) else {
            return nil
        }
        let message = try frame.decodeControl()
        if case let .metadata(metadata) = message {
            return metadata
        }
        return nil
    }

    public func killSession(sessionID: UUID, timeout: TimeInterval = 5) throws {
        let reader = DaemonFrameReader()
        try handshake(role: MuxyDaemonProtocol.clientRole, reader: reader, timeout: timeout)
        try send(control: .kill(sessionID: sessionID))
    }

    public func listSessions(timeout: TimeInterval = 5) throws -> [DaemonSessionMetadata] {
        let reader = DaemonFrameReader()
        try handshake(role: MuxyDaemonProtocol.clientRole, reader: reader, timeout: timeout)
        try send(control: .list)
        guard let frame = try receiveFrame(reader: reader, timeout: timeout),
              case let .sessionList(sessions) = try frame.decodeControl()
        else {
            return []
        }
        return sessions
    }
}
