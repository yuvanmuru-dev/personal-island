# First graphical host verification

Date: November 11, 2026. Result: **Release app built; bundle/signature inspection passed. App not launched.**

This is the M1 integration foundation, not the finished utility. All accepted feature groups remain in the plan; face unlock stays deferred.

## Build evidence

| Item | Observed result |
| --- | --- |
| Selected tools | Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS SDK 27.2 |
| Configuration | Release, arm64, minimum macOS 15.2 |
| App identity | `dev.personal.PersonalIsland`, version 0.1.0 (1) |
| App sources | Eight explicit local Swift files plus three local core sources in a statically linked framework target; presentation state extracted for direct tests |
| External package resolution | None; no package references, dependency plugins or upstream build scripts in this host |
| Build result | `BUILD SUCCEEDED`, command exit 0 |
| Signature | Valid ad-hoc local signature; hardened runtime present |
| Effective Release entitlements | Empty dictionary; no debugging entitlement or disabled library validation |
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

- Add region capture, image validation, shelf admission/removal and native AppKit attachment dragging.
- Schedule safe export cleanup at launch and periodically before enabling exports. The present UI cannot create exports and does not schedule cleanup.
- Verify actual MacBook/Dell placement, hot-plugging, Spaces, hover/focus, keyboard access and reduced motion.
- Test synthetic attachments in destination composers, including canceled/repeated drags and delayed drafts. Do not infer send completion from drag completion.
- Add Spotify, Calendar and each remaining accepted utility through independently controlled adapters.

No app launch/install, personal-data permission grant, account access, external messaging or authentication change was performed during this checkpoint.
