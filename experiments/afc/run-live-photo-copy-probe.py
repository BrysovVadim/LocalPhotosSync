#!/usr/bin/env python3
"""Copy and locally verify one bounded Live Photo resource pair from a verified phone catalog."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
COPY_RUNNER_PATH = ROOT / "experiments" / "afc" / "run-asset-copy-probe.py"
VERIFIER_SOURCE = ROOT / "experiments" / "afc" / "verify-live-photo.swift"
RECEIPT_SOURCE = ROOT / "Sources" / "LocalPhotosSyncUSB" / "ArchiveReceipt.swift"
PROOF_ROOT = ROOT / ".build" / "phone-live-photo-proof"
EXECUTABLE_ROOT = ROOT / ".build" / "probe-executables"
MAX_COPY = 32 * 1024 * 1024
RESOURCE_PAIRS = ((0, 1, "image"), (3, 18, "movie"))


def load_copy_helpers():
    spec = importlib.util.spec_from_file_location("asset_copy_probe_helpers", COPY_RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("copy_helpers_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COPY = load_copy_helpers()
CATALOG = COPY.CATALOG


def emit(status, copied_images=0, copied_movies=0, copied_bytes=0, verified=False, folder=None):
    print(json.dumps({
        "source": "iphone_afc", "status": status,
        "copiedImages": copied_images, "copiedMovies": copied_movies,
        "copiedBytes": copied_bytes, "verified": verified,
        "localFolder": str(folder) if folder is not None else None,
    }, separators=(",", ":")))


def safe_pair_path(directory, filename):
    if not isinstance(directory, str) or not isinstance(filename, str):
        return None
    valid_directory = (
        CATALOG.safe_components(directory, True, 512) and
        ((len(directory.split("/")) == 2 and directory.startswith("DCIM/")) or
         (len(directory.split("/")) == 3 and directory.startswith("PhotoData/CPLAssets/")))
    )
    if not valid_directory or not CATALOG.safe_components(filename, False, 255):
        return None
    path = PurePosixPath(filename)
    suffix = path.suffix
    stem = path.stem
    if not suffix or not stem or re.fullmatch(r"\.[A-Za-z0-9]{1,8}", suffix) is None:
        return None
    movie_name = stem + ".MOV"
    if not CATALOG.safe_components(movie_name, False, 255):
        return None
    return directory, filename, movie_name


def _resource_lengths(connection, asset_id):
    rows = connection.execute(
        """SELECT ZRESOURCETYPE,ZDATASTORESUBTYPE,ZVERSION,ZDATALENGTH
           FROM ZINTERNALRESOURCE WHERE ZASSET=? LIMIT 65""",
        (asset_id,),
    ).fetchall()
    if len(rows) > 64 or any(any(type(value) is not int for value in row) for row in rows):
        return None
    found = {}
    # ZVERSION is private metadata with no established current-version contract.
    # Competing resources remain ambiguous even when their raw versions differ.
    for resource_type, subtype, _raw_version, length in rows:
        for expected_type, expected_subtype, role in RESOURCE_PAIRS:
            if resource_type == expected_type and subtype == expected_subtype:
                found.setdefault(role, []).append(length)
    if any(len(found.get(role, [])) != 1 for _, _, role in RESOURCE_PAIRS):
        return None
    lengths = {role: values[0] for role, values in found.items()}
    if any(type(lengths[role]) is not int or not 0 < lengths[role] <= MAX_COPY for role in ("image", "movie")):
        return None
    return lengths


def select_live_photo_candidate(database, asset_id=None):
    if asset_id is not None and (type(asset_id) is not int or not 1 <= asset_id <= 0x7FFFFFFFFFFFFFFF):
        return None
    uri = database.as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        asset_columns = {row[1] for row in connection.execute("PRAGMA table_info(ZASSET)")}
        required_assets = CATALOG.REQUIRED_COLUMNS | {"ZDIRECTORY", "ZKINDSUBTYPE", "ZADJUSTMENTSSTATE"}
        resource_columns = {row[1] for row in connection.execute("PRAGMA table_info(ZINTERNALRESOURCE)")}
        required_resources = {"ZASSET", "ZRESOURCETYPE", "ZDATASTORESUBTYPE", "ZVERSION", "ZDATALENGTH"}
        if not required_assets.issubset(asset_columns) or not required_resources.issubset(resource_columns):
            return None
        sql = """SELECT Z_PK,ZDIRECTORY,ZFILENAME FROM ZASSET
                 WHERE ZBUNDLESCOPE=0 AND ZVISIBILITYSTATE=0 AND ZHIDDEN=0 AND ZTRASHEDSTATE=0
                   AND ZKIND=0 AND ZKINDSUBTYPE=2 AND ZADJUSTMENTSSTATE=0
                   AND typeof(Z_PK)='integer' AND typeof(ZBUNDLESCOPE)='integer'
                   AND typeof(ZVISIBILITYSTATE)='integer' AND typeof(ZHIDDEN)='integer'
                   AND typeof(ZTRASHEDSTATE)='integer' AND typeof(ZKIND)='integer'
                   AND typeof(ZKINDSUBTYPE)='integer' AND typeof(ZADJUSTMENTSSTATE)='integer'
                   AND ZDIRECTORY IS NOT NULL AND ZFILENAME IS NOT NULL"""
        parameters = ()
        if asset_id is not None:
            rows = connection.execute(sql + " AND Z_PK=? LIMIT 2", (asset_id,)).fetchall()
        else:
            rows = connection.execute(sql + " ORDER BY Z_PK DESC LIMIT 10000", parameters).fetchall()
        if asset_id is not None and len(rows) != 1:
            return None
        for row in rows:
            if len(row) != 3 or type(row[0]) is not int or not isinstance(row[1], str) or not isinstance(row[2], str):
                continue
            paths = safe_pair_path(row[1], row[2])
            if paths is None:
                if asset_id is not None:
                    return None
                continue
            lengths = _resource_lengths(connection, row[0])
            if lengths is None:
                if asset_id is not None:
                    return None
                continue
            return {"assetID": row[0], "directory": paths[0], "imageName": paths[1],
                    "movieName": paths[2], "resourceLengths": lengths}
        return None
    except sqlite3.Error:
        return None
    finally:
        connection.close()


def create_proof_folder():
    try:
        build = ROOT / ".build"
        if not stat.S_ISDIR(build.lstat().st_mode):
            return None
        PROOF_ROOT.mkdir(mode=0o700, exist_ok=True)
        if not stat.S_ISDIR(PROOF_ROOT.lstat().st_mode) or stat.S_IMODE(PROOF_ROOT.lstat().st_mode) != 0o700:
            return None
        folder = PROOF_ROOT / str(uuid.uuid4())
        folder.mkdir(mode=0o700)
        os.chmod(folder, 0o700)
        return folder
    except OSError:
        return None


def compile_verifier():
    try:
        EXECUTABLE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        build_folder = EXECUTABLE_ROOT / str(uuid.uuid4())
        build_folder.mkdir(mode=0o700)
        os.chmod(build_folder, 0o700)
        executable = build_folder / "verify-live-photo"
    except OSError:
        return None
    command = ["swiftc", "-swift-version", "5", str(RECEIPT_SOURCE), str(VERIFIER_SOURCE),
               "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "ImageIO",
               "-framework", "Photos", "-o", str(executable)]
    try:
        result = subprocess.run(command, cwd=ROOT, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return executable if result.returncode == 0 else None


def write_private_json(path, value):
    data = json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("utf-8") + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        return True
    except OSError:
        return False


def copy_private_media(source_folder, destination, expected_bytes):
    source = source_folder / "media.bin"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    source_fd = None
    destination_fd = None
    try:
        source_fd = os.open(source, flags)
        source_info = os.fstat(source_fd)
        if not stat.S_ISREG(source_info.st_mode) or stat.S_IMODE(source_info.st_mode) != 0o600 or source_info.st_size != expected_bytes:
            return False
        destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                 getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0), 0o600)
        copied = 0
        with os.fdopen(source_fd, "rb") as src, os.fdopen(destination_fd, "wb") as dst:
            source_fd = None
            destination_fd = None
            os.fchmod(dst.fileno(), 0o600)
            while True:
                chunk = src.read(64 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > expected_bytes:
                    return False
                dst.write(chunk)
            dst.flush()
            os.fsync(dst.fileno())
        return copied == expected_bytes and destination.stat().st_size == expected_bytes and stat.S_IMODE(destination.stat().st_mode) == 0o600
    except OSError:
        return False
    finally:
        if source_fd is not None:
            os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)


def independently_match_receipt(folder, child_result, expected_bytes):
    if child_result.get("status") != "asset_copy_complete" or child_result.get("stableObserved") is not True:
        return False
    if child_result.get("copiedBytes") != expected_bytes or not COPY.validate_copy_receipt(folder, child_result):
        return False
    receipt = COPY.read_copy_receipt(folder)
    if not isinstance(receipt, dict) or receipt.get("stableObserved") is not True:
        return False
    media = folder / "media.bin"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(media, flags)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != expected_bytes:
            os.close(fd)
            return False
        digest = hashlib.sha256()
        count = 0
        with os.fdopen(fd, "rb") as source:
            while True:
                chunk = source.read(64 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count > expected_bytes:
                    return False
                digest.update(chunk)
        return count == expected_bytes and digest.hexdigest() == receipt["receivedStreamSHA256"]
    except OSError:
        return False


def run_copy(executable, directory, filename, binding, expected_bytes):
    folder = COPY.create_output_folder()
    if folder is None:
        return "local_folder_unavailable", None, None
    payload = directory.encode("utf-8") + b"\n" + filename.encode("utf-8") + b"\n" + binding
    env = os.environ.copy()
    env.pop("USBMUXD_SOCKET_ADDRESS", None)
    env["DYLD_LIBRARY_PATH"] = COPY.DYLD_PATH
    try:
        result = subprocess.run([str(executable), str(folder)], cwd=ROOT, env=env, input=payload,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60, check=False)
    except subprocess.TimeoutExpired:
        return "probe_timeout", folder, None
    except OSError:
        return "probe_process_error", folder, None
    try:
        raw = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError:
        raw = ""
    child = COPY.safe_child_result(raw, folder)
    if child is None:
        return "probe_output_invalid", folder, None
    if child["status"] != "asset_copy_complete":
        return child["status"], folder, child
    if result.returncode != 0:
        return "probe_process_failed", folder, child
    if not independently_match_receipt(folder, child, expected_bytes):
        return "copy_validation_failed", folder, child
    return "asset_copy_complete", folder, child


def completion_result(value):
    expected_keys = {
        "verified", "status", "hashMatches", "imageIdentifierFound", "movieIdentifierFound",
        "identifiersMatch", "imageWidth", "imageHeight", "durationSeconds", "videoTracks",
        "containerPlayable", "livePhotoFilesLoadable", "libraryAccessRequested",
    }
    return (
        isinstance(value, dict) and set(value) == expected_keys and value.get("status") == "verified" and
        value.get("verified") is True and
        value.get("hashMatches") is True and value.get("identifiersMatch") is True and
        value.get("livePhotoFilesLoadable") is True and value.get("containerPlayable") is True and
        value.get("imageIdentifierFound") is True and value.get("movieIdentifierFound") is True and
        value.get("libraryAccessRequested") is False and
        type(value.get("imageWidth")) is int and 0 < value["imageWidth"] <= 8192 and
        type(value.get("imageHeight")) is int and 0 < value["imageHeight"] <= 8192 and
        type(value.get("videoTracks")) is int and value["videoTracks"] > 0 and
        type(value.get("durationSeconds")) in (int, float) and 0 <= value["durationSeconds"] < 3600
    )


def write_completion_marker(folder, verification, image_bytes, movie_bytes):
    if not completion_result(verification):
        return False
    return write_private_json(folder / "complete.json", {
        "source": "iphone_afc", "status": "live_photo_pair_verified",
        "imageBytes": image_bytes, "movieBytes": movie_bytes, "verified": True,
    })


def main(argv=None):
    parser = argparse.ArgumentParser(description="Copy and verify one local Live Photo resource pair.")
    parser.add_argument("--snapshot", required=True, help="Verified phone catalog snapshot folder")
    parser.add_argument("--asset-id", help="Optional positive int64 visible main photo asset ID")
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
    if not isinstance(binding, bytes) or len(binding) != CATALOG.BINDING_BYTES:
        emit("source_binding_unavailable")
        return 1
    candidate = select_live_photo_candidate(database, asset_id)
    if candidate is None:
        emit("live_photo_candidate_unavailable")
        return 1
    proof_folder = create_proof_folder()
    if proof_folder is None:
        emit("local_folder_unavailable")
        return 1
    context = {
        "sourceSnapshot": str(snapshot.resolve()), "assetID": candidate["assetID"],
        "imageName": candidate["imageName"], "movieName": candidate["movieName"],
        "imageResourceBytes": candidate["resourceLengths"]["image"],
        "movieResourceBytes": candidate["resourceLengths"]["movie"],
    }
    if not write_private_json(proof_folder / "pair-context.json", context):
        emit("private_context_failed", folder=proof_folder)
        return 1

    env = os.environ.copy()
    env.pop("USBMUXD_SOCKET_ADDRESS", None)
    env["DYLD_LIBRARY_PATH"] = COPY.DYLD_PATH
    copy_executable = COPY.compile_probe(env)
    if copy_executable is None:
        emit("copy_probe_build_failed", folder=proof_folder)
        return 1
    image_status, image_folder, image_child = run_copy(
        copy_executable, candidate["directory"], candidate["imageName"], binding,
        candidate["resourceLengths"]["image"])
    if image_status != "asset_copy_complete":
        emit(image_status, folder=proof_folder)
        return 1
    image_suffix = PurePosixPath(candidate["imageName"]).suffix
    image_bytes = image_child["copiedBytes"]
    if not copy_private_media(image_folder, proof_folder / ("still" + image_suffix), image_bytes):
        emit("local_media_copy_failed", folder=proof_folder)
        return 1
    movie_status, movie_folder, movie_child = run_copy(
        copy_executable, candidate["directory"], candidate["movieName"], binding,
        candidate["resourceLengths"]["movie"])
    if movie_status != "asset_copy_complete":
        emit(movie_status, copied_images=1, copied_bytes=image_bytes, folder=proof_folder)
        return 1

    if not copy_private_media(movie_folder, proof_folder / "motion.MOV", movie_child["copiedBytes"]):
        emit("local_media_copy_failed", copied_images=1, copied_bytes=image_bytes, folder=proof_folder)
        return 1
    inputs = {
        "imageFile": str(proof_folder / ("still" + image_suffix)),
        "movieFile": str(proof_folder / "motion.MOV"),
        "imageFolder": str(image_folder), "movieFolder": str(movie_folder),
        "proofFolder": str(proof_folder),
    }
    inputs_path = proof_folder / "verifier-inputs.json"
    if not write_private_json(inputs_path, inputs):
        emit("verifier_input_failed", copied_images=1, copied_movies=1,
             copied_bytes=image_child["copiedBytes"] + movie_child["copiedBytes"], folder=proof_folder)
        return 1
    verifier = compile_verifier()
    if verifier is None:
        emit("verifier_build_failed", copied_images=1, copied_movies=1,
             copied_bytes=image_child["copiedBytes"] + movie_child["copiedBytes"], folder=proof_folder)
        return 1
    try:
        result = subprocess.run([str(verifier), str(inputs_path)], cwd=ROOT, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        emit("verification_timeout", copied_images=1, copied_movies=1,
             copied_bytes=image_child["copiedBytes"] + movie_child["copiedBytes"], folder=proof_folder)
        return 1
    except OSError:
        emit("verification_process_error", copied_images=1, copied_movies=1,
             copied_bytes=image_child["copiedBytes"] + movie_child["copiedBytes"], folder=proof_folder)
        return 1
    try:
        verification = json.loads(result.stdout.decode("utf-8", errors="strict").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        verification = None
    if result.returncode != 0 or not completion_result(verification):
        emit("live_photo_verification_failed", copied_images=1, copied_movies=1,
             copied_bytes=image_child["copiedBytes"] + movie_child["copiedBytes"], folder=proof_folder)
        return 1
    if not write_completion_marker(proof_folder, verification,
                                   image_child["copiedBytes"], movie_child["copiedBytes"]):
        emit("completion_marker_failed", copied_images=1, copied_movies=1,
             copied_bytes=image_child["copiedBytes"] + movie_child["copiedBytes"], folder=proof_folder)
        return 1
    total = image_child["copiedBytes"] + movie_child["copiedBytes"]
    emit("live_photo_pair_verified", copied_images=1, copied_movies=1, copied_bytes=total,
         verified=True, folder=proof_folder)
    return 0


if __name__ == "__main__":
    sys.exit(main())
