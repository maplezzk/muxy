import Foundation

enum DaemonSessionWarmup {
    static func startDaemonIfNeeded() {
        guard DaemonSessionSettings.isEnabled else { return }
        guard let muxydPath = MuxydBinaryLocator.binaryPath() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: muxydPath)
        process.arguments = ["daemon"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("muxyd warmup spawn failed: \(error)")
        }
    }
}
