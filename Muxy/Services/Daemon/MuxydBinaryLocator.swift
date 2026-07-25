import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "MuxydBinaryLocator")

enum MuxydBinaryLocator {
    static let binaryName = "muxyd"

    static func binaryPath(bundle: Bundle = .main) -> String? {
        if let override = ProcessInfo.processInfo.environment["MUXYD_BINARY_PATH"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        guard let executableURL = bundle.executableURL else { return nil }
        let sibling = executableURL.deletingLastPathComponent().appendingPathComponent(binaryName)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling.path
        }
        logger.error("muxyd binary not found next to \(executableURL.path, privacy: .public)")
        return nil
    }
}
