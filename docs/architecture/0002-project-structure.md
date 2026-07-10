# ADR 0002: Project structure

- Status: accepted
- Build system: Swift Package Manager
- `NVNVCore`: domain, storage, indexing, recovery, and reconciliation
- `NVNVApp`: SwiftUI application and platform adapters
- `NVNVProbes`: executable platform feasibility checks
- `NVNVCoreTests`: Swift Testing unit and real-filesystem integration tests

SwiftPM keeps the file-authoritative core directly testable. The GUI is staged
as a proper application bundle by `script/build_and_run.sh`.
