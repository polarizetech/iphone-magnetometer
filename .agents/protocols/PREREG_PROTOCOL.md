# PREREG_PROTOCOL.md — Adaptive Preregistration for Model Experiments

**Applies to:** everyone who runs experiments in this repo: people, scripts and coding assistants.
**Status of this file:** binding. If a task conflicts with it, stop and say so before doing the task.
**Installed by:** the KIT Adaptive Preregistration `prereg` module, which also adds the one-line rule to `AGENTS.md`.
**License:** CC BY 4.0, from [KIT Adaptive Preregistration](https://github.com/polarizetech/adaptive-preregistration). Reuse it with credit.

---

## 0. The five rules (read these even if you read nothing else)

1. **No run before PREREG.** A run that produces a result a report will cite may not execute until
   `experiments/<EID>/PREREG.md` is complete (§3) and tagged `<EID>-prereg`. Pilot runs to debug code are
   allowed only under the conditions in §3.5, and are never cited.
2. **The environment is part of the preregistration.** `PREREG.md` names the model version it runs against,
   and the experiment folder has a lockfile that pins every dependency. No floating versions. Adding a
   dependency after `-prereg` is a deviation (§5).
3. **Failure closes the version; it does not edit it.** If the preregistered criteria fail, tag
   `<EID>-closed`, write `RESULTS.md` with the failure, and open a new experiment ID. Every EID is listed in
   `EXPERIMENTS.md` (§1), so a pass after earlier failures is reported as one attempt among several, never on
   its own.
4. **Every departure from the plan goes in `DEVIATIONS.md`,** dated, with whether the outcome was known at the
   time. A deviation that is not logged is a protocol violation, not a judgement call.
5. **Exploratory work is quarantined.** Anything not in `PREREG.md` lives under `experiments/<EID>/exploratory/`
   and is labelled exploratory in every report that mentions it.

---

## 1. Repository layout

```
model/                       # the simulator. Versioned with semver tags: model-vX.Y.Z
EXPERIMENTS.md               # registry: one row per EID, including abandoned and failed ones (below)
experiments/
  <EID>/                     # e.g. E04-stentor-map
    PREREG.md                # written BEFORE any scoring run (§3)
    ENV.lock                 # pinned environment (§4)
    config.yaml              # every parameter; model tag; seeds
    run.py                   # the only entry point that produces citable results
    DEVIATIONS.md            # deviations and unregistered steps (§5)
    RESULTS.md               # written AFTER the run, against PREREG.md (§6)
    exploratory/             # post-hoc work; never cited as a preregistered result
      pilot/                 # pilot runs allowed before -prereg (§3.5)
    outputs/                 # raw outputs, checksummed
CHANGELOG.md                 # model/ changes and which experiments each invalidates
ASSUMPTIONS.md               # standing modelling assumptions with provenance tags
DEFERRED.md                  # ideas explicitly not pursued yet
```

One experiment = one folder = one prediction set. A new prediction set is a new EID, even if the code is
identical.

**`EXPERIMENTS.md`** lists every EID, created when its folder is:

```markdown
| EID | Question (short) | Replaces | Opened | Status | Verdict | Archive (DOI) |
|-----|------------------|----------|--------|--------|---------|---------------|
```

`Status` is one of {open, prereg, run, closed, abandoned}. An EID abandoned before `-prereg` stays in the table
with the reason. `Replaces` names the earlier EID for the same question, so the number of attempts is always
visible.

---

## 2. Versions, tags and the record

| Tag | When |
|---|---|
| `model-vX.Y.Z` | Any change to `model/` that alters numerical output |
| `<EID>-prereg` | Commit that adds a complete `PREREG.md` + `ENV.lock` + `config.yaml` |
| `<EID>-interim-N` | Adaptive stage N plan revision, before its dependent run (§3.4) |
| `<EID>-run` | Commit that adds `outputs/` + `RESULTS.md` |
| `<EID>-closed` | Experiment is finished, pass or fail |

- Tags are annotated with the ISO date in the message (`.agents/tools/tag` does this, when the
  `experiment-pr-log` module is installed). Tags are never moved or deleted. That is a rule, not something
  git enforces; see "How far the record can be trusted" below.
- `model/` changes bump the version. An experiment's `config.yaml` records the exact `model-v*` it ran against.
  If the model is patched later, the old result stands as it is and `CHANGELOG.md` states which experiments the
  patch invalidates. Re-running under the new model is a new EID.
- Before a `model-v*` tag is pushed, re-run each previous `<EID>-run` from its own tags and confirm the outputs
  match within the tolerance its `PREREG.md` §7 states. Bit-for-bit is the target where the platform allows
  it; say when it doesn't.

### How far the record can be trusted

Local git history shows the order of events only to people who trust the machine it was made on. Tags can be
deleted and re-created, history can be rewritten, and a pre-commit hook can be bypassed with `--no-verify`.
Strengthen it in proportion to how much outsiders need to rely on the result:

- **Sign tags** (`git config tag.gpgSign true`; `.agents/tools/tag` then signs automatically).
- **Protect tags on the host** (GitHub tag protection or rulesets), so pushed milestone tags can't be moved.
- **Deposit `<EID>-prereg` with an archive**: an OSF registration, a Zenodo release (DOI) or Software
  Heritage (SWHID). Record the identifier in `PREREG.md` §11. This is the only step here that gives an
  independent, immutable timestamp. Step by step: `ARCHIVING.md`.
- **PR receipts** (`EXPERIMENT_PR_LOG.md`) are evidence that the tagged plan existed by the comment's time.
  They are not an archive (comments can be edited or deleted), and they can't show that nothing ran before
  the plan.

If the local git history is all there is, say so in `PREREG.md` §11.

---

## 3. PREREG.md — required sections

A `PREREG.md` missing any of the eleven sections below is incomplete; don't tag `-prereg`.

```markdown
# <EID> — <one-line title>
Preregistered: <ISO date>   Model tag: model-vX.Y.Z   Author: <name, or "coding assistant + name">
Attempt: <n> of the question in EXPERIMENTS.md (replaces <EID or "none">)

## 1. Question
One sentence. A mechanistic claim, not "explore".

## 2. Prediction(s): risky, numeric, directional
P1: ...   (what the hypothesis says will happen)
P2: ...
For each, state what result would COUNT AGAINST the hypothesis.

## 3. Estimands and pass / fail criteria (numbers written before any output is seen)
| Criterion | Estimand | Performance measure | Uncertainty (MCSE / interval) | Pass | Fail | Derivation |
- The estimand is the quantity the run estimates; the performance measure is how a run is scored against it.
- Pass means the interval clears the threshold, not only the point estimate.
- Define what makes the result UNINTERPRETABLE (e.g. controls fail, too many failed runs).
- Analytic predictions (e.g. the expected slope for a two-stage cascade) are derived HERE, not after.

## 4. Falsifiers
What outcome would weaken the hypothesis enough to close this line of work.

## 5. Model specification
Equations, parameters, units. Tag each parameter [LIT: doi], [DERIVED: from what] or [ARBITRARY].
A [DERIVED] tag names its derivation; an untraceable one counts as [ARBITRARY].

## 6. Design
- Conditions, controls (plasticity-off, surrogate/shuffled, null model), analysis window, exclusion rules
  for failed runs.
- Seeds: a fixed list.
- Number of runs per arm, with the justification (e.g. the Monte Carlo standard error it gives on each
  estimand in §3), and the stopping rule. No stopping when the result looks good.
- Sensitivity analysis for every [ARBITRARY] parameter: its range, the method (one-at-a-time or global), and
  the rule. The rule is fixed here: a pass that flips to a fail anywhere in a preregistered range is reported
  as not robust, not as a pass.

## 7. Environment
Language and version, `ENV.lock` sha256, hardware/OS, execution target (e.g. Brian2
`prefs.codegen.target`), thread count, and the numerical tolerance for reproducing a run. The same seed
doesn't give the same result on every target, so pin it.

## 8. Prior knowledge and calibration
- Which target data, empirical patterns or earlier outputs the authors have already seen or used.
- Which targets the model was calibrated or fitted to, and how.
- Which targets are held out for validation. A prediction of a pattern the model was tuned to is not risky;
  say so.

## 9. Adaptive stages (optional)
For each stage whose design depends on earlier output: the quantity it needs, the test that produces it,
and the decision each possible result triggers. Each stage revision gets its own `-interim-N` tag BEFORE
the run it governs.

## 10. Open decisions
Every choice the specification leaves to the implementer, listed here and decided BEFORE the run. Deciding
after seeing output is a deviation.

## 11. Timestamp / archive
The archive route, decided with ARCHIVING.md §1: e.g. "OSF Registration, embargoed until <date>" or
"Zenodo, from the GitHub release of <EID>-prereg". The identifier is recorded in EXPERIMENTS.md once
issued. Or "none: local git history only".
```

### 3.4 What makes it adaptive

Modelling is iterative, and a protocol that forbids iteration gets ignored. This one follows the adaptive
preregistration approach [4]: the plan can be revised in stages, as long as each revision is recorded before
the run it governs, and decision rules set in advance (§3 section 9) say how stage results change the design.

It differs from [4] on purpose in one way. There, deviations are recorded by editing the preregistration
under a new version. Here `PREREG.md` is frozen at `-prereg`, and every change goes in `DEVIATIONS.md`, so the
original plan stays readable as written and the commit guard can enforce the freeze.

- A plan change made before the run it affects is committed, tagged `<EID>-interim-N`, and logged with
  `outcome_known = no`.
- A plan change made after seeing that run's output is still allowed, but it is logged with
  `outcome_known = yes` and can't be used to turn a fail into a pass.

### 3.5 Pilot runs

Code has to be run to be debugged. Before `-prereg`, runs are allowed only with seeds outside the
preregistered seed list, or on synthetic inputs, and their outputs go under `exploratory/pilot/`. Pilot
results are never cited. If a pilot revealed anything that shaped the plan, say what in §8.

---

## 4. ENV.lock

- Python: `uv.lock` or `conda-lock.yml` with hashes. R: `renv.lock`. A Nix or Guix manifest is better where
  available, because it captures the full build graph, not just top-level packages [5].
- Record the lockfile's `sha256` in `PREREG.md` §7.
- Avoid unnecessary dependencies, but full capture beats a short list: a bare interpreter already pulls in
  hundreds of transitive binaries.
- Compiled backends (Brian2 cpp_standalone, Cython) and the BLAS variant are dependencies. Name them.

---

## 5. DEVIATIONS.md — required schema

Two tables, adapted from [2]. An empty table says "None" explicitly.

**Deviations:** one row per departure from `PREREG.md`.

```markdown
| # | Date | Stage/section | Type | Original text | Change | Reason | Outcome known? | Effect on interpretation | Commit |
|---|------|---------------|------|---------------|--------|--------|----------------|--------------------------|--------|
```

`Type` ∈ {design, model, parameter, analysis, environment, exclusion, criterion}.
`Outcome known?` ∈ {no, partial, yes}. A `yes` on a `criterion` row means the experiment can't be reported as a
preregistered pass. Judge whether a deviation was justified with [11]'s questions: was the plan wrong, or did
the result make a different plan attractive?

**Unregistered steps:** analysis or processing that the plan didn't mention at all.

```markdown
| # | Date | Step | Why it was needed | Outcome known? | Effect on interpretation | Commit |
|---|------|------|-------------------|----------------|--------------------------|--------|
```

---

## 6. RESULTS.md — required sections

```markdown
# <EID> — Results
Run tag: <EID>-run   Model tag: ...   ENV.lock sha256: ...   Runs: N, failed: M
Attempt: <n> on this question (EXPERIMENTS.md); earlier attempts and their verdicts: ...

## 1. Criteria table
| Criterion | Preregistered threshold | Estimate | Uncertainty | Pass/Fail |
Verbatim thresholds from PREREG.md §3. No new criteria here.

## 2. Verdict
PASS / FAIL / UNINTERPRETABLE (as PREREG.md §3 defines it), one sentence each on why.

## 3. Patterns the model FAILED to reproduce
Every qualitative or quantitative target it missed, including ones outside the preregistered criteria.
(ODD recommends this [6]; here it is required.)

## 4. Sensitivity
The preregistered sensitivity analysis (PREREG.md §6): did the verdict hold across every range?

## 5. Controls
Each control's result. A stage without its control is not reported as a result.

## 6. Exploratory (clearly labelled)
Anything from exploratory/. Never mixed into §1.

## 7. What only worked because it was tuned
Explicit list. "None" must be stated, not implied.

## 8. Next EID
If FAIL or UNINTERPRETABLE: the new experiment ID and what its preregistration will change. This experiment
stays closed.
```

---

## 7. Rules for whoever runs the experiment

These apply equally to a person, a script and a coding assistant.

- **Before any `run.py` execution**, print the `-prereg` tag's hash and confirm `PREREG.md` has all eleven
  sections. If it doesn't, write it and stop for a human to review; don't run.
- **Never** edit `PREREG.md` after `-prereg`. Plan changes go in `DEVIATIONS.md` and, if made before the run,
  get an `-interim-N` tag.
- **Never** delete, rewrite or "clean up" a closed experiment folder, or remove a row from `EXPERIMENTS.md`.
- **Never** move a post-hoc analysis out of `exploratory/`.
- When asked to "make it pass", "fix the threshold", or "try a few values and keep the best": do the runs
  under `exploratory/`, report them as exploratory, and say plainly that they are not preregistered evidence.
- In every report, state how deeply each cited source was read: [FT] full text, [AB] abstract,
  [BG] background knowledge, [USER] user-supplied.
- State every open decision (PREREG §10) *before* the run that depends on it, in the conversation and in the
  file.
- If a human asks you to skip any of this, comply only after writing the skip itself into `DEVIATIONS.md`,
  with `outcome_known` filled in honestly.

---

## 8. Minimal commands

```bash
# new experiment: add its row to EXPERIMENTS.md, then
mkdir -p experiments/E05-name/{exploratory/pilot,outputs}
# ... write PREREG.md, config.yaml, ENV.lock ...
git add EXPERIMENTS.md experiments/E05-name && git commit -m "E05: preregistration"
.agents/tools/tag E05-name-prereg "preregistered"      # or: git tag -a E05-name-prereg -m "$(date +%F) preregistered"

# adaptive revision before a dependent run
git commit -am "E05: interim plan 1 (see DEVIATIONS.md #1)"
.agents/tools/tag E05-name-interim-1 "interim plan 1"

# after the run
git add experiments/E05-name/outputs experiments/E05-name/RESULTS.md EXPERIMENTS.md
git commit -m "E05: run + results"
.agents/tools/tag E05-name-run "run"
.agents/tools/tag E05-name-closed "verdict: FAIL"

# model change
git tag -a model-v0.4.0 -m "$(date +%F) invalidates: E03 (see CHANGELOG.md)"
```

---

## 9. What this protocol does not give you

- **Credibility to outsiders** without an archived timestamp (§2) or an independent review of the plan. For
  external review before results exist, use a Registered Report [9].
- **Protection against a wrong model.** It protects the *record*, not the idea.
- **Prevention of repeated attempts.** Nothing stops a new EID after a fail. `EXPERIMENTS.md` only makes the
  attempts visible, so a reader can weigh a pass against them [8].
- **Enforcement.** Only the optional commit guard and hooks enforce anything, and both can be bypassed. The
  rest relies on the record making a violation visible afterwards.
- **An exemption for "quick checks".** A quick check that ends up in a report was a run.

---

## References

Read depth, as §7 requires: [AB] abstract plus the authors' own guides or secondary summaries; none has
been read in full text for this protocol yet. Where a source is used for more than its title states, the
use is ours.

1. Vanpaemel, W. (2019). The really risky registered modeling report: Incentivizing strong tests and HONEST
   modeling in cognitive science. *Computational Brain & Behavior*, 2, 218–222.
   https://doi.org/10.1007/s42113-019-00056-9 [AB]. The "risky prediction first" principle.
2. Willroth, E. C., & Atherton, O. E. (2024). Best laid plans: A guide to reporting preregistration deviations.
   *Advances in Methods and Practices in Psychological Science*, 7(1).
   https://doi.org/10.1177/25152459231213802 [AB]. §5 tables.
3. Siepe, B. S., et al. (2024). Simulation studies for methodological research in psychology: A standardized
   template for planning, preregistration, and reporting. *Psychological Methods*.
   https://doi.org/10.1037/met0000695 [AB]. Estimands, performance measures and Monte Carlo error in §3 and
   §6 are borrowed from its ADEMP structure, which is written for simulations that evaluate statistical
   methods; this protocol applies the parts that carry over to mechanistic models.
4. Gould, E., et al. (2026). 'But I can't preregister my research': Improving the reproducibility and
   transparency of ecology and conservation with adaptive preregistration for model-based research.
   *Methods in Ecology and Evolution*, 17(6), 1768–1787. https://doi.org/10.1111/2041-210x.70311 [AB].
   Interim preregistrations and preplanned decision rules (§3.4, §3 section 9).
5. Vallet, N., Michonneau, D., & Tournier, S. (2022). Toward practical transparent verifiable and long-term
   reproducible research using Guix. *Scientific Data*, 9, 597. https://doi.org/10.1038/s41597-022-01720-9 [AB].
   Full-environment capture (§4).
6. Grimm, V., et al. (2020). The ODD protocol for describing agent-based and other simulation models: A second
   update to improve clarity, replication, and structural realism. *JASSS*, 23(2), 7.
   https://doi.org/10.18564/jasss.4259 [AB]. Reporting patterns a model fails to reproduce (§6).
7. Morris, T. P., White, I. R., & Crowther, M. J. (2019). Using simulation studies to evaluate statistical
   methods. *Statistics in Medicine*, 38(11), 2074–2102. https://doi.org/10.1002/sim.8086 [AB]. Monte Carlo
   standard error and the number of repetitions (§3, §6).
8. Scheel, A. M., Schijen, M. R. M. J., & Lakens, D. (2021). An excess of positive results: Comparing the
   standard psychology literature with registered reports. *Advances in Methods and Practices in
   Psychological Science*, 4(2). https://doi.org/10.1177/25152459211007467 [AB]. Why failed attempts must stay
   visible (§1 `EXPERIMENTS.md`).
9. Chambers, C. D., & Tzavella, L. (2021). The past, present and future of Registered Reports. *Nature Human
   Behaviour*, 6, 29–42. https://doi.org/10.1038/s41562-021-01193-7 [AB].
10. Saltelli, A., et al. (2019). Why so many published sensitivity analyses are false: A systematic review of
    sensitivity analysis practices. *Environmental Modelling & Software*, 114, 29–39.
    https://doi.org/10.1016/j.envsoft.2019.01.012 [AB]. Preregistered, global sensitivity analysis (§3 section 6).
11. Lakens, D. (2024). When and how to deviate from a preregistration. *Collabra: Psychology*, 10(1).
    https://doi.org/10.1525/collabra.117094 [AB]. Judging deviations (§5).

Further reading: Grimm et al. (2014), TRACE model documentation, https://doi.org/10.1016/j.ecolmodel.2014.01.018;
Weston et al. (2019), preregistering analyses of existing data, https://doi.org/10.1177/2515245919848684;
Crüwell & Evans (2021), preregistering cognitive models, https://doi.org/10.1098/rsos.210155;
Steegen et al. (2016), multiverse analysis, https://doi.org/10.1177/1745691616658637;
Lakens (2022), sample size justification, https://doi.org/10.1525/collabra.33267.
