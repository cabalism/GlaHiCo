# GlaHiCo — LLM code review for GHC merge requests

The name matches "sa-shi-ko" syllable for syllable — a nod to the Linux kernel
review service this borrows its shape from — and the syllables are Glasgow
Haskell Compiler.

Status: v2 design, 2026-07-29. Replaces the first draft (now `DESIGN_OLD.md`),
which specified too much machinery before any code existed. This version keeps
the same purpose and public constraints but cuts the tool down to a script and
the pipeline down to find-then-filter.

This file records the rationale — the constraints and design decisions the
code can't speak for. For what the tool actually does and how to run it, read
`README.md` and `glahico.hs`; the mechanics are deliberately not duplicated
here.

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

## Shape of the tool

A **single-file Haskell cabal script** wrapping `claude -p`. No cabal project,
no module tree — structure gets added when it hurts, not before.

Publication is explicit: `glahico publish RUN_DIR` posts the review as an
internal-visibility snippet on sjakobi/GlaHiCo (see README), but linking it
from the MR stays manual — Simon posts nothing into the MR that he didn't
decide to. Feedback arrives as snippet comments; no bundle repo, no feedback
machinery in v1.

## Design decisions

- **Find, then filter.** One finder agent hunts correctness bugs only —
  style, speculative refactors, pre-existing issues the MR doesn't touch, and
  test-coverage nagging are out of scope. Each finding is then verified by an
  independent agent whose prompt tries to *disprove* it before substantiating
  it, and judges whether a GHC maintainer would care. Noise control is
  structural, done by the pipeline, not by hand-curation after the fact.
- **Auditability.** Refuted or irrelevant findings are dropped from the
  review but preserved in the run directory, so filter behaviour can be
  inspected.
- **Snippets are never model output.** Quoted code in the review is extracted
  by the script from the head checkout at verifier-chosen line ranges, so the
  model can't misquote the code under review.
- **Disclosure by commit.** The prompts live in this repository, so the
  glahico commit recorded in the review's disclosure section *is* the
  exact-prompt disclosure — reading the repo at that commit reproduces every
  prompt. Anything uncommitted (ad-hoc `--prompt` text, dirty prompt files)
  is instead disclosed by value, inlined verbatim in a review appendix.
- **Read-only agents.** Read, grep, and git inspection in a dedicated
  worktree; no build, no test runs, no writes, no network. The harness tool
  allowlist restricts agents to read-oriented git subcommands — a strong
  default rather than a hard guarantee, since a few permitted flags (`git
  grep -O`, `--output` on diff/log) could in principle execute a command or
  write a file. Together with a public-project check on the target, this
  makes "only public context reaches the provider" true by construction.
- **No false-positive guide yet.** The verifier prompt carries only generic
  noise guidance; a standing guide file gets created **from data**, once real
  runs have produced real false positives to put in it.

### Models

Finder and verifier take **separate model (and effort) settings**, e.g. Fable
for the finder and Opus 4.8 for verification — the stages have different jobs
and different cost profiles, and mixing models also decorrelates their blind
spots. Settable per run (`--finder-model`, `--verifier-model`, likewise for
effort) with defaults in the script; all verifiers in a run share one setting.
Whatever ran is recorded per stage in the disclosure.

### Custom prompts

`--prompt TEXT` / `--prompt-file PATH` **append** extra instructions to the
finder prompt — no templating, no overriding the built-in prompt. Typical use:
"pay special attention to X" for a particular MR. The verifier prompt is not
touched: it stays the same neutral filter regardless of what the finder was
steered towards. Ad-hoc prompts are in no commit, so they are disclosed by
value: inlined verbatim in an appendix of the review.

## Budget

The harness runs on a Claude Pro subscription, which meters interactive use.
Per-finding verification multiplies calls, but findings per MR should be few
if the finder prompt is doing its job; a finder that regularly emits ten
findings has a noise problem the verifiers shouldn't be paid to clean up.
Anything batch-shaped (regression corpora, replay sweeps) stays out of scope.

## Deferred, deliberately

All of DESIGN_OLD's remaining structure waits for evidence that it's needed:

- YAML pipeline definitions, multiple tasks, docs/perf pipelines.
- Public bundle repo, feedback YAML and stats.
- The false-positive guide (until data exists).
- A second harness (codex) and cross-model agreement.
- Severity/confidence fields in the finding schema.
- Publishing whole run bundles publicly (everything in them is public by
  construction) rather than just the review.

## Open questions

1. **Harness system prompt vs. "exact prompt".** `claude -p` prepends a system
   prompt GlaHiCo can't reproduce; the disclosure covers what GlaHiCo sent.
   Probably just state that limitation in the disclaimer.
2. **Mailing-list thread outcome.** The 15 replies to the announcement may
   contain agreed constraints not yet reflected here (DESIGN_OLD §13.1).
