import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(text: String, lineEnding: LineEnding = .lf) -> String {
        sha256(Data(lineEnding.encoded(text).utf8))
    }
}
