"""Run the project's automated checks without starting the graphical app."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build/verification"
RECEIPT = ROOT / "implementation/TEST_RUN_RECEIPT.json"


def execute(name, command, env=None):
    print("Checking " + name + "…", flush=True)
    completed = subprocess.run(command, cwd=ROOT, env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUTPUT / (name + ".log")).write_text(completed.stdout)
    if completed.returncode:
        print("\n".join(completed.stdout.splitlines()[-70:]), flush=True)
        raise RuntimeError(name + " failed; see build/verification/" + name + ".log")
    return completed.stdout


def checked_repo_path(path):
    """Reject path aliases before reading immutable inputs or deleting outputs."""
    root = ROOT.resolve()
    absolute = Path(os.path.abspath(path))
    if not absolute.is_relative_to(root):
        raise RuntimeError("Verification path is outside this checkout: " + str(path))
    current = root
    for part in absolute.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            raise RuntimeError("Verification refuses symlink path: " + str(current.relative_to(root)))
    return absolute


def coverage_directories(scratch):
    scratch = checked_repo_path(scratch)
    output = checked_repo_path(OUTPUT)
    if not scratch.is_relative_to(output) or scratch == output:
        raise RuntimeError("Coverage scratch directory is outside owned verification output")
    if not scratch.exists():
        return []
    if not scratch.is_dir():
        raise RuntimeError("Coverage scratch path is not a directory")
    found = []
    for directory, names, files in os.walk(scratch, followlinks=False):
        current = Path(directory)
        for name in list(names):
            child = current / name
            if child.is_symlink():
                if name == "codecov" or current.name == "codecov":
                    raise RuntimeError("Coverage directory contains a symlink: " + str(child))
                # SwiftPM's debug -> architecture/debug alias must not be
                # traversed a second time or followed outside this scratch.
                names.remove(name)
        if current.name == "codecov":
            checked_repo_path(current)
            for name in files:
                if (current / name).is_symlink():
                    raise RuntimeError("Coverage artifact is a symlink: " + str(current / name))
            found.append(current)
    return sorted(found)


def clear_coverage_artifacts(scratch):
    """Remove only disposable coverage files, preserving compilation caches."""
    artifacts = []
    for directory in coverage_directories(scratch):
        for path in directory.iterdir():
            if path.suffix not in {".json", ".profraw", ".profdata"}:
                continue
            if not stat.S_ISREG(path.lstat().st_mode):
                raise RuntimeError("Coverage artifact is not an ordinary file: " + str(path))
            artifacts.append(path)
    # Validate every candidate before deleting any, so a bad later entry cannot
    # partially clear an otherwise suspect directory tree.
    for path in artifacts:
        path.unlink()


def coverage_report(scratch, expected_package):
    reports = sorted(path for directory in coverage_directories(scratch)
                     for path in directory.glob("*.json"))
    if len(reports) != 1 or reports[0].name != expected_package + ".json":
        raise RuntimeError("Expected one fresh " + expected_package + " coverage report")
    report = reports[0]
    if not stat.S_ISREG(report.lstat().st_mode):
        raise RuntimeError("Coverage report is not an ordinary file")
    source_folder = ROOT / ("PersonalIslandCore/Sources" if expected_package == "PersonalIslandCore"
                            else "PersonalIslandApp/Sources")
    covered_files = {}
    document = json.loads(report.read_text())
    for segment in document.get("data", []):
        for item in segment.get("files", []):
            path = Path(os.path.abspath(item["filename"]))
            if not path.is_relative_to(source_folder):
                continue
            path = checked_repo_path(path)
            if not path.is_file():
                raise RuntimeError("Coverage references missing production source: " + str(path))
            name = str(path.relative_to(ROOT))
            if name in covered_files:
                raise RuntimeError("Duplicate production-file coverage summary: " + name)
            if not isinstance(item.get("summary"), dict):
                raise RuntimeError("Missing production-file coverage summary: " + name)
            covered_files[name] = item["summary"]
    if not covered_files:
        raise RuntimeError("Swift tests produced no coverage report for production source")
    return covered_files


def immutable_inputs():
    """Inventory inputs, excluding generated project/plist/cache/receipt files."""
    files = set()
    ignored_directories = {"__pycache__", ".pytest_cache", ".build", ".swiftpm", ".cache", ".test-output"}
    folders = (
        "PersonalIslandApp/Sources", "PersonalIslandApp/Resources", "PersonalIslandCore/Sources",
        "PersonalIslandCore/Tests", "Tests", ".github",
    )
    for folder in folders:
        base = checked_repo_path(ROOT / folder)
        if not base.exists():
            continue
        if not base.is_dir():
            raise RuntimeError("Verification input tree is not a directory: " + str(base))
        for directory, names, file_names in os.walk(base, followlinks=False):
            names[:] = sorted(name for name in names if name not in ignored_directories)
            for name in names:
                checked_repo_path(Path(directory) / name)
            for name in file_names:
                if name == ".DS_Store" or name.endswith((".pyc", ".pyo")):
                    continue
                files.add(checked_repo_path(Path(directory) / name))
    required = ("Package.swift", "PersonalIslandCore/Package.swift", "implementation/APP_SOURCE_PROVENANCE.json")
    files.update(checked_repo_path(ROOT / name) for name in required)
    for name in ("Package.resolved", "PersonalIslandCore/Package.resolved"):
        candidate = checked_repo_path(ROOT / name)
        if candidate.exists():
            files.add(candidate)
    files.update(checked_repo_path(path) for path in (ROOT / "implementation").glob("*.py"))
    hashes = {}
    for path in sorted(files):
        if not stat.S_ISREG(path.lstat().st_mode):
            raise RuntimeError("Verification input is not an ordinary file: " + str(path))
        hashes[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def require_unchanged_inputs(before):
    after = immutable_inputs()
    if before != after:
        changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
        raise RuntimeError("Verification inputs changed during checks: " + ", ".join(changed[:6]))


def passing_test_count(output, framework):
    pattern = r"Ran (\d+) tests? in" if framework == "Python" else r"Test run with (\d+) tests\b[^\n]*passed"
    matches = re.findall(pattern, output)
    if len(matches) != 1 or int(matches[0]) == 0:
        raise RuntimeError(framework + " test discovery did not report one nonzero passing test run")
    return int(matches[0])


def verify_provenance():
    document = json.loads((ROOT / "implementation/APP_SOURCE_PROVENANCE.json").read_text())
    actual = {str(path.relative_to(ROOT)) for folder in (
        "PersonalIslandCore/Sources/PersonalIslandCore", "PersonalIslandApp/Sources"
    ) for path in (ROOT / folder).glob("*.swift")}
    if actual != {item["local_path"] for item in document["files"]}:
        raise RuntimeError("Source provenance does not cover the current app/core source list")
    for item in document["files"]:
        digest = hashlib.sha256((ROOT / item["local_path"]).read_bytes()).hexdigest()
        if digest != item["local_sha256"]:
            raise RuntimeError("Update reviewed source provenance for " + item["local_path"])
    for item in document["retained_upstream_notices"]:
        digest = hashlib.sha256((ROOT / item["local_path"]).read_bytes()).hexdigest()
        if digest != item["sha256"]:
            raise RuntimeError("Retained upstream notice changed: " + item["local_path"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy-only", action="store_true", help="Run Python policy checks without Swift/Xcode")
    args = parser.parse_args()
    RECEIPT.unlink(missing_ok=True)
    results = {"status": "running", "mode": "policy-only" if args.policy_only else "full",
               "started_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "app_launched": False, "stages": {}}
    try:
        checked_repo_path(OUTPUT).mkdir(parents=True, exist_ok=True)
        inputs = immutable_inputs()
        results["input_sha256"] = inputs
        verify_provenance()
        python_output = execute("build-policy", [sys.executable, "-m", "unittest", "discover",
            "-s", "Tests/Python", "-p", "test_*.py", "-v"])
        results["stages"]["build_policy"] = {"passed": passing_test_count(python_output, "Python")}
        if not args.policy_only:
            if sys.platform != "darwin":
                raise RuntimeError("The full checks require macOS with Xcode; use --policy-only on other systems")
            for name, package, expected_package in (
                ("storage", ROOT / "PersonalIslandCore", "PersonalIslandCore"),
                ("presentation", ROOT, "PersonalIslandPresentation"),
            ):
                scratch = OUTPUT / name
                cache = OUTPUT / (name + "-cache")
                clear_coverage_artifacts(scratch)
                for folder in (cache / "clang", cache / "swift"):
                    folder.mkdir(parents=True, exist_ok=True)
                environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache / "clang"),
                                   SWIFT_MODULECACHE_PATH=str(cache / "swift"))
                output = execute(name, ["/usr/bin/xcrun", "swift", "test", "--package-path", str(package),
                    "--disable-sandbox", "--enable-code-coverage", "--scratch-path", str(scratch),
                    "--cache-path", str(cache / "spm"), "--config-path", str(cache / "config"),
                    "--security-path", str(cache / "security"),
                    "-Xswiftc", "-module-cache-path", "-Xswiftc", str(cache / "swift")], environment)
                results["stages"][name] = {"passed": passing_test_count(output, "Swift"),
                    "coverage": coverage_report(scratch, expected_package)}
            execute("release-app", [sys.executable, "implementation/build_app.py"])
            results["stages"]["release_app"] = {"build_and_bundle_policy": "passed"}
        require_unchanged_inputs(inputs)
        results["status"] = "passed"
    except Exception as error:
        results["status"] = "failed"
        results["error"] = str(error)
        print(str(error), file=sys.stderr)
    results["finished_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    RECEIPT.write_text(json.dumps(results, indent=2) + "\n")
    if results["status"] == "passed":
        counts = [str(result["passed"]) + " " + name for name, result in results["stages"].items() if "passed" in result]
        print("Passed: " + ", ".join(counts) + ("; Release build and bundle checks." if not args.policy_only else "."))
    return 0 if results["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
