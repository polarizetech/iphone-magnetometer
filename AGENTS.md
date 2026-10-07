<!-- kit_ap:start -->
<!-- Managed by KIT Adaptive Preregistration (https://github.com/polarizetech/adaptive-preregistration.git). Don't edit between these markers: change the kit, then run `.agents/bin/kit_ap update`. -->

# Agent protocols

This repo uses **KIT Adaptive Preregistration**: agent protocols that are maintained in one central repo and vendored into `.agents/`. Every agent follows them, whatever the tool (Claude Code, Codex, Copilot, Cursor, Gemini, ChatGPT…).

- The rules in this block and the documents in `.agents/protocols/` are binding. If a task conflicts with one, stop and say so before doing the task.
- Project-specific instructions (outside these markers, or in nested `AGENTS.md` files) may add to the protocols. If one contradicts a protocol, ask the user which wins.
- Don't edit files in `.agents/` or text between the `kit_ap` markers. Updates overwrite them. To change a protocol, propose the change to the user as an edit to the kit repo.
- If a session-start message says the protocols are out of date, tell the user once. Don't update without their go-ahead. If your tool has no hooks, run `.agents/bin/kit_ap check` once at the start of a session.

## Preregistration

Read and obey `.agents/protocols/PREREG_PROTOCOL.md` before running, modifying, or reporting any experiment, and `.agents/protocols/SCOPE_PROTOCOL.md` before building anything in a unit (an app, sim, tool, calculator, …; a folder with `preregistrations/`, or the repository itself).

- **A claim, or an exploratory label.** A unit starts with a falsifiable claim in the user's own words and what would count against it, recorded in its `SCOPE.toml`: one question, and the rest of the claim is stated when its first experiment is preregistered. If the user says a unit is exploratory, don't ask for a claim: record what is being built (`stage = "exploratory"`), label the unit exploratory, and build. Nothing an exploratory unit shows is a finding, and it gets its claim before its first experiment.
- Propose; never substitute. The user's claim, design and decisions are recorded as they give them.
- Infrastructure is yours to decide, following the organisation's conventions. Anything that implements a research concept, or presents a result in a way that changes what someone would conclude, is science: once the unit has a claim, build it only after it has an evidence basis and the user's recorded decision. A gap blocks that feature only.
- Ask one decision at a time. If you disagree, say so once, with evidence; then record and follow the user's choice.
- Never count a source you couldn't verify. `.agents/tools/scope-status` shows unscoped units and what is open.

## Experiment branches and PRs

Read and obey `.agents/protocols/EXPERIMENT_PR_LOG.md`. Use one branch (`experiment/<EID>`) and one draft PR per experiment. Tag with `.agents/tools/tag`, never bare `git tag`.

<!-- kit_ap:end -->
