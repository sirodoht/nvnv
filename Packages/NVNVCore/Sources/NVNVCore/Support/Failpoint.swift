import Darwin
import Foundation

/// Named durability boundaries used by subprocess crash tests.
public enum Failpoint {
    public static func trigger(_ name: String) {
        guard ProcessInfo.processInfo.environment["NVNV_FAILPOINT"] == name else { return }
        _exit(86)
    }
}
