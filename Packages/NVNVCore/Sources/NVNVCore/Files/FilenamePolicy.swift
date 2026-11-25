import Foundation

public enum FilenamePolicy {
    public static func sanitizedStem(_ input: String, maxUTF8Bytes: Int = 240) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NVNVError.invalidTitle("enter at least one non-whitespace character") }

        var output = ""
        var replacing = false
        for scalar in trimmed.unicodeScalars {
            let forbidden = scalar == "/" || scalar == ":" || scalar.value == 0 ||
                CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            if forbidden {
                if !replacing { output.append("-") }
                replacing = true
            } else {
                output.unicodeScalars.append(scalar)
                replacing = false
            }
        }
        output = output.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard output != ".", output != "..", !output.isEmpty else {
            throw NVNVError.invalidTitle("the title does not produce a usable filename")
        }
        while output.utf8.count > maxUTF8Bytes, !output.isEmpty { output.removeLast() }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    public static func availableFilename(
        stem: String, extension ext: String, in directory: URL,
        excluding: URL? = nil, fileManager: FileManager = .default
    ) -> String {
        var counter = 1
        while true {
            let suffix = counter == 1 ? "" : " \(counter)"
            let candidate = "\(stem)\(suffix).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if url.standardizedFileURL == excluding?.standardizedFileURL || !fileManager.fileExists(atPath: url.path) {
                return candidate
            }
            if let excluding, isCaseVariant(url, of: excluding) { return candidate }
            counter += 1
        }
    }

    /// True when `candidate` differs from `existing` only by letter case and
    /// resolves to the same file, as it does on a case-insensitive volume. A
    /// distinct file with that spelling on a case-sensitive volume is not a
    /// variant and must still be treated as a collision.
    public static func isCaseVariant(_ candidate: URL, of existing: URL) -> Bool {
        guard candidate.lastPathComponent != existing.lastPathComponent,
              candidate.lastPathComponent.caseInsensitiveCompare(existing.lastPathComponent) == .orderedSame,
              candidate.deletingLastPathComponent().standardizedFileURL
                == existing.deletingLastPathComponent().standardizedFileURL else { return false }
        var candidateInfo = stat()
        var existingInfo = stat()
        guard lstat(candidate.path, &candidateInfo) == 0, lstat(existing.path, &existingInfo) == 0 else { return false }
        return candidateInfo.st_dev == existingInfo.st_dev && candidateInfo.st_ino == existingInfo.st_ino
    }
}
