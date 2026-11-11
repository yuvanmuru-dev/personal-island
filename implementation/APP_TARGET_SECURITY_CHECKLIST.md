# Controlled app target: build and privacy checks

Updated November 11, 2026. This is a checklist for the early **PersonalIslandApp** host, not a completed build or runtime-verification receipt. Atoll remains the first full-app candidate and a source for deliberate ports; DynamicNotch remains a component reference/alternative. All accepted utility groups stay planned. Face unlock is deferred.

The subsequent M1 build and artifact checks are now recorded separately in [PersonalIslandApp/VERIFICATION.md](../PersonalIslandApp/VERIFICATION.md) and [APP_BUILD_RECEIPT.json](APP_BUILD_RECEIPT.json). Unchecked items below remain a reusable preflight checklist; they are not the current artifact's results. First-launch and feature-integration checks remain pending.

The initial host policy is **Apple SDK frameworks plus local PersonalIslandCore, with no external package resolution or upstream executable helpers**. PersonalIslandCore's inspected manifest declares no external dependencies, plugins or binary targets. The app target and its resulting bundle must be checked separately; this document does not assert that either has already passed.

The exact upstream pins, dispositions and review limits are in [UPSTREAM_DEPENDENCY_INVENTORY.json](UPSTREAM_DEPENDENCY_INVENTORY.json). The source findings are in [SECURITY_REVIEW.md](../SECURITY_REVIEW.md).

## Static evidence already inspected

| Item | Observed source fact | Build decision |
| --- | --- | --- |
| Atoll packages | 13 project references, 11 linked app products and 16 resolved pins. Package implementations/manifests remain unreviewed. | No upstream dependency is approved merely because its revision is pinned. |
| Automatic membership | The upstream project synchronizes its DynamicIsland and Contents directories into the target. | Use an explicit host source/resource list; do not include the entire audit tree. |
| NowPlayingTestClient | Explicit CopyFiles phase adds this compiled executable with CodeSignOnCopy. | Omit it; an exception in synchronized membership alone would not remove this explicit copy. |
| MediaRemote adapter | The project copies a framework and Perl loader as resources. | Omit until matching source has been reviewed and rebuilt or replaced. Broader media support remains planned. |
| Sparkle | Package, app startup, settings, plist feed/key and signing/install surfaces are present upstream. | Omit coherently. The signing shell phase exits unless Release + install; its presence is not evidence it ran in Debug. |
| Signing controls | Entitlements disable library validation although the related project build setting says NO. Upstream team/Developer ID settings are present. | Use the personal target's own settings and inspect its actual signed entitlements. |

Evidence: [package products](../audit/sources/atoll/DynamicIsland.xcodeproj/project.pbxproj:380), [project references](../audit/sources/atoll/DynamicIsland.xcodeproj/project.pbxproj:426), [synchronized membership](../audit/sources/atoll/DynamicIsland.xcodeproj/project.pbxproj:130), [helper copy](../audit/sources/atoll/DynamicIsland.xcodeproj/project.pbxproj:70), [framework resources](../audit/sources/atoll/DynamicIsland.xcodeproj/project.pbxproj:468), [signing script](../audit/sources/atoll/DynamicIsland.xcodeproj/project.pbxproj:485), [entitlements](../audit/sources/atoll/DynamicIsland/DynamicIsland.entitlements:5).

## Before building the controlled host

- [ ] Confirm the actual developer directory, compiler and SDK in the new build receipt. Earlier Command Line Tools receipts are historical; do not label those old values as the current environment.
- [ ] Confirm the host uses only its explicit source files and the local core. No remote package references, binary targets, build plugins, compiler macros supplied by dependencies or upstream signing phases are included.
- [ ] Use a stable personal bundle identifier and local build/signing configuration. Do not overwrite an upstream app or reuse its team identity. Keep hardened runtime; inspect effective signing rather than inferring it from project flags.
- [ ] Use purpose-specific permission descriptions. Do not inherit prompts for AI voice recording, camera mirror, Notes, Reminders or saving screenshots to Desktop/Documents.
- [ ] Leave screenshot/clipboard/calendar/media details hidden while locked, online lookups unconfigured, clipboard monitoring off until enabled, and login startup off. These are activation defaults, not scope removals.
- [ ] Keep logs free of screenshot/clipboard/calendar contents, personal paths and credentials. Display errors without dumping payloads.

## Excluded from this host

Verify absence from source membership, startup calls, resources, package products and the final bundle—not merely a false UI setting:

- [ ] `Contents/Helpers/NowPlayingTestClient`, all bundled `MediaRemoteAdapter.framework` copies and `mediaremote-adapter.pl`.
- [ ] Sparkle/upstream updater: package, custom updater views/delegate, feed/key/downloader/installer plist entries, updater Mach exceptions and Release/install signing script.
- [ ] Atoll extension RPC/XPC hosting, authorization/web-content routes and AtollExtensionKit. No unrequested loopback listener.
- [ ] AI Screen Assistant, cloud AI endpoints, AI account-usage credential readers, TerminalManager/SwiftTerm and related settings/shortcuts.
- [ ] LocalSend discovery/listeners/transfer code. Ordinary attachment dragging and AirDrop remain planned separately.
- [ ] DynamicNotch camera/password unlock. No enrollment, login-password storage or synthetic key-event unlock path.
- [ ] Blanket ATS arbitrary-load exceptions, disabled library validation, unrelated embedded helpers and upstream branding/assets imported without provenance.

## Before adding an upstream package or helper later

The audit snapshots are selected text, not complete build checkouts. Reading a raw manifest is different from evaluating it; a Package.swift can itself execute while the package graph is prepared.

- [ ] Read the raw manifests at the exact approved revisions; inspect the transitive graph before resolution/build.
- [ ] Identify binary targets and artifact URLs/checksums, command/build/prebuild plugins, compiler macro executables, generated-code tools and shell scripts. Current inventory flags mean **unverified**, not absent.
- [ ] For a retained helper, establish matching source and build steps. Re-signing a downloaded binary is not rebuilding its implementation.
- [ ] Keep versions/revisions reproducible; do not silently follow a moving main branch or automatically upgrade during a routine build.
- [ ] Review private API, permission, network and storage implications at the adapter boundary. Add cancellation/stop behavior and failure/unavailable states.
- [ ] Record each port's repository, commit, source path/hash, local destination, modifications and license/notices. Keep Atoll's LICENSE, NOTICE, COPYRIGHT_ASSETS and TRADEMARKS information available; media can have separate terms. Record DynamicNotch notices for its ports. Personal use is the current scope; no publishing/distribution is performed by this checklist.

## Inspect the built bundle before launch

Use inspection tools against the exact built artifact and attach their results to an artifact-specific receipt. These steps are **pending**, not test results:

1. Record the app path, source revision/file manifest, build command/configuration and executable hash.
2. List every file and symlink under the bundle, including Resources, Frameworks, Helpers, PlugIns, XPCServices and login-item locations. Identify executable formats and unexpected nested bundles; do not assume only the main executable can contain code.
3. Inspect the executable's linked libraries and runtime search paths with `otool`; confirm third-party paths/helpers were not inherited. Apple system libraries are expected. This does not detect every dynamically constructed load.
4. Inspect Info.plist with `plutil`: identity, usage descriptions, URL handlers and absence of upstream update/installer keys or blanket ATS relaxation.
5. Inspect and verify signatures with `codesign`, including the actual entitlements and hardened-runtime flags. Confirm no disabled library validation, unrelated Mach services or unintended broad permissions.
6. Inspect project/package/build-phase records for remote references, plugins and scripts. Search source for dynamic loads, processes, network clients/listeners and activation hooks; absence from ordinary linked-library output alone is insufficient.
7. Record pass/fail and unresolved items. An empty checklist or a successful compile is not evidence that these checks passed.

## First-launch and integration verification

- [ ] Use synthetic content for the initial host checks. Confirm it opens settings and quits cleanly, with no automatic capture, clipboard collection, account reads, prompts for omitted features, login item or upstream updater.
- [ ] Inspect process/listener/network activity with online modules disabled. Check each deliberate online integration independently when added; distinguish app traffic from macOS Calendar/account synchronization and other processes.
- [ ] Verify feature disable stops timers, requests, observers, log streams, subprocesses and audio taps. Two display presenters must share collectors and one shelf.
- [ ] Test permission denial/revocation and unavailable private integrations. Do not substitute invented zero values or simulated success.
- [ ] Run real screenshot/attachment checks later with synthetic images. Destination apps control staging/upload timing and their copies; no messages to people are sent as tests.
- [ ] Keep all accepted feature rows in the status matrix. A controlled host preview does not establish lock-screen, broader media, transfer, statistics or other unfinished support.

## Receipt boundary

This preflight inspected local source/configuration text only. It did not fetch or execute upstream packages, inspect an actual finished host bundle, launch an app, grant permissions or certify runtime privacy. Build and inspection results belong in a separate receipt tied to the produced artifact; update status only from observed evidence.
