# FieldLab — iPhone magnetic signal test platform

FieldLab is a native SwiftUI research app for testing how far coherent processing can recover a deliberately coded magnetic signal below the instantaneous noise of an iPhone magnetometer.

**Standalone repo.** It also rides in the `audio-projects` monorepo as a submodule at
`tools/iphone-magnetometer`. **The recorder and the server import nothing from that monorepo** —
everything monorepo-side they touch is optional and announces itself when absent (`python3
dev_check.py` prints its skips). The analysis scripts do use shared libraries, and each names the
one it needs and raises with the install line rather than degrading. Findings are written to the
`research` corpus, not to this repo — see `research_path.py`.

## Built on

The shared libraries this instrument and its analysis run against. All of them live in the
`audio-projects` monorepo under `tools/`, and each is a separate tool with its own tests and
docs — start at `tools/REGISTRY.md` there.

| tool | version | what it does here | reached by | absent → |
|---|---|---|---|---|
| `universal-wave-translation-layer` (`uwtl`) | 0.2.1 | `uwtl.spectral` — every line, floor, prominence bar and variance share in `census.py`; `uwtl.adequacy` in `dev_check.py` | installed package | `census.py` will not import |
| `universal-wave-translation-layer/tools/biosignal-signature` (`biosig`) | 0.1.1 | `biosig.morphology` — what shape a periodic line has (rate stability, harmonics, rate modulation), used by the consumer's `fingerprint.py` | installed package | the consumer's morphology reading is unavailable |
| `cardiac-events` | 0.1.0 | R-peak detection, the two-clock map and event-locked averaging in `cardiomagprobe/analysis/cardiomag_analysis.py` | installed package | raises, naming `pip install -e <monorepo>/tools/cardiac-events` |
| `injection-recovery` (`injrec`) | unversioned, path import | the efficiency sweeps — `injection_sweep.py`, `ladder2.py`, `prior_ladder.py` inject a known cardiac source into **real** phone noise and refuse a bound the curve never reached | `sys.path` into the monorepo | raises, naming the monorepo root it looked for |
| `dataset-fetch` | 0.1.0 | the `station` job's Sierra Nevada ELF hour (a range read out of a 26.7 GB Zenodo archive), and the `spaces` provider that reads the `streams/` backup | the consumer's analysis venv | the station panel reports no reading |
| `elf-stations` | unversioned, path import | the ELF archive's file format and its coverage table, so the station hour arrives as a `Session` | `sys.path` from the consumer's `stations.py` | reported absent, not guessed at |
| `dataset-publish` | — | the one-off private backup of `streams/` to the object store (`recordings/fieldlab/streams`) | run by hand in the monorepo | the store is the only copy, which it is anyway |
| `design` | — | the web viewer's tokens and fonts | HTTP, `tools_path.DESIGN` | the page falls back; a 404, not a crash |
| `tailscale` | — | serving at `/iphone-magnetometer/` on the tailnet | the gateway, on demand | run `serve.py` directly on localhost |

**Nothing in the monorepo is required to record.** The recorder, the wire format, the stream store
and the live viewer work with none of the above installed; the table is what the *analysis* costs.

## Run

1. Install Xcode 16 or newer and select it with `sudo xcode-select -s /Applications/Xcode.app` if needed.
2. Regenerate the project after editing `project.yml`: `xcodegen generate`.
3. Open `BiomimeticRadar.xcodeproj`, choose an iPhone signing team, and run on a physical iPhone. Core Motion acquisition is not meaningful in Simulator.
4. Grant optional location access only if GPS metadata is desired.

The app stores raw and processed data separately in its Documents directory and exposes experiment bundles through the system share sheet.

## First validation

Use **Simulator** in the app to validate the 8.3 Hz lock-in and coded matched-filter path. Then use **Experiment → Calibration wizard** for staged physical validation and randomized blinded ON/OFF trials.

This is an experimental instrument, not a biomagnetic or planetary-signal detector. Results are labelled according to preregistration, significance, replication, and null-control status.

