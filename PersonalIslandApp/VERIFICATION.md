# First graphical host verification

Date: November 11, 2026. Result: **Release app built; bundle/signature inspection passed. User subsequently confirmed the island is visible after opening the preview.**

Subsequent user report and three supplied screenshots establish the compact island, expanded empty shelf and Settings window on the MacBook's built-in display. The Dell is not connected and remains untested. Closing, Quit, hover/focus behavior, exact placement and runtime privacy remain unverified. Screenshots remain conversation evidence and were not copied into the repository. The build receipt's `app_launched: false` describes the build script, which does not launch the app; these later user observations are recorded separately here.

This is the M1 integration foundation, not the finished utility. All accepted feature groups remain in the plan; face unlock stays deferred.

## M2 drag-out increment — November 12, 2026

Version 0.3.0 (6) passes 178 automated tests (169 before the local-signing checks were added) and the Release bundle checks; the build emitted no compiler warnings for app sources. New sources: pure `ShelfDragFlow` (unit-tested, 100% line coverage) and the `ShelfDragSource` AppKit adapter (compiled and reviewed, not executed by tests). The drag offers `.copy` only to other applications and carries a `public.file-url` to an app-owned temporary export plus `public.png` data. SwiftUI's `DragSession` type in the macOS 27 SDK collides with the core's type name, so the app qualifies it as `PersonalIslandCore.DragSession`.

Runtime checks for the user: drag one screenshot into a Discord desktop message box, a new Mail message and a Messages conversation without sending; select two or three thumbnails and drag them together; cancel a drag by dropping back on the shelf or pressing Escape, then drag again; confirm the shelf stays open while dragging and closes afterwards when hover-opened. Note which apps attach a file and which insert the image. Do not send messages to people as a test. The user subsequently reported that drag-out works; per-destination details were not itemized.

## M2 region capture increment — November 12, 2026

Version 0.2.0 (5) passes 156 automated tests and the Release bundle checks; the build emitted no compiler warnings for app sources. Five new local sources: pure `CaptureGeometry` and `CaptureFlow` (unit-tested), and the `GlobalHotKey` (Carbon), `RegionSelector` (AppKit overlay) and `ScreenRegionCapture` (ScreenCaptureKit/ImageIO) adapters, which are compiled and source-reviewed but not exercised by automated tests. Linked frameworks remain Apple system frameworks; Release entitlements remain empty and Info.plist still carries no privacy usage-description keys (macOS does not require one for Screen Recording).

Runtime checks for the user: press ⌃⇧4 with another app focused and confirm it keeps focus afterwards; drag a region on each display, including across the display boundary (selection is clamped to the starting display); Escape and a plain click cancel; the islands and overlay are absent from the thumbnail; Copy pastes the full image elsewhere; Remove/Clear update both displays; the first capture shows the Screen Recording request, after which the app must be quit and reopened. The user subsequently reported that capture works on the MacBook; this is a user report without itemized results. Image pixel dimensions at each display's scaling have not been measured, and the Dell remains untested.

## Notch placement update — November 12, 2026

Version 0.1.3 (4) passes 139 automated tests and the Release bundle checks. The 0.1.2 below-menu placement covered application content, so it was replaced. The compact notched window is now the camera-housing rectangle (public `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` and `safeAreaInsets.top`), flush with the top edge, with no visible content. Non-notched displays use a pill inset inside the menu-bar center. Only the user-opened expanded shelf crosses the menu row. Housing widths above 320pt or malformed metadata fall back to 180pt; housing height is bounded to 64pt.

The panel level is `mainMenu + 3`, so an open shelf draws over status items while opened menus still appear above it. `ignoresMouseEvents` is explicitly false so the transparent notch target receives events. After quitting/reopening 0.1.3, the user reported that it works on the MacBook built-in display. This is a user report, not an instrumented measurement. The Dell pill remains untested because the Dell is unavailable.

## Menu-bar clearance update — November 12, 2026 (superseded by 0.1.3)

Version 0.1.2 (3) passes 143 automated tests and the Release bundle checks. Both complete window states now stay below the protected menu/notch band; moving only content would leave an invisible click-interception rectangle. The band is the maximum of the screen safe-area top, the current visible-frame top inset and the public status-bar thickness, clamped to the screen. The latter remains reserved for auto-hidden menus. [Apple visible-frame documentation](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe), [Apple status-bar thickness](https://developer.apple.com/documentation/appkit/nsstatusbar/thickness).

The MacBook software body starts flush beneath that band and no longer places tray/count controls alongside the camera inside the menu row. Non-notched displays retain a small gap below it. An infeasible layout hides instead of crossing the band. Ten additional tests establish these geometry invariants, including invalid inputs and display translations. No menu-item or Accessibility inspection is performed. The global status-bar thickness is a conservative fallback, not a measurement of every menu item on each display.

Actual visual placement and menu-icon click access await user retesting after quitting/reopening the app. The built-in display report and supplied screenshot identified the previous overlap; the screenshot was not copied into the repository. Hover input/delays are unchanged, but the hover target is now the visible body below the menu row.

## Hover update — November 12, 2026

Version 0.1.1 (2) builds and passes all 133 automated tests and bundle checks. Hover uses one stable native tracking area, with 80ms entry and 120ms exit waits and 120ms content animation. Duplicate inputs cannot restart a deadline, and settings/hide/close cancel pending hover work. These are configured delays, not measured end-to-end latency. Native tracking is active for the panel while other apps have focus, using [Apple tracking-area options](https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct). Actual event delivery and perceived response await user retesting.

Quit the existing preview from its menu-bar icon, reopen the built app, enable Expand on hover, and move the pointer onto and away from the compact island. Also repeat with another app focused, and with quick leave/re-entry. A manually opened shelf retains click-to-close behavior. No automatic app launch or relaunch was performed by verification.

## Build evidence

| Item | Observed result |
| --- | --- |
| Selected tools | Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS SDK 27.2 |
| Configuration | Release, arm64, minimum macOS 15.2 |
| App identity | `dev.personal.PersonalIsland`, version 0.12.0 (17); initial preview was 0.1.0 (1) |
| App sources | Twenty-one explicit local Swift files plus three local core sources in a statically linked framework target; presentation state extracted for direct tests |
| External package resolution | None; no package references, dependency plugins or upstream build scripts in this host |
| Build result | `BUILD SUCCEEDED`, command exit 0 |
| Signature | Local builds: valid signature from the user's self-signed "Personal Island Local Signing" certificate (designated requirement: bundle identifier + certificate leaf), hardened runtime present. Without that identity (CI): valid ad-hoc signature |
| Effective Release entitlements | Exactly `com.apple.security.automation.apple-events: true` (Spotify control) and `com.apple.security.personal-information.calendars: true` (reading events), both required under the hardened runtime; no debugging entitlement or disabled library validation |
| Linked libraries | Apple system frameworks/libraries only |
| Runtime search paths | `/usr/lib/swift`, `@executable_path/../Frameworks` |
| Bundle inventory | Eight files: main executable, Info.plist, PkgInfo, four unchanged Atoll notices, signature resource seal |
| Helpers/nested code/symlinks | None in the inspected app bundle |

Build command from the workspace root:

```sh
python3 implementation/build_app.py
```

The script regenerates the explicit-source project, builds into the workspace, verifies the signature, checks effective entitlements and library paths, and enforces the bundle file allowlist. It records actual toolchain output, input hashes, app executable hash and bundle file hashes. A failed rebuild removes the previous success receipt. Input changes during compilation reject a success receipt.

The resulting app is [PersonalIsland.app](../build/XcodeDerivedData/Build/Products/Release/PersonalIsland.app). Full evidence is in [APP_BUILD_RECEIPT.json](../implementation/APP_BUILD_RECEIPT.json); compiler output is in [app-build.log](../build/app-build.log). Source origins and adaptations are recorded in [APP_SOURCE_PROVENANCE.json](../implementation/APP_SOURCE_PROVENANCE.json).

Xcode emitted restricted-environment cache/Simulator diagnostics and a missing-umbrella-header warning for the pure Swift static framework. These did not fail the macOS build or its imports. No Simulator run was needed. The editor-only upstream `#Preview` block was removed because its preview macro process could not run in the restricted build environment; the production notch drawing body still matches the pinned upstream source.

## Reviewed behavior and limits

Static source review confirms startup constructs only the shared coordinator and display presenters. Shelf storage is initialized on demand in the app's private temporary area. No capture, clipboard collector, media/calendar adapter, network client/listener, credential reader, login item or updater is constructed by the current host. This is a source observation, not a runtime traffic measurement.

The code defines menu-bar Settings/Quit, per-display visibility, optional hover expansion and a shared shelf model. Escape handling applies when the island has keyboard focus; hover opening deliberately does not claim global Escape handling. These interactions and screen placement still need a running-app check. Settings are session-only at this stage.

The initial bundle check caught Xcode injecting `get-task-allow` into Release. The generator now disables base-entitlement injection for Release; the final artifact has empty effective entitlements. Debug builds retain normal debugging setup and have not been built or qualified here. The host is not App Sandbox restricted; hardened runtime and an empty entitlement list do not constitute a filesystem or network access boundary.

The storage core now passes 33 synthetic regression tests with the selected tools; its initial 19-test milestone remains recorded in [core verification](../PersonalIslandCore/VERIFICATION.md). Direct geometry/state and build-policy suites are included in the single verification command described in [TESTING.md](../TESTING.md). These are not a graphical-app launch or full runtime qualification.

## Next integration work

- Region capture, shelf admission/removal, Copy and thumbnails are built (0.2.0); the user reported they work on the MacBook. Native dragging with temporary PNG exports is built (0.3.0) and awaits destination checks.
- Export cleanup is scheduled at launch and every 30 minutes (0.2.0). Dragging now creates exports, so this cleanup is active.
- Verify actual MacBook/Dell placement, hot-plugging, Spaces, hover/focus, keyboard access and reduced motion.
- Test synthetic attachments in destination composers, including canceled/repeated drags and delayed drafts. Do not infer send completion from drag completion.
- Add Spotify, Calendar and each remaining accepted utility through independently controlled adapters.

No app launch/install, personal-data permission grant, account access, external messaging or authentication change was performed during this checkpoint.
