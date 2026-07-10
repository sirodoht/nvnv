import Foundation

public enum TextTransforms {
    public static func indent(
        text: String, selection: NSRange, softTabs: Bool, tabWidth: Int
    ) -> (String, NSRange) {
        let source = text as NSString
        let width = min(max(tabWidth, 1), 16)
        let touched = source.lineRange(for: selection)
        let block = source.substring(with: touched)
        let prefix = softTabs ? String(repeating: " ", count: width) : "\t"
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        let replacement = lines.map { prefix + $0 }.joined(separator: "\n")
        let output = source.replacingCharacters(in: touched, with: replacement)
        let added = prefix.utf16.count * lines.count
        return (output, NSRange(location: selection.location + prefix.utf16.count, length: selection.length + max(0, added - prefix.utf16.count)))
    }

    public static func outdent(text: String, selection: NSRange, tabWidth: Int) -> (String, NSRange) {
        let source = text as NSString
        let width = min(max(tabWidth, 1), 16)
        let touched = source.lineRange(for: selection)
        let block = source.substring(with: touched)
        var removed = 0
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var value = String(line)
            if value.hasPrefix("\t") { value.removeFirst(); removed += 1 }
            else {
                let spaces = min(value.prefix(while: { $0 == " " }).count, width)
                value.removeFirst(spaces)
                removed += spaces
            }
            return value
        }
        let replacement = lines.joined(separator: "\n")
        let output = source.replacingCharacters(in: touched, with: replacement)
        return (output, NSRange(location: max(touched.location, selection.location - min(removed, selection.location - touched.location)), length: max(0, selection.length - max(0, removed - 1))))
    }

    public static func newlineInsertion(text: String, caret: Int) -> (range: NSRange, replacement: String) {
        let source = text as NSString
        let safeCaret = min(max(caret, 0), source.length)
        let lineRange = source.lineRange(for: NSRange(location: safeCaret, length: 0))
        let beforeCaret = NSRange(location: lineRange.location, length: safeCaret - lineRange.location)
        let line = source.substring(with: beforeCaret)
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let content = String(line.dropFirst(indentation.count))

        if let marker = listMarker(in: content) {
            if marker.remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                let markerRange = NSRange(location: lineRange.location + indentation.utf16.count, length: marker.full.utf16.count)
                return (markerRange, "")
            }
            return (NSRange(location: safeCaret, length: 0), "\n\(indentation)\(marker.next)")
        }
        if content.isEmpty, !indentation.isEmpty {
            let amount = indentation.last == "\t" ? 1 : min(4, indentation.count)
            return (NSRange(location: safeCaret - amount, length: amount), "\n")
        }
        return (NSRange(location: safeCaret, length: 0), "\n\(indentation)")
    }

    private static func listMarker(in content: String) -> (full: String, next: String, remainder: String)? {
        for bullet in ["- ", "* ", "+ "] where content.hasPrefix(bullet) {
            return (bullet, bullet, String(content.dropFirst(bullet.count)))
        }
        let pattern = #"^([0-9]+)\.\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let numberRange = Range(match.range(at: 1), in: content),
              let number = UInt64(content[numberRange]) else { return nil }
        let fullRange = Range(match.range, in: content)!
        let full = String(content[fullRange])
        let next = number == UInt64.max ? full : "\(number + 1). "
        return (full, next, String(content[fullRange.upperBound...]))
    }
}
