import Foundation

extension Bundle {
    static let appResources: Bundle = {
        let bundleName = "Muxy_Muxy.bundle"

        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
        ]

        for case let url? in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        return Bundle.main
    }()

    static var providerIconsURL: URL? {
        var candidates: [URL] = []

        if let resourceURL = appResources.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("ProviderIcons"))
        }

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                return candidate
            }
        }

        return nil
    }
}
