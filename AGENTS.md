<!-- kit_ap:start -->
<!-- Managed by KIT Adaptive Preregistration (https://github.com/polarizetech/adaptive-preregistration.git). Don't edit between these markers: change the kit, then run `.agents/bin/kit_ap update`. -->

# Agent protocols

This repo uses **KIT Adaptive Preregistration**: agent protocols that are maintained in one central repo and vendored into `.agents/`. Every agent follows them, whatever the tool (Claude Code, Codex, Copilot, Cursor, Gemini, ChatGPT…).

- The rules in this block and the documents in `.agents/protocols/` are binding. If a task conflicts with one, stop and say so before doing the task.
- Project-specific instructions (outside these markers, or in nested `AGENTS.md` files) may add to the protocols. If one contradicts a protocol, ask the user which wins.
- Don't edit files in `.agents/` or text between the `kit_ap` markers. Updates overwrite them. To change a protocol, propose the change to the user as an edit to the kit repo.
- If a session-start message says the protocols are out of date, tell the user once. Don't update without their go-ahead. If your tool has no hooks, run `.agents/bin/kit_ap check` once at the start of a session.

## Preregistration

Read and obey `.agents/protocols/PREREG_PROTOCOL.md` before running, modifying, or reporting any experiment.

## Experiment branches and PRs

Read and obey `.agents/protocols/EXPERIMENT_PR_LOG.md`. Use one branch (`experiment/<EID>`) and one draft PR per experiment. Tag with `.agents/tools/tag`, never bare `git tag`.

<!-- kit_ap:end -->
