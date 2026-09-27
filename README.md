# iphone-magnetometer — FieldLab

**Kind:** tool · **Version:** 0.1.0

An iPhone magnetometer recorder, and the small server that keeps what it records. FieldLab streams
the phone's **raw** magnetometer, motion and timing to a Mac in self-describing chunks, keeps them in
a store on disk, and draws what arrived. It records; it does not interpret. What a recording means is
the job of whatever study uses it.

It is an experimental instrument, not a medical or biomagnetic detector.

## What is here

| | |
|---|---|
| **FieldLab** (`BiomimeticRadar/`) | SwiftUI app. Streams the raw magnetometer (not Apple's calibrated field), device motion, timing and optional GPS. Deletes a chunk from the phone only once the server acknowledges it. |
| **Server and viewer** (`serve.py`, `web/`) | Receives chunks into `streams/`, serves a live dashboard, and runs a consuming study's analysis as jobs. Standard library only. |
| **Readers** (`store.py`, `session.py`, `census.py`, `bands.py`) | Load a stretch of the stream as one session with its measured rate and clock jitter, and attribute its variance to named bands. |
| **CardioMag Probe** (`cardiomagprobe/`) | A second app for heartbeat-locked recordings at chest distances, with camera PPG timing, and a Python analysis of its exports. |
| [`INTEGRATION.md`](INTEGRATION.md) | Reading the stream from your own project: web page, Python, your own page and analysis. |
| [`INTERFERENCE.md`](INTERFERENCE.md) | How an iPhone's own parts write into its magnetometer, and the view-only filters for them. |

## Run

**The apps** need Xcode 16+ and a physical iPhone; Core Motion is not meaningful in Simulator.

1. Copy `config/Local.xcconfig.example` to `config/Local.xcconfig` and put your Apple Developer Team
   ID in it (the file is git-ignored).
2. Open `BiomimeticRadar.xcodeproj` (or `cardiomagprobe/CardioMagProbe.xcodeproj`) and run.
3. In the app's Stream settings, set the server URL to wherever `serve.py` is reachable from the phone.

`project.yml` is the source of each Xcode project (`xcodegen generate`).

**The server** (Python 3.9+, standard library only):

```bash
python3 serve.py 8212        # http://127.0.0.1:8212/
```

Keep it on a private network (a tailnet or LAN). It has no authentication: anyone who can reach it
can read the stream and add to it.

| variable | does |
|---|---|
| `FIELDLAB_STREAMS` | where the store lives (default `streams/` here) |
| `FIELDLAB_ANALYSIS` | a study's analysis directory: its `run.py` and `.venv` for the job runner, and an optional `../watch/` page |
| `FIELDLAB_PREFIXES` | extra URL prefixes a reverse proxy mounts the server under, comma-separated |
| `FIELDLAB_DESIGN` | an optional design-system directory for the web page's fonts and colours |

Any of these can also go in a git-ignored `fieldlab.env` beside `serve.py`, one `KEY=value` per line,
for a launcher that cannot set environment variables. Relative paths there resolve from that folder.

**`streams/` is the only copy of every recording.** The phone deletes its copy once the server
acknowledges a chunk. Back it up; never point a test at it (use `FIELDLAB_STREAMS=$(mktemp -d)`).

## Checks

```bash
uv sync
make check          # ruff, swift-format, and the gate (dev_check.py) against a scratch store
make swift-test     # the XCTests over the platform-independent core
make cardiomag-test # CardioMag Probe's Python analysis tests
```

## Validating the tool

Measurements of the instrument itself (what rate the phone really delivers, what the pipeline can
recover) follow [adaptive preregistration](https://github.com/polarizetech/adaptive-preregistration),
installed in `.agents/`: predictions are written and tagged before the run. They are registered in
[`EXPERIMENTS.md`](EXPERIMENTS.md). Research findings made *with* FieldLab do not live here.

## Licence and citation

Code is MIT; documentation and test data are CC BY 4.0 ([`LICENSE`](LICENSE)). To cite it, see
[`CITATION.cff`](CITATION.cff).
