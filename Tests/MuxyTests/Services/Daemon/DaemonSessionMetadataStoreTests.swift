import Foundation
import MuxyDaemonKit
import Testing

@testable import Muxy

@Suite("DaemonSessionMetadataStore")
@MainActor
struct DaemonSessionMetadataStoreTests {
    private func makeMetadata(sessionID: UUID, foregroundPID: Int32?) -> DaemonSessionMetadata {
        DaemonSessionMetadata(
            sessionID: sessionID,
            childPID: 100,
            foregroundPID: foregroundPID,
            exited: false,
            exitStatus: nil,
            cols: 80,
            rows: 24,
            startedAt: Date()
        )
    }

    @Test("returns foreground PID from query")
    func returnsForegroundPID() {
        let sessionID = UUID()
        let store = DaemonSessionMetadataStore(query: { _, _ in
            DaemonSessionMetadata(
                sessionID: sessionID,
                childPID: 100,
                foregroundPID: 4242,
                exited: false,
                exitStatus: nil,
                cols: 80,
                rows: 24,
                startedAt: Date()
            )
        })
        #expect(store.foregroundProcessID(for: sessionID) == 4242)
    }

    @Test("caches results within TTL")
    func cachesWithinTTL() {
        let sessionID = UUID()
        var queryCount = 0
        let store = DaemonSessionMetadataStore(query: { _, _ in
            queryCount += 1
            return DaemonSessionMetadata(
                sessionID: sessionID,
                childPID: 100,
                foregroundPID: 4242,
                exited: false,
                exitStatus: nil,
                cols: 80,
                rows: 24,
                startedAt: Date()
            )
        })
        _ = store.foregroundProcessID(for: sessionID)
        _ = store.foregroundProcessID(for: sessionID)
        #expect(queryCount == 1)
    }

    @Test("returns nil when query throws")
    func nilOnError() {
        struct TestError: Error {}
        let store = DaemonSessionMetadataStore(query: { _, _ in
            throw TestError()
        })
        #expect(store.foregroundProcessID(for: UUID()) == nil)
    }

    @Test("invalidate forces a fresh query")
    func invalidateRefetches() {
        let sessionID = UUID()
        var queryCount = 0
        let store = DaemonSessionMetadataStore(query: { _, _ in
            queryCount += 1
            return DaemonSessionMetadata(
                sessionID: sessionID,
                childPID: 100,
                foregroundPID: 4242,
                exited: false,
                exitStatus: nil,
                cols: 80,
                rows: 24,
                startedAt: Date()
            )
        })
        _ = store.foregroundProcessID(for: sessionID)
        store.invalidate(sessionID: sessionID)
        _ = store.foregroundProcessID(for: sessionID)
        #expect(queryCount == 2)
    }
}
