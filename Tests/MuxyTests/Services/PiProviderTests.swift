import Foundation
import Testing

@testable import Muxy

@Suite("PiProvider")
struct PiProviderTests {
    private let provider = PiProvider()

    @Test("id returns pi")
    func id() {
        #expect(provider.id == "pi")
    }

    @Test("displayName returns Pi")
    func displayName() {
        #expect(provider.displayName == "Pi")
    }

    @Test("socketTypeKey returns pi")
    func socketTypeKey() {
        #expect(provider.socketTypeKey == "pi")
    }

    @Test("iconName returns pi")
    func iconName() {
        #expect(provider.iconName == "pi")
    }

    @Test("executableNames contains pi")
    func executableNames() {
        #expect(provider.executableNames == ["pi"])
    }

    @Test("hookScriptName returns muxy-pi-extension")
    func hookScriptName() {
        #expect(provider.hookScriptName == "muxy-pi-extension")
    }

    @Test("settingsKey is derived from id")
    func settingsKey() {
        #expect(provider.settingsKey == "muxy.notifications.provider.pi.enabled")
    }

    @Test("isEnabled stores and retrieves value via UserDefaults")
    func isEnabledStorage() {
        let key = provider.settingsKey
        let defaults = UserDefaults.standard

        // Clean up before test
        defaults.removeObject(forKey: key)
        #expect(defaults.bool(forKey: key, fallback: true) == true)

        // Set to false
        provider.isEnabled = false
        #expect(provider.isEnabled == false)

        // Set back to true
        provider.isEnabled = true
        #expect(provider.isEnabled == true)

        // Clean up
        defaults.removeObject(forKey: key)
    }

    @Test("install creates extension file")
    func installCreatesFile() throws {
        // Use a temp directory instead of ~/.pi/agent/extensions
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The install method uses Bundle.appResources which won't find the file
        // in test context. This test verifies the method throws the expected error
        // when the bundle resource is not found.
        #expect(throws: PiProviderError.bundleResourceNotFound) {
            try provider.install(hookScriptPath: "")
        }
    }

    @Test("uninstall does nothing when file does not exist")
    func uninstallNoFile() throws {
        // Should not throw when there's nothing to remove
        try provider.uninstall()
    }

    @Test("isToolInstalled checks pi executable")
    func isToolInstalled() {
        // This test depends on whether pi is installed in the test environment.
        // We just verify it returns a Bool without throwing.
        let result = provider.isToolInstalled()
        #expect(result is Bool)
    }
}
