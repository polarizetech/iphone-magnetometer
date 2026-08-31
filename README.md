# FieldLab — iPhone magnetic signal test platform

FieldLab is a native SwiftUI research app for testing how far coherent processing can recover a deliberately coded magnetic signal below the instantaneous noise of an iPhone magnetometer.

**Standalone repo.** It also rides in the `audio-projects` monorepo as a submodule at
`tools/fieldlab-recorder`. It imports nothing from that monorepo; everything monorepo-side is
optional and announces itself when absent (`python3 dev_check.py` prints its skips). Findings are
written to the `research` corpus, not to this repo — see `research_path.py`.

## Run

1. Install Xcode 16 or newer and select it with `sudo xcode-select -s /Applications/Xcode.app` if needed.
2. Regenerate the project after editing `project.yml`: `xcodegen generate`.
3. Open `BiomimeticRadar.xcodeproj`, choose an iPhone signing team, and run on a physical iPhone. Core Motion acquisition is not meaningful in Simulator.
4. Grant optional location access only if GPS metadata is desired.

The app stores raw and processed data separately in its Documents directory and exposes experiment bundles through the system share sheet.

## First validation

Use **Simulator** in the app to validate the 8.3 Hz lock-in and coded matched-filter path. Then use **Experiment → Calibration wizard** for staged physical validation and randomized blinded ON/OFF trials.

This is an experimental instrument, not a biomagnetic or planetary-signal detector. Results are labelled according to preregistration, significance, replication, and null-control status.

