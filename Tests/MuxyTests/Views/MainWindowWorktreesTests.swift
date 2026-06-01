import Foundation
import Testing

@testable import Muxy

@MainActor
struct LiveWorktreesTestHarness {
    var registeredPaneIDs: [UUID] = []

    mutating func addToRegistry(paneID: UUID) {
        _ = TerminalViewRegistry.shared.view(for: paneID, workingDirectory: "/tmp/test")
        registeredPaneIDs.append(paneID)
        #expect(TerminalViewRegistry.shared.allPaneIDs.contains(paneID))
    }

    mutating func cleanupRegistry() {
        for id in registeredPaneIDs {
            TerminalViewRegistry.shared.removeView(for: id)
            #expect(!TerminalViewRegistry.shared.allPaneIDs.contains(id))
        }
        registeredPaneIDs.removeAll()
    }
}

@Suite("MainWindow.liveWorktreesSnapshot (active)", .serialized)
@MainActor
struct MainWindowLiveWorktreesSnapshotActiveTests {
    var harness = LiveWorktreesTestHarness()

    @Test("returns worktrees whose panes have live views in the registry")
    mutating func returnsWorktreesWithLiveViews() {
        let projectID = UUID()
        let activeWorktreeID = UUID()
        let backgroundWorktreeID = UUID()
        let orphanWorktreeID = UUID()
        let appState = makeAppState(
            projectID: projectID,
            activeWorktreeID: activeWorktreeID,
            backgroundWorktreeID: backgroundWorktreeID,
            orphanWorktreeID: orphanWorktreeID
        )
        let activePane = paneID(in: appState, worktreeID: activeWorktreeID)
        let backgroundPane = paneID(in: appState, worktreeID: backgroundWorktreeID)
        harness.addToRegistry(paneID: activePane)
        harness.addToRegistry(paneID: backgroundPane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: []
        ).activeWorktrees

        let resultSet = Set(result)
        #expect(resultSet.contains(WorktreeKey(projectID: projectID, worktreeID: activeWorktreeID)))
        #expect(resultSet.contains(WorktreeKey(projectID: projectID, worktreeID: backgroundWorktreeID)))
        #expect(!resultSet.contains(WorktreeKey(projectID: projectID, worktreeID: orphanWorktreeID)))
    }

    @Test("excludes worktrees from other projects")
    mutating func excludesOtherProjects() {
        let projectA = UUID()
        let projectB = UUID()
        let worktreeA = UUID()
        let worktreeB = UUID()
        let appState = makeAppState(
            projectID: projectA,
            activeWorktreeID: worktreeA,
            backgroundWorktreeID: nil,
            orphanWorktreeID: nil
        )
        addAreaWithPane(appState: appState, projectID: projectB, worktreeID: worktreeB)
        let paneB = paneID(in: appState, projectID: projectB, worktreeID: worktreeB)
        harness.addToRegistry(paneID: paneB)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: []
        ).activeWorktrees

        #expect(result == [WorktreeKey(projectID: projectA, worktreeID: worktreeA)])
    }

    @Test("skips paneIDs that no longer match a tab in the workspace")
    mutating func skipsOrphanedPaneIDs() {
        let projectID = UUID()
        let worktreeID = UUID()
        let appState = makeAppState(
            projectID: projectID,
            activeWorktreeID: worktreeID,
            backgroundWorktreeID: nil,
            orphanWorktreeID: nil
        )
        let realPane = paneID(in: appState, worktreeID: worktreeID)
        let orphanPane = UUID()
        harness.addToRegistry(paneID: realPane)
        harness.addToRegistry(paneID: orphanPane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: []
        ).activeWorktrees

        #expect(result == [WorktreeKey(projectID: projectID, worktreeID: worktreeID)])
    }

    @Test("deduplicates when many panes share the same worktree key")
    mutating func deduplicatesByWorktree() {
        let projectID = UUID()
        let worktreeID = UUID()
        let appState = makeAppState(
            projectID: projectID,
            activeWorktreeID: worktreeID,
            backgroundWorktreeID: nil,
            orphanWorktreeID: nil
        )
        let area = appState.workspaceRoots[WorktreeKey(projectID: projectID, worktreeID: worktreeID)]!
            .allAreas()[0]
        area.createTab()
        let firstPane = area.tabs[0].content.pane!.id
        let secondPane = area.tabs[1].content.pane!.id
        harness.addToRegistry(paneID: firstPane)
        harness.addToRegistry(paneID: secondPane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: []
        ).activeWorktrees

        #expect(result == [WorktreeKey(projectID: projectID, worktreeID: worktreeID)])
    }

    @Test("returns activeKey even when registry is empty")
    mutating func returnsActiveKeyWhenRegistryEmpty() {
        let projectID = UUID()
        let worktreeID = UUID()
        let appState = makeAppState(
            projectID: projectID,
            activeWorktreeID: worktreeID,
            backgroundWorktreeID: nil,
            orphanWorktreeID: nil
        )
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: [],
            in: appState,
            projects: []
        ).activeWorktrees

        #expect(result == [WorktreeKey(projectID: projectID, worktreeID: worktreeID)])
    }

    @Test("nil activeProjectID returns empty active and routes panes to background")
    mutating func nilActiveProjectIDRoutesToBackground() {
        let projectID = UUID()
        let worktreeID = UUID()
        let appState = AppState(
            selectionStore: SelectionStoreStub(),
            terminalViews: TerminalViewRemovingStub(),
            workspacePersistence: WorkspacePersistenceStub()
        )
        addAreaWithPane(appState: appState, projectID: projectID, worktreeID: worktreeID)
        appState.activeProjectID = nil
        let pane = paneID(in: appState, worktreeID: worktreeID)
        harness.addToRegistry(paneID: pane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: [Project(name: "P", path: "/tmp/p")]
        )

        #expect(result.activeWorktrees.isEmpty)
        #expect(result.backgroundWorktrees.isEmpty)
    }

    private func paneID(in appState: AppState, projectID: UUID? = nil, worktreeID: UUID) -> UUID {
        for (key, root) in appState.workspaceRoots {
            if let projectID, key.projectID != projectID { continue }
            if key.worktreeID != worktreeID { continue }
            for area in root.allAreas() {
                for tab in area.tabs {
                    if let pane = tab.content.pane { return pane.id }
                }
            }
        }
        Issue.record("no pane for worktree \(worktreeID)")
        return UUID()
    }

    private func makeAppState(
        projectID: UUID,
        activeWorktreeID: UUID,
        backgroundWorktreeID: UUID?,
        orphanWorktreeID: UUID?
    ) -> AppState {
        let appState = AppState(
            selectionStore: SelectionStoreStub(),
            terminalViews: TerminalViewRemovingStub(),
            workspacePersistence: WorkspacePersistenceStub()
        )
        addAreaWithPane(appState: appState, projectID: projectID, worktreeID: activeWorktreeID)
        appState.activeProjectID = projectID
        appState.activeWorktreeID[projectID] = activeWorktreeID
        if let backgroundWorktreeID {
            addAreaWithPane(appState: appState, projectID: projectID, worktreeID: backgroundWorktreeID)
        }
        if let orphanWorktreeID {
            addAreaWithPane(appState: appState, projectID: projectID, worktreeID: orphanWorktreeID)
        }
        return appState
    }

    private func addAreaWithPane(appState: AppState, projectID: UUID, worktreeID: UUID) {
        let key = WorktreeKey(projectID: projectID, worktreeID: worktreeID)
        let area = TabArea(projectPath: "/tmp/\(worktreeID.uuidString)")
        appState.workspaceRoots[key] = .tabArea(area)
        appState.focusedAreaID[key] = area.id
    }
}

@Suite("MainWindow.liveWorktreesSnapshot (background)", .serialized)
@MainActor
struct MainWindowLiveWorktreesSnapshotBackgroundTests {
    var harness = LiveWorktreesTestHarness()

    @Test("returns background project worktrees with live panes")
    mutating func returnsBackgroundProjectWorktrees() {
        let activeProject = Project(name: "Active", path: "/tmp/active")
        let bgProject = Project(name: "BG", path: "/tmp/bg")
        let bgWorktreeID = UUID()
        let appState = makeAppState(activeProject: activeProject, backgroundProjects: [(bgProject, bgWorktreeID)])
        let bgPane = findPane(in: appState, projectID: bgProject.id, worktreeID: bgWorktreeID)
        harness.addToRegistry(paneID: bgPane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: [activeProject, bgProject]
        ).backgroundWorktrees

        #expect(result.count == 1)
        #expect(result[0].key == WorktreeKey(projectID: bgProject.id, worktreeID: bgWorktreeID))
        #expect(result[0].project == bgProject)
    }

    @Test("excludes active project worktrees")
    mutating func excludesActiveProject() {
        let activeProject = Project(name: "Active", path: "/tmp/active")
        let appState = makeAppState(activeProject: activeProject, backgroundProjects: [])
        let activeWorktreeID = appState.activeWorktreeID[activeProject.id]!
        let activePane = findPane(in: appState, projectID: activeProject.id, worktreeID: activeWorktreeID)
        harness.addToRegistry(paneID: activePane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: [activeProject]
        ).backgroundWorktrees

        #expect(result.isEmpty)
    }

    @Test("deduplicates same worktree with multiple panes")
    mutating func deduplicatesSameWorktree() {
        let activeProject = Project(name: "Active", path: "/tmp/active")
        let bgProject = Project(name: "BG", path: "/tmp/bg")
        let bgWorktreeID = UUID()
        let appState = makeAppState(activeProject: activeProject, backgroundProjects: [(bgProject, bgWorktreeID)])
        let key = WorktreeKey(projectID: bgProject.id, worktreeID: bgWorktreeID)
        let area = appState.workspaceRoots[key]!.allAreas()[0]
        area.createTab()
        let pane1 = area.tabs[0].content.pane!.id
        let pane2 = area.tabs[1].content.pane!.id
        harness.addToRegistry(paneID: pane1)
        harness.addToRegistry(paneID: pane2)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: [activeProject, bgProject]
        ).backgroundWorktrees

        #expect(result.count == 1)
    }

    @Test("skips panes whose project is not in project list")
    mutating func skipsUnknownProject() {
        let activeProject = Project(name: "Active", path: "/tmp/active")
        let unknownProjectID = UUID()
        let unknownWorktreeID = UUID()
        let appState = makeAppState(activeProject: activeProject, backgroundProjects: [])
        let unknownKey = WorktreeKey(projectID: unknownProjectID, worktreeID: unknownWorktreeID)
        let unknownArea = TabArea(projectPath: "/tmp/unknown")
        appState.workspaceRoots[unknownKey] = .tabArea(unknownArea)
        appState.focusedAreaID[unknownKey] = unknownArea.id
        let unknownPane = unknownArea.tabs[0].content.pane!.id
        harness.addToRegistry(paneID: unknownPane)
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: TerminalViewRegistry.shared.allPaneIDs,
            in: appState,
            projects: [activeProject]
        ).backgroundWorktrees

        #expect(result.isEmpty)
    }

    @Test("returns empty when paneIDs is empty")
    mutating func emptyPaneIDsReturnsEmpty() {
        let activeProject = Project(name: "Active", path: "/tmp/active")
        let bgProject = Project(name: "BG", path: "/tmp/bg")
        let bgWorktreeID = UUID()
        let appState = makeAppState(activeProject: activeProject, backgroundProjects: [(bgProject, bgWorktreeID)])
        defer { harness.cleanupRegistry() }

        let result = MainWindow.liveWorktreesSnapshot(
            paneIDs: [],
            in: appState,
            projects: [activeProject, bgProject]
        ).backgroundWorktrees

        #expect(result.isEmpty)
    }

    private func findPane(in appState: AppState, projectID: UUID, worktreeID: UUID) -> UUID {
        for (key, root) in appState.workspaceRoots {
            guard key.projectID == projectID, key.worktreeID == worktreeID else { continue }
            for area in root.allAreas() {
                for tab in area.tabs {
                    if let pane = tab.content.pane { return pane.id }
                }
            }
        }
        Issue.record("no pane for project \(projectID) worktree \(worktreeID)")
        return UUID()
    }

    private func makeAppState(
        activeProject: Project,
        backgroundProjects: [(Project, UUID)]
    ) -> AppState {
        let appState = AppState(
            selectionStore: SelectionStoreStub(),
            terminalViews: TerminalViewRemovingStub(),
            workspacePersistence: WorkspacePersistenceStub()
        )
        let activeWorktreeID = UUID()
        let activeKey = WorktreeKey(projectID: activeProject.id, worktreeID: activeWorktreeID)
        let activeArea = TabArea(projectPath: "/tmp/\(activeWorktreeID.uuidString)")
        appState.workspaceRoots[activeKey] = .tabArea(activeArea)
        appState.focusedAreaID[activeKey] = activeArea.id
        appState.activeProjectID = activeProject.id
        appState.activeWorktreeID[activeProject.id] = activeWorktreeID
        for (project, worktreeID) in backgroundProjects {
            let key = WorktreeKey(projectID: project.id, worktreeID: worktreeID)
            let area = TabArea(projectPath: "/tmp/\(worktreeID.uuidString)")
            appState.workspaceRoots[key] = .tabArea(area)
            appState.focusedAreaID[key] = area.id
        }
        return appState
    }
}

@Suite("GhosttyTerminalNSView.wakeFromOffline", .serialized)
@MainActor
struct GhosttyTerminalNSViewWakeFromOfflineTests {
    var harness = LiveWorktreesTestHarness()

    @Test("no-op on a freshly-registered view (not offlined)")
    mutating func noOpOnFreshView() {
        let paneID = UUID()
        let view = TerminalViewRegistry.shared.view(for: paneID, workingDirectory: "/tmp/test")
        harness.addToRegistry(paneID: paneID)
        defer { harness.cleanupRegistry() }

        let beforeSurface = view.surface
        view.wakeFromOffline()
        let afterSurface = view.surface

        #expect(beforeSurface == nil)
        #expect(afterSurface == beforeSurface)
    }

    @Test("safe to call twice on a fresh view")
    mutating func safeToCallTwiceOnFreshView() {
        let paneID = UUID()
        let view = TerminalViewRegistry.shared.view(for: paneID, workingDirectory: "/tmp/test")
        harness.addToRegistry(paneID: paneID)
        defer { harness.cleanupRegistry() }

        view.wakeFromOffline()
        view.wakeFromOffline()
    }

    @Test("no-op when view has a surface")
    mutating func noOpWhenViewHasSurface() {
        let paneID = UUID()
        let view = TerminalViewRegistry.shared.view(for: paneID, workingDirectory: "/tmp/test")
        harness.addToRegistry(paneID: paneID)
        defer { harness.cleanupRegistry() }

        view.materializeHeadless()
        let surfaceBefore = view.surface
        #expect(surfaceBefore != nil)

        view.wakeFromOffline()
        #expect(view.surface == surfaceBefore)
    }
}

@Suite("MuxyAPI waitForView routing", .serialized)
@MainActor
struct MuxyAPIWaitForViewRoutingTests {
    var harness = LiveWorktreesTestHarness()

    @Test("send returns paneNotFound for unknown pane ID")
    mutating func sendReturnsNotFoundForUnknownPane() async {
        defer { harness.cleanupRegistry() }
        let appState = makeAppState()
        let result = await MuxyAPI.Panes.send(
            paneIDString: UUID().uuidString,
            text: "ls",
            appState: appState
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure, got success")
            return
        }
        guard case .paneNotFound = err else {
            Issue.record("expected paneNotFound, got \(err)")
            return
        }
    }

    @Test("readScreen returns paneSurfaceNotReady for view with no surface and not offlined")
    mutating func readScreenReturnsSurfaceNotReady() async {
        let paneID = UUID()
        _ = TerminalViewRegistry.shared.view(for: paneID, workingDirectory: "/tmp/test")
        harness.addToRegistry(paneID: paneID)
        defer { harness.cleanupRegistry() }
        let appState = makeAppState()

        let result = await MuxyAPI.Panes.readScreen(
            paneIDString: paneID.uuidString,
            lines: 10,
            appState: appState
        )
        switch result {
        case .success(let text):
            #expect(text == "")
        case .failure(let err):
            if case .paneSurfaceNotReady = err {
            } else {
                Issue.record("expected success or paneSurfaceNotReady, got \(err)")
            }
        }
    }

    @Test("sendKeys returns paneNotFound for unknown pane ID")
    mutating func sendKeysReturnsNotFoundForUnknownPane() async {
        defer { harness.cleanupRegistry() }
        let appState = makeAppState()
        let result = await MuxyAPI.Panes.sendKeys(
            paneIDString: UUID().uuidString,
            key: "enter",
            appState: appState
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure, got success")
            return
        }
        guard case .paneNotFound = err else {
            Issue.record("expected paneNotFound, got \(err)")
            return
        }
    }

    private func makeAppState() -> AppState {
        AppState(
            selectionStore: SelectionStoreStub(),
            terminalViews: TerminalViewRemovingStub(),
            workspacePersistence: WorkspacePersistenceStub()
        )
    }
}

private final class WorkspacePersistenceStub: WorkspacePersisting {
    func loadWorkspaces() throws -> [WorkspaceSnapshot] { [] }
    func saveWorkspaces(_: [WorkspaceSnapshot]) throws {}
}

@MainActor
private final class SelectionStoreStub: ActiveProjectSelectionStoring {
    private var activeProjectID: UUID?
    private var activeWorktreeIDs: [UUID: UUID] = [:]
    func loadActiveProjectID() -> UUID? { activeProjectID }
    func saveActiveProjectID(_ id: UUID?) { activeProjectID = id }
    func loadActiveWorktreeIDs() -> [UUID: UUID] { activeWorktreeIDs }
    func saveActiveWorktreeIDs(_ ids: [UUID: UUID]) { activeWorktreeIDs = ids }
}

@MainActor
private final class TerminalViewRemovingStub: TerminalViewRemoving {
    func removeView(for _: UUID) {}
    func needsConfirmQuit(for _: UUID) -> Bool { false }
}
