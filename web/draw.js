// draw.js — canvas drawing for the live page. Colours come from tools/design tokens via CSS
// custom properties, never literals here; the one exception is the spectrogram colormap, which
// is Viridis by the same convention `signal-scope` and `ecg-song` use for a power field.

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

export function tokens() {
  return {
    fg: css('--foreground'), muted: css('--muted-foreground'), faint: css('--faint-foreground'),
    border: css('--border'), accent: css('--accent'), card: css('--card'),
    measured: css('--measured'), predicted: css('--predicted'), refuted: css('--refuted'),
    exploring: css('--exploring'), spec: css('--spec'),
    mono: css('--font-mono') || 'monospace',
  };
}

function prep(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth || 600, h = canvas.clientHeight || 200;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w, h };
}

function fmtTime(epoch) {
  const d = new Date(epoch * 1000);
  return d.toLocaleTimeString([], { hour12: false });
}

/**
 * Strip chart: one or more series against wall time. `series = [{t, y, color, label}]`.
 * `gaps = [[t0,t1],…]` are drawn as hatched bands — a gap is shown, never interpolated across.
 */
export function strip(canvas, series, { gaps = [], unit = 'µT', t0, t1, title = '' } = {}) {
  const { ctx, w, h } = prep(canvas);
  const T = tokens();
  ctx.clearRect(0, 0, w, h);
  const padL = 64, padR = 12, padT = 22, padB = 22;
  const W = w - padL - padR, H = h - padT - padB;
  const all = series.filter(s => s.t.length > 1);
  if (!all.length) {
    ctx.fillStyle = T.faint; ctx.font = `12px ${T.mono}`;
    ctx.fillText('no samples in this window', padL, h / 2);
    return;
  }
  const tmin = t0 ?? Math.min(...all.map(s => s.t[0]));
  const tmax = t1 ?? Math.max(...all.map(s => s.t[s.t.length - 1]));
  let ymin = Infinity, ymax = -Infinity;
  for (const s of all) for (let i = 0; i < s.y.length; i++) {
    if (s.t[i] < tmin || s.t[i] > tmax) continue;
    if (s.y[i] < ymin) ymin = s.y[i]; if (s.y[i] > ymax) ymax = s.y[i];
  }
  if (!isFinite(ymin)) { ymin = 0; ymax = 1; }
  if (ymax - ymin < 1e-9) { ymin -= 0.5; ymax += 0.5; }
  const pad = (ymax - ymin) * 0.08; ymin -= pad; ymax += pad;
  const X = t => padL + ((t - tmin) / (tmax - tmin || 1)) * W;
  const Y = v => padT + (1 - (v - ymin) / (ymax - ymin)) * H;

  // gaps
  ctx.fillStyle = T.refuted; ctx.globalAlpha = 0.18;
  for (const [a, b] of gaps) { if (b < tmin || a > tmax) continue; ctx.fillRect(X(Math.max(a, tmin)), padT, Math.max(2, X(Math.min(b, tmax)) - X(Math.max(a, tmin))), H); }
  ctx.globalAlpha = 1;

  // axes
  ctx.strokeStyle = T.border; ctx.lineWidth = 1;
  ctx.strokeRect(padL + 0.5, padT + 0.5, W, H);
  ctx.fillStyle = T.muted; ctx.font = `11px ${T.mono}`;
  const yticks = 4;
  for (let i = 0; i <= yticks; i++) {
    const v = ymin + (i / yticks) * (ymax - ymin);
    const y = Y(v);
    ctx.fillText(v.toFixed(Math.abs(ymax - ymin) < 1 ? 3 : 2), 4, y + 4);
    ctx.beginPath(); ctx.moveTo(padL, y + 0.5); ctx.lineTo(padL + W, y + 0.5); ctx.globalAlpha = 0.4; ctx.stroke(); ctx.globalAlpha = 1;
  }
  const xticks = Math.min(6, Math.max(2, Math.floor(W / 110)));
  for (let i = 0; i <= xticks; i++) {
    const t = tmin + (i / xticks) * (tmax - tmin);
    const label = fmtTime(t);
    ctx.fillText(label, Math.min(X(t) - 22, padL + W - 60), h - 6);
  }
  ctx.fillStyle = T.faint; ctx.fillText(unit, 4, padT - 7);
  if (title) { ctx.fillStyle = T.muted; ctx.fillText(title, padL, padT - 7); }

  // series — break the line across any gap longer than 3× the median step
  for (const s of all) {
    ctx.strokeStyle = s.color; ctx.lineWidth = s.width || 1;
    ctx.beginPath();
    let pen = false;
    let step = s.t.length > 2 ? (s.t[s.t.length - 1] - s.t[0]) / (s.t.length - 1) : 1;
    for (let i = 0; i < s.t.length; i++) {
      if (s.t[i] < tmin || s.t[i] > tmax) { pen = false; continue; }
      const x = X(s.t[i]), y = Y(s.y[i]);
      if (i > 0 && s.t[i] - s.t[i - 1] > 3 * step) pen = false;
      if (!pen) { ctx.moveTo(x, y); pen = true; } else ctx.lineTo(x, y);
    }
    ctx.stroke();
  }
}

/**
 * Spectrum: log10 PSD vs frequency, with band overlays from the registry and a target marker.
 * `bands = [{id,label,lowHz,highHz,folded?}]`.
 */
export function spectrum(canvas, f, psd, { bands = [], target = null, fmax = null, floorHz = null, floorAsd = null } = {}) {
  const { ctx, w, h } = prep(canvas);
  const T = tokens();
  ctx.clearRect(0, 0, w, h);
  const padL = 64, padR = 12, padT = 18, padB = 24;
  const W = w - padL - padR, H = h - padT - padB;
  if (!f.length) { ctx.fillStyle = T.faint; ctx.font = `12px ${T.mono}`; ctx.fillText('not enough samples for a spectrum', padL, h / 2); return; }
  const FM = fmax || f[f.length - 1];
  const logp = Array.from(psd, p => Math.log10(p + 1e-30));
  let lo = Infinity, hi = -Infinity;
  for (let i = 1; i < f.length; i++) { if (f[i] > FM) break; if (logp[i] < lo) lo = logp[i]; if (logp[i] > hi) hi = logp[i]; }
  if (!isFinite(lo)) { lo = -10; hi = 0; }
  lo = Math.floor(lo) - 0.2; hi = Math.ceil(hi) + 0.2;
  const X = fr => padL + (fr / FM) * W;
  const Y = v => padT + (1 - (v - lo) / (hi - lo)) * H;

  // band overlays
  ctx.font = `10px ${T.mono}`;
  let bi = 0;
  for (const b of bands) {
    if (b.highHz < 0 || b.lowHz > FM) continue;
    const x0 = X(Math.max(0, b.lowHz)), x1 = X(Math.min(FM, b.highHz));
    ctx.fillStyle = b.folded ? T.exploring : T.predicted; ctx.globalAlpha = 0.10;
    ctx.fillRect(x0, padT, Math.max(1, x1 - x0), H);
    ctx.globalAlpha = 0.85; ctx.fillStyle = b.folded ? T.exploring : T.predicted;
    // stagger the rotated labels so adjacent bands do not print on top of each other
    ctx.save(); ctx.translate(x0 + 3, padT + 4 + (bi++ % 3) * (H / 3)); ctx.rotate(Math.PI / 2);
    ctx.fillText((b.folded ? '⤵ ' : '') + b.id, 0, 0); ctx.restore();
    ctx.globalAlpha = 1;
  }

  // axes
  ctx.strokeStyle = T.border; ctx.strokeRect(padL + 0.5, padT + 0.5, W, H);
  ctx.fillStyle = T.muted; ctx.font = `11px ${T.mono}`;
  for (let v = Math.ceil(lo); v <= Math.floor(hi); v++) {
    const y = Y(v); ctx.fillText(`1e${v}`, 8, y + 4);
    ctx.beginPath(); ctx.moveTo(padL, y + 0.5); ctx.lineTo(padL + W, y + 0.5); ctx.globalAlpha = 0.35; ctx.stroke(); ctx.globalAlpha = 1;
  }
  const ticks = Math.min(10, Math.max(2, Math.floor(W / 60)));
  for (let i = 0; i <= ticks; i++) { const fr = (i / ticks) * FM; ctx.fillText(fr.toFixed(FM > 20 ? 0 : 1), X(fr) - 8, h - 6); }
  ctx.fillStyle = T.faint; ctx.fillText('µT²/Hz', 4, padT - 5); ctx.fillText('Hz', padL + W - 16, h - 6);

  // the curve — per-pixel MAX envelope when there are more bins than pixels, so a one-bin line
  // (mains folded to 40 Hz is one bin wide at 0.024 Hz resolution) survives being drawn 1 px wide
  // instead of vanishing between two pixel columns. The numbers (floor, at-target) come from
  // the bins, never from this envelope.
  ctx.strokeStyle = T.measured; ctx.lineWidth = 1.2; ctx.beginPath();
  let pen = false;
  const binsPerPx = (f.length * FM / (f[f.length - 1] || FM)) / W;
  if (binsPerPx <= 1.5) {
    for (let i = 1; i < f.length; i++) {
      if (f[i] > FM) break;
      const x = X(f[i]), y = Y(logp[i]);
      if (!pen) { ctx.moveTo(x, y); pen = true; } else ctx.lineTo(x, y);
    }
  } else {
    let px = -1, mx = -Infinity, mn = Infinity;
    for (let i = 1; i < f.length; i++) {
      if (f[i] > FM) break;
      const p = Math.floor(X(f[i]));
      if (p !== px) {
        if (px >= 0) { if (!pen) { ctx.moveTo(px, Y(mn)); pen = true; } ctx.lineTo(px, Y(mn)); ctx.lineTo(px, Y(mx)); }
        px = p; mx = -Infinity; mn = Infinity;
      }
      if (logp[i] > mx) mx = logp[i]; if (logp[i] < mn) mn = logp[i];
    }
    if (px >= 0 && isFinite(mx)) { if (!pen) ctx.moveTo(px, Y(mn)); ctx.lineTo(px, Y(mn)); ctx.lineTo(px, Y(mx)); }
  }
  ctx.stroke();

  // target marker
  if (target != null && target <= FM) {
    ctx.strokeStyle = T.accent; ctx.setLineDash([4, 3]); ctx.beginPath();
    ctx.moveTo(X(target) + 0.5, padT); ctx.lineTo(X(target) + 0.5, padT + H); ctx.stroke(); ctx.setLineDash([]);
    ctx.fillStyle = T.accent; ctx.fillText(`target ${target} Hz`, X(target) + 4, padT + H - 4);
  }
  if (floorHz != null && floorAsd != null && isFinite(floorAsd)) {
    const v = Math.log10(floorAsd * floorAsd + 1e-30);
    ctx.strokeStyle = T.exploring; ctx.setLineDash([2, 3]); ctx.beginPath();
    ctx.moveTo(X(Math.max(0, floorHz - 2)), Y(v) + 0.5); ctx.lineTo(X(Math.min(FM, floorHz + 2)), Y(v) + 0.5); ctx.stroke(); ctx.setLineDash([]);
  }
}

// Viridis, 8 anchors, linear in between.
const VIRIDIS = [[68, 1, 84], [71, 44, 122], [59, 81, 139], [44, 113, 142], [33, 144, 141], [39, 173, 129], [92, 200, 99], [170, 220, 50], [253, 231, 37]];
export function viridis(u) {
  u = Math.min(1, Math.max(0, u)) * (VIRIDIS.length - 1);
  const i = Math.min(VIRIDIS.length - 2, Math.floor(u)), k = u - i;
  const a = VIRIDIS[i], b = VIRIDIS[i + 1];
  return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k];
}

/**
 * A rolling spectrogram: one column per chunk, newest on the right. Shares ONE dB scale across
 * every column (the `signal-scope` rule — a residual or a quiet hour on its own autoscale would
 * look like the loud one), and says the scale on the canvas.
 */
export class Spectrogram {
  constructor(canvas, { columns = 360, fmax = 50 } = {}) {
    this.canvas = canvas; this.columns = columns; this.fmax = fmax;
    this.data = []; // [{t, f, logPsd}]
    this.lo = null; this.hi = null;
  }
  push(t, f, logPsd) {
    this.data.push({ t, f: Float64Array.from(f), logPsd: Float64Array.from(logPsd) });
    while (this.data.length > this.columns) this.data.shift();
  }
  clear() { this.data = []; }
  draw({ bands = [], target = null } = {}) {
    const { ctx, w, h } = prep(this.canvas);
    const T = tokens();
    ctx.clearRect(0, 0, w, h);
    const padL = 44, padR = 60, padT = 18, padB = 22;
    const W = w - padL - padR, H = h - padT - padB;
    if (!this.data.length) { ctx.fillStyle = T.faint; ctx.font = `12px ${T.mono}`; ctx.fillText('waiting for chunks', padL, h / 2); return; }
    // shared scale from the 2nd and 98th percentiles of everything on screen
    const vals = [];
    for (const c of this.data) for (let i = 1; i < c.f.length; i++) { if (c.f[i] > this.fmax) break; vals.push(c.logPsd[i]); }
    vals.sort((a, b) => a - b);
    const lo = vals[Math.floor(vals.length * 0.02)], hi = vals[Math.floor(vals.length * 0.98)];
    this.lo = lo; this.hi = hi;
    const colW = W / this.columns;
    const img = ctx.createImageData(Math.max(1, Math.ceil(W)), Math.max(1, Math.ceil(H)));
    const px = img.data;
    const iw = img.width, ih = img.height;
    const start = this.columns - this.data.length;
    for (let ci = 0; ci < this.data.length; ci++) {
      const c = this.data[ci];
      const x0 = Math.floor((start + ci) * colW), x1 = Math.max(x0 + 1, Math.floor((start + ci + 1) * colW));
      for (let y = 0; y < ih; y++) {
        const fr = this.fmax * (1 - y / ih);
        // nearest bin
        const bin = Math.min(c.f.length - 1, Math.round(fr / (c.f[1] || 1)));
        const u = (c.logPsd[bin] - lo) / ((hi - lo) || 1);
        const [r, g, b] = viridis(u);
        for (let x = x0; x < x1 && x < iw; x++) { const o = (y * iw + x) * 4; px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = 255; }
      }
    }
    ctx.putImageData(img, padL, padT);
    // axes & bands
    ctx.strokeStyle = T.border; ctx.strokeRect(padL + 0.5, padT + 0.5, W, H);
    ctx.fillStyle = T.muted; ctx.font = `11px ${T.mono}`;
    for (let i = 0; i <= 5; i++) { const fr = (i / 5) * this.fmax; const y = padT + (1 - fr / this.fmax) * H; ctx.fillText(fr.toFixed(0), 6, y + 4); }
    ctx.fillStyle = T.faint; ctx.fillText('Hz', 6, padT - 5);
    for (const b of bands) {
      if (b.lowHz > this.fmax) continue;
      const y0 = padT + (1 - Math.min(this.fmax, b.highHz) / this.fmax) * H, y1 = padT + (1 - Math.max(0, b.lowHz) / this.fmax) * H;
      ctx.strokeStyle = b.folded ? T.exploring : T.predicted; ctx.globalAlpha = 0.7;
      ctx.beginPath(); ctx.moveTo(padL + W + 2, y0); ctx.lineTo(padL + W + 2, y1); ctx.lineWidth = 3; ctx.stroke(); ctx.lineWidth = 1;
      ctx.fillStyle = b.folded ? T.exploring : T.predicted; ctx.font = `9px ${T.mono}`;
      ctx.fillText(b.id, padL + W + 7, (y0 + y1) / 2 + 3); ctx.globalAlpha = 1;
    }
    if (target != null) {
      const y = padT + (1 - target / this.fmax) * H;
      ctx.strokeStyle = T.accent; ctx.setLineDash([3, 3]); ctx.beginPath(); ctx.moveTo(padL, y + 0.5); ctx.lineTo(padL + W, y + 0.5); ctx.stroke(); ctx.setLineDash([]);
    }
    const first = this.data[0].t, last = this.data[this.data.length - 1].t;
    ctx.fillStyle = T.muted; ctx.font = `11px ${T.mono}`;
    ctx.fillText(fmtTime(first), padL + (start * colW), h - 6);
    ctx.fillText(fmtTime(last), padL + W - 60, h - 6);
    ctx.fillStyle = T.faint;
    ctx.fillText(`one dB scale for every column · 1e${lo.toFixed(1)} … 1e${hi.toFixed(1)} µT²/Hz · ${this.data.length} chunks`, padL, padT - 5);
  }
}

/**
 * The signal's own waveform: the phase-triggered average cycle with its cycle-to-cycle spread as a
 * band, and a short unaveraged strip beside it.
 *
 * Both are drawn because either alone misleads. An average can look clean while every individual
 * cycle is a mess, so the spread band is not decoration — it is the error bar on the shape. The
 * average sharpens as the recording grows (its noise falls as the square root of the cycle count);
 * the strip does not, and is the honest reminder of what one cycle actually looks like.
 */
export function waveform(canvas, wave) {
  const { ctx, w, h } = prep(canvas);
  const T = tokens();
  ctx.clearRect(0, 0, w, h);
  if (!wave || !wave.available) {
    ctx.fillStyle = T.faint; ctx.font = `12px ${T.mono}`;
    ctx.fillText(wave?.reason || 'no waveform', 8, h / 2);
    return;
  }
  const cycle = wave.mean_cycle_nt, spread = wave.cycle_spread_nt || [];
  const padL = 52, padR = 8, padT = 16, padB = 18;
  const half = Math.floor((w - padL - padR) * 0.62);
  const W = half, H = h - padT - padB;
  let lo = Infinity, hi = -Infinity;
  for (let i = 0; i < cycle.length; i++) {
    lo = Math.min(lo, cycle[i] - (spread[i] || 0));
    hi = Math.max(hi, cycle[i] + (spread[i] || 0));
  }
  if (!isFinite(lo) || hi - lo < 1e-9) { lo = -1; hi = 1; }
  const pad = (hi - lo) * 0.08; lo -= pad; hi += pad;
  const X = i => padL + (i / (cycle.length - 1)) * W;
  const Y = v => padT + (1 - (v - lo) / (hi - lo)) * H;

  // the spread band first, so the mean sits on top of it
  ctx.fillStyle = T.measured; ctx.globalAlpha = 0.18;
  ctx.beginPath();
  for (let i = 0; i < cycle.length; i++) ctx.lineTo(X(i), Y(cycle[i] + (spread[i] || 0)));
  for (let i = cycle.length - 1; i >= 0; i--) ctx.lineTo(X(i), Y(cycle[i] - (spread[i] || 0)));
  ctx.closePath(); ctx.fill(); ctx.globalAlpha = 1;

  ctx.strokeStyle = T.border; ctx.strokeRect(padL + 0.5, padT + 0.5, W, H);
  ctx.strokeStyle = T.measured; ctx.lineWidth = 1.5; ctx.beginPath();
  for (let i = 0; i < cycle.length; i++) (i ? ctx.lineTo : ctx.moveTo).call(ctx, X(i), Y(cycle[i]));
  ctx.stroke();
  ctx.fillStyle = T.muted; ctx.font = `11px ${T.mono}`;
  ctx.fillText(hi.toFixed(1), 4, padT + 8);
  ctx.fillText(lo.toFixed(1), 4, padT + H);
  ctx.fillStyle = T.faint;
  ctx.fillText('nT', 4, padT - 4);
  ctx.fillText(`one cycle, ${wave.cycles_averaged} averaged`, padL, h - 5);

  // the unaveraged strip
  const strip = wave.strip_nt || [];
  if (strip.length > 4) {
    const sx = padL + W + 22, sw = w - sx - padR;
    let slo = Math.min(...strip), shi = Math.max(...strip);
    if (shi - slo < 1e-9) { slo -= 1; shi += 1; }
    const SX = i => sx + (i / (strip.length - 1)) * sw;
    const SY = v => padT + (1 - (v - slo) / (shi - slo)) * H;
    ctx.strokeStyle = T.border; ctx.strokeRect(sx + 0.5, padT + 0.5, sw, H);
    ctx.strokeStyle = T.predicted; ctx.lineWidth = 1; ctx.beginPath();
    for (let i = 0; i < strip.length; i++) (i ? ctx.lineTo : ctx.moveTo).call(ctx, SX(i), SY(strip[i]));
    ctx.stroke();
    ctx.fillStyle = T.faint;
    ctx.fillText(`${wave.strip_seconds}s raw, not averaged`, sx, h - 5);
  }
}
