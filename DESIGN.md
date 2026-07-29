# GlaHiCo — LLM code review for GHC merge requests

The name matches "sa-shi-ko" syllable for syllable — a nod to the Linux kernel
review service this borrows its shape from — and the syllables are Glasgow
Haskell Compiler.

Status: v2 design, 2026-07-29. Replaces the first draft (now `DESIGN_OLD.md`),
which specified too much machinery before any code existed. This version keeps
the same purpose and public constraints but cuts the tool down to a script and
the pipeline down to find-then-filter.

## Purpose

An opt-in, spare-time service: someone pings `@sjakobi llm-review please` on a
GHC merge request, Simon runs the tool locally, and pastes the resulting review
into the MR. The goal is to surface **correctness bugs that matter to GHC
maintainers** while keeping noise acceptably low. Noise control is the design's
centre of gravity: a review that wastes maintainer time is worse than none.

### Binding constraints (from the ghc-devs announcement)

- Reviews are **tool output**, labelled as such, posted **verbatim** — no human
  curation of model output. (Filtering done *by the pipeline* is disclosed and
  fine; Simon deleting embarrassing findings is not.)
- Every review discloses **model, effort level, and the exact prompt**.
- **Only public code and context** is sent to the LLM provider.
- There is a **killswitch**. In v1 it is trivially satisfied: nothing is posted
  except by hand.

## The tool

A **single-file Haskell cabal script** wrapping `claude -p`. No cabal project,
no module tree — structure gets added when it hurts, not before. It:

1. resolves the target and prepares a worktree,
2. assembles the context pack,
3. runs the finder, then one verifier per finding,
4. writes `review.md` under a per-run directory and prints its path.

Publication is manual: Simon reads nothing into the MR that the tool didn't
write, but he pastes it (or a snippet link) himself. No snippet automation, no
bundle repo, no feedback machinery in v1.

### Models

Finder and verifier take **separate model (and effort) settings**, e.g. Fable
for the finder and Opus 4.8 for verification — the stages have different jobs
and different cost profiles, and mixing models also decorrelates their blind
spots. Settable per run (`--finder-model`, `--verifier-model`, likewise for
effort) with defaults in the script; all verifiers in a run share one setting.
Whatever ran is recorded per stage in the disclosure header.

### Custom prompts

`--prompt TEXT` / `--prompt-file PATH` **append** extra instructions to the
finder prompt — no templating, no overriding the built-in prompt. Typical use:
"pay special attention to X" for a particular MR. The verifier prompt is not
touched: it stays the same neutral filter regardless of what the finder was
steered towards. Ad-hoc prompts are in no commit, so they are disclosed by
value: inlined verbatim in an appendix of `review.md`.

### Targets

- An MR number (`14892`, `!14892`) in ghc/ghc, fetched via
  `refs/merge-requests/<iid>/head`.
- An MR in another project, e.g. a fork like `sjakobi/ghc`, given as a GitLab
  MR URL — the project to fetch from comes from the URL.
- A local git range (`master..HEAD`) — for exercising prompt changes on local
  branches without involving anyone's MR. Forge-derived context is simply
  absent for these.

GlaHiCo owns its own bare mirror of ghc/ghc and a worktree per target, separate
from Simon's working checkouts. Submodules are initialised.

## Context pack

Assembled once per run, shared by finder and verifiers, archived in the run
directory. Everything in it is public.

- **Diff** (`base..head`, with `--stat`) and **commit messages** (full).
- **Worktree** with the head checked out, for read-only exploration.
- For MR targets: **MR metadata** (title, description, labels, branches),
  **MR discussion** (non-system notes — so the review can avoid restating what
  humans already said), and **linked issues** (`#NNNNN` references from commit
  messages and the MR description; title, description, comments; depth 1,
  capped).

Truncation, when caps bite, is explicit (`[truncated]`) and noted in the
disclosure header.

Agents are read-only: read, grep, git inspection in the worktree; no build, no
test runs, no writes, no network. Enforced by the harness tool allowlist.

## Pipeline

Two LLM stages; everything else is the script.

### 1. Finder

One `claude -p` agent over the context pack, hunting **correctness bugs only**:
logic errors introduced by the change, partiality, violated invariants,
behaviour that contradicts the commit message. Explicitly out of scope: style,
speculative refactors, pre-existing issues the MR doesn't touch, test-coverage
nagging.

Output: `findings.json`, a list of

```json
{ "id": "f1", "title": "...", "file": "compiler/...", "line": 412,
  "claim": "...", "evidence": "..." }
```

That is the whole schema — no severity/confidence taxonomy yet. Malformed
output is a hard error with the raw output preserved.

### 2. Verifier — one agent per finding

Each finding gets its own fresh agent with the context pack, the finding, and
read-only worktree access. Its prompt runs three steps in order:

1. **Disprove**: actively try to refute the finding, citing code as evidence.
2. **Prove**: then try to substantiate it, again with evidence.
3. **Relevance**: would a GHC maintainer reviewing this MR care?

Output per finding: the evidence from both steps plus a verdict —
`confirmed`, `uncertain`, or `refuted` — and `relevant: true/false`.

Kept for the review: confirmed-and-relevant findings in the main section;
uncertain-but-relevant ones in a clearly labelled low-confidence section.
Refuted or irrelevant findings are dropped from the review but preserved in the
run directory, so filter behaviour stays auditable.

There is no false-positive guide yet. The verifier prompt carries only generic
noise guidance; a standing guide file gets created **from data**, once real
runs have produced real false positives to put in it.

### 3. Report

Assembled mechanically by the script, not by another LLM call: disclosure
header, then the surviving findings (title, location, claim, evidence,
verifier's supporting evidence), then the low-confidence section.

Disclosure header: glahico commit, model and effort per stage, target SHAs, truncations, and
a one-line disclaimer that this is tool output. The prompts live in this
repository, so the glahico commit *is* the exact-prompt disclosure — reading the
repo at that commit reproduces every prompt. Ad-hoc additions from
`--prompt`/`--prompt-file` are in no commit and are inlined verbatim in an
appendix instead; most runs use none and have no appendix.

## Run directory

```
runs/<slug>/<timestamp>/
  context/         the pack as sent
  findings.json    finder output
  verdicts/f*.json verifier outputs, including refuted/irrelevant ones
  review.md        the deliverable
```

Local only for now. Publishing bundles publicly (everything in them is public
by construction) is a later decision, not a v1 feature.

## Budget

The harness runs on a Claude Pro subscription, which meters interactive use.
Per-finding verification multiplies calls, but findings per MR should be few
if the finder prompt is doing its job; a finder that regularly emits ten
findings has a noise problem the verifiers shouldn't be paid to clean up.
Anything batch-shaped (regression corpora, replay sweeps) stays out of scope.

## Deferred, deliberately

All of DESIGN_OLD's remaining structure waits for evidence that it's needed:

- YAML pipeline definitions, multiple tasks, docs/perf pipelines.
- Snippet automation, public bundle repo, feedback YAML and stats.
- The false-positive guide (until data exists).
- A second harness (codex) and cross-model agreement.
- Severity/confidence fields in the finding schema.

## Open questions

1. **Harness system prompt vs. "exact prompt".** `claude -p` prepends a system
   prompt GlaHiCo can't reproduce; the disclosure covers what GlaHiCo sent.
   Probably just state that limitation in the disclaimer.
2. **Mailing-list thread outcome.** The 15 replies to the announcement may
   contain agreed constraints not yet reflected here (DESIGN_OLD §13.1).
