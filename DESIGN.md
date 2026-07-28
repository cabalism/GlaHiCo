# GaHiCo — LLM code review for GHC merge requests

The name is "sashiko" with GHC's consonants substituted in — a nod to the
Linux kernel review service this borrows its shape from.

Status: design draft, pre-implementation. Decisions below come from the
requirements interview on 2026-07-28; open questions are collected at the end.

## 1. Purpose

A spare-time, opt-in service: someone pings `@sjakobi llm-review please` on a
GHC merge request, and a machine-generated review appears as a link in that MR.

GaHiCo is the tool that turns the ping into the link. It is a local CLI run by
a human, not a bot.

### Constraints from the ghc-devs announcement

These are promises already made in public and are binding on the design:

- Reviews are **tool output**, not a personal review, and are labelled as such.
- Output is posted **verbatim**, with **no curation or editing** of model output.
- Every review discloses **model, effort level, and the exact prompt** used.
- **Only public code and context** is sent to the LLM provider.
- There is a **killswitch** if signal-to-noise degrades.

"No curation" is a constraint on the *human*, not the pipeline: a verification
stage that drops its own low-confidence findings is part of the disclosed
prompt and is therefore fine. What is forbidden is Simon reading the output and
deleting the embarrassing parts before posting.

### Non-goals (initially)

- No unattended operation: no webhook, no polling, no auto-posting.
- No building or running GHC by the agent.
- No proprietary or private context of any kind.
- Not a general-purpose forge bot; GHC's GitLab only.

## 2. Human workflow

1. Simon sees a ping on `!14892`.
2. `gahico review 14892` (optionally `--tasks correctness,docs`,
   `--harness codex`, `--prompt-file ./adhoc.md`).
3. The tool fetches the MR, prepares a worktree, runs the pipeline(s), writes
   an artifact bundle, and creates a snippet.
4. It prints the snippet URL and a ready-to-paste MR comment.
5. Simon pastes the comment into the MR himself.

Step 5 stays manual by choice: it keeps a human deciding that *this* review
gets published at all, which is the cheapest possible killswitch.

## 3. CLI surface

```
gahico review <MR>                 # MR id: 14892 or !14892 or full URL
    --tasks correctness[,docs,...] # pipelines to run; default: correctness
    --harness claude|codex         # default from config
    --model / --effort             # harness-specific, recorded in disclosure
    --prompt-file PATH             # extra instructions appended to each task
    --prompt TEXT                  # same, inline
    --rev SHA                      # review a specific head; default: MR head
    --no-publish                   # produce the bundle, skip the snippet
    --dry-run                      # assemble context and print it, run nothing

gahico show <MR>                   # path + summary of the last run
gahico open <MR>                   # open the bundle dir
gahico publish <RUN>               # publish an existing bundle (retry path)
gahico feedback <RUN>              # open the feedback YAML for annotation
gahico prompts                     # list pipelines and prompt versions
```

A run is identified by `<mr>/<utc-timestamp>`; `<MR>` alone means "latest run".

## 4. Architecture

```
gahico/
  cli.py            argument parsing, top-level command flow
  config.py         ~/.config/gahico/config.toml + defaults
  gitlab.py         MR/issue/note fetch, snippet creation (python-gitlab)
  repo.py           clone maintenance, MR ref fetch, worktree pool
  context.py        assembles the context pack for a run
  pipeline.py       loads pipeline YAML, runs stages, threads findings
  harness/
    base.py         Harness protocol: run(prompt, cwd, model, effort) -> Result
    claude.py       `claude -p` adapter
    codex.py        `codex exec` adapter
  findings.py       Finding dataclass, JSON schema, merge/dedup helpers
  report.py         findings -> review.md, disclosure header, comment template
  bundle.py         artifact bundle layout, writing, indexing
  feedback.py       feedback YAML scaffold and rollup stats
prompts/
  correctness.yaml  pipeline definition (stages, models, prompt files)
  docs.yaml
  stages/*.md       prompt bodies, versioned in git
```

The layering that matters: **context assembly, pipeline execution, and
publication are independent.** Any of them can be run alone, which is what
makes `--dry-run`, `--no-publish`, and `publish <RUN>` cheap to support and
makes the whole thing testable without an API key.

## 5. Context pack

Assembled once per run, shared by all tasks and all stages, and archived in the
bundle verbatim. Everything in it is public.

- **MR metadata**: iid, title, description, author, source/target branch, head
  SHA, target-branch merge-base SHA, labels.
- **MR discussion**: existing notes (excluding system notes), so the review can
  avoid restating what humans already said.
- **Linked issues**: issues referenced as `#NNNNN` in the MR description or
  commit messages — title, description, and comments. Depth 1, no transitive
  chasing, capped in count and size.
- **Commits**: `git log --format=fuller` for `merge-base..head`, full messages.
- **Diff**: `git diff <merge-base>..<head>`, plus `--stat`.
- **Worktree**: the MR head checked out, for free exploration.

Size caps: individual items are truncated with an explicit
`[truncated N bytes]` marker rather than silently cut, and truncation is noted
in the disclosure header.

### Agent capabilities

Read-only. The agent may read files, grep, and inspect git history in the
worktree. It may **not** build, run tests, write files in the worktree, or
access the network. Enforced per harness by tool allowlists, not by trust.

The performance task (later; see §11) is the one that needs more: it wants
`.dump-simpl` output for the MR head and for its merge-base to diff against.
That means a build tree, which means a build step outside the agent's control —
deliberately deferred until the correctness task is working.

## 6. Repository and worktree management

GaHiCo owns its own clone; it never touches `~/ghc/work` or `~/ghc/work-trees`.

```
~/gahico/ghc.git          bare mirror of ghc/ghc (origin = gitlab.haskell.org)
~/gahico/wt/<iid>/        worktree per MR, reused across runs of the same MR
```

MR heads are fetched via GitLab's merge-request refs:

```
git fetch origin +refs/merge-requests/<iid>/head:refs/gahico/mr/<iid>
```

so fork remotes never need to be configured, and MRs from any fork work
uniformly.

Submodules are initialised (`--recurse-submodules`), because a review of a
`libraries/` change is worthless without the submodule contents. This is a
one-time cost per clone, amortised across all runs; worktrees share the
mirror's object store. Worktrees older than N days are pruned.

## 7. Pipelines

A task is a named pipeline defined declaratively in YAML, so growing the stage
set is data, not code. The initial `correctness` pipeline is lean:

| Stage | Name | Input | Output |
|---|---|---|---|
| 1 | intent | context pack | prose: what the change intends, what it claims |
| 2 | hunt | context pack + stage 1 | candidate findings (JSON) |
| 3 | verify | context pack + candidates | surviving findings with confidence + severity (JSON) |
| 4 | report | verified findings | review markdown |

Stage 2 is where the GHC-specific prompt content lives: totality and partial
patterns, laziness/strictness and space leaks, `panic`/`assert` discipline,
Core and type-environment invariants, Note accuracy, and whether the code
actually does what the commit message says. Splitting these into separate
stages (sashiko-style) is a later, config-only change.

Each stage is a **separate harness invocation** with a fresh session. Prior
stage outputs are passed as files in a run-local `context/` directory and
referenced from the prompt. This keeps stages portable across harnesses that
have very different session models, and makes each stage independently
replayable from the bundle. Session continuation is a possible later
optimisation, not a design assumption.

### Findings as a typed interchange

Stages 2 and 3 exchange JSON, not prose:

```json
{ "id": "f3", "title": "...", "file": "compiler/GHC/Core/Opt/Simplify.hs",
  "line": 412, "severity": "high", "confidence": "medium",
  "claim": "...", "evidence": "...", "suggested_fix": "..." }
```

This buys three things: mechanical dedup, stable ids that feedback annotations
can refer to, and a machine-readable corpus for measuring signal-to-noise.
Malformed JSON from a stage is a hard error with the raw output preserved — no
silent recovery.

### Multiple tasks, one review

`--tasks correctness,docs` runs each pipeline independently and merges the
reports into **one** `review.md` with a section per task, published as **one**
snippet. One link to post per ping.

## 8. Output and publication

`review.md` structure:

```markdown
# LLM review of !14892 — <MR title>

<disclaimer: machine-generated, not a human review, see ghc-devs announcement>

## Disclosure
| field | value |
harness / model / effort / pipeline + prompt version (git SHA) / commit
reviewed / merge-base / context truncations / wall time / token usage & cost

## Findings — correctness
### [high, medium confidence] Title
...

## Findings — docs
...

## Appendix: exact prompts
<every stage prompt, verbatim>
```

The exact-prompts appendix is what discharges the disclosure promise on the
artifact itself rather than in a comment somewhere.

**Publication target**: a snippet in a dedicated `gahico` project on
gitlab.haskell.org. Snippets support comments, so discussion of the *review*
happens on the review, not in the MR thread where it would drown the discussion
of the *code*. The dedicated project also hosts the public review corpus (§9),
keeping everything GaHiCo-related in one place under Simon's control and off
third-party infrastructure.

The MR comment (printed for manual pasting) is short and states what the thing
is, who to blame, and where to complain:

```
[LLM review] Machine-generated review of <sha>: <snippet-url>
Produced by GaHiCo with <model> (<effort>), prompt <pipeline>@<version>.
This is tool output, not a review by me; I have not curated it.
Comments on the review itself are best left on the snippet.
```

## 9. Artifact bundle

Per run, under `~/gahico/runs/<iid>/<timestamp>/`:

```
run.json          MR iid, SHAs, harness, model, effort, pipeline versions,
                  timings, token usage, cost, tool version, exit status
context/          the full context pack as sent
stages/NN-<name>/ prompt.txt, raw stdout, parsed output, stderr, timing
findings.json     final verified findings
review.md         published artifact
snippet.json      snippet id + URL, once published
feedback.yaml     created empty, annotated later
```

Bundles are pushed to a public git repo in the `gahico` project, so quality
over time is auditable by anyone, not just by Simon. Anything sent to the model
was public by construction, so publishing the bundle leaks nothing new.

## 10. Feedback tracking

`feedback.yaml` maps finding ids to an outcome:

```yaml
f1: {verdict: true-positive, note: "fixed in v2"}
f2: {verdict: false-positive, note: "misread the strictness annotation"}
f3: {verdict: grey, note: "style, not a bug"}
```

Annotated after the fact, from the MR discussion or the author's reply.
`gahico stats` rolls these up per model, per pipeline version, and over time.
This is what makes the killswitch promise a data-driven decision rather than a
vibe, and it is the only way to tell whether a prompt change helped.

## 11. Roadmap after v1

- `docs` pipeline (Haddock accuracy, Note correctness — the `check-comments`
  angle).
- `perf` pipeline: build MR head and merge-base, diff `.dump-simpl`, feed to
  the agent. Needs a build orchestration step outside the agent.
- Finer-grained correctness stages, as pipeline config.
- Regression corpus: run against GHC commits that were later fixed by a
  follow-up MR, and measure hit rate — sashiko's methodology, GHC's data.
- Additional harnesses.
- Only after signal-to-noise is demonstrably good: consider automating the
  trigger (polling GitLab todos) and the posting.

## 12. Configuration and secrets

`~/.config/gahico/config.toml`: gitlab url, project paths, clone/worktree/run
directories, default harness/model/effort, size caps, pruning policy.
The GitLab PAT (scope `api`, for reading MRs and creating snippets) comes from
the environment or a pass-style command, never from the config file.

## 13. Open questions

1. **Thread outcome.** The mailing list archive rendered only the original
   post, so the 15 replies (Klebinger, Shao, Angermann, Graf, Peyton Jones,
   Ellis, Duggal) are not reflected here. Any concessions or constraints agreed
   there need folding into §1 before implementation.
2. **Cost per review.** A 4-stage pipeline over a large MR with free
   exploration is not cheap. Worth a budget cap per run, and a printed cost
   before publication?
3. **Multiple harnesses per review.** Running claude *and* codex on the same MR
   and reporting both would be a strong signal-to-noise filter (agreement
   between independent models). Worth it, or too expensive for v1?
4. **Re-reviews.** When an MR is updated and re-pinged, should the review be
   incremental (diff since the last reviewed SHA) or always full? Full is
   simpler and more honest; incremental is much cheaper on long-lived MRs.
5. **Public bundle repo and rate of growth.** Raw harness output per run is
   large. Cap it, or accept a fat repo?
