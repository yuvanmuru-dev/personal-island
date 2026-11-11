"""Acquire pinned repository text for static review. Never execute repository code."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path, PurePosixPath
import hashlib
import io
import json
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent / "sources"
REPOSITORIES = (
    ("atoll", "Ebullioscopic/Atoll", "b8d86a2d8118d905ffa3e2c912adc736683741bb"),
    ("dynamicnotch", "jackson-storm/DynamicNotch", "f8623de5806ec5a22d9845189360bc9f4d92c374"),
)
TEXT_SUFFIXES = {
    ".swift", ".h", ".m", ".mm", ".c", ".cpp", ".hpp", ".plist",
    ".entitlements", ".sh", ".bash", ".zsh", ".js", ".ts", ".py",
    ".rb", ".pl", ".pm", ".sdef", ".xcconfig", ".yml", ".yaml",
    ".toml", ".xml", ".md", ".txt", ".resolved", ".pbxproj",
    ".xcworkspacedata", ".json", ".strings", ".xcstrings", ".xcscheme",
}


def acquire(spec):
    key, repository, revision = spec
    # Use macOS curl's certificate trust; do not bypass TLS verification.
    response = subprocess.run([
        "/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
        "--proto", "=https", "--tlsv1.2", "--max-time", "90",
        "--max-filesize", str(120 * 1024 * 1024),
        f"https://codeload.github.com/{repository}/zip/{revision}",
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    archive_bytes = response.stdout
    if len(archive_bytes) > 120 * 1024 * 1024:
        raise ValueError("Archive exceeds review download limit")
    destination = ROOT / key
    destination.mkdir(parents=True, exist_ok=True)
    extracted, skipped = [], []
    total_size = 0
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        for member in archive.infolist():
            if member.is_dir():
                continue
            path_parts = PurePosixPath(member.filename).parts
            if len(path_parts) < 2 or any(p in {"..", "."} for p in path_parts):
                raise ValueError(f"Unexpected archive path: {member.filename}")
            relative = PurePosixPath(*path_parts[1:])
            if relative.is_absolute() or "\\" in str(relative):
                raise ValueError(f"Unsafe archive path: {relative}")
            mode = member.external_attr >> 16
            entry = {"path": str(relative), "size": member.file_size}
            if stat.S_ISLNK(mode):
                skipped.append({**entry, "reason": "symlink-not-followed"})
                continue
            if relative.suffix.lower() not in TEXT_SUFFIXES and relative.name not in {
                "LICENSE", "NOTICE", "COPYRIGHT_ASSETS", "TRADEMARKS", "Makefile",
                "Dockerfile", "PrivacyInfo.xcprivacy", ".gitmodules", ".gitignore",
            }:
                skipped.append({**entry, "reason": "non-text-or-unselected-type"})
                continue
            if member.file_size > 8 * 1024 * 1024:
                skipped.append({**entry, "reason": "individual-file-size-limit"})
                continue
            data = archive.read(member)
            try:
                data.decode("utf-8")
            except UnicodeDecodeError:
                skipped.append({**entry, "reason": "non-UTF8"})
                continue
            total_size += len(data)
            if total_size > 80 * 1024 * 1024:
                raise ValueError("Expanded text exceeds review limit")
            output = destination.joinpath(*relative.parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            output.chmod(0o644)
            extracted.append({**entry, "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {
        "repository": repository,
        "revision": revision,
        "review_date": "2026-11-10",
        "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
        "text_files": extracted,
        "skipped_files": skipped,
        "limits": "Source-text snapshot only. Binaries and symlinks are not analyzed or executed.",
    }
    (ROOT / f"{key}-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"repository": repository, "revision": revision,
            "text_files": len(extracted), "text_bytes": total_size,
            "skipped_files": len(skipped)}


if __name__ == "__main__":
    ROOT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=2) as executor:
        for result in executor.map(acquire, REPOSITORIES):
            print(json.dumps(result), flush=True)
