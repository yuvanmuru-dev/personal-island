# Personal Island — controlled app host

This is the first graphical integration target. It uses an explicit set of app
sources, the local PersonalIslandCore source module, and Apple frameworks. It
does not compile the entire upstream Atoll application or resolve its packages.
All accepted utilities remain in the implementation roadmap; this initial host
does not claim they are connected or working yet. Face unlock is deferred.

The target includes the reviewed Atoll notch shape and adapted presentation
ideas with their attribution. The upstream license and notices are preserved in
Resources. The audit snapshots remain unchanged; they are not build checkouts.

The first Release build and bundle checks pass with Xcode 27.2. See
[VERIFICATION.md](VERIFICATION.md)
for the exact checkpoint and untested behavior. The user subsequently opened the preview and confirmed a visible island; both-screen placement and interactions remain unchecked.

## Menu-bar clearance update

Version 0.1.2 keeps the complete compact and expanded window below the system menu/notch band, so its graphics and mouse target cannot extend into the reserved menu row. The body joins the notch below that row on the MacBook; non-notched displays keep a small gap. Controls no longer include a camera spacer or repeated notch padding. The native tracking and shorter hover waits from 0.1.1 are retained. Quit/reopen the app to retest actual menu-icon visibility and click access.

## Hover update

Version 0.1.1 fixes repeated hover events extending the open/close waits. It uses a stable native tracker, shorter 80ms/120ms waits and 120ms animation; settings and hiding cancel pending hover work. Quit the old running preview and reopen the built app before retesting. Hover defaults off each session, so enable it in Settings. The updated native interaction still needs user confirmation.

## Build

From the workspace root, with a compatible full Xcode selected:

```sh
python3 implementation/build_app.py
```

The generator creates an explicit-source Xcode project with two local targets:
PersonalIsland and a static PersonalIslandCore framework built from the same
three sources used by the standalone core package. There are no remote package
references, custom shell build phases, copied helper executables, updater,
extension hosting, or AI/terminal/password-unlock modules.

The build script uses a workspace-local output directory, builds Release for
Apple silicon, applies an ad-hoc signature with hardened runtime, and records
bundle/signature/link inspection. It does not launch or install the app. This
signing configuration is for personal local use, not notarized distribution.

Open PersonalIsland.xcodeproj in Xcode to inspect the source and targets.
Choosing Run in Xcode or opening the built app is a separate first launch;
runtime layout and behavior must be verified rather than inferred from a build.

## Initial behavior and remaining integration

The host provides a menu-bar entry, settings, Quit, a shared coordinator and
separate display presenters. Shelf storage is initialized lazily in the app's
owned temporary area. No screen/clipboard/calendar/media capture or collector
starts automatically. Online features and login startup are not connected.

Native screenshot capture and actual attachment dragging are the next stage.
Spotify, Calendar and all selected utilities follow the milestones in
BUILD_IMPLEMENTATION_PLAN.md. A successful host build does not complete those
features, prove runtime privacy, or validate lock-screen/private integrations.
