# golden/ — a real audited session, kept as a regression fence

`session-a-*` is one of the first two real FieldLab exports (2026-08-23), the ones the P0/P1 audit
was written against: baseline |B| ≈ 690 µT (a magnet on the phone), the gyro peaking near 9 rad/s
while the session was labelled "stationary", an emitter-on `cpuLoad` run, and a 100 Hz request that
actually sampled at 101.42 Hz.

`GoldenSessionTests` re-runs the current analysis over `session-a-raw.csv` and asserts the audit
fixes are visible: the rate is measured (~101.4 Hz), the DC and motion gates fail, the tier is
capped at exploratory, and the averaging gain cannot exceed √N. If those numbers move, the analysis
changed — which should be a deliberate diff, not a silent one.

The raw CSV is the input; `session-a-metadata.json` is the export's own metadata for reference. It
is **not** a golden *output* file — the point is that the new analysis produces a corrected result,
so the diff against the archived `results.json` is expected and is the whole reason to keep this.
