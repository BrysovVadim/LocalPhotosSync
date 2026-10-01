#!/usr/bin/env python3
"""Copy at most one cached thumbnail from a receipt-verified phone catalog source."""

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
SOURCE = ROOT / "experiments" / "afc" / "thumbnail-candidate.c"
EXECUTABLE_NAME = "thumbnail-candidate-probe"
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
SNAPSHOT_ROOT = ROOT / ".build" / "phone-catalog-probe"
RECEIPT_KEYS = {
    "source", "status", "capturedAt", "usbDevices", "candidateBytes", "sqliteHeader",
    "databaseBytesCopied", "databaseStableObserved", "walPresent", "walBytesCopied",
    "walStableObserved", "stabilityProven", "assetCounts",
}
REQUIRED_COLUMNS = {
    "Z_PK", "ZDIRECTORY", "ZFILENAME", "ZKIND", "ZBUNDLESCOPE", "ZHIDDEN",
    "ZTRASHEDSTATE", "ZVISIBILITYSTATE",
}
BINDING_MAGIC = b"LPSBIND1"
BINDING_BYTES = 72


def emit(status, *, candidates=0, found=0, copied=0, image_format="unknown", path=None):
    result = {
        "source": "iphone_afc", "status": status,
        "candidatePathsStatted": candidates, "candidateFilesFound": found,
        "thumbnailBytesCopied": copied, "imageFormat": image_format,
    }
    if path is not None:
        result["localImagePath"] = str(path)
    print(json.dumps(result, separators=(",", ":")))


def regular_file(path):
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False


def safe_components(value, allow_slash, limit):
    if not isinstance(value, str) or not value or value.startswith("/") or len(value.encode("utf-8")) > limit:
        return False
    if "\\" in value or any(ord(char) < 32 or ord(char) == 127 for char in value):
        return False
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return allow_slash or len(parts) == 1


def verified_snapshot(folder):
    try:
        resolved_root = SNAPSHOT_ROOT.resolve(strict=True)
        resolved_folder = folder.resolve(strict=True)
        if resolved_root not in resolved_folder.parents or not stat.S_ISDIR(folder.lstat().st_mode):
            return None
        receipt_path = folder / "catalog-receipt.json"
        database = folder / "Photos.sqlite"
        binding_path = folder / "source-binding.bin"
        if not regular_file(receipt_path) or not regular_file(database) or not regular_file(binding_path):
            return None
        if stat.S_IMODE(receipt_path.lstat().st_mode) != 0o600 or stat.S_IMODE(binding_path.lstat().st_mode) != 0o600:
            return None
        binding = binding_path.read_bytes()
        if len(binding) != BINDING_BYTES or binding[:len(BINDING_MAGIC)] != BINDING_MAGIC:
            return None
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
            return None
        if receipt.get("source") != "iphone_afc" or receipt.get("status") != "metadata_copy_complete":
            return None
        if type(receipt.get("usbDevices")) is not int or receipt["usbDevices"] != 1 or receipt.get("sqliteHeader") is not True:
            return None
        if receipt.get("assetCounts") is not None or receipt.get("stabilityProven") is not False:
            return None
        for key in ("candidateBytes", "databaseBytesCopied", "walBytesCopied"):
            if type(receipt.get(key)) is not int or receipt[key] < 0:
                return None
        if not 16 <= receipt["candidateBytes"] <= 256 * 1024 * 1024:
            return None
        for key in ("databaseStableObserved", "walPresent", "walStableObserved"):
            if type(receipt.get(key)) is not bool:
                return None
        if not isinstance(receipt.get("capturedAt"), str) or not re.fullmatch(
                r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|\+00:00)", receipt["capturedAt"]):
            return None
        db_size = database.lstat().st_size
        if db_size != receipt["databaseBytesCopied"] or not 16 <= db_size <= 256 * 1024 * 1024:
            return None
        with database.open("rb") as handle:
            if handle.read(16) != b"SQLite format 3\x00":
                return None
        wal = folder / "Photos.sqlite-wal"
        names = set(os.listdir(folder))
        if receipt["walPresent"]:
            if "Photos.sqlite-wal" not in names or not regular_file(wal):
                return None
            if wal.lstat().st_size != receipt["walBytesCopied"] or wal.lstat().st_size > 64 * 1024 * 1024:
                return None
        elif receipt["walBytesCopied"] != 0 or "Photos.sqlite-wal" in names:
            return None
        shm = folder / "Photos.sqlite-shm"
        if "Photos.sqlite-shm" in names and not regular_file(shm):
            return None
        return database, binding
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def parse_positive_asset_id(value):
    if not isinstance(value, str) or len(value) > 19 or not value.isascii() or not value.isdecimal():
        return None
    asset_id = int(value, 10)
    return asset_id if 1 <= asset_id <= 0x7FFFFFFFFFFFFFFF else None


def select_one_candidate(database, asset_id=None):
    if asset_id is not None and (type(asset_id) is not int or not 1 <= asset_id <= 0x7FFFFFFFFFFFFFFF):
        return None
    uri = database.as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(ZASSET)")}
        if not REQUIRED_COLUMNS.issubset(columns):
            return None
        sql = """
            SELECT Z_PK, ZDIRECTORY, ZFILENAME
            FROM ZASSET
            WHERE ZBUNDLESCOPE=0 AND ZVISIBILITYSTATE=0 AND ZHIDDEN=0
              AND ZTRASHEDSTATE=0
              AND typeof(Z_PK)='integer'
              AND typeof(ZBUNDLESCOPE)='integer' AND typeof(ZVISIBILITYSTATE)='integer'
              AND typeof(ZHIDDEN)='integer' AND typeof(ZTRASHEDSTATE)='integer'
              AND typeof(ZKIND)='integer'
              AND ZDIRECTORY IS NOT NULL AND ZFILENAME IS NOT NULL
        """
        if asset_id is None:
            row = connection.execute(sql + " AND ZKIND=0 AND typeof(ZKIND)='integer' ORDER BY Z_PK DESC LIMIT 1").fetchone()
        else:
            row = connection.execute(sql + " AND ZKIND IN (0,1) AND typeof(ZKIND)='integer' AND Z_PK = ? LIMIT 1", (asset_id,)).fetchone()
        if not row or type(row[0]) is not int or not isinstance(row[1], str) or not isinstance(row[2], str):
            return None
        directory, filename = row[1], row[2]
        valid_directory = (
            safe_components(directory, True, 512) and
            (len(directory.split("/")) == 2 and directory.startswith("DCIM/") or
             len(directory.split("/")) == 3 and directory.startswith("PhotoData/CPLAssets/"))
        )
        if not valid_directory or not safe_components(filename, False, 255):
            return None
        return directory, filename
    finally:
        connection.close()


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
    command.extend([str(SOURCE), "-limobiledevice-1.0", "-lusbmuxd-2.0", "-lplist-2.0", "-lsqlite3", "-o", str(executable)])
    try:
        succeeded = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=10, check=False).returncode == 0
        return executable if succeeded else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def safe_result(raw):
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    expected = {"source", "status", "candidatePathsStatted", "candidateFilesFound",
                "thumbnailBytesCopied", "imageFormat", "stableObserved"}
    if not isinstance(value, dict) or set(value) != expected or value.get("source") != "iphone_afc":
        return None
    if not isinstance(value.get("status"), str) or not re.fullmatch(r"[a-z0-9_]+", value["status"]):
        return None
    for key in ("candidatePathsStatted", "candidateFilesFound", "thumbnailBytesCopied"):
        if type(value.get(key)) is not int or value[key] < 0:
            return None
    if value["candidatePathsStatted"] > 2 or value["candidateFilesFound"] > 1 or value["thumbnailBytesCopied"] > 4 * 1024 * 1024:
        return None
    if value.get("imageFormat") not in {"jpeg", "png", "heif", "unknown"}:
        return None
    if type(value.get("stableObserved")) is not bool:
        return None
    return value


def main(argv):
    if argv == ["--help"]:
        print("usage: run-thumbnail-probe.py --snapshot <verified-local-snapshot-folder> [--asset-id <positive-int64>]")
        return 0
    if len(argv) not in (2, 4) or argv[0] != "--snapshot" or (len(argv) == 4 and argv[2] != "--asset-id"):
        print("usage: run-thumbnail-probe.py --snapshot <verified-local-snapshot-folder> [--asset-id <positive-int64>]", file=sys.stderr)
        return 2
    snapshot = Path(argv[1]).absolute()
    asset_id = None
    if len(argv) == 4:
        asset_id = parse_positive_asset_id(argv[3])
        if asset_id is None:
            emit("invalid_asset_id")
            return 2
    verified = verified_snapshot(snapshot)
    if verified is None:
        emit("verified_snapshot_unavailable")
        return 1
    database, source_binding = verified
    try:
        candidate = select_one_candidate(database, asset_id)
    except (sqlite3.Error, OSError):
        candidate = None
    if candidate is None:
        emit("candidate_unknown")
        return 1

    env = os.environ.copy()
    env.pop("USBMUXD_SOCKET_ADDRESS", None)
    env["DYLD_LIBRARY_PATH"] = DYLD_PATH
    executable = compile_probe(env)
    if executable is None:
        emit("probe_build_failed")
        return 1
    output_root = ROOT / ".build" / "phone-thumbnail-probe"
    try:
        if not stat.S_ISDIR((ROOT / ".build").lstat().st_mode):
            emit("local_folder_unavailable")
            return 1
        try:
            output_root.mkdir(mode=0o700)
        except FileExistsError:
            if not stat.S_ISDIR(output_root.lstat().st_mode):
                emit("local_folder_unavailable")
                return 1
        output_folder = output_root / str(uuid.uuid4())
        output_folder.mkdir(mode=0o700)
        directory_fd = os.open(output_folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchmod(directory_fd, 0o700)
        finally:
            os.close(directory_fd)
    except OSError:
        emit("local_folder_unavailable")
        return 1
    image_path = output_folder / "thumbnail.img"
    try:
        child_input = f"{candidate[0]}\n{candidate[1]}\n".encode("utf-8") + source_binding
        result = subprocess.run([str(executable), str(output_folder)],
                                cwd=ROOT, env=env, capture_output=True,
                                input=child_input, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        emit("probe_timeout", path=image_path)
        return 1
    except OSError:
        emit("probe_process_error", path=image_path)
        return 1
    try:
        child_output = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError:
        child_output = ""
    data = safe_result(child_output)
    if data is None:
        emit("probe_output_invalid", path=image_path)
        return 1
    if result.returncode == 0 and data["status"] == "thumbnail_copied":
        try:
            image_stat = image_path.lstat()
            with image_path.open("rb") as handle:
                header = handle.read(16)
            jpeg = len(header) >= 3 and header[:3] == b"\xff\xd8\xff"
            png = len(header) >= 8 and header[:8] == b"\x89PNG\r\n\x1a\n"
            heif = len(header) >= 12 and header[4:8] == b"ftyp" and header[8:12] in {b"heic", b"heix", b"hevc", b"mif1", b"msf1"}
            actual_format = "jpeg" if jpeg else ("png" if png else ("heif" if heif else "unknown"))
            if (not stat.S_ISREG(image_stat.st_mode) or stat.S_IMODE(image_stat.st_mode) != 0o600 or
                    image_stat.st_size != data["thumbnailBytesCopied"] or actual_format != data["imageFormat"]):
                emit("local_image_validation_failed", candidates=data["candidatePathsStatted"],
                     found=data["candidateFilesFound"], copied=data["thumbnailBytesCopied"],
                     image_format=data["imageFormat"], path=image_path)
                return 1
        except OSError:
            emit("local_image_validation_failed", candidates=data["candidatePathsStatted"],
                 found=data["candidateFilesFound"], copied=data["thumbnailBytesCopied"],
                 image_format=data["imageFormat"], path=image_path)
            return 1
        data["localImagePath"] = str(image_path)
    print(json.dumps(data, separators=(",", ":")))
    return 0 if result.returncode == 0 and data["status"] == "thumbnail_copied" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
