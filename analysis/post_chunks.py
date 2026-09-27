#!/usr/bin/env python3
"""Post spool files to the server by hand — the escape hatch when the phone could not.

    python3 analysis/post_chunks.py ~/Downloads/FieldLab\\ Spool            # localhost:8212
    python3 analysis/post_chunks.py <dir> --base https://<host>.<tailnet>.ts.net/biomimetic-radar
    python3 analysis/post_chunks.py <dir> --delete                          # remove once accepted

The phone's spool lives in **Files ▸ On My iPhone ▸ FieldLab ▸ FieldLab Spool**. If the Mac was
unreachable for a long stretch — no tailnet, server down, a trip — the chunks are still sitting
there. Copy the folder off (AirDrop, Finder, iCloud) and run this. Ingest is idempotent, so
re-posting a chunk the server already holds is reported as a duplicate and changes nothing.

Stdlib only, so it runs without the analysis venv.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

CONTENT_TYPE = "application/x-fieldlab-chunk"


def post(base: str, body: bytes, timeout: float = 60) -> dict:
    req = urllib.request.Request(
        base.rstrip("/") + "/api/stream/chunk", data=body, method="POST",
        headers={"Content-Type": CONTENT_TYPE, "X-FieldLab-Compression": "deflate-raw"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("directory", help="a folder of .chunk files (the phone's spool)")
    ap.add_argument("--base", default="http://127.0.0.1:8212")
    ap.add_argument("--delete", action="store_true",
                    help="delete each file once the server has accepted it (default: keep everything)")
    args = ap.parse_args()

    files = sorted(Path(args.directory).glob("*.chunk"))
    if not files:
        print(f"no .chunk files in {args.directory}", file=sys.stderr)
        return 1
    sent = dup = failed = 0
    for path in files:
        try:
            ack = post(args.base, path.read_bytes())
        except (urllib.error.URLError, OSError) as exc:
            print(f"{path.name}: FAILED — {exc}")
            failed += 1
            continue
        if ack.get("duplicate"):
            dup += 1
        else:
            sent += 1
        print(f"{path.name}: {ack.get('message')}")
        # Deleting is opt-in and only ever after a 2xx: the same rule the phone's spool follows.
        if args.delete and ack.get("ok"):
            path.unlink()
    print(f"\n{sent} stored, {dup} already held, {failed} failed, of {len(files)} files")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
