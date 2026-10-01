#!/usr/bin/env python3
"""Compile and run a bounded header-only read for one verified phone catalog asset."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / ".build" / "afc-runtime"
SOURCE = ROOT / "experiments" / "afc" / "asset-header.c"
THUMBNAIL_RUNNER = ROOT / "experiments" / "afc" / "run-thumbnail-probe.py"
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


def load_catalog_helpers():
    spec = importlib.util.spec_from_file_location("thumbnail_probe_helpers", THUMBNAIL_RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError("catalog_helpers_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CATALOG = load_catalog_helpers()


def emit(status, found=0, declared=0, read=0, image_format="unknown"):
    print(json.dumps({
        "source": "iphone_afc", "status": status, "found": found,
        "declaredBytes": declared, "bytesRead": read, "format": image_format,
    }, separators=(",", ":")))


def read_binding(binding_path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(binding_path, flags)
    except OSError:
        return None
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != CATALOG.BINDING_BYTES:
            return None
        chunks = []
        remaining = CATALOG.BINDING_BYTES
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                return None
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            return None
        value = b"".join(chunks)
        return value if value.startswith(CATALOG.BINDING_MAGIC) else None
    finally:
        os.close(descriptor)


def compile_probe(env):
    try:
        BUILD_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        build_folder = BUILD_ROOT / str(uuid.uuid4())
        build_folder.mkdir(mode=0o700)
        os.chmod(build_folder, 0o700)
        executable = build_folder / "asset-header-probe"
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


def safe_result(raw):
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    expected = {"source", "status", "found", "declaredBytes", "bytesRead", "format"}
    if not isinstance(value, dict) or set(value) != expected or value.get("source") != "iphone_afc":
        return None
    if not isinstance(value["status"], str) or not re.fullmatch(r"[a-z0-9_]+", value["status"]):
        return None
    if type(value["found"]) is not int or value["found"] not in (0, 1):
        return None
    if type(value["declaredBytes"]) is not int or not 0 <= value["declaredBytes"] <= 0xFFFFFFFFFFFFFFFF:
        return None
    if type(value["bytesRead"]) is not int or not 0 <= value["bytesRead"] <= 16:
        return None
    if value["format"] not in {"jpeg", "png", "isobmff", "unknown"}:
        return None
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read at most 16 header bytes from one main asset file.")
    parser.add_argument("--snapshot", required=True, help="Verified phone catalog snapshot folder")
    parser.add_argument("--asset-id", help="Optional positive int64 Photos asset ID; default is latest visible photo")
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
    database, _ = verified
    try:
        candidate = CATALOG.select_one_candidate(database, asset_id)
    except (OSError, ValueError, CATALOG.sqlite3.Error):
        candidate = None
    if candidate is None:
        emit("candidate_unknown")
        return 1
    binding = read_binding(snapshot / "source-binding.bin")
    if binding is None:
        emit("source_binding_unavailable")
        return 1

    env = os.environ.copy()
    env.pop("USBMUXD_SOCKET_ADDRESS", None)
    env["DYLD_LIBRARY_PATH"] = DYLD_PATH
    executable = compile_probe(env)
    if executable is None:
        emit("probe_build_failed")
        return 1
    directory, filename = candidate
    input_bytes = directory.encode("utf-8") + b"\n" + filename.encode("utf-8") + b"\n" + binding
    try:
        result = subprocess.run([str(executable)], cwd=ROOT, env=env, input=input_bytes,
                                capture_output=True, timeout=20, check=False)
    except subprocess.TimeoutExpired:
        emit("probe_timeout")
        return 1
    except OSError:
        emit("probe_process_error")
        return 1
    try:
        child_output = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError:
        child_output = ""
    data = safe_result(child_output)
    if data is None:
        emit("probe_output_invalid")
        return 1
    print(json.dumps(data, separators=(",", ":")))
    return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
