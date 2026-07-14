import Foundation

public struct DetectedURL: Equatable, Sendable {
    public let url: URL
    public let range: NSRange

    public init(url: URL, range: NSRange) {
        self.url = url
        self.range = range
    }
}

public final class SupportedURLDetector {
    private let detector: NSDataDetector

    public init?() {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        self.detector = detector
    }

    public func matches(in text: String) -> [DetectedURL] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url,
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return DetectedURL(url: url, range: match.range)
        }
    }
}
