import importlib.util
import io
import struct
import subprocess
import tempfile
import unittest
import zlib
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("source_check", Path(__file__).parents[1] / "check-source.py")
source_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_check)


class SourceCheckTests(unittest.TestCase):
    @staticmethod
    def png_chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    @classmethod
    def icon_png(cls):
        return (b"\x89PNG\r\n\x1a\n"
                + cls.png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 6, 0, 0, 0))
                + cls.png_chunk(b"IDAT", zlib.compress(bytes((1024 * 4 + 1) * 1024)))
                + cls.png_chunk(b"IEND", b""))

    def test_only_the_reviewed_icon_path_accepts_png(self):
        icon = self.icon_png()
        self.assertEqual(source_check.check("Resources/AppIcon.png", icon, "100644", "test"), [])
        self.assertTrue(source_check.check("Resources/Other.png", icon, "100644", "test"))

    def test_icon_metadata_is_rejected(self):
        icon = self.icon_png()
        for kind in [b"tEXt", b"iTXt", b"eXIf"]:
            data = icon[:-12] + self.png_chunk(kind, b"metadata") + icon[-12:]
            self.assertFalse(source_check.is_app_icon(data))

    def test_icon_malformed_or_trailing_data_is_rejected(self):
        icon = self.icon_png()
        for data in [icon[:-1], icon + b"trailing", icon[:29] + b"bad!" + icon[33:], b"not an icon"]:
            self.assertFalse(source_check.is_app_icon(data))

    def test_plain_source_and_urls_are_allowed(self):
        self.assertEqual(source_check.check("Sources/App.swift", b"let x = 1", "100644", "test"), [])

    def test_personal_path_is_detected(self):
        data = b"path=" + b"/Users" + b"/example/private"
        self.assertTrue(source_check.check("Sources/App.swift", data, "100644", "test"))

    def test_unicode_and_space_in_private_paths_are_detected(self):
        for prefix in [b"/Users", b"/home", b"C:\\Users"]:
            separator = b"\\" if prefix.startswith(b"C:") else b"/"
            data = prefix + separator + "Пользователь с пробелами".encode()
            self.assertTrue(source_check.PRIVATE_PATH.search(data))

    def test_private_key_formats_and_modern_tokens_are_detected(self):
        for label in ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY", "OPENSSH PRIVATE KEY", "ENCRYPTED PRIVATE KEY"]:
            data = ("-----BEGIN " + label + "-----").encode()
            self.assertTrue(source_check.SECRET.search(data))
        self.assertTrue(source_check.SECRET.search(b"github_pat_" + b"a" * 40))

    def test_links_binary_and_workflow_files_are_rejected(self):
        for path, data, mode in [
            ("link", b"target", "120000"),
            ("file", b"\0binary", "100644"),
            (".local/notes.md", b"notes", "100644"),
        ]:
            self.assertTrue(source_check.check(path, data, mode, "test"))

    def test_staged_and_historical_content_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
                               cwd=root, check=True, capture_output=True)
            git("init", "-b", "main")
            source = root / "App.swift"
            source.write_bytes(b"let path = " + b"/Users" + b"/example/private")
            git("add", "App.swift")
            source.write_text("let safe = true")
            with patch.object(source_check, "ROOT", root), redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
                self.assertEqual(source_check.main(), 1)
            git("-c", "user.name=Example", "-c", "user.email=example@example.invalid", "commit", "-m", "fixture")
            git("add", "App.swift")
            git("-c", "user.name=Example", "-c", "user.email=example@example.invalid", "commit", "-m", "replace fixture")
            with patch.object(source_check, "ROOT", root), redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
                self.assertEqual(source_check.main(), 1)


if __name__ == "__main__":
    unittest.main()
