#!/usr/bin/env python3
"""Check files eligible for publication, including staged content and commit history."""
import re
import struct
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_PATH = re.compile(rb"(?:/Users/|/home/|[A-Za-z]:\\Users\\)[^/\\\r\n\"'<>|]+")
SECRET = re.compile(
    rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"
    rb"|\bgh[pousr]_[A-Za-z0-9]{20,}"
    rb"|\bgithub_pat_[A-Za-z0-9_]{20,}"
    rb"|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"
)
WORKFLOW = re.compile(
    r"(^|/)(?:\.local|\.agents?|\.codex|\.claude|\.cursor|\.gemini|node_modules|vendor|build|\.build|models|recordings|transcripts)(/|$)"
    r"|(^|/)(?:agents[^/]*|claude\.md|gemini\.md|skill\.md|memory\.md|glossary\.md|issues\.md|context\.md)$",
    re.IGNORECASE,
)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def is_app_icon(data):
    """Only the 1024px RGBA icon is allowed; text, EXIF and other metadata are rejected."""
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > 8 * 1024 * 1024:
        return False
    position = 8
    compressed = bytearray()
    while position + 12 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        end = position + length + 12
        if end > len(data):
            return False
        kind = data[position + 4:position + 8]
        payload = data[position + 8:end - 4]
        if zlib.crc32(kind + payload) != struct.unpack(">I", data[end - 4:end])[0]:
            return False
        if kind == b"IHDR":
            if position != 8 or payload != struct.pack(">IIBBBBB", 1024, 1024, 8, 6, 0, 0, 0):
                return False
        elif kind == b"IDAT" and position > 8:
            compressed.extend(payload)
        elif kind == b"IEND" and not payload and end == len(data) and compressed:
            expected = (1024 * 4 + 1) * 1024
            decoder = zlib.decompressobj()
            try:
                pixels = decoder.decompress(compressed, expected + 1)
            except zlib.error:
                return False
            return len(pixels) == expected and decoder.eof and not decoder.unused_data
        else:
            return False
        position = end
    return False


def check(path, data, mode, location):
    problems = []
    ignored = subprocess.run(
        ["git", "check-ignore", "--no-index", "-q", "--", path], cwd=ROOT,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
    if WORKFLOW.search(path) or ignored:
        problems.append("local-only file")
    if mode == "120000":
        problems.append("symlink requires review")
    if PRIVATE_PATH.search(data):
        problems.append("personal absolute path")
    if SECRET.search(data):
        problems.append("credential or private key")
    if path == "Resources/AppIcon.png":
        if not is_app_icon(data):
            problems.append("app icon must be a metadata-free 1024px RGBA PNG")
    elif b"\x00" in data and mode != "120000":
        problems.append("binary file requires review")
    return [f"{location}: {path}: {problem}" for problem in problems]


def main():
    errors = []
    files = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    for entry in files:
        if not entry:
            continue
        path = entry.decode()
        file = ROOT / path
        if file.exists() or file.is_symlink():
            if file.is_symlink():
                errors += check(path, b"", "120000", "working tree")
            else:
                errors += check(path, file.read_bytes(), "100644", "working tree")
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, oid, _ = metadata.decode().split()
        errors += check(path.decode(), git("cat-file", "blob", oid), mode, "index")
    refs = git("for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags").decode().splitlines()
    if subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=ROOT,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        refs.append("HEAD")
    seen = set()
    for commit in git("rev-list", *refs).decode().splitlines() if refs else []:
        for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
            if not entry:
                continue
            metadata, path = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            key = (mode, oid, path)
            if key in seen:
                continue
            seen.add(key)
            if kind != "blob":
                errors.append(f"history: {path.decode()}: external checkout requires review")
            else:
                errors += check(path.decode(), git("cat-file", "blob", oid), mode, "history")
    if errors:
        print("\n".join(sorted(set(errors))), file=sys.stderr)
        return 1
    print("Source check passed: working tree, index and local branch/tag history.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
