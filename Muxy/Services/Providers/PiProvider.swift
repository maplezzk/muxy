import Foundation

struct PiProvider: AIProviderIntegration, AIUsageProvider {
    let id = "pi"
    let displayName = "Pi"
    let socketTypeKey = "pi"
    let iconName = "pi"
    let executableNames = ["pi"]
    let hookScriptName = "muxy-pi-extension"
    let hookScriptExtension = "ts"

    private static let extensionsDir = NSHomeDirectory() + "/.pi/agent/extensions"
    private static let destinationFileName = "muxy-notify.ts"
    private static var destinationPath: String { extensionsDir + "/" + destinationFileName }
    private static let bundleResourceName = "muxy-pi-extension"
    private static let bundleResourceExtension = "ts"

    func isToolInstalled() -> Bool {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.local/bin/pi",
            "/usr/local/bin/pi",
            "/opt/homebrew/bin/pi",
        ]
        return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let settingsPath = NSHomeDirectory() + "/.pi/agent/settings.json"

    func install(hookScriptPath: String) throws {
        // Note: hookScriptPath is from installAll/forceInstall which hardcodes .sh extension.
        // PiProvider bypasses this by locating the bundled file directly.
        guard let sourceURL = Bundle.appResources.url(
            forResource: Self.bundleResourceName,
            withExtension: Self.bundleResourceExtension
        ) else {
            throw PiProviderError.bundleResourceNotFound
        }

        let sourceData = try Data(contentsOf: sourceURL)

        // Skip if destination already exists with same content
        if FileManager.default.fileExists(atPath: Self.destinationPath),
           let existingData = try? Data(contentsOf: URL(fileURLWithPath: Self.destinationPath)),
           existingData == sourceData
        {
            return
        }

        try FileManager.default.createDirectory(
            atPath: Self.extensionsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FilePermissions.privateDirectory]
        )

        let destURL = URL(fileURLWithPath: Self.destinationPath)
        if FileManager.default.fileExists(atPath: Self.destinationPath) {
            try FileManager.default.removeItem(at: destURL)
        }

        try sourceData.write(to: destURL, options: .atomic)

        try Self.registerExtensionInSettings()
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: Self.destinationPath) else { return }
        try FileManager.default.removeItem(atPath: Self.destinationPath)
        try Self.unregisterExtensionFromSettings()
    }

    private static func registerExtensionInSettings() throws {
        guard FileManager.default.fileExists(atPath: Self.settingsPath) else { return }
        let url = URL(fileURLWithPath: Self.settingsPath)
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var extensions = json["extensions"] as? [String] ?? []
        let extensionPath = Self.destinationPath

        if !extensions.contains(extensionPath) {
            extensions.append(extensionPath)
            json["extensions"] = extensions
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])

            let backupPath = Self.settingsPath + ".muxy-backup"
            try? FileManager.default.removeItem(atPath: backupPath)
            try FileManager.default.copyItem(atPath: Self.settingsPath, toPath: backupPath)

            try updatedData.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: FilePermissions.privateFile],
                ofItemAtPath: Self.settingsPath
            )
        }
    }

    private static func unregisterExtensionFromSettings() throws {
        guard FileManager.default.fileExists(atPath: Self.settingsPath) else { return }
        let url = URL(fileURLWithPath: Self.settingsPath)
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        guard var extensions = json["extensions"] as? [String] else { return }
        extensions.removeAll { $0 == Self.destinationPath }

        if extensions.isEmpty {
            json.removeValue(forKey: "extensions")
        } else {
            json["extensions"] = extensions
        }

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])

        let backupPath = Self.settingsPath + ".muxy-backup"
        try? FileManager.default.removeItem(atPath: backupPath)
        try FileManager.default.copyItem(atPath: Self.settingsPath, toPath: backupPath)

        try updatedData.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: FilePermissions.privateFile],
            ofItemAtPath: Self.settingsPath
        )
    }
}

enum PiProviderError: LocalizedError {
    case bundleResourceNotFound

    var errorDescription: String? {
        switch self {
        case .bundleResourceNotFound:
            return "Pi extension file (muxy-pi-extension.ts) not found in app bundle"
        }
    }
}
