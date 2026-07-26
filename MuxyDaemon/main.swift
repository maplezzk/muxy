import Foundation
import MuxyDaemonKit

enum MuxyDaemonCommand {
    static let sessionCommandEnvironmentKey = "MUXYD_SESSION_COMMAND"

    static func run() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = arguments.first else {
            FileHandle.standardError.write(Data("usage: muxyd <daemon|shim|list|kill> [args]\n".utf8))
            return 2
        }
        switch subcommand {
        case "daemon":
            return runDaemon()
        case "shim":
            return runShim(arguments: Array(arguments.dropFirst()))
        case "list":
            return runList()
        case "kill":
            return runKill(arguments: Array(arguments.dropFirst()))
        default:
            FileHandle.standardError.write(Data("unknown subcommand: \(subcommand)\n".utf8))
            return 2
        }
    }

    private static func runDaemon() -> Int32 {
        try? MuxyDaemonPaths.ensureDirectory()
        daemonLog("muxyd daemon starting pid \(ProcessInfo.processInfo.processIdentifier)")
        let server = MuxyDaemonServer(socketPath: MuxyDaemonPaths.socketPath, log: daemonLog)
        do {
            try server.run()
            return 0
        } catch {
            daemonLog("muxyd: \(error)")
            return 1
        }
    }

    private static let daemonLog: @Sendable (String) -> Void = { message in
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = MuxyDaemonPaths.logPath
        if !FileManager.default.fileExists(atPath: path) {
            try? MuxyDaemonPaths.ensureDirectory()
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private static func runShim(arguments: [String]) -> Int32 {
        guard let sessionIDString = arguments.first, let sessionID = UUID(uuidString: sessionIDString) else {
            FileHandle.standardError.write(Data("usage: muxyd shim <session-uuid>\n".utf8))
            return 2
        }
        let workingDirectory = FileManager.default.currentDirectoryPath
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let shim = MuxyDaemonShim(
            socketPath: MuxyDaemonPaths.socketPath,
            daemonExecutablePath: executableURL.path
        )
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = ProcessInfo.processInfo.environment[sessionCommandEnvironmentKey]
            ?? "exec \"\(shell)\" -l"
        return shim.run(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            command: command,
            environment: filteredEnvironment()
        )
    }

    private static func runList() -> Int32 {
        let client = MuxyDaemonClient()
        do {
            try client.connect(socketPath: MuxyDaemonPaths.socketPath)
            let sessions = try client.listSessions()
            for session in sessions {
                let state = session.exited ? "exited(\(session.exitStatus ?? 0))" : "running"
                print("\(session.sessionID.uuidString)\tpid \(session.childPID)\t\(state)\t\(session.cols)x\(session.rows)")
            }
            client.close()
            return 0
        } catch {
            FileHandle.standardError.write(Data("muxyd list: \(error)\n".utf8))
            return 1
        }
    }

    private static func runKill(arguments: [String]) -> Int32 {
        guard let sessionIDString = arguments.first, let sessionID = UUID(uuidString: sessionIDString) else {
            FileHandle.standardError.write(Data("usage: muxyd kill <session-uuid>\n".utf8))
            return 2
        }
        let client = MuxyDaemonClient()
        do {
            try client.connect(socketPath: MuxyDaemonPaths.socketPath)
            try client.killSession(sessionID: sessionID)
            client.close()
            return 0
        } catch {
            FileHandle.standardError.write(Data("muxyd kill: \(error)\n".utf8))
            return 1
        }
    }

    private static func filteredEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let removedKeys = ["SHLVL", "OLDPWD", "PWD", "_"]
        for key in removedKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}

exit(MuxyDaemonCommand.run())
