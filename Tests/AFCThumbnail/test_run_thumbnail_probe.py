import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "experiments" / "afc" / "run-thumbnail-probe.py"
SPEC = importlib.util.spec_from_file_location("thumbnail_probe", SCRIPT)
thumbnail_probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(thumbnail_probe)


class ThumbnailProbeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.snapshot_root = Path(self.temporary.name) / "phone-catalog-probe"
        self.snapshot_root.mkdir()
        self.original_root = thumbnail_probe.SNAPSHOT_ROOT
        thumbnail_probe.SNAPSHOT_ROOT = self.snapshot_root
        self.addCleanup(setattr, thumbnail_probe, "SNAPSHOT_ROOT", self.original_root)

    def test_default_selects_latest_visible_photo_and_targeted_id_selects_exact_row(self):
        folder, database = self.make_snapshot([
            (10, "DCIM/100APPLE", "older.heic", 0, 0, 0, 0, 0),
            (20, "PhotoData/CPLAssets/3", "newer.heic", 0, 0, 0, 0, 0),
        ])

        self.assertIsNotNone(thumbnail_probe.verified_snapshot(folder))
        self.assertEqual(thumbnail_probe.select_one_candidate(database), ("PhotoData/CPLAssets/3", "newer.heic"))
        self.assertEqual(thumbnail_probe.select_one_candidate(database, 10), ("DCIM/100APPLE", "older.heic"))
        self.assertEqual(thumbnail_probe.select_one_candidate(database, 20), ("PhotoData/CPLAssets/3", "newer.heic"))

    def test_asset_id_parser_enforces_positive_int64_boundaries(self):
        self.assertEqual(thumbnail_probe.parse_positive_asset_id("1"), 1)
        self.assertEqual(thumbnail_probe.parse_positive_asset_id("9223372036854775807"), 0x7FFFFFFFFFFFFFFF)
        for value in ("0", "-1", "+1", "9223372036854775808", "1.0", " 1", "١"):
            with self.subTest(value=value):
                self.assertIsNone(thumbnail_probe.parse_positive_asset_id(value))
        database = self.make_snapshot([])[1]
        for invalid in (0, -1, True, 0x8000000000000000, "1"):
            with self.subTest(invalid=invalid):
                self.assertIsNone(thumbnail_probe.select_one_candidate(database, invalid))
        maximum = 0x7FFFFFFFFFFFFFFF
        maximum_database = self.make_snapshot([
            (maximum, "DCIM/100APPLE", "boundary.heic", 0, 0, 0, 0, 0),
        ])[1]
        self.assertEqual(thumbnail_probe.select_one_candidate(maximum_database, maximum),
                         ("DCIM/100APPLE", "boundary.heic"))

    def test_targeted_lookup_allows_visible_video_but_rejects_other_ineligible_rows(self):
        _, database = self.make_snapshot([
            (100, "DCIM/100APPLE", "photo.heic", 0, 0, 0, 0, 0),
            (101, "DCIM/100APPLE", "hidden.heic", 0, 0, 1, 0, 0),
            (102, "DCIM/100APPLE", "extra.heic", 0, 3, 0, 0, 0),
            (103, "DCIM/100APPLE", "series.heic", 0, 0, 0, 0, 2),
            (104, "DCIM/100APPLE", "video.mov", 1, 0, 0, 0, 0),
            (105, "DCIM/100APPLE", "trashed.heic", 0, 0, 0, 1, 0),
            (106, "DCIM/100APPLE", "unknown-kind.heic", 2, 0, 0, 0, 0),
            (107, "DCIM/100APPLE", "text-kind.heic", "unknown", 0, 0, 0, 0),
        ])
        self.assertEqual(thumbnail_probe.select_one_candidate(database), ("DCIM/100APPLE", "photo.heic"))
        self.assertEqual(thumbnail_probe.select_one_candidate(database, 104), ("DCIM/100APPLE", "video.mov"))
        for asset_id in (999, 101, 102, 103, 105, 106, 107):
            with self.subTest(asset_id=asset_id):
                self.assertIsNone(thumbnail_probe.select_one_candidate(database, asset_id))

    def test_receipt_is_required_and_unknown_schema_has_no_candidate(self):
        folder, database = self.make_snapshot([(1, "DCIM/100APPLE", "photo.heic", 0, 0, 0, 0, 0)])
        (folder / "catalog-receipt.json").unlink()
        self.assertIsNone(thumbnail_probe.verified_snapshot(folder))

        unknown_folder, unknown_db = self.make_snapshot([], columns="Z_PK INTEGER PRIMARY KEY")
        self.assertIsNotNone(thumbnail_probe.verified_snapshot(unknown_folder))
        self.assertIsNone(thumbnail_probe.select_one_candidate(unknown_db))

    def test_binding_is_required_and_malformed_binding_is_rejected(self):
        folder, _ = self.make_snapshot([])
        binding = folder / "source-binding.bin"
        binding.unlink()
        self.assertIsNone(thumbnail_probe.verified_snapshot(folder))
        binding.write_bytes(b"invalid")
        binding.chmod(0o600)
        self.assertIsNone(thumbnail_probe.verified_snapshot(folder))
        binding.write_bytes(thumbnail_probe.BINDING_MAGIC + bytes(64))
        binding.chmod(0o644)
        self.assertIsNone(thumbnail_probe.verified_snapshot(folder))

    def make_snapshot(self, rows, columns=None):
        folder = self.snapshot_root / str(uuid.uuid4())
        folder.mkdir(mode=0o700)
        database = folder / "Photos.sqlite"
        columns = columns or (
            "Z_PK INTEGER PRIMARY KEY, ZDIRECTORY TEXT, ZFILENAME TEXT, ZKIND INTEGER, "
            "ZBUNDLESCOPE INTEGER, ZHIDDEN INTEGER, ZTRASHEDSTATE INTEGER, ZVISIBILITYSTATE INTEGER"
        )
        connection = sqlite3.connect(database)
        try:
            connection.execute(f"CREATE TABLE ZASSET ({columns})")
            if "ZFILENAME" in columns and "ZVISIBILITYSTATE" in columns:
                connection.executemany("INSERT INTO ZASSET VALUES (?, ?, ?, ?, ?, ?, ?, ?)", rows)
            connection.commit()
        finally:
            connection.close()
        size = database.stat().st_size
        receipt = {
            "source": "iphone_afc", "status": "metadata_copy_complete",
            "capturedAt": "2026-09-30T12:00:00.000Z", "usbDevices": 1,
            "candidateBytes": size, "sqliteHeader": True,
            "databaseBytesCopied": size, "databaseStableObserved": True,
            "walPresent": False, "walBytesCopied": 0, "walStableObserved": False,
            "stabilityProven": False, "assetCounts": None,
        }
        receipt_path = folder / "catalog-receipt.json"
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        receipt_path.chmod(0o600)
        binding = folder / "source-binding.bin"
        binding.write_bytes(thumbnail_probe.BINDING_MAGIC + bytes(range(32)) + bytes(range(32)))
        binding.chmod(0o600)
        return folder, database


if __name__ == "__main__":
    unittest.main()
