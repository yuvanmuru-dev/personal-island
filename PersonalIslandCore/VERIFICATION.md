# First core milestone verification

Date: November 11, 2026. Result: **library compiled; 19 tests passed, 0 failed**.
This is a partial implementation milestone, not a completed Mac application.

## Toolchain and command

Toolchain output:

```text
swift-driver version: 1.120.5 Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)
Target: arm64-apple-macosx18.0
```

Working directory:
`PersonalIslandCore` (from the repository root)

```sh
mkdir -p .cache/clang .cache/swift
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFT_MODULECACHE_PATH="$PWD/.cache/swift" \
  swift test --disable-sandbox --scratch-path .build --cache-path .cache/spm \
  --config-path .cache/config --security-path .cache/security \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.cache/swift"
```

Final command exit status: 0. Final output:

```text
Build complete! (1.18s)
Testing Library Version: 124.4
Test run with 19 tests passed after 0.020 seconds.
```

This was an incremental build after an earlier successful compilation. The
first attempt using SwiftPM's default nested process sandbox failed at manifest
startup with `sandbox_apply: Operation not permitted`; the command above avoids
that nested wrapper and keeps caches/configuration in this package. No added
filesystem permission, dependency download, upstream script, app launch, or
personal-data access was needed. Only the newly written library and synthetic
test runner were compiled and executed.

## Exercised cases

- Screenshot payloads stay in memory until a file drag needs an export.
- RAM capacity failure preserves existing screenshots without eviction.
- Export byte and count admission limits reject new exports without deleting
  protected files; expiry can free capacity for a later retry.
- Imported originals survive clear, export expiry, and restart workflows.
- Canceled/repeated drags retain exports and reuse the same representation.
- Overlapping active drags protect a removed source; ending the last drag renews
  the full 24-hour grace interval, including exact expiry boundaries.
- Restart restores export metadata, never screenshot shelf contents.
- Roots/files/catalog use the intended POSIX permissions and generated names.
- Corrupt/missing catalogs, injected catalog paths, unknown files, symlinked
  exports, symlinked roots, and unrecognized roots preserve outside sentinels.
- Invalid drag selections publish no export files.
- Concurrent cooperating owners are refused; failed initialization releases its
  directory lock; FIFO catalog input is rejected without waiting for a writer.

## Implemented default limits

| Resource | Default |
| --- | --- |
| In-memory screenshot count | 20 |
| Encoded screenshot payload bytes | 128 MiB |
| Recognized temporary PNG exports | 256 files |
| Recognized temporary PNG export contents | 512 MiB |
| Catalog input/output | 4 MiB |
| Export grace interval | At least 24 hours after latest recorded use; also protected while its source item or a drag is active |

Payload budgets are not a total process-memory measurement. They exclude future
decoded image/capture buffers, thumbnails, caller-retained snapshots, imported
reference metadata, and receiving-app caches. The export budget covers owned
cataloged PNGs, not every file on the Mac. Unknown files fail closed and need
inspection; they are not deleted to meet a quota.

## Remaining gates

No ScreenCaptureKit capture, clipboard behavior, AppKit drag/file promises,
Discord/Mail/Messages compatibility, display UI, lock-screen behavior, permission
prompt, account integration, or energy/CPU/memory benchmark has been tested.
No filesystem fault-injection, abrupt-process crash, or power-loss test was run.
Catalog replacement is atomic but is not a complete durable transaction proof.
Root verification and generated paths are not authentication against a malicious
same-user process able to alter both files and metadata. Cleanup cannot run while
the app is closed. External drafts may outlive the provisional grace interval.

The rest of the accepted feature set remains in the main implementation plan;
this package establishes its shared shelf/ownership foundation only. Face unlock
remains deferred.

## Xcode 27.2 compatibility recheck

Date: November 11, 2026. Result: **the unchanged library compiled; the same 19
Swift Testing tests passed, 0 failed**. No source compatibility fixes were needed.

Selected toolchain and SDK:

```text
Xcode 27.2
Build version 27B52
macOS SDK: 27.2
swift-driver version: 1.168.6 Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
Target: arm64-apple-macosx27.0.0
```

Ran from this package directory using the same package-local paths:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFT_MODULECACHE_PATH="$PWD/.cache/swift" \
  swift test --disable-sandbox --scratch-path .build --cache-path .cache/spm \
  --config-path .cache/config --security-path .cache/security \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.cache/swift"
```

Command exit status: 0. Final output:

```text
Build complete! (8.29 sec)
Testing Library Version: 2403
Test run with 19 tests in 0 suites passed after 0.019 seconds.
```

The runner also printed an XCTest discovery summary with zero tests; the 19
actual cases use Swift Testing and passed in its subsequent summary above.
Version/SDK lookup emitted restricted-cache/FSEvents diagnostics but successfully
reported the selected toolchain. The test build itself completed without source
errors. This recheck used synthetic temporary fixtures only; it did not launch a
GUI, capture the screen, read accounts, make network requests, or validate any
of the outstanding application/drag/capture integration gates listed above.
