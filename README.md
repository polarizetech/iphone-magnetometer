# iphone-magnetometer

**Kind:** study · **Stage:** PROBE

**Can a stock iPhone's magnetometer, with coherent processing, recover a coded or physiological magnetic
signal below its instantaneous noise floor?**

This repo holds the instrument used to find out: an iPhone recorder, the server that keeps what it records,
and the tests that decide which lines in a recording are real. It is an experimental instrument, not a
medical or biomagnetic detector. Findings are written up in the research corpus, not here (see
[`RESEARCH.md`](RESEARCH.md)).

## What is here

| | |
|---|---|
| **FieldLab** (`BiomimeticRadar/`) | SwiftUI app. Streams the raw magnetometer, motion and timing to a server in self-describing chunks, and deletes its copy only once the server acknowledges it. |
| **Server and viewer** (`serve.py`, `web/`) | Receives chunks into `streams/`, the only copy of every recording, and draws what arrived. Standard library only. |
| **Readers** (`store.py`, `session.py`, `census.py`, `bands.py`) | Load a stretch of the stream as one session, and attribute its variance to named bands. |
| **CardioMag Probe** (`cardiomagprobe/`) | A second app asking the cardiac version of the question directly, with its own analysis. |
| [`INTEGRATION.md`](INTEGRATION.md) | Reading the stream from another project. |
| [`INTERFERENCE.md`](INTERFERENCE.md) | How the phone's own parts write into its magnetometer. |
| [`CHANGELOG.md`](CHANGELOG.md) | What changed, including what turned out to be wrong. |

## Where it stands

- The recorder and store have run as an always-on stream since August 2026.
- The strongest unexplained line so far (about 1.69 Hz) fits both "cardiac-like" and "rotating machinery".
  The recording cannot tell them apart.
- An automatic alias test was withdrawn on 2026-09-15, because it could not tell an alias from a real
  line. The replacement is a manual test: record at 100 Hz, then at 64 Hz. Whether the phone actually
  delivers 64 Hz has not been measured yet.
- Open questions are queued in [`EXPERIMENTS.md`](EXPERIMENTS.md).

## Run

**The apps** need Xcode 16+ and a physical iPhone; Core Motion is not meaningful in Simulator. Copy
`config/Local.xcconfig.example` to `config/Local.xcconfig` and put your own Apple Developer Team ID in it
(the file is git-ignored), then open `BiomimeticRadar.xcodeproj` and run. In the app's Stream settings, set the
server URL to wherever `serve.py` is reachable from the phone. `project.yml` is the source of the Xcode
project (`xcodegen generate`).

**The server:**

```bash
python3 serve.py 8212        # http://127.0.0.1:8212/
```

**The checks:**

```bash
uv sync
make check                   # the protocol check, ruff, swift-format and the gate (dev_check.py)
make swift-test              # 70 XCTests over the platform-independent core
```

## Dependencies

Recording, storing and viewing need nothing beyond Python 3.9 and Xcode; `census.py` adds numpy. Some of
CardioMag Probe's analysis scripts use shared libraries that are **not published** (`cardiac-events`,
`injection-recovery`). Each script that needs one stops and names it rather than running without it.

## Preregistration

New experiments follow [adaptive preregistration](https://github.com/polarizetech/adaptive-preregistration),
installed in `.agents/`: predictions are written and tagged before the run that tests them. The repo
follows the [study protocol](https://github.com/polarizetech/scientific-research-scaffold) layout, with
`STUDY.toml` as its manifest.

## Licence and citation

Code is MIT; documentation and data are CC BY 4.0 ([`LICENSE`](LICENSE)). To cite it, see
[`CITATION.cff`](CITATION.cff).
