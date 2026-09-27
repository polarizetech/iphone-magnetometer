import Charts
import SwiftUI

/// The whole app: what the sensor is reading right now, and whether it is reaching the Mac.
///
/// The live readout sits **above** the stream controls on purpose — the first question anyone has
/// standing over a running phone is "is it actually doing something", and a number that moves
/// answers it faster than any status string. Everything below it answers the second question:
/// "and is it getting to the Mac".
struct StreamView: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        StreamBody(model: model, stream: model.stream, uploader: model.stream.uploader, sensor: model.sensor)
            .navigationTitle("FieldLab")
    }
}

private struct StreamBody: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var stream: StreamController
    @ObservedObject var uploader: StreamUploader
    @ObservedObject var sensor: SensorManager
    @State private var confirmDiscard = false
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                liveField
                gates
                streamCard
                uploadCard
                phoneCard
                if showSettings { settings }
                Button(showSettings ? "Hide settings" : "Settings") { withAnimation { showSettings.toggle() } }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                footer
            }.padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { if !stream.isRunning { model.startPreview() } }
    }

    // MARK: - live

    private var header: some View {
        HStack {
            StatusPill(text: stream.state.rawValue.uppercased(), active: stream.state == .running)
            Spacer()
            Text(stream.settings.deviceName + " · " + stream.deviceID)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var liveField: some View {
        LabCard("Live magnetic field · µT") {
            let field = sensor.latestSample?.magnetic ?? .zero
            HStack {
                MetricView(label: "X", value: f(field.x), color: .red)
                MetricView(label: "Y", value: f(field.y), color: .green)
                MetricView(label: "Z", value: f(field.z), color: LabTheme.blue)
                MetricView(label: "|B|", value: f(field.magnitude), color: LabTheme.cyan)
            }
            if sensor.recentSamples.count > 2 {
                Chart(Array(sensor.recentSamples.suffix(160))) { sample in
                    LineMark(
                        x: .value("Time", sample.monotonicTime),
                        y: .value("Magnitude", sample.magnetic.magnitude)
                    )
                    .foregroundStyle(LabTheme.cyan).lineStyle(.init(lineWidth: 1))
                }
                .chartXAxis(.hidden).frame(height: 120)
            } else {
                EmptyChart(message: sensor.isRunning ? "Waiting for samples…" : "Sensor idle")
            }
            HStack {
                MetricView(label: "Magnetometer", value: String(format: "%.1f Hz", sensor.magnetometerRateHz))
                MetricView(label: "IMU / attitude", value: String(format: "%.1f Hz", sensor.motionRateHz))
            }
            if let error = sensor.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            Text(
                "Raw, unsmoothed, and unfiltered — including the Earth's ~50 µT standing field. Nothing on the phone filters anything; the Mac's viewer has the toggles."
            )
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var gates: some View {
        LabCard("Before you leave it running") {
            if model.preflight.results.isEmpty {
                Text("Checking the phone…").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.preflight.results) { g in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: g.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(g.passed ? LabTheme.cyan : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.gate.title).font(.caption.weight(.semibold))
                            Text(g.reason).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NavigationLink("What in this phone interferes with the sensor") { InterferenceView() }
                .font(.caption)
        }
    }

    // MARK: - stream

    private var streamCard: some View {
        LabCard("Always-on stream") {
            HStack {
                MetricView(label: "Stream", value: stream.streamID ?? "—", color: LabTheme.orange)
                MetricView(label: "Chunks cut", value: "\(stream.seq)")
                MetricView(label: "Samples", value: "\(stream.totalSamples)")
            }
            HStack {
                MetricView(label: "Buffered", value: "\(stream.buffered)")
                MetricView(label: "Running", value: elapsed)
                MetricView(label: "Chunk", value: String(format: "%.0f s", stream.settings.chunkSeconds))
            }
            Button {
                stream.isRunning ? model.stopStreaming() : model.startStreaming()
            } label: {
                Label(
                    stream.isRunning ? "Stop streaming" : "Start always-on stream",
                    systemImage: stream.isRunning ? "stop.fill" : "antenna.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(stream.isRunning ? .red : LabTheme.cyan)
            .foregroundStyle(.black)
            Text(stream.message).font(.footnote).foregroundStyle(.secondary)
            if let note = stream.sensorNote { Text(note).font(.footnote).foregroundStyle(.orange) }
            if stream.wasInterrupted {
                Label(
                    "The stream was running when the app last ended — iOS cannot restart a sensor from the background. Unsent chunks are uploading; press Start to resume recording.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var uploadCard: some View {
        LabCard("Reaching the Mac") {
            HStack {
                MetricView(label: "Sent", value: "\(uploader.sentChunks)", color: LabTheme.cyan)
                MetricView(label: "In flight", value: "\(uploader.inFlight.count)")
                MetricView(
                    label: "Waiting", value: "\(stream.spoolFiles)",
                    color: stream.spoolFiles > 2 ? LabTheme.orange : .primary)
            }
            HStack {
                MetricView(label: "Bytes sent", value: bytes(uploader.sentBytes))
                MetricView(label: "Spool on phone", value: bytes(stream.spoolBytes))
                MetricView(label: "Last ack", value: ago(uploader.lastAck))
            }
            if !stream.serverMissing.isEmpty {
                Label(
                    "Server reports \(stream.serverMissing.count) missing chunk(s): \(stream.serverMissing.prefix(8).map(String.init).joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle"
                ).font(.footnote).foregroundStyle(.orange)
            }
            if let error = uploader.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Button("Retry uploads now") { stream.sweep() }.buttonStyle(.bordered)
                Spacer()
                Button("Discard spool…", role: .destructive) { confirmDiscard = true }
                    .buttonStyle(.bordered).disabled(stream.spoolFiles == 0)
            }
            .confirmationDialog(
                "Discard \(stream.spoolFiles) unsent chunk(s)? They have NOT reached the Mac.",
                isPresented: $confirmDiscard, titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { _ = stream.discardSpool() }
            }
            Text(
                "Unsent chunks live in Files ▸ On My iPhone ▸ FieldLab ▸ FieldLab Spool. They are the export: copy them off and post them with analysis/post_chunks.py if the Mac is unreachable."
            )
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var phoneCard: some View {
        LabCard("Phone state") {
            Text(stream.keepAliveStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                MetricView(label: "Battery", value: stream.batteryLevel < 0 ? "—" : String(format: "%.0f%%", stream.batteryLevel * 100))
                MetricView(label: "Thermal", value: thermal(stream.thermalState))
                MetricView(label: "Attitude", value: stream.settings.attitude ? "gyro on" : "mag only")
            }
            Text(
                "Core Motion stops delivering to a backgrounded app within seconds unless a location session is running. That session is the blue pill in the status bar — the honest cost of an always-on sensor."
            )
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - settings

    private var settings: some View {
        LabCard("Settings") {
            Group {
                LabeledContent("Server") {
                    TextField("https://host/biomimetic-radar", text: $stream.settings.serverURL)
                        .multilineTextAlignment(.trailing).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.caption.monospaced())
                }
                LabeledContent("Device name") {
                    TextField("name", text: $stream.settings.deviceName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Picker("Chunk length", selection: $stream.settings.chunkSeconds) {
                    Text("5 s · live").tag(5.0)
                    Text("10 s · live").tag(10.0)
                    Text("30 s").tag(30.0)
                    Text("60 s").tag(60.0)
                    Text("5 min · economy").tag(300.0)
                }
                // 64 Hz exists for the alias test only: 101.4 Hz and 50 Hz may be an exact 2:1 pair,
                // which lands an alias of k*rate +/- f on the same frequency at both. 64 is not a
                // whole-number ratio of 101.4, so a genuine alias moves. Mains folds to 4 Hz here.
                Picker("Sample rate", selection: $stream.settings.sampleRateHz) {
                    Text("50 Hz").tag(50.0)
                    Text("64 Hz · alias test").tag(64.0)
                    Text("100 Hz").tag(100.0)
                }
                Toggle("Attitude (gyro — the power cost)", isOn: $stream.settings.attitude)
                Toggle("Record GPS in samples", isOn: $stream.settings.includeLocation)
                Toggle("Wi-Fi only uploads", isOn: $stream.settings.wifiOnly)
                    .onChange(of: stream.settings.wifiOnly) { _, _ in stream.applyNetworkPolicy() }
            }.disabled(stream.isRunning)

            Divider().padding(.vertical, 4)

            // The one experiment control kept on the phone: without a positive control, nothing can
            // ever show that the Mac-side detector works end to end.
            Picker("Positive control", selection: $model.emitter.transducer) {
                ForEach(EmitterSchedule.Transducer.allCases) { Text($0.label).tag($0) }
            }.disabled(stream.isRunning)
            if model.emitter.isPhoneEmitting {
                Label(EmitterSchedule.firewall, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption).foregroundStyle(.orange)
                Text(
                    String(
                        format:
                            "Emitting %.2f Hz, code %@, %.0f%% drive. Every chunk is stamped %@ with the carrier and code, so the Mac can matched-filter it and will refuse to read it as anything external.",
                        model.emitter.carrierHz,
                        model.emitter.code.map { $0 > 0 ? "1" : "0" }.joined(),
                        model.emitter.amplitude * 100, EmitterSchedule.stamp)
                )
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Off. The phone emits nothing and any signal in the record came from outside it.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Text(
                stream.isRunning
                    ? "Stop the stream to change settings."
                    : "Chunk length is the Mac viewer's latency: it sees a chunk when the chunk closes. Longer chunks cost nothing in data volume and save radio wake-ups."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Text(
            "The phone records; the Mac decides. Nothing here analyses, filters, or interprets — every number that means something is computed on the other end, from the same raw samples this app sends."
        )
        .font(.caption).foregroundStyle(.tertiary)
        .multilineTextAlignment(.center).padding(.horizontal)
    }

    // MARK: - formatting

    private func f(_ value: Double) -> String { String(format: "%+.3f", value) }
    private var elapsed: String {
        guard let start = stream.startedAt, stream.isRunning else { return "—" }
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    private func bytes(_ n: Int) -> String {
        n < 1024
            ? "\(n) B"
            : n < 1_048_576
                ? String(format: "%.1f KB", Double(n) / 1024)
                : String(format: "%.1f MB", Double(n) / 1_048_576)
    }
    private func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(Date().timeIntervalSince(date))
        return s < 60 ? "\(s)s ago" : s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago"
    }
    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "?"
        }
    }
}
