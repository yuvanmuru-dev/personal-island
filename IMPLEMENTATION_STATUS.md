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
| Private repository and automated checks | Local verification passed; automatic checks configured | Private yuvanmuru-dev/personal-island repository. 139 automated tests pass locally: 33 storage, 43 presentation and 63 build-policy/verifier tests, followed by the actual Release build and bundle policy. GitHub checks run the same command on main/PR changes; current cloud results are linked in TESTING.md. |
| Face unlock | Deferred | No active research or implementation. |

Current tools: `/Applications/Xcode.app/Contents/Developer`, Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS SDK 27.2. First-launch tool setup check passed. Earlier Command Line Tools/SDK 15.5 values in the initial core receipt are historical.

The user opened the built preview, then confirmed the empty shelf and supplied three screenshots showing the compact island, expanded shelf and Settings on the MacBook's built-in display. The Dell is currently unavailable, so its check remains pending. This establishes those visible interface states, not complete placement/focus/closing validation or runtime privacy. The screenshots were inspected in the conversation and were not copied into the repository. No screenshot capture, clipboard collector, media controller, calendar reader, login item, network feature or authentication modification has been activated by this work. M0 tests use synthetic temporary fixtures only.

The built host has a menu-bar entry, Settings/Quit, two-display presentation code and one shared shelf coordinator. This is an integration foundation: capture, native attachment dragging, Spotify/Calendar and the remaining utilities are not connected. Precise display placement and interactions have not been verified in the running app. Temporary export cleanup scheduling must also be connected in M2; the current host only initializes storage on first shelf opening and cannot create exports through its UI.

[App build and bundle inspection](PersonalIslandApp/VERIFICATION.md), [exact artifact receipt](implementation/APP_BUILD_RECEIPT.json), [source provenance](implementation/APP_SOURCE_PROVENANCE.json).

## Notch placement update — November 12

Version 0.1.3 (4) replaces the 0.1.2 below-menu-bar placement, which put the island over application content (user report and screenshot). It rebuilds and passes all 139 automated tests plus Release bundle/signature checks. On a notched display the compact window is now exactly the camera-housing rectangle from the public auxiliary-area and safe-area metadata, flush with the top edge. macOS places no menus or status items there, so the compact island cannot cover menu-bar icons or apps. It draws nothing visible and serves only as the hover/click target. The 0.1.0 overlap came from 36pt wings on each side of the housing; there are none now. Non-notched displays get an 84pt pill inset inside the center of the menu bar. The expanded shelf grows down from the top and may cover the menu row only while open; it closes on pointer exit (hover-opened) or by click/close button/Escape. The panel level is above status items, it explicitly receives mouse events over its transparent notch target, and pointer reconciliation includes the top display edge.

Geometry tests were replaced: the compact window equals the housing and does not intersect either menu region; expansion keeps the top anchor and contains the compact window; the pill stays within the menu row; metadata fallbacks and invalid frames stay bounded. After quitting/reopening 0.1.3, the user reported that it works on the MacBook built-in display. This is a user report covering the notch placement and interaction, not an instrumented measurement. Dell pill placement remains untested because the Dell is unavailable.

## Menu-bar clearance update — November 12 (superseded by 0.1.3)

Version 0.1.2 (3) rebuilds and passes all 143 automated tests plus Release bundle/signature checks. The user reported menu/Control Center items being covered by the compact island. Both compact and expanded interactive window rectangles now sit below the entire protected menu/notch band. The band conservatively uses the largest public safe-area inset, visible-frame top inset and status-bar thickness; it remains reserved when menus auto-hide. The MacBook body touches the bottom of that band, while a non-notched display keeps a small floating gap.

Compact controls no longer reserve a camera gap inside their body, and expanded content no longer repeats the notch padding. Public geometry is refreshed on show/update/expansion; unusable layouts hide before enabling tracking. Ten new regressions cover both states, auto-hide, menu-height precedence, logical display sizes, Docks and invalid/consumed geometry. Hover timing and original-file handling are unchanged. No menu-item inspection, Accessibility permission, private API or new network behavior was added. Actual icon visibility/click access and the new hover target below the menu row await user confirmation after quitting/reopening. The screenshot remains conversation evidence and is not in Git.

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
