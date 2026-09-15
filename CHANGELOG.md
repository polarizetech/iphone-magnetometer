# Changelog — FieldLab (biomimetic-radar)

## 2026-09-15 — the automatic alias test was wrong

The 2026-08-23 entry below says decimating the record settles the alias question. **It does not.**
Once sampled, an alias is the folded tone, so nothing done to one recording can tell it from a real
line; the test passed both. It now reports inconclusive and the question is a manual test in
`falsify/unexplained-local-line` (record at 100 Hz, then 50 Hz). The app's two rates are exactly
2:1 if the 50 Hz path decimates, which cannot move an alias of `k·rate ± f` either; a non-integer
rate option (e.g. 64 Hz) would settle it and is not offered.

## 2026-08-23 (evening) — automatic verification, morphology, and the signal register

**The tests run themselves now.** Alerts used to end with advice; advice nobody runs is not a
control. `analysis/fieldlab/autotests.py` runs every test that can be answered from the recording
alone, and the surprise is that **the alias test is one of them** — decimating the record halves the
sample rate, which moves every alias and leaves every real line alone, so one recording settles it.
Also automatic: persistence across the record, the IMU motion check, the emitter check, harmonic
structure, and a phone-state (battery/thermal) check that reports *inconclusive* when the state
never varied, because a test that could not be run must not read as one that passed.

**The manual tests are now tracked, not printed.** Four of them — walk away, rotate, power down the
suspect appliance, record elsewhere — each with what it settles, what to expect, and its possible
outcomes. They stay outstanding and prominent until a person records what happened, through
`POST /api/register/confirm`. A second run of the same test **appends**: a source that vanished on
Tuesday and not on Friday is the most interesting result available.

**`fingerprint.py` — what a signal looks like, blind.** Modality-agnostic descriptors over one
extracted component, and the discriminator that makes it worth doing is **rate stability**: a motor
holds its rate; a heart does not, and *the way* it does not is specific — respiratory sinus
arrhythmia, a modulation of the rate itself at the breathing rate. Six morphology classes are ranked
by how many of their tells matched, and a near-tie is reported as a near-tie.

**A waveform that sharpens as the recording grows.** The averaged cycle is triggered on the signal's
own phase, so its noise falls as √N while the shape stays — 257 cycles on the first real signal. It
is drawn with its cycle-to-cycle spread as a band and an unaveraged strip beside it, because an
average can look clean while every cycle is a mess.

**`register.py` — the wildlife camera.** Every signal ever found, with its first and last sighting,
its fingerprint history, its test results, the hour and weekday it appeared, the GPS, the 3-hourly
Kp, and the daily solar/cosmic-ray/lunar fields plus timestamped space-weather events read straight
off `projects/geostorm-trends`' `data/shared/space.json`. Nothing is ever deleted.

**Three bugs found and fixed, all the same failure in different clothes.** The RSA probe reported
**52× respiratory sinus arrhythmia on a rock-stable motor** (a ratio against a null with no width),
so a physical *depth* measure was added. Then the real 1.6931 Hz signal scored **"Cardiac-like,
100%"** with RSA at 0.200 Hz — and the rate's spectrum turned out to be **flat**, its top six bins
within 1.5× of each other, the "peak" only 1.1× its neighbourhood. Depth alone was not enough; a
prominence bar was added and a fixed 4.0 was *still* too low, because the max of N noise bins over
their median sits well above 1 by chance. The bar is now computed — `ln(N/α)/ln 2`, the same rule
the census uses. And the register wrote bare `NaN`, which is not valid JSON, so the browser rejected
the whole document and the register looked empty rather than broken.

**With all three fixed, the real 1.6931 Hz signal reads honestly**: *"Looks like Cardiac-like or
Rotating machinery — both fit (64% and 57%), and this reading cannot separate them."*

`analysis/dev_check.py` **131/131**, `dev_check.py` **73/73**.

## 2026-08-23 (later still) — the alert banner and the signature catalogue

- **An alert banner at the top of the web app.** "Scan for signals" runs the census and the coupling
  ladder over the current window and the banner says what in that record is **structure noise does
  not produce** — with the window it was computed over and how old it is, because a scan describes a
  window and not "now". Cached server-side at `GET /api/alerts`, pushed over SSE when a scan lands.
- **`signatures.py` — the source-class catalogue**, and its point is the **reach** column. A class
  whose plausible maximum field is below what the recording could have detected is **never offered
  as a match, however well the frequency fits**; it is listed under *ruled out* with its number
  instead. At 7.83 Hz the banner therefore says "consistent with a motor or lightning; **Schumann
  RULED OUT, max 0.001 nT**", and a 1.2 Hz line gets "**human heart RULED OUT, max 0.05 nT**".
- **`SIGNAL-TAXONOMY.md`** — the reasoning and the arithmetic behind every class: which are
  reachable, which are out of reach and by how many orders, which are structurally impossible
  (light, sound), and the three cheap tests that settle a real one.
- **Four gates on an alert**: prominence above a bar computed from the bins searched, not phone
  motion, not the phone emitting, and persistence (a component in one half only is reported as an
  **event**, not a signal).
- **Two defects found and fixed while building it.** A 5.064 Hz line "matched" a 0.300 Hz band as
  its **17th harmonic**, because the tolerance grew with the order — the search is now capped at
  order 8 with a fixed tolerance. And broadband classes (sensor noise, phone motion) were being
  offered as "consistent with" a 24 dB line, which is backwards: noise does not make lines.
- **A weakness inherited from the Swift, now fixed**: a band's prominence was measured at the band
  **centre**, so a 17 Hz tone carrying 99.5% of a record's variance inside the 12–25 Hz traction
  band scored 4.4 dB. Components now also report the strongest line inside them (`peak_hz`,
  `peak_prominence_db`) and the alert layer judges on that. The partition is unchanged.
- `analysis/dev_check.py` **106/106**, including: no biological class is ever offered at this rig's
  floor, Schumann is ruled out at 7.83 Hz, light and sound are never offered anywhere, a quiet
  record raises nothing, and the banner payload passes the vocabulary firewall.

## 2026-08-23 (later) — the census, the coupling ladder, and a real unidentified source

The four items on the "what next" list, done. The phone did not change; all of this is Mac-side.

- **The band registry is now PARSED from `BandRegistry.swift`** (`analysis/fieldlab/bands.py`), not
  copied. Stronger than a parity test — there is no second copy to drift. `serve.py` imports the
  same parser instead of its own regex.
- **The census runs offline** (`analysis/fieldlab/census.py`): every unit of AC variance partitioned,
  folded bands claiming first, a computed prominence bar, anonymous `U-nn` lines, and motion
  regressed on attitude. It can now census an hour, or the same hour on two days, which the phone
  never could.
- **Cross-band coupling with the full surrogate ladder** (`analysis/fieldlab/coupling.py`): S1
  time-shift, S2 block-wise phase-randomised, S3 shape-matched, S4 BH-FDR with the arithmetic
  unpassability check — all four imported from `tools/universal-wave-translation-layer`.
- **S3 and S4 were EXTRACTED into that tool** from `projects/elf-structure-reader`, which built
  them, on the repo's second-consumer rule. That project keeps a re-export and is unchanged:
  **109/109 there, 64/64 in the tool** after the move.
- **Two preconditions run before any surrogate.** The **F-transient** control (a band must contain
  an oscillation before its phase means anything — impulsive common drive otherwise manufactures
  coupling), and a new **mechanical common-drive** control: if the modulator is also in the IMU, the
  phone was moving and the pair is refused.
- **S1 is withheld for a periodic modulator.** Measured: a genuinely nested 1 Hz → 40 Hz signal
  scored **−1.3 null SD** under S1, because circularly shifting a periodic envelope only re-phases
  it. Every band this instrument watches is quasi-periodic, so S2 carries the gate instead.
- **The vocabulary firewall** (`analysis/fieldlab/language.py`), adopted from `elf-structure-reader`
  and extended: a report that calls structure *information*, *a message* or *intelligence* raises
  rather than printing.
- **The baseline module** (`analysis/fieldlab/baseline.py`): the noise floor per band in nT/√Hz, the
  minimum detectable field over the recorded dwell, a dwell table, and contamination checks that
  refuse to call a magnet-contaminated recording a baseline.
- New `run.py` commands `baseline`, `census`, `coupling`; all three run as jobs from the web viewer.
- `analysis/dev_check.py` **92/92**, including a three-way ground truth (nested → genuine, sawtooth →
  shape-attributable, uncoupled → nothing) and a regression on a bug this work introduced and caught:
  a near-constant IMU channel manufacturing a 4216× "mechanical" refusal, which is the same
  ratio-against-a-null-with-no-width failure the codebase already guarded elsewhere.

### The first real finding

A **1.6931 Hz magnetic line with six harmonics**, ~101.6 per minute, almost entirely on the z axis,
present in **every individual chunk** (15–32× prominence, so not an artefact of assembling them),
**117× prominent in the magnetometer and 1.1–1.5× in every IMU channel** — so it is magnetic, not
the phone moving. Its phase modulates the amplitude of the folded 60 Hz mains, and that survives the
whole ladder (S1 11.4 null SD, S2 p = 0.024, S3 p = 0.016, shape_excess 0.88). The folded mains also
carries symmetric sidebands at ±4.17 Hz. **The source is unidentified.** The mundane reading — a
mains-powered motor at ~102 rpm whose load varies once per revolution, modulating both its own field
and the local mains — fits every number, and the three cheap tests that would settle it (change the
sample rate, rotate the phone, walk 10 m) all need someone at the phone.

## FieldLab-recorder-2.0 — 2026-08-23 — the phone is a sensor; the Mac decides

**The iPhone app was cut back from six tabs to one.** It records, and it gets the samples to the
Mac. Everything that interprets — spectrum, band census, cross-band coupling, geometry, blinded
experiment decks, results and tiers — now happens in the web viewer and `analysis/`, where an idea
can be tried in seconds instead of through a device build.

- **One screen.** Live X/Y/Z/|B| and a rolling chart sit above the stream controls, so "is it
  doing something" is answered by a number that moves. Below that: the preflight gates, the stream,
  the upload state, and the phone's own condition. Settings are collapsed.
- **Deleted from the app:** Dashboard, Analyze, Signals (census), Geometry, Experiment, Results and
  Lightning views; `AppModel`, `DataRecorder`, `ExportManager`, `SpaceWeatherService`,
  `ProcessingComponents`. Recoverable at `94529ba`.
- **Excluded from the app but KEPT in the repo and the tested SwiftPM core:** `SignalProcessor`,
  `SignalCensus`, `CrossBandCoupling`, `BandRegistry`, `FFT`, `LightningCoupling`,
  `ReferenceSignals`, `SyntheticDataSimulator`, `ExperimentModels`. `swift test` still builds and
  tests all of it — it is the reference for the Python ports, and deleting worked-out, tested
  algorithms to shorten a folder listing would be the expensive kind of tidy.
- **Export merged into the stream.** There is no export screen: the spool *is* the export. It moved
  to `Documents/FieldLab Spool` with `UIFileSharingEnabled`, so unsent chunks are visible in
  Files ▸ On My iPhone ▸ FieldLab and can be copied off and posted with `analysis/post_chunks.py`.
- **More of the phone, on purpose.** A per-chunk `aux` block now carries battery level and state,
  thermal state, low-power mode, **barometric pressure and relative altitude** (a falling barometer
  is the cheapest local storm indicator this phone has), and free disk. These are covariates that
  explain how the *record* can move without the *world* moving; they are not signal sources.
- **The emitter is the one experiment control kept**, as a single picker: it is the only positive
  control this rig has, and without it nothing can show the Mac-side detector works end to end. Its
  chunk stamp is now structured (carrier, code, chip, amplitude) so the Mac can build the matched
  reference rather than assuming the defaults.

## FieldLab-MVP-1.2 — 2026-08-23 — always-on stream + first-export audit fixes

**⚠️ Sessions recorded before 1.2 are NOT comparable to sessions recorded after it.** The analysis
timebase, the analysis observable, and the tier rules all changed. Re-run the offline analysis on
an old raw.csv to compare; do not compare an old results.json to a new one.

### Always-on background streaming (new)
- The iPhone can now stream the magnetometer continuously to this Mac over the tailnet instead of
  only recording local sessions. The phone cuts the stream into chunks (5 s "live" … 5 min
  "economy"), spools each to disk, and a **background `URLSession`** carries them up — so uploads
  survive the app being suspended or killed. A coarse Core Location session keeps Core Motion
  delivering while the app is backgrounded (the blue status-bar pill is the honest cost).
- New Swift: `Processing/StreamChunk.swift`, `Services/StreamController.swift`,
  `Services/StreamUploader.swift`, `Views/StreamView.swift`, an `AppDelegate` for background events.
  `SensorManager` now supports multiple owners so a stream and an experiment can share the sensor.
- New Mac half: `serve.py` (stdlib) receives chunks, stores them decompressed as `raw.csv` (same
  columns as an export), reports missing sequence numbers, and serves a live web viewer
  (`web/`, strip + Welch spectrum + rolling spectrogram, bands parsed from `BandRegistry.swift`).
  `analysis/run.py … --stream <device> --from … --to …` reads a window of the store as one Session.
- Wire contract pinned by a Swift-written fixture (`analysis/fixtures/sample.chunk`) that the Python
  `dev_check.py` decodes — the two halves cannot silently disagree on the format.

### First-export audit (P0 correctness)
- **Timebase.** Every frequency axis, lock-in reference, and code-chip boundary is now evaluated at
  the REAL per-sample timestamps, not the requested rate. A 100 Hz request that ran at 101.42 Hz was
  slipping the 8.3 Hz reference by ~4.5 cycles over 60 s and nulling the lock-in. `codedReference`,
  `phaseTrace`, `lockInTrace` all take true times; the census and coupling use the achieved rate.
- **Averaging gain.** `coherentAveragingReport` now measures noise-only reduction (per-epoch
  deviation vs the ±average residual), drops the first epoch's filter transient, hard-caps the
  reported gain at the √N ceiling, and flags any raw excess as a diagnostic error. The old metric
  reported 30 dB against a 15 dB ceiling.
- **Observable.** The default representation is now `.vector`: each axis (x,y,z) is filtered,
  locked-in, and matched on its own, then combined coherently (vector amplitude, a χ²(6) F-test, a
  3-axis matched statistic). `|B|` is kept for display only — the norm discarded the phase/polarity
  the detector exists to use.

### Data-integrity gates (P1)
- New `Processing/QualityGates.swift`: DC-field, motion (derived from the sensor, never a user
  label), clock-consistency, sample-count, and positive-control gates. A failing gate **caps the
  tier at exploratory**. A live preflight runs in the Experiment tab so a magnet on the phone or a
  hand-held run is caught before recording.
- **Blinding leak fixed.** While blinded and below the reveal threshold, the export omits
  `randomizedTrials`, `trialIndex`, and the `emitter` block, and ships a SHA-256 **commitment** to
  the sealed assignment instead, so unblinding stays verifiable.

### Calibration (P2)
- Tesla-referenced sensitivity in every result: noise floor in nT/√Hz at the target band, and the
  minimum detectable field (nT) over the recorded dwell at a stated α.
- **External-coil emitter mode** with a field in nanotesla (from coil moment + distance, or a stated
  field). A coil run is a real calibration and is NOT emitter-capped; a phone-transducer run still
  is, and still carries the `EMITTER-ON` firewall.
- **Positive-control requirement:** an emitter-off null is only reported as meaningful once a passing
  emitter-on control exists for the same device and protocol.
- **Distance-falloff fit** (`analysis/fieldlab/calibration.py`): fit `A = A0·r^-n` across distances;
  a real magnetic source falls near r^-3, an artefact does not move with distance.

### Tests
- Swift: 69/69 (`swift test`) including `AuditFixTests` (12 acceptance tests) and
  `GoldenSessionTests` (replay of a real audited export — `BiomimeticRadarTests/golden/`).
- Python: `analysis/dev_check.py` 62/62 offline; project `dev_check.py` 51/51 (server + wire format).
