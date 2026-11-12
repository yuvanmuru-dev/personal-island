# Source review for the personal Mac island

Reviewed November 10, 2026. **Both projects need changes before adoption into the personal build.** The findings include actual file-access and authentication-design problems, local retention surprises, external data flows, and optimization opportunities. They do not establish malicious intent by either author.

## Scope and confidence

| Snapshot | Source included | Review method |
| --- | --- | --- |
| Atoll `b8d86a2d8118d905ffa3e2c912adc736683741bb` | 481 text files; 391 Swift files including tests, 364 in the app directory | Broad searches, then manual tracing of sensitive feature paths and their defaults/callers. |
| DynamicNotch `f8623de5806ec5a22d9845189360bc9f4d92c374` | 557 text files; 466 Swift files including tests, 423 in the app directory | Same approach, including screenshots, tray recovery, media, lock screen, network, and updater. |

This is a substantial static review, not an exhaustive line-by-line verification of all 187,233 Swift lines. Included source text was searched for network calls, credentials, process execution, listeners, permissions, storage/deletion, logging, timers, and updates. High-impact findings were checked against initialization, defaults, and surrounding callers; the two DynamicNotch findings involving password unlock and moved-file deletion received an independent challenge pass.

Neither application, build script, installer, helper, test, or exploit was run. No personal screenshots, clipboard, calendars, account files, passwords, browser databases, or keychain items were accessed. The acquisition downloaded public source archives, extracted selected text only, and did not execute repository content. No source modifications or fixes were made.

**Limits:** runtime traffic, macOS 27 compatibility, effective signed entitlements, distributed binaries, prebuilt framework implementations, and transitive dependency implementations remain unverified. Public advisory checks covered Sparkle and Lottie; this was not a complete dependency vulnerability scan. A clean keyword search is not proof that data cannot leave the Mac.

The acquisition manifests preserve file hashes and skipped-file lists. [Scope receipt](audit/SOURCE_SCOPE.json), [Atoll manifest](audit/sources/atoll-manifest.json), [DynamicNotch manifest](audit/sources/dynamicnotch-manifest.json).

## Important findings

### 1. High: Atoll's local extension API can authorize its own file access

The WebSocket connection accepts a caller-supplied application identifier. Its authorization method automatically approves an unapproved caller, including an identity that was denied or revoked. File-sharing scopes and extensions default on, and the server starts at launch. An approved caller can list shelf contents and request file bytes; it can first add another app-accessible path to the shelf. The resulting exposure extends beyond files the user deliberately put there.

This listener is explicitly restricted to the Mac's loopback addresses. **The reviewed version does not expose this RPC port directly to the LAN.** The issue is a missing local-client trust boundary, including potential abuse of permissions held by the host app. Reads remain subject to macOS filesystem and privacy protections. Browser-origin reachability was not tested.

Fix: remove this unrequested extension interface from the personal build, or require authenticated clients, explicit narrowly scoped approval, preserved denials, item-specific grants, and byte/message limits. Do not accept arbitrary local paths from an extension.

Evidence: [automatic approval, lines 139–158](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/services/Extensions/ExtensionRPCService.swift#L139-L158), [file access, lines 382–456](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/services/Extensions/ExtensionRPCService.swift#L382-L456), [loopback restriction](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/services/Extensions/ExtensionRPCServer.swift#L85-L115).

The same RPC upload path appends an unchecked caller-provided filename to its temporary directory and writes it. Parent path components can escape that directory; repeated names can overwrite files. Fix this separately with generated unique names, strict containment and symlink checks, non-overwriting creation, and size limits. [Upload destination, lines 564–587](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/services/Extensions/ExtensionRPCService.swift#L564-L587).

### 2. High, after setup: DynamicNotch's camera unlock does not verify an enrolled identity

An extra feature named Face ID requests and stores the actual Mac login password. Its scan checks face position, size, eyes, and gaze, but does not compare an enrolled identity. A successful scan retrieves the password and types it using global keyboard events. The ordinary missing-camera branch can also report simulated success.

**Conditions:** enrollment defaults false, a saved password is necessary, and the lock-screen triggers are gated. Denying camera permission fails the scan; it does not trigger simulated success. This review did not demonstrate actual macOS unlocking, a FileVault bypass, or password transmission over the network. The source does show an inappropriate authentication design and possible password leakage into an unintended keyboard target.

Fix: remove the inherited password-enrollment/typing bridge. Follow-up on November 11: the user expressed interest in genuine face-only unlock, then asked to defer it until later. Exclude the inherited unlock feature from the current build and retain the research for a future revisit. This audit finding still applies to the reviewed implementation; it does not establish that every possible replacement is impossible. [Deferred feasibility note](FACE_UNLOCK_FEASIBILITY.md).

Evidence: [face checks, lines 271–298](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/FaceID/Services/FaceIDService.swift#L271-L298), [password typing, lines 216–257](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/FaceID/Services/FaceIDService.swift#L216-L257), [enrollment defaults](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/FaceID/Services/FaceIDSettingsStore.swift#L11-L35), [password verification/storage](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/FaceID/Services/FaceIDKeychainService.swift#L14-L63).

### 3. Known vulnerable dependency versions: both snapshots pin older Sparkle updaters

Atoll's resolved package list pins Sparkle 2.7.0; DynamicNotch pins 2.9.4. Published advisory GHSA-3x7w-j75x-ppq5 covers versions through 2.9.5 and identifies 2.9.6 as patched. The flaw involves a local, high-complexity path/symlink race in a privileged installation. A separate advisory covers root-run cache cleanup in versions 2.2.0–2.9.5. These conditions matter: an affected version is not proof that these apps are currently running a vulnerable privileged update on this Mac.

For a personally maintained build, remove the upstream updater and use reviewed local rebuilds. If an updater is retained, update to a currently patched release, review its configuration, and use your own update authority. Both apps contain upstream HTTPS feed URLs and signature keys; retaining those keeps upstream involved in future executable updates. Signature verification is a useful control, but does not establish that an update preserves your local changes or matches audited source.

Evidence: [Atoll package pin](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved), [DynamicNotch package pin](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved), [Sparkle path-race advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5), [root-run cleanup advisory](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp), [2.9.6 fixes](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6).

### 4. High conditional data-loss risk: DynamicNotch's tray recovery can delete moved originals

The default import mode copies, which preserves originals. In optional Move mode, files move into the app's tray directory before the full import is recorded. A partial import failure, crash, or lost/corrupt manifest can leave originals untracked. On next initialization the app permanently deletes untracked tray files. Normal removal uses Trash for known moved items, but this recovery path does not have that protection.

Fix: preserve originals through references or owned copies. Use transactional ownership records and quarantine unknown files rather than deleting them. Our temporary screenshot cleanup must only delete demonstrably app-created exports.

Evidence: [move-before-registration](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/DragAndDrop/Tray/ViewModels/FileTrayViewModel.swift#L176-L184), [import moves](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/DragAndDrop/Tray/ViewModels/FileTrayViewModel.swift#L396-L413), [orphan deletion](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/DragAndDrop/Tray/ViewModels/FileTrayViewModel.swift#L324-L365).

### 5. Atoll's LocalSend integration weakens transfer security

This optional LAN-sharing component accepts any TLS server trust in its custom delegate and can retry an HTTPS peer over unencrypted HTTP following certain connection/TLS failures. File metadata and content follow this transport. Its destination selection can also fall back to the first discovered device when the chosen device disappears. Opening the sharing view starts LAN discovery even when another provider is selected; discovery advertises host/device information and has no corresponding stop method in this class.

This finding concerns Atoll's integration, not every implementation of the LocalSend protocol. No interception was attempted. AirDrop is a separate route and remains in the requested feature set.

Fix: omit unused LocalSend integration, or implement explicit peer selection and authenticated pairing, enforce encryption without silent downgrade, and stop discovery when unused.

Evidence: [TLS acceptance](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/components/Shelf/Services/LocalSendService.swift#L1053-L1064), [scheme fallback](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/components/Shelf/Services/LocalSendService.swift#L1024-L1044), [peer fallback](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/components/Shelf/Services/LocalSendService.swift#L501-L516).

### 6. Clipboard and screenshot retention differ from your requested behavior

Atoll enables clipboard history and its persistence by default. Once monitoring starts, copied text, URLs, paths, and images can enter persistent history. Text metadata uses ordinary preferences; persistent images use Documents/ClipboardData. The collection path does not visibly exclude concealed/transient pasteboard types or selected source apps. There is count-based eviction but no age-based expiry in the reviewed path. This is local retention; no clipboard-upload mechanism was identified in those paths.

The current commit does have a useful session-only option that purges unpinned history, and it keeps new session-only images in memory. Pinned items deliberately persist. However, session-only image dragging falls back to preview text because its drag provider expects a disk filename.

Atoll's assistant also keeps generated screenshots in Documents/ScreenAssistantScreenshots; clearing attachments deletes audio backing files but leaves these screenshots. DynamicNotch changes system screenshot settings, saves ordinary dismissals, and deletes some drag sources shortly after drag start. Neither lifecycle should be reused unchanged for the temporary shared tray.

Fix: keep requested clipboard history with clear pause/exclusion/expiry controls and a session-only default. Preserve screenshots in a separate owned temporary store, support image data/file promises plus leased exports, and make permanent Save explicit. Keep a visible distinction between removing a shelf reference and deleting an owned temporary image.

Evidence: [clipboard defaults](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/models/Constants.swift#L1358-L1366), [capture](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/ClipboardManager.swift#L576-L674), [assistant cleanup](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/ScreenAssistantManager.swift#L256-L278), [DynamicNotch screenshot lifetime](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/ScreenshotHub/ViewModels/ScreenshotViewModel.swift#L221-L267).

### 7. Atoll stores some secrets in preferences and logs sensitive content

Cloud assistant keys and Spotify Canvas web-player credentials use ordinary preferences. This differs from the Spotify library OAuth flow, which uses Keychain and PKCE. Assistant code also prints full prompts, file URLs, and partial responses through direct print calls. A central log-level setting does not suppress those calls. Whether stdout is retained depends on launch and collection behavior; this review did not prove every print becomes a persistent system log.

Fix: use Keychain for necessary secrets, eliminate content-bearing logs, redact diagnostic exports, and avoid the web-cookie Canvas path unless deliberately configured. The accepted feature list does not require an AI assistant or other apps' AI-usage credential integrations, so omit those from the personal fork.

Evidence: [assistant key preferences](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/models/Constants.swift#L1368-L1378), [Canvas credentials](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/SpotifyAuthManager.swift#L96-L118), [prompt logging](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/ScreenAssistantManager.swift#L365-L375), [Keychain-backed Spotify OAuth](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/Spotify/SpotifyTokenStore.swift#L36-L72).

## Are the authors getting your data?

The reviewed first-party source did **not identify an author-operated analytics or automatic crash-upload service collecting clipboard, screenshot, or calendar contents**. Keyword searches and declared dependency lists did not identify common analytics SDKs. That is a bounded negative finding, not proof of absence in embedded frameworks, dependencies, release binaries, or all runtime paths. Atoll's crash-report button copies a report to the clipboard on user action in the inspected function; it does not upload it there.

There are multiple external data paths. Providers necessarily see connection metadata such as source IP and timing; HTTPS does not hide the request contents from its destination. Provider-side retention policies were not audited.

| Feature | What can leave the Mac | Trigger/control observed |
| --- | --- | --- |
| Weather, Atoll | Coordinates when available to Open-Meteo/AQI and possibly wttr.in; otherwise wttr.in sees the IP-based request. | Weather defaults on and launch schedules refresh. Location permission remains controlled by macOS. |
| Lyrics | Track title/artist; DynamicNotch LRCLIB can also receive album/duration. Atoll may fall back to NetEase. | Atoll lyrics default off. DynamicNotch requests when a lyrics presentation is active; normal dependency injection selects LRCLIB. |
| Artwork/extra music metadata | Image/track identifiers and sometimes title/artist to Spotify, Apple, or image CDNs. | Depends on player, missing metadata, artwork settings, and configured integrations. Basic Spotify controls can stay local. |
| VPN country flag, DynamicNotch | Source IP and request timing to api.country.is, ipapi.co, or ipwho.is. | A new active VPN triggers lookup; no separate request-consent guard was found there. Local VPN status can work without this lookup. |
| Updater | Requests to upstream GitHub feeds and release hosts. | Sparkle configuration and automatic-check settings. Signed updates use upstream keys. |
| Assistant, Atoll | Prompt/context to the configured provider; cloud builders include recent history. Gemini can receive actual attachment contents including screenshots/files. | Explicit Send and configured credentials. Empty cloud keys prevent default cloud requests. Other current provider builders send text/file context, not attachment bytes; the local Ollama builder sends one contextual message. |
| AI usage dashboard, Atoll | Credentials/usage requests to the corresponding account provider; some paths read and refresh another app's credentials. | Dashboard defaults off. This feature was not requested and should be omitted. No unrelated developer-server upload was identified in these paths. |
| LocalSend | Host/device discovery data to the LAN; selected files and metadata to the chosen peer. | Opening share UI starts discovery; sending is an explicit action, with the transport/selection defects above. |
| Your drag into Discord/Mail/Messages | The attachment is handed to the receiving app, which controls upload timing, delivery, and its own retained copies. | Dragging may trigger an upload before the final Send action. Our cleanup does not control destination copies. |

Sources: [weather requests](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/LockScreenWeatherManager.swift#L603-L732), [Atoll lyric lookup](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/MusicManager.swift#L1799-L1915), [DynamicNotch lyric request](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/NowPlaying/Services/Lyrics/Provider/LRCLIBLyricsProvider.swift#L123-L147), [VPN request services](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/Network/VPN/Services/VPNLocationService.swift#L20-L107), [assistant send path](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/ScreenAssistantManager.swift#L365-L425). Exact destinations, payloads, defaults, and credential handling are expanded in the network notes linked below.

## Coverage of all requested feature groups

| Requested group | Source-reviewed privacy/security boundary | Personal-build treatment |
| --- | --- | --- |
| Temporary screenshots and file shelf | Capture, local files, bookmarks, tray manifests, extension access, drag exports, permanent deletion. | Replace lifetime/ownership rules; keep your originals in place. |
| Spotify and broader players | Apple Events, metadata lookups, private media helpers, optional credentials. | Keep local Spotify path and isolate additional adapters. |
| Calendar | Local EventKit access; Atoll also modifies reminder completion, beyond merely displaying events. | Display-only agenda; selected calendars; accurate full-access permission explanation. |
| Battery/charging | Local power/device information in inspected collectors. | Keep; no remote upload was identified in the traced status path. |
| Bluetooth/Wi-Fi/VPN/hotspot | Local device/network names and status; VPN country lookup is an external addition. | Keep local indicators; make online country lookup independently configurable. |
| Downloads/AirDrop | Local observation and explicit system sharing; auxiliary LocalSend has separate risks. | Keep activity display; constrain observation and require deliberate sharing. |
| Timers | Local countdowns and system Clock/log bridges. | Keep; separate app-owned timers from system observation and suspend unused work. |
| Lock-screen widgets and deferred face unlock | Intentional display of media/event/reminder details while locked; unsafe inherited password-unlock bridge. | Keep widgets with per-widget privacy settings. Face unlock is deferred; exclude the inherited unlock implementation from the current build. |
| CPU/GPU/RAM/network/disk | Local hardware, interface, and process information; private counters may vary by Mac. | Keep; collect visible/requested metrics at bounded rates. |
| Clipboard history | Sensitive local collection/persistence and drag export. | Keep with session retention, exclusions, byte bounds, pause/clear, and safe image export. |
| Visualizer and lyrics | Atoll real audio-tap option; DynamicNotch decorative equalizer; lyrics need external queries. | Keep lightweight and actual-audio modes distinct; explain permissions and online lookup. |
| Color picker, Focus, recording status | Local sampling/status and private/log-based detection; some stop-recording actions signal all matching system capture processes. | Keep indicators; make broader control actions explicit and targeted. |

No upload was identified in the traced calendar, battery, basic statistics, color-picker, or camera/microphone-status indicator paths. This is narrower than claiming those entire applications never communicate. Default camera/mic indicators read device-running status; they are not evidence of recording those streams. Camera preview, audio capture, voice attachments, and the separate camera-unlock feature are different paths.

Both apps disable App Sandbox while enabling hardened runtime. Atoll also disables library validation in its entitlements and globally relaxes App Transport Security in Info.plist. Those settings are hardening concerns, not proof of malware. TCC permissions still apply. Focus detection in some modes checks Full Disk Access; do not grant broad access without deciding whether that particular integration is worth it. Embedded MediaRemoteAdapter frameworks were not analyzed internally, so compiling the main app alone would not establish end-to-end source control.

## Concrete optimization opportunities

No CPU, battery, memory, or network reduction has been measured. These are source-backed changes to test, while retaining the full requested feature set.

1. **Replace screenshot directory polling.** DynamicNotch scans every 0.25 seconds. A dedicated capture callback removes this steady four-times-per-second scan and avoids global screenshot-preference changes. [Polling source](https://github.com/jackson-storm/DynamicNotch/blob/f8623de5806ec5a22d9845189360bc9f4d92c374/DynamicNotch/Features/ScreenshotHub/Services/ScreenshotMonitorService.swift#L29-L67).
2. **Share collectors across the two displays.** One model for media, weather, statistics, calendar, and shelf; two presenters. Do not create a second sampler or lookup merely to draw the Dell capsule. This is an architecture requirement, not a claim that the current apps always duplicate collectors.
3. **Preserve useful lifecycle gating.** Atoll already stops statistics after the stats view closes and clamps sampling to 1–60 seconds. DynamicNotch has visibility-gated equalizer animation and activity/detail-gated polling. Keep those mechanisms; extend them to disabled modules and hidden windows rather than treating every timer as waste. [Stats lifecycle](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/StatsManager.swift#L514-L657).
4. **Coalesce weather/network requests.** Atoll schedules forced weather refresh from both initialization and startup without an in-flight guard. Use a shared in-flight task, caching, backoff, and cancellation. Keep lyrics/artwork caches bounded and avoid duplicate Spotify metadata downloads. [Weather initialization](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/managers/LockScreenWeatherManager.swift#L36-L42), [startup refresh](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/DynamicIslandApp.swift#L1103-L1108).
5. **Bound bytes and stream large files.** Clipboard history needs total/per-item byte budgets and cached thumbnail/hash data. Atoll LocalSend materializes all selected files as Data before sequential uploads; file-backed streaming avoids memory use proportional to the entire batch. [Transfer file loading](https://github.com/Ebullioscopic/Atoll/blob/b8d86a2d8118d905ffa3e2c912adc736683741bb/DynamicIsland/components/Shelf/Services/LocalSendService.swift#L829-L865).
6. **Stop unneeded discovery and fallback polling.** Prefer existing notifications, add a stop lifecycle for LocalSend, and gate shell/log fallbacks. Atoll's brightness fallback runs at 0.15-second intervals and Bluetooth fallback at 3 seconds. Adjust according to active interaction, visibility, and power mode after measurement. Avoid rerunning expensive hardware/process metadata queries for a hidden panel.
7. **Refresh calendar at meaningful times.** Use event-store changes and the next event boundary, selected calendars, and a bounded lookahead. Avoid broad yearly fetches and refreshing disabled lock-screen widgets every minute. Retain existing refresh throttling.
8. **Bound animation work.** The Dell's 120 Hz display should not force continuous 120 fps work for every module. Run real audio analysis only when its visualization is enabled/visible; use reduced motion and pause layer/Lottie animations when hidden. Package default animations locally rather than repeatedly loading mutable remote URLs.

## Recommended implementation gates

1. Keep the accepted utilities in the product scope (narrowed by the owner on November 12; see PLAN.md). Choose one main source base after a build/dependency audit; Atoll remains the breadth candidate, with DynamicNotch components available for display behavior and missing features.
2. Before personal use, fix/remove the extension file interface, remove the inherited camera/password-unlock bridge, eliminate unsafe orphan deletion, replace screenshot lifetime rules, and remove or patch the updater. Repair necessary secret storage and remove sensitive logs. Face-only unlock is deferred at the user's request and is not part of the current implementation scope.
3. Keep weather, lyrics, artwork, and VPN location lookup separately configurable. Display the destination and data sent. Keep clipboard history and lock-screen details under explicit retention/privacy settings. Omit unrequested AI, terminal, credential-usage dashboards, and third-party extension hosting.
4. Rebuild or separately verify embedded helpers and inspect effective signed permissions. Preserve hardened runtime; avoid global cleartext/TLS exceptions. A source fork is not proof that every included binary was built from reviewed source.
5. Perform controlled runtime validation with synthetic content: traffic with features off and on one at a time; attachment export/expiry; crash/restart recovery; malformed manifests/filenames; denied permissions; and 4K/multi-display idle and active resource measurements. Do not label any of these tests passed yet.

## Detailed evidence notes

- [Atoll local access, retention, permissions, and performance](audit/notes/atoll-local.md)
- [Atoll outbound requests, credentials, and network optimization](audit/notes/atoll-network.md)
- [DynamicNotch security, privacy, and efficiency](audit/notes/dynamicnotch.md)

Dimension assessment: **security requires fixes; privacy requires explicit online/retention controls; correctness requires screenshot and file-recovery changes; performance has concrete optimization candidates pending measurement; maintainability benefits from a pinned dependency inventory and isolated integrations.** Useful existing controls include signed updater configuration, Keychain/PKCE in the Spotify library flow, current memory-only clipboard support, bounded image caching, and multiple lifecycle/cancellation safeguards. Retain those controls while correcting the identified gaps.
