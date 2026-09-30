#!/usr/bin/env python3
"""Extract headers and libraries from Homebrew's verified cached bottles."""
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parents[2]
cache = root / ".build/afc-homebrew-cache/downloads"
destination = root / ".build/afc-runtime"
if not hasattr(tarfile, "data_filter"):
    raise SystemExit("Use Python 3.12+ for safe archive extraction.")
archives = list(cache.glob("*.tar.gz"))
if not archives:
    raise SystemExit("Run the documented Homebrew fetch first.")
if destination.exists() and any(destination.iterdir()):
    raise SystemExit("Runtime folder already contains files; existing files preserved.")
destination.mkdir(parents=True, exist_ok=True)
for archive in archives:
    with tarfile.open(archive) as bundle:
        members = [
            member for member in bundle.getmembers()
            if "lib" in Path(member.name).parts or "include" in Path(member.name).parts
        ]
        bundle.extractall(destination, members=members, filter="data")
print("Local AFC headers and libraries extracted. No packages installed globally.")
