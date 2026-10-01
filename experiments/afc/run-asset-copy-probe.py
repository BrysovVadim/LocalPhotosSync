#!/usr/bin/env python3
"""Copy at most one verified phone asset into a private local probe folder."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / ".build" / "afc-runtime"
SOURCE = ROOT / "experiments" / "afc" / "asset-copy.c"
THUMBNAIL_RUNNER = ROOT / "experiments" / "afc" / "run-thumbnail-probe.py"
OUTPUT_ROOT = ROOT / ".build" / "phone-asset-copy-probe"
BUILD_ROOT = ROOT / ".build" / "probe-executables"
INCLUDES = [
    RUNTIME / "libimobiledevice" / "1.4.0" / "include",
    RUNTIME / "libusbmuxd" / "2.1.1" / "include",
    RUNTIME / "libplist" / "2.7.0" / "include",
    RUNTIME / "libimobiledevice-glue" / "1.3.2" / "include",
]
LIBDIRS = sorted({path.parent for path in RUNTIME.rglob("*.dylib")})
LIBDIRS = list(dict.fromkeys(LIBDIRS + [
    RUNTIME / "libimobiledevice" / "1.4.0" / "lib",
    RUNTIME / "libusbmuxd" / "2.1.1" / "lib",
    RUNTIME / "libplist" / "2.7.0" / "lib",
]))
DYLD_PATH = ":".join(str(path) for path in LIBDIRS)
COPY_LIMIT = 32 * 1024 * 1024


def load_catalog_helpers():
    spec = importlib.util.spec_from_file_location("thumbnail_probe_helpers", THUMBNAIL_RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError("catalog_helpers_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CATALOG = load_catalog_helpers()


def emit(status, copied=0, stable=False, folder=None):
    print(json.dumps({
        "source": "iphone_afc", "status": status, "copiedBytes": copied,
        "stableObserved": stable, "localFolder": str(folder) if folder is not None else None,
    }, separators=(",", ":")))


def compile_probe(env):
    try:
        BUILD_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        build_folder = BUILD_ROOT / str(uuid.uuid4())
        build_folder.mkdir(mode=0o700)
        os.chmod(build_folder, 0o700)
        executable = build_folder / "asset-copy-probe"
    except OSError:
        return None
    command = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror"]
    command.extend(f"-I{path}" for path in INCLUDES)
    command.extend(f"-L{path}" for path in LIBDIRS)
    command.extend([
        str(SOURCE), "-limobiledevice-1.0", "-lusbmuxd-2.0", "-lplist-2.0",
        "-o", str(executable),
    ])
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return executable if result.returncode == 0 else None


def safe_child_result(raw, expected_folder):
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    expected_keys = {"source", "status", "copiedBytes", "stableObserved", "localFolder"}
    statuses = {
        "asset_copy_complete", "invalid_arguments", "local_folder_unavailable", "device_discovery_failed",
        "requires_exactly_one_usb_device", "source_binding_unavailable", "source_binding_mismatch",
        "existing_pair_record_unavailable", "invalid_pair_record", "existing_system_buid_unavailable",
        "usb_connection_failed", "lockdown_connection_failed", "existing_pair_session_failed",
        "afc_service_unavailable", "afc_requires_unverified_service_tls", "afc_connection_failed",
        "candidate_path_too_long", "asset_unavailable", "asset_stat_failed", "asset_size_out_of_bounds",
        "local_file_create_failed", "asset_readonly_open_failed", "asset_hash_failed", "asset_read_failed",
        "local_write_failed", "asset_close_failed", "local_sync_failed", "local_close_failed",
        "asset_stat_after_failed", "asset_changed", "copy_receipt_failed",
    }
    if not isinstance(value, dict) or set(value) != expected_keys or value.get("source") != "iphone_afc":
        return None
    if value.get("status") not in statuses:
        return None
    copied = value.get("copiedBytes")
    if type(copied) is not int or not 0 <= copied <= COPY_LIMIT:
        return None
    if type(value.get("stableObserved")) is not bool:
        return None
    if value.get("localFolder") != str(expected_folder):
        return None
    return value


def validate_copy_receipt(folder, child_result):
    receipt_path = folder / "copy-receipt.json"
    media_path = folder / "media.bin"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptors = []
    try:
        for path, expected_size in ((receipt_path, None), (media_path, child_result["copiedBytes"])):
            descriptor = os.open(path, flags)
            descriptors.append(descriptor)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
                return False
            if expected_size is not None and info.st_size != expected_size:
                return False
        if os.fstat(descriptors[0]).st_size > 1024:
            return False
        with os.fdopen(descriptors[0], "r", encoding="utf-8") as receipt_file:
            descriptors[0] = -1
            receipt = json.load(receipt_file)
        expected_keys = {"source", "status", "declaredBytes", "copiedBytes", "stableObserved", "receivedStreamSHA256"}
        if not isinstance(receipt, dict) or set(receipt) != expected_keys:
            return False
        return (
            receipt.get("source") == "iphone_afc" and
            receipt.get("status") == "asset_copy_complete" and
            type(receipt.get("declaredBytes")) is int and 0 <= receipt["declaredBytes"] <= COPY_LIMIT and
            receipt["declaredBytes"] == child_result["copiedBytes"] and
            type(receipt.get("copiedBytes")) is int and receipt["copiedBytes"] == child_result["copiedBytes"] and
            type(receipt.get("stableObserved")) is bool and
            receipt["stableObserved"] == child_result["stableObserved"] and
            isinstance(receipt.get("receivedStreamSHA256"), str) and
            re.fullmatch(r"[0-9a-f]{64}", receipt["receivedStreamSHA256"]) is not None
        )
    except (OSError, ValueError, json.JSONDecodeError):
        return False
    finally:
        for descriptor in descriptors:
            if descriptor >= 0:
                os.close(descriptor)


def numeric_column(statement, index):
    return statement[index] if type(statement[index]) is int else None


def asset_context(database, snapshot, selected_path, requested_asset_id):
    uri = database.as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(ZASSET)")}
        required = CATALOG.REQUIRED_COLUMNS | {"ZDIRECTORY"}
        if not required.issubset(columns):
            return None
        directory, filename = selected_path
        conditions = """ZBUNDLESCOPE=0 AND ZVISIBILITYSTATE=0 AND ZHIDDEN=0
                        AND ZTRASHEDSTATE=0 AND typeof(Z_PK)='integer'
                        AND typeof(ZBUNDLESCOPE)='integer' AND typeof(ZVISIBILITYSTATE)='integer'
                        AND typeof(ZHIDDEN)='integer' AND typeof(ZTRASHEDSTATE)='integer'
                        AND typeof(ZKIND)='integer' AND ZDIRECTORY=? AND ZFILENAME=?"""
        parameters = [directory, filename]
        if requested_asset_id is None:
            conditions += " AND ZKIND=0"
            order = "ORDER BY Z_PK DESC LIMIT 1"
        else:
            conditions += " AND ZKIND IN (0,1) AND Z_PK=?"
            parameters.append(requested_asset_id)
            order = "LIMIT 1"
        row = connection.execute(
            f"SELECT Z_PK,ZKIND FROM ZASSET WHERE {conditions} {order}", parameters
        ).fetchone()
        if row is None or type(row[0]) is not int or type(row[1]) is not int:
            return None
        asset_pk, asset_kind = row

        original_size = None
        original_choice = None
        additional_columns = {entry[1] for entry in connection.execute("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)")}
        additional_fields = [name for name in ("ZORIGINALFILESIZE", "ZORIGINALRESOURCECHOICE") if name in additional_columns]
        if additional_fields and "ZASSET" in additional_columns:
            expression = ",".join(f"aa.{name}" for name in additional_fields)
            additional = connection.execute(
                f"SELECT {expression} FROM ZADDITIONALASSETATTRIBUTES aa WHERE aa.ZASSET=? LIMIT 1",
                (asset_pk,),
            ).fetchone()
            if additional is not None:
                index = 0
                if "ZORIGINALFILESIZE" in additional_fields:
                    original_size = numeric_column(additional, index); index += 1
                if "ZORIGINALRESOURCECHOICE" in additional_fields:
                    original_choice = numeric_column(additional, index)

        resource_columns = {entry[1] for entry in connection.execute("PRAGMA table_info(ZINTERNALRESOURCE)")}
        resource_fields = (
            "ZRESOURCETYPE", "ZDATASTORECLASSID", "ZDATASTORESUBTYPE", "ZVERSION",
            "ZRECIPEID", "ZDATALENGTH", "ZLOCALAVAILABILITY",
        )
        if set(resource_fields + ("ZASSET", "Z_PK")).issubset(resource_columns):
            resources = []
            names = ",".join(resource_fields)
            for resource in connection.execute(
                    f"SELECT {names} FROM ZINTERNALRESOURCE WHERE ZASSET=? ORDER BY Z_PK LIMIT 65",
                    (asset_pk,)):
                resources.append({key: numeric_column(resource, index) for index, key in enumerate(resource_fields)})
            if len(resources) > 64:
                return None
        else:
            resources = None
        return {
            "sourceSnapshot": str(snapshot.resolve()),
            "assetID": asset_pk,
            "filename": filename,
            "ZKIND": asset_kind,
            "ZORIGINALFILESIZE": original_size,
            "ZORIGINALRESOURCECHOICE": original_choice,
            "linkedResources": resources,
        }
    except sqlite3.Error:
        return None
    finally:
        connection.close()


def read_copy_receipt(folder):
    path = folder / "copy-receipt.json"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = None
    try:
        descriptor = os.open(path, flags)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 1024:
            return None
        with os.fdopen(descriptor, "r", encoding="utf-8") as receipt_file:
            descriptor = None
            return json.load(receipt_file)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def write_private_receipt(folder, context, copy_receipt):
    receipt = {
        "source": "iphone_afc",
        "status": "asset_copy_complete",
        **context,
        "declaredBytes": copy_receipt["declaredBytes"],
        "copiedBytes": copy_receipt["copiedBytes"],
        "stableObserved": copy_receipt["stableObserved"],
        "receivedStreamSHA256": copy_receipt["receivedStreamSHA256"],
    }
    encoded = json.dumps(receipt, separators=(",", ":"), ensure_ascii=True).encode("utf-8") + b"\n"
    dirfd = None
    descriptor = None
    try:
        dirfd = os.open(folder, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        descriptor = os.open("asset-copy-receipt.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), 0o600, dir_fd=dirfd)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = None
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        return True
    except OSError:
        return False
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if dirfd is not None:
            os.close(dirfd)


def create_output_folder():
    try:
        build = ROOT / ".build"
        if not stat.S_ISDIR(build.lstat().st_mode):
            return None
        OUTPUT_ROOT.mkdir(mode=0o700, exist_ok=True)
        if not stat.S_ISDIR(OUTPUT_ROOT.lstat().st_mode):
            return None
        folder = OUTPUT_ROOT / str(uuid.uuid4())
        folder.mkdir(mode=0o700)
        os.chmod(folder, 0o700)
        return folder
    except OSError:
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(description="Copy one bounded main asset file from a verified phone catalog.")
    parser.add_argument("--snapshot", required=True, help="Verified phone catalog snapshot folder")
    parser.add_argument("--asset-id", help="Optional positive int64 asset ID; default is latest visible photo")
    args = parser.parse_args(argv)
    asset_id = None
    if args.asset_id is not None:
        asset_id = CATALOG.parse_positive_asset_id(args.asset_id)
        if asset_id is None:
            emit("invalid_asset_id")
            return 2

    snapshot = Path(args.snapshot)
    verified = CATALOG.verified_snapshot(snapshot)
    if verified is None:
        emit("verified_snapshot_unavailable")
        return 1
    database, binding = verified
    try:
        candidate = CATALOG.select_one_candidate(database, asset_id)
    except (OSError, ValueError, CATALOG.sqlite3.Error):
        candidate = None
    if candidate is None:
        emit("candidate_unknown")
        return 1
    context = asset_context(database, snapshot, candidate, asset_id)
    if context is None:
        emit("asset_context_unavailable")
        return 1
    if not isinstance(binding, bytes) or len(binding) != CATALOG.BINDING_BYTES:
        emit("source_binding_unavailable")
        return 1
    folder = create_output_folder()
    if folder is None:
        emit("local_folder_unavailable")
        return 1

    env = os.environ.copy()
    env.pop("USBMUXD_SOCKET_ADDRESS", None)
    env["DYLD_LIBRARY_PATH"] = DYLD_PATH
    executable = compile_probe(env)
    if executable is None:
        emit("probe_build_failed", folder=folder)
        return 1
    directory, filename = candidate
    input_bytes = directory.encode("utf-8") + b"\n" + filename.encode("utf-8") + b"\n" + binding
    try:
        result = subprocess.run([str(executable), str(folder)], cwd=ROOT, env=env,
                                input=input_bytes, capture_output=True, timeout=60, check=False)
    except subprocess.TimeoutExpired:
        emit("probe_timeout", folder=folder)
        return 1
    except OSError:
        emit("probe_process_error", folder=folder)
        return 1
    try:
        child_output = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError:
        child_output = ""
    data = safe_child_result(child_output, folder)
    if data is None:
        emit("probe_output_invalid", folder=folder)
        return 1
    if result.returncode != 0 or data["status"] != "asset_copy_complete":
        emit(data["status"], copied=data["copiedBytes"], stable=data["stableObserved"], folder=folder)
        return 1
    if not validate_copy_receipt(folder, data):
        emit("copy_receipt_invalid", copied=data["copiedBytes"], stable=data["stableObserved"], folder=folder)
        return 1
    copy_receipt = read_copy_receipt(folder)
    if copy_receipt is None or not write_private_receipt(folder, context, copy_receipt):
        emit("copy_receipt_write_failed", copied=data["copiedBytes"], stable=data["stableObserved"], folder=folder)
        return 1
    emit("asset_copy_complete", copied=data["copiedBytes"], stable=data["stableObserved"], folder=folder)
    return 0


if __name__ == "__main__":
    sys.exit(main())
