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

Input: a run dir and a finding id (`f1`, `f2`, …). Multiple finding ids may
be given; process them one at a time, each through all steps. If the given
path is the target dir (parent of timestamped run dirs), use its single or
latest timestamped child and say so.

Output: `RUN_DIR/tickets/<fid>.md` (draft ticket) plus, when a reproducer
exists, `RUN_DIR/tickets/<fid>/` with the reproducer files. **Never file the
issue** — Simon files manually. Do not post anything via glab.

## 1. Load the finding

Read from the run dir:
- `verdicts/<fid>.json` — the authoritative record: `finding` (claim,
  evidence, file, line, title), `verdict`, `writeup`, `snippets`,
  `prove_evidence` / `disprove_evidence`.
- `review.md` — rendered writeup and code snippets.
- `context/commits.txt` and `context/diff.patch` — the reviewed commits
  (for a sweep run these are the backport SHAs on the 9.14 branch).

For sweep runs, `~/glahico/sweeps/*/state.tsv` maps run dirs back to group
ids and target specs; `worklist.json` has the master-side cherry-pick source
SHAs — cite both branch and master SHAs in the ticket when available.

## 2. Does it still apply?

Work in `~/ghc/work`. **Read-only**: fetch and inspect objects; never check
out branches, never touch the working tree or its `_build`.

- `git -C ~/ghc/work fetch origin`
- Inspect the flawed code at `origin/master` (`git show origin/master:<file>`,
  `git log origin/master --oneline -- <file>`): is the defect still present,
  already fixed (cite the fixing commit), or refactored away?
- The finding came from a backport review, so also check the release branch
  (`origin/ghc-9.14`): a bug can be branch-only (bad backport) or fixed on
  master but not backported. Record where the bug lives — this decides the
  milestone and framing (master bug vs. 9.14.2 release blocker).

If it applies nowhere anymore, stop for this finding and report why —
don't draft.

## 3. Duplicate check

Search the GHC tracker (host gitlab.haskell.org, project `ghc/ghc`) with
several angles — symptom phrasing, function/type names, file name, error
message text:

```
glab api "projects/ghc%2Fghc/issues?search=<terms>&scope=all&per_page=100"
```

(100 is GitLab's per-page maximum; if a query still returns a full page,
tighten the terms or fetch further pages with `&page=2` rather than judging
from a truncated list.)

(glab's configured token is read_api — sufficient.) Check open issues and
recently closed ones. If a matching issue exists, stop for this finding and
report it with a link; if a related-but-not-identical issue exists, continue
and reference it in the draft.

## 4. Reproducer

Always try to build one and run it.

- Prefer the existing compiler `~/ghc/work/_build/stage1/bin/ghc` (despite
  the name, that IS the stage-2 compiler). Check which commit it corresponds
  to and note that in the ticket. Do not rebuild anything in `~/ghc/work`.
- If a different build is genuinely required (bug not present in the
  existing build's commit, or needs a specific branch): first check disk
  space (`df --output=avail -BG ~/ghc`); only if **≥ 10 GB** free, create a
  fresh worktree with `~/ghc/wt <name> <branch> <start-point>` (dirs land in
  `~/ghc/work-trees/`; wt boots, configures, and warms up hadrian). Build/run
  tests there with `~/ghc/tt` (builds the stage-2 compiler on first use;
  respects the machine-wide build-slot pool). Otherwise fall back to the
  existing compiler or a reasoning-only ticket, and say so.
- Minimise the reproducer as far as practical. Save the files plus a
  `run.sh` with the exact invocation and expected-vs-actual behaviour to
  `RUN_DIR/tickets/<fid>/`. Shape it testsuite-like (a `.hs` and expected
  output) where natural, but standalone files suffice.
- If constructing or running a reproducer isn't possible (bug not
  user-observable, needs unavailable hardware, etc.), still draft the
  ticket and state plainly in it that there is no executed reproducer and
  why; give the code-level trigger scenario instead.

## 5. Draft the ticket

Write GitLab-flavoured markdown to `RUN_DIR/tickets/<fid>.md`. Concise and
high-quality — a GHC developer should grasp the bug from the first screen.

Structure:

1. A metadata block for Simon (not part of the ticket body), listing
   suggested labels (e.g. `~bug`, subsystem label like `~"compiler perf"` /
   `~CodeGen` / `~RTS`, `~backport` when branch-relevant) and suggested
   milestone (e.g. `%9.14.2` for release-branch bugs), plus links to any
   related issues found in step 3.
2. Title line.
3. Summary — what is wrong and its user-visible consequence.
4. Reproducer — inline the small files, exact command, expected vs. actual
   output, and which compiler/commit it was run against. Or the explicit
   no-reproducer statement from step 4.
5. Analysis — the offending code (file:line on the relevant branch), the
   introducing commits (branch SHA and master source SHA where known), and
   where the bug does/doesn't exist (master vs. ghc-9.14) from step 2.
6. Provenance — note the bug was found by GlaHiCo, an automated
   Claude-based review of the backports, and that the analysis was
   human-checked; link the reviewed commits.

## 6. Report

End with, per finding: verdict (drafted / duplicate of #N / already fixed by
<commit> / not worth filing because …), the draft path, reproducer status
(executed against which compiler, or why not), and anything Simon should
double-check before filing.
