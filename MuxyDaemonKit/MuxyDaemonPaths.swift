import Foundation

public enum MuxyDaemonPaths {
    public static let socketPathOverrideKey = "MUXYD_SOCKET_PATH"
    public static let logPathOverrideKey = "MUXYD_LOG_PATH"

    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment[socketPathOverrideKey], !override.isEmpty {
            return override
        }
        return defaultDirectory().appendingPathComponent("muxyd.sock").path
    }

    public static var logPath: String {
        if let override = ProcessInfo.processInfo.environment[logPathOverrideKey], !override.isEmpty {
            return override
        }
        return defaultDirectory().appendingPathComponent("muxyd.log").path
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Muxy", isDirectory: true)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: defaultDirectory(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
