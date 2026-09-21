---
name: glahico-draft-ticket
description: >
  Turn a GlaHiCo review finding into a draft GHC issue: verify it still
  applies on the active branches, search gitlab.haskell.org for duplicates,
  build and run a reproducer, and write a draft ticket into the run dir.
  Never files the issue itself. Usage: /glahico-draft-ticket RUN_DIR FINDING_ID
  (e.g. /glahico-draft-ticket ~/glahico/runs/local-work-…/20260804T174020 f1).
---

# GlaHiCo finding → draft GHC ticket

Task: for each given finding, check that it still applies and isn't already
tracked; if it's worth filing, build and run a reproducer and write a
short, factual draft ticket. If it isn't worth filing (already fixed,
duplicate, not a real bug), report why instead of drafting.

Pre-checks (per finding, before any other work):

- The review must be published: `RUN_DIR/snippet.json` exists (written by
  `glahico publish`). If it doesn't, stop and ask Simon to publish first.
- No draft exists yet: if `RUN_DIR/tickets/<fid>.md` is already there,
  stop and point to it — it may have been hand-edited or already filed;
  never overwrite it.

Hard policies:

- **Draft only, never file.** Simon files manually. Don't post anything.
- **No installs without approval.** Don't install toolchains, packages or
  tools for a reproducer. If one is needed, stop and ask, giving size and
  reason.
- **Verify before you claim.** Every factual statement in the ticket
  (what a function does, what a flag means, what a branch contains) is
  checked against source or haddocks first. Drop what you can't check, or
  mark it as a guess. The reviewer's verdict is a lead, not a fact.
- **Reproducer effort.** Spend at least ten minutes on a reproducer before
  giving up. If none could be built or run, draft anyway, say so in the
  ticket and give the code-level trigger scenario instead.
- **Title** ≤ 90 characters, stating the observed behaviour in neutral
  terms — not the diagnosis, not the impact.

Where things go:

- Draft: `RUN_DIR/tickets/<fid>.md`. Reproducer files also go to
  `RUN_DIR/tickets/<fid>/`, but the ticket includes them inline — it must
  be self-contained.
- The draft starts with a metadata block for Simon, not part of the
  ticket: suggested labels, related issues, reasons not to file (severity,
  scope, doubts), and the reproducer attempts made if none succeeded.
- Labels: exactly one `llm-derived::` label — `llm-derived::reproducer` if
  you built and ran one, `llm-derived::unverified` otherwise. Never
  `verified`, `false-positive` or `low-impact`; those are for others to
  apply. Also suggest topic/component labels.

Ticket structure, in this order:

1. Title.
2. Banner, one line in italics, verbatim:

   ```
   *This issue was discovered during an LLM-based code review (see
   "Provenance" below). I, @sjakobi, have checked it for plausibility,
   but not in depth.*
   ```

3. Summary — only if the title doesn't already say it.
4. Reproducer — one file, how to run it, observed output. The header
   comment says what the file does and what to expect; no analysis in it.
5. Analysis — optional, signposted so it can be skipped.
6. Facts — which branches and compilers it reproduces on, what introduced
   it (a backport slip, or the original commit/MR), and known user reports
   if any.
7. Provenance, facts only:

   ```
   Found by [GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo), an
   LLM-based code-review pipeline, while reviewing <what>. The
   published review of <branch-sha> (master: <master-sha>) is at
   <snippet.json web_url> (finding <fid>).
   The draft of this ticket was also written by an LLM agent.
   ```

Inputs to consult:

- Finding evidence: `RUN_DIR/verdicts/<fid>.json` (authoritative), plus
  `review.md` and `context/`. For sweep runs, `~/glahico/sweeps/*/state.tsv`
  and `worklist.json` map run dirs to groups and to the master-side
  cherry-pick source SHAs — cite branch and master SHAs where known.
- The original MR discussion for the reviewed commits — it often explains
  the intent and known limitations.
- The active branches: master, ghc-10.0, ghc-9.14, ghc-9.12, ghc-9.10.
  A bug can be branch-only (bad backport) or fixed on master but not
  backported. Check the reproducer with the compilers available — ghcup
  installs (`ghcup list -c installed`, including prereleases) and
  `~/ghc/work` — and say in the facts which branches you couldn't check.
- Issue search: host gitlab.haskell.org, project `ghc/ghc`, e.g.
  `glab api "projects/ghc%2Fghc/issues?search=<terms>&scope=all&per_page=100"`
  (100 is GitLab's max; paginate rather than judge from a truncated list).
  glab's token is read_api — sufficient.

Environment facts:

- `~/ghc/work` is the sweep hub: treat it as **read-only** (fetch and
  `git show` are fine; never check anything out, never rebuild its
  `_build`). Its `_build/stage1/bin/ghc` IS the stage-2 compiler — note
  which commit it was built from when using it.
- If a different build is genuinely needed: only with ≥ 10 GB free on
  `~/ghc`, create a worktree with `~/ghc/wt <name> <branch> <start-point>`
  (lands in `~/ghc/work-trees/`) and build/test there with `~/ghc/tt`.
