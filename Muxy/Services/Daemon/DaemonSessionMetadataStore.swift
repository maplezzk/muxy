import Foundation
import MuxyDaemonKit
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonSessionMetadataStore")

@MainActor
final class DaemonSessionMetadataStore {
    static let shared = DaemonSessionMetadataStore()

    static let cacheTTL: TimeInterval = 1
    static let queryTimeout: TimeInterval = 0.5

    struct Entry {
        let foregroundPID: Int32?
        let exited: Bool
        let queriedAt: Date
    }

    private var entries: [UUID: Entry] = [:]
    private let socketPath: () -> String
    private let query: (String, UUID) throws -> DaemonSessionMetadata?

    init(
        socketPath: @escaping () -> String = { MuxyDaemonPaths.socketPath },
        query: ((String, UUID) throws -> DaemonSessionMetadata?)? = nil
    ) {
        self.socketPath = socketPath
        self.query = query ?? { path, sessionID in
            let client = MuxyDaemonClient()
            defer { client.close() }
            try client.connect(socketPath: path)
            return try client.queryMetadata(sessionID: sessionID, timeout: Self.queryTimeout)
        }
    }

    func foregroundProcessID(for sessionID: UUID) -> Int32? {
        entry(for: sessionID)?.foregroundPID
    }

    func invalidate(sessionID: UUID) {
        entries.removeValue(forKey: sessionID)
    }

    private func entry(for sessionID: UUID) -> Entry? {
        if let cached = entries[sessionID], Date().timeIntervalSince(cached.queriedAt) < Self.cacheTTL {
            return cached
        }
        do {
            guard let metadata = try query(socketPath(), sessionID) else {
                let entry = Entry(foregroundPID: nil, exited: false, queriedAt: Date())
                entries[sessionID] = entry
                return entry
            }
            let entry = Entry(foregroundPID: metadata.foregroundPID, exited: metadata.exited, queriedAt: Date())
            entries[sessionID] = entry
            return entry
        } catch {
            logger
                .debug(
                    "metadata query failed for \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return nil
        }
    }
}
