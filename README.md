# Personal Island for Mac

A personal, locally controlled Mac island project for the 14-inch M5 MacBook Pro and Dell 4K display. Both displays will share one temporary screenshot/file shelf. The intended product also includes Spotify, Apple Calendar, and the accepted status and utility features. Face unlock is deferred.

Private source repository: [yuvanmuru-dev/personal-island](https://github.com/yuvanmuru-dev/personal-island).

## Verify a checkout

With full Xcode selected on a Mac, run:

```sh
python3 implementation/verify.py
```

This tests the actual storage and presentation logic, measures source coverage, checks project/build policy, and builds and inspects the Release app without opening it. See [TESTING.md](TESTING.md) for automated coverage and checks still requiring a running app. Builds use only checked-in local source and Apple SDKs; the upstream audit archive is not needed.

## Current status

The controlled graphical app host builds and passes bundle/signature inspection. It uses explicit presentation sources and the local core, without the upstream package/helper/startup graph. Expanded storage, presentation and build-policy tests are included. It has not been launched; capture, native dragging and the accepted integrations are still to be implemented.

- [Build and implementation plan](BUILD_IMPLEMENTATION_PLAN.md)
- [Product scope and decisions](PLAN.md)
- [Security and privacy review](SECURITY_REVIEW.md)
- [App source and build instructions](PersonalIslandApp/README.md)
- [App build verification](PersonalIslandApp/VERIFICATION.md)
- [Deferred face-unlock research](FACE_UNLOCK_FEASIBILITY.md)

The source snapshots under `audit/sources/` are static review evidence, not build checkouts. They deliberately exclude executable/framework content and some assets. Do not run their scripts or treat them as a ready-to-install application.

The reference archive stays local and is excluded from Git. Pinned review manifests/notes, source provenance and retained license notices are tracked. Screenshots, temporary shelves, compiler caches, built apps, personal environment files and machine-specific build receipts are ignored.

## Implementation boundaries

`PersonalIslandCore/` contains new, dependency-free storage logic and synthetic tests, and is linked into the controlled app host. It performs no capture, clipboard monitoring, account access, network requests, app installation, or login changes.

[Core interface and build instructions](PersonalIslandCore/README.md), [initial core verification](PersonalIslandCore/VERIFICATION.md).

Build/test results and remaining work are tracked in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).
