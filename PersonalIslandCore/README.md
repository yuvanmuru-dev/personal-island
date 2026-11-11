# PersonalIslandCore

First implementation milestone: a native Swift 6.1 library for the shared shelf,
ownership, and temporary export lifetime. It has no package dependencies, app
entry point, UI, network client, clipboard observer, screen capture, account
access, or permission prompts. macOS 15 or later is the package deployment target.
It does not implement the complete island or any of the other accepted utilities.

## Interface

Create one `ShelfStore` actor with an explicit dedicated `exportRoot` URL. The
parent directory must exist. A new root is created privately; an existing root
must have a valid catalog and contain only recognized regular owned files.
Advisory locking refuses a second cooperating owner of the same directory.
Use one shared actor for both display presenters.

- `addScreenshot(encodedPNG:)` holds opaque already encoded bytes in RAM. The
  capture adapter must validate/encode PNG data; this library deliberately does
  not decode images. Default limits are 20 screenshots and 128 MiB of encoded
  screenshot data. Admission failure preserves every existing item.
  Temporary exports have a separate configurable admission budget: 256 files
  and 512 MiB by default. Reaching it rejects a new export; it never evicts an
  active/source-protected export or shortens the grace period. Sweep eligible
  expired exports before retrying. These limits cover cataloged exports, not
  receiving-app caches, explicit saved files, or unrelated files on the Mac.
- `addFileReference(_:)` stores a file URL and optional bookmark. It does not
  open, copy, move, or delete that file. The AppKit adapter will resolve bookmarks
  and handle source access; this core does not claim an attachment is available.
- `snapshot()` returns the in-memory shelf. No shelf item or screenshot payload
  is restored from disk after a restart.
- `beginFileDrag(itemIDs:)` returns original file references and generated PNG
  exports for screenshots. Call it only when an adapter actually needs file
  representations. All selected exports and their catalog are committed before
  the URLs are returned. Repeated drags reuse a screenshot's export.
- `endDrag(_:)` releases an active drag and renews its exports' grace period.
  Use it for canceled drags too. It says nothing about sending/upload completion.
- `remove(_:)` and `clear()` remove shelf entries and release screenshot memory.
  Exported PNGs follow their leases. Imported original files are untouched.
- `sweepExpiredExports()` removes only recognized exports whose source item is
  gone, which have no active drag, and whose latest use was at least 24 hours ago.
  Call periodically and after initialization. The library creates no timer or
  cleanup helper; cleanup cannot run while the app is closed.

Public models are `Sendable`. Synchronous disk I/O runs within the store actor,
not the main actor. The actor serializes all shelf/lease coordination. Its
initialization is synchronous and should be performed off the UI thread when
integrated. File-backed transfer, thumbnails, image/TIFF data representations,
file promises, and two-display UI are future adapters.

## Export ownership and recovery

Exports live only in the supplied root as generated `UUID.png` names. No display
name, imported path, or catalog string is used as a deletion path. The root is
mode 0700; exports and the versioned atomic JSON catalog are mode 0600. File
creation is exclusive. Directory-relative filesystem operations reject symlinks,
hard-linked files, changed roots, and unexpected ownership or permissions.

The catalog contains only a version, store identifier, export/source identifiers,
and timestamps. It contains no screenshot contents, file reference paths,
clipboard content, or original names. A corrupt/missing catalog, an unknown file,
or a suspicious root fails closed: the library refuses the directory or sweep
and preserves its contents for inspection. It never deletes untracked files to
"repair" a manifest. A crash between creating an export and committing metadata
can therefore leave a directory needing inspection, rather than risking data
loss. Do not automatically erase that directory when handling an error.

This protects against accidental corruption, path escape, and unsafe recovery.
It is not authentication against a malicious process running as the same user
and able to alter both the catalog and files. It is not protection against a
privileged attacker or proof that a file's bytes remain unchanged after export.
The advisory lock coordinates cooperating stores; other processes can ignore it.
Atomic catalog replacement is not a complete power-loss transaction guarantee.

The 24-hour grace period is provisional. Arbitrary receiving apps provide no
universal "finished reading/sending" signal; long-lived drafts can outlive it.
Receiving apps also control their own attachment caches. No promise is made
that bytes never touch disk, that another app deletes its copy, or that the
operating system will retain temporary files indefinitely.

## Verification

Tests use synthetic byte payloads, isolated temporary directories, and a fake
clock. They never inspect personal screenshots, clipboard contents, calendars,
credentials, or application data. The cases cover ownership preservation,
capacity rejection, canceled/repeated/overlapping drags, exact grace boundaries,
restart, permissions, malformed catalogs, unknown files, path injection,
symlinked roots/exports, and concurrent ownership.

The verified command uses package-local caches:

```sh
mkdir -p .cache/clang .cache/swift
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFT_MODULECACHE_PATH="$PWD/.cache/swift" \
  swift test --disable-sandbox --scratch-path .build --cache-path .cache/spm \
  --config-path .cache/config --security-path .cache/security \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.cache/swift"
```

This development environment prevents SwiftPM from starting its own nested
process sandbox, so the verified command includes `--disable-sandbox`. It changes
SwiftPM's nested process wrapper; it does not require granting the application
access to personal data. The package has no dependencies or external build tools.

No Discord/Mail/Messages compatibility, capture permission, UI, macOS lock-screen
behavior, or resource measurement has been validated by these tests. Those are
the next integration milestones. Filesystem fault injection, abrupt-process
crash testing, and power-loss testing remain future validation work.
