import importlib.util
import json
import sqlite3
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import subprocess


RUNNER = Path(__file__).resolve().parents[2] / "experiments" / "afc" / "run-live-photo-copy-probe.py"
SPEC = importlib.util.spec_from_file_location("live_photo_copy_probe", RUNNER)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class LivePhotoCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "Photos.sqlite"
        connection = sqlite3.connect(self.database)
        connection.executescript("""
            CREATE TABLE ZASSET (
                Z_PK INTEGER, ZDIRECTORY TEXT, ZFILENAME TEXT, ZKIND INTEGER,
                ZBUNDLESCOPE INTEGER, ZVISIBILITYSTATE INTEGER, ZHIDDEN INTEGER,
                ZTRASHEDSTATE INTEGER, ZKINDSUBTYPE INTEGER, ZADJUSTMENTSSTATE INTEGER
            );
            CREATE TABLE ZINTERNALRESOURCE (
                Z_PK INTEGER, ZASSET INTEGER, ZRESOURCETYPE INTEGER,
                ZDATASTORESUBTYPE INTEGER, ZVERSION INTEGER, ZDATALENGTH INTEGER
            );
            INSERT INTO ZASSET VALUES (51,'DCIM/100APPLE','sample.HEIC',0,0,0,0,0,2,0);
            INSERT INTO ZINTERNALRESOURCE VALUES (1,51,0,1,0,1200);
            INSERT INTO ZINTERNALRESOURCE VALUES (2,51,3,18,0,2400);
        """)
        connection.commit()
        connection.close()

    def tearDown(self):
        self.temporary.cleanup()

    def add_resource(self, pk, asset_id, resource_type, subtype, version, length):
        connection = sqlite3.connect(self.database)
        connection.execute("INSERT INTO ZINTERNALRESOURCE VALUES (?,?,?,?,?,?)",
                           (pk, asset_id, resource_type, subtype, version, length))
        connection.commit()
        connection.close()

    def test_selects_one_visible_unedited_main_photo_with_exact_resource_pair(self):
        candidate = probe.select_live_photo_candidate(self.database, 51)
        self.assertEqual(candidate, {
            "assetID": 51, "directory": "DCIM/100APPLE", "imageName": "sample.HEIC",
            "movieName": "sample.MOV", "resourceLengths": {"image": 1200, "movie": 2400},
        })

    def test_duplicate_resource_is_ambiguous(self):
        self.add_resource(3, 51, 0, 1, 0, 1300)
        self.assertIsNone(probe.select_live_photo_candidate(self.database, 51))

    def test_different_raw_versions_do_not_hide_ambiguous_resources(self):
        self.add_resource(3, 51, 0, 1, 2, 1300)
        self.assertIsNone(probe.select_live_photo_candidate(self.database, 51))

    def test_unique_nonzero_raw_version_does_not_disqualify_pair(self):
        connection = sqlite3.connect(self.database)
        connection.execute("UPDATE ZINTERNALRESOURCE SET ZVERSION=2 WHERE ZRESOURCETYPE=3")
        connection.commit()
        connection.close()
        self.assertEqual(probe.select_live_photo_candidate(self.database, 51)["resourceLengths"],
                         {"image": 1200, "movie": 2400})

    def test_oversize_resource_does_not_form_pair(self):
        connection = sqlite3.connect(self.database)
        connection.execute("UPDATE ZINTERNALRESOURCE SET ZDATALENGTH=? WHERE ZRESOURCETYPE=3",
                           (probe.MAX_COPY + 1,))
        connection.commit()
        connection.close()
        self.assertIsNone(probe.select_live_photo_candidate(self.database, 51))

    def test_edited_asset_is_not_selected(self):
        connection = sqlite3.connect(self.database)
        connection.execute("UPDATE ZASSET SET ZADJUSTMENTSSTATE=1 WHERE Z_PK=51")
        connection.commit()
        connection.close()
        self.assertIsNone(probe.select_live_photo_candidate(self.database, 51))

    def test_non_main_scope_asset_is_not_selected(self):
        connection = sqlite3.connect(self.database)
        connection.execute("UPDATE ZASSET SET ZBUNDLESCOPE=3 WHERE Z_PK=51")
        connection.commit()
        connection.close()
        self.assertIsNone(probe.select_live_photo_candidate(self.database, 51))

    def test_unsafe_filename_is_rejected(self):
        self.assertIsNone(probe.safe_pair_path("DCIM/100APPLE", "../sample.HEIC"))
        self.assertIsNone(probe.safe_pair_path("DCIM/100APPLE", "sample"))
        self.assertIsNone(probe.safe_pair_path("DCIM/../100APPLE", "sample.HEIC"))

    def test_failed_verifier_cannot_create_completion_marker(self):
        folder = self.root / "private-proof"
        folder.mkdir(mode=0o700)
        verification = {"verified": False, "hashMatches": True, "identifiersMatch": False,
                        "livePhotoFilesLoadable": False, "containerPlayable": True,
                        "imageIdentifierFound": True, "movieIdentifierFound": False,
                        "libraryAccessRequested": False}
        self.assertFalse(probe.write_completion_marker(folder, verification, 1200, 2400))
        self.assertFalse((folder / "complete.json").exists())

    def test_failed_copy_process_cannot_report_completed_copy(self):
        child = {"status": "asset_copy_complete", "copiedBytes": 1200, "stableObserved": True}
        result = subprocess.CompletedProcess(["fixture"], 1, b"{}")
        with patch.object(probe.COPY, "create_output_folder", return_value=self.root), \
             patch.object(probe.subprocess, "run", return_value=result), \
             patch.object(probe.COPY, "safe_child_result", return_value=child), \
             patch.object(probe, "independently_match_receipt") as validate:
            status, _, _ = probe.run_copy(Path("fixture"), "DCIM/100APPLE", "sample.HEIC",
                                         bytes(72), 1200)
        self.assertEqual(status, "probe_process_failed")
        validate.assert_not_called()

    def test_failed_verifier_process_cannot_complete_even_with_success_json(self):
        proof = self.root / "private-proof"
        proof.mkdir(mode=0o700)
        verification = {
            "verified": True, "status": "verified", "hashMatches": True,
            "imageIdentifierFound": True, "movieIdentifierFound": True,
            "identifiersMatch": True, "imageWidth": 400, "imageHeight": 300,
            "durationSeconds": 3, "videoTracks": 1, "containerPlayable": True,
            "livePhotoFilesLoadable": True, "libraryAccessRequested": False,
        }
        result = subprocess.CompletedProcess(["fixture"], 1, json.dumps(verification).encode())
        copies = [("asset_copy_complete", self.root, {"copiedBytes": 1200}),
                  ("asset_copy_complete", self.root, {"copiedBytes": 2400})]
        with patch.object(probe.CATALOG, "verified_snapshot", return_value=(self.database, bytes(72))), \
             patch.object(probe, "create_proof_folder", return_value=proof), \
             patch.object(probe.COPY, "compile_probe", return_value=Path("fixture")), \
             patch.object(probe, "run_copy", side_effect=copies), \
             patch.object(probe, "copy_private_media", return_value=True), \
             patch.object(probe, "compile_verifier", return_value=Path("fixture")), \
             patch.object(probe.subprocess, "run", return_value=result), \
             patch.object(probe, "emit") as emit:
            exit_code = probe.main(["--snapshot", str(self.root), "--asset-id", "51"])
        self.assertEqual(exit_code, 1)
        self.assertEqual(emit.call_args.args[0], "live_photo_verification_failed")
        self.assertFalse((proof / "complete.json").exists())


if __name__ == "__main__":
    unittest.main()
