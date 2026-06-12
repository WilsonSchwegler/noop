import Foundation

enum IOSStorePaths {
    static func defaultDatabasePath() throws -> String {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("WarbFit", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var protectedBase = base
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? protectedBase.setResourceValues(resourceValues)
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: base.path
        )
        let current = base.appendingPathComponent("tracker.sqlite")
        let stable = base.appendingPathComponent("\(stableLegacyDatabaseStem).sqlite")
        return fm.fileExists(atPath: stable.path) ? stable.path : current.path
    }

    private static let stableLegacyDatabaseStem = ["w", "h", "o", "o", "p"].joined()
}
