import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess


RUNNER = Path(__file__).resolve().parents[2] / "experiments" / "afc" / "run-asset-header-probe.py"
SPEC = importlib.util.spec_from_file_location("asset_header_probe", RUNNER)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class AssetHeaderProbeInputTests(unittest.TestCase):
    def test_binding_requires_regular_exact_mode_and_fixed_length_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            binding = folder / "source-binding.bin"
            value = probe.CATALOG.BINDING_MAGIC + bytes(range(64))
            binding.write_bytes(value)
            binding.chmod(0o600)
            self.assertEqual(probe.read_binding(binding), value)

            binding.chmod(0o644)
            self.assertIsNone(probe.read_binding(binding))
            binding.chmod(0o600)
            binding.write_bytes(value[:-1])
            self.assertIsNone(probe.read_binding(binding))

            link = folder / "binding-link"
            link.symlink_to(binding)
            self.assertIsNone(probe.read_binding(link))

    def test_child_json_accepts_only_fixed_bounded_header_result(self):
        valid = {
            "source": "iphone_afc", "status": "asset_header_read", "found": 1,
            "declaredBytes": 1024, "bytesRead": 16, "format": "isobmff",
        }
        self.assertEqual(probe.safe_result(json.dumps(valid)), valid)
        for changes in (
            {"bytesRead": 17}, {"declaredBytes": 0x10000000000000000},
            {"format": "private/path"}, {"assetId": 123}, {"found": True},
        ):
            with self.subTest(changes=changes):
                invalid = dict(valid)
                invalid.update(changes)
                self.assertIsNone(probe.safe_result(json.dumps(invalid)))

    def test_incomplete_header_cannot_be_reported_as_readable(self):
        value = {"source": "iphone_afc", "status": "asset_header_read", "found": 1,
                 "declaredBytes": 1024, "bytesRead": 15, "format": "jpeg"}
        self.assertIsNone(probe.safe_result(json.dumps(value)))

    def test_empty_file_cannot_be_reported_as_readable(self):
        value = {"source": "iphone_afc", "status": "asset_header_read", "found": 1,
                 "declaredBytes": 0, "bytesRead": 0, "format": "unknown"}
        self.assertIsNone(probe.safe_result(json.dumps(value)))

    def test_missing_file_requires_zero_result_fields(self):
        value = {"source": "iphone_afc", "status": "asset_unavailable", "found": 0,
                 "declaredBytes": 0, "bytesRead": 0, "format": "unknown"}
        self.assertEqual(probe.safe_result(json.dumps(value)), value)
        value["found"] = 1
        self.assertIsNone(probe.safe_result(json.dumps(value)))

    def test_success_json_with_failed_child_exit_cannot_report_readable(self):
        value = {"source": "iphone_afc", "status": "asset_header_read", "found": 1,
                 "declaredBytes": 1024, "bytesRead": 16, "format": "jpeg"}
        result = subprocess.CompletedProcess(["fixture"], 1, json.dumps(value).encode())
        with patch.object(probe.CATALOG, "verified_snapshot", return_value=(Path("fixture"), b"")), \
             patch.object(probe.CATALOG, "select_one_candidate", return_value=("DCIM/100APPLE", "sample.JPG")), \
             patch.object(probe, "read_binding", return_value=bytes(72)), \
             patch.object(probe, "compile_probe", return_value=Path("fixture")), \
             patch.object(probe.subprocess, "run", return_value=result), \
             patch.object(probe, "emit") as emit:
            exit_code = probe.main(["--snapshot", "fixture", "--asset-id", "1"])
        self.assertEqual(exit_code, 1)
        emit.assert_called_once_with("probe_process_failed")


if __name__ == "__main__":
    unittest.main()
