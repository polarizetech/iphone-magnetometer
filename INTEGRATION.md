# Using FieldLab's stream from your own project

**This tool owns one iPhone, its stream, and the store on disk. Your project reads it.** There is
no per-project copy of the data and there must not be — one device, one record.

| You want | Read |
|---|---|
| Live samples in a **web page** | §2, `fieldlab-client.js` |
| The recording in **Python** | §3, `store.py` |
| To ship **your own page** on top of the recorder | §4 |
| To run **your own analysis** from the dashboard's job runner | §5 |
| To know what the recorder **cannot** tell you | §6 |

---

## 0. Start it (once, shared by everything)

```bash
python3 serve.py 8212
```

Run it on a private network the phone can reach (a tailnet or LAN), and put that URL in the app's
Stream settings. Behind a reverse proxy it can live under a path prefix (`FIELDLAB_PREFIXES`).

**Only one process may own the store.** That is why this is a tool and not a copy in each project:
the phone deletes its own copy of a chunk the moment this server acknowledges it, so a second
writer means the two halves of a recording exist in different folders and neither is complete.

The viewer is at `/`. It draws what arrived and does not interpret it.

---

## 1. The two states that are not the same

Everything below distinguishes these, and your UI must too:

| state | means |
|---|---|
| **no reading** | nothing was recorded in this window — the phone was off, or offline |
| **a measurement** | something was recorded, and here is what it was |

Rendering "no reading" as a quiet or empty measurement is the single most common way to get a
confident wrong answer out of this tool. `store.summary()` returns `available: false` and the HTTP
routes return `available: false` for exactly this; do not collapse it into a zero.

The other one: **a reading describes a WINDOW, never "now".** The phone streams intermittently and
spools when it is off wifi, so the newest data is routinely hours old. Put the window's age on
screen in words — `FieldLab.describeAge()` does it — rather than leaving a reader to subtract
timestamps.

---

## 2. A web page

```html
<script src="https://<your-server>/fieldlab-client.js"></script>
```

Served from the tool so every consumer shares one copy and they cannot drift. **Reads are
CORS-open**, so a project on its own port can fetch across; writes are not (see §6).

```js
const fl = new FieldLab({ base: 'https://<your-server>' });

const devices = await fl.devices();
const dev = devices[0].device;

const w = await fl.latest(dev, 300);        // the newest window that HOLDS data
if (!w.available) {
  show(`No recording — ${w.reason}`);       // NOT "the signal is quiet"
} else {
  show(`over ${w.reading.window_s}s, ${w.describeAge()}`);
}

fl.onChunk(() => refresh());                 // fires when the phone lands a chunk
```

`fl.samples(dev, from, to, step)` gives raw samples for a window (epoch seconds). Ask for bins,
not every sample, over anything long — the server refuses windows over 6 h at `step < 10`, because
a naive request for a day is 8.7 million rows.

---

## 3. Python

```python
import store          # pip install git+https://github.com/polarizetech/iphone-magnetometer, or put this repo on sys.path

for dev in store.devices():
    print(store.summary(dev))               # available? how fresh? how much?

win = store.latest_window(dev, seconds=300)  # None means NO RECORDING
if win:
    for row in store.read_rows(dev, *win):
        row["mx_uT"], row["my_uT"], row["mz_uT"], row["wall_epoch"]
```

**`store.py` is stdlib-only and imports nothing from `serve.py`** — asserted by a test — so a
consumer needs no venv, no numpy and no running server to read the record.

Three things it handles that you should not re-implement:

- **`runs()`** groups chunks into continuous recordings. A stream folder is not one recording: it
  holds every start the phone made, suspended stretches, and single-chunk **stragglers** of a few
  hundred milliseconds uploaded as the app died. Asking for "the newest data" naively returned
  **70 samples spanning 0.7 s** and read as a real, empty window.
- **`latest_window()`** applies a minimum coverage, so it skips those.
- **`read_rows()`** adds `wall_epoch`. The CSV carries the sensor's **monotonic** clock; joining
  against anything in the world needs wall time, and the mapping is per chunk.

For numpy arrays and a session object with metadata (measured rate, clock jitter), use `session.py`:
`session.load_stream(<store>/<device>)`. `census.py` partitions a session's variance into named bands.

---

## 4. Shipping your own page

The recorder's viewer is deliberately generic. If your project wants a page about **its** question
— a gate, a checklist, its own readouts — put it in `<your-project>/watch/` and this server mounts
it at `/watch` without knowing anything about it.

```
your-project/
  analysis/            ← FIELDLAB_ANALYSIS points here
  watch/index.html     ← served at /watch/
  watch/your.css .js
```

Only `.html`, `.css` and `.js` are served, no traversal, no directory listing — the folder sits
inside a project that also holds analysis code and cached data.

Write assets **relative** (`../design/design.css`, `watch.js`). A reverse proxy that strips a mount
prefix does not rewrite HTML, so a root-relative `/design/design.css` escapes the mount and 404s
behind the proxy while working perfectly on localhost.

---

## 5. Your own analysis, from the job runner

`POST /api/analyze` shells out to `<analysis>/run.py <command> --stream … --from … --to …` in
**your** venv and streams the result back as a job. Set `FIELDLAB_ANALYSIS` to your analysis
directory; without it the job runner is disabled.

The server **never imports your analysis** for this — a missing or broken sidecar degrades to a
disabled button, not an import error that takes the device offline.

The one exception is `runbook.py`, which the server imports directly because it is stdlib on
purpose: ticking a checkbox must not cost an interpreter start.

---

## 6. What this tool will not do

- **It does not interpret.** No verdicts, no identification, no claim about what a line *is*.
  Frequency proximity never identifies a source. That belongs to your project.
- **It will not take a cross-origin write.** Reads are CORS-open so any project can consume the
  stream. Every POST must be `application/json` or the chunk type, which a browser will only send
  cross-origin after a preflight this server never grants. Any page may read the record; only this
  tool's own pages may change it.
- **It cannot give you a signal the sensor never had.** Up to 100 Hz sampling, analogue bandwidth far
  below VLF, and a noise floor of tens of nT/√Hz. Work out the coherent dwell your target needs
  before designing around a faint signal.
- **It does not guarantee the phone is streaming.** `wifiOnly` is on by default, so off wifi the
  app records and spools and uploads nothing until it is back. Check `summary()["age_s"]`.

---

## 7. If you find yourself copying

If you are copying anything out of this repo rather than importing it, the seam is in the wrong
place; open an issue rather than forking.
