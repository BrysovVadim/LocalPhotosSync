import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[2] / "experiments" / "afc" / "run-asset-copy-probe.py"
SPEC = importlib.util.spec_from_file_location("asset_copy_probe", RUNNER)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class AssetCopyProbeResultTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name) / "output"
        self.folder.mkdir(mode=0o700)
        self.child = {
            "source": "iphone_afc", "status": "asset_copy_complete", "copiedBytes": 3,
            "stableObserved": True, "localFolder": str(self.folder),
        }

    def tearDown(self):
        self.temporary.cleanup()

    def write_outputs(self, receipt=None, media=b"abc"):
        (self.folder / "media.bin").write_bytes(media)
        (self.folder / "media.bin").chmod(0o600)
        value = receipt or {
            "source": "iphone_afc", "status": "asset_copy_complete", "declaredBytes": 3,
            "copiedBytes": 3, "stableObserved": True, "receivedStreamSHA256": "a" * 64,
        }
        path = self.folder / "copy-receipt.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        path.chmod(0o600)

    def test_child_result_is_bounded_and_has_no_private_fields(self):
        raw = json.dumps(self.child)
        self.assertEqual(probe.safe_child_result(raw, self.folder), self.child)
        for extra in ({"filename": "private.heic"}, {"sha256": "a" * 64}, {"copiedBytes": probe.COPY_LIMIT + 1}):
            with self.subTest(extra=extra):
                invalid = dict(self.child)
                invalid.update(extra)
                self.assertIsNone(probe.safe_child_result(json.dumps(invalid), self.folder))
        self.assertIsNone(probe.safe_child_result(raw, self.folder.parent))

    def test_private_receipt_and_media_must_match_exact_byte_count(self):
        self.write_outputs()
        self.assertTrue(probe.validate_copy_receipt(self.folder, self.child))

        invalid_receipt = {
            "source": "iphone_afc", "status": "asset_copy_complete", "declaredBytes": 4,
            "copiedBytes": 4, "stableObserved": True, "sha256": "a" * 64,
        }
        self.write_outputs(invalid_receipt)
        self.assertFalse(probe.validate_copy_receipt(self.folder, self.child))

        self.write_outputs()
        (self.folder / "media.bin").chmod(0o644)
        self.assertFalse(probe.validate_copy_receipt(self.folder, self.child))

    def test_receipt_digest_must_remain_local_and_well_formed(self):
        self.write_outputs({
            "source": "iphone_afc", "status": "asset_copy_complete", "declaredBytes": 3,
            "copiedBytes": 3, "stableObserved": True, "receivedStreamSHA256": "invalid",
        })
        self.assertFalse(probe.validate_copy_receipt(self.folder, self.child))

    def test_asset_context_contains_raw_observations_for_only_selected_row(self):
        database = self.folder / "Photos.sqlite"
        connection = sqlite3.connect(database)
        try:
            connection.executescript("""
                CREATE TABLE ZASSET (Z_PK INTEGER, ZDIRECTORY TEXT, ZFILENAME TEXT, ZKIND INTEGER,
                    ZBUNDLESCOPE INTEGER, ZVISIBILITYSTATE INTEGER, ZHIDDEN INTEGER, ZTRASHEDSTATE INTEGER);
                CREATE TABLE ZADDITIONALASSETATTRIBUTES (ZASSET INTEGER, ZORIGINALFILESIZE INTEGER,
                    ZORIGINALRESOURCECHOICE INTEGER);
                CREATE TABLE ZINTERNALRESOURCE (Z_PK INTEGER, ZASSET INTEGER, ZRESOURCETYPE INTEGER,
                    ZDATASTORECLASSID INTEGER, ZDATASTORESUBTYPE INTEGER, ZVERSION INTEGER,
                    ZRECIPEID INTEGER, ZDATALENGTH INTEGER, ZLOCALAVAILABILITY INTEGER);
                INSERT INTO ZASSET VALUES (42,'DCIM/100APPLE','clip.mov',1,0,0,0,0);
                INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (42,987654,52);
                INSERT INTO ZINTERNALRESOURCE VALUES (1,42,13,4,5,2,3,1000,1);
                INSERT INTO ZINTERNALRESOURCE VALUES (2,42,14,6,7,1,8,2000,-1);
            """)
            connection.commit()
        finally:
            connection.close()
        context = probe.asset_context(database, self.folder, ("DCIM/100APPLE", "clip.mov"), 42)
        self.assertEqual(context["assetID"], 42)
        self.assertEqual(context["ZKIND"], 1)
        self.assertEqual(context["ZORIGINALFILESIZE"], 987654)
        self.assertEqual(context["ZORIGINALRESOURCECHOICE"], 52)
        self.assertEqual(context["linkedResources"], [
            {"ZRESOURCETYPE": 13, "ZDATASTORECLASSID": 4, "ZDATASTORESUBTYPE": 5,
             "ZVERSION": 2, "ZRECIPEID": 3, "ZDATALENGTH": 1000, "ZLOCALAVAILABILITY": 1},
            {"ZRESOURCETYPE": 14, "ZDATASTORECLASSID": 6, "ZDATASTORESUBTYPE": 7,
             "ZVERSION": 1, "ZRECIPEID": 8, "ZDATALENGTH": 2000, "ZLOCALAVAILABILITY": -1},
        ])
        self.assertIsNone(probe.asset_context(database, self.folder, ("DCIM/100APPLE", "wrong.mov"), 42))
        copy_receipt = {
            "declaredBytes": 3, "copiedBytes": 3, "stableObserved": True,
            "receivedStreamSHA256": "a" * 64,
        }
        self.assertTrue(probe.write_private_receipt(self.folder, context, copy_receipt))
        private_receipt = self.folder / "asset-copy-receipt.json"
        self.assertEqual(private_receipt.stat().st_mode & 0o777, 0o600)
        saved = json.loads(private_receipt.read_text(encoding="utf-8"))
        self.assertEqual(saved["filename"], "clip.mov")
        self.assertEqual(saved["assetID"], 42)
        self.assertEqual(saved["receivedStreamSHA256"], "a" * 64)


if __name__ == "__main__":
    unittest.main()
