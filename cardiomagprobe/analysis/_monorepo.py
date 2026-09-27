"""Where the injection sweeps find `injrec`, which is not in this repo.

`injection_sweep`, `ladder2` and `prior_ladder` plant synthetic cardiac sources with `injrec`
(`tools/injection-recovery` in the audio-projects monorepo). This puts it, and this repo's own
readers (store, session, bands, census), on `sys.path`, or raises saying where it looked.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def monorepo_root() -> Path:
    for c in Path(__file__).resolve().parents:
        if (c / "tools").is_dir() and (c / "falsify").is_dir():
            return c
    raise RuntimeError("monorepo root not found. This script plants synthetic cardiac sources with injrec "
                       "(tools/injection-recovery), which lives in the audio-projects monorepo; run it from a "
                       "checkout where this repo is tools/iphone-magnetometer. session and census are in this repo.")


def use_injrec() -> Path:
    """Put this repo and injrec on sys.path; return the monorepo root."""
    root = monorepo_root()
    for p in (REPO, root / "tools" / "injection-recovery"):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))
    return root
