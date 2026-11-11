"""Failure-path receipts and input stability, with every subprocess mocked."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "implementation"))
import build_app


class BuildFailureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "implementation").mkdir()
        self.receipt = self.root / "implementation/APP_BUILD_RECEIPT.json"
        self.receipt.write_text('{"build":"passed","fixture":"old"}')
        patching = patch.multiple(build_app, ROOT=self.root, BUILD=self.root / "build")
        patching.start()
        self.addCleanup(patching.stop)

    def fixture_inputs(self):
        for name in build_app.APP_FILES:
            path = self.root / "PersonalIslandApp/Sources" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// synthetic compile input; never compiled")
        paths = [
            "PersonalIslandApp/PersonalIsland.xcodeproj/project.pbxproj",
            "PersonalIslandApp/PersonalIsland.xcodeproj/xcshareddata/xcschemes/PersonalIsland.xcscheme",
            "PersonalIslandApp/Info.plist", "PersonalIslandApp/PersonalIsland.entitlements",
            "implementation/generate_app_project.py", "implementation/app_policy.py",
        ]
        for name in paths:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic input")

    def test_generator_failure_removes_old_success_without_running_xcode(self):
        with patch.object(build_app, "run", return_value=subprocess.CompletedProcess([], 9, stdout="fixture generation failure")) as run:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(build_app.main(), 9)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(run.call_count, 1)
        self.assertNotIn("xcodebuild", str(run.call_args))

    def test_missing_new_source_stops_before_build_and_invalidates_receipt(self):
        self.fixture_inputs()
        (self.root / "PersonalIslandApp/Sources/IslandPresentation.swift").unlink()
        with patch.object(build_app, "run", return_value=subprocess.CompletedProcess([], 0, stdout="")) as run:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(build_app.main(), 1)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(run.call_count, 1)

    def test_failed_compile_writes_log_but_never_leaves_success_receipt(self):
        self.fixture_inputs()
        # The script itself is a real hashed input; use its path within the fixture.
        script = self.root / "implementation/build_app.py"
        script.write_text("synthetic build script fixture")
        results = [subprocess.CompletedProcess([], 0, stdout=""), subprocess.CompletedProcess([], 1, stdout="error: synthetic compile failure")]
        with patch.object(build_app, "__file__", str(script)), patch.object(build_app, "run", side_effect=results) as run:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(build_app.main(), 1)
        self.assertFalse(self.receipt.exists())
        self.assertEqual((self.root / "build/app-build.log").read_text(), "error: synthetic compile failure")
        self.assertEqual(run.call_count, 2)

    def test_changed_compile_input_cannot_receive_success_receipt(self):
        self.fixture_inputs()
        script = self.root / "implementation/build_app.py"
        script.write_text("synthetic build script fixture")
        calls = []

        def simulated_process(arguments):
            calls.append(arguments)
            if "/usr/bin/xcodebuild" in arguments:
                (self.root / "PersonalIslandApp/Sources/IslandView.swift").write_text("changed during compilation")
            return subprocess.CompletedProcess([], 0, stdout="")

        with patch.object(build_app, "__file__", str(script)), patch.object(build_app, "run", side_effect=simulated_process):
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "inputs changed"):
                build_app.main()
        self.assertFalse(self.receipt.exists())
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
