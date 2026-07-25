import Foundation
import MuxyDaemonKit
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonSessionTerminator")

enum DaemonSessionTerminator {
    static func terminate(sessionID: UUID, socketPath: String = MuxyDaemonPaths.socketPath) {
        let path = socketPath
        DispatchQueue.global(qos: .utility).async {
            let client = MuxyDaemonClient()
            defer { client.close() }
            do {
                try client.connect(socketPath: path)
                try client.killSession(sessionID: sessionID)
            } catch {
                logger
                    .debug("kill session \(sessionID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
