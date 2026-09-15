# CLAUDE.md — `iphone-magnetometer`

**Renamed from `fieldlab-recorder` on 2026-09-15** (repo, monorepo submodule path, and gateway
folder). The repo is about one question — *can a stock iPhone do this?* — so it is named for the
device, leaving room for other recorders built on the same concept. **The app is still FieldLab**
and the iOS bundle id `com.biomimeticradar.app` is unchanged: iOS keys the app's container to it,
and the phone holds unsent chunks there. Every old URL still resolves through `tailscale.json`
aliases (`/fieldlab-recorder`, `/biomimetic-radar` — the phone's default upload endpoint).


**The phone as a magnetometer.** The iOS recorder, the chunk wire format, the always-on stream
store, and the web dashboard over it. Wiring a consumer in → the API list at the top of
[`serve.py`](serve.py).

Run: `python3 serve.py 8212`.
Tests: `FIELDLAB_STREAMS=$(mktemp -d) python3 dev_check.py` (**94/94** standalone).

## ⚠ THIS IS ITS OWN REPO (`polarizetech/iphone-magnetometer`, extracted 2026-08-31)

It rides in the `audio-projects` monorepo as a **submodule at `tools/iphone-magnetometer`**, the same
arrangement `universal-wave-translation-layer` and `research` have. A fresh monorepo clone needs
`git clone --recurse-submodules`, or `git submodule update --init tools/iphone-magnetometer`; the
monorepo stores a 40-character pointer, and changing this tool is a commit **here** plus a pointer
commit **there**.

**The bar that made extraction possible, and the one to keep:** this repo imports **nothing** from
the monorepo. Every monorepo-side thing is optional and, when absent, is announced rather than
passed over — `dev_check.py` prints four `SKIP` lines standalone and they name what is missing.

| what the monorepo adds | how it is reached | absent → |
|---|---|---|
| `tools/design` | `tools_path.DESIGN`, one module, HTTP only | the page falls back; a 404, not a crash |
| `tools/tailscale/gateway.py` | `dev_check` only | `SKIP`, loudly |
| a consumer's `session.py` | whatever `serve.py`'s `_analysis_dir()` finds | `SKIP` — the wire-format parity check is the seam between the halves |
| `SIGNAL-TAXONOMY.md` | searched for | `SKIP` — it is CLAIM-side and stays with the falsify entry |

`serve.py` finds its consumer's analysis directory by `$FIELDLAB_ANALYSIS` → a monorepo search →
`./analysis`, so it has never had a hardcoded consumer path and does not gain one now.

## `session.py` and `census.py` — the reader moved in (2026-09-15)

The record loader (`session`: an export directory or a window of the stream store → one `Session`,
with the measured rate and clock jitter) and the variance partition (`census`: every unit of AC
variance attributed to a named band, an anonymous `U-nn` line, or left unattributed) moved here from
`falsify/round-the-world-elf/analysis/fieldlab/`. They sit beside `bands.py` and `store.py` for the
same reason those do: **the thing that writes a format and the thing that reads it belong together**,
and three separate folders were already reaching across the monorepo for them.

- **They import only the standard library, numpy and this repo's `bands`**, asserted by AST in
  `dev_check.py`, so the repo still imports nothing from the monorepo.
- **The wire-format parity check stopped being skippable.** It used to depend on a consumer being on
  the path; it now reads this repo's own `session.py`, so it runs standalone too.
- `dev_check.py` also loads the simulated phone's scratch store with `session.load_stream` and runs a
  `census` over it (shares sum to 1, and `census.band_registry is bands`). It skips loudly without
  numpy.
- **The monorepo keeps one-line redirects, not copies.** Each replaces itself in `sys.modules` with
  this module, so `from fieldlab import census` in either falsify entry returns this exact object —
  a test that patches it patches the real thing, and there is only ever one `Band` class.
  `falsify/round-the-world-elf/analysis/fieldlab/_instrument.py` holds the finder and refuses loudly
  if some other module named `session` or `census` got onto `sys.path` first.

## `cardiomagprobe/` — the second iPhone app (folded in 2026-09-15)

A separate SwiftUI app (**CardioMag Probe**) asking the cardiac question directly: a
heartbeat-correlated magnetometer component at chest distances, with **camera-fingertip PPG timing**
(`CameraPPGRecorder.swift`), manual beat marks, or imported beat times as the trigger. It came from
`projects/iphone-meg-2.0` with its analysis (`cardiomag_analysis.py`, synthetic validation, the
prior/injection ladders, site survey, body signals, hard-iron calibration) and docs
(`PROTOCOL.md`, `SCHEMA.md`, `ARTIFACT_CHECKLIST.md`).

**Source only; no build output and no history** — the origin had committed ~9,830 Xcode build
files, and carrying its history would have put them in this repo forever. **`calibrate`,
`bodysignals` and `site_survey` run standalone** since `session` and `census` moved in (below).
**`ladder2` and `prior_ladder` are the one remaining tie**: they plant synthetic cardiac sources with
`injrec` from the monorepo's `tools/injection-recovery`, and raise with that reason when run
outside it. **`cardiomag_analysis.py` now depends on `cardiac-events`** (the monorepo's
`tools/cardiac-events`, installable, imports nothing else from the monorepo). Its epoch cutter,
baseline correction, circular beat shift and held-out template are that tool's, checked
bit-identical before and after on the synthetic dataset. `test_analysis.py` (3 tests) passes with
it installed: `pip install -e <monorepo>/tools/cardiac-events`.

**Note the PPG trigger** against `research/.../mechanisms/ecg-gated-magnetometry.md`: PPG timing
is adequate as an HRV covariate and was rejected as a *gate*, because pulse-arrival jitter
oscillates with respiration (20 ms retains 0.001 of a 30 Hz component).

## Findings do not live here — `research_path.py`

**An instrument records; a corpus decides.** Everything this rig measures is written up in
`polarizetech/research` under `projects/bioem-propagation`, and `research_path.py` resolves that
checkout (`$FIELDLAB_RESEARCH_DIR` → `$RESEARCH_DIR` → a monorepo sibling → an adjacent clone),
**raising with the clone command rather than guessing**. `python3 research_path.py` prints where it
resolved and what is there.

It is a **declared path, deliberately not a submodule.** A nested checkout would mean two working
copies of one repo inside the monorepo, which is the exact bug the monorepo's own root `CLAUDE.md`
records from when `research/` was tracked as both a plain directory and a submodule: *"every edit
had to be committed twice or the copies silently diverged."* An **empty** `research/` is likewise
refused as a corpus — that is an uninitialised submodule, and findings written into it are lost at
the next update.

## What moved in with it

**`bands.py`** — the reader for `BandRegistry.swift`, which is authored here. It lived in
`falsify/round-the-world-elf` until the split; a reader in another repo stops resolving the moment
the two are checked out separately, and the alternative (a copy) is what that module's own
docstring forbids — *"a second copy of a catalogue is a catalogue that drifts."* The origin keeps a
**re-export shim**, the same one `lightning-feed` and `elf-stations` left behind, so
`from . import bands` is unchanged and every consumer still sees ONE `Band` class.

## What deliberately did NOT move

`streams/` is gitignored and stays on the machine that recorded it — **330 MB across 1,290 chunks
as of the extraction, and the phone deletes its own copy once this server acknowledges a chunk, so
it is the only copy.** Never `rm -rf` it; point test servers at `FIELDLAB_STREAMS=$(mktemp -d)`.
The claim under test (`falsify/unexplained-local-line`), its analysis package, and
`SIGNAL-TAXONOMY.md` all stayed in the monorepo: **this repo is the instrument, not the claim.**

## What it owns, and what it does not

**It owns the DEVICE and the RECORDING.** Acquisition, the chunk format, durability, the stream
store, and a dashboard that draws what came in.

**It does not decide what a recording means.** That belongs to whichever `falsify/` entry is making
a claim about it — currently `falsify/unexplained-local-line`. `serve.py` resolves the analysis
directory (`FIELDLAB_ANALYSIS`, else the default consumer, else local) and **shells out** to its
`run.py` in its own venv; it never imports it. So this server stays stdlib, and a missing analysis
degrades to a disabled button rather than an import error.

## The consumer's own page, mounted at `/watch` (2026-08-25)

The dashboard here is **generic** — it draws what came in. A page about ONE claim is not, so a
consuming entry ships its own under `<entry>/watch/` and this server mounts it at `/watch` without
knowing anything about its content. Only `.html`/`.css`/`.js`, no traversal, no directory listing —
`CLAIM_WEB` sits inside a falsify entry that also holds analysis code and cached data.

`falsify/unexplained-local-line/watch/` is the first one: the 1.6837 Hz line, a gate that says
whether it is safe to run a manual test right now, and the three tests as a checklist.

**Two new API routes, and they arrive by deliberately different mechanisms:**

* `GET /api/watch` **shells out** to `run.py watch` in the analysis venv, behind a 4 s cache. The
  reading needs scipy and uwtl; the cache TTL is shorter than the shortest chunk setting (5 s) so a
  fresh chunk is never hidden behind a stale reading.
* `GET /api/runbook` and its two POSTs **import** `fieldlab.runbook` directly, because that module
  is **stdlib on purpose** — ticking a checkbox must not cost an interpreter start.

**The gate state stamped onto a ticked step comes from the SERVER's cached reading, never from the
browser.** A page left open since the morning would otherwise stamp a step with a gate state from
hours ago, and that stamp is the entire point of recording it.

## ⚠️ The gateway does not reload its own code

Found 2026-08-25, after two silent days. The running `gateway.py` predated both `falsify/` as a
served root and the `tools/` opt-in, so **every alias in `tailscale.json` returned 404 and the
phone's uploads were failing** while this server sat there healthy. The stale `serve.py` on 8212
was worse: started from the pre-split folder, so `STREAMS` and `WEB` pointed at a path that no
longer existed — it answered `/api/bands` and 404'd its own index.

    launchctl kickstart -k gui/$(id -u)/tech.polarize.gateway

Then check **all four aliases**, not one. `falsify/unexplained-local-line/RUN.md` has the probe.

## Why it is in `tools/` with one consumer

`falsify/PROTOCOL.md`'s **device exception**: a device is an exclusive resource — one phone, one
stream store — and two owners is a bug rather than a duplication. A coil streaming through the same
chunk format is the expected second consumer, and the format was built to take it.

## ⚠️ It is served, and that is deliberate

**`tools/` is off the gateway's URL surface by default — a privacy property, not an oversight.**
This tool opts back in with its own [`tailscale.json`](tailscale.json), because its whole job is to
*receive over the tailnet*: the iOS app posts chunks to
`https://<host>.<tailnet>.ts.net/biomimetic-radar`, a default already shipped to a phone in the
field. **Moving this folder into `tools/` broke that until the opt-in existed, and it would have
failed silently with the server looking healthy.** Every privacy guard still applies — a folder
containing `research/`, `subjects/` or `recordings/` is still refused, which is exactly why the
store is named `streams/`.

**Do not remove an alias from `tailscale.json`.** Each one is a URL some device may still hold;
removing one strands it.

## Where the raw stream lives, and why it breaks the cache rule on purpose

**`streams/` stays inside this tool, in the repo checkout.** That is a deliberate exception to the
convention `tools/dataset-fetch` sets (a shared cache at `~/.cache/…`, *never* inside a project
repo), and the exception is the operator's call, recorded 2026-08-25 with its reasoning:

> **A cache and a system of record are different things that happen to look alike.**
> `dataset-fetch` holds data that can be **re-fetched** — the API it came from still has the
> history, so losing the cache costs time and nothing else. The phone's stream can be re-fetched
> from nowhere: there is no API behind it, the phone **deletes its own copy the moment this server
> acknowledges a chunk**, and no second copy exists anywhere. It is the only extant record of a
> measurement. That belongs beside the code that reads it, not in a directory whose whole contract
> is "safe to delete".

**One store, in the tool — never one per project.** One phone, one stream. A project that wants
these samples *reads* this store (see [`INTEGRATION.md`](INTEGRATION.md)); it does not keep a copy.
Two copies of an exclusive device's record is precisely the bug the device exception exists to
prevent, and there is no reconciliation path once they diverge.

### The exit, and the number that triggers it

This is a for-now decision, not a permanent one. `dev_check.py` **fails once the store passes
`STORE_FLAG_GB`**, so the repo tells you rather than the disk doing it — a silent 20 GB checkout is
how this stops being reversible.

When it fires, the intended path is **object storage (DigitalOcean Spaces) as the system of
record**, with this folder demoted to a local cache of whatever is being worked on. That inverts
the argument above in the right way: once the raw data is durably somewhere else, this directory
*becomes* re-fetchable and the `dataset-fetch` rule applies to it normally. `FIELDLAB_STREAMS`
already exists as the override, so the local half needs no new plumbing.

## Why there is no guided session mode IN THE APP

Asked and decided 2026-08-29. A coached placement/turn/timing mode would be genuinely useful — and
it belongs on a **second device**, not on the recorder. Two measured reasons:

1. **Touching the phone moves the phone.** Advancing a step on the recording device injects exactly
   the motion the protocol exists to avoid; `BEM-0004` puts the tolerance at 0.2 arcsec.
2. **The speaker is a magnet coil.** Audio or haptic cues from the recording device write
   **740–15,600 nT** into its own magnetometer, locked to the cue schedule.

What an in-app mode would have added — a time reference for starts, stops and turns — the existing
`/watch/` runbook already provides, stamped server-side with the gate state at each tick. The
protocols live in `runbook.ACQUISITION` as data; reach them with `GET /api/runbook?which=acquisition`.

## ⚠️ Open defect — the calibrated channel is not logged

The wire format carries `mx_uT, my_uT, mz_uT, magnitude_uT` and nothing else magnetic. Recording the
**raw** `CMMagnetometerData` is the right primary choice and stays. But the **calibrated**
`CMDeviceMotion.magneticField` plus its accuracy state should be logged **beside** it as a
diagnostic — never mixed into an analysis.

**Why it matters, concretely:** the raw channel reads 560–1,184 µT because every iPhone since the 12
carries its own MagSafe magnet array. That was misread as *"a magnetic accessory is on the phone"*
for three days and across six documents. **The calibrated channel removes device hard-iron by
definition, so logging both would have shown the difference immediately.** `phyphox` lets a user
switch between them in two taps; this app offers only one.

Recommended by the received methods document (§3.1) and by
`research/projects/bioem-propagation/mechanisms/iphone-magnetometer-implementation-comparison.md`.
Needs an app build, so it waits for the next one.

## ⚠️ Never `rm -rf streams/`

It is the phone's uploaded record and **the phone deletes its own copy once the server acknowledges
a chunk** — 276 MB and 1,080 chunks with no second copy anywhere. Point test servers at a scratch
store with `FIELDLAB_STREAMS=$(mktemp -d) python3 serve.py <port>`; `dev_check.py` already does.
*This was learned the expensive way: a cleanup during development destroyed ~28 minutes of the first
real always-on recording.*

## ⚠️ Do not rename the bundle id

The Xcode target and type prefixes say `BiomimeticRadar`; the product is **FieldLab**. The bundle id
`com.biomimeticradar.app` **must not change**: the app is installed on a phone holding unsent chunks
in `Documents/FieldLab Spool`, and iOS keys a container to the bundle id, so renaming orphans that
data.

## The wire format is the seam

One self-describing raw-DEFLATE file per chunk — a JSON header line then `raw.csv`, the **same
columns as an export**, so an analysis reads a stretch of stream with the same loader it uses for a
file. The format is pinned by a **Swift-written fixture** (`analysis/fixtures/sample.chunk`) that
the Python tests decode, so the two halves cannot silently disagree.

`BiomimeticRadar/Processing/BandRegistry.swift` is the **single source of truth for the band
catalogue** — `falsify/round-the-world-elf/analysis/fieldlab/bands.py` parses it rather than keeping
a copy, and locates it by search because a hardcoded depth has broken on a folder move four times in
this repo.
