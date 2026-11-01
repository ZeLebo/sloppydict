import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class KeyboardSafetyTests(unittest.TestCase):
    def test_app_does_not_install_or_rearm_a_filtering_event_tap(self):
        for path in (ROOT / 'Sources').rglob('*.swift'):
            source = path.read_text()
            self.assertNotRegex(source, r'CGEvent\s*\.\s*(tapCreate|tapEnable)\s*\(', str(path.relative_to(ROOT)))

    def test_live_window_checks_are_not_an_app_entrypoint(self):
        source = (ROOT / 'Sources/SloppyDict/SloppyDictApp.swift').read_text()
        self.assertNotIn('--check-hud', source)
        self.assertNotIn('--render-preview', source)
        self.assertNotIn('--render-hud-preview', source)

    def test_no_global_raw_keyboard_monitor_is_installed(self):
        for path in (ROOT / 'Sources').rglob('*.swift'):
            self.assertNotRegex(path.read_text(), r'NSEvent\s*\.\s*addGlobalMonitorForEvents', str(path.relative_to(ROOT)))

    def test_default_tests_do_not_use_native_clipboard(self):
        makefile = (ROOT / 'Makefile').read_text()
        target = re.search(r'(?ms)^test:\n(.*?)(?=^\S|\Z)', makefile).group(1)
        self.assertNotIn('delivery-checks', target)
        self.assertNotIn('SloppyDict.app', target)


if __name__ == '__main__':
    unittest.main()
