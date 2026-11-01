#!/usr/bin/env python3
"""Check files eligible for publication, including staged content and commit history."""
import re
import subprocess
import sys
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
    if b"\x00" in data and mode != "120000":
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
