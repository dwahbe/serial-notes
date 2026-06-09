import Foundation

/// Escaping for values embedded inside an AppleScript double-quoted string literal.
/// Shared by `MeetingExporter` (the Notes note body + folder name) and
/// `MoveToApplications` (the privileged `do shell script` command). `internal` so
/// the injection-safety behavior is unit-testable.
enum AppleScriptString {
    /// Escape `\` then `"` so `value` is safe inside a `"…"` AppleScript literal.
    static func escapingLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
