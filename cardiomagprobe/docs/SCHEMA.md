# Export schema 1.0.0

Each app export is one immutable session folder.

## `samples.csv`

One row per raw magnetometer update. Blank cells mean a diagnostic channel was unavailable.

| Field | Unit / meaning |
|---|---|
| `session_id` | Stable UUID |
| `monotonic_timestamp` | Core Motion seconds since boot |
| `wall_clock_iso8601` | Human-reference UTC timestamp |
| `mag_x_uT`, `mag_y_uT`, `mag_z_uT` | Raw device-frame `CMMagnetometerData` |
| `mag_magnitude_uT` | Derived magnitude; never replaces axes |
| `cal_mag_*_uT` | Optional calibrated device-motion diagnostic |
| `accel_*_g` | Acceleration in g |
| `gyro_*_rad_s` | Rotation rate |
| `attitude_*` | Optional quaternion x/y/z/w |
| `ppg` | Latest normalized red-channel trace value |
| `beat_marker` | 1 when a beat marker is attached to the sample |
| `motion_quality` | 1 when current inertial thresholds pass |
| `condition` | Protocol condition label |
| `distance_cm` | Nominal distance, blank for noise/background |
| `placement_note` | Quoted free text |

## `manifest.json`

Contains schema and session IDs, creation time, device model, condition, nominal distance, placement note, requested/achieved sample rate, row and beat counts, original monotonic beat-time array, exact analysis settings, file inventory, and interpretation warning. Never modify original markers; create a derived manifest for edits.

