# ADR 0002: Project structure

- Status: accepted
- Build systems: Xcode for the macOS app; Swift Package Manager for the core,
  probes, and tests
- `NVNVCore`: domain, storage, indexing, recovery, and reconciliation
- `NVNVApp`: SwiftUI application and platform adapters
- `NVNVProbes`: executable platform feasibility checks
- `NVNVCoreTests`: Swift Testing unit and real-filesystem integration tests

SwiftPM keeps the file-authoritative core directly testable under
`Packages/NVNVCore`. The root `nvnv.xcodeproj` compiles `Sources/NVNVApp`,
links that local package's `NVNVCore` product, and owns application bundling,
assets, signing, and deployment settings. `script/build_and_run.sh` builds
that native app target and stages the result in `dist/`.
