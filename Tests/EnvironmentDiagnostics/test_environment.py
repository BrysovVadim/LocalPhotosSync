import importlib.util
import pathlib
import plistlib
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "diagnose-environment.py"
SPEC = importlib.util.spec_from_file_location("diagnose_environment", SCRIPT)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


class BonjourParsingTests(unittest.TestCase):
    def test_duplicate_add_then_remove_with_different_flags(self):
        lines = [
            "15:00:00.000 Add 3 2 local. _apple-mobdev2._tcp. Private iPhone Name",
            "15:00:00.100 Add 3 2 local. _apple-mobdev2._tcp. Private iPhone Name",
            "15:00:00.300 Rmv 0 2 local. _apple-mobdev2._tcp. Private iPhone Name",
        ]
        self.assertEqual(module.parse_bonjour_events(lines), 0)

    def test_same_instance_remains_active_on_another_interface(self):
        lines = [
            "15:00:00.000 Add 3 2 local. _apple-mobdev2._tcp. Private iPhone Name",
            "15:00:00.200 Add 4 3 local. _apple-mobdev2._tcp. Private iPhone Name",
            "15:00:00.300 Rmv 0 2 local. _apple-mobdev2._tcp. Private iPhone Name",
        ]
        self.assertEqual(module.parse_bonjour_events(lines), 1)

    def test_ignores_other_services_and_malformed_lines(self):
        lines = [
            "Browsing for _apple-mobdev2._tcp. local.",
            "Add local. _http._tcp. unrelated",
            "15:00:00.000 Add 3 2 local. _apple-mobdev2._tcp.",
            "15:00:00.100 Rmv 0 2 local. _apple-mobdev2._tcp. never-added",
        ]
        self.assertEqual(module.parse_bonjour_events(lines), 0)

    def test_usb_parser_counts_recognizable_products_not_host_classes(self):
        tree = {
            "IORegistryEntryName": "IOUSBHostDevice",
            "USB Product Name": "iPhone 17 Pro",
            "USB Serial Number": "PRIVATE-SERIAL",
            "children": [{"IORegistryEntryName": "AppleUSBHostDevice", "kUSBProductString": "iPad Air"}],
        }
        self.assertEqual(module.count_usb_ios_products(plistlib.dumps(tree)), 2)

    def test_usb_parser_ignores_generic_apple_peripherals(self):
        tree = {"USB Product Name": "Apple Keyboard", "children": [{"USB Product Name": "Magic Mouse"}]}
        self.assertEqual(module.count_usb_ios_products(plistlib.dumps(tree)), 0)

    def test_usb_parser_returns_zero_when_no_products_are_present(self):
        self.assertEqual(module.count_usb_ios_products(plistlib.dumps({})), 0)

    def test_usb_parser_rejects_malformed_plist(self):
        with self.assertRaisesRegex(ValueError, "malformed ioreg plist"):
            module.count_usb_ios_products(b"<not a plist>")

    def test_usb_command_returns_null_on_malformed_plist(self):
        completed = mock.Mock(returncode=0, stdout="malformed")
        with mock.patch.object(module.subprocess, "run", return_value=completed):
            self.assertEqual(module._run_ioreg("/usr/sbin/ioreg", 5), (None, "error"))

    def test_timeout_status_discards_raw_output(self):
        with mock.patch.object(module.subprocess, "run", side_effect=module.subprocess.TimeoutExpired("ioreg", 5)):
            self.assertEqual(module._run_ioreg("/usr/sbin/ioreg", 5), (None, "timeout"))
        with mock.patch.object(module.subprocess, "Popen", side_effect=FileNotFoundError("private output")):
            self.assertEqual(module._run_bonjour("/usr/bin/dns-sd", 1), (None, "error"))

    def test_bonjour_timeout_keeps_partial_count_and_suppresses_output(self):
        class TimedOutBrowse:
            def __init__(self):
                self.calls = 0

            def communicate(self, timeout):
                self.calls += 1
                if self.calls == 1:
                    raise module.subprocess.TimeoutExpired("dns-sd", timeout)
                return ("15:00:00.000 Add 3 2 local. _apple-mobdev2._tcp. Secret Name", "")

            def terminate(self):
                pass

            def poll(self):
                return None

        with mock.patch.object(module.subprocess, "Popen", return_value=TimedOutBrowse()):
            self.assertEqual(module._run_bonjour("/usr/bin/dns-sd", 1), (1, "window_complete"))

    def test_bonjour_nonzero_early_exit_is_error(self):
        class FailedBrowse:
            returncode = 1

            def communicate(self, timeout):
                return ("15:00:00.000 Add 3 2 local. _apple-mobdev2._tcp. Secret Name", "")

        with mock.patch.object(module.subprocess, "Popen", return_value=FailedBrowse()):
            self.assertEqual(module._run_bonjour("/usr/bin/dns-sd", 1), (None, "error"))

    def test_report_contains_aggregate_data_not_raw_device_names(self):
        with (
            mock.patch.object(module.platform, "system", return_value="Darwin"),
            mock.patch.object(module.platform, "mac_ver", return_value=("15.0", ())),
            mock.patch.object(module.shutil, "which", side_effect=lambda tool: f"/usr/bin/{tool}"),
            mock.patch.object(module, "_run_ioreg", return_value=(2, "ok")),
            mock.patch.object(module, "_run_bonjour", return_value=(1, "window_complete")),
        ):
            import json
            rendered = json.dumps(module.diagnose())
        for private_value in ("UDID", "SerialNumber", "AA:BB:CC:DD:EE:FF", "Private iPhone Name", "192.0.2.1"):
            self.assertNotIn(private_value, rendered)
        self.assertIn('"count": 1', rendered)
        self.assertNotIn("stdout", rendered)

    def test_parsed_usb_names_and_serials_never_enter_output(self):
        raw_plist = plistlib.dumps({"USB Product Name": "Secret iPhone Name", "USB Serial Number": "PRIVATE-SERIAL"}).decode()
        completed = mock.Mock(returncode=0, stdout=raw_plist)
        with (
            mock.patch.object(module.platform, "system", return_value="Darwin"),
            mock.patch.object(module.platform, "mac_ver", return_value=("15.0", ())),
            mock.patch.object(module.shutil, "which", side_effect=lambda tool: f"/usr/bin/{tool}"),
            mock.patch.object(module.subprocess, "run", return_value=completed),
            mock.patch.object(module, "_run_bonjour", return_value=(0, "ok")),
        ):
            import json
            rendered = json.dumps(module.diagnose())
        self.assertIn('"count": 1', rendered)
        self.assertNotIn("Secret iPhone Name", rendered)
        self.assertNotIn("PRIVATE-SERIAL", rendered)


if __name__ == "__main__":
    unittest.main()
