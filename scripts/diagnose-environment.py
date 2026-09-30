#!/usr/bin/env python3
"""Report aggregate macOS USB and Apple mobile-device Bonjour discovery counts."""

from __future__ import annotations

import argparse
import json
import platform
import plistlib
import re
import shutil
import subprocess
import sys
from typing import Iterable

SERVICE_TYPE = "_apple-mobdev2._tcp."
_EVENT_RE = re.compile(r"\b(Add|Rmv|Remove)\b", re.IGNORECASE)
_PRODUCT_KEYS = {"usb product name", "kusbproductstring"}


def count_usb_ios_products(plist_data: bytes) -> int:
    """Count recognizable iPhone/iPad/iPod product labels in an ioreg plist."""
    try:
        root = plistlib.loads(plist_data)
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise ValueError("malformed ioreg plist") from error

    count = 0

    def visit(value: object) -> None:
        nonlocal count
        if isinstance(value, dict):
            labels = [
                item.casefold()
                for key, item in value.items()
                if isinstance(key, str) and key.casefold() in _PRODUCT_KEYS and isinstance(item, str)
            ]
            if any(any(product in label for product in ("iphone", "ipad", "ipod")) for label in labels):
                count += 1
            for child in value.values():
                visit(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                visit(child)

    visit(root)
    return count


def parse_bonjour_events(lines: Iterable[str], service_type: str = SERVICE_TYPE) -> int:
    """Return active unique instance count from dns-sd browse event lines."""
    active: set[tuple[str, str]] = set()
    wanted = service_type.rstrip(".").lower()
    for line in lines:
        fields = line.split()
        event_index = next(
            (i for i, field in enumerate(fields) if _EVENT_RE.fullmatch(field)),
            None,
        )
        if event_index is None:
            continue
        event_name = fields[event_index].lower()
        service_index = next(
            (i for i, field in enumerate(fields) if field.rstrip(".").lower() == wanted),
            None,
        )
        if service_index is None or service_index != event_index + 4 or service_index + 1 >= len(fields):
            continue
        flags, interface = fields[event_index + 1 : event_index + 3]
        if not flags.isdigit() or not interface.isdigit():
            continue
        # Instance names may contain spaces; they remain process-local and are never emitted.
        instance = " ".join(fields[service_index + 1 :]).strip()
        if not instance:
            continue
        domain = fields[service_index - 1].lower() if service_index else ""
        key = (interface, domain, instance.casefold())
        if event_name == "add":
            active.add(key)
        else:
            active.discard(key)
    return len({(domain, instance) for _, domain, instance in active})


def _run_ioreg(command: str, timeout: float) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            [command, "-p", "IOUSB", "-a"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except OSError:
        return None, "error"
    if result.returncode != 0:
        return None, "error"
    try:
        return count_usb_ios_products(result.stdout.encode()), "ok"
    except ValueError:
        return None, "error"


def _run_bonjour(command: str, seconds: float) -> tuple[int | None, str]:
    process: subprocess.Popen[str] | None = None
    try:
        process = subprocess.Popen(
            [command, "-B", SERVICE_TYPE, "local."],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            stdout, _ = process.communicate(timeout=seconds)
            if process.returncode != 0:
                return None, "error"
            return parse_bonjour_events(stdout.splitlines()), "ok"
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                stdout, _ = process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, _ = process.communicate()
            return parse_bonjour_events(stdout.splitlines()), "window_complete"
    except OSError:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        return None, "error"


def diagnose(browse_seconds: float = 5.0) -> dict[str, object]:
    is_macos = platform.system() == "Darwin"
    ioreg_path = shutil.which("ioreg") if is_macos else None
    dns_sd_path = shutil.which("dns-sd") if is_macos else None
    usb_count, usb_status = (None, "unavailable")
    bonjour_count, bonjour_status = (None, "unavailable")
    if ioreg_path:
        usb_count, usb_status = _run_ioreg(ioreg_path, timeout=5.0)
    if dns_sd_path:
        bonjour_count, bonjour_status = _run_bonjour(dns_sd_path, seconds=browse_seconds)
    return {
        "macos_version": platform.mac_ver()[0] if is_macos else None,
        "tools": {"ioreg": bool(ioreg_path), "dns-sd": bool(dns_sd_path)},
        "usb_ios_products": {"count": usb_count, "status": usb_status},
        "bonjour_sync_services": {"count": bonjour_count, "status": bonjour_status},
        "scope": "Discovery counts only; this does not grant access to the media library.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browse-seconds", type=float, default=5.0, help="Bonjour browse duration (1–30 seconds).")
    args = parser.parse_args()
    if not 1.0 <= args.browse_seconds <= 30.0:
        parser.error("--browse-seconds must be between 1 and 30")
    print(json.dumps(diagnose(args.browse_seconds), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
