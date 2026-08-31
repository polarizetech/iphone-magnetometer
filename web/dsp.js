// dsp.js — the small amount of signal processing the live page does itself.
//
// The Mac's server is stdlib Python and deliberately does no DSP; the heavy analysis is
// `analysis/` in its own venv. What the page needs to DRAW — a detrended strip, a Welch spectrum,
// a spectrogram column — is cheap enough to do in the browser, and doing it here means the server
// never holds a second copy of the samples.
//
// Everything here is about |B| or one axis of it in MICROTESLA, at the achieved rate the server
// reports. Nothing here decides what a peak IS.

export function detrend(x) {
  // Remove mean and linear trend. A magnetometer's standing ~50 µT and its thermal wander would
  // otherwise be the whole spectrum.
  const n = x.length;
  if (n < 2) return Float64Array.from(x);
  let sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (let i = 0; i < n; i++) { sx += i; sy += x[i]; sxx += i * i; sxy += i * x[i]; }
  const den = n * sxx - sx * sx;
  const slope = den ? (n * sxy - sx * sy) / den : 0;
  const intercept = (sy - slope * sx) / n;
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) out[i] = x[i] - (intercept + slope * i);
  return out;
}

export function hann(n) {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1));
  return w;
}

/** In-place radix-2 complex FFT. `re`/`im` are Float64Array of power-of-two length. */
export function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ar = re[i + k], ai = im[i + k];
        const br = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const bi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ar + br; im[i + k] = ai + bi;
        re[i + k + len / 2] = ar - br; im[i + k + len / 2] = ai - bi;
        const ncr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
}

/**
 * Welch power spectral density, one-sided, in (units²)/Hz.
 * Returns { f, psd, segments, resolutionHz }. Detrends each segment, Hann window, 50% overlap.
 */
export function welch(x, fs, nfft = 2048) {
  const n = x.length;
  if (n < 64 || !(fs > 0)) return { f: new Float64Array(0), psd: new Float64Array(0), segments: 0, resolutionHz: NaN };
  let seg = nfft;
  while (seg > n) seg >>= 1;
  const w = hann(seg);
  let wsum = 0; for (let i = 0; i < seg; i++) wsum += w[i] * w[i];
  const half = seg / 2;
  const psd = new Float64Array(half + 1);
  const step = Math.max(1, half);
  let segments = 0;
  const re = new Float64Array(seg), im = new Float64Array(seg);
  for (let start = 0; start + seg <= n; start += step) {
    const d = detrend(x.subarray ? x.subarray(start, start + seg) : x.slice(start, start + seg));
    for (let i = 0; i < seg; i++) { re[i] = d[i] * w[i]; im[i] = 0; }
    fft(re, im);
    for (let k = 0; k <= half; k++) {
      let p = (re[k] * re[k] + im[k] * im[k]) / (fs * wsum);
      if (k > 0 && k < half) p *= 2;
      psd[k] += p;
    }
    segments++;
  }
  if (!segments) return { f: new Float64Array(0), psd: new Float64Array(0), segments: 0, resolutionHz: NaN };
  for (let k = 0; k <= half; k++) psd[k] /= segments;
  const f = new Float64Array(half + 1);
  for (let k = 0; k <= half; k++) f[k] = (k * fs) / seg;
  return { f, psd, segments, resolutionHz: fs / seg };
}

/** One spectrogram column: the log10 PSD of one window, as returned by welch with a single segment. */
export function column(x, fs, nfft = 1024) {
  const { f, psd } = welch(x, fs, nfft);
  const out = new Float64Array(psd.length);
  for (let i = 0; i < psd.length; i++) out[i] = Math.log10(psd[i] + 1e-30);
  return { f, logPsd: out };
}

/**
 * Noise floor AT a frequency, not broadband: the median PSD in ±halfWidthHz around `target`,
 * excluding ±excludeHz around it. Returns amplitude spectral density in units/√Hz, plus the PSD
 * right at the target for comparison. This is the estimator `tools/eeg-bridge` reached after
 * measuring that a broadband RMS overstates the noise at a frequency by 20–90×.
 */
export function floorAt(f, psd, target, halfWidthHz = 2, excludeHz = 0.25) {
  const ring = [];
  let at = NaN, best = Infinity;
  for (let i = 0; i < f.length; i++) {
    const d = Math.abs(f[i] - target);
    if (d < best) { best = d; at = psd[i]; }
    if (d <= halfWidthHz && d > excludeHz) ring.push(psd[i]);
  }
  if (!ring.length) return { asd: NaN, atTarget: NaN, bins: 0 };
  ring.sort((a, b) => a - b);
  const med = ring[Math.floor(ring.length / 2)];
  return { asd: Math.sqrt(med), atTarget: Math.sqrt(at), bins: ring.length };
}

/** One-pole high-pass. Returns a NEW array; the input (raw) is never mutated. */
export function highPass(x, fs, cutoffHz) {
  if (!(cutoffHz > 0) || x.length < 2) return Float64Array.from(x);
  const dt = 1 / fs, rc = 1 / (2 * Math.PI * cutoffHz), a = rc / (rc + dt);
  const out = new Float64Array(x.length);
  out[0] = 0;
  for (let i = 1; i < x.length; i++) out[i] = a * (out[i - 1] + x[i] - x[i - 1]);
  return out;
}

/** RBJ notch at f0 (a NEW array). Q sets the notch width. */
export function notch(x, fs, f0, q = 25) {
  if (!(f0 > 0) || f0 >= fs / 2 || x.length < 3) return Float64Array.from(x);
  const w0 = 2 * Math.PI * f0 / fs, alpha = Math.sin(w0) / (2 * q), a0 = 1 + alpha;
  const b0 = 1 / a0, b1 = -2 * Math.cos(w0) / a0, b2 = 1 / a0, a1 = -2 * Math.cos(w0) / a0, a2 = (1 - alpha) / a0;
  const y = new Float64Array(x.length);
  for (let n = 0; n < x.length; n++) {
    y[n] = b0 * x[n];
    if (n >= 1) y[n] += b1 * x[n - 1] - a1 * y[n - 1];
    if (n >= 2) y[n] += b2 * x[n - 2] - a2 * y[n - 2];
  }
  return y;
}

export function stats(x) {
  const n = x.length;
  if (!n) return { mean: NaN, sd: NaN, min: NaN, max: NaN };
  let s = 0, mn = Infinity, mx = -Infinity;
  for (let i = 0; i < n; i++) { s += x[i]; if (x[i] < mn) mn = x[i]; if (x[i] > mx) mx = x[i]; }
  const mean = s / n;
  let v = 0; for (let i = 0; i < n; i++) v += (x[i] - mean) ** 2;
  return { mean, sd: Math.sqrt(v / Math.max(1, n - 1)), min: mn, max: mx };
}
