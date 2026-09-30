#!/usr/bin/env python3
"""Inspect a local iPhone metadata copy; print aggregate values only."""
import argparse
import json
from pathlib import Path
import sqlite3


def inspect(folder):
    database = folder / "Photos.sqlite"
    result = {
        "source": "iphone_afc_snapshot",
        "snapshotConsistency": "unproven",
        "catalogCoverage": "unknown",
        "kindInterpretation": "historical_ios17_0_photo_1_video",
    }
    if not database.is_file():
        return {**result, "status": "database_missing"}
    connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        integrity = connection.execute("PRAGMA quick_check").fetchall()
        if integrity != [("ok",)]:
            return {**result, "status": "integrity_check_failed"}
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
        table = next((name for name in ("ZASSET", "ZGENERICASSET") if name in tables), None)
        if table is None:
            return {**result, "status": "asset_table_unknown"}
        columns = {row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')}
        required = {"ZKIND", "ZTRASHEDSTATE", "ZHIDDEN", "ZVISIBILITYSTATE"}
        if not required.issubset(columns):
            return {**result, "status": "asset_schema_unknown", "missingFields": sorted(required - columns)}
        result.update(status="aggregate_query_complete", integrityCheck="ok", assetTable=table)
        result["assetRows"] = connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        result["kindAndTrashStates"] = [
            {"kind": row[0], "trashState": row[1], "rows": row[2]}
            for row in connection.execute(
                f'SELECT ZKIND, ZTRASHEDSTATE, COUNT(*) FROM "{table}" GROUP BY ZKIND, ZTRASHEDSTATE'
            )
        ]
        if any(
            state[key] is not None and type(state[key]) is not int
            for state in result["kindAndTrashStates"] for key in ("kind", "trashState")
        ):
            return {"source": "iphone_afc_snapshot", "status": "asset_state_types_unknown"}
        filters = {
            "notTrashed": "ZTRASHEDSTATE = 0",
            "visibleCandidates": "ZTRASHEDSTATE = 0 AND ZHIDDEN = 0 AND ZVISIBILITYSTATE = 0",
        }
        if {"ZBUNDLESCOPE", "ZSAVEDASSETTYPE"}.issubset(columns):
            scopes = connection.execute(
                f'SELECT ZBUNDLESCOPE, ZSAVEDASSETTYPE, ZKIND, COUNT(*) FROM "{table}" '
                'WHERE ZTRASHEDSTATE = 0 GROUP BY ZBUNDLESCOPE, ZSAVEDASSETTYPE, ZKIND'
            ).fetchall()
            if any(value is not None and type(value) is not int for row in scopes for value in row[:3]):
                return {"source": "iphone_afc_snapshot", "status": "asset_state_types_unknown"}
            result["scopeAndTypeStates"] = [
                {"scope": scope, "savedType": saved, "kind": kind, "rows": count}
                for scope, saved, kind, count in scopes
            ]
            filters["scopeZeroVisibleCandidates"] = (
                "ZTRASHEDSTATE = 0 AND ZHIDDEN = 0 AND ZVISIBILITYSTATE = 0 AND ZBUNDLESCOPE = 0"
            )
        for label, predicate in filters.items():
            kinds = connection.execute(
                f'SELECT ZKIND, COUNT(*) FROM "{table}" WHERE {predicate} GROUP BY ZKIND'
            ).fetchall()
            counts = dict(kinds)
            result[label] = {
                "photos": counts.get(0, 0),
                "videos": counts.get(1, 0),
                "other": sum(count for kind, count in kinds if kind not in (0, 1)),
                "total": sum(count for _, count in kinds),
            }
        return result
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot_folder", type=Path)
    arguments = parser.parse_args()
    try:
        result = inspect(arguments.snapshot_folder)
    except (OSError, sqlite3.Error):
        result = {"source": "iphone_afc_snapshot", "status": "snapshot_read_failed"}
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "aggregate_query_complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
