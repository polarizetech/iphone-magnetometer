# Changelog

Changes to the tool. Findings made with it are recorded by the studies that use it, not here.

## 0.1.0 — 2026-09-27

First public release, extracted from the private study that built it.

- **FieldLab (iOS):** always-on streaming of the raw magnetometer, device motion and timing in
  self-describing chunks; a durable on-phone spool that deletes a chunk only on the server's `ok`
  ack; per-request Wi-Fi-only; at most 16 uploads in flight; optional GPS that stops with the last
  measurement that asked for it; settings that survive app updates field by field.
- **Server:** stores chunks idempotently and refuses to overwrite a stored one (409); validates
  headers; confines static files to `web/`; accepts only JSON or chunk POSTs, so no other web page can
  write to it; size limits on bodies and job windows; a consuming analysis configured by environment
  or `fieldlab.env`, never built in.
- **Readers:** `store.manifest` as the one reader of the store; `session` loads a window with its
  measured rate and clock jitter; `census` partitions variance into named bands with a prominence bar
  computed from how many bins were searched.
- **CardioMag Probe:** heartbeat-triggered analysis off the main thread and fast enough to run on
  Stop; PPG beat times converted exactly to the sensor clock; the camera session reused across
  recordings; camera usage string declared. The Python analysis runs on numpy, pandas and scipy alone.
- **Tooling:** ruff and swift-format in `make check`; CI; MIT + CC BY 4.0; adaptive preregistration
  for measurements of the tool itself.
