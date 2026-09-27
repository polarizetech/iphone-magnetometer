// swift-format-ignore-file
// serve.py, bands.py and dev_check.py read this file with regular expressions; keep its layout.
import Foundation

/// The known ways THIS PHONE interferes with its own magnetometer.
///
/// FieldLab reads the **raw** magnetometer on purpose — Apple's calibrated field applies
/// device-dependent hard-iron corrections that would silently eat a faint external signal, and
/// Apple's own docs say the raw stream is "hugely influenced by magnetic fields generated on the
/// device itself." So the device's own fields are always in the raw data, and the honest move is
/// not to remove them but to **name** them, so a peak can be attributed rather than chased, and so
/// a filter can be offered that the operator turns on and off — never one that runs by default.
///
/// **Nothing here filters anything.** This is a catalogue. The visualiser (`web/`) reads it over
/// `api/interference` and offers each entry as a toggle that affects only what is *drawn*; the
/// stored raw CSV is never touched. The rule is the repo's rule: keep everything in the raw data,
/// filter only at the point of looking, and be able to put the filter back.
///
/// Sources for the catalogue (see `INTERFERENCE.md` for the full notes and links): Apple Support on
/// magnetic accessories interfering with iPhone sensors; NXP AN4247 and Analog Devices on hard-iron
/// (permanent magnets: speakers, vibrators) vs soft-iron vs current-sourced device fields; the
/// Core Motion raw-vs-calibrated distinction. Amplitudes are order-of-magnitude and tier **[C]** —
/// none was measured on this specific phone, and measuring them is exactly what a baseline run is for.
enum InterferenceRegistry {

    /// How a source shows up in the magnetometer — which decides how (and whether) it can be filtered.
    enum Character: String, Codable, Sendable {
        /// A permanent magnet fixed in the body. Adds a near-DC offset that moves only when the
        /// PHONE moves (hard iron). Lives at 0 Hz and in the drift band; a high-pass suppresses it.
        case hardIronDC
        /// Current through a coil or trace, modulated at some rate (haptics, charging, backlight,
        /// CPU/PMIC). Appears at whatever rate the current is switched — often above the ELF bands,
        /// often aliased. A notch at its rate suppresses it.
        case currentModulated
        /// A magnet on a moving actuator (camera OIS/AF voice-coil). Moves with focus/stabilisation,
        /// not with a fixed rate — correlated with camera activity, not with a frequency.
        case movingActuator
        /// Soft iron: ferrous material that distorts an external field's direction without adding its
        /// own. Cannot be notched — it warps, it does not emit. Only calibration addresses it, and we
        /// deliberately do not calibrate.
        case softIron
    }

    /// Where the source sits relative to the device.
    enum Origin: String, Codable, Sendable { case internalComponent, accessory, external }

    struct Source: Codable, Sendable, Identifiable {
        let id: String
        let name: String
        let origin: Origin
        let character: Character
        /// Roughly where in the body, for the operator's mental model.
        let location: String
        /// What it does to the reading.
        let effect: String
        /// How to tell it is the culprit — the cheap diagnostic.
        let tell: String
        /// What the operator can do about it (physically), separate from any viewer filter.
        let mitigation: String
        /// A suggested viewer filter, if one applies. `highPass` removes the DC/drift a hard-iron
        /// magnet sits in; `notch` removes a current source's rate; nil means no filter helps and
        /// the entry is documentation only.
        let suggestedFilter: SuggestedFilter?
        /// Order-of-magnitude expected size at the sensor, tier [C], for the mental model only.
        let orderOfMagnitude: String
    }

    struct SuggestedFilter: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case highPass, notch, none }
        let kind: Kind
        /// For `highPass`, the cutoff; for `notch`, the centre. Hz. Nil for `none`.
        let hz: Double?
        /// A notch may name several harmonics.
        let harmonics: [Double]?
    }

    /// The catalogue. Internal-then-accessory, hard-iron (the MagSafe case) first because it is the
    /// one that has already bitten a real session.
    static let sources: [Source] = [
        Source(id: "magsafe-accessory", name: "MagSafe magnet / magnetic wallet or case",
               origin: .accessory, character: .hardIronDC,
               location: "ring on the back, centred on the wireless-charging coil",
               effect: "Adds hundreds of µT of standing field — it dwarfs the Earth's ~50 µT and swamps the sensor's usable range. A real session recorded with a MagSafe wallet on read 690 µT at rest.",
               tell: "Baseline |B| far outside 25–75 µT. The DC-field preflight gate catches exactly this.",
               mitigation: "Remove it. This is the one interference source you can simply take off the phone, and the only correct move — no filter recovers range the sensor never had.",
               suggestedFilter: SuggestedFilter(kind: .highPass, hz: 0.1, harmonics: nil),
               orderOfMagnitude: "100s of µT"),
        Source(id: "magsafe-internal", name: "Internal MagSafe magnet array (MagSafe iPhones)",
               origin: .internalComponent, character: .hardIronDC,
               location: "ring around the wireless-charging coil, rear-centre",
               effect: "On MagSafe-equipped iPhones the alignment magnets are a permanent internal field. Apple shields and flux-gates them away from the sensors, but they are still a fixed hard-iron offset in the raw stream.",
               tell: "A steady offset that moves only when the phone rotates; present even with no accessory attached.",
               mitigation: "Cannot be removed. It is part of why the raw |B| rest level is not exactly the geomagnetic field. A high-pass hides the offset for viewing.",
               suggestedFilter: SuggestedFilter(kind: .highPass, hz: 0.1, harmonics: nil),
               orderOfMagnitude: "µT, shielded"),
        Source(id: "speaker-magnets", name: "Loudspeaker / earpiece magnets",
               origin: .internalComponent, character: .hardIronDC,
               location: "top earpiece and bottom speaker",
               effect: "Neodymium speaker magnets are classic hard iron — a fixed offset. When audio plays, the voice-coil current adds a small audio-rate component on top.",
               tell: "A fixed offset always; a rate that tracks whatever the phone is playing when it plays.",
               mitigation: "Do not play audio during a session. The static offset cannot be removed and is another reason rest |B| ≠ geomagnetic.",
               suggestedFilter: SuggestedFilter(kind: .highPass, hz: 0.1, harmonics: nil),
               orderOfMagnitude: "µT static"),
        Source(id: "taptic-engine", name: "Taptic Engine (haptics)",
               origin: .internalComponent, character: .currentModulated,
               location: "a mass on a coil beside a magnet, lower-centre — closest strong source to the sensor",
               effect: "The single largest CONTROLLABLE magnetic source in the device: a coil driving a mass past a magnet, centimetres from the magnetometer. Any haptic — a keyboard tick, a notification — writes a transient across the band. It is also the app's own positive-control emitter, for the same reason.",
               tell: "Bursts that line up with haptic feedback. Turn off system haptics for a session.",
               mitigation: "Silence haptics (Settings ▸ Sounds & Haptics) and avoid touching the screen during a run. This is the source most worth eliminating physically.",
               suggestedFilter: SuggestedFilter(kind: .none, hz: nil, harmonics: nil),
               orderOfMagnitude: "µT transients, near-field"),
        Source(id: "wireless-charging-coil", name: "Wireless-charging coil + ferrite",
               origin: .internalComponent, character: .softIron,
               location: "rear-centre",
               effect: "The charging coil's ferrite is soft iron — it distorts an external field's direction without adding its own. While actively charging wirelessly, the coil current is a strong rate source on top.",
               tell: "Direction distortion always; a large rate component only while on a wireless charger.",
               mitigation: "Do not record on a wireless charger. Soft-iron distortion cannot be notched — only calibration addresses it, and we deliberately read raw.",
               suggestedFilter: SuggestedFilter(kind: .none, hz: nil, harmonics: nil),
               orderOfMagnitude: "soft iron"),
        Source(id: "camera-ois", name: "Camera OIS / autofocus actuators",
               origin: .internalComponent, character: .movingActuator,
               location: "rear camera bump",
               effect: "Optical image stabilisation and closed-loop autofocus move lens elements with voice-coil motors — magnets on a moving carriage. The field near the sensor changes as the camera focuses or stabilises.",
               tell: "Steps or wander that coincide with the camera being active or the phone being moved (OIS reacts to motion).",
               mitigation: "Do not run the camera during a session; keep the phone still so OIS is not driven.",
               suggestedFilter: SuggestedFilter(kind: .none, hz: nil, harmonics: nil),
               orderOfMagnitude: "µT, activity-dependent"),
        Source(id: "pmic-cpu", name: "CPU / PMIC current draw and DC-DC converters",
               origin: .internalComponent, character: .currentModulated,
               location: "logic board",
               effect: "Processor and power-management current has a field, and switching regulators run at fixed high rates. Duty-cycled CPU load is one of the app's emitter transducers for exactly this reason; ordinary load adds a variable component and warms the sensor (thermal drift).",
               tell: "A component that tracks CPU activity, plus slow drift as the phone warms.",
               mitigation: "Close other apps; let the phone reach thermal steady state before recording. Switching-regulator rates are usually far above the ELF bands and alias.",
               suggestedFilter: SuggestedFilter(kind: .highPass, hz: 0.05, harmonics: nil),
               orderOfMagnitude: "sub-µT, plus thermal drift"),
        Source(id: "display-backlight", name: "Display backlight current",
               origin: .internalComponent, character: .currentModulated,
               location: "behind the screen",
               effect: "Backlight LED current has a field that changes with brightness; it is the app's weakest emitter transducer. Auto-brightness makes it vary on its own.",
               tell: "A component that tracks screen brightness changes.",
               mitigation: "Lock brightness (disable auto-brightness) and keep the screen state constant, or run screen-off.",
               suggestedFilter: SuggestedFilter(kind: .none, hz: nil, harmonics: nil),
               orderOfMagnitude: "sub-µT"),
        Source(id: "battery-charging", name: "Wired charging current / battery",
               origin: .internalComponent, character: .currentModulated,
               location: "battery and Lightning/USB-C port",
               effect: "Charging current through the board and battery adds a field that varies with charge state and is absent on battery power.",
               tell: "A component present only while plugged in and charging.",
               mitigation: "Record on battery, or if a long always-on run must stay charged, record the charging state as a covariate rather than trying to remove it.",
               suggestedFilter: SuggestedFilter(kind: .none, hz: nil, harmonics: nil),
               orderOfMagnitude: "sub-µT, charge-dependent"),
        Source(id: "nfc-antenna", name: "NFC antenna",
               origin: .internalComponent, character: .currentModulated,
               location: "rear",
               effect: "The NFC coil is idle most of the time but energises during Apple Pay / tag reads at 13.56 MHz — far above the sample rate, so it can only appear as an aliased transient if it fires.",
               tell: "A one-off transient at the moment of an NFC interaction.",
               mitigation: "Do not use Apple Pay / scan tags during a session.",
               suggestedFilter: SuggestedFilter(kind: .none, hz: nil, harmonics: nil),
               orderOfMagnitude: "transient only"),
        Source(id: "external-magnets", name: "External magnets, magnetic mounts, cards, other devices",
               origin: .external, character: .hardIronDC,
               location: "anything nearby",
               effect: "A magnetic car/desk mount, a laptop, speakers, a credit card's magnetic stripe, another phone — any of these adds a standing field that changes as the phone or the object moves.",
               tell: "Baseline |B| depends on where the phone is put down; it changes when nearby objects move.",
               mitigation: "Record away from metal, magnets, and electronics. This is why a baseline is location-specific.",
               suggestedFilter: SuggestedFilter(kind: .highPass, hz: 0.1, harmonics: nil),
               orderOfMagnitude: "wildly variable"),
    ]

    /// The reasons a viewer filter exists at all, in one place — rendered on the page so the toggles
    /// carry their justification.
    static let philosophy = "The raw CSV is never filtered. These toggles change only what is drawn, and any of them can be turned off to see the raw data again. A magnet that interferes with a band you care about may still carry a faint trace of that band — so nothing is removed from the record, only hidden from a particular view."
}
