"""research_path — where this instrument's FINDINGS live, which is not in this repo.

**The rule this file exists to hold: an instrument records, a corpus decides.** FieldLab produces
recordings and measurements; what any of it *means* is tiered, scoped and amended in
`polarizetech/research`, under `projects/bioem-propagation`. Keeping findings here would give the
same number two homes and no way to tell which is current — and this bench already paid for that
lesson once, when the research corpus was tracked as BOTH a plain directory and a submodule and
every edit had to be committed twice or the copies silently diverged.

So this is a **declared path, deliberately not a checkout.** There is exactly one working copy of
the corpus on a machine and this module finds it:

    $FIELDLAB_RESEARCH_DIR      an explicit override, checked first
    $RESEARCH_DIR               the monorepo-wide convention
    <parents>/research          a monorepo checkout (this repo as a submodule under tools/)
    <parent-of-this-repo>/research      a standalone clone beside this one

`resolve()` **raises rather than guessing**, with the clone command in the message. A findings
directory that silently does not exist is how a measurement gets written to a path nobody reads.
"""
from __future__ import annotations

import os
from pathlib import Path

HERE = Path(__file__).resolve().parent

#: The corpus project that owns everything this instrument produces. Sessions go in `sessions/`,
#: standing arguments in `mechanisms/`, tiered claims in `claims/`, planned tests in `probes/`.
CORPUS_PROJECT = "projects/bioem-propagation"
CLONE_HINT = "git clone git@github.com:polarizetech/research.git"


def candidates() -> list[Path]:
    """Every path that will be tried, in order — exposed so a failure can print the search."""
    out: list[Path] = []
    for var in ("FIELDLAB_RESEARCH_DIR", "RESEARCH_DIR"):
        env = os.environ.get(var)
        if env:
            out.append(Path(env).expanduser())
    for parent in HERE.parents:
        out.append(parent / "research")
    return out


def find() -> Path | None:
    """The corpus checkout, or None. A directory only counts if it holds the project we write to —
    an empty `research/` is an uninitialised submodule, not a corpus, and treating it as one writes
    findings into a directory that a later `submodule update` will overwrite."""
    for c in candidates():
        if (c / CORPUS_PROJECT).is_dir():
            return c
    return None


def resolve() -> Path:
    """The corpus checkout, or raise with the search and the fix."""
    found = find()
    if found is not None:
        return found
    searched = "\n  ".join(str(c) for c in candidates())
    raise FileNotFoundError(
        "the research corpus is not on this machine, so there is nowhere to write findings.\n"
        f"  {CLONE_HINT}\n"
        "  then set FIELDLAB_RESEARCH_DIR, or clone it beside this repo.\n"
        f"searched:\n  {searched}"
    )


def findings_dir() -> Path:
    """`projects/bioem-propagation` inside the corpus."""
    return resolve() / CORPUS_PROJECT


if __name__ == "__main__":
    found = find()
    if found is None:
        print("research corpus: NOT FOUND")
        print(f"  {CLONE_HINT}")
        for c in candidates():
            print(f"  tried {c}")
        raise SystemExit(1)
    d = findings_dir()
    print(f"research corpus: {found}")
    print(f"findings:        {d}")
    for sub in ("sessions", "mechanisms", "claims", "probes"):
        p = d / sub
        print(f"  {sub:11s} {len(list(p.glob('*.md'))) if p.is_dir() else 0:3d} documents"
              f"{'' if p.is_dir() else '   (absent)'}")
