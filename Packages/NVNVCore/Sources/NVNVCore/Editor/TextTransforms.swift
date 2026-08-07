import Foundation

public enum TextTransforms {
    public static func tabInsertion(
        text: String, caret: Int, softTabs: Bool, tabWidth: Int
    ) -> (range: NSRange, replacement: String) {
        let source = text as NSString
        let safeCaret = min(max(caret, 0), source.length)
        guard softTabs else {
            return (NSRange(location: safeCaret, length: 0), "\t")
        }

        let width = min(max(tabWidth, 1), 16)
        let lineStart = source.lineRange(for: NSRange(location: safeCaret, length: 0)).location
        let beforeCaret = source.substring(
            with: NSRange(location: lineStart, length: safeCaret - lineStart)
        )
        var column = 0
        for character in beforeCaret.utf16 {
            if character == 9 {
                column += width - (column % width)
            } else {
                column += 1
            }
        }
        let count = width - (column % width)
        return (
            NSRange(location: safeCaret, length: 0),
            String(repeating: " ", count: count)
        )
    }

    public static func indent(
        text: String, selection: NSRange, softTabs: Bool, tabWidth: Int
    ) -> (String, NSRange) {
        let source = text as NSString
        let width = min(max(tabWidth, 1), 16)
        let touched = source.lineRange(for: selection)
        let block = source.substring(with: touched)
        let prefix = softTabs ? String(repeating: " ", count: width) : "\t"
        let (lines, hasTrailingNewline) = indentationLines(in: block)
        let replacement = lines.map { prefix + $0 }.joined(separator: "\n")
            + (hasTrailingNewline ? "\n" : "")
        let output = source.replacingCharacters(in: touched, with: replacement)
        let added = prefix.utf16.count * lines.count
        return (output, NSRange(location: selection.location + prefix.utf16.count, length: selection.length + max(0, added - prefix.utf16.count)))
    }

    public static func outdent(text: String, selection: NSRange, tabWidth: Int) -> (String, NSRange) {
        let source = text as NSString
        let width = min(max(tabWidth, 1), 16)
        let touched = source.lineRange(for: selection)
        let block = source.substring(with: touched)
        let (lines, hasTrailingNewline) = indentationLines(in: block)
        var deletions: [(location: Int, length: Int)] = []
        var lineStart = touched.location
        let transformedLines = lines.map { line -> String in
            var value = line
            let removed: Int
            if value.hasPrefix("\t") {
                value.removeFirst()
                removed = 1
            } else {
                let spaces = min(value.prefix(while: { $0 == " " }).count, width)
                value.removeFirst(spaces)
                removed = spaces
            }
            if removed > 0 { deletions.append((lineStart, removed)) }
            lineStart += line.utf16.count + 1
            return value
        }
        let replacement = transformedLines.joined(separator: "\n")
            + (hasTrailingNewline ? "\n" : "")
        let output = source.replacingCharacters(in: touched, with: replacement)
        let start = position(selection.location, afterDeleting: deletions)
        let end = position(NSMaxRange(selection), afterDeleting: deletions)
        return (output, NSRange(location: start, length: max(0, end - start)))
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

    private static func indentationLines(in block: String) -> ([String], Bool) {
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        return (lines, hasTrailingNewline)
    }

    private static func position(
        _ original: Int, afterDeleting deletions: [(location: Int, length: Int)]
    ) -> Int {
        var removedBeforePosition = 0
        for deletion in deletions {
            if original <= deletion.location { break }
            if original < deletion.location + deletion.length {
                return deletion.location - removedBeforePosition
            }
            removedBeforePosition += deletion.length
        }
        return original - removedBeforePosition
    }
}
