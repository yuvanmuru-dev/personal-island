# Implementation status

Updated November 12, 2026.

| Milestone | Status | Evidence / remaining work |
| --- | --- | --- |
| Source security review | Static pass completed | Pinned source and findings in SECURITY_REVIEW.md; runtime, binaries and dependency implementations remain unverified. |
| Build/implementation plan | Written | BUILD_IMPLEMENTATION_PLAN.md defines M0–M5 and all accepted features. |
| M0 safe storage/export core | Built with expanded regression tests | Dependency-free library compiled; 33 synthetic tests pass, including concurrent requests, batch rollback and damaged metadata. Native adapters, filesystem fault injection and abrupt-process recovery testing remain. See TESTING.md and PersonalIslandCore/VERIFICATION.md. |
| M1 controlled app source/build | Built; initial MacBook interface confirmed | Release Apple silicon app builds with Xcode 27.2. Explicit app/core sources, no remote packages or helpers, valid ad-hoc signature with hardened runtime and empty Release entitlements. User report/screenshots confirm the compact island, expanded empty shelf and Settings on the built-in display. Dell/shared-display behavior, closing/Quit and broader interactions remain unchecked. See PersonalIslandApp/VERIFICATION.md. |
| M2 two-display screenshot preview | Not started | Requires capture and AppKit drag adapters plus actual destination/display checks. |
| M3 Spotify/Calendar | Not started | No permissions requested or personal accounts accessed. |
| M4 all additional utilities | Planned | Every accepted feature group remains in scope. |
| M5 personal-use qualification | Planned | Runtime privacy, stability, accessibility and resource measurements not performed. |
| Private repository and automated checks | Local verification passed; automatic checks configured | Private yuvanmuru-dev/personal-island repository. 133 automated tests pass locally: 33 storage, 37 presentation and 63 build-policy/verifier tests, followed by the actual Release build and bundle policy. GitHub checks run the same command on main/PR changes; current cloud results are linked in TESTING.md. |
| Face unlock | Deferred | No active research or implementation. |

Current tools: `/Applications/Xcode.app/Contents/Developer`, Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS SDK 27.2. First-launch tool setup check passed. Earlier Command Line Tools/SDK 15.5 values in the initial core receipt are historical.

The user opened the built preview, then confirmed the empty shelf and supplied three screenshots showing the compact island, expanded shelf and Settings on the MacBook's built-in display. The Dell is currently unavailable, so its check remains pending. This establishes those visible interface states, not complete placement/focus/closing validation or runtime privacy. The screenshots were inspected in the conversation and were not copied into the repository. No screenshot capture, clipboard collector, media controller, calendar reader, login item, network feature or authentication modification has been activated by this work. M0 tests use synthetic temporary fixtures only.

The built host has a menu-bar entry, Settings/Quit, two-display presentation code and one shared shelf coordinator. This is an integration foundation: capture, native attachment dragging, Spotify/Calendar and the remaining utilities are not connected. Precise display placement and interactions have not been verified in the running app. Temporary export cleanup scheduling must also be connected in M2; the current host only initializes storage on first shelf opening and cannot create exports through its UI.

[App build and bundle inspection](PersonalIslandApp/VERIFICATION.md), [exact artifact receipt](implementation/APP_BUILD_RECEIPT.json), [source provenance](implementation/APP_SOURCE_PROVENANCE.json).

## Hover response update — November 12

Version 0.1.1 (2) rebuilds and passes all 133 tests plus Release bundle/signature checks. The hover state now ignores duplicate pointer/preference inputs, preserving the original open/close deadline. Entry wait is 80ms (previously 250ms), exit wait 120ms (previously 500ms), and content animation 120ms (previously 180ms). A stable native tracking host replaces the SwiftUI hover callback; pointer position is reconciled after events, showing and resizing. Turning hover off cancels pending work immediately; hiding/closing resets it. Manually opened shelves retain their existing click-to-close behavior.

Ten new regressions cover duplicate entry/exit, setting transitions, canceled stale callbacks and hide/resume. These changes are built and source-reviewed; actual pointer response while another app has focus and the perceived timing still require user confirmation after quitting/reopening the preview. No new permissions, network behavior or integrations were introduced. Dell testing remains pending.

## Expanded automated verification

The initial November 11 expanded run passed 123 tests and the Release build/bundle checks with Xcode 27.2. It tests shared production sources directly, including the real hover scheduler, and records coverage only from the current run. The verifier rejects source/test changes during a run and records input hashes, mode and UTC timestamps. Exact local results remain in ignored implementation/TEST_RUN_RECEIPT.json; see TESTING.md for the coverage scope and manual runtime gaps. No graphical app launch or personal-data access occurred.

## Verified first increment

The new core keeps screenshots in memory, holds imported files as untouched references, creates generated private temporary exports when requested, and preserves exports through canceled/repeated/overlapping drags and restart grace periods. It rejects unknown/unsafe cleanup roots and malformed metadata rather than deleting untracked files. Separate admission limits cover screenshot RAM and retained export files.

The first compilation and final 19-test run succeeded using the selected Swift 6.1.2 tools, with package-local build caches. Independent review identified and corrected descriptor ownership during failed initialization, blocking nonregular catalog reads, and concurrent ownership of the same root. The final narrowed review found no unresolved material issue within the documented threat model.

After Xcode installation, the unchanged core compiled again with Swift 6.4.2 and all 19 tests passed with zero failures. This compatibility run used no GUI, personal accounts or network features.

[Exact verification command, results and remaining limits](PersonalIslandCore/VERIFICATION.md).
