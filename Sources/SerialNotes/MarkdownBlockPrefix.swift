import Foundation

/// The block-prefix grammar — indent + list/task marker or heading fence —
/// shared by the live editor's line styling and `MarkdownInlineToggle`'s
/// clamping, so a styling chord can never treat structure as inline text.
/// Keep the list pattern aligned with `MeetingExporter`: three unordered
/// markers, both ordered delimiters, optional task syntax. Digits are
/// ASCII-only ([0-9], not \d) so everything the grammar admits as ordered is
/// also something `OrderedMarker` can classify — ICU \d matches Unicode
/// digits that Int() can't parse, which used to hide the typed number behind
/// a drawn bullet.
enum MarkdownBlockPrefix {
    // ATX headings require a space after the fence (or an empty heading), so a
    // meeting note such as `#123` remains ordinary text.
    static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})([ \\t]+|$)")
    static let listRegex = try! NSRegularExpression(
        pattern: "^(\\s*)([-+*]|[0-9]+[.)])(\\s+)(?:(\\[[ xX]\\])(\\s+))?"
    )
    static let listMarkerOnlyRegex = try! NSRegularExpression(
        pattern: "^(\\s*)([-+*]|[0-9]+[.)])$"
    )

    /// UTF-16 length of `line`'s block prefix — where inline text begins.
    /// Zero for plain lines.
    static func length(ofLine line: String) -> Int {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let match = listRegex.firstMatch(in: line, range: range) {
            return match.range.length
        }
        if let match = headingRegex.firstMatch(in: line, range: range) {
            return match.range.length
        }
        return 0
    }
}
