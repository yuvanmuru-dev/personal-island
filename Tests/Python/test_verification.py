"""Verifier evidence boundaries, with every test/build subprocess mocked."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "implementation"))
import verify


class VerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.output = self.root / "build/verification"
        self.receipt = self.root / "implementation/TEST_RUN_RECEIPT.json"
        fixtures = {
            "Package.swift": "// presentation package fixture",
            "PersonalIslandCore/Package.swift": "// storage package fixture",
            "implementation/APP_SOURCE_PROVENANCE.json": "{}",
            "implementation/verify.py": "# immutable verifier fixture",
            "implementation/build_app.py": "# immutable build fixture",
            "PersonalIslandCore/Sources/PersonalIslandCore/Store.swift": "// core fixture",
            "PersonalIslandApp/Sources/Geometry.swift": "// presentation fixture",
            "PersonalIslandCore/Tests/CoreTests.swift": "// core test fixture",
            "Tests/PresentationTests.swift": "// presentation test fixture",
            "Tests/Python/test_policy.py": "# policy test fixture",
            "PersonalIslandApp/Resources/Notice.txt": "retained notice fixture",
            ".github/workflows/verify.yml": "# CI fixture",
        }
        for name, content in fixtures.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.receipt.write_text('{"status":"passed","fixture":"old success"}')
        patching = patch.multiple(verify, ROOT=self.root, OUTPUT=self.output, RECEIPT=self.receipt)
        patching.start()
        self.addCleanup(patching.stop)

    def codecov(self, stage="storage", extra="out/Products/Debug"):
        directory = self.output / stage / extra / "codecov"
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    def write_report(self, stage="storage", *, duplicate=False, extra="out/Products/Debug"):
        package, source = (
            ("PersonalIslandCore", "PersonalIslandCore/Sources/PersonalIslandCore/Store.swift")
            if stage == "storage" else
            ("PersonalIslandPresentation", "PersonalIslandApp/Sources/Geometry.swift")
        )
        item = {"filename": str(self.root / source), "summary": {"lines": {"count": 10, "covered": 9, "percent": 90}}}
        document = {"data": [{"files": [item, item] if duplicate else [item]}]}
        path = self.codecov(stage, extra) / (package + ".json")
        path.write_text(json.dumps(document))
        return path

    def run_main(self, execute, *, policy_only=False):
        argv = ["verify.py"] + (["--policy-only"] if policy_only else [])
        with patch.object(verify, "verify_provenance"), patch.object(verify, "execute", side_effect=execute), \
             patch.object(sys, "argv", argv), patch.object(sys, "platform", "darwin"), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = verify.main()
        return status, json.loads(self.receipt.read_text())

    def successful_execute(self, name, command, env=None):
        if name == "build-policy":
            return "Ran 7 tests in 0.01s\nOK\n"
        if name in {"storage", "presentation"}:
            self.write_report(name)
            count = 3 if name == "storage" else 4
            return f"Test run with {count} tests in 0 suites passed after 0.01 seconds.\n"
        if name == "release-app":
            return "Built and inspected synthetic app fixture; no real build occurred.\n"
        self.fail("Unexpected stage: " + name)

    def test_clears_only_generated_coverage_and_retains_build_cache(self):
        directory = self.codecov()
        artifacts = [directory / name for name in ("old.json", "run.profraw", "default.profdata")]
        for path in artifacts:
            path.write_text("stale coverage fixture")
        preserved = [directory / "README.txt", directory.parent / "Module.o"]
        for path in preserved:
            path.write_text("preserve build cache fixture")
        verify.clear_coverage_artifacts(self.output / "storage")
        self.assertTrue(all(not path.exists() for path in artifacts))
        self.assertTrue(all(path.read_text() == "preserve build cache fixture" for path in preserved))

    def test_stale_report_cannot_satisfy_a_later_missing_coverage_run(self):
        old_report = self.write_report()

        def no_new_coverage(name, command, env=None):
            if name == "build-policy": return "Ran 7 tests in 0.01s\nOK\n"
            if name == "storage":
                self.assertFalse(old_report.exists())
                return "Test run with 3 tests passed after 0.01 seconds.\n"
            self.fail("Verifier proceeded after missing storage coverage")

        status, receipt = self.run_main(no_new_coverage)
        self.assertEqual(status, 1)
        self.assertEqual(receipt["status"], "failed")
        self.assertNotIn("fixture", receipt)
        self.assertIn("fresh PersonalIslandCore coverage", receipt["error"])

    def test_rejects_duplicate_production_file_summaries(self):
        self.write_report(duplicate=True)
        with self.assertRaisesRegex(RuntimeError, "Duplicate production-file"):
            verify.coverage_report(self.output / "storage", "PersonalIslandCore")

    def test_rejects_multiple_resolved_package_reports(self):
        self.write_report()
        self.write_report(extra="old-toolchain/debug")
        with self.assertRaisesRegex(RuntimeError, "one fresh"):
            verify.coverage_report(self.output / "storage", "PersonalIslandCore")

    def test_requires_expected_package_report(self):
        report = self.write_report()
        report.rename(report.with_name("WrongPackage.json"))
        with self.assertRaisesRegex(RuntimeError, "one fresh PersonalIslandCore"):
            verify.coverage_report(self.output / "storage", "PersonalIslandCore")

    def test_rejects_coverage_symlinks_without_touching_outside_target(self):
        outside = self.root / "outside.json"
        outside.write_text("preserve outside fixture")
        directory = self.codecov()
        link = directory / "PersonalIslandCore.json"
        link.symlink_to(outside)
        for operation in (
            lambda: verify.clear_coverage_artifacts(self.output / "storage"),
            lambda: verify.coverage_report(self.output / "storage", "PersonalIslandCore"),
        ):
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                operation()
        self.assertEqual(outside.read_text(), "preserve outside fixture")
        self.assertTrue(link.is_symlink())

    def test_rejects_codecov_directory_alias_and_outside_scratch(self):
        outside = self.root / "unowned"
        outside.mkdir()
        (outside / "preserve.json").write_text("preserve")
        parent = self.output / "storage/debug"
        parent.mkdir(parents=True)
        (parent / "codecov").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            verify.clear_coverage_artifacts(self.output / "storage")
        with self.assertRaisesRegex(RuntimeError, "outside owned"):
            verify.clear_coverage_artifacts(outside)
        self.assertEqual((outside / "preserve.json").read_text(), "preserve")

    def test_normal_swiftpm_debug_alias_is_not_traversed_twice(self):
        self.write_report(extra="architecture/debug")
        scratch = self.output / "storage"
        (scratch / "debug").symlink_to(scratch / "architecture/debug", target_is_directory=True)
        coverage = verify.coverage_report(scratch, "PersonalIslandCore")
        self.assertEqual(set(coverage), {"PersonalIslandCore/Sources/PersonalIslandCore/Store.swift"})

    def test_source_and_test_mutations_invalidate_input_snapshot(self):
        before = verify.immutable_inputs()
        for name in ("PersonalIslandApp/Sources/Geometry.swift", "Tests/PresentationTests.swift"):
            path = self.root / name
            original = path.read_text()
            path.write_text(original + "\n// changed during checks")
            with self.assertRaisesRegex(RuntimeError, "inputs changed"):
                verify.require_unchanged_inputs(before)
            path.write_text(original)
        verify.require_unchanged_inputs(before)

    def test_input_membership_addition_and_removal_are_detected(self):
        before = verify.immutable_inputs()
        added = self.root / "Tests/NewTests.swift"
        added.write_text("// new test input")
        with self.assertRaisesRegex(RuntimeError, "NewTests.swift"):
            verify.require_unchanged_inputs(before)
        added.unlink()
        removed = self.root / "PersonalIslandApp/Resources/Notice.txt"
        removed.unlink()
        with self.assertRaisesRegex(RuntimeError, "Notice.txt"):
            verify.require_unchanged_inputs(before)

    def test_generated_outputs_and_caches_do_not_invalidate_inputs(self):
        before = verify.immutable_inputs()
        for name in (
            "PersonalIslandApp/Info.plist", "PersonalIslandApp/PersonalIsland.entitlements",
            "PersonalIslandApp/PersonalIsland.xcodeproj/project.pbxproj", "build/generated.log",
            "Tests/Python/__pycache__/test_policy.pyc", "implementation/TEST_RUN_RECEIPT.json",
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("regenerated fixture output")
        verify.require_unchanged_inputs(before)

    def test_midrun_test_change_cannot_record_success_after_release_stage(self):
        calls = []

        def mutate_after_tests(name, command, env=None):
            calls.append(name)
            result = self.successful_execute(name, command, env)
            if name == "release-app":
                (self.root / "Tests/PresentationTests.swift").write_text("// changed while verifying")
            return result

        status, receipt = self.run_main(mutate_after_tests)
        self.assertEqual(status, 1)
        self.assertEqual(receipt["status"], "failed")
        self.assertIn("inputs changed", receipt["error"])
        self.assertEqual(calls, ["build-policy", "storage", "presentation", "release-app"])

    def test_failed_stage_replaces_stale_success_receipt(self):
        def fail(name, command, env=None):
            raise RuntimeError("synthetic test failure")

        status, receipt = self.run_main(fail)
        self.assertEqual(status, 1)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["mode"], "full")
        self.assertEqual(receipt["stages"], {})
        self.assertNotIn("fixture", receipt)

    def test_full_receipt_binds_counts_mode_inputs_and_utc_times(self):
        status, receipt = self.run_main(self.successful_execute)
        self.assertEqual(status, 0)
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(receipt["mode"], "full")
        self.assertEqual(receipt["stages"]["build_policy"]["passed"], 7)
        self.assertEqual(receipt["stages"]["storage"]["passed"], 3)
        self.assertEqual(receipt["stages"]["presentation"]["passed"], 4)
        self.assertIn("release_app", receipt["stages"])
        self.assertEqual(receipt["input_sha256"], verify.immutable_inputs())
        self.assertTrue(receipt["started_at_utc"].endswith("+00:00"))
        self.assertTrue(receipt["finished_at_utc"].endswith("+00:00"))
        self.assertFalse(receipt["app_launched"])

    def test_policy_only_receipt_does_not_claim_swift_or_release_checks(self):
        calls = []

        def policy(name, command, env=None):
            calls.append(name)
            return self.successful_execute(name, command, env)

        status, receipt = self.run_main(policy, policy_only=True)
        self.assertEqual(status, 0)
        self.assertEqual(receipt["mode"], "policy-only")
        self.assertEqual(set(receipt["stages"]), {"build_policy"})
        self.assertEqual(calls, ["build-policy"])

    def test_zero_or_ambiguous_runner_counts_cannot_pass(self):
        for output, framework in (
            ("Ran 0 tests in 0.01s", "Python"),
            ("Ran 2 tests in 0.01s\nRan 3 tests in 0.02s", "Python"),
            ("Test run with 0 tests passed", "Swift"),
            ("Test run with 2 tests passed\nTest run with 3 tests passed", "Swift"),
        ):
            with self.subTest(framework=framework, output=output), self.assertRaisesRegex(RuntimeError, "one nonzero"):
                verify.passing_test_count(output, framework)



# Fixture paths are assembled so this file itself never contains them.
HOME = "/" + "Users/" + "someone/"
PERSONAL = "someone" + "@" + "example.com"


class PublishableTextTests(unittest.TestCase):
    def test_home_paths_and_personal_emails_are_reported_with_location(self):
        findings = verify.publishable_text_findings({
            "README.md": "intro\nSee [plan](" + HOME + "Documents/PLAN.md)\n",
            "TESTING.md": "Contact " + PERSONAL + " for access",
        })
        self.assertEqual(findings, ["README.md:2: home-folder path", "TESTING.md:1: email address"])

    def test_relative_links_shared_paths_and_no_reply_addresses_pass(self):
        self.assertEqual(verify.publishable_text_findings({
            "README.md": "[plan](PLAN.md) and [core](../PersonalIslandCore/README.md)",
            "notes.md": "/" + "Users/Shared/ is a system folder; /tmp and /usr/bin are fine",
            "commit.txt": "123+someone" + "@" + "users.noreply.github.com and noreply" + "@" + "anthropic.com",
        }), [])

    def test_third_party_snapshots_and_retained_notices_are_not_rewritten(self):
        self.assertEqual(verify.publishable_text_findings({
            "audit/sources/atoll/ReadMe.md": "maintainer " + PERSONAL,
            "PersonalIslandApp/Resources/Atoll-NOTICE.txt": "Copyright " + PERSONAL,
            "LICENSE": "license text " + PERSONAL,
        }), [])

    def test_lookalike_no_reply_addresses_are_still_reported(self):
        at = "@"
        for address in ("someone" + at + "users.noreply.github.com.evil.example",
                        "noreply" + at + "anthropic.com.example", "x" + at + "noreply.github.com"):
            with self.subTest(address=address):
                self.assertEqual(verify.publishable_text_findings({"a.md": address}), ["a.md:1: email address"])

    def test_new_files_not_yet_added_are_checked_but_ignored_files_are_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            (root / ".gitignore").write_text("local-notes.md\n")
            (root / "local-notes.md").write_text("ignored " + PERSONAL)
            (root / "NewTests.swift").write_text("let url = \"" + PERSONAL + "\"")
            with patch.object(verify, "ROOT", root):
                with self.assertRaises(RuntimeError) as raised:
                    verify.verify_publishable_text()
                self.assertIn("NewTests.swift:1: email address", str(raised.exception))
                self.assertNotIn("local-notes.md", str(raised.exception))
                (root / "NewTests.swift").write_text("let url = \"https://i.scdn.co/image/x\"")
                verify.verify_publishable_text()

    def test_the_current_checkout_is_publishable(self):
        verify.verify_publishable_text()


if __name__ == "__main__":
    unittest.main()
