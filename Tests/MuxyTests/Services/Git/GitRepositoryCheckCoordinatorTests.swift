import Foundation
import Testing

@testable import Muxy

@Suite("GitRepositoryCheckCoordinator")
struct GitRepositoryCheckCoordinatorTests {
    @Test("deduplicates concurrent checks for the same repository")
    func deduplicatesConcurrentChecks() async {
        let probe = GitRepositoryCheckProbe()
        let coordinator = makeCoordinator(maxConcurrentChecks: 4, probe: probe)

        let results = await results(
            for: Array(repeating: ("/repo", WorkspaceContext.local), count: 8),
            coordinator: coordinator
        )
        let checkCount = await probe.checkCount

        #expect(results.allSatisfy { $0 })
        #expect(checkCount == 1)
    }

    @Test("treats workspace contexts as distinct repositories")
    func separatesWorkspaceContexts() async {
        let probe = GitRepositoryCheckProbe()
        let coordinator = makeCoordinator(maxConcurrentChecks: 4, probe: probe)
        let remote = WorkspaceContext.ssh(SSHDestination(host: "server"))

        let results = await results(
            for: [("/repo", WorkspaceContext.local), ("/repo", remote)],
            coordinator: coordinator
        )
        let checkCount = await probe.checkCount

        #expect(results.allSatisfy { $0 })
        #expect(checkCount == 2)
    }

    @Test("limits concurrent checks")
    func limitsConcurrentChecks() async {
        let probe = GitRepositoryCheckProbe()
        let coordinator = makeCoordinator(maxConcurrentChecks: 2, probe: probe)
        let repositories = (0 ..< 8).map { ("/repo-\($0)", WorkspaceContext.local) }

        let results = await results(for: repositories, coordinator: coordinator)
        let maximumActiveCheckCount = await probe.maximumActiveCheckCount

        #expect(results.allSatisfy { $0 })
        #expect(maximumActiveCheckCount == 2)
    }

    private func makeCoordinator(
        maxConcurrentChecks: Int,
        probe: GitRepositoryCheckProbe
    ) -> GitRepositoryCheckCoordinator {
        GitRepositoryCheckCoordinator(maxConcurrentChecks: maxConcurrentChecks) { path, context in
            await probe.check(path: path, context: context)
        }
    }

    private func results(
        for repositories: [(String, WorkspaceContext)],
        coordinator: GitRepositoryCheckCoordinator
    ) async -> [Bool] {
        await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for (path, context) in repositories {
                group.addTask {
                    await coordinator.isGitRepository(path, context: context)
                }
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

private actor GitRepositoryCheckProbe {
    private(set) var checkCount = 0
    private(set) var maximumActiveCheckCount = 0
    private var activeCheckCount = 0

    func check(path _: String, context _: WorkspaceContext) async -> Bool {
        checkCount += 1
        activeCheckCount += 1
        maximumActiveCheckCount = max(maximumActiveCheckCount, activeCheckCount)
        try? await Task.sleep(for: .milliseconds(50))
        activeCheckCount -= 1
        return true
    }
}
