---
name: glahico-draft-ticket
description: >
  Turn a GlaHiCo review finding into a draft GHC issue: verify it still
  applies on origin/master, search gitlab.haskell.org for duplicates, build
  and run a reproducer, and write a draft ticket into the run dir. Never
  files the issue itself. Usage: /glahico-draft-ticket RUN_DIR FINDING_ID
  (e.g. /glahico-draft-ticket ~/glahico/runs/local-work-…/20260804T174020 f1).
---

# GlaHiCo finding → draft GHC ticket

Task: for each given finding, check that it still applies and isn't already
tracked; if it's worth filing, build and run a reproducer and write a
concise, high-quality draft ticket. If it isn't worth filing (already
fixed, duplicate, not a real bug), report why instead of drafting.

Pre-checks (per finding, before any other work):

- The review must be published: `RUN_DIR/snippet.json` exists (written by
  `glahico publish`). If it doesn't, stop and ask Simon to publish first.
- No draft exists yet: if `RUN_DIR/tickets/<fid>.md` is already there,
  stop and point to it — it may have been hand-edited or already filed;
  never overwrite it.

Hard policies:

- **Draft only, never file.** Simon files manually. Don't post anything.
- Draft goes to `RUN_DIR/tickets/<fid>.md`, topped by a metadata block for
  Simon (suggested labels, related issues). Reproducer files go to
  `RUN_DIR/tickets/<fid>/` and are also included verbatim in the ticket
  body — the ticket must be self-contained, not reference attachments.
- Title: ≤ 90 characters, naming the symptom or component, not the
  diagnosis.
- Always try to actually run the reproducer. If constructing or running
  one isn't possible, draft anyway and say so plainly in the ticket,
  giving the code-level trigger scenario instead.
- LLM provenance is stated in two places, and the level-of-human-review
  claim lives ONLY in the banner:
  - Banner, in italics, directly after the title (before the first
    section), verbatim:

    ```
    *This ticket reports a possible bug found by an LLM-based code
    review (details under "Provenance" below). I, @sjakobi, have
    checked it for plausibility, but not verified it in depth.*
    ```

  - `## Provenance` as the last section, facts only — pipeline,
    reviewed commits, published review, LLM-written draft:

    ```
    Found by [GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo), an
    LLM-based code-review pipeline, while reviewing <what>. The
    published review of <branch-sha> (master: <master-sha>) is at
    <snippet.json web_url> (finding <fid>).
    The draft of this ticket was also written by an LLM agent.
    ```

Environment facts:

- Finding evidence: `RUN_DIR/verdicts/<fid>.json` (authoritative), plus
  `review.md` and `context/`. For sweep runs, `~/glahico/sweeps/*/state.tsv`
  and `worklist.json` map run dirs to groups and to the master-side
  cherry-pick source SHAs — cite branch and master SHAs where known.
- `~/ghc/work` is the sweep hub: treat it as **read-only** (fetch and
  `git show` are fine; never check anything out, never rebuild its
  `_build`). Its `_build/stage1/bin/ghc` IS the stage-2 compiler — prefer
  it for reproducers, noting which commit it was built from.
- Findings come from backport reviews, so check `origin/ghc-9.14` as well
  as `origin/master` — a bug can be branch-only (bad backport) or fixed on
  master but not backported.
- If a different build is genuinely needed: only with ≥ 10 GB free on
  `~/ghc`, create a worktree with `~/ghc/wt <name> <branch> <start-point>`
  (lands in `~/ghc/work-trees/`) and build/test there with `~/ghc/tt`.
- Issue search: host gitlab.haskell.org, project `ghc/ghc`, e.g.
  `glab api "projects/ghc%2Fghc/issues?search=<terms>&scope=all&per_page=100"`
  (100 is GitLab's max; paginate rather than judge from a truncated list).
  glab's token is read_api — sufficient.
