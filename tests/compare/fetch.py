# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Download the parcel dataset the comparison suite measures against.

The suite needs real cadastral data — adjacent parcels that share boundaries,
with the hairline gaps and near-parallel edges that break overlay engines. The
GeoMoose demo data is exactly that, and it is public, so the numbers in the
README are reproducible off this machine.

    .venv/bin/python tests/compare/fetch.py

Writes `tests/compare/data/parcels.geoparquet` and verifies its SHA-256. If the
file is already there and correct, it does nothing.
"""
import argparse
import hashlib
import sys
import urllib.request
from pathlib import Path

URL = 'https://raw.githubusercontent.com/geomoose/gm3-demo-data/main/demo/parcels/parcels.geoparquet'
SHA256 = '764c0d0a2c7cb5941dde01fb882f9397bd457d1aa6a1550300c96b0d1f2e82a5'
DESTINATION = Path(__file__).parent / 'data' / 'parcels.geoparquet'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(destination=DESTINATION, url=URL, expected=SHA256, force=False):
    if destination.exists() and not force:
        if digest(destination) == expected:
            print(f'{destination} already present and verified')
            return destination
        print(f'{destination} has the wrong checksum, re-downloading', file=sys.stderr)

    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f'downloading {url}')
    partial = destination.with_suffix(destination.suffix + '.part')
    with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as out:
        while chunk := response.read(1 << 16):
            out.write(chunk)

    got = digest(partial)
    if got != expected:
        partial.unlink(missing_ok=True)
        sys.exit(f'checksum mismatch\n  expected {expected}\n  got      {got}')
    # Only move a verified file into place, so a failed run never leaves a
    # half-written dataset that a later run would trust.
    partial.replace(destination)
    print(f'wrote {destination} ({destination.stat().st_size:,} bytes, sha256 verified)')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=DESTINATION)
    parser.add_argument('--force', action='store_true', help='re-download even if present')
    args = parser.parse_args()
    fetch(args.out, force=args.force)
    return 0


if __name__ == '__main__':
    sys.exit(main())
