import Darwin
import Foundation
import MuxyDaemonC

public enum MuxyDaemonSessionError: Error, Equatable {
    case ptyFailed(String)
    case forkFailed(String)
    case notRunning
}

public final class MuxyDaemonSession {
    public static let defaultScrollbackCapacity = 1_048_576

    public let id: UUID
    public let createdAt: Date
    public private(set) var childPID: Int32
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16
    public private(set) var exitStatus: Int32?

    public var isExited: Bool {
        exitStatus != nil
    }

    public private(set) var scrollback: MuxyDaemonRingBuffer
    public private(set) var terminalModes = TerminalModeTracker()

    public private(set) var masterFileDescriptor: Int32 = -1

    public init(id: UUID, scrollbackCapacity: Int = defaultScrollbackCapacity) {
        self.id = id
        createdAt = Date()
        childPID = 0
        cols = 80
        rows = 24
        scrollback = MuxyDaemonRingBuffer(capacity: scrollbackCapacity)
    }

    public var isRunning: Bool {
        masterFileDescriptor >= 0
    }

    public func start(
        cols: UInt16,
        rows: UInt16,
        workingDirectory: String,
        command: String,
        environment: [String: String]
    ) throws {
        var environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") }
        environmentPointers.append(nil)
        defer {
            for pointer in environmentPointers where pointer != nil {
                free(pointer)
            }
        }

        var master: Int32 = -1
        let pid = muxy_forkpty_exec(
            workingDirectory,
            "/bin/zsh",
            command,
            &environmentPointers,
            cols,
            rows,
            &master
        )
        guard pid >= 0, master >= 0 else {
            throw MuxyDaemonSessionError.ptyFailed(String(cString: strerror(errno)))
        }

        childPID = pid
        masterFileDescriptor = master
        self.cols = cols
        self.rows = rows

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
    }

    public func readAvailable(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        guard masterFileDescriptor >= 0 else { return -1 }
        while true {
            let count = read(masterFileDescriptor, buffer, capacity)
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return 0
            }
            if count < 0 {
                return -1
            }
            return count
        }
    }

    public func appendScrollback(_ data: Data) {
        scrollback.append(data)
        terminalModes.process(data)
    }

    public func write(_ data: Data) -> Bool {
        guard masterFileDescriptor >= 0 else { return false }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(masterFileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1000)
                    continue
                }
                return false
            }
            return true
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        guard masterFileDescriptor >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFileDescriptor, TIOCSWINSZ, &size)
    }

    public func notifyResize() {
        guard masterFileDescriptor >= 0, !isExited else { return }
        let pgrp = tcgetpgrp(masterFileDescriptor)
        if pgrp > 0 {
            kill(-pgrp, SIGWINCH)
        }
    }

    public func foregroundProcessID() -> Int32? {
        guard masterFileDescriptor >= 0, !isExited else { return nil }
        let pid = tcgetpgrp(masterFileDescriptor)
        return pid > 0 ? pid : nil
    }

    public func metadata() -> DaemonSessionMetadata {
        DaemonSessionMetadata(
            sessionID: id,
            childPID: childPID,
            foregroundPID: foregroundProcessID(),
            exited: isExited,
            exitStatus: exitStatus,
            cols: cols,
            rows: rows,
            startedAt: createdAt
        )
    }

    public func markExited(status: Int32) {
        guard exitStatus == nil else { return }
        exitStatus = status
    }

    public func terminate() {
        if masterFileDescriptor >= 0 {
            close(masterFileDescriptor)
            masterFileDescriptor = -1
        }
        if childPID > 0, !isExited {
            kill(childPID, SIGHUP)
        }
    }

    deinit {
        if masterFileDescriptor >= 0 {
            close(masterFileDescriptor)
        }
    }
}
