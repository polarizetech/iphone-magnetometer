import Foundation

struct SyntheticScenario: Sendable {
    var duration = 60.0
    var sampleRate = 50.0
    var carrierHz = 8.3
    var amplitudeMicrotesla = 0.025
    var noiseMicrotesla = 0.25
    var driftMicroteslaPerSecond = 0.002
    var code = [1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0]
    var chipDuration = 0.25
    var seed: UInt64 = 42
}

struct SyntheticDataSimulator: Sendable {
    func generate(_ scenario: SyntheticScenario) -> [SensorSample] {
        let count = Int(scenario.duration * scenario.sampleRate)
        var generator = SeededGenerator(seed: scenario.seed)
        let start = Date()
        return (0..<count).map { index in
            let t = Double(index) / scenario.sampleRate
            let chip = Int(t / scenario.chipDuration) % scenario.code.count
            let coded = scenario.code[chip] * scenario.amplitudeMicrotesla * sin(2 * .pi * scenario.carrierHz * t)
            let noise = gaussian(using: &generator) * scenario.noiseMicrotesla
            let drift = scenario.driftMicroteslaPerSecond * t
            return SensorSample(
                monotonicTime: t, wallTime: start.addingTimeInterval(t),
                magnetic: Vector3(
                    x: 21 + coded + noise + drift,
                    y: -4 + 0.7 * noise,
                    z: 42 + 0.35 * coded + 0.5 * noise))
        }
    }

    private func gaussian(using generator: inout SeededGenerator) -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &generator), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &generator)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
