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

## Dragging out (0.3.0, readable names in 0.3.1)

Drag a thumbnail into another app to attach it. Click thumbnails to select several, then drag any selected one to take them all. The shelf stays open while you drag, and items stay on the shelf afterwards so you can drag them again. Screenshots become temporary PNG files named like `Screenshot 2026-11-12 at 14.32.05.png` only when dragged; they are cleaned up automatically at least 24 hours after their last use once removed from the shelf.

## Spotify (0.5.0)

Turn on "Spotify in the island" in Settings. The open island gets a Media tab with the current track, a progress bar you can drag to seek, and previous/play-pause/next. macOS asks once whether Personal Island may control Spotify. Everything stays on this Mac; the island never opens Spotify by itself. Settings are now remembered between launches.

## Window and screen capture (0.4.0)

After ⌃⇧4, press Space to switch to window mode: the window under the pointer is highlighted, and a click captures just that window even if others overlap it. Press Space again to go back to dragging a region. Press Return to capture the whole screen the pointer is on. The overlay shows these keys at the bottom.

## Region capture (0.2.0)

Press ⌃⇧4 (or use the menu-bar item or the camera button in the shelf), drag a region, and the screenshot lands in the shelf in memory only. Escape or a plain click cancels. Hover a thumbnail for Copy and Remove; the trash button clears the shelf. The first capture asks for Screen Recording permission; after granting it, quit and reopen the app. The shortcut can be turned off in Settings. Dragging screenshots into other apps comes next.

## Notch placement update

Version 0.1.3 makes the compact island exactly the size of the MacBook camera housing, at the top of the screen. It shows nothing there and never covers menus, menu-bar icons or app content; hover or click it to open the shelf. External displays show a small pill in the middle of the menu bar. The open shelf may cover the menu bar until it closes. The user confirmed it works on the MacBook; the external-display pill is still untested.

## Menu-bar clearance update (superseded by 0.1.3)


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
Apple silicon with hardened runtime, and records
bundle/signature/link inspection. It does not launch or install the app. This
signing configuration is for personal local use, not notarized distribution.

Signing: if the login keychain contains exactly one code-signing identity named
"Personal Island Local Signing" (a self-signed certificate made with Keychain
Access → Certificate Assistant → Create a Certificate, Identity Type Self
Signed Root, Certificate Type Code Signing), the build re-signs with it so
macOS keeps privacy permissions such as Screen Recording across rebuilds.
Without it the app is signed ad hoc and permissions must be re-granted after
each rebuild.

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
