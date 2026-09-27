# EXPERIMENT_PR_LOG.md — Branch, PR and tag receipts per experiment

**Applies to:** everyone who runs experiments in this repo: people, scripts and coding assistants.
**Works with:** `PREREG_PROTOCOL.md` (experiment IDs, tags), if used. This document only defines *where* the
record goes and *what* gets posted; it does not define preregistration itself. It needs the GitHub CLI (`gh`).
**Installed by:** the KIT Adaptive Preregistration `experiment-pr-log` module, which also adds the one-line rule to `AGENTS.md`.
**License:** CC BY 4.0, from [KIT Adaptive Preregistration](https://github.com/polarizetech/adaptive-preregistration). Reuse it with credit.

---

## 1. Rules

Every experiment gets one branch and one draft PR, so its commits, tags and receipts sit together on one page
and in git beside the results.

| Rule | Detail |
|---|---|
| Branch per experiment | `experiment/<EID>` off `main`. Model changes go on `model/<topic>` branches, not experiment branches. |
| Draft PR at start | First action on the branch: `git commit --allow-empty -m "start <EID>"; git push -u origin HEAD; gh pr create --draft --title "<EID>: <title>" --body "Preregistered experiment. See experiments/<EID>/PREREG.md"`. Receipts need the PR to exist. |
| Prereg receipt on the PR | Tag `<EID>-prereg` with `.agents/tools/tag` (§2), which posts the receipt as a PR comment straight away. The comment's timestamp comes from GitHub, not the local machine, so it is evidence the tagged plan existed by then. It is not an archive (comments can be edited or deleted) and can't show that nothing ran before the plan. For an immutable timestamp, also archive the tag (`PREREG_PROTOCOL.md` §2). |
| Interim and run receipts | Same after each `-interim-N`, `-run`, `-closed` tag. The PR then shows the ordering prereg → interim → run → closed with server-side times. |
| Protect the tags | Turn on tag protection (a GitHub ruleset for `*-prereg`, `*-interim-*`, `*-run`, `*-closed`, `model-v*`) so pushed milestone tags can't be moved or deleted, and sign them (`git config tag.gpgSign true`). |
| PR stays open until closed | Merge only after `<EID>-closed`. A FAIL is still merged: the closed folder is the record. Squash-merging is forbidden (it destroys the tag→commit mapping); use merge commits. |

## 2. Tools (installed in `.agents/`)

| File | What it does |
|---|---|
| `.agents/tools/tag <tag> "<message>"` | `git tag -a` with a dated message (signed if `tag.gpgSign` is set), then posts the receipt. Use this, **never bare `git tag`**, for experiment tags. |
| `.agents/tools/prereg-receipt <tag>` | Posts a tag receipt to the branch's PR: commit, tag date, EID, and sha256 of `experiments/<EID>/PREREG.md` and `ENV.lock` as committed at the tag (so a receipt posted late still describes what was tagged). The EID is the tag minus its `-prereg`/`-interim-N`/`-run`/`-closed` suffix; other tags (e.g. `model-v*`) get `n/a`. The comment's time comes from GitHub, not this machine. |
| `.agents/tools/prereg-status` | Prints one line of context (branch, EID, milestone and interim tags present, whether `PREREG.md` is FROZEN). Claude Code runs it on every prompt via the `UserPromptSubmit` hook. |

## 3. Commit guard (`.agents/githooks/pre-commit`)

Enable once per clone with `git config core.hooksPath .agents/githooks`. This replaces `.git/hooks` for the repo, so move any existing hooks into the kit first.

It refuses to commit:
- run outputs (`experiments/<EID>/outputs/*`, `RESULTS.md`) for an experiment that has no `<EID>-prereg` tag;
- any change to `experiments/<EID>/PREREG.md` after `<EID>-prereg` exists. Log the change in `DEVIATIONS.md` instead.

Like any git hook it only runs where it's enabled, and `git commit --no-verify` skips it. It catches mistakes; the tags and receipts are what make a violation visible afterwards.

## 4. Hooks

The module merges a Claude Code `UserPromptSubmit` hook running `.agents/tools/prereg-status` into `.claude/settings.json`. Tools without hooks should run it at the start of a session on an `experiment/*` branch.

---

## 5. Using this without PREREG_PROTOCOL.md

Replace `<EID>` with any work-unit slug and drop the tag names you don't use. The branch→PR→log
mapping and `.agents/tools/tag` + receipt still work. The commit guard assumes `-prereg` tags (it blocks
run outputs without one), so leave it off if you don't preregister.
