#!/usr/bin/env python3
"""Compile and run the existing-pair AFC catalog probe with a hard deadline."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone
import uuid


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / ".build" / "afc-runtime"
SOURCE = ROOT / "experiments" / "afc" / "catalog-header.c"
EXECUTABLE_NAME = "catalog-header-probe"
INCLUDES = [
    RUNTIME / "libimobiledevice" / "1.4.0" / "include",
    RUNTIME / "libusbmuxd" / "2.1.1" / "include",
    RUNTIME / "libplist" / "2.7.0" / "include",
    RUNTIME / "libimobiledevice-glue" / "1.3.2" / "include",
]
LIBDIRS = sorted({p.parent for p in RUNTIME.rglob("*.dylib")})
LIBDIRS += [
    RUNTIME / "libimobiledevice" / "1.4.0" / "lib",
    RUNTIME / "libusbmuxd" / "2.1.1" / "lib",
    RUNTIME / "libplist" / "2.7.0" / "lib",
]
LIBDIRS = list(dict.fromkeys(LIBDIRS))
DYLD_PATH = ":".join(str(p) for p in LIBDIRS)


def emit(status, fields=None):
    result = {"source": "iphone_afc", "status": status, "assetCounts": None}
    if fields:
        result.update(fields)
    print(json.dumps(result, separators=(",", ":")))


def compile_probe(env):
    executable_root = ROOT / ".build" / "probe-executables"
    try:
        executable_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        build_folder = executable_root / str(uuid.uuid4())
        build_folder.mkdir(mode=0o700)
        os.chmod(build_folder, 0o700)
        executable = build_folder / EXECUTABLE_NAME
    except OSError:
        return None
    command = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror"]
    command.extend(f"-I{path}" for path in INCLUDES)
    command.extend(f"-L{path}" for path in LIBDIRS)
    command.extend([str(SOURCE), "-limobiledevice-1.0", "-lusbmuxd-2.0", "-lplist-2.0", "-o", str(executable)])
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return executable if result.returncode == 0 else None


def safe_child_json(raw):
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(value, dict) or value.get("source") != "iphone_afc":
        return None
    status = value.get("status")
    if not isinstance(status, str) or not re.fullmatch(r"[a-z0-9_]+", status):
        return None
    allowed = {
        "source", "usbDevices", "status", "candidateBytes", "sqliteHeader",
        "databaseBytesCopied", "databaseStableObserved", "walPresent",
        "walBytesCopied", "walStableObserved", "stabilityProven", "assetCounts",
    }
    if set(value) - allowed or value.get("assetCounts") is not None:
        return None
    for key in ("usbDevices", "candidateBytes", "databaseBytesCopied", "walBytesCopied"):
        if key in value and (not isinstance(value[key], int) or isinstance(value[key], bool) or value[key] < 0):
            return None
    for key in ("sqliteHeader", "databaseStableObserved", "walPresent", "walStableObserved", "stabilityProven"):
        if key in value and not isinstance(value[key], bool):
            return None
    if "stabilityProven" in value and value["stabilityProven"] is not False:
        return None
    if status == "metadata_copy_complete":
        required = {
            "usbDevices", "candidateBytes", "sqliteHeader", "databaseBytesCopied",
            "databaseStableObserved", "walPresent", "walBytesCopied",
            "walStableObserved", "stabilityProven", "assetCounts",
        }
        if not required.issubset(value) or value["usbDevices"] != 1 or value["sqliteHeader"] is not True:
            return None
        if value["databaseBytesCopied"] == 0 or value["assetCounts"] is not None:
            return None
    return value


def write_receipt(snapshot, child_data):
    receipt = {
        "source": child_data["source"],
        "status": child_data["status"],
        "capturedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "usbDevices": child_data["usbDevices"],
        "candidateBytes": child_data["candidateBytes"],
        "sqliteHeader": child_data["sqliteHeader"],
        "databaseBytesCopied": child_data["databaseBytesCopied"],
        "databaseStableObserved": child_data["databaseStableObserved"],
        "walPresent": child_data["walPresent"],
        "walBytesCopied": child_data["walBytesCopied"],
        "walStableObserved": child_data["walStableObserved"],
        "stabilityProven": child_data["stabilityProven"],
        "assetCounts": None,
    }
    path = snapshot / "catalog-receipt.json"
    descriptor = None
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            descriptor = None
            output.write(json.dumps(receipt, separators=(",", ":")) + "\n")
            output.flush()
            os.fsync(output.fileno())
        return True
    except OSError:
        return False
    finally:
        if descriptor is not None:
            os.close(descriptor)


def main(argv):
    if argv == ["--help"]:
        print("usage: run-probe.py [--copy-metadata]")
        print("Runs the header-only probe; copy mode saves fixed metadata files under .build/phone-catalog-probe/.")
        return 0
    copy_mode = argv == ["--copy-metadata"]
    if argv not in ([], ["--copy-metadata"]):
        print("usage: run-probe.py [--copy-metadata]", file=sys.stderr)
        return 2
    env = os.environ.copy()
    env.pop("USBMUXD_SOCKET_ADDRESS", None)
    env["DYLD_LIBRARY_PATH"] = DYLD_PATH
    executable = compile_probe(env)
    if executable is None:
        emit("probe_build_failed")
        return 1

    snapshot = None
    command = [str(executable)]
    timeout = 20
    if copy_mode:
        snapshot_root = ROOT / ".build" / "phone-catalog-probe"
        try:
            snapshot_root.mkdir(parents=True, exist_ok=True)
            snapshot = snapshot_root / str(uuid.uuid4())
            snapshot.mkdir(mode=0o700)
        except OSError:
            emit("snapshot_folder_unavailable")
            return 1
        command.extend(["--copy-metadata", str(snapshot)])
        timeout = 90

    try:
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        fields = {"snapshotPath": str(snapshot)} if snapshot else None
        emit("probe_timeout", fields)
        return 1
    except OSError:
        fields = {"snapshotPath": str(snapshot)} if snapshot else None
        emit("probe_process_error", fields)
        return 1

    data = safe_child_json(result.stdout.strip())
    if data is None:
        fields = {"snapshotPath": str(snapshot)} if snapshot else None
        emit("probe_output_invalid", fields)
        return 1
    if copy_mode and (result.returncode != 0 or data["status"] != "metadata_copy_complete"):
        data["snapshotPath"] = str(snapshot)
        print(json.dumps(data, separators=(",", ":")))
        return 1
    if copy_mode and not write_receipt(snapshot, data):
        emit("copy_receipt_failed", {"snapshotPath": str(snapshot)})
        return 1
    if snapshot:
        data["snapshotPath"] = str(snapshot)
    print(json.dumps(data, separators=(",", ":")))
    return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
