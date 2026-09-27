/* fieldlab-client.js — the phone's magnetometer, in any web page that can reach the server.
 *
 *   <script src="https://<your-server>/fieldlab-client.js"></script>
 *   const fl = new FieldLab();                 // same origin, or {base: 'https://<your-server>'}
 *   const devs = await fl.devices();
 *   fl.onChunk(() => redraw());                // fires when the phone lands a new chunk
 *   const w = await fl.latest(devs[0].device, 300);   // the newest window that HOLDS data
 *
 * Served from the tool itself, the same way `eeg-bridge` serves `eeg-client.js`: every consumer
 * gets one copy and they cannot drift. Copy it into your project only if you mean to fork it.
 *
 * ## Two things this client exists to stop you getting wrong
 *
 * 1. **"The last five minutes" is not `now - 300`.** The phone may have stopped hours ago, and the
 *    newest thing in the store is often a straggler chunk of a few hundred milliseconds uploaded
 *    as the app died. `latest()` asks the server for the newest run that actually holds data.
 * 2. **A reading describes a WINDOW, never "now".** Every result carries `ageSeconds` and
 *    `describeAge()`, because a live-looking page over a two-day-old window is the failure this
 *    whole tool keeps re-learning. Put the age on screen, in words.
 */
(function (global) {
  'use strict';

  class FieldLab {
    /** @param {{base?: string}} opts base is the tool's mount; default = this page's origin+dir. */
    constructor(opts = {}) {
      this.base = (opts.base || '.').replace(/\/+$/, '');
      this._es = null;
      this._handlers = { chunk: [], status: [], error: [] };
    }

    _url(path, params) {
      const u = `${this.base}/${path.replace(/^\/+/, '')}`;
      if (!params) return u;
      const q = new URLSearchParams(
        Object.entries(params).filter(([, v]) => v !== undefined && v !== null));
      return q.toString() ? `${u}?${q}` : u;
    }

    async _get(path, params) {
      const res = await fetch(this._url(path, params));
      if (!res.ok) throw new Error(`${path} -> ${res.status}`);
      return res.json();
    }

    /** Every device that has ever streamed here, newest activity first. */
    async devices() {
      const s = await this._get('api/status');
      return (s.devices || []).map(d => ({
        device: d.device, name: d.name,
        streams: (d.streams || []).length,
        latest: d.latest || null,
      }));
    }

    /** Per-stream detail for one device: chunk counts, gaps, achieved rate, phone state. */
    streams(device) { return this._get('api/streams', { device }); }

    /**
     * A window of samples. `from`/`to` are epoch SECONDS; `step` bin-averages (ask for bins, not
     * every sample, over anything long — the server refuses >6 h at step < 10).
     */
    samples(device, from, to, step = 1) {
      return this._get('api/samples', { device, from, to, step });
    }

    /**
     * The newest window that actually holds data, already read and measured server-side.
     * Returns the payload plus `ageSeconds`/`describeAge()` for the END of the window.
     *
     * `available: false` means NO RECORDING — render it as that, never as a quiet or empty
     * measurement. "Nothing was recorded" and "nothing was there" are different claims and only
     * one of them is a measurement.
     */
    async latest(device, seconds = 300) {
      const res = await this._get('api/watch', { device, seconds });
      const end = res.window ? res.window[1] : null;
      res.ageSeconds = end ? (Date.now() / 1000 - end) : null;
      res.describeAge = () => FieldLab.describeAge(res.ageSeconds);
      return res;
    }

    /** Age in words. Use it: subtracting timestamps is not something a reader does in their head. */
    static describeAge(s) {
      if (s == null) return 'unknown age';
      if (s < 20) return 'just now';
      if (s < 90) return `${Math.round(s)} s ago`;
      if (s < 5400) return `${Math.round(s / 60)} min ago`;
      if (s < 172800) return `${Math.round(s / 3600)} h ago`;
      return `${Math.round(s / 86400)} days ago`;
    }

    /** The band catalogue, parsed from the iOS app's BandRegistry.swift — one source of truth. */
    bands() { return this._get('api/bands'); }

    /** Fires when the phone lands a chunk. Returns an unsubscribe function. */
    onChunk(fn) { return this._on('chunk', fn); }
    onError(fn) { return this._on('error', fn); }

    _on(event, fn) {
      this._handlers[event] = this._handlers[event] || [];
      this._handlers[event].push(fn);
      this._connect();
      return () => {
        this._handlers[event] = this._handlers[event].filter(h => h !== fn);
      };
    }

    _connect() {
      if (this._es) return;
      try {
        this._es = new EventSource(this._url('api/events'));
        ['chunk', 'status', 'register', 'runbook'].forEach(evt =>
          this._es.addEventListener(evt, e => {
            let data = null;
            try { data = JSON.parse(e.data); } catch { /* a heartbeat carries no body */ }
            (this._handlers[evt] || []).forEach(h => h(data));
          }));
        this._es.onerror = () => (this._handlers.error || []).forEach(h => h());
      } catch (err) {
        (this._handlers.error || []).forEach(h => h(err));
      }
    }

    /** Drop the event stream. A page that is done should call this; browsers cap open streams. */
    close() { if (this._es) { this._es.close(); this._es = null; } }
  }

  global.FieldLab = FieldLab;
  if (typeof module !== 'undefined' && module.exports) module.exports = FieldLab;
})(typeof window !== 'undefined' ? window : globalThis);
