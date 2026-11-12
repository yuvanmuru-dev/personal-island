"""Pure validation policy for the current controlled preview bundle.

No subprocesses, filesystem access or network requests occur here. These checks
validate supplied inspection evidence; they do not replace codesign verification
or prove runtime behavior. Adding a deliberate capability/resource later requires
an explicit policy update alongside its implementation.
"""
from dataclasses import dataclass
import hashlib
from pathlib import PurePosixPath
import plistlib
import re
from typing import Mapping, Sequence
from xml.parsers.expat import ExpatError


class PolicyError(ValueError):
    """Inspection evidence is malformed or violates the preview policy."""


BUNDLE_IDENTIFIER = "dev.personal.PersonalIsland"
EXECUTABLE_NAME = "PersonalIsland"
EXECUTABLE_PATH = "Contents/MacOS/" + EXECUTABLE_NAME
NOTICE_NAMES = (
    "Atoll-LICENSE.txt", "Atoll-NOTICE.txt", "Atoll-COPYRIGHT_ASSETS.txt",
    "Atoll-TRADEMARKS.txt",
)
ALLOWED_BUNDLE_FILES = frozenset({
    "Contents/Info.plist", EXECUTABLE_PATH, "Contents/PkgInfo",
    "Contents/_CodeSignature/CodeResources",
    *("Contents/Resources/" + name for name in NOTICE_NAMES),
})
ALLOWED_RUNTIME_PATHS = frozenset({"/usr/lib/swift", "@executable_path/../Frameworks"})
FORBIDDEN_INFO_KEYS = frozenset({
    "NSAppTransportSecurity", "CFBundleURLTypes", "SMPrivilegedExecutables",
    "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
    "NSCalendarsUsageDescription",
    "NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription",
    "NSAppleMusicUsageDescription",
    "NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription",
    "NSBluetoothAlwaysUsageDescription", "NSScreenCaptureUsageDescription",
    "NSAudioCaptureUsageDescription", "NSDesktopFolderUsageDescription",
    "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
})
# Each reviewed capability is listed with its exact value and the permission
# text macOS shows. Anything else stays forbidden.
APPLE_EVENTS_USAGE = (
    "Personal Island sends Apple Events only to Spotify, when you turn on Spotify "
    "in Settings, to show the current track and to play, pause and skip."
)
CALENDARS_USAGE = (
    "Personal Island shows your next event and today's agenda from calendars on this Mac, "
    "when you turn on Calendar in Settings. Events are only read, never changed or sent anywhere."
)
REQUIRED_INFO_STRINGS = {
    "NSAppleEventsUsageDescription": APPLE_EVENTS_USAGE,
    "NSCalendarsFullAccessUsageDescription": CALENDARS_USAGE,
}
# Sending Apple Events under the hardened runtime requires this entitlement.
# The Automation permission prompt still applies per target app (Spotify).
# Reading events under the hardened runtime requires the calendars
# entitlement; macOS still asks the user for Calendar access separately.
RELEASE_ENTITLEMENTS = {
    "com.apple.security.automation.apple-events": True,
    "com.apple.security.personal-information.calendars": True,
}
MACHO_MAGICS = frozenset({
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
})


def validate_info_plist(info: Mapping) -> None:
    if not isinstance(info, dict):
        raise PolicyError("Built Info.plist must be a dictionary")
    if not all(isinstance(key, str) for key in info):
        raise PolicyError("Built Info.plist keys must be strings")
    if info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER:
        raise PolicyError("Unexpected built bundle identity")
    if info.get("CFBundleExecutable") != EXECUTABLE_NAME:
        raise PolicyError("Unexpected built executable name")
    if info.get("CFBundlePackageType") != "APPL" or info.get("LSUIElement") is not True:
        raise PolicyError("Unexpected application/menu-bar configuration")
    forbidden = sorted(key for key in info if key in FORBIDDEN_INFO_KEYS or key.startswith("SU"))
    if forbidden:
        raise PolicyError("Unexpected capability/update configuration: " + ", ".join(forbidden))
    for key, text in REQUIRED_INFO_STRINGS.items():
        if info.get(key) != text:
            raise PolicyError("Missing or changed permission explanation: " + key)
    unreviewed = sorted(key for key in info if key.endswith("UsageDescription") and key not in REQUIRED_INFO_STRINGS)
    if unreviewed:
        raise PolicyError("Unreviewed permission explanation: " + ", ".join(unreviewed))


LOCAL_SIGNING_IDENTITY = "Personal Island Local Signing"
_IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"\n]*)"(?:\s+\([^\n]*\))?\s*$')


def parse_signing_identity(output: str, name: str = LOCAL_SIGNING_IDENTITY):
    """Return the SHA-1 of the single code-signing identity named exactly `name`.

    `security find-identity -p codesigning` may list an identity in more than
    one section, so equal hashes collapse. Two different identities with the
    same name are ambiguous and rejected rather than guessed between.
    """
    if not isinstance(output, str):
        raise PolicyError("Signing identity inspection must be text")
    hashes = {match.group(1) for line in output.splitlines()
              if (match := _IDENTITY_LINE.match(line)) and match.group(2) == name}
    if len(hashes) > 1:
        raise PolicyError("More than one signing identity is named " + name)
    return next(iter(hashes), None)


def validate_release_signature(signature_output: str, entitlement_bytes: bytes,
                               expected_authority: str | None = None) -> dict:
    """Require one hardened signature and exactly the reviewed entitlements.

    Without `expected_authority` the signature must be ad-hoc. With it, the
    signature must come from exactly that one local certificate (no chain,
    no team), so macOS privacy permissions persist across local rebuilds.

    An empty entitlements output is valid when codesign reports no entitlement
    blob. A present blob must be a well-formed, empty plist dictionary.
    """
    if not isinstance(signature_output, str) or not signature_output.strip():
        raise PolicyError("Missing signature inspection output")
    flags = re.findall(r"^CodeDirectory[^\n]*\bflags=0x([0-9a-fA-F]+)(?:\([^\n]*?\))?(?:\s|$)", signature_output, re.MULTILINE)
    if len(flags) != 1:
        raise PolicyError("Expected one parseable CodeDirectory flags entry")
    flag_value = int(flags[0], 16)
    if not flag_value & 0x10000:
        raise PolicyError("Release signature is missing hardened runtime")
    signatures = re.findall(r"^Signature=(.+)$", signature_output, re.MULTILINE)
    authorities = re.findall(r"^Authority=(.+)$", signature_output, re.MULTILINE)
    teams = re.findall(r"^TeamIdentifier=(.+)$", signature_output, re.MULTILINE)
    if expected_authority is None:
        if signatures != ["adhoc"] or not flag_value & 0x2 or authorities:
            raise PolicyError("Unexpected signing identity for the local build")
    elif (signatures or flag_value & 0x2 or authorities != [expected_authority]
          or teams != ["not set"]):
        raise PolicyError("Unexpected signing identity for the local build")
    if not isinstance(entitlement_bytes, bytes):
        raise PolicyError("Entitlements inspection must supply bytes")
    if entitlement_bytes.strip():
        try:
            entitlements = plistlib.loads(entitlement_bytes)
        except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError, ExpatError) as error:
            raise PolicyError("Malformed effective entitlements plist") from error
    else:
        entitlements = {}
    if not isinstance(entitlements, dict):
        raise PolicyError("Effective entitlements must be a dictionary")
    # Exact match: no extra keys, no missing key, and `True` must be a real
    # boolean (plist integers compare equal to True in Python).
    if (entitlements.keys() != RELEASE_ENTITLEMENTS.keys()
            or any(type(entitlements[key]) is not type(value) or entitlements[key] != value
                   for key, value in RELEASE_ENTITLEMENTS.items())):
        raise PolicyError("Release build has unexpected effective entitlements")
    return entitlements


def _tool_body(output: str, executable: str) -> list[str]:
    if not isinstance(output, str) or not output.strip():
        raise PolicyError("Missing executable inspection output")
    lines = output.strip().splitlines()
    if lines[0] != executable + ":":
        raise PolicyError("Inspection output does not identify the expected executable")
    return lines[1:]


def parse_system_libraries(output: str, executable: str) -> list[str]:
    lines = _tool_body(output, executable)
    if not lines:
        raise PolicyError("Linked-library inspection contains no library entries")
    version = r"\d+(?:\.\d+){0,3}"
    pattern = re.compile(
        r"^\s+(.+?) \(compatibility version " + version
        + r", current version " + version + r"(?:, (?:weak|reexport|upward))*\)$"
    )
    paths = []
    for line in lines:
        match = pattern.fullmatch(line)
        if not match:
            raise PolicyError("Malformed linked-library inspection entry")
        path = match.group(1)
        if (not path.startswith(("/System/Library/", "/usr/lib/"))
                or "\x00" in path or "\\" in path
                or any(part in (".", "..", "") for part in path.split("/")[1:])):
            raise PolicyError("Unexpected non-system linked library")
        paths.append(path)
    if len(paths) != len(set(paths)):
        raise PolicyError("Duplicate linked-library inspection entries")
    return paths


def parse_runtime_paths(output: str, executable: str) -> list[str]:
    """Parse all load-command blocks so malformed RPATH output fails closed."""
    body = "\n".join(_tool_body(output, executable))
    blocks = re.split(r"(?m)^Load command (\d+)\s*$", body)
    if blocks[0].strip() or len(blocks) < 3:
        raise PolicyError("Malformed or missing load-command inspection")
    paths = []
    for position in range(1, len(blocks), 2):
        if int(blocks[position]) != (position - 1) // 2:
            raise PolicyError("Noncontiguous load-command inspection")
        block = blocks[position + 1]
        commands = re.findall(r"(?m)^\s+cmd (LC_[A-Z0-9_]+)\s*$", block)
        sizes = re.findall(r"(?m)^\s+cmdsize (\d+)\s*$", block)
        if len(commands) != 1 or len(sizes) != 1 or int(sizes[0]) < 8:
            raise PolicyError("Malformed load-command inspection block")
        if commands[0] == "LC_RPATH":
            matches = re.findall(r"(?m)^\s+path (.+?) \(offset (\d+)\)\s*$", block)
            if len(matches) != 1:
                raise PolicyError("Malformed runtime library search path")
            path, offset = matches[0]
            if int(offset) < 8 or int(offset) >= int(sizes[0]):
                raise PolicyError("Invalid runtime library search path offset")
            if path not in ALLOWED_RUNTIME_PATHS:
                raise PolicyError("Unexpected runtime library search path")
            paths.append(path)
    if len(paths) != len(set(paths)):
        raise PolicyError("Duplicate runtime library search paths")
    return paths


@dataclass(frozen=True)
class BundleEntry:
    path: str
    kind: str
    data: bytes = b""


def _valid_relative_path(path: str) -> bool:
    return (isinstance(path, str) and bool(path) and not path.startswith("/")
            and "\x00" not in path and "\\" not in path
            and all(part not in ("", ".", "..") for part in path.split("/")))


def validate_bundle_entries(entries: Sequence[BundleEntry]) -> list[dict]:
    """Validate a collected bundle inventory without following filesystem links."""
    allowed_directories = {
        str(parent) for name in ALLOWED_BUNDLE_FILES
        for parent in PurePosixPath(name).parents if str(parent) != "."
    }
    seen = set()
    files = set()
    inventory = []
    for entry in sorted(entries, key=lambda value: value.path):
        if not _valid_relative_path(entry.path) or entry.path in seen:
            raise PolicyError("Unsafe or duplicate bundle inventory path")
        seen.add(entry.path)
        if entry.kind == "directory":
            if entry.path not in allowed_directories:
                raise PolicyError("Unexpected directory in controlled app")
            continue
        if entry.kind != "file":
            raise PolicyError("Unexpected symlink or nonregular node in controlled app")
        if entry.path not in ALLOWED_BUNDLE_FILES:
            raise PolicyError("Unexpected file in controlled app")
        if not isinstance(entry.data, bytes):
            raise PolicyError("Bundle file inspection must supply bytes")
        has_code = entry.data[:4] in MACHO_MAGICS or entry.data.startswith((b"\x7fELF", b"#!", b"!<arch>\n"))
        if entry.path == EXECUTABLE_PATH:
            if entry.data[:4] not in MACHO_MAGICS:
                raise PolicyError("Main executable is not a Mach-O file")
        elif has_code:
            raise PolicyError("Unexpected additional executable code in app")
        files.add(entry.path)
        inventory.append({"path": entry.path, "bytes": len(entry.data), "sha256": hashlib.sha256(entry.data).hexdigest()})
    if files != ALLOWED_BUNDLE_FILES:
        raise PolicyError("Built bundle is missing required allowlisted files")
    return inventory
