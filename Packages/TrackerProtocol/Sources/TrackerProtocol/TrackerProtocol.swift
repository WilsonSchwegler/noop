import Foundation

/// WarbFit protocol library — schema-driven TRACKER 4.0 frame decoder.
/// Implemented across Framing.swift / Values.swift / Schema.swift / Interpreter.swift (Phase B).
public enum TrackerProtocolInfo {
    /// URL of the bundled canonical decode schema (a resource of this package target).
    public static func schemaResourceURL() -> URL? {
        Bundle.module.url(forResource: "tracker_protocol", withExtension: "json")
    }
}
