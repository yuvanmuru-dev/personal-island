"""Inspect a generated project in a fresh fixture, without Xcode or audit data."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "implementation"))
import generate_app_project as generator
import app_policy


def parse_generated_openstep(text):
    """Small independent reader for the generator's quoted OpenStep subset."""
    text = text.split("\n", 1)[1]  # Xcode's encoding comment.
    scanner = re.compile(r'\s*("(?:\\.|[^"\\])*"|-?\d+|[{}()=;,])', re.DOTALL)
    tokens = []
    position = 0
    while text[position:].strip():
        match = scanner.match(text, position)
        if not match:
            raise AssertionError("Invalid generated OpenStep syntax")
        tokens.append(match.group(1))
        position = match.end()
    position = 0

    def take(expected=None):
        nonlocal position
        if position >= len(tokens):
            raise AssertionError("Truncated generated project")
        token = tokens[position]
        position += 1
        if expected is not None and token != expected:
            raise AssertionError(f"Expected {expected}, found {token}")
        return token

    def value():
        token = take()
        if token == "{":
            result = {}
            while tokens[position] != "}":
                key = json.loads(take())
                if key in result:
                    raise AssertionError("Duplicate generated project key")
                take("=")
                result[key] = value()
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while tokens[position] != ")":
                result.append(value())
                if tokens[position] == ",":
                    take(",")
                elif tokens[position] != ")":
                    raise AssertionError("Invalid project array separator")
            take(")")
            return result
        if token.startswith('"'):
            return json.loads(token)
        return int(token)

    result = value()
    if position != len(tokens):
        raise AssertionError("Unexpected data after project")
    return result


class ProjectGenerationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "PersonalIslandApp"
        self.project = self.app / "PersonalIsland.xcodeproj"
        resources = self.app / "Resources"
        resources.mkdir(parents=True)
        for name in generator.RESOURCES:
            shutil.copyfile(ROOT / "PersonalIslandApp/Resources" / name, resources / name)
        self.patching = patch.multiple(generator, ROOT=self.root, APP=self.app, PROJECT=self.project)
        self.patching.start()
        self.addCleanup(self.patching.stop)
        self.generate()

    def generate(self):
        with contextlib.redirect_stdout(io.StringIO()):
            generator.main()
        self.graph = parse_generated_openstep((self.project / "project.pbxproj").read_text())
        self.objects = self.graph["objects"]

    def target(self, name):
        matches = [value for value in self.objects.values() if value["isa"] == "PBXNativeTarget" and value["name"] == name]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def configurations(self, target):
        ids = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        return {self.objects[key]["name"]: self.objects[key]["buildSettings"] for key in ids}

    def phase_files(self, target, isa):
        phases = [self.objects[key] for key in target["buildPhases"] if self.objects[key]["isa"] == isa]
        self.assertEqual(len(phases), 1)
        return [self.objects[self.objects[key]["fileRef"]]["path"] for key in phases[0]["files"]]

    def test_fresh_checkout_needs_canonical_notices_but_no_audit_archive(self):
        self.assertFalse((self.root / "audit").exists())
        for name in generator.RESOURCES:
            self.assertEqual((self.app / "Resources" / name).read_bytes(),
                             (ROOT / "PersonalIslandApp/Resources" / name).read_bytes())

    def test_exact_application_and_shared_core_sources_are_explicit(self):
        self.assertEqual(set(self.phase_files(self.target("PersonalIsland"), "PBXSourcesBuildPhase")), {
            "PersonalIslandApp.swift", "IslandCoordinator.swift", "IslandPanelController.swift",
            "IslandGeometry.swift", "IslandView.swift", "SettingsView.swift", "NotchShape.swift",
            "IslandPresentation.swift", "CaptureGeometry.swift", "CaptureFlow.swift", "GlobalHotKey.swift",
            "RegionSelector.swift", "ScreenRegionCapture.swift",
        })
        self.assertEqual(set(self.phase_files(self.target("PersonalIslandCore"), "PBXSourcesBuildPhase")), {
            "Models.swift", "OwnedExportDirectory.swift", "ShelfStore.swift",
        })
        core_groups = [value for value in self.objects.values() if value.get("path") == "../PersonalIslandCore/Sources/PersonalIslandCore"]
        self.assertEqual(len(core_groups), 1)

    def test_no_remote_packages_executable_copy_phases_or_automatic_membership(self):
        forbidden = {"XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency", "PBXShellScriptBuildPhase",
                     "PBXCopyFilesBuildPhase", "PBXFileSystemSynchronizedRootGroup"}
        self.assertFalse(forbidden.intersection(value["isa"] for value in self.objects.values()))
        project = self.objects[self.graph["rootObject"]]
        self.assertEqual(project["isa"], "PBXProject")
        self.assertFalse(project.get("packageReferences"))
        for name in ("PersonalIsland", "PersonalIslandCore"):
            self.assertFalse(self.target(name).get("packageProductDependencies"))
            self.assertEqual({self.objects[key]["isa"] for key in self.target(name)["buildPhases"]},
                             {"PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"})

    def test_app_depends_on_static_local_core_without_embedding_it(self):
        app = self.target("PersonalIsland")
        core = self.target("PersonalIslandCore")
        self.assertEqual(len(app["dependencies"]), 1)
        dependency = self.objects[app["dependencies"][0]]
        self.assertIs(self.objects[dependency["target"]], core)
        for configuration in self.configurations(core).values():
            self.assertEqual(configuration["MACH_O_TYPE"], "staticlib")
            self.assertEqual(configuration["SKIP_INSTALL"], "YES")
        self.assertEqual(self.phase_files(app, "PBXFrameworksBuildPhase"), ["PersonalIslandCore.framework"])

    def test_release_excludes_debug_entitlement_injection_and_keeps_runtime(self):
        configs = self.configurations(self.target("PersonalIsland"))
        self.assertEqual(configs["Release"]["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO")
        self.assertEqual(configs["Debug"]["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "YES")
        for config in configs.values():
            self.assertEqual(config["ENABLE_HARDENED_RUNTIME"], "YES")
            self.assertEqual(config["CODE_SIGN_IDENTITY"], "-")
            self.assertEqual(config["DEVELOPMENT_TEAM"], "")
            for key in ("ENABLE_RESOURCE_ACCESS_CAMERA", "ENABLE_RESOURCE_ACCESS_CONTACTS", "ENABLE_RESOURCE_ACCESS_CALENDARS",
                        "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT", "ENABLE_RESOURCE_ACCESS_LOCATION"):
                self.assertEqual(config[key], "NO")
        self.assertEqual(plistlib.loads((self.app / "PersonalIsland.entitlements").read_bytes()), {})

    def test_only_retained_notices_are_bundle_resources(self):
        self.assertEqual(set(self.phase_files(self.target("PersonalIsland"), "PBXResourcesBuildPhase")), set(app_policy.NOTICE_NAMES))
        self.assertEqual(self.phase_files(self.target("PersonalIslandCore"), "PBXResourcesBuildPhase"), [])

    def test_unreviewed_neighbor_files_are_not_silently_included(self):
        (self.app / "Sources").mkdir()
        (self.app / "Sources/Unreviewed.swift").write_text("unreviewed source fixture")
        (self.app / "Resources/Unexpected.dat").write_bytes(b"unreviewed resource fixture")
        self.generate()
        paths = {value.get("path") for value in self.objects.values() if value["isa"] == "PBXFileReference"}
        self.assertNotIn("Unreviewed.swift", paths)
        self.assertNotIn("Unexpected.dat", paths)

    def test_missing_retained_notice_stops_generation(self):
        (self.app / "Resources" / generator.RESOURCES[0]).unlink()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(FileNotFoundError):
            generator.main()

    def test_generated_plist_has_no_inherited_permissions_or_updater(self):
        info = plistlib.loads((self.app / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")
        self.assertEqual(info["CFBundleExecutable"], "$(EXECUTABLE_NAME)")
        self.assertIs(info["LSUIElement"], True)
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertFalse(set(info) & app_policy.FORBIDDEN_INFO_KEYS)
        self.assertFalse(any(key.startswith("SU") for key in info))

    def test_shared_scheme_has_no_build_pre_or_post_actions(self):
        scheme = ET.parse(self.project / "xcshareddata/xcschemes/PersonalIsland.xcscheme").getroot()
        self.assertIsNone(scheme.find(".//PreActions"))
        self.assertIsNone(scheme.find(".//PostActions"))
        self.assertEqual(scheme.find("LaunchAction").get("buildConfiguration"), "Debug")
        self.assertEqual(scheme.find("ArchiveAction").get("buildConfiguration"), "Release")
        refs = scheme.findall(".//BuildableReference")
        self.assertTrue(refs)
        self.assertTrue(all(value.get("BuildableName") == "PersonalIsland.app" for value in refs))

    def test_generation_is_deterministic(self):
        before = (self.project / "project.pbxproj").read_bytes()
        self.generate()
        self.assertEqual((self.project / "project.pbxproj").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
