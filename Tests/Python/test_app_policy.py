"""Adversarial inspection fixtures; no Xcode, GUI, accounts or network needed."""
from dataclasses import replace
import hashlib
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "implementation"))
import app_policy as policy
import build_app


EXECUTABLE = "/tmp/Controlled Preview.app/Contents/MacOS/PersonalIsland"
SIGNATURE = "\n".join([
    "Executable=" + EXECUTABLE,
    "CodeDirectory v=20500 size=1852 flags=0x10002(adhoc,runtime) hashes=47+7 location=embedded",
    "Signature=adhoc", "TeamIdentifier=not set",
])
LIBRARIES = EXECUTABLE + ":\n" + "\n".join([
    "\t/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation (compatibility version 300.0.0, current version 5027.1.8)",
    "\t/usr/lib/swift/libswiftCoreAudio.dylib (compatibility version 1.0.0, current version 482.208.0, weak)",
]) + "\n"


def load_commands(paths=("/usr/lib/swift", "@executable_path/../Frameworks")):
    result = EXECUTABLE + ":\nLoad command 0\n      cmd LC_SEGMENT_64\n  cmdsize 72\n  segname __PAGEZERO\n"
    for index, path in enumerate(paths, 1):
        result += f"Load command {index}\n          cmd LC_RPATH\n      cmdsize 80\n         path {path} (offset 12)\n"
    return result


def valid_info():
    return {
        "CFBundleIdentifier": policy.BUNDLE_IDENTIFIER,
        "CFBundleExecutable": "PersonalIsland", "CFBundlePackageType": "APPL",
        "LSUIElement": True, "CFBundleVersion": "1",
        "NSAppleEventsUsageDescription": policy.APPLE_EVENTS_USAGE,
    }


ENTITLEMENTS = {"com.apple.security.automation.apple-events": True}
ENTITLEMENT_BYTES = plistlib.dumps(ENTITLEMENTS)


def bundle_entries():
    return [policy.BundleEntry(name, "file", b"\xcf\xfa\xed\xfeexecutable" if name == policy.EXECUTABLE_PATH else b"ordinary text")
            for name in sorted(policy.ALLOWED_BUNDLE_FILES)]


class InfoPolicyTests(unittest.TestCase):
    def test_current_preview_identity_and_menu_bar_configuration_pass(self):
        policy.validate_info_plist(valid_info())

    def test_identity_or_executable_path_substitution_fails(self):
        for key, value in [
            ("CFBundleIdentifier", "com.upstream.App"),
            ("CFBundleExecutable", "../../outside"),
            ("CFBundleExecutable", "/usr/bin/osascript"),
            ("CFBundleExecutable", "Other"),
        ]:
            with self.subTest(key=key, value=value):
                info = valid_info()
                info[key] = value
                with self.assertRaises(policy.PolicyError):
                    policy.validate_info_plist(info)

    def test_missing_or_wrong_application_kind_is_rejected(self):
        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType", "LSUIElement"):
            info = valid_info()
            del info[key]
            with self.subTest(key=key), self.assertRaises(policy.PolicyError):
                policy.validate_info_plist(info)
        for value in (False, 1, "YES"):
            with self.subTest(value=value), self.assertRaises(policy.PolicyError):
                policy.validate_info_plist({**valid_info(), "LSUIElement": value})

    def test_every_forbidden_capability_and_unknown_updater_key_is_rejected(self):
        for key in sorted(policy.FORBIDDEN_INFO_KEYS | {"SUEnableInstallerLauncherService", "SUFutureUpdaterKey"}):
            with self.subTest(key=key), self.assertRaises(policy.PolicyError):
                policy.validate_info_plist({**valid_info(), key: "untrusted value"})

    def test_reviewed_permission_text_is_required_exactly(self):
        info = valid_info()
        del info["NSAppleEventsUsageDescription"]
        for candidate in (info, {**info, "NSAppleEventsUsageDescription": ""},
                          {**info, "NSAppleEventsUsageDescription": "Personal Island controls every app."}):
            with self.subTest(candidate=candidate.get("NSAppleEventsUsageDescription")), self.assertRaises(policy.PolicyError):
                policy.validate_info_plist(candidate)

    def test_unreviewed_permission_explanations_are_rejected(self):
        for key in ("NSContactsUsageDescription", "NSPhotoLibraryUsageDescription", "NSFutureThingUsageDescription"):
            with self.subTest(key=key), self.assertRaises(policy.PolicyError):
                policy.validate_info_plist({**valid_info(), key: "text"})

    def test_malformed_plist_shape_is_rejected(self):
        for value in ([], None, "plist", {1: "bad key"}):
            with self.subTest(value=value), self.assertRaises(policy.PolicyError):
                policy.validate_info_plist(value)


class SignaturePolicyTests(unittest.TestCase):
    def test_release_requires_exactly_the_reviewed_apple_events_entitlement(self):
        for data in (plistlib.dumps(ENTITLEMENTS), plistlib.dumps(ENTITLEMENTS, fmt=plistlib.FMT_BINARY)):
            with self.subTest(data=data[:8]):
                self.assertEqual(policy.validate_release_signature(SIGNATURE, data), ENTITLEMENTS)

    def test_missing_entitlements_are_rejected(self):
        # Re-signing without them would silently break Spotify control.
        for data in (plistlib.dumps({}), b"", b"\n"):
            with self.subTest(data=data[:8]), self.assertRaises(policy.PolicyError):
                policy.validate_release_signature(SIGNATURE, data)

    def test_debug_privileged_extra_or_mistyped_entitlements_are_rejected(self):
        for values in (
            {**ENTITLEMENTS, "com.apple.security.get-task-allow": True},
            {**ENTITLEMENTS, "com.apple.security.get-task-allow": False},
            {**ENTITLEMENTS, "com.apple.security.cs.disable-library-validation": True},
            {**ENTITLEMENTS, "com.apple.security.personal-information.calendars": True},
            {"com.apple.security.automation.apple-events": False},
            {"com.apple.security.automation.apple-events": 1},
            {"com.apple.security.automation.apple-events": "YES"},
            {"com.apple.security.get-task-allow": True},
        ):
            with self.subTest(values=values), self.assertRaises(policy.PolicyError):
                policy.validate_release_signature(SIGNATURE, plistlib.dumps(values))

    def test_no_hardened_runtime_fails(self):
        with self.assertRaisesRegex(policy.PolicyError, "hardened runtime"):
            policy.validate_release_signature(SIGNATURE.replace("0x10002", "0x2"), ENTITLEMENT_BYTES)

    def test_non_ad_hoc_or_contradictory_signature_fails(self):
        for output in (
            SIGNATURE.replace("Signature=adhoc", "Signature=Developer ID Application"),
            SIGNATURE.replace("0x10002", "0x10000"),
            SIGNATURE + "\nSignature=adhoc",
        ):
            with self.subTest(output=output), self.assertRaises(policy.PolicyError):
                policy.validate_release_signature(output, ENTITLEMENT_BYTES)

    def test_local_identity_signature_passes_only_for_the_expected_authority(self):
        local = "\n".join([
            "Executable=" + EXECUTABLE,
            "CodeDirectory v=20500 size=1852 flags=0x10000(runtime) hashes=47+7 location=embedded",
            "Signature size=1650", "Authority=" + policy.LOCAL_SIGNING_IDENTITY,
            "Signed Time=Nov 12, 2026 at 03:10:00", "TeamIdentifier=not set",
        ])
        self.assertEqual(policy.validate_release_signature(local, ENTITLEMENT_BYTES, policy.LOCAL_SIGNING_IDENTITY), ENTITLEMENTS)
        for output, authority in (
            (local, None),  # an identity-signed build cannot pass as ad hoc
            (local, "Someone Else"),
            (local.replace("flags=0x10000(runtime)", "flags=0x2(adhoc)"), policy.LOCAL_SIGNING_IDENTITY),
            (local.replace("flags=0x10000(runtime)", "flags=0x10002(adhoc,runtime)"), policy.LOCAL_SIGNING_IDENTITY),
            (local + "\nSignature=adhoc", policy.LOCAL_SIGNING_IDENTITY),
            (local + "\nAuthority=Apple Root CA", policy.LOCAL_SIGNING_IDENTITY),
            (local.replace("TeamIdentifier=not set", "TeamIdentifier=ABCDE12345"), policy.LOCAL_SIGNING_IDENTITY),
            (SIGNATURE, policy.LOCAL_SIGNING_IDENTITY),  # ad hoc when an identity was used
        ):
            with self.subTest(output=output, authority=authority), self.assertRaises(policy.PolicyError):
                policy.validate_release_signature(output, ENTITLEMENT_BYTES, authority)

    def test_ad_hoc_signature_with_an_authority_fails(self):
        with self.assertRaises(policy.PolicyError):
            policy.validate_release_signature(SIGNATURE + "\nAuthority=Personal Island Local Signing", ENTITLEMENT_BYTES)

    def test_missing_duplicate_or_malformed_code_directory_fails(self):
        for output in ("", "tool error", SIGNATURE.replace("0x10002", "0xgarbage"),
                       SIGNATURE.replace("CodeDirectory", "NotCodeDirectory"),
                       SIGNATURE + "\nCodeDirectory flags=0x10002"):
            with self.subTest(output=output), self.assertRaises(policy.PolicyError):
                policy.validate_release_signature(output, ENTITLEMENT_BYTES)

    def test_malformed_or_non_dictionary_entitlement_payload_fails(self):
        for data in (b"malformed", b"<plist><dict>", plistlib.dumps([]), plistlib.dumps("wrong type"), "not bytes"):
            with self.subTest(data=data), self.assertRaises(policy.PolicyError):
                policy.validate_release_signature(SIGNATURE, data)


HASH_A = "A" * 40
HASH_B = "0123456789ABCDEF0123456789ABCDEF01234567"


class SigningIdentityTests(unittest.TestCase):
    def listing(self, *entries):
        lines = ["Policy: Code Signing", "  Matching identities"]
        lines += [f'  {index}) {digest} "{name}"{suffix}' for index, (digest, name, suffix) in enumerate(entries, 1)]
        lines += [f"     {len(entries)} identities found"]
        return "\n".join(lines) + "\n"

    def test_exact_name_selects_its_hash_even_when_untrusted_or_listed_twice(self):
        output = self.listing((HASH_A, "Apple Development: someone", ""),
                              (HASH_B, policy.LOCAL_SIGNING_IDENTITY, " (CSSMERR_TP_NOT_TRUSTED)"))
        output += self.listing((HASH_B, policy.LOCAL_SIGNING_IDENTITY, ""))
        self.assertEqual(policy.parse_signing_identity(output), HASH_B)

    def test_absent_or_similar_names_select_nothing(self):
        for output in ("", "     0 valid identities found\n",
                       self.listing((HASH_A, policy.LOCAL_SIGNING_IDENTITY + " 2", "")),
                       self.listing((HASH_A, "personal island local signing", "")),
                       self.listing((HASH_A[:39], policy.LOCAL_SIGNING_IDENTITY, ""))):
            with self.subTest(output=output):
                self.assertIsNone(policy.parse_signing_identity(output))

    def test_two_identities_with_the_same_name_are_rejected(self):
        output = self.listing((HASH_A, policy.LOCAL_SIGNING_IDENTITY, ""), (HASH_B, policy.LOCAL_SIGNING_IDENTITY, ""))
        with self.assertRaisesRegex(policy.PolicyError, "More than one"):
            policy.parse_signing_identity(output)

    def test_non_text_inspection_fails(self):
        with self.assertRaises(policy.PolicyError):
            policy.parse_signing_identity(b"bytes")


class LinkagePolicyTests(unittest.TestCase):
    def test_system_libraries_with_weak_links_and_spaces_in_executable_pass(self):
        self.assertEqual(policy.parse_system_libraries(LIBRARIES, EXECUTABLE), [
            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
            "/usr/lib/swift/libswiftCoreAudio.dylib",
        ])

    def test_external_relative_and_system_prefix_escape_paths_fail(self):
        for path in ("/opt/third-party.dylib", "@rpath/Unexpected.framework/Unexpected",
                     "/System/LibraryFake/Helper", "/usr/lib/../../tmp/Helper",
                     "/usr/lib//Helper", "/usr/lib/./Helper"):
            output = EXECUTABLE + f":\n\t{path} (compatibility version 1.0.0, current version 1.0.0)\n"
            with self.subTest(path=path), self.assertRaises(policy.PolicyError):
                policy.parse_system_libraries(output, EXECUTABLE)

    def test_missing_wrong_header_and_malformed_library_output_fail_closed(self):
        for output in ("", EXECUTABLE + ":", LIBRARIES.replace(EXECUTABLE, "/tmp/Other"),
                       EXECUTABLE + ":\n\t/usr/lib/Helper\n", LIBRARIES + "warning: truncated\n"):
            with self.subTest(output=output), self.assertRaises(policy.PolicyError):
                policy.parse_system_libraries(output, EXECUTABLE)

    def test_duplicate_library_records_fail(self):
        with self.assertRaises(policy.PolicyError):
            policy.parse_system_libraries(LIBRARIES + LIBRARIES.splitlines()[1] + "\n", EXECUTABLE)

    def test_only_allowed_runtime_paths_pass(self):
        self.assertEqual(policy.parse_runtime_paths(load_commands(), EXECUTABLE), [
            "/usr/lib/swift", "@executable_path/../Frameworks",
        ])

    def test_no_runtime_paths_is_valid_with_complete_non_rpath_commands(self):
        self.assertEqual(policy.parse_runtime_paths(load_commands(()), EXECUTABLE), [])

    def test_external_or_expanded_runtime_paths_fail(self):
        for path in ("/tmp", "@loader_path", "@executable_path/../../outside", "/usr/lib/swift/../other"):
            with self.subTest(path=path), self.assertRaises(policy.PolicyError):
                policy.parse_runtime_paths(load_commands((path,)), EXECUTABLE)

    def test_empty_truncated_or_malformed_load_commands_fail_closed(self):
        outputs = (
            "", EXECUTABLE + ":", load_commands().replace("Load command 1", "Load command 9"),
            load_commands().replace("cmd LC_RPATH", "cmd broken", 1),
            load_commands().replace("path /usr/lib/swift (offset 12)", "path /usr/lib/swift"),
            load_commands().replace("cmdsize 80", "cmdsize nope", 1),
            load_commands() + "Load command 3\n",
        )
        for output in outputs:
            with self.subTest(output=output), self.assertRaises(policy.PolicyError):
                policy.parse_runtime_paths(output, EXECUTABLE)

    def test_invalid_path_offsets_and_duplicate_paths_fail(self):
        for output in (
            load_commands().replace("offset 12", "offset 0", 1),
            load_commands().replace("offset 12", "offset 99", 1),
            load_commands(("/usr/lib/swift", "/usr/lib/swift")),
        ):
            with self.subTest(output=output), self.assertRaises(policy.PolicyError):
                policy.parse_runtime_paths(output, EXECUTABLE)


class BundlePolicyTests(unittest.TestCase):
    def test_exact_inventory_passes_and_hashes_actual_bytes(self):
        entries = bundle_entries()
        inventory = policy.validate_bundle_entries(entries)
        self.assertEqual({entry["path"] for entry in inventory}, policy.ALLOWED_BUNDLE_FILES)
        for entry in inventory:
            data = next(value.data for value in entries if value.path == entry["path"])
            self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(entry["bytes"], len(data))

    def test_missing_required_file_fails(self):
        for name in policy.ALLOWED_BUNDLE_FILES:
            with self.subTest(name=name), self.assertRaises(policy.PolicyError):
                policy.validate_bundle_entries([entry for entry in bundle_entries() if entry.path != name])

    def test_unexpected_files_helpers_and_empty_code_directories_fail(self):
        for extra in (
            policy.BundleEntry("Contents/Helpers/RenamedTool", "file", b"code"),
            policy.BundleEntry("Contents/Resources/extra.txt", "file", b"extra"),
            policy.BundleEntry("Contents/XPCServices", "directory"),
            policy.BundleEntry("Contents/Frameworks", "directory"),
        ):
            with self.subTest(extra=extra), self.assertRaises(policy.PolicyError):
                policy.validate_bundle_entries(bundle_entries() + [extra])

    def test_symlinks_and_nonregular_nodes_fail(self):
        for kind in ("symlink", "fifo", "other"):
            entries = [replace(value, kind=kind) if value.path == "Contents/PkgInfo" else value for value in bundle_entries()]
            with self.subTest(kind=kind), self.assertRaises(policy.PolicyError):
                policy.validate_bundle_entries(entries)

    def test_hidden_executable_content_in_an_allowlisted_notice_fails(self):
        for magic in policy.MACHO_MAGICS | {b"\x7fELF", b"#!/bin/sh\n", b"!<arch>\n"}:
            entries = [replace(value, data=magic + b"payload") if value.path.endswith("Atoll-LICENSE.txt") else value for value in bundle_entries()]
            with self.subTest(magic=magic), self.assertRaises(policy.PolicyError):
                policy.validate_bundle_entries(entries)

    def test_non_macho_main_executable_fails(self):
        entries = [replace(value, data=b"#!/bin/sh\n") if value.path == policy.EXECUTABLE_PATH else value for value in bundle_entries()]
        with self.assertRaises(policy.PolicyError):
            policy.validate_bundle_entries(entries)

    def test_duplicate_absolute_or_traversal_inventory_paths_fail(self):
        for name in ("../outside", "/tmp/outside", "Contents/../outside", "Contents//PkgInfo", "Contents\\PkgInfo"):
            with self.subTest(name=name), self.assertRaises(policy.PolicyError):
                policy.validate_bundle_entries(bundle_entries() + [policy.BundleEntry(name, "file", b"fixture")])
        with self.assertRaises(policy.PolicyError):
            policy.validate_bundle_entries(bundle_entries() + [bundle_entries()[0]])


class FilesystemCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Fixture.app"
        self.app.mkdir()
        for entry in bundle_entries():
            path = self.app / entry.path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(entry.data)

    def test_actual_regular_file_tree_passes_without_execution(self):
        inventory = policy.validate_bundle_entries(build_app.collect_bundle_entries(self.app))
        self.assertEqual(len(inventory), 8)

    def test_actual_file_symlink_is_rejected_and_outside_sentinel_untouched(self):
        outside = self.root / "sentinel"
        outside.write_bytes(b"preserve")
        target = self.app / "Contents/PkgInfo"
        target.unlink()
        target.symlink_to(outside)
        with self.assertRaises(policy.PolicyError):
            policy.validate_bundle_entries(build_app.collect_bundle_entries(self.app))
        self.assertEqual(outside.read_bytes(), b"preserve")

    def test_directory_symlink_is_not_traversed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret").write_bytes(b"preserve")
        (self.app / "Contents/link").symlink_to(outside, target_is_directory=True)
        entries = build_app.collect_bundle_entries(self.app)
        self.assertFalse(any(value.path.endswith("secret") for value in entries))
        with self.assertRaises(policy.PolicyError):
            policy.validate_bundle_entries(entries)

    def test_symlink_bundle_root_is_rejected(self):
        link = self.root / "Linked.app"
        link.symlink_to(self.app, target_is_directory=True)
        with self.assertRaises(policy.PolicyError):
            build_app.collect_bundle_entries(link)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixture requires POSIX")
    def test_fifo_is_classified_without_opening_or_blocking(self):
        target = self.app / "Contents/PkgInfo"
        target.unlink()
        os.mkfifo(target)
        entries = build_app.collect_bundle_entries(self.app)
        self.assertEqual(next(value.kind for value in entries if value.path == "Contents/PkgInfo"), "other")
        with self.assertRaises(policy.PolicyError):
            policy.validate_bundle_entries(entries)


if __name__ == "__main__":
    unittest.main()
