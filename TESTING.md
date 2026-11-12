# Tests and build checks

Run the complete automated checks from the repository root on a Mac with full Xcode selected:

```sh
python3 implementation/verify.py
```

This runs the Python build-policy tests, storage tests, presentation tests with measured source coverage, and a Release app build followed by bundle/signature inspection. It does not open the graphical app or access screenshots, the clipboard, Spotify, Calendar or credentials. Tests create only synthetic data in their own temporary directories.

Detailed output stays in ignored `build/verification/` logs. Machine-specific results are written to ignored `implementation/TEST_RUN_RECEIPT.json` and `implementation/APP_BUILD_RECEIPT.json`. A failed run records failure rather than presenting an old success as current. The verified test counts and coverage are recorded there; coverage includes the tested production files only, not the generated Swift test runner.

## Automated coverage

| Area | What the tests establish |
| --- | --- |
| Screenshot ownership | Image bytes stay in memory until a file drag requests an export. Bounded admission rejects additional screenshots without evicting existing ones. |
| Original files | References remain untouched through removal, clearing, restart and export cleanup. Symlinks, hardlinks and unexpected directory contents do not become deletion targets. |
| Exports and leases | Canceled, repeated and overlapping drags retain their exports. Source presence and active drags protect files; the last use renews the grace period. |
| Transaction boundaries | A failed multi-item export does not publish partial drag results, consume a lease or delete existing exports. Count and byte budgets are enforced separately. |
| Concurrent requests | Actor serialization preserves quotas and shared exports when multiple capture/drag requests arrive together. |
| Recovery | Missing/corrupt/oversized/inconsistent metadata fails closed. Missing temporary exports can be recreated; binary contents remain intact across restart. |
| Display layout | Attached notch versus floating capsule, negative screen origins, scaled layouts and small display areas obey tested containment/menu-bar rules. |
| Interaction state | Click toggles, hover open/close, canceled delayed work and stale callbacks obey deterministic tests without wall-clock sleeps or taking over the desktop. |
| Release policy | Invalid signatures, debugging permissions, unexpected entitlements, third-party libraries, unsafe search paths, helpers, symlinks and unexpected bundle files are rejected. |
| Project generation | Generated membership stays explicit, uses only local app/core sources, includes retained notices, and excludes remote packages, helper-copy phases and custom build scripts. Release and Debug signing remain distinct. |

The presentation package compiles the same geometry/state sources used by the app. It creates no NSApplication, windows or display observers. Tests exercise the production policy validators used by the actual bundle checker; mocked inspection text is used only for rejection cases. The final Release build separately checks real compiler/signing output and the actual app contents.

Swift Testing parameterized cases may produce more scenario inputs than top-level test functions. Reported counts use the runner's own summary; they are not inflated by counting each assertion.

## Latest local results

November 12, 2026, Xcode 27.2 / Swift 6.4.2: **178 tests passed, zero failed** (33 storage, 73 presentation, 72 Python policy/verifier), followed by a passing Release build and bundle/signature inspection. Verifier tests additionally cover rejecting stale/ambiguous coverage, source/test drift, and misleading success receipts.

Measured production line coverage from that run:

| File | Covered lines |
| --- | --- |
| Models.swift | 66/68 (97.1%) |
| OwnedExportDirectory.swift | 196/208 (94.2%) |
| ShelfStore.swift | 159/159 (100%) |
| IslandGeometry.swift | 102/102 (100%) |
| IslandPresentation.swift | 153/153 (100%) |
| CaptureGeometry.swift | 31/31 (100%) |
| CaptureFlow.swift | 30/31 (96.8%) |
| ShelfDragFlow.swift | 46/46 (100%) |

These are line measurements for the tested core/presentation sources, not a claim that every branch, UI interaction or planned integration is tested. The new layout tests caught and fixed a tiny-display menu-bar overlap. Deterministic hover race tests are complemented by one bounded production-timer smoke test that awaits actual open/close callbacks without elapsed-time assertions.

Ten hover regressions additionally verify that repeated entry/exit callbacks preserve the original deadline, preference changes take effect while stationary, manual opening is retained, and suspended/hidden presenters cannot be reopened or closed by stale work. Native AppKit event delivery is compiled and reviewed but remains a manual running-app check.

Nine local-signing regressions cover selecting the "Personal Island Local Signing" identity (exact name only, untrusted or twice-listed identities accepted, two same-named identities rejected), the signature policy for either mode (an identity-signed build cannot pass as ad hoc, and vice versa; no extra authority, ad-hoc flag or team), and the re-signing step (ad hoc kept without an identity; hardened runtime and no entitlements with one; listing/signing failures stop the build). Subprocesses are mocked; no keychain is read.

Version 0.3.0 adds 13 drag regressions. Seven test the drag lifecycle with a fake platform: a dropped drag ends its core session exactly once and releases the shelf; a drag that cannot start, or whose mouse is released during export preparation, still ends its prepared session without starting; concurrent requests are ignored without preparing exports; empty requests do nothing; preparation failure reports and needs no end; an end failure is reported and the flow recovers. Six test holding the shelf open during a drag: pointer exit is deferred and re-evaluated on release, a pointer still inside keeps it open, a pending peek close is cancelled and rescheduled, hover turned off meanwhile closes a hover-opened shelf, a manual opening stays open, and suspension clears the hold. The AppKit drag source is compiled and reviewed but not executed by tests; no drag, pasteboard write or destination app is involved.

Version 0.2.0 adds 17 capture regressions. Seven test region selection (any drag direction, clamping to the starting display, negative-origin displays, whole-point rounding, clicks/tiny/invalid input) and AppKit-to-Core-Graphics conversion for displays left of, below and above the primary. Five test the capture lifecycle with an injected fake platform: success hides and restores islands exactly once and admits once; missing permission requests access without hiding or capturing; cancellation, capture failure and full-shelf failure restore islands; a second request during selection is rejected and cancel ends the first. Five test the post-capture peek: it closes after its duration, never disturbs an open shelf, is held while the pointer is on it regardless of the hover setting, and click/suspend cancel its timer. The ScreenCaptureKit, overlay, hot-key and pasteboard adapters are compiled and reviewed but not executed by tests: the suite never requests Screen Recording, registers a global shortcut or opens windows.

Version 0.1.3 replaced the below-menu-band geometry tests (which encoded a placement that covered app content) with notch-placement tests. The compact notched window must equal the camera housing and not intersect either menu/status region; expansion keeps the top anchor and contains the compact window; the external pill stays within the menu row; invalid housing metadata, implausible safe areas, invalid menu heights and invalid frames stay bounded. The presentation suite therefore went from 47 to 43 test functions. These establish the pure geometry contract; actual hover/click delivery in the housing and visible artifacts still require a running-app check.

## GitHub checks

The private [personal-island repository](https://github.com/yuvanmuru-dev/personal-island) runs the same command on pushes to `main` and pull requests. [Current runs are visible in GitHub Actions](https://github.com/yuvanmuru-dev/personal-island/actions/workflows/verify.yml); a manual run is also available there. The workflow uses a standard Apple silicon `macos-15` runner and selects Xcode 16.4; local checks use the selected Xcode, including this Mac's Xcode 27.2. This checks an older supported toolchain as well as the current local one. Runner labels/toolchains come from [GitHub's maintained image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

The workflow has read-only repository access, does not retain checkout credentials, pins the official checkout action to a commit, cancels superseded runs, and has a ten-minute limit. It does not publish an app, upload artifacts, install a login item or use personal account secrets. Private hosted runs consume the account's Actions allowance; no billing settings or paid runners are enabled here. See [GitHub's billing rules](https://docs.github.com/en/actions/concepts/billing-and-usage).

For policy-only checks without building the app:

```sh
python3 implementation/verify.py --policy-only
```

## Checks still requiring a running app

These automated tests validate the implemented foundation. They do not establish that unfinished features work. Add tests with each integration and retain explicit unavailable states until real behavior is verified.

- First launch, menu-bar Settings/Quit, keyboard focus, VoiceOver, reduced motion and actual animation.
- MacBook/Dell placement, scaling, fullscreen, Spaces, clamshell, hot-plugging and mixed refresh rates.
- Native capture fidelity, permission denial/revocation, safe cleanup scheduling and attachment handling in Discord, Mail and Messages composers.
- Delayed drafts, canceled/repeated/multi-item drags, sleep/wake and process interruption. Drag completion is not proof of sending or uploading.
- Spotify/Calendar and the other accepted utilities, their disable/stop behavior, and any deliberate network destinations.
- Idle CPU, memory, energy, responsiveness and measured runtime network activity.

Face unlock remains deferred. No automated test enrolls a face, stores a login password or changes authentication.
