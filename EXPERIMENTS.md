# Experiments

One row per experiment. Status and verdict change here; the experiment's own files are frozen at its tags.
The rules are `.agents/protocols/PREREG_PROTOCOL.md`.

| EID | Question | Replaces | Opened | Status | Verdict | Archive (DOI) |
|---|---|---|---|---|---|---|

No experiment has been opened under the kit (2026-09-25).

## Earlier preregistration systems

Both stay exactly as they are. New experiments use the kit (`experiments/<EID>/`, `<EID>-prereg` tags).

- **FieldLab's in-app protocol.** Each session carries a `protocolSnapshot` and a code hash, written on
  the phone before acquisition, and `SignalProcessor` computes the result tier from it
  (`preregistered` only when the run was also blinded and passed its gates). This labels individual
  recordings; it is not a git-tagged preregistration, and nothing here converts it into one.
- **CardioMag Probe's `cardiomagprobe/docs/PROTOCOL.md`**, a written acquisition and decision
  protocol. It was never tagged or frozen in git.

## Queued: open questions not yet opened as experiments

A plan, not a register. An EID gets a row above only when its folder is created.

| question | first experiment it needs | blocked on |
|---|---|---|
| Does CoreMotion deliver 64 Hz when asked? | record at 64 Hz and measure the achieved rate (`CHANGELOG.md` 2026-09-16) | a phone run |
| Is the unexplained local line an alias? | record at 100 Hz, then 64 Hz; an alias moves, a real line does not | the 64 Hz rate being confirmed; the claim lives in the monorepo's `falsify/unexplained-local-line` |
| Does the calibrated channel remove the MagSafe offset? | log `CMDeviceMotion.magneticField` beside the raw channel (`CLAUDE.md`, open defect) | an app build |
