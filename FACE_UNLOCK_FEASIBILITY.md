# Hands-free face unlock — deferred research

Updated November 11, 2026. **Deferred at the user's request: no further face-unlock research or implementation is planned in the current scope.** The remaining notes are preserved for a later revisit.

The desired future behavior is unlocking the Mac from sleep using **face alone**, with no Touch ID gesture or Apple Watch approval. A cosmetic scan animation or unlocking only the island would not satisfy that goal.

No camera capture, enrollment, password collection, login-policy modification, or unlock attempt has been performed. A secure, supported implementation on this Mac has not yet been established.

## What the source review established

DynamicNotch's current face feature can supply camera framing, preview, scan animation, timeout/cancel UI, and presence/attention signals. Its verification path does not compare an enrolled facial identity, its missing-camera path can simulate success, and its unlock bridge types a saved Mac password. Reusing that bridge unchanged would retain the security findings in [SECURITY_REVIEW.md](SECURITY_REVIEW.md).

The recommendation to remove the inherited implementation remains valid. The user expressed interest in the capability and subsequently deferred it; the current island build should exclude the inherited unlock feature while retaining ordinary lock-screen widgets.

## Two independent problems to solve

1. **Face verification:** distinguish the enrolled owner from other people and resist photographs, recorded video, replayed/virtual-camera frames, and enrollment tampering. A face bounding box, open eyes, a head turn, or a successful blink challenge is not sufficient evidence of secure identity authentication.
2. **macOS session unlock:** connect an approved authentication result to the actual system lock screen and preserve the expected keychain/session security behavior. Hiding an overlay or returning success inside our app does not unlock macOS.

The M5 MacBook Pro specification lists a 12MP Center Stage camera and Touch ID. Apple's Face ID uses TrueDepth depth/infrared sensing and Secure Enclave protection. These documents do not establish that our custom camera implementation can provide those hardware-backed properties. Do not describe it as Apple's Face ID or use Apple's false-match claims for it. [Mac hardware](https://support.apple.com/en-za/125405), [Face ID design](https://support.apple.com/en-us/102381).

## System-integration routes

| Route | What is established | Remaining issue |
| --- | --- | --- |
| LocalAuthentication in the island app | Apple documents authentication of operations/resources inside an app using system-supported methods. | Its success result is not a documented way to submit our custom camera match to unlock the macOS session. |
| Authorization plug-in | Apple provides plug-in APIs for custom authorization policy and login/authentication UI. | Suitability for camera-only screen unlock on macOS 27, camera access, keychain/session behavior, privilege boundaries, recovery, and removal all require investigation. A documented plug-in API is not proof this particular authentication design works safely. |
| Platform SSO | Apple documents system login/unlock integration through a compatible identity-provider extension and device-management configuration. | This adds managed-device/identity infrastructure and does not automatically make a webcam match a trusted authenticator. It may be a poor fit for the desired personal, locally controlled utility. |
| Stored-password keyboard injection | DynamicNotch implements this mechanism. | Fixing identity matching alone does not solve password custody, keyboard-target races, or system trust. Do not inherit it as the default solution or assume it is secure because the password is in Keychain. |

Sources: [LocalAuthentication](https://developer.apple.com/documentation/localauthentication), [authorization plug-ins](https://developer.apple.com/documentation/security/authorization-plug-ins), [custom authorization UI](https://developer.apple.com/documentation/securityinterface/sfauthorizationpluginview), [Platform SSO requirements](https://support.apple.com/guide/deployment/platform-sso-for-macos-dep7bbb05313/web).

Apple Developer Technical Support has also described keychain-unlock problems with third-party authorization plug-ins in a reported screen-unlock path. That is a reason to validate keychain behavior, not proof the same bug exists on this specific macOS 27 installation. [Apple DTS discussion](https://developer.apple.com/forums/thread/796487).

**Current conclusion:** a fully hands-free camera-only session unlock remains technically unresolved for this personal app. No safe ordinary menu-bar-app route was identified in this research. System-level extension routes exist, so this is not a claim that every possible implementation is impossible. Do not promise delivery or silently substitute a second-factor/cosmetic experience.

## Investigation sequence for a future revisit

1. **System feasibility first.** Examine the authorization plug-in route and current macOS 27 requirements before designing credential handling. Determine whether session unlock, login/data-protection keychains, screen-sharing/remote sessions, and recovery continue to work without storing and typing the account password. Keep cold boot/FileVault unlock outside the confirmed from-sleep target.
2. **Local recognition prototype.** Build a separate, explicitly activated prototype that performs no OS unlock. Use real identity enrollment/matching, bounded camera use, conservative failure handling, attempt limits, and no simulated-success fallbacks. Enrollment/reset should require the operating system's existing owner authentication; this one-time setup requirement is distinct from the desired hands-free wake flow.
3. **Privacy design.** Keep face processing local. Store the minimum protected enrollment representation, avoid retaining raw frames by default, provide Delete Enrollment, and keep biometric data out of logs, analytics, cloud APIs, clipboard, and the screenshot tray. A custom protected file/Keychain design must not be represented as Apple's Secure Enclave biometric-template storage.
4. **Adversarial and usability checks.** Evaluate impostors with consent, photos/video, lighting, glasses, camera disconnect/denial, multiple faces, virtual sources, sleep/wake races, lockouts, and canceled enrollment. Report observed performance and limitations; a small personal test set cannot establish a population-level false-accept rate.
5. **Isolated system test.** If a plausible supported integration exists, test with synthetic accounts in a disposable environment before any live-Mac authentication-policy changes. Test failures, crash/reboot, keychain access, uninstall/rollback, and manual password recovery. Normal system protections remain in place.

The built-in camera is unavailable with the MacBook lid closed; Dell-only/clamshell use needs a supported, explicitly selected camera or must remain locked for normal manual recovery. No automatic success on camera absence is acceptable.

## Decision gate

Resume only when the user returns to this feature. Any future real session-unlock integration requires the route, credential custody, spoof resistance, recovery behavior, and current-platform compatibility to be understood and documented. If the only practical route relies on stored-password injection or weak camera verification, state that tradeoff clearly before implementation rather than quietly adopting it. The requested face-only goal remains recorded even if later research concludes it cannot meet the user's security expectations.
