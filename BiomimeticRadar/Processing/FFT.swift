import Foundation

/// A radix-2 FFT and the two things this app needs from it: a linear power spectrum, and an
/// analytic signal (envelope + phase) for one band.
///
/// It exists because the cross-band coupling test needs a *real* Hilbert transform. Complex
/// demodulation at a band's centre — which is what the lock-in does — is only valid for a narrow
/// band, and the bands that matter here are not narrow: Pc1 spans 0.2–5 Hz, a factor of 25. Using
/// a centre frequency for those would produce a phase estimate that means nothing, and the coupling
/// number computed from it would look exactly like a real one.
enum FFT {

    /// In-place iterative radix-2 Cooley–Tukey. `real.count` must be a power of two.
    static func transform(real: inout [Double], imaginary: inout [Double], inverse: Bool = false) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0, imaginary.count == n else { return }

        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
            var k = n >> 1
            while k <= j {
                j -= k
                k >>= 1
            }
            j += k
        }

        var length = 2
        while length <= n {
            let sign: Double = inverse ? 1 : -1
            let angle: Double = sign * 2 * Double.pi / Double(length)
            let wReal = cos(angle)
            let wImaginary = sin(angle)
            var start = 0
            while start < n {
                var currentReal = 1.0
                var currentImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let a = start + offset
                    let b = a + length / 2
                    let tReal: Double = currentReal * real[b] - currentImaginary * imaginary[b]
                    let tImaginary: Double = currentReal * imaginary[b] + currentImaginary * real[b]
                    real[b] = real[a] - tReal
                    imaginary[b] = imaginary[a] - tImaginary
                    real[a] += tReal
                    imaginary[a] += tImaginary
                    let nextReal: Double = currentReal * wReal - currentImaginary * wImaginary
                    currentImaginary = currentReal * wImaginary + currentImaginary * wReal
                    currentReal = nextReal
                }
                start += length
            }
            length <<= 1
        }

        if inverse {
            let scale = 1 / Double(n)
            for index in 0..<n {
                real[index] *= scale
                imaginary[index] *= scale
            }
        }
    }

    /// Largest power of two not exceeding `count`.
    static func usableLength(_ count: Int) -> Int {
        guard count >= 8 else { return 0 }
        var n = 1
        while n * 2 <= count { n *= 2 }
        return n
    }

    /// Hann-windowed magnitude-squared spectrum in LINEAR power, and the frequency of each bin.
    static func spectrum(_ signal: [Double], sampleRateHz rate: Double) -> (freqs: [Double], power: [Double]) {
        let n = usableLength(signal.count)
        guard n >= 8 else { return ([], []) }
        var real = [Double](repeating: 0, count: n)
        var imaginary = [Double](repeating: 0, count: n)
        for index in 0..<n {
            let taper: Double = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(n - 1))
            real[index] = signal[index] * taper
        }
        transform(real: &real, imaginary: &imaginary)
        let bins = n / 2
        var freqs = [Double](repeating: 0, count: bins)
        var power = [Double](repeating: 0, count: bins)
        let scale = 1 / Double(n * n)
        for k in 0..<bins {
            freqs[k] = Double(k) * rate / Double(n)
            power[k] = (real[k] * real[k] + imaginary[k] * imaginary[k]) * scale
        }
        return (freqs, power)
    }

    /// Envelope and instantaneous phase of one band, via a frequency-domain Hilbert transform.
    ///
    /// The band is selected by zeroing bins outside it — a brick wall, which is exact in frequency
    /// and rings in time. For the offline windows this is used on (thousands of samples, bands well
    /// inside the passband) that is the right trade; the alternative is a filter whose own phase
    /// response contaminates the phase being measured, which would be worse for exactly this job.
    static func analyticBand(
        _ signal: [Double], sampleRateHz rate: Double,
        lowHz: Double, highHz: Double
    ) -> (envelope: [Double], phase: [Double])? {
        let n = usableLength(signal.count)
        guard n >= 64, rate > 0, highHz > lowHz else { return nil }
        let mean = signal.prefix(n).reduce(0, +) / Double(n)
        var real = Array(signal.prefix(n)).map { $0 - mean }
        var imaginary = [Double](repeating: 0, count: n)
        transform(real: &real, imaginary: &imaginary)

        let resolution = rate / Double(n)
        let lowBin = max(1, Int(lowHz / resolution))
        let highBin = min(n / 2 - 1, Int(highHz / resolution + 0.5))
        guard highBin >= lowBin else { return nil }

        // Analytic signal: keep the wanted positive frequencies, double them, zero everything else.
        var filteredReal = [Double](repeating: 0, count: n)
        var filteredImaginary = [Double](repeating: 0, count: n)
        for bin in lowBin...highBin {
            filteredReal[bin] = 2 * real[bin]
            filteredImaginary[bin] = 2 * imaginary[bin]
        }
        transform(real: &filteredReal, imaginary: &filteredImaginary, inverse: true)

        var envelope = [Double](repeating: 0, count: n)
        var phase = [Double](repeating: 0, count: n)
        for index in 0..<n {
            envelope[index] = hypot(filteredReal[index], filteredImaginary[index])
            phase[index] = atan2(filteredImaginary[index], filteredReal[index])
        }
        return (envelope, phase)
    }
}
