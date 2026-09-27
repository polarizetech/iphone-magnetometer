@AGENTS.md

# CLAUDE.md — iphone-magnetometer (FieldLab)

A **tool**: an iPhone magnetometer recorder (`BiomimeticRadar/`), its server and store (`serve.py`,
`store.py`), readers (`session.py`, `census.py`, `bands.py`), and CardioMag Probe (`cardiomagprobe/`).
This repo is **public**. Read `README.md` first.

## It is a tool, and stays one

- **No findings here.** What a recording shows, claims, results and study-specific analysis belong to
  the study using the tool (its repo and the research corpus), never to this repo, its changelog or
  its comments. Measurements *of the tool itself* are allowed, preregistered in `EXPERIMENTS.md`.
- **No knowledge of any particular study or deployment.** A consumer is configured
  (`FIELDLAB_ANALYSIS`, `FIELDLAB_PREFIXES`, `FIELDLAB_DESIGN`), never searched for by name.
- **No private data**: no hostnames, team IDs, personal paths, or location in fixtures.
- Before adding a module, ask whether it acquires, stores or reads the stream. If it interprets a
  recording, it belongs in the study.

## Rules that protect data

- **Never `rm -rf streams/`.** It is the only copy: the phone deletes its own once the server acks.
  Tests use `FIELDLAB_STREAMS=$(mktemp -d)`; `dev_check.py` already does.
- **Never change the bundle id `com.biomimeticradar.app`.** iOS keys the app's container to it, and
  unsent chunks live there. The Xcode names say BiomimeticRadar; the product is FieldLab.
- A stored chunk is never overwritten: different bytes for a stored seq get 409.

## The seams

- **The wire format** is one raw-DEFLATE file per chunk: a JSON header line, then `raw.csv`. It is
  pinned by a Swift-written fixture (`analysis/fixtures/sample.chunk`) that the Python gate decodes.
- **`BandRegistry.swift` is the single source of the band catalogue**; `bands.py` parses it. Python
  also reads `InterferenceRegistry.swift` and `StreamChunk.swift` with regexes, so those three carry
  `swift-format-ignore-file`. Reformatting them empties `/api/bands`.
- `serve.py`, `store.py` and `bands.py` are **standard library only and run on Python 3.9**;
  `session.py` and `census.py` add numpy.

## Checks

`make check` (ruff, swift-format, `dev_check.py`), `make swift-test`, `make cardiomag-test`. The
Xcode test target for FieldLab does not build: several of its tests cover code that is only in the
SwiftPM core, so run those with `swift test`.

## Open defect

The calibrated `CMDeviceMotion.magneticField` and its accuracy are not logged beside the raw channel.
The raw channel includes the phone's own MagSafe magnets (hundreds of µT); logging both makes that
offset visible. Needs an app build.
