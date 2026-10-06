#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PACKAGE="$ROOT_DIR/.build/model-tests"

# Compile the application models as a library, without the SwiftUI App entry
# point. These tests exercise real folders and writes without opening windows.
python3 - "$ROOT_DIR" "$TEST_PACKAGE" <<'PY'
import sys
from pathlib import Path

root, package = map(Path, sys.argv[1:])
for name in ("App", "Tests"):
    (package / name).mkdir(parents=True, exist_ok=True)
sources = [
    "Stores/AppModel.swift", "Stores/LibrarySession.swift",
    "Stores/LibraryWindowCoordinator.swift", "App/LibraryWindowController.swift",
    "Services/DirectoryWatcher.swift", "Views/PlainTextEditor.swift",
]
tests = ["NamedLibraryTests.swift", "LibraryWindowTests.swift", "AppModelConflictTests.swift"]
for directory, files, source_root in (
    ("App", sources, root / "Sources/NVNVApp"),
    ("Tests", tests, root / "Tests/NVNVAppTests"),
):
    for filename in files:
        link = package / directory / Path(filename).name
        link.unlink(missing_ok=True)
        link.symlink_to(source_root / filename)
(package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NVNVModelTests",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "'''+str(root / "Packages/NVNVCore")+'''")],
    targets: [
        .target(name: "nvnv", dependencies: ["NVNVCore"], path: "App"),
        .testTarget(name: "NVNVModelTests", dependencies: ["nvnv", "NVNVCore"], path: "Tests")
    ]
)
''')
PY

swift test --package-path "$TEST_PACKAGE" "$@"
