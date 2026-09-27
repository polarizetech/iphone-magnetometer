import Foundation

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum SignalAnalysis {
    static func analyze(samples: [SensorSample], beatTimes: [Double], settings: AnalysisSettings) -> AnalysisReport? {
        guard samples.count > 20, beatTimes.count >= 4 else { return nil }
        let time = samples.map(\.monotonicTime)
        guard let firstTime = time.first, let lastTime = time.last, lastTime - firstTime > settings.preWindow + settings.postWindow + 0.1
        else { return nil }
        let dt = median(zip(time.dropFirst(), time).map(-))
        let relativeGrid = stride(from: -settings.preWindow, through: settings.postWindow + dt / 2, by: dt).map { $0 }
        let valid = beatTimes.filter { beat in
            let nearby = samples.filter { abs($0.monotonicTime - beat) <= settings.preWindow }
            guard !nearby.isEmpty else { return false }
            let accelNoise = nearby.map { abs($0.accelMagnitude - 1) }.max() ?? 0
            let gyroNoise = nearby.map(\.gyroMagnitude).max() ?? 0
            return accelNoise <= settings.accelMotionThreshold && gyroNoise <= settings.gyroMotionThreshold
        }
        let channels: [(String, (SensorSample) -> Double)] = [
            ("X", { $0.magX }), ("Y", { $0.magY }), ("Z", { $0.magZ }), ("|B|", { $0.magMagnitude }),
        ]
        var rng = SeededGenerator(state: settings.seed)
        let results = channels.compactMap { name, channel -> AxisResult? in
            // One pass over the samples per channel. The surrogate loop below extracts epochs
            // 2 x surrogateCount times, and rebuilding this array inside it froze the app on Stop.
            let values = samples.map(channel)
            let epochs = extractEpochs(times: time, values: values, beatTimes: valid, grid: relativeGrid, settings: settings)
            guard epochs.count >= 4 else { return nil }
            let mean = columnMean(epochs)
            let (low, high) = bootstrapCI(epochs: epochs, count: settings.bootstrapCount, rng: &rng)
            let responseIndices = relativeGrid.indices.filter {
                relativeGrid[$0] >= settings.responseStart && relativeGrid[$0] <= settings.responseEnd
            }
            let realRMS = rms(responseIndices.map { mean[$0] })
            var circularNullRMS: [Double] = []
            var shuffledNullRMS: [Double] = []
            let duration = (time.last ?? 0) - (time.first ?? 0)
            for _ in 0..<settings.surrogateCount {
                let shift = Double.random(
                    in: settings.postWindow..<(max(settings.postWindow + 0.01, duration - settings.preWindow)), using: &rng)
                let shifted = valid.map { (time.first ?? 0) + (($0 - (time.first ?? 0) + shift).truncatingRemainder(dividingBy: duration)) }
                let nullEpochs = extractEpochs(times: time, values: values, beatTimes: shifted, grid: relativeGrid, settings: settings)
                if !nullEpochs.isEmpty {
                    let nullMean = columnMean(nullEpochs)
                    circularNullRMS.append(rms(responseIndices.map { nullMean[$0] }))
                }
                let intervals = zip(valid.dropFirst(), valid).map(-).shuffled(using: &rng)
                var shuffled = [valid[0]]
                for interval in intervals { shuffled.append(shuffled.last! + interval) }
                let shuffledEpochs = extractEpochs(
                    times: time, values: values, beatTimes: shuffled, grid: relativeGrid, settings: settings)
                if !shuffledEpochs.isEmpty {
                    let shuffledMean = columnMean(shuffledEpochs)
                    shuffledNullRMS.append(rms(responseIndices.map { shuffledMean[$0] }))
                }
            }
            let circularP = Double(1 + circularNullRMS.filter { $0 >= realRMS }.count) / Double(circularNullRMS.count + 1)
            let shuffledP = Double(1 + shuffledNullRMS.filter { $0 >= realRMS }.count) / Double(shuffledNullRMS.count + 1)
            return AxisResult(
                id: name, axis: name, times: relativeGrid, mean: mean, lowerCI: low, upperCI: high, rms: realRMS,
                empiricalP: max(circularP, shuffledP), shuffledP: shuffledP, circularP: circularP,
                oddEvenCorrelation: splitCorrelation(epochs: epochs, selector: { $0 % 2 == 0 }),
                halfCorrelation: splitCorrelation(epochs: epochs, selector: { $0 < epochs.count / 2 }))
        }
        let heldOut = heldOutTemplateCorrelation(samples: samples, beatTimes: valid, settings: settings)
        let contaminated = valid.count < max(4, beatTimes.count / 2)
        let bestP = results.map(\.empiricalP).min() ?? 1
        let conclusion =
            contaminated
            ? "result likely contaminated by motion"
            : (bestP <= 0.0125 && heldOut > 0.2
                ? "heartbeat-correlated component detected; replication and controls required"
                : "no component detected above current noise/control threshold")
        return AnalysisReport(
            axisResults: results, validBeats: valid.count, rejectedBeats: beatTimes.count - valid.count, heldOutCorrelation: heldOut,
            motionContaminated: contaminated, conclusion: conclusion)
    }

    static func extractEpochs(
        samples: [SensorSample], beatTimes: [Double], grid: [Double], channel: (SensorSample) -> Double, settings: AnalysisSettings
    ) -> [[Double]] {
        guard samples.count > 1 else { return [] }
        return extractEpochs(
            times: samples.map(\.monotonicTime), values: samples.map(channel), beatTimes: beatTimes, grid: grid, settings: settings)
    }

    /// Baseline-corrected epochs from times and values already pulled out of the samples.
    static func extractEpochs(
        times: [Double], values: [Double], beatTimes: [Double], grid: [Double], settings: AnalysisSettings
    ) -> [[Double]] {
        guard times.count > 1, let firstTime = times.first, let lastTime = times.last,
            let gridStart = grid.first, let gridEnd = grid.last
        else { return [] }
        return beatTimes.compactMap { beat in
            guard beat + gridStart >= firstTime, beat + gridEnd <= lastTime else { return nil }
            var epoch = grid.map { interpolate(times: times, values: values, at: beat + $0) }
            let baseline = zip(grid, epoch).filter { $0.0 >= settings.baselineStart && $0.0 <= settings.baselineEnd }.map(\.1)
            guard !baseline.isEmpty else { return nil }
            let b = baseline.reduce(0, +) / Double(baseline.count)
            epoch = epoch.map { $0 - b }
            return epoch
        }
    }

    static func jittered(times: [Double], milliseconds: Double, seed: UInt64) -> [Double] {
        var rng = SeededGenerator(state: seed)
        let span = milliseconds / 1000
        return times.map { $0 + Double.random(in: -span...span, using: &rng) }
    }

    static func circularShift(times: [Double], start: Double, end: Double, offset: Double) -> [Double] {
        let duration = end - start
        return times.map {
            start + (($0 - start + offset).truncatingRemainder(dividingBy: duration) + duration).truncatingRemainder(dividingBy: duration)
        }.sorted()
    }

    static func heldOutTemplateCorrelation(samples: [SensorSample], beatTimes: [Double], settings: AnalysisSettings) -> Double {
        guard beatTimes.count >= 6 else { return 0 }
        let split = beatTimes.count / 2
        let dt = median(zip(samples.dropFirst().map(\.monotonicTime), samples.map(\.monotonicTime)).map(-))
        let grid = stride(from: -settings.preWindow, through: settings.postWindow, by: dt).map { $0 }
        let train = extractEpochs(
            samples: samples, beatTimes: Array(beatTimes[..<split]), grid: grid, channel: { $0.magX }, settings: settings)
        let test = extractEpochs(
            samples: samples, beatTimes: Array(beatTimes[split...]), grid: grid, channel: { $0.magX }, settings: settings)
        guard !train.isEmpty, !test.isEmpty else { return 0 }
        return correlation(columnMean(train), columnMean(test))
    }

    static func interpolate(times: [Double], values: [Double], at t: Double) -> Double {
        var low = 0
        var high = times.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= t { low = mid } else { high = mid }
        }
        let f = (t - times[low]) / max(times[high] - times[low], .leastNonzeroMagnitude)
        return values[low] + f * (values[high] - values[low])
    }

    static func columnMean(_ rows: [[Double]]) -> [Double] {
        guard let count = rows.first?.count else { return [] }
        return (0..<count).map { i in rows.reduce(0) { $0 + $1[i] } / Double(rows.count) }
    }

    private static func bootstrapCI(epochs: [[Double]], count: Int, rng: inout SeededGenerator) -> ([Double], [Double]) {
        guard count > 0 else {
            let mean = columnMean(epochs)
            return (mean, mean)
        }
        var means: [[Double]] = []
        for _ in 0..<count {
            means.append(columnMean((0..<epochs.count).map { _ in epochs[Int.random(in: 0..<epochs.count, using: &rng)] }))
        }
        let low = means.first!.indices.map { i in means.map { $0[i] }.sorted()[Int(Double(count - 1) * 0.025)] }
        let high = means.first!.indices.map { i in means.map { $0[i] }.sorted()[Int(Double(count - 1) * 0.975)] }
        return (low, high)
    }

    private static func splitCorrelation(epochs: [[Double]], selector: (Int) -> Bool) -> Double {
        let a = epochs.indices.filter(selector).map { epochs[$0] }
        let b = epochs.indices.filter { !selector($0) }.map { epochs[$0] }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return correlation(columnMean(a), columnMean(b))
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        let aa = a.map { $0 - ma }
        let bb = b.map { $0 - mb }
        let den = sqrt(aa.map { $0 * $0 }.reduce(0, +) * bb.map { $0 * $0 }.reduce(0, +))
        return den == 0 ? 0 : zip(aa, bb).map(*).reduce(0, +) / den
    }
    static func rms(_ values: [Double]) -> Double { sqrt(values.map { $0 * $0 }.reduce(0, +) / Double(max(values.count, 1))) }
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.isEmpty ? 0.02 : s[s.count / 2]
    }
}
