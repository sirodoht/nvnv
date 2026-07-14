import Foundation
import NVNVCore
import Testing

@Suite("Supported URL detection")
struct SupportedURLDetectorTests {
    @Test func detectsLinksInAnExistingPlainTextBody() throws {
        let body = """
        Older links: https://example.com/path and http://example.org.
        Contact mailto:hello@example.com but not ftp://example.net/file.
        """
        let detector = try #require(SupportedURLDetector())

        let detectedText = detector.matches(in: body).map {
            (body as NSString).substring(with: $0.range)
        }

        #expect(detectedText == [
            "https://example.com/path",
            "http://example.org",
            "mailto:hello@example.com",
        ])
    }
}
