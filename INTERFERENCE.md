# INTERFERENCE.md — how this phone interferes with its own magnetometer

FieldLab reads the **raw** magnetometer (`CMMagnetometer`), not Apple's calibrated field. That is a
deliberate choice: the calibrated field applies device-dependent hard-iron corrections that would
silently subtract a faint external signal, and Apple's own guidance is that the raw stream is
"hugely influenced by magnetic fields generated on the device itself." So the phone's own fields are
**always in the raw data**. The response is not to remove them — it is to name them, so a peak can be
attributed, and to offer view-only filters the operator turns on and off.

**The rule (enforced in code):** the stored `raw.csv` is never filtered. Every filter in the web
viewer operates on a *copy* and changes only what is drawn; turning them off shows the raw data
again. A magnet that interferes with a band you care about may still carry a faint trace of that
band, so nothing is ever removed from the record — only hidden from a particular view.

The catalogue lives in `BiomimeticRadar/Processing/InterferenceRegistry.swift` (one source of truth;
`serve.py` serves it at `api/interference` and the viewer renders it). Amplitudes are
order-of-magnitude, tier **[C]** — none was measured on this specific phone. **Measuring them is
exactly what a baseline recording is for, and no clean baseline exists yet.**

## The four ways a source shows up

| Character | What it is | Filterable? |
|---|---|---|
| **hard-iron DC** | a permanent magnet fixed in the body (or an accessory) — a near-DC offset that moves only when the *phone* moves | high-pass hides the offset; the magnet's *range cost* cannot be recovered |
| **current-modulated** | current through a coil/trace switched at some rate (haptics, charging, backlight, CPU/PMIC) | a notch at its rate, when the rate is known and fixed |
| **moving actuator** | a magnet on a moving carriage (camera OIS/AF) — changes with camera activity, not a fixed rate | no frequency filter; correlate with camera use instead |
| **soft iron** | ferrous material that warps an external field's direction without adding its own | not notchable; only calibration addresses it, and we read raw on purpose |

## The sources (summary — full text in the registry)

**Accessory / external (removable — do this first):**
- **MagSafe magnet / magnetic wallet or case** — hundreds of µT, swamps the sensor. *This is what a
  real session hit: 690 µT at rest.* The DC-field preflight gate catches it. **Remove it.**
- **External magnets, mounts, cards, other devices** — variable standing field; record away from
  metal and electronics.

**Internal (cannot be removed — mitigate by not exercising them):**
- **Internal MagSafe magnet array** (MagSafe iPhones) — a fixed, shielded hard-iron offset.
- **Loudspeaker / earpiece magnets** — fixed offset; audio adds an audio-rate component. Don't play audio.
- **Taptic Engine (haptics)** — the largest controllable source, centimetres from the sensor; also
  the app's own positive-control emitter. Silence system haptics; don't touch the screen mid-run.
- **Wireless-charging coil + ferrite** — soft iron always; a strong rate source while wirelessly charging. Don't record on a wireless charger.
- **Camera OIS / autofocus** — voice-coil magnets that move with focus/stabilisation. Don't run the camera; keep the phone still.
- **CPU / PMIC current + DC-DC converters** — a variable component plus thermal drift. Let the phone reach thermal steady state; close other apps.
- **Display backlight** — brightness-dependent current. Lock brightness or run screen-off.
- **Wired charging / battery** — charge-state-dependent field. Record on battery, or log charging as a covariate.
- **NFC antenna** — idle except during Apple Pay / tag reads (13.56 MHz, aliased transient). Don't use NFC mid-run.

## The clean-baseline protocol — and what it is now MEASURED to be worth

**Updated 2026-08-26. The stakes are no longer hypothetical.** The same detector ladder, run over
two real 300 s stationary windows from this store, recovered a planted cardiac signal at:

| host | cardiac-band ASD | smallest signal recovered 95% of the time |
|---|---|---|
| a record with a **magnet on the phone** | 204.5 nT/√Hz | **498 nT** |
| a record **without** one | 15.6 nT/√Hz | **6.1 nT** |

**82× in amplitude, ~6,700× in averaging time.** ⚠️ **Corrected 2026-08-26:** this was first
attributed to a magnet accessory. There was none. The two records differ in **motion** — the noisy
one was still only **73.5%** of the time (rotation p90 **0.2048 rad/s**), the quiet one **95.3%**
(p90 **0.0022**). The number stands; the cause was misread. Putting the phone down is the whole of it, and nothing else available
to this instrument comes close — a two-phone gradiometer was measured at 1.07×. **Prep dominates
everything the software does**, which is the same conclusion `tools/eeg-bridge` reached on its rig
by a completely different route.

A baseline is what turns "no measured floor" into a number. One recording:

1. **Remove every accessory** — MagSafe wallet, case, mount. **Do NOT expect |B| to fall to
   25–75 µT, and do not treat it as a failure when it does not.** Every iPhone since the 12 carries
   its own MagSafe magnet array on the −z face: measured here at **560–1,184 µT across 15 runs and
   two handsets**, z-dominated and stable to 2 µT over ten minutes. Raw `CMMagnetometerData`
   includes device hard-iron bias by design. **`QualityGates.earthFieldLow/High` (25–75 µT) is
   therefore unpassable on this hardware and has failed 100% of recordings ever taken** — see the
   correction note below. What you are removing accessories for is the *variability* they add, not
   the offset.
2. **Phone flat and still** on a non-metal surface, away from electronics and other phones. Confirm the motion gate passes.
3. **Screen off or brightness locked, auto-brightness off, haptics off, on battery, no audio.**
4. **Emitter off.** Record **10 minutes**, not 60 s. 60 s gives a usable floor above ~10 Hz and a
   poor one below it: the cardiac/Pc1 band is exactly where drift lives, and a short record cannot
   separate a floor from a trend. The two windows in the table above were 300 s and that is the
   minimum worth taking seriously.
5. Export, and run `analysis/run.py structure` / the census over it. The result is this phone's
   **noise floor at each band**, in nT/√Hz — the denominator every future detection claim needs.

Repeat at a few orientations and locations: the floor is location-specific (external sources) and
orientation-specific (internal hard iron rotates with the phone). Keep them all — the spread *is* the
measurement of how much prep matters, the same lesson `tools/eeg-bridge` learned on its rig.

## Sources

- [Apple — Magnetic accessories may interfere with iPhone sensors](https://support.apple.com/en-in/102434)
- [Apple Developer — CMCalibratedMagneticField](https://developer.apple.com/documentation/coremotion/cmcalibratedmagneticfield) and [CMMagneticFieldCalibrationAccuracy](https://developer.apple.com/documentation/coremotion/cmmagneticfieldcalibrationaccuracy)
- [NXP AN4247 — magnetometer PCB layout / hard-iron & soft-iron](https://www.nxp.com/docs/en/application-note/AN4247.pdf)
- [Analog Devices — hard & soft iron correction](https://ez.analog.com/mems/w/documents/4493/hard-soft-iron-correction-for-magnetometer-measurements)


## ⚠️ The DC gate is measuring the wrong thing (open defect, 2026-08-26)

`QualityGates.dcFieldResult` passes only for |B| in **25–75 µT**. No iPhone reading the **raw**
magnetometer channel can satisfy that: the device's own magnet array puts the baseline at
**560–1,184 µT**, measured across 15 runs and two handsets. So the gate fails every recording, caps
every session at `exploratory`, and reports the instrument's normal condition as a fault.

**The quantity it should test is DEVIATION FROM THIS DEVICE'S OWN BASELINE**, not absolute
magnitude — a per-device offset learned once from a stationary recording, then a gate on |B|
straying from it by more than a few µT. That catches what the gate was written to catch (an actual
external magnet, a ferrous object moving nearby) and passes a healthy phone.

Until it is changed, **read a failing DC gate on this hardware as no information at all.**
