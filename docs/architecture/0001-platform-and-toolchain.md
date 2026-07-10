# ADR 0001: Platform and toolchain

- Status: accepted
- Minimum deployment: macOS 15.0
- Development toolchain: Xcode 26.6, Swift 6.3
- UI: SwiftUI, with narrowly scoped AppKit bridges

macOS 15 retains a broad install base while allowing Observation and current
SwiftUI window APIs. Standard controls adopt the current system appearance,
including Liquid Glass on systems that provide it; nvnv does not emulate glass
with custom blur layers on older systems.
