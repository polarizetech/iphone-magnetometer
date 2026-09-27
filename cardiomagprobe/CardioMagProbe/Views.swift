import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: ExperimentViewModel
    @State private var useCamera = true
    @State private var showProtocol = false
    @State private var showImport = false
    @State private var importText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HeaderCard()
                    if !model.completedNoiseCalibration { CalibrationBanner() }
                    ConditionCard(showProtocol: $showProtocol)
                    LiveMetricsCard()
                    PPGCard(useCamera: $useCamera)
                    ControlsCard(useCamera: useCamera, showImport: $showImport)
                    if let report = model.report { ResultsCard(report: report) }
                    Text("Even a heartbeat-locked component does not by itself establish direct magnetocardiography.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }.padding()
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.075).ignoresSafeArea())
            .navigationTitle("CardioMag Probe")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showProtocol) { ProtocolView() }
            .sheet(isPresented: $showImport) {
                NavigationStack {
                    Form { TextEditor(text: $importText).frame(minHeight: 220) }
                        .navigationTitle("Import beat times")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Import") {
                                    model.importBeatTimes(text: importText)
                                    showImport = false
                                }
                            }
                        }
                }
            }
            .sheet(isPresented: $model.showShare) { if let url = model.exportedURL { ShareSheet(items: [url]) } }
        }
    }
}

struct HeaderCard: View {
    @EnvironmentObject var model: ExperimentViewModel
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.isRecording ? .red : .cyan).frame(width: 10, height: 10).shadow(
                color: model.isRecording ? .red : .cyan, radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status).font(.subheadline.weight(.semibold))
                Text(
                    model.isRecording
                        ? model.elapsed.formatted(.number.precision(.fractionLength(1))) + " s elapsed"
                        : "Falsification-first research instrument"
                ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.cardStyle()
    }
}

struct CalibrationBanner: View {
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "scope").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text("Recommended first run").font(.headline)
                Text("Record a stationary 10+ minute noise-floor calibration before attempting the chest protocol.").font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }.cardStyle(tint: .orange.opacity(0.11))
    }
}

struct ConditionCard: View {
    @EnvironmentObject var model: ExperimentViewModel
    @Binding var showProtocol: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Protocol condition", systemImage: "ruler").font(.headline)
                Spacer()
                Button("Guide") { showProtocol = true }.font(.subheadline)
            }
            Picker("Condition", selection: $model.condition) { ForEach(ProtocolCondition.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu).tint(.cyan)
            Text(model.condition.instruction).font(.caption).foregroundStyle(.secondary)
            TextField("Placement / orientation note", text: $model.placementNote).textFieldStyle(.roundedBorder)
        }.cardStyle()
    }
}

struct LiveMetricsCard: View {
    @EnvironmentObject var model: ExperimentViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live sensors", systemImage: "waveform.path.ecg").font(.headline)
                Spacer()
                Label(
                    model.motionGood ? "Stable" : "Motion",
                    systemImage: model.motionGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                ).font(.caption.weight(.bold)).foregroundStyle(model.motionGood ? .green : .orange)
            }
            HStack {
                Metric(title: "|B|", value: model.magneticMagnitude, unit: "µT")
                Metric(title: "Rate", value: model.achievedHz, unit: "Hz")
                Metric(title: "HR", value: model.heartRate ?? 0, unit: model.heartRate == nil ? "—" : "bpm")
            }
            HStack {
                AxisValue(label: "X", value: model.latestMag.0, color: .cyan)
                AxisValue(label: "Y", value: model.latestMag.1, color: .mint)
                AxisValue(label: "Z", value: model.latestMag.2, color: .purple)
            }
            HStack {
                Text("Accel deviation").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.4f g", abs(model.accelMagnitude - 1))).monospacedDigit()
                Text("Gyro").foregroundStyle(.secondary).padding(.leading)
                Text(String(format: "%.4f rad/s", model.gyroMagnitude)).monospacedDigit()
            }.font(.caption)
        }.cardStyle()
    }
}

struct PPGCard: View {
    @EnvironmentObject var model: ExperimentViewModel
    @Binding var useCamera: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Beat timing", systemImage: "camera.aperture").font(.headline)
                Spacer()
                Toggle("Camera PPG", isOn: $useCamera).labelsHidden()
            }
            WaveformView(points: model.ppgPoints).frame(height: 86)
            Text("Camera PPG supplies timing only. Lag is searched within ±500 ms; zero-lag is not assumed.").font(.caption)
                .foregroundStyle(.secondary)
        }.cardStyle()
    }
}

struct ControlsCard: View {
    @EnvironmentObject var model: ExperimentViewModel
    let useCamera: Bool
    @Binding var showImport: Bool
    var body: some View {
        VStack(spacing: 12) {
            Button {
                model.isRecording ? model.stop() : model.start(useCameraPPG: useCamera)
            } label: {
                Label(
                    model.isRecording ? "Stop recording" : "Start recording", systemImage: model.isRecording ? "stop.fill" : "record.circle"
                ).frame(maxWidth: .infinity).padding().background(model.isRecording ? Color.red : Color.cyan).foregroundStyle(.black).font(
                    .headline
                ).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            HStack {
                Button("Mark beat") { model.markBeat() }.buttonStyle(.bordered).disabled(!model.isRecording)
                Button("Import times") { showImport = true }.buttonStyle(.bordered)
                Button("Export") { model.export() }.buttonStyle(.borderedProminent).disabled(model.samples.isEmpty)
            }
        }
    }
}

struct ResultsCard: View {
    let report: AnalysisReport
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Analysis gate", systemImage: "checkmark.shield").font(.headline)
            Text(report.conclusion).font(.title3.weight(.semibold))
            HStack {
                Metric(title: "Valid", value: Double(report.validBeats), unit: "beats")
                Metric(title: "Rejected", value: Double(report.rejectedBeats), unit: "motion")
                Metric(title: "Held-out r", value: report.heldOutCorrelation, unit: "")
            }
            ForEach(report.axisResults) { r in
                VStack(spacing: 3) {
                    HStack {
                        Text(r.axis).font(.caption.bold()).frame(width: 28)
                        Text("RMS \(r.rms, specifier: "%.4g") µT")
                        Spacer()
                        Text("worst p \(r.empiricalP, specifier: "%.4f")")
                    }
                    HStack {
                        Text("shuffled \(r.shuffledP, specifier: "%.4f")")
                        Spacer()
                        Text("circular \(r.circularP, specifier: "%.4f")")
                    }.foregroundStyle(.secondary)
                }.font(.caption).monospacedDigit()
            }
            Text(
                "Multiple-axis threshold shown descriptively; replication, distance behavior, background control, and held-out performance take priority over p < 0.05."
            ).font(.caption).foregroundStyle(.secondary)
        }.cardStyle(tint: report.motionContaminated ? .orange.opacity(0.12) : .cyan.opacity(0.08))
    }
}

struct ProtocolView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Before recording") {
                    Label("Use a non-metallic stand or fixture", systemImage: "iphone.gen3")
                    Label("Mark distance, placement, and orientation", systemImage: "ruler")
                    Label("Never perform a figure-eight during acquisition", systemImage: "hand.raised.fill")
                }
                Section("Required block order") {
                    ForEach(Array(ProtocolCondition.allCases.enumerated()), id: \.element.id) { i, c in
                        VStack(alignment: .leading) {
                            Text("\(i + 1). \(c.rawValue)").font(.headline)
                            Text(c.instruction).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Interesting only if") {
                    Text(
                        "Real timing beats shuffled and circular-shift nulls; motion rejection passes; held-out morphology reproduces; another session replicates; amplitude changes with distance; background control is absent or reduced."
                    )
                }
            }.navigationTitle("Acquisition protocol").toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct WaveformView: View {
    let points: [PPGPoint]
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard points.count > 1 else { return }
                let values = points.map(\.value)
                let lo = values.min() ?? -1
                let hi = values.max() ?? 1
                var path = Path()
                for (i, p) in points.enumerated() {
                    let x = CGFloat(i) / CGFloat(points.count - 1) * size.width
                    let y = size.height - CGFloat((p.value - lo) / max(hi - lo, 0.01)) * size.height
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    if p.isBeat { context.fill(Path(ellipseIn: CGRect(x: x - 2, y: 2, width: 4, height: 4)), with: .color(.red)) }
                }
                context.stroke(path, with: .color(.pink), lineWidth: 1.5)
            }
        }.background(.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct Metric: View {
    let title: String
    let value: Double
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1)))).font(.title3.bold().monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct AxisValue: View {
    let label: String
    let value: Double
    let color: Color
    var body: some View {
        HStack {
            Text(label).foregroundStyle(color).fontWeight(.bold)
            Text(String(format: "%.3f", value)).monospacedDigit()
            Text("µT").foregroundStyle(.secondary)
        }.font(.caption).frame(maxWidth: .infinity)
    }
}

struct CardModifier: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content.padding(16).background(tint).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(
            RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }
}
extension View { func cardStyle(tint: Color = .white.opacity(0.035)) -> some View { modifier(CardModifier(tint: tint)) } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
