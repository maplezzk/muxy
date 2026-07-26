import Foundation
import Testing

@testable import Muxy

@Suite("TerminalLaunchCommand daemon helpers")
struct DaemonLaunchCommandTests {
    @Test("shim command runs muxyd with the session ID")
    func shimCommand() {
        let sessionID = UUID()
        let command = TerminalLaunchCommand.daemonShimCommand(muxydPath: "/Applications/Muxy.app/Contents/MacOS/muxyd", sessionID: sessionID)
        #expect(!command.hasPrefix("exec "))
        #expect(command.contains("muxyd"))
        #expect(command.contains("shim"))
        #expect(command.contains(sessionID.uuidString))
    }

    @Test("shim command escapes paths with spaces")
    func shimCommandEscapesSpaces() {
        let sessionID = UUID()
        let command = TerminalLaunchCommand.daemonShimCommand(muxydPath: "/Applications/Muxy App/muxyd", sessionID: sessionID)
        #expect(command.contains("'"))
        #expect(!command.contains("/Applications/Muxy App/muxyd shim"))
    }

    @Test("daemon session command wraps the login shell script")
    func sessionCommand() {
        let command = TerminalLaunchCommand.daemonSessionCommand(interactive: true, keepsShellOpen: false)
        #expect(command.contains(TerminalLaunchCommand.environmentKey))
        #expect(command.contains("-l"))
    }

    @Test("default session command execs a login shell")
    func defaultSessionCommand() {
        let command = TerminalLaunchCommand.daemonDefaultSessionCommand(shell: "/bin/zsh")
        #expect(command == "exec '/bin/zsh' -l" || command == "exec /bin/zsh -l")
    }
}
