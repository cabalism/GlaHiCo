# GaHiCo — LLM code review for GHC merge requests

The name is "sashiko" with GHC's consonants substituted in — a nod to the
Linux kernel review service this borrows its shape from.

Status: design draft, pre-implementation. Decisions below come from the
requirements interview on 2026-07-28 and the build-versus-fork decision the same
day (§1, `sashiko-ghc.md`); open questions are collected at the end.

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

### Relationship to sashiko

Decided 2026-07-28: GaHiCo is a separate tool that treats sashiko as a
**reference implementation**, not as a dependency, a fork, or an upstream to
contribute GHC support to. `sashiko-ghc.md` in this repository is the port
analysis that led there.

The case against forking is not that sashiko's plumbing is kernel-specific — it
mostly isn't. It is that the parts worth having are small and separable, while
the parts a fork forces you to carry are neither wanted nor static:

- The conflict surface of a long-lived fork is `src/worker/prompts.rs`, 2483
  lines of hardcoded kernel stage prompts. That is the file GaHiCo would rewrite
  in full, and the file upstream regularly rewrites too, syncing from the
  review-prompts repository. Every rebase is a conflict in the deliverable.
- What comes with it is a service: webhooks, a database, a web UI, NNTP and lore
  ingestion, email policy, `MAINTAINERS`-based baseline resolution. §1 rules all
  of that out. Domain-agnostic is not the same as wanted.
- sashiko is Apache 2.0, so anything worth taking can be taken with attribution.
  A fork relationship buys nothing a copy doesn't.

The orchestrator is also much smaller here than the 3576 lines of
`src/reviewer.rs` suggest, because most of that file is database persistence,
email routing, and quota management. What remains after removing them — worktree
prep, stage sequencing, artifact writing — is §4's `Repo`/`Pipeline`/`Bundle`.

Haskell survives this decision unchanged, for the reasons in §4. Reuse here
means reading sashiko before writing the equivalent module, not linking against
it, so the implementation language was never actually what the choice turned on.

### Non-goals (initially)

- No unattended operation: no webhook, no polling, no auto-posting.
- No building or running GHC by the agent.
- No proprietary or private context of any kind.
- Not a general-purpose forge bot; GHC's GitLab only.

## 2. Human workflow

1. Simon sees a ping on `!14892`.
2. `gahico review 14892` (optionally `--tasks correctness,docs`,
   `--harness codex`, `--prompt-file ./adhoc.md`).
3. The tool resolves the target, prepares a worktree, runs the pipeline(s),
   writes an artifact bundle, and creates a snippet.
4. It prints the snippet URL and a ready-to-paste MR comment.
5. Simon pastes the comment into the MR himself.

Step 5 stays manual by choice: it keeps a human deciding that *this* review
gets published at all, which is the cheapest possible killswitch.

This is the workflow the service exists for, but it is not the only one the
tool supports: reviewing a bare commit or a local branch (§3) runs the same
pipeline and stops after step 3, with no comment to paste. That path is how
prompt changes get exercised without involving anyone else's merge request.

## 3. CLI surface

```
gahico review <TARGET>             # see below
    --tasks correctness[,docs,...] # pipelines to run; default: correctness
    --harness claude|codex         # default from config
    --model / --effort             # harness-specific, recorded in disclosure
    --prompt-file PATH             # extra instructions appended to each task
    --prompt TEXT                  # same, inline
    --base REV                     # what to diff against; default per target
    --no-publish                   # produce the bundle, skip the snippet
    --dry-run                      # assemble context and print it, run nothing

gahico show <TARGET>               # path + summary of the last run
gahico open <TARGET>               # open the bundle dir
gahico publish <RUN>               # publish an existing bundle (retry path)
gahico feedback <RUN>              # open the feedback YAML for annotation
gahico prompts                     # list pipelines and the built-in prompts
```

### Targets

A merge request is one kind of review target, not the identifier everything
else is keyed on. Accepted forms:

| Target | Example | Default base |
|---|---|---|
| MR in the default project | `14892`, `!14892` | merge-base with target branch |
| MR in any project | a full GitLab MR URL | merge-base with target branch |
| A commit | `a1b2c3d` | its first parent |
| A commit range | `master..HEAD`, `origin/master..wip` | the range's start |
| A branch or tag | `wip/T27433` | merge-base with `master` |

Each resolves to the same internal shape: a base SHA, a head SHA, the project to
fetch from, and — only when the target is a merge request — forge metadata.
Everything downstream of resolution consumes that shape, so reviewing a bare
commit is not a special case, it is the same pipeline with the forge-derived
parts of the context pack absent (§5).

Fork MRs are covered by the URL form: the project to fetch from comes from the
URL, so an MR against `sjakobi/ghc` works exactly like one against `ghc/ghc`.

A run is identified by `<target-slug>/<utc-timestamp>`, where the slug is
`mr/<project>/<iid>`, `commit/<short-sha>`, or `range/<short-base>..<short-head>`.
A `<TARGET>` alone means "the latest run for that target".

## 4. Architecture

Haskell, as a cabal project.

```
gahico.cabal
src/GaHiCo/
  CLI.hs            optparse-applicative, top-level command flow
  Config.hs         ~/.config/gahico/config.yaml + defaults
  GitLab.hs         MR/issue/note fetch, snippet creation
  Repo.hs           clone maintenance, MR ref fetch, worktree pool
  Context.hs        assembles the context pack for a run
  Pipeline.hs       loads pipeline YAML, runs stages, threads findings
  Harness.hs        Harness record: run :: Prompt -> WorkTree -> ModelSpec
                                        -> IO Result
  Harness/Claude.hs `claude -p` adapter
  Harness/Codex.hs  `codex exec` adapter
  Findings.hs       Finding type, To/FromJSON, merge and dedup
  Report.hs         findings -> review.md, disclosure header, comment template
  Bundle.hs         artifact bundle layout, writing, indexing
  Feedback.hs       feedback YAML scaffold and rollup stats
prompts/
  correctness.yaml  pipeline definition (stages, models, prompt files)
  docs.yaml
  stages/*.md       prompt bodies
  false-positive-guide.md
```

`prompts/` is embedded into the binary with `file-embed`, and the build stamps
the commit. See Note [Prompts are pinned by the tool commit].

Dependencies of note: `gitlab-haskell` (merge requests, issues, notes,
discussions), `req` + `aeson` for snippet creation, which `gitlab-haskell` does
not cover, `typed-process` for harness invocation, `yaml` for pipeline and
config files, `optparse-applicative` for the CLI.

Haskell over Python because it is the language Simon is fluent in, because GHC
contributors can read and patch it, and because the findings interchange (§7)
is the load-bearing part of the design and benefits most from a checked schema.
Nothing here calls a model provider's SDK directly, so Python's advantage in
that ecosystem does not apply. See §7 for what changes if it ever does.

### What to read from sashiko, and when

Per §1, sashiko is consulted module by module as the corresponding GaHiCo module
gets written. Paths are relative to the sashiko checkout; it is Apache 2.0 and
anything derived from it carries attribution.

| Before writing | Read | For |
|---|---|---|
| `Pipeline.hs` | `src/worker/stage.rs` (400 lines) | The stage contract: structured findings between stages, schema validation, retry on malformed output. Its only imports are `crate::ai` types and `serde_json`, so it reads standalone. |
| `Harness/Claude.hs`, `Harness/Codex.hs` | `src/ai/claude_cli.rs`, `src/ai/codex_cli.rs` | Driving `claude -p` and `codex exec` as subprocesses: output parsing, tool allowlists, session handling. This is the existing answer to §7's problem that stage 2 needs an agent loop and Haskell has no Agent SDK. |
| `prompts/false-positive-guide.md` | `third_party/prompts/kernel/false-positive-guide.md` | Structure, not content. 495 lines of enumerated noise patterns where each carries its own carve-outs — the mechanism that keeps a guide from suppressing real bugs as it grows (§7). |
| The regression corpus (§11) | `src/bin/benchmark.rs` | Known-buggy commits, `fixed_by`, LLM judge, hit rate. Already project-agnostic; only the dataset is kernel-specific. |

One divergence to make deliberately rather than by omission: sashiko's stage
contract retries a stage that returns malformed JSON, where §7 makes it a hard
error. Hard error is the right default for a tool whose output is published
under a no-curation promise, but it should be a decision, not an accident of not
having read `stage.rs`.

The layering that matters: **context assembly, pipeline execution, and
publication are independent.** Any of them can be run alone, which is what
makes `--dry-run`, `--no-publish`, and `publish <RUN>` cheap to support and
makes the whole thing testable without an API key.

`Harness` is a record of functions rather than a class, so the harness is
chosen at runtime from config and a new backend is a value, not an instance.

## 5. Context pack

Assembled once per run, shared by all tasks and all stages, and archived in the
bundle verbatim. Everything in it is public.

Always present, for every target:

- **Commits**: `git log --format=fuller` for `base..head`, full messages.
- **Diff**: `git diff <base>..<head>`, plus `--stat`.
- **Worktree**: the head checked out, for free exploration.
- **Linked issues**: issues referenced as `#NNNNN` in the commit messages (and
  in the MR description, when there is one) — title, description, and comments.
  Depth 1, no transitive chasing, capped in count and size.

Present only when the target is a merge request:

- **MR metadata**: project, iid, title, description, author, source/target
  branch, labels.
- **MR discussion**: existing notes (excluding system notes), so the review can
  avoid restating what humans already said.

Stage prompts must therefore treat the forge-derived sections as optional. This
costs a little prompt care and buys the ability to review a commit, a branch, or
a fork MR through exactly the same path.

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
~/gahico/wt/<slug>/       worktree per target, reused across runs of that target
```

A commit, range or branch target needs no fetch beyond keeping the mirror
current. An MR target is fetched via GitLab's merge-request refs, from the
project the target names:

```
git fetch <project-url> +refs/merge-requests/<iid>/head:refs/gahico/<slug>
```

Fetching by URL rather than from a configured remote is what makes fork MRs
work without setup — and because the fork shares almost all of its history with
the mirror, the fetch is small.

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

Stage 3 additionally loads `prompts/false-positive-guide.md`, a standing
document of GHC-specific patterns that have produced false positives before,
each with its exceptions. It is shared by every pipeline, and it is the main
thing that gets edited in response to feedback (§10) — which is why it is a file
of its own rather than prose inside the verify stage prompt. It needs
calibration in both directions: a guide only ever added to drifts towards
suppressing real bugs.

Each stage is a **separate harness invocation** with a fresh session. Prior
stage outputs are passed as files in a run-local `context/` directory and
referenced from the prompt. This keeps stages portable across harnesses that
have very different session models, and makes each stage independently
replayable from the bundle. Session continuation is a possible later
optimisation, not a design assumption.

### Harness backends, including direct API calls

The harness boundary is deliberately narrow, and calling a provider's API
directly is just another implementation of it — no change to the pipeline,
context, or publication layers.

The cost of doing so is not the HTTP client; it is the agent loop. Stages 1, 3
and 4 are prompt-in, output-out over a context pack GaHiCo assembled itself, so
an API backend for them is a `POST /v1/messages` and a decoder. Stage 2 wants
free exploration of the worktree, so an API backend for *it* means implementing
tool schemas, the multi-turn loop, and allowlist enforcement — which is
precisely what `claude -p` already is. There is no Haskell equivalent of the
Agent SDK to lean on.

So the split is intentional: CLI harnesses for v1 everywhere, and if the
disclosure gap in open question §13.6 is judged serious, an API backend for the
non-agentic stages first, where it is cheap. Reconsidering the implementation
language only becomes reasonable if the whole pipeline goes API-native.

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
# LLM review of <target> — <MR title, or the head commit subject>

<disclaimer: machine-generated, not a human review, see ghc-devs announcement>

## Disclosure
| field | value |
gahico commit / harness / model / effort / tasks run / commit reviewed /
merge-base / context truncations / wall time / token usage & cost

## Findings — correctness
### [high, medium confidence] Title
...

## Findings — docs
...

## Appendix: ad-hoc prompts        (only when --prompt/--prompt-file was used)
<the extra instructions, verbatim>
```

### Note [Prompts are pinned by the tool commit]

§1 promises to disclose the exact prompt. Built-in prompts discharge that
**by reference**: the pipeline definitions, every stage prompt and the
false-positive guide all live in the GaHiCo repository, so one identifier — the
commit the binary was built from — pins the whole set. Reading the repo at that
commit reproduces the prompt exactly.

Prompts supplied per-run with `--prompt` or `--prompt-file` are in no commit, so
they are disclosed **by value**, inlined verbatim in the appendix. Most reviews
use no ad-hoc prompt and therefore have no appendix.

The obvious alternative — inlining every stage prompt in every review — is both
bulkier (the false-positive guide alone is expected to reach several hundred
lines) and *less* complete, because it discloses prompt bodies while silently
omitting the pipeline structure that decides which of them run and in what
order. The commit covers both.

Two consequences:

- Prompts are embedded in the binary rather than read from disk at runtime, so
  "the prompts at commit X" is a property of the artifact rather than a claim
  about what happened to be on disk during the run.
- Publishing from a dirty working tree is refused, because the stamped commit
  would not describe what actually ran. Local iteration uses `--no-publish`;
  such runs are stamped `<commit>-dirty` in the bundle so they are still
  recorded, just not publishable.

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
Produced by GaHiCo <commit> with <model> (<effort>); that commit is the prompt.
This is tool output, not a review by me; I have not curated it.
Comments on the review itself are best left on the snippet.
```

## 9. Artifact bundle

Per run, under `~/gahico/runs/<slug>/<timestamp>/`:

```
run.json          target, SHAs, harness, model, effort, gahico commit,
                  timings, token usage, cost, exit status
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
f1: {verdict: true-positive, category: strictness, note: "fixed in v2"}
f2: {verdict: false-positive, category: new, note: "misread a bang pattern"}
f3: {verdict: grey, category: style, note: "style, not a bug"}
```

`category` names a section of the false-positive guide (§7), or `new` when the
pattern has no section yet. It is what makes feedback actionable rather than
merely recorded: rolled up, it says which guide sections are not working and
which recurring patterns are still unaddressed. Free-text notes alone cannot
answer either question, and stop being read after a few weeks.

Annotated after the fact, from the MR discussion or the author's reply.
`gahico stats` rolls these up per model, per tool commit, and over time.
This is what makes the killswitch promise a data-driven decision rather than a
vibe, and it is the only way to tell whether a prompt change helped.

## 11. Roadmap after v1

- `docs` pipeline (Haddock accuracy, Note correctness — the `check-comments`
  angle).
- `perf` pipeline: build MR head and merge-base, diff `.dump-simpl`, feed to
  the agent. Needs a build orchestration step outside the agent.
- Finer-grained correctness stages, as pipeline config.
- Regression corpus: run against GHC commits that were later fixed by a
  follow-up MR — sashiko's methodology, GHC's data. Scoped to a smoke test of
  10–20 commits, run once before a tool release to catch obvious breakage. A
  published hit rate needs a corpus large enough to be meaningful, which the
  subscription budget cannot reach (§13); spreading the runs over weeks instead
  would let the tool commit drift mid-measurement, so the number would not mean
  what it claims either way.
- Additional harnesses.
- Only after signal-to-noise is demonstrably good: consider automating the
  trigger (polling GitLab todos) and the posting.

## 12. Configuration and secrets

`~/.config/gahico/config.yaml`: gitlab url, project paths, clone/worktree/run
directories, default harness/model/effort, size caps, pruning policy. YAML
rather than TOML only because pipelines are already YAML, and one format is one
parser.

The GitLab PAT (scope `api`, for reading MRs and creating snippets) comes from
the environment or a pass-style command, never from the config file.

## 13. Open questions

Several of these are constrained by a fact worth stating once: the harnesses
run on Claude Pro and Codex Pro subscriptions, which meter interactive use.
Anything batch-shaped — a regression corpus, a replay sweep — is not affordable
there, and driving a subscription at that volume is not what it is sold for.
The subscription harness is therefore the budget for day-to-day reviews, and
volume work belongs to an API backend or does not happen. See Q2, Q3, Q6, Q7
and Q9.

1. **Thread outcome.** The mailing list archive rendered only the original
   post, so the 15 replies (Klebinger, Shao, Angermann, Graf, Peyton Jones,
   Ellis, Duggal) are not reflected here. Any concessions or constraints agreed
   there need folding into §1 before implementation.
2. **Cost per review.** A 4-stage pipeline over a large MR with free
   exploration is not cheap. Worth a budget cap per run, and a printed cost
   before publication? Under a subscription the cap is not a cost control but a
   rationing one: the scarce thing is the weekly allowance, shared with every
   other use of the harness.
3. **Multiple harnesses per review.** Running claude *and* codex on the same MR
   and reporting both would be a strong signal-to-noise filter (agreement
   between independent models). This is the one volume question the
   subscriptions can absorb — 2× on a single MR, not N× over a corpus — since
   the two runs draw on separate allowances. Worth it for v1, or is the
   agreement signal not yet worth doubling the wall time?
4. **Re-reviews.** When an MR is updated and re-pinged, should the review be
   incremental (diff since the last reviewed SHA) or always full? Full is
   simpler and more honest; incremental is much cheaper on long-lived MRs.
5. **Public bundle repo and rate of growth.** Raw harness output per run is
   large. Cap it, or accept a fat repo?
6. **"Exact prompt" versus the harness system prompt.** §1 promises to disclose
   the exact prompt, but a CLI harness prepends a system prompt and tool
   preamble that GaHiCo neither controls nor can reproduce in the appendix. So
   the appendix is the exact prompt *GaHiCo* sent, not the full input to the
   model. Options: say exactly that in the disclosure and accept it; or move the
   non-agentic stages to direct API calls, where the published prompt is the
   whole prompt (§7). This is the strongest argument for an API backend; the
   volume constraint above is a second, independent one pointing the same way.
   Worth settling before the first public review rather than after.
7. **Replaying annotated runs against a new guide.** Bundles archive the context
   pack and every stage input, so re-running an old target under a new tool
   commit is mechanically possible. Doing it over the runs already annotated in
   §10 would show whether a false-positive-guide edit actually suppressed what
   it was meant to — and, on the true-positive ones, whether it suppressed
   anything it shouldn't have. But a sweep of the annotated set per guide edit
   is exactly the batch shape the subscriptions cannot pay for, and the sweep is
   where the value was. What survives is the narrow form: replay one archived
   run when one guide edit is suspicious. Worth building for that alone? It
   remains the only real check on a guide that otherwise only grows, and the
   full sweep stays available to an API backend.
8. **Feedback from snippet comments.** `gahico feedback` currently opens an
   empty file for Simon to fill in from memory. Since reviews are published as
   snippets with comments enabled (§8), authors will often say which findings
   were wrong right there. Pre-populating the YAML from snippet comments and MR
   replies would cut the annotation cost, which is the thing most likely to
   stop happening.
9. **What a fresh invocation per stage costs.** §7 gives each stage its own
   harness invocation with prior outputs passed as files, which buys replay,
   per-stage auditability, and portability across harnesses — all of which §8's
   disclosure and §9's public bundles depend on. The price is re-reading the
   context pack once per stage, roughly quadrupling input tokens on a four-stage
   pipeline before any exploration. Prompt caching recovers much of it if stages
   share a prefix and run close together, which they do. This is the same
   question as §13.2 seen from the design side, and settling one settles both.
   sashiko avoids the cost by threading state in-process through its database —
   an option foreclosed here, and deliberately so.
10. **Rename to GlaHiCo?** Under consideration. "Gla-Hi-Co" matches "sa-shi-ko"
    syllable for syllable rather than only in its consonants, and the syllables
    are Glasgow Haskell Compiler. It also sounds better. The cost is the
    directory, `~/gahico/`, `~/.config/gahico/`, the binary name and the module
    namespace — trivial now, tedious once any of that exists. Now the first
    thing to settle: with the build-versus-fork question closed (§1), nothing
    else stands between this design and code that hardcodes whichever name wins.
