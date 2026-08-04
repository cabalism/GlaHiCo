---
name: glahico-file-issue
description: >
  Turn a GlaHiCo review finding into a draft GHC issue: verify it still
  applies on origin/master, search gitlab.haskell.org for duplicates, build
  and run a reproducer, and write a draft ticket into the run dir. Never
  files the issue itself. Usage: /glahico-file-issue RUN_DIR FINDING_ID
  (e.g. /glahico-file-issue ~/glahico/runs/local-work-…/20260804T174020 f1).
---

# GlaHiCo finding → draft GHC ticket

Task: for each given finding, check that it still applies and isn't already
tracked; if it's worth filing, build and run a reproducer and write a
concise, high-quality draft ticket. If it isn't worth filing (already
fixed, duplicate, not a real bug), report why instead of drafting.

Hard policies:

- **Draft only, never file.** Simon files manually. Don't post anything.
- Draft goes to `RUN_DIR/tickets/<fid>.md`, topped by a metadata block for
  Simon (suggested labels, milestone, related issues). Reproducer files
  plus a `run.sh` go to `RUN_DIR/tickets/<fid>/`.
- Always try to actually run the reproducer. If constructing or running
  one isn't possible, draft anyway and say so plainly in the ticket,
  giving the code-level trigger scenario instead.
- The ticket notes GlaHiCo provenance: found by an automated Claude-based
  review of the commits (link them), analysis human-checked.

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
  master but not backported; that decides milestone and framing.
- If a different build is genuinely needed: only with ≥ 10 GB free on
  `~/ghc`, create a worktree with `~/ghc/wt <name> <branch> <start-point>`
  (lands in `~/ghc/work-trees/`) and build/test there with `~/ghc/tt`.
- Issue search: host gitlab.haskell.org, project `ghc/ghc`, e.g.
  `glab api "projects/ghc%2Fghc/issues?search=<terms>&scope=all&per_page=100"`
  (100 is GitLab's max; paginate rather than judge from a truncated list).
  glab's token is read_api — sufficient.
