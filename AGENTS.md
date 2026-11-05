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

<!-- scaffold:start -->
# iphone-magnetometer

**Kind:** tool (`TOOL.toml`). Records an iPhone's raw magnetometer, motion and timing as an always-on stream (FieldLab), keeps it in a server-side store, and reads it back

- **No research here, except comparisons with other tools.** No questions, findings or `RESEARCH.md`, and no
  root `experiments/` or `preregistrations/`. A measurement made with this tool belongs to the study that made
  it. The exception is comparison units: `sims/<slug>/` and `datasets/<slug>/` that compare this tool's
  functionality against other tools, preregistering predictions based on inputs and checking whether the run is
  correct, as an extension of the test suite (`.agents/protocols/TOOL_VERSIONING.md` §1a). Each names what it
  `compares` in its `SCOPE.toml`, is listed under `[[comparisons]]` in `TOOL.toml`, keeps its preregistrations
  and results inside it, and predicts tool outputs, never the world.
- **Bench sims.** A sim in `sims/<slug>/` whose `SCOPE.toml` says `kind = "bench"` checks this tool against
  reference implementations in other repos, as part of its tests (`.agents/protocols/TOOL_VERSIONING.md` §1b;
  `scaffold new sim <name> --inside . --reference ...`). Each reference is declared under `[[references]]` with
  a tag (never a branch) and the tag's commit, and pinned at that tag in the sim's own `pyproject.toml`; GPL
  code runs as a separate process, never imported. Its `tolerances.toml` is its preregistration: the person
  decides it before anything is scored (propose bounds, never set them), and not meeting it is a failure. Not
  run automatically: run `make sims` when tagging a new version and commit each `results/<version>.json`.
- **Size the goal first.** A new study or tool starts exploratory, from the person's goal and a rough idea of
  how to get there (`--goal`, `--approach`), not from a claim. Before building anything, talk it through with
  the person, back and forth: is the goal one tool's worth, or should it be broken up? Propose a split when
  it is too big, in plain words, and let the person decide. Record the decision as `scope = "one"` or
  `scope = "split: a, b"` with `scope_decided` (YYYY-MM-DD) under `[exploration]` in `SCOPE.toml`; `scaffold check` warns until it is there.
  After a split, each piece starts the same way. A claim comes later, when the person wants one.
- **Scope before science, once there is a claim.** The claim, then the features, then an evidence basis and the person's recorded
  decision for every scientific feature, in `SCOPE.toml` (`.agents/protocols/SCOPE_PROTOCOL.md`). Infrastructure
  is yours to decide; nothing scientific is built before it is scoped. An override's experiment is
  preregistered in the research corpus, not here. A tool starts exploratory and skips this until it gets its
  claim (`stage = "exploratory"` in `SCOPE.toml`); nothing it shows is a finding.
- **Releases** follow `.agents/protocols/TOOL_VERSIONING.md`; run `python3 .agents/tools/release-check` before
  tagging.
- **One version.** `version` in `TOOL.toml`, `pyproject.toml` and `CITATION.cff`, and a `CHANGELOG.md`
  heading, all agree; `scaffold check` fails when they drift. Releases are tagged `vX.Y.Z`.
- **Consumers.** Each repo that depends on this tool is listed in `TOOL.toml` with what it `uses`. A change
  to any of those is a change for that consumer even when every test here passes: name it under
  `### Outputs changed` in `CHANGELOG.md`.
- **No absolute home-directory paths.**
- **Visual work uses the design system.** Anything visual or user-facing built here (a web UI, a dashboard, a
  chart, a figure or report page, slides) uses [polarize-ui](https://github.com/polarizetech/polarize-ui/tree/v0.6.7), pinned to `v0.6.7`. Its own
  [instructions](https://github.com/polarizetech/polarize-ui/blob/v0.6.7/README.md) are the source of truth: read them before building, follow them over any
  summary here, and link to them rather than copying them into this repo. A build-based app depends on `@polarizetech/polarize-ui` from `github:polarizetech/polarize-ui#v0.6.7`. A zero-build page links its stylesheet, `design.css`, from a checkout of `polarizetech/polarize-ui` at `v0.6.7` (a submodule, or the sibling checkout an app's `serve.py` serves).
  - **Design first, with the designer.** A new page, or a change to how one looks, is designed before it is built: hand it to the `designer` agent, which designs it as a design made from the Design artifact type with the polarize-ui design system ([its artifact](https://claude.ai/artifact/9gWHMLHB5exoNc67MGayjG)), using only its components and tokens, then hands the design to `frontend-developer` to build. Don't improvise a page's look while building it.
  - **No documentation on a page.** A page shows the tool: its controls, its data, and the labels the design
    system requires (how sure a number is, units, n, scope). Instructions, explanations, version notes and
    "about this" text go in the README, not on the page, unless the person asks for them there.
  - Colours, type, spacing and radii come from its tokens, never literals. Don't edit its generated files; a
    change to the look is made upstream, in its token source, and arrives here with a new tag.
  - In anything that could be pushed to a public repo, use only standard visualisation techniques, and demo
    data that is public (licensed, with attribution) or synthetic. When unsure, ask the person before pushing.
  - An app made with `scaffold new app` comes wired to it: its README § Design says what the page links and
    how `serve.py` serves the pinned files. Keep that wiring when you rewrite a page; a yellow banner across
    the page means the design system isn't being served, and says how to fix it.
  - `scaffold check` warns when a page here doesn't load the design system (or its `<body>` class), when it
    is pinned to a branch, or when a page hand-writes a hex colour outside the files listed under
    `[design] allow_hex` in the manifest. The theme pages pin (`data-theme`) is recorded there as `theme`.
    The other points above are advice, not checks.
  - From its instructions (files are in `polarizetech/polarize-ui` at `v0.6.7`):
    - A zero-build page links `design.css` and `design.js` and puts the `ui` class on `<body>`; a build-based app uses the shadcn bridge and the React components (`README.md` § Using it, `shadcn/SHADCN.md`). Never load `design.css` and the shadcn `theme.css` in the same document: both define `--accent`, and the loser is silent.
    - `design.css` is generated from `tokens.json`: never edit `design.css`; change the token upstream, in `tokens.json`.
    - The label rule (`CLAUDE.md` § The rule): a tier badge (MEASURED, PREDICTED, MODELLED, EXPLORATORY, SPEC, TASTE, REFUTED) is never hidden or shortened, and its explanation goes in `<ui-note>`. Measured values are upright (`.ui-measured`), predicted values italic (`.ui-predicted`). Every invented value carries ADDED or TASTE.
    - Choose and judge a view of scientific data by `METHOD.md`: write the question it answers first, and label n, units, scope and thresholds on the figure itself.
- **Every question starts with the retrieval tool.** Each question or task the person sends is answered with `research-rag` ([polarizetech/retrieval-augmented-generation](https://github.com/polarizetech/retrieval-augmented-generation)), the MCP server of that name in the session, whatever assistant you are: retrieve passages for it first (`rag__retrieve_evidence`; for a literature question, its pipeline, `pipeline__research_start`), and ground what you say in the passages it returns, not in memory or a general web search. A question about this repo's own code or files is no exception: retrieve, then read the checkout, which is the source of truth for its own files, and say when no passage applies. A reply that only approves or answers something you asked continues the earlier request. If its tools aren't available in the session, say so before answering any other way. The person can tell you not to use it, for one question or a whole session.
- **The retrieval tool picks the specialist.** Before bringing in a research role or specialist, call `pipeline__profile_route` on `research-rag` with the question, and use only the research roles and the specialist it returns, following its `guidance`. When it names no specialist, answer without one. A specialist's brief is `.claude/agents/<name>.md` when it is installed here, and otherwise the file at the path the route gives. Building roles (designer, developers, engineers) are still chosen by the kind of task, and the person can always name a role themselves.


## Agents and coordination

Maintained by scientific-research-scaffold from scientific-research-agents (`scaffold update` keeps this section current; edits here are
replaced). The full rules are the [coordination protocol](https://github.com/polarizetech/scientific-research-agents/blob/v0.10.0/COORDINATION.md).

## Retrieval first, for every question

Every question or task handled by the lead or any specialist agent, in any assistant (Claude, Codex or
another), starts with the configured Scientific Research RAG MCP backed by
[`polarizetech/retrieval-augmented-generation`](https://github.com/polarizetech/retrieval-augmented-generation)
before answering and before any literature, web, corpus, or other search. It may be exposed as
`scientific_research_rag` or `research-rag`. Ground answers in its retrieved passages. A reply that only
approves or answers the agent's own question continues the earlier request.

Skip it only when the service is unavailable or the user explicitly opts out for the request or session.
When it is unavailable, say so before falling back. A question about the current repository is no exception:
retrieve first, then inspect the checkout directly because local files are the source of truth, and say when
no passage applies. Never index private or user-supplied material into a shared corpus without authorization.

**The tool picks the specialist.** Before bringing in a research role or specialist, call the tool's
`pipeline__profile_route` with the question, and use only the research roles and the specialist it
returns, following its guidance. When it names no specialist, the lead answers without one. Building roles
are chosen by the kind of task, and the user can always name a role.

## Specialist roles

This repo has specialist roles, each briefed in a file under `.claude/agents/`. Claude Code delegates to
them as subagents. **Other assistants (ChatGPT, Codex and the rest): before a task of one of these kinds,
read that file and follow it as your brief.** When the environment supports and the user has authorized
subagents, the lead may delegate; otherwise apply the relevant brief in the current session.

| role | takes | brief |
|---|---|---|
| `scout` | finding and summarising; read-only | `.claude/agents/scout.md` |
| `computational-engineer` | simulators, models, numerical code, pipelines | `.claude/agents/computational-engineer.md` |
| `mathematician` | equations, constants, units and valid ranges; specifies calculators | `.claude/agents/mathematician.md` |
| `designer` | layout and visual design on the design system | `.claude/agents/designer.md` |
| `frontend-developer` | interfaces built from the designer's mockups | `.claude/agents/frontend-developer.md` |
| `researcher` | literature, evidence and evidence tiers | `.claude/agents/researcher.md` |
| `analyst` | data analysis and statistics | `.claude/agents/analyst.md` |
| `science-writer` | papers and blog posts | `.claude/agents/science-writer.md` |

- **Hand back briefly.** Each piece of work ends with a handoff of at most 150 words: Done, Files, Open,
  Next. Pass handoffs between roles, not transcripts.
- **The science gate.** A scientific feature goes researcher, then the person's decision, then engineer.
  Nothing skips the person's decision.
- **Parallel only when independent**: different files, at most three at a time, each in its own worktree.
- **Start cheap, escalate on a signal**: two failed attempts, a design decision across many files, or
  subtle scientific or statistical judgment. Escalate the task, not the session.
- **Codex:** use `gpt-5.6-sol`. Use low reasoning effort for finding and summarising, medium by default, and a higher effort supported by the selected model when escalating.
- **Scaffold version.** At the start of a session, run `scaffold version .` (or `../scientific-research-scaffold/bin/scaffold version .`). If it reports a newer release, tell the person and offer to upgrade, following the steps it prints (Claude Code runs this by itself).
<!-- scaffold:end -->
