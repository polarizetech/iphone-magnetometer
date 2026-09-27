
// ---------------------------------------------------------------- what the CONSUMING project adds
// This viewer is the TOOL's: it draws what the phone recorded. Four panels here are not about the
// phone at all -- they are one falsification entry's questions (an ELF observatory to compare
// against, that entry's signal register, its findings, its band-catalogue alerts). A second
// consumer of this tool asking a different question wants none of them, and would have inherited
// a dashboard talking about Schumann modes.
//
// So the consuming project DECLARES what it adds, in `<entry>/watch/claim.json`, and anything it
// does not declare is hidden. No consumer at all -> a clean device viewer.
const CLAIM_PANELS = { alerts: 'alertBanner', station: 'stationCard',
                       findings: 'findingsCard', register: 'registerCard' };

async function applyClaim() {
  let claim = { declared: false };
  try { claim = await api('api/claim'); } catch { /* older server, or none: hide them all */ }
  const on = new Set(claim.declared ? (claim.panels || []) : []);
  for (const [name, id] of Object.entries(CLAIM_PANELS)) {
    const el = $(id);
    if (!el) continue;
    if (on.has(name)) { el.dataset.claimPanel = name; }
    else { el.hidden = true; el.dataset.hiddenByClaim = 'true'; }
  }
  const banner = $('claimBanner');
  if (banner) {
    if (claim.declared) {
      banner.hidden = false;
      banner.innerHTML = `<strong>${escapeHtml(claim.name)}</strong>
        <span class="pill">${escapeHtml(claim.kind || 'project')}</span>
        <span class="pill">${escapeHtml(claim.status || '')}</span>
        <p class="hint" style="margin:.4rem 0 0">${escapeHtml(claim.claim || '')}</p>
        <p class="hint" style="margin:.4rem 0 0">The panels below marked with this project's name
          are <strong>its</strong> readings of this recording, not the recorder's.
          ${claim.url ? `<a href="${escapeHtml(claim.url)}">Open its own page \u2192</a>` : ''}</p>`;
    } else {
      banner.hidden = false;
      banner.innerHTML = `<p class="hint" style="margin:0">No project is interpreting this
        recording. This is the device viewer: what the phone recorded, and nothing about what it
        means. A project adds its own readings by shipping <code>watch/claim.json</code> \u2014 see
        <code>INTEGRATION.md</code>.</p>`;
    }
  }
  return claim;
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

// app.js — the live page. Fetches by RELATIVE path so it works on localhost and behind the
// gateway's /biomimetic-radar/ prefix alike.
import { welch, column, floorAt, stats, highPass, notch, detrend } from './dsp.js';
import { strip, spectrum, Spectrogram, tokens, waveform } from './draw.js';

const $ = (id) => document.getElementById(id);
const api = (path) => fetch(path, { cache: 'no-store' }).then(r => { if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`); return r.json(); });
const post = (path, body) => fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(r => r.json());

const S = {
  status: null, bands: [], device: null, stream: null,
  ring: { t: [], mx: [], my: [], mz: [], mag: [] }, gaps: [], rateHz: null, emitter: false,
  lastChunkEpoch: null, chunkSeconds: 10, lastEvent: null, missing: [],
  maxKeepSeconds: 3600,
  interference: [], notches: new Map(),   // id -> {hz|harmonics} enabled by the operator
};
const spectro = new Spectrogram($('spectrogram'), { columns: 360, fmax: 50 });

// ----------------------------------------------------------------------------- helpers
function fmt(v, d = 2) { return (v == null || !isFinite(v)) ? '—' : Number(v).toFixed(d); }
function ago(epoch) { if (!epoch) return '—'; const s = Date.now() / 1000 - epoch; return s < 90 ? `${s.toFixed(0)} s` : s < 5400 ? `${(s / 60).toFixed(0)} min` : `${(s / 3600).toFixed(1)} h`; }
// Labels and values are text, never markup: several values (device name, model, thermal and battery
// state) arrive unauthenticated from the phone's hello and chunk headers.
function kpi(label, value, cls = '') { return `<div class="kpi"><p class="ui-label">${escapeHtml(label)}</p><div class="val ${cls}">${escapeHtml(value)}</div></div>`; }

/** The phone's per-chunk covariates. Each one explains a way the RECORD can move without the world
 *  moving — a warm phone drifts, a charging phone has current, a falling barometer means weather.
 *  Absent on chunks from before the aux block existed, which is shown as "—", never as zero. */
function auxKpis(aux) {
  if (!aux) return '';
  const warmish = ['serious', 'critical'].includes(aux.thermalState);
  const gb = aux.freeDiskBytes != null ? (aux.freeDiskBytes / 1e9).toFixed(1) + ' GB' : '—';
  return kpi('phone thermal', aux.thermalState || '—', warmish ? 'is-warn' : '')
    + kpi('battery', (aux.batteryLevel != null ? (aux.batteryLevel * 100).toFixed(0) + '%' : '—')
        + (aux.batteryState && aux.batteryState !== 'unknown' ? ' · ' + aux.batteryState : ''),
        aux.batteryState === 'charging' ? 'is-warn' : '')
    + kpi('pressure', aux.pressureKPa != null ? aux.pressureKPa.toFixed(2) + ' kPa' : '— no barometer')
    + kpi('free disk', gb, (aux.freeDiskBytes != null && aux.freeDiskBytes < 2e9) ? 'is-bad' : '')
    + (aux.lowPowerMode ? kpi('low power mode', 'ON — iOS throttles the sensor', 'is-bad') : '');
}

/** Where a registry band shows up at THIS sample rate. Mirrors `BandRegistry.Placement` in spirit:
 *  direct, folded (one alias), or unlocatable (wider than the sampled spectrum — refused a place). */
function placeBands(bands, fs) {
  if (!fs) return bands.map(b => ({ ...b, folded: false }));
  const ny = fs / 2;
  const alias = f => { const m = f % fs; return m > ny ? fs - m : m; };
  const out = [];
  for (const b of bands) {
    if (b.highHz <= ny) { out.push({ ...b, folded: false }); continue; }
    if (b.highHz - b.lowHz >= ny) { out.push({ ...b, unlocatable: true }); continue; }
    const lo = Math.max(b.lowHz, 0), hi = b.highHz;
    if (lo < ny) { out.push({ ...b, highHz: ny, folded: false }); }
    const a = alias(Math.max(lo, ny)), c = alias(hi);
    const zoneA = Math.floor(Math.max(lo, ny) / ny), zoneC = Math.floor(hi / ny);
    if (zoneA === zoneC) out.push({ ...b, lowHz: Math.min(a, c), highHz: Math.max(a, c), folded: true });
    else out.push({ ...b, lowHz: Math.min(a, c), highHz: ny, folded: true });
  }
  return out;
}

// ----------------------------------------------------------------------------- data
async function loadStatus() {
  S.status = await api('api/status');
  const sel = $('device');
  const current = sel.value;
  sel.innerHTML = '';
  if (!S.status.devices.length) {
    sel.innerHTML = '<option value="">— no device has streamed yet —</option>';
    $('streamNote').textContent = 'Start the always-on stream on the phone (Stream tab) with this server\'s URL. The first chunk creates the device here.';
    return;
  }
  for (const d of S.status.devices) {
    const o = document.createElement('option');
    o.value = d.device;
    const l = d.latest;
    o.textContent = `${d.name || d.device} · ${d.device}` + (l ? ` · last chunk ${ago(l.toEpoch)} ago` : '');
    sel.appendChild(o);
  }
  const pick = current && S.status.devices.some(d => d.device === current) ? current
    : S.status.devices.slice().sort((a, b) => (b.latest?.toEpoch || 0) - (a.latest?.toEpoch || 0))[0].device;
  sel.value = pick;
  if (pick !== S.device) { await selectDevice(pick); await loadAlerts(); await loadRegister(); }
  loadFindings();   // static, device-independent — the measured record, not the live stream
  $('venvPill').textContent = `analysis venv: ${S.status.analysisVenv ? 'present' : 'MISSING — see analysis/README.md'}`;
  $('venvPill').className = 'pill ' + (S.status.analysisVenv ? 'is-on' : 'is-bad');
}

async function selectDevice(device) {
  S.device = device;
  S.ring = { t: [], mx: [], my: [], mz: [], mag: [] };
  spectro.clear();
  const d = S.status.devices.find(x => x.device === device);
  S.stream = d?.latest?.stream || null;
  S.lastChunkEpoch = d?.latest?.toEpoch || null;
  S.missing = d?.latest?.missing || [];
  // chunk length from the latest stream's manifest, else 10 s
  if (d?.latest?.info?.settings?.chunkSeconds) S.chunkSeconds = d.latest.info.settings.chunkSeconds;
  const windowS = Number($('window').value);
  const now = Date.now() / 1000;
  const from = Math.max(now - S.maxKeepSeconds, (S.lastChunkEpoch || now) - S.maxKeepSeconds);
  const to = Math.max(now, (S.lastChunkEpoch || now) + 1);
  await fetchInto(from, to, true);
  // spectrogram back-fill from what we hold, in chunk-length slices
  backfillSpectrogram();
  redraw();
  await loadChunks();
}

async function fetchInto(from, to, replace = false) {
  if (!S.device) return;
  const span = to - from;
  const step = span > 2 * 3600 ? 10 : 1;   // the server refuses >6 h without bins; we stay under that
  const res = await api(`api/samples?device=${encodeURIComponent(S.device)}&from=${from}&to=${to}&step=${step}`);
  if (replace) S.ring = { t: [], mx: [], my: [], mz: [], mag: [] };
  // append, dropping anything at or before our last t (a re-fetch overlap)
  const lastT = S.ring.t.length ? S.ring.t[S.ring.t.length - 1] : -Infinity;
  let start = 0;
  while (start < res.t.length && res.t[start] <= lastT) start++;
  for (const k of ['t', 'mx', 'my', 'mz', 'mag']) for (let i = start; i < res.t.length; i++) S.ring[k].push(res[k][i]);
  // trim
  const cutoff = (S.ring.t[S.ring.t.length - 1] || 0) - S.maxKeepSeconds;
  let drop = 0; while (drop < S.ring.t.length && S.ring.t[drop] < cutoff) drop++;
  if (drop) for (const k of Object.keys(S.ring)) S.ring[k].splice(0, drop);
  S.rateHz = res.rateHz || S.rateHz;
  S.emitter = S.emitter || res.emitter;
  S.gaps = res.gaps || [];
  return res;
}

function backfillSpectrogram() {
  const t = S.ring.t; if (t.length < 64 || !S.rateHz) return;
  const ch = channelSeries('mag');
  const n = Math.max(1, Math.round(S.chunkSeconds * S.rateHz));
  const cols = [];
  for (let i = 0; i + n <= ch.y.length; i += n) cols.push([ch.t[i], ch.y.slice(i, i + n)]);
  for (const [tt, y] of cols.slice(-spectro.columns)) { const c = column(Float64Array.from(y), S.rateHz, 1024); spectro.push(tt, c.f, c.logPsd); }
}

function channelSeries(ch) { return { t: S.ring.t, y: S.ring[ch] }; }

/** Apply the active VIEW filters to a copy of a raw channel. Order: detrend → high-pass → notches.
 *  Never mutates S.ring — the raw data stays raw, this is only what gets drawn. */
function filtered(y) {
  const fs = S.rateHz || 100;
  let out = Float64Array.from(y);
  if (document.getElementById('fRaw').checked) return out;   // raw wins outright
  if (document.getElementById('fDetrend').checked) out = detrend(out);
  if (document.getElementById('fHighpass').checked) {
    const hz = parseFloat(document.getElementById('fHpHz').value) || 0.1;
    out = highPass(out, fs, hz);
  }
  for (const spec of S.notches.values()) {
    if (spec.harmonics) for (const h of spec.harmonics) { if (h < fs / 2) out = notch(out, fs, h); }
    else if (spec.hz && spec.hz < fs / 2) out = notch(out, fs, spec.hz);
  }
  return out;
}
function anyFilterActive() {
  return !document.getElementById('fRaw').checked &&
    (document.getElementById('fHighpass').checked || document.getElementById('fDetrend').checked || S.notches.size > 0);
}

// ----------------------------------------------------------------------------- drawing
function redraw() {
  const T = tokens();
  const windowS = Number($('window').value);
  const tEnd = S.ring.t.length ? S.ring.t[S.ring.t.length - 1] : Date.now() / 1000;
  const t0 = tEnd - windowS, t1 = tEnd;
  const ch = $('channel').value;
  const active = anyFilterActive();
  let series;
  if (ch === 'xyz') {
    series = [{ t: S.ring.t, y: filtered(S.ring.mx), color: T.refuted, label: 'X' }, { t: S.ring.t, y: filtered(S.ring.my), color: T.measured, label: 'Y' }, { t: S.ring.t, y: filtered(S.ring.mz), color: T.predicted, label: 'Z' }];
  } else {
    series = [{ t: S.ring.t, y: filtered(S.ring[ch]), color: T.measured }];
  }
  const stripTitle = ch === 'mag'
    ? (active ? '|B| — VIEW FILTER ON (raw is unchanged on disk)' : '|B| raw, including the Earth\'s standing field')
    : ch + (active ? ' — filtered view' : '');
  strip($('strip'), series, { gaps: S.gaps, t0, t1, unit: active ? 'µT (filtered view)' : 'µT', title: stripTitle });

  // spectrum
  const specS = Number($('specSeconds').value);
  $('specSecondsLabel').textContent = `${specS} s`;
  const chS = ch === 'xyz' ? 'mag' : ch;
  const yFull = filtered(S.ring[chS]), t = S.ring.t;
  let i0 = t.length; while (i0 > 0 && t[i0 - 1] >= tEnd - specS) i0--;
  const seg = Float64Array.from(yFull.slice(i0));
  const target = Number($('target').value) || 8.3;
  const fs = S.rateHz || 0;
  const placed = placeBands(S.bands, fs);
  const w = welch(seg, fs, seg.length >= 4096 ? 4096 : 2048);
  const fl = floorAt(w.f, w.psd, target);
  spectrum($('spectrum'), w.f, w.psd, { bands: placed.filter(b => !b.unlocatable), target, fmax: fs ? fs / 2 : 50, floorHz: target, floorAsd: fl.asd });
  const unloc = placed.filter(b => b.unlocatable).map(b => b.id);
  $('specKpis').innerHTML =
    kpi('achieved rate', `${fmt(fs, 1)} Hz`) +
    kpi('resolution', `${fmt(w.resolutionHz, 3)} Hz`) +
    kpi('segments', `${w.segments}`) +
    kpi(`floor at ${target} Hz`, isFinite(fl.asd) ? `${fmt(fl.asd * 1000, 2)} nT/√Hz` : '—', 'is-warn') +
    kpi('at target', isFinite(fl.atTarget) ? `${fmt(fl.atTarget * 1000, 2)} nT/√Hz` : '—') +
    (unloc.length ? kpi('unlocatable bands', unloc.join(', '), 'is-warn') : '');
  spectro.fmax = fs ? fs / 2 : 50;
  spectro.draw({ bands: placed.filter(b => !b.unlocatable), target });

  // status kpis
  // The |B| statistics are of the RAW channel, always — a filtered mean is a statement about
  // the filter, and this readout is how the operator sanity-checks the actual field level.
  const st = stats(S.ring[chS].slice(i0));
  const age = S.lastChunkEpoch ? Date.now() / 1000 - S.lastChunkEpoch : null;
  const live = age != null && age < 3 * S.chunkSeconds + 5;
  $('liveBadge').textContent = live ? 'MEASURED · live' : (age == null ? 'MEASURED · waiting' : `MEASURED · stale ${ago(S.lastChunkEpoch)}`);
  $('liveBadge').setAttribute('tier', live ? 'measured' : 'exploratory');
  const d = S.status?.devices.find(x => x.device === S.device);
  $('kpis').innerHTML =
    kpi('device', d ? `${d.name || '—'} · ${d.latest?.info?.deviceModel || ''}` : '—') +
    kpi('stream', S.stream || '—') +
    kpi('last chunk', age == null ? '—' : `${ago(S.lastChunkEpoch)} ago`, live ? 'is-good' : 'is-warn') +
    kpi('samples held', `${S.ring.t.length}`) +
    kpi(`|B| mean · sd (${specS} s)`, `${fmt(st.mean, 3)} · ${fmt(st.sd, 4)} µT`) +
    kpi('missing chunks', `${S.missing.length}`, S.missing.length ? 'is-bad' : 'is-good') +
    (S.emitter ? kpi('EMITTER-ON', 'measures this phone, not the world', 'is-bad') : '') +
    auxKpis(d?.latest?.aux);
  $('streamNote').textContent = d?.latest?.info?.settings
    ? `phone settings: ${d.latest.info.settings.chunkSeconds}s chunks · ${d.latest.info.settings.sampleRateHz} Hz requested · attitude ${d.latest.info.settings.attitude ? 'on' : 'off'} · ${d.latest.info.settings.wifiOnly ? 'Wi-Fi only' : 'cellular allowed'} · app ${d.latest.info.appVersion || '?'} · iOS ${d.latest.info.systemVersion || '?'}`
    : (d ? `no hello from the phone for this stream — headers only` : '');
}

async function loadChunks() {
  if (!S.device) return;
  const res = await api(`api/streams?device=${encodeURIComponent(S.device)}`);
  const streams = res.streams.slice().sort((a, b) => (b.fromEpoch || 0) - (a.fromEpoch || 0));
  const latest = streams[0];
  $('chunkCount').textContent = latest ? `${latest.chunks} chunks · ${latest.samples} samples · stream ${latest.stream}` : 'no chunks';
  $('gapCount').textContent = latest ? `${latest.missing.length} missing seq · ${S.gaps.length} clock gaps in window` : '—';
  $('gapCount').className = 'pill ' + (latest && (latest.missing.length || S.gaps.length) ? 'is-bad' : 'is-on');
  $('spoolNote').textContent = latest?.info?.keepAlive ? `keep-alive: ${latest.info.keepAlive}` : 'keep-alive: unknown';
  const lines = streams.map(s => `${s.stream}  ${s.from || '—'} → ${s.to || '—'}  ${s.chunks} chunks  ${s.samples} samples  rate ${fmt(s.rateHz, 1)} Hz` +
    (s.missing.length ? `  MISSING ${s.missing.slice(0, 20).join(',')}${s.missing.length > 20 ? '…' : ''}` : '') + (s.emitter ? '  EMITTER-ON' : ''));
  $('chunkList').textContent = lines.join('\n') || 'nothing yet';
}

// ----------------------------------------------------------------------------- events
function connectEvents() {
  const es = new EventSource('api/events');
  es.onopen = () => { $('sse').textContent = 'events: connected'; $('sse').className = 'pill is-on'; };
  es.onerror = () => { $('sse').textContent = 'events: reconnecting…'; $('sse').className = 'pill is-bad'; };
  es.addEventListener('chunk', async (e) => {
    const ev = JSON.parse(e.data);
    S.lastEvent = ev;
    if (!S.device || ev.device !== S.device) { await loadStatus(); if (ev.device !== S.device) return; }
    if (ev.stream !== S.stream) { S.stream = ev.stream; await loadChunks(); }
    S.missing = ev.missing || [];
    S.lastChunkEpoch = Math.max(S.lastChunkEpoch || 0, Date.parse(ev.endedAt) / 1000);
    S.emitter = S.emitter || !!ev.emitter;
    const a = Date.parse(ev.startedAt) / 1000, b = Date.parse(ev.endedAt) / 1000;
    const lastT = S.ring.t.length ? S.ring.t[S.ring.t.length - 1] : a - 1;
    const res = await fetchInto(Math.min(lastT + 1e-4, a), b + 0.5);
    // the column for THIS chunk
    if (S.rateHz && res && res.mag.length >= 64) {
      const c = column(Float64Array.from(res.mag), S.rateHz, 1024);
      spectro.push(a, c.f, c.logPsd);
    }
    redraw();
    if (ev.seq % 6 === 0) loadChunks();
  });
  es.addEventListener('hello', () => loadStatus());
  es.addEventListener('alerts', () => loadAlerts());
  es.addEventListener('register', () => loadRegister());
  es.addEventListener('station', () => loadStation());
  es.addEventListener('job', () => loadJobs());
}

// ----------------------------------------------------------------------------- professional station
async function loadStation() {
  if (!S.device) return;
  let res;
  try { res = await api(`api/station?device=${encodeURIComponent(S.device)}`); } catch { return; }
  const box = $('stationBody');
  if (!res || !res.station) {
    box.innerHTML = '<p class="hint">No reference profile yet. Press the button — it pulls one hour from a real ELF observatory and runs the same census on it.</p>';
    return;
  }
  $('stationSource').textContent = `source: ${res.source || 'api/dataset_fetch'}`;
  const checks = (res.phone_line_checks || []).map(c => {
    const mark = c.present === true ? '<span class="presentmark">PRESENT</span>'
      : c.present === false ? '<span class="absent">absent</span>' : '—';
    return `<div class="linecheck"><span class="hz">${c.hz} Hz</span> — ${mark}
      ${c.prominence != null ? `(${c.prominence}x its neighbourhood; a line needs 3.0x)` : ''}
      <p>${esc(c.reading || c.reason || '')}</p></div>`;
  }).join('');
  const top = (res.census?.components || []).slice(0, 6).map(c =>
    `<div class="linecheck"><span class="hz">${(c.fraction * 100).toFixed(1)}%</span> ${esc(c.label)}</div>`).join('');
  box.innerHTML = `
    <div class="verdict">
      <strong>NOT a simultaneous comparison.</strong>
      <p class="hint">${esc(res.simultaneity_note || '')}</p>
    </div>
    <div class="kpis">
      ${kpi('station', res.station || '—')}
      ${kpi('hour', (res.utc_start || '').slice(0, 16))}
      ${kpi('rate', `${res.rate_hz} Hz`)}
      ${kpi('nyquist', `${res.nyquist_hz} Hz`, 'is-good')}
      ${kpi('archive covers', `${res.coverage?.start} → ${res.coverage?.end}`, 'is-warn')}
    </div>
    <div class="stationgrid">
      <div><p class="ui-label">Does it show the phone's lines?</p>${checks || '<p class="hint">No frequencies were passed to check.</p>'}</div>
      <div><p class="ui-label">What this station's hour contains</p>${top}</div>
    </div>
    <p class="hint">${esc(res.attribution || '')} Licence ${esc(res.licence || '')}. Retrieved via <code>${esc(res.retrieval || '')}</code>.</p>`;
}

async function runStation() {
  if (!S.device) return;
  const btn = $('stationRun');
  btn.disabled = true; btn.textContent = 'Fetching a real ELF hour…';
  // Hand it whatever the register currently holds, so the comparison is against real found lines.
  let freqs = [];
  try {
    const reg = await api(`api/register?device=${encodeURIComponent(S.device)}`);
    freqs = (reg.signals || []).map(s => s.frequency_hz).slice(0, 8);
  } catch { /* a missing register just means nothing to check against */ }
  const extra = freqs.length ? ['--against', freqs.join(',')] : [];
  const now = Date.now() / 1000;
  const res = await post('api/analyze', { command: 'station', device: S.device, from: now - 60, to: now, extra });
  if (res.ok) {
    for (let i = 0; i < 900; i++) {
      await new Promise(r => setTimeout(r, 1000));
      const jobs = (await api('api/jobs')).jobs;
      const j = jobs.find(x => x.id === res.job);
      if (j && j.state !== 'running') break;
    }
    await loadStation(); loadFindings();
  } else alert(res.error || 'failed');
  btn.disabled = false; btn.textContent = 'Compare against a real ELF station';
}

// ----------------------------------------------------------------------------- the signal register
async function loadRegister() {
  if (!S.device) return;
  let res;
  try { res = await api(`api/register?device=${encodeURIComponent(S.device)}`); } catch { return; }
  $('registerCount').textContent = `${res.count} signal${res.count === 1 ? '' : 's'} logged`;
  const box = $('registerList');
  if (!res.count) {
    box.innerHTML = '<p class="hint">Nothing logged yet. Press <strong>Identify signals in this window</strong> — it fingerprints everything above the noise, runs every test it can on its own, and logs what it finds here.</p>';
    return;
  }
  box.innerHTML = res.signals.map(sig => {
    const last = sig.sightings[sig.sightings.length - 1] || {};
    const tests = (last.tests && last.tests.automatic) || [];
    const rows = tests.map(t => {
      const cls = t.passed === true ? 'ok' : t.passed === false ? 'no' : 'na';
      const mark = t.passed === true ? 'PASS' : t.passed === false ? 'FAIL' : ' ?  ';
      return `<div class="t"><span class="mark ${cls}">${mark}</span><span><strong>${esc(t.label)}</strong> — ${esc(t.reason)}</span></div>`;
    }).join('');
    const manual = (sig.outstanding || []).map(m => `
      <div class="item ${m.done ? 'done' : ''}">
        <div class="label">${m.done ? '✓ ' : '☐ '}${esc(m.label)}</div>
        <p class="why"><strong>Settles:</strong> ${esc(m.settles)} <em>${esc(m.expect)}</em></p>
        ${m.done ? `<p class="outcome">recorded: ${esc(m.last_outcome)}</p>` : ''}
        <div class="actions">${m.outcomes.map(o =>
          `<button data-sig="${sig.id}" data-test="${m.id}" data-outcome="${o}">${esc(o)}</button>`).join('')}</div>
      </div>`).join('');
    const fp = last.fingerprint || {};
    return `<div class="sig">
      <div class="head">
        <span class="hz">${sig.frequency_hz} Hz</span>
        <span class="sid">${sig.id}</span>
        <span class="status">${esc(sig.status)}</span>
        <span class="sid">${sig.sighting_count} sighting${sig.sighting_count === 1 ? '' : 's'} · first ${esc((sig.first_seen || '').slice(0, 16))}</span>
      </div>
      <p class="looks">${esc(last.looks_like || '')}</p>
      <div class="grid">
        <div><canvas class="wave" height="150" data-sig="${sig.id}"></canvas></div>
        <div class="tests">
          <p class="hint" style="margin-top:0">rate CV ${fmt(fp.rate_cv, 4)} · ${fp.harmonic_count ?? '—'} harmonics · ${fmt(fp.amplitude_nt, 1)} nT${fp.rate_modulation_in_respiratory_band ? ' · RATE modulated in the respiratory band' : ''}</p>
          ${rows}
        </div>
      </div>
      <div class="manual">
        <h4>Tests only you can run — these are the ones that can actually identify the source</h4>
        ${manual}
      </div>
    </div>`;
  }).join('');
  // draw each waveform, and wire the confirm buttons
  for (const sig of res.signals) {
    const c = box.querySelector(`canvas.wave[data-sig="${sig.id}"]`);
    if (c) waveform(c, sig.waveform);
  }
  box.querySelectorAll('.manual button').forEach(b => b.addEventListener('click', async () => {
    b.disabled = true;
    await post('api/register/confirm', {
      device: S.device, signal: b.dataset.sig, test: b.dataset.test, outcome: b.dataset.outcome });
    await loadRegister();
  }));
}

async function identifySignals() {
  if (!S.device) return;
  const btn = $('identify');
  btn.disabled = true; btn.textContent = 'Identifying…';
  const to = S.lastChunkEpoch || Date.now() / 1000;
  const from = to - Number($('window').value);
  const res = await post('api/analyze', { command: 'identify', device: S.device, from, to });
  if (res.ok) {
    for (let i = 0; i < 900; i++) {
      await new Promise(r => setTimeout(r, 1000));
      const jobs = (await api('api/jobs')).jobs;
      const j = jobs.find(x => x.id === res.job);
      if (j && j.state !== 'running') break;
    }
    await loadRegister();
  } else alert(res.error || 'failed');
  btn.disabled = false; btn.textContent = 'Identify signals in this window';
}

// ----------------------------------------------------------------------------- jobs
function renderBandNotches() {
  const row = $('bandNotchRow');
  const notchable = S.bands.filter(b => /^(mains|traction)/.test(b.id));
  row.querySelectorAll('label').forEach(l => l.remove());
  for (const b of notchable) {
    const lab = document.createElement('label');
    lab.innerHTML = `<input type="checkbox" data-bandnotch="${b.id}"> ${b.id}`;
    row.appendChild(lab);
    lab.querySelector('input').addEventListener('change', (e) => {
      if (e.target.checked) {
        // notch at the band centre, folded into the sampled range if needed
        const fs = S.rateHz || 100, centre = (b.lowHz + b.highHz) / 2;
        const ny = fs / 2; let f = centre % fs; if (f > ny) f = fs - f;
        S.notches.set('band:' + b.id, { hz: f });
        $('fRaw').checked = false;
      } else S.notches.delete('band:' + b.id);
      redraw();
    });
  }
}

function renderInterference() {
  const box = $('interferenceList');
  if (!S.interference.length) { box.innerHTML = ''; return; }
  const cls = { hardIronDC: 'hard', currentModulated: 'rate', movingActuator: 'actu', softIron: 'soft' };
  box.innerHTML = S.interference.map(src => {
    const f = src.suggestedFilter;
    const canNotch = f && f.kind === 'notch';
    const toggle = canNotch
      ? `<label class="toggle"><input type="checkbox" data-notch="${src.id}"> notch ${(f.harmonics || [f.hz]).join(', ')} Hz</label>`
      : (f && f.kind === 'highPass') ? `<span class="toggle">use the High-pass toggle above</span>`
      : `<span class="toggle">no filter — physical mitigation only</span>`;
    return `<div class="src"><div class="head">
        <span class="name">${src.name}</span>
        <span class="chip ${cls[src.character] || ''}">${src.character}</span>
        <span class="chip">${src.origin}</span>
        <span class="chip">${src.orderOfMagnitude}</span>
        ${toggle}
      </div>
      <p><strong>Effect:</strong> ${src.effect}</p>
      <p><strong>Tell:</strong> ${src.tell}</p>
      <p><strong>Do:</strong> ${src.mitigation}</p></div>`;
  }).join('');
  box.querySelectorAll('input[data-notch]').forEach(cb => cb.addEventListener('change', () => {
    const id = cb.getAttribute('data-notch');
    const src = S.interference.find(s => s.id === id);
    if (cb.checked) { S.notches.set(id, src.suggestedFilter); $('fRaw').checked = false; }
    else S.notches.delete(id);
    redraw();
  }));
}

// ----------------------------------------------------------------------------- alerts
async function loadAlerts() {
  if (!S.device) return;
  let res;
  try { res = await api(`api/alerts?device=${encodeURIComponent(S.device)}`); } catch { return; }
  const box = $('alertBanner');
  const a = res.alerts;
  if (!a) { box.hidden = true; return; }
  box.hidden = false;
  const ageS = res.computedAt ? (Date.now() / 1000 - res.computedAt) : null;
  // A scan describes the window it ran on, not "now". Saying so is the difference between an alert
  // and a claim about the present.
  const stale = ageS != null && ageS > 900;
  const when = res.computedAt
    ? `scanned ${new Date(res.from * 1000).toLocaleTimeString([], { hour12: false })}–${new Date(res.to * 1000).toLocaleTimeString([], { hour12: false })}, ${ago(res.computedAt)} ago`
    : '';
  if (!a.count) {
    box.className = 'alertbar is-quiet';
    box.innerHTML = `<h2 class="ui-display ui-display--3">Nothing above the noise in that window</h2>
      <p class="means">${a.means || ''}</p><p class="when ${stale ? 'stale' : ''}">${when}</p>`;
    return;
  }
  box.className = 'alertbar';
  const rows = a.alerts.map(al => {
    const consistent = (al.consistent_with || []).map(c => c.label).join(', ');
    const ruled = (al.ruled_out || []).map(c => `${c.label} (max ${c.max_nt} nT)`).join(', ');
    return `<div class="alert">
      <div class="head"><span class="kind ${al.kind}">${al.kind}</span>
        <span class="title">${esc(al.headline)}</span></div>
      <p>${esc(al.detail)}</p>
      ${consistent ? `<p class="ruled"><strong>Consistent with:</strong> ${esc(consistent)}</p>`
                   : `<p class="ruled"><strong>Consistent with:</strong> nothing this sensor can reach.</p>`}
      ${ruled ? `<p class="ruled"><strong>Ruled out — too small for this sensor:</strong> ${esc(ruled)}</p>` : ''}
      ${al.next_test ? `<p class="next"><strong>Next test:</strong> ${esc(al.next_test)}</p>` : ''}
    </div>`;
  }).join('');
  box.innerHTML = `<h2 class="ui-display ui-display--3">${a.count} thing${a.count === 1 ? '' : 's'} in this record that noise does not produce</h2>
    <p class="means">${esc(a.means || '')}</p>
    <p class="when ${stale ? 'stale' : ''}">${when}${stale ? ' — older than 15 minutes; re-scan before reading it as current.' : ''}</p>
    ${rows}
    <p class="means">${esc(a.caveat || '')}</p>`;
}

const esc = escapeHtml;

async function scanForSignals() {
  if (!S.device) return;
  const btn = $('scan');
  btn.disabled = true; btn.textContent = 'Scanning…';
  const to = S.lastChunkEpoch || Date.now() / 1000;
  const from = to - Number($('window').value);
  const res = await post('api/analyze', { command: 'alerts', device: S.device, from, to });
  if (!res.ok) { alert(res.error || 'failed'); btn.disabled = false; btn.textContent = 'Scan for signals'; return; }
  // Poll until the job finishes; the coupling ladder takes a minute or two.
  for (let i = 0; i < 600; i++) {
    await new Promise(r => setTimeout(r, 1000));
    const jobs = (await api('api/jobs')).jobs;
    const j = jobs.find(x => x.id === res.job);
    if (j && j.state !== 'running') break;
  }
  await loadAlerts();
  await loadJobs();
  btn.disabled = false; btn.textContent = 'Scan for signals';
}

async function loadJobs() {
  const res = await api('api/jobs');
  $('jobs').innerHTML = res.jobs.map(j => `<div class="job"><div class="head"><span class="pill ${j.state === 'done' ? 'is-on' : j.state === 'failed' ? 'is-bad' : ''}">${j.id} · ${j.state}</span>
    <span>${escapeHtml(j.command)} · ${escapeHtml(j.device)} · ${new Date(j.from * 1000).toISOString()} → ${new Date(j.to * 1000).toISOString()}</span></div>
    <div class="out">${escapeHtml(j.output || '(no output yet)')}</div></div>`).join('') || '<p class="hint">No jobs yet.</p>';
}

async function runJob() {
  if (!S.device) return;
  const now = Date.now() / 1000;
  let from, to;
  if ($('jobWindow').value === 'custom') {
    from = Date.parse($('jobFrom').value) / 1000; to = Date.parse($('jobTo').value) / 1000;
    if (!isFinite(from) || !isFinite(to)) { alert('From/To must be ISO-8601'); return; }
  } else {
    to = S.lastChunkEpoch || now; from = to - Number($('jobWindow').value);
  }
  const res = await post('api/analyze', { command: $('cmd').value, device: S.device, from, to });
  if (!res.ok) alert(res.error || 'failed');
  await loadJobs();
}

// ----------------------------------------------------------------------------- wiring
$('device').addEventListener('change', e => selectDevice(e.target.value));
for (const id of ['window', 'specSeconds', 'channel', 'target']) $(id).addEventListener('change', redraw);
// Filter toggles. Raw and the processing filters are mutually exclusive: turning any filter on
// clears Raw; turning Raw on clears every filter and every per-source notch.
$('fRaw').addEventListener('change', () => {
  if ($('fRaw').checked) {
    $('fHighpass').checked = false; $('fDetrend').checked = false; S.notches.clear();
    document.querySelectorAll('input[data-notch]').forEach(cb => cb.checked = false);
  }
  redraw();
});
for (const id of ['fHighpass', 'fDetrend', 'fHpHz']) $(id).addEventListener('change', () => {
  if ($('fHighpass').checked || $('fDetrend').checked) $('fRaw').checked = false;
  redraw();
});
$('runJob').addEventListener('click', runJob);
$('scan').addEventListener('click', scanForSignals);
$('identify').addEventListener('click', identifySignals);
$('stationRun').addEventListener('click', runStation);
window.addEventListener('resize', redraw);
setInterval(() => { if (S.device) redraw(); }, 5000);   // the "last chunk … ago" readout, and staleness

(async () => {
  // FIRST: which of this page's panels belong to the consuming project, and which to the device.
  // Done before the claim-owned loaders run, so an undeclared panel is never populated at all
  // rather than filled and then hidden.
  const claim = await applyClaim();
  const wants = new Set(claim.declared ? (claim.panels || []) : []);
  try { S.bands = (await api('api/bands')).bands; } catch { S.bands = []; }
  try { const inf = await api('api/interference'); S.interference = inf.sources; if (inf.philosophy) $('filterPhilosophy').textContent = inf.philosophy; renderInterference(); } catch { S.interference = []; }
  renderBandNotches();
  await loadStatus();
  await loadJobs();
  if (wants.has('alerts')) await loadAlerts();
  if (wants.has('register')) await loadRegister();
  if (wants.has('station')) await loadStation();
  connectEvents();
  redraw();
})();

// ----------------------------------------------------------------------------- measured findings
// The page's one non-live panel. Everything else here shows what the phone is doing NOW; this shows
// what has been established, including the station work that previously existed only on the command
// line and was invisible in the browser.
async function loadFindings() {
  const box = $('findingsBody');
  if (!box) return;
  let d;
  try { d = await api('api/findings'); } catch { return; }
  if (!d || d.available === false) {
    box.innerHTML = `<p class="hint">Not generated yet — run <code>${esc(d?.how || 'analysis/run.py summary')}</code>.</p>`;
    return;
  }
  const rows = [];
  const R = d.reach || {};
  const cav = R.cavity_on_this_phone || {}, echo = R.echo_timing_on_this_phone || {};
  rows.push(`<h3 class="ui-label">The geometry, and what this rig can reach</h3>
    <table class="tbl"><tbody>
    <tr><td>one lap of the cavity</td><td><strong>${R.lap_ms} ms</strong> → lap rate <strong>${R.lap_rate_hz} Hz</strong>, against a Schumann fundamental of ${R.schumann_f1_hz} Hz — the same quantity</td></tr>
    <tr><td>see the cavity on this phone</td><td><span class="pill pill--${cav.reach === 'reachable' ? 'ok' : 'bad'}">${esc(cav.reach || '')}</span> ${cav.required_dwell_years} years of coherent dwell</td></tr>
    <tr><td>resolve one lap from the next</td><td><span class="pill pill--${echo.reach === 'reachable' ? 'ok' : 'bad'}">${esc(echo.reach || '')}</span> ${echo.peaks_per_lap}× separation — <strong>the sample rate is already adequate; only the sensitivity is not</strong></td></tr>
    </tbody></table>`);

  const b = d.station_baseline || {};
  if (b.available) {
    const modes = (b.modes || []).map(m =>
      `<tr><td>mode ${m.mode}</td><td><strong>${m.median_hz} Hz</strong></td><td>Q ${m.median_q}</td><td>moved ${m.range_hz} Hz across the day</td></tr>`).join('');
    rows.push(`<h3 class="ui-label">The professional ELF station — ${b.hours_fetched} hours, ${b.date}</h3>
      <p class="hint">${esc(b.station)}. ${b.hours_all_five_modes} hours resolved all five Schumann modes. ${esc(b.note)}</p>
      <table class="tbl"><tbody>${modes}</tbody></table>`);
    const dd = b.diurnal || {};
    if (dd.reading) {
      rows.push(`<p><strong>Did the cavity track the sun?</strong> ${esc(dd.reading)}
        Implied diurnal swing of the fundamental: <strong>${dd.implied_fundamental_swing_hz} Hz</strong>.</p>
        <p class="hint">Rank-1 check: <code>${esc(dd.rank1_verdict || '')}</code> — ${esc(dd.rank1_reading || '')}</p>`);
    }
    if (b.component_agreement) {
      rows.push(`<p class="hint"><strong>Orthogonal coil:</strong> ${esc(b.component_agreement.reading)}</p>`);
    }
  }

  const dc = d.device_control || {};
  if (dc.available) {
    rows.push(`<h3 class="ui-label">Another person's iPhone, as a control</h3>
      <p class="hint">${esc(dc.dataset)} — ${esc(dc.device)}. ${esc(dc.caveats)}</p>
      <ul>${(dc.established || []).map(x => `<li>${esc(x)}</li>`).join('')}</ul>
      <p class="hint">${esc(dc.attribution)}</p>`);
  }

  const et = d.echo_test || {};
  if (et.reading) {
    rows.push(`<h3 class="ui-label">Can the echo test run at all?</h3>
      <p><span class="pill pill--bad">${et.separable ? 'separable' : 'NOT SEPARABLE'}</span>
      ${esc(et.reading)}</p>
      <p class="hint">What would separate them instead:</p>
      <ul>${(et.what_would_separate_them || []).map(x => `<li>${esc(x)}</li>`).join('')}</ul>
      <table class="tbl"><thead><tr><th>frequency</th><th>attenuation</th><th>per lap</th><th>laps to −40 dB</th></tr></thead><tbody>
      ${(et.attenuation_vs_frequency || []).map(a =>
        `<tr><td>${a.hz} Hz</td><td>${a.db_per_megametre} dB/Mm</td><td>${a.db_per_lap} dB</td><td>${a.laps_to_40db}</td></tr>`).join('')}
      </tbody></table>
      <p class="hint">Attenuation rises with frequency, which is why the Schumann band survives many
      laps and 82 Hz survives about one.</p>
      <h3 class="ui-label">Events whose timing is known in advance</h3>
      <table class="tbl"><tbody>${(et.predictable_events || []).map(e =>
        `<tr><td><strong>${esc(e.event)}</strong><br><span class="hint">${esc(e.timing)}</span></td>
         <td>${esc(e.predicted_effect)}</td><td>${esc(e.status)}</td></tr>`).join('')}</tbody></table>`);
  }

  const ps = d.phone_signals || {};
  if (ps.available) {
    rows.push(`<h3 class="ui-label">This phone's own register — ${ps.count} signals</h3>
      <p class="hint">${esc(ps.note)}</p>`);
  }
  if (d.standing_caution) rows.push(`<p class="hint"><strong>${esc(d.standing_caution)}</strong></p>`);
  box.innerHTML = rows.join('');
}
