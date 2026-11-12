"""Build and inspect the controlled app, without launching or installing it."""
from pathlib import Path
import datetime
import hashlib
import json
import plistlib
import stat
import subprocess
import sys

if __package__:
    from .app_policy import (
        LOCAL_SIGNING_IDENTITY, BundleEntry, PolicyError, parse_runtime_paths,
        parse_signing_identity, parse_system_libraries, validate_bundle_entries,
        validate_info_plist, validate_release_signature,
    )
    from .generate_app_project import APP_FILES
else:
    from app_policy import (
        LOCAL_SIGNING_IDENTITY, BundleEntry, PolicyError, parse_runtime_paths,
        parse_signing_identity, parse_system_libraries, validate_bundle_entries,
        validate_info_plist, validate_release_signature,
    )
    from generate_app_project import APP_FILES

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"


def run(arguments):
    return subprocess.run(arguments, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def collect_bundle_entries(app):
    """Collect regular files without reading special nodes or following links."""
    if not stat.S_ISDIR(app.lstat().st_mode):
        raise PolicyError("Controlled app must be an ordinary directory")
    entries = []

    def visit(directory):
        for path in sorted(directory.iterdir()):
            name = path.relative_to(app).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entries.append(BundleEntry(name, "symlink"))
            elif stat.S_ISDIR(mode):
                entries.append(BundleEntry(name, "directory"))
                visit(path)
            elif stat.S_ISREG(mode):
                entries.append(BundleEntry(name, "file", path.read_bytes()))
            else:
                entries.append(BundleEntry(name, "other"))

    visit(app)
    return entries


def apply_local_signing(app):
    """Re-sign with the user's local identity when exactly one exists.

    Xcode signs ad hoc, which macOS identifies by a per-build code hash, so
    Screen Recording permission is lost on every rebuild. A stable local
    certificate keeps the same designated requirement. Without one (for
    example in CI) the ad-hoc signature is kept. Returns the authority name
    the signature must carry, or None for ad hoc.
    """
    listed = run(["/usr/bin/security", "find-identity", "-p", "codesigning"])
    if listed.returncode:
        raise PolicyError("Could not list local code-signing identities")
    identity = parse_signing_identity(listed.stdout, LOCAL_SIGNING_IDENTITY)
    if identity is None:
        return None
    # Re-signing replaces the signature, so the reviewed entitlements must be
    # supplied again or they would be silently dropped.
    signed = run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime",
                  "--timestamp=none", "--entitlements", str(ROOT / "PersonalIslandApp/PersonalIsland.entitlements"),
                  str(app)])
    if signed.returncode:
        raise PolicyError("Local signing failed: " + signed.stdout.strip()[-300:])
    return LOCAL_SIGNING_IDENTITY


def main():
    receipt_path = ROOT / "implementation/APP_BUILD_RECEIPT.json"
    # A failed rebuild must not leave a previous success looking current.
    receipt_path.unlink(missing_ok=True)
    generated = run([sys.executable, str(ROOT / "implementation/generate_app_project.py")])
    print(generated.stdout, end="", flush=True)
    if generated.returncode: return generated.returncode
    required = APP_FILES
    missing = [name for name in required if not (ROOT / "PersonalIslandApp/Sources" / name).is_file()]
    if missing:
        print("Required application source files are missing: " + ", ".join(missing))
        return 1
    BUILD.mkdir(exist_ok=True)
    input_paths = sorted([
        *list((ROOT / "PersonalIslandApp/Sources").glob("*.swift")),
        *list((ROOT / "PersonalIslandCore/Sources/PersonalIslandCore").glob("*.swift")),
        *list((ROOT / "PersonalIslandApp/Resources").glob("*")),
        ROOT / "PersonalIslandApp/PersonalIsland.xcodeproj/project.pbxproj",
        ROOT / "PersonalIslandApp/PersonalIsland.xcodeproj/xcshareddata/xcschemes/PersonalIsland.xcscheme",
        ROOT / "PersonalIslandApp/Info.plist", ROOT / "PersonalIslandApp/PersonalIsland.entitlements",
        Path(__file__).resolve(), ROOT / "implementation/generate_app_project.py",
        ROOT / "implementation/app_policy.py",
    ])
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in input_paths}
    command = [
        "/usr/bin/xcodebuild", "-project", str(ROOT / "PersonalIslandApp/PersonalIsland.xcodeproj"),
        "-scheme", "PersonalIsland", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(BUILD / "XcodeDerivedData"),
        "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "build",
    ]
    result = run(command)
    (BUILD / "app-build.log").write_text(result.stdout)
    interesting = [line for line in result.stdout.splitlines() if any(word in line for word in ["error:", "warning:", "BUILD SUCCEEDED", "BUILD FAILED", "CodeSign "])]
    print("\n".join(interesting[-45:]), flush=True)
    if result.returncode:
        print("Full build log: " + str(BUILD / "app-build.log"))
        return result.returncode
    if any(hashlib.sha256(p.read_bytes()).hexdigest() != source_hashes[str(p.relative_to(ROOT))] for p in input_paths):
        raise RuntimeError("Build inputs changed during compilation; rebuild before recording success")
    app = BUILD / "XcodeDerivedData/Build/Products/Release/PersonalIsland.app"
    signing_authority = apply_local_signing(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    validate_info_plist(info)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    verification = run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(app)])
    signature = run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)])
    entitlement_result = subprocess.run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    linked = run(["/usr/bin/otool", "-L", str(executable)])
    load_commands = run(["/usr/bin/otool", "-l", str(executable)])
    if verification.returncode or signature.returncode or linked.returncode or load_commands.returncode or entitlement_result.returncode:
        print(verification.stdout + signature.stdout + linked.stdout + load_commands.stdout)
        return 1
    entitlements = validate_release_signature(signature.stdout, entitlement_result.stdout, signing_authority)
    library_paths = parse_system_libraries(linked.stdout, str(executable))
    runtime_paths = parse_runtime_paths(load_commands.stdout, str(executable))
    toolchain = {}
    for name, arguments in {
        "developer_directory": ["/usr/bin/xcode-select", "-p"],
        "xcode": ["/usr/bin/xcodebuild", "-version"],
        "swift": ["/usr/bin/xcrun", "swift", "--version"],
        "macos_sdk": ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
    }.items():
        inspected = run(arguments)
        if inspected.returncode: raise RuntimeError("Could not record " + name)
        toolchain[name] = inspected.stdout.strip().splitlines()[-1] if name == "macos_sdk" else inspected.stdout.strip()
    inventory = validate_bundle_entries(collect_bundle_entries(app))
    built_at = datetime.datetime.now(datetime.timezone.utc)
    receipt = {
        "date": built_at.date().isoformat(), "built_at_utc": built_at.isoformat(),
        "configuration": "Release", "build": "passed", "app_path": str(app),
        "toolchain": toolchain, "build_command": command, "build_input_sha256": source_hashes,
        "bundle_identifier": info["CFBundleIdentifier"], "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "external_package_dependencies": [], "embedded_upstream_helpers": [],
        "signature_verification": verification.stdout.strip(), "signature_details": signature.stdout.strip(),
        "signing": {"mode": "local_identity" if signing_authority else "ad_hoc", "authority": signing_authority},
        "effective_entitlements": entitlements, "hardened_runtime": True, "runtime_search_paths": runtime_paths,
        "linked_libraries": linked.stdout.strip().splitlines(), "validated_library_paths": library_paths,
        "bundle_files": inventory,
        "load_commands_sha256": hashlib.sha256(load_commands.stdout.encode()).hexdigest(), "app_launched": False,
        "limitations": "Build and bundle inspection only; the app is not launched. Runtime behavior is recorded separately from user checks.",
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print("Built and inspected (not launched): " + str(app), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
