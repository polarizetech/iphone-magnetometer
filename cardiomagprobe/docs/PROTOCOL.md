# Preregistered protocol

## Primary question and statistic

Can a stationary stock iPhone at 5–8 cm from the sternum show a reproducible heartbeat-correlated magnetometer component? For each raw axis and magnitude, the primary statistic is RMS of the baseline-corrected heartbeat-triggered average from −100 to +350 ms relative to the PPG pulse marker. Compare it with at least 1,000 timing surrogates. Correct the four-channel decision threshold to 0.0125; searched lag values must also be included in the family of tests.

PPG is mechanically and physiologically delayed from cardiac electrical activation. The preregistered epoch is −500 to +500 ms and zero lag is not assumed. Preserve original PPG markers; revised markers belong in derived output.

## Acquisition

- Use the same iPhone, room, non-metallic fixture, orientation, and anatomical mark across conditions.
- Remove magnetic cases and nearby watches. Disconnect charging cables.
- Record a 10+ minute stationary noise block first.
- Record 5, 7.5, 15, and 30 cm blocks plus an empty-room block.
- Do not touch, rotate, or figure-eight the phone while recording.
- Record deviations in the placement note. Do not retrospectively omit blocks.

## Required gates

1. Reject/flag beat windows crossing preregistered accelerometer or gyroscope thresholds.
2. Real timing must exceed both shuffled-interbeat and circular-shift nulls.
3. Accelerometer/gyro triggered averages must not explain the magnetic morphology.
4. Odd/even and first/second-half morphology, lag, and polarity must agree.
5. Learn morphology and preferred projection on the training half only; freeze them before scoring the held-out half.
6. Time-reversed, different-distance, and shuffled-timing templates must not perform similarly.
7. Results must replicate in a separate session/day.
8. Amplitude must change systematically/localize with distance.
9. The same result must be absent or substantially reduced in the empty-room condition.

Failure of any gate is displayed as a failure, not hidden behind a nominal p-value. No single threshold establishes magnetocardiography.

## Timing knowledge experiment

Evaluate held-out performance with 0, 5, 10, 25, 50, 100, 250, and 500 ms synthetic jitter. Compare prior levels: no prior; approximate rate band; exact beat times; times plus frozen morphology; times plus frozen morphology and XYZ projection; then spatial behavior across distances. Report surrogate false-positive rate at every level.

