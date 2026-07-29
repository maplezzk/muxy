import Foundation

public enum MuxyDaemonProtocol {
    public static let version = 1
    public static let maximumFramePayload = 4 * 1024 * 1024
    public static let shimRole = "shim"
    public static let clientRole = "client"
}

public enum DaemonFrameType: UInt8, Sendable {
    case control = 0x01
    case sessionInput = 0x02
    case sessionOutput = 0x03
}

public struct DaemonCreateParams: Codable, Equatable, Sendable {
    public var workingDirectory: String
    public var command: String
    public var environment: [String: String]

    public init(workingDirectory: String, command: String, environment: [String: String]) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
    }
}

public struct DaemonAttachRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var cols: UInt16
    public var rows: UInt16
    public var create: DaemonCreateParams?

    public init(sessionID: UUID, cols: UInt16, rows: UInt16, create: DaemonCreateParams?) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
        self.create = create
    }
}

public struct DaemonAttachedResponse: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var created: Bool
    public var exited: Bool
    public var exitStatus: Int32?
    public var bracketedPaste: Bool
    public var mouseMode: UInt16

    public init(sessionID: UUID, created: Bool, exited: Bool, exitStatus: Int32?, bracketedPaste: Bool = false, mouseMode: UInt16 = 0) {
        self.sessionID = sessionID
        self.created = created
        self.exited = exited
        self.exitStatus = exitStatus
        self.bracketedPaste = bracketedPaste
        self.mouseMode = mouseMode
    }
}

public struct DaemonSessionMetadata: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var childPID: Int32
    public var foregroundPID: Int32?
    public var exited: Bool
    public var exitStatus: Int32?
    public var cols: UInt16
    public var rows: UInt16
    public var startedAt: Date

    public init(
        sessionID: UUID,
        childPID: Int32,
        foregroundPID: Int32?,
        exited: Bool,
        exitStatus: Int32?,
        cols: UInt16,
        rows: UInt16,
        startedAt: Date
    ) {
        self.sessionID = sessionID
        self.childPID = childPID
        self.foregroundPID = foregroundPID
        self.exited = exited
        self.exitStatus = exitStatus
        self.cols = cols
        self.rows = rows
        self.startedAt = startedAt
    }
}

public enum DaemonControlMessage: Codable, Equatable, Sendable {
    case hello(version: Int, role: String)
    case helloOK(version: Int)
    case attach(DaemonAttachRequest)
    case attached(DaemonAttachedResponse)
    case resize(cols: UInt16, rows: UInt16)
    case exited(status: Int32)
    case query(sessionID: UUID)
    case metadata(DaemonSessionMetadata)
    case kill(sessionID: UUID)
    case killed(sessionID: UUID)
    case list
    case sessionList([DaemonSessionMetadata])
    case error(String)

    enum CodingKeys: String, CodingKey {
        case kind
        case version
        case role
        case request
        case response
        case cols
        case rows
        case status
        case sessionID
        case metadata
        case sessions
        case message
    }

    enum Kind: String, Codable {
        case hello
        case helloOK
        case attach
        case attached
        case resize
        case exited
        case query
        case metadata
        case kill
        case killed
        case list
        case sessionList
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .hello:
            self = try .hello(
                version: container.decode(Int.self, forKey: .version),
                role: container.decode(String.self, forKey: .role)
            )
        case .helloOK:
            self = try .helloOK(version: container.decode(Int.self, forKey: .version))
        case .attach:
            self = try .attach(container.decode(DaemonAttachRequest.self, forKey: .request))
        case .attached:
            self = try .attached(container.decode(DaemonAttachedResponse.self, forKey: .response))
        case .resize:
            self = try .resize(
                cols: container.decode(UInt16.self, forKey: .cols),
                rows: container.decode(UInt16.self, forKey: .rows)
            )
        case .exited:
            self = try .exited(status: container.decode(Int32.self, forKey: .status))
        case .query:
            self = try .query(sessionID: container.decode(UUID.self, forKey: .sessionID))
        case .metadata:
            self = try .metadata(container.decode(DaemonSessionMetadata.self, forKey: .metadata))
        case .kill:
            self = try .kill(sessionID: container.decode(UUID.self, forKey: .sessionID))
        case .killed:
            self = try .killed(sessionID: container.decode(UUID.self, forKey: .sessionID))
        case .list:
            self = .list
        case .sessionList:
            self = try .sessionList(container.decode([DaemonSessionMetadata].self, forKey: .sessions))
        case .error:
            self = try .error(container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(version, role):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(version, forKey: .version)
            try container.encode(role, forKey: .role)
        case let .helloOK(version):
            try container.encode(Kind.helloOK, forKey: .kind)
            try container.encode(version, forKey: .version)
        case let .attach(request):
            try container.encode(Kind.attach, forKey: .kind)
            try container.encode(request, forKey: .request)
        case let .attached(response):
            try container.encode(Kind.attached, forKey: .kind)
            try container.encode(response, forKey: .response)
        case let .resize(cols, rows):
            try container.encode(Kind.resize, forKey: .kind)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case let .exited(status):
            try container.encode(Kind.exited, forKey: .kind)
            try container.encode(status, forKey: .status)
        case let .query(sessionID):
            try container.encode(Kind.query, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        case let .metadata(metadata):
            try container.encode(Kind.metadata, forKey: .kind)
            try container.encode(metadata, forKey: .metadata)
        case let .kill(sessionID):
            try container.encode(Kind.kill, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        case let .killed(sessionID):
            try container.encode(Kind.killed, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        case .list:
            try container.encode(Kind.list, forKey: .kind)
        case let .sessionList(sessions):
            try container.encode(Kind.sessionList, forKey: .kind)
            try container.encode(sessions, forKey: .sessions)
        case let .error(message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}
