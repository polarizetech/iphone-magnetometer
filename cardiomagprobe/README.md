# CardioMag Probe

CardioMag Probe is a native SwiftUI research app for testing whether a stock iPhone shows a reproducible **heartbeat-correlated magnetometer component** at chest-adjacent distances. It is deliberately a falsification-first instrument, not a medical device and not an automatic magnetocardiography detector.

The app records raw `CMMagnetometerData` X/Y/Z values and original monotonic timestamps alongside accelerometer, gyroscope, optional calibrated magnetic field, attitude, camera-derived PPG timing, protocol condition, distance, and placement notes. It reports achieved sampling cadence rather than assuming the requested 50 Hz rate.

## Build and install

Requirements: macOS, Xcode 15 or newer, iOS 17 or newer, and a physical iPhone with magnetometer, accelerometer, and gyroscope.

1. Open `CardioMagProbe.xcodeproj` in Xcode.
2. Select the **CardioMagProbe** target, choose your Apple development team, and change the bundle identifier if Xcode requests it.
3. Connect and trust a physical iPhone. Camera and magnetometer acquisition cannot be validated in the Simulator.
4. Select the iPhone as the run destination and press Run.
5. Grant camera access only if you want fingertip PPG. If permission is denied, use **Mark beat** or **Import times**.

The project is generated from `project.yml`. After changing that file, run `xcodegen generate`.

## Recommended first experiment

Choose **Noise floor calibration** and record the phone stationary on a non-metallic stand for at least 10 minutes. Keep people, chargers, speakers, motors, magnetic cases, watches, and moving metal away. Review achieved cadence, sample-interval stability, per-axis standard deviation, spectral density, repeated values, and inertial coupling in the Python report before attempting a chest recording.

Then record the complete sequence on the same fixture:

1. Sternum, 5 cm / 2 in
2. Sternum, 7.5 cm / 3 in
3. Sternum, 15 cm / 6 in
4. Sternum, 30 cm / 12 in
5. Empty-room/background control

Do not move the phone or perform a figure-eight during acquisition. The figure-eight compass gesture would create a large artifact by rotating the phone through Earth’s magnetic field.

## Analysis and exports

Stop runs the on-device heartbeat-triggered analysis. Export writes a lossless `samples.csv` plus `manifest.json`, including beat times and every analysis setting. On a Mac:

```bash
cd analysis
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python analyze_session.py /path/to/CardioMag-session --out report
python -m unittest test_analysis.py
```

The independent Python implementation provides motion rejection, baseline-corrected X/Y/Z/magnitude epochs, bootstrap confidence intervals, empirical surrogate tests, split reproducibility, held-out template validation, coherence helpers, timing-jitter curves, prior-information levels, stationary-noise characterization, and multi-session distance comparison.

## Interpretation limits

Commodity phone magnetometers operate far above ordinary cardiac picotesla fields. A statistical heartbeat lock could arise from chest/device motion, PPG/camera electronics, environmental magnetic changes, timing leakage, selection, or overfitting. Never report “heart magnetic field detected” from this app.

An observation is worth follow-up only if real timing beats shuffled and circular-shift timing, motion rejection passes, a frozen training template predicts untouched data, morphology/lag/polarity reproduce in another session, amplitude changes systematically with distance, and the identical empty-background analysis is absent or substantially reduced. A null result is valid.

## Repository map

- `CardioMagProbe/` — SwiftUI app, acquisition, export, and on-device analysis
- `CardioMagProbeTests/` — alignment, surrogate, jitter, and held-out tests
- `analysis/` — independent Python analysis of an exported session
- `docs/SCHEMA.md` — CSV/JSON contract
- `docs/ARTIFACT_CHECKLIST.md` — required artifact and control review

