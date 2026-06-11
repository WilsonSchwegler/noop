import Foundation

enum IOSStorePaths {
    static func defaultDatabasePath() throws -> String {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("WarbFit", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("whoop.sqlite").path
    }
}
