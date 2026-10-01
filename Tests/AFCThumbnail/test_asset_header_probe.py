import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


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


if __name__ == "__main__":
    unittest.main()
