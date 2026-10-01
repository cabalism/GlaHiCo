---
name: glahico-remaining-findings
description: >
  Turn the findings of a finished GlaHiCo sweep that got no ticket of their
  own into one bundled GHC issue, in three separate steps: collect them
  into a file in the sweep dir, check each for actionability, draft the
  ticket. Never files it. Usage: /glahico-remaining-findings SWEEP_DIR
  collect|check|draft (e.g. /glahico-remaining-findings
  ~/glahico/sweeps/ghc-9.14.2-rc2 collect).
---

# GlaHiCo sweep → one ticket for the remaining findings

Vocabulary: a sweep is one GlaHiCo pass over a commit range, split into
groups; each group has one review (`review.md`, published as a snippet)
with numbered findings. "Remaining" findings are those that triage did not
route to a ticket of their own, an MR comment or a tracking ticket, and
did not drop.

The three steps are separate invocations. Each one ends by reporting to
Simon and stopping, so that he can prune or annotate the file before the
next step. Never run the next step in the same invocation.

Hard policies:

- **Draft only, never file.** Don't post anything anywhere.
- **Verify before you claim.** Facts come from the run dir's
  `verdicts/<fid>.json`, from git in `~/ghc/work` (read-only: `git log`,
  `git show`, `git grep` at a ref; never check anything out) and from the
  GitLab API. `findings.md` and `triage.md` are leads for what to look at,
  not sources for the ticket text.
- **No new reproducers.** A finding that needs one belongs to
  `glahico-draft-ticket`; say so in the file and leave it out of the
  bundle.
- The file `SWEEP_DIR/remaining-findings.md` is shared state between the
  steps and may have been hand-edited. Read it as it is; never regenerate
  it from scratch once it exists.

## Step 1: `collect`

Pre-checks: `SWEEP_DIR` has `findings.md` and `triage.md`; every done group
has a snippet URL (`snippets.tsv` or `snippet.json` in the run dir),
otherwise stop and ask Simon to run `publish-reviews.sh`. If
`remaining-findings.md` already exists, stop and point to it.

Go through every finding in `findings.md` and keep the ones `triage.md`
did not route elsewhere: not filed (no issue number), not reported on an MR
or tracking ticket, not dropped as refuted or moot. Findings whose
disposition is missing or ambiguous are kept and marked `disposition:
unclear`. Findings triage already called unactionable are kept too, with
the reason; step 2 confirms it.

Write `SWEEP_DIR/remaining-findings.md`:

```
# Remaining findings — <sweep name>

Collected <date> from findings.md and triage.md. One entry per finding;
step 2 fills in `actionable:`.

## <group> <fid>: <finding title as in the review>

- area: <bucket from buckets.tsv, or the top-level path of the flagged
  file: compiler/GHC/<Subsystem>, rts, libraries/<name>, docs, testsuite>
- commits: <branch sha> (master source <sha>, MR !N) | branch-only
- finding: <one sentence, from verdicts/<fid>.json>
- location: <file and the function, Note or changelog entry concerned>
- triage: <what triage.md says, quoted briefly>
- review: <snippet URL> (finding <fid>)
- actionable: TODO
```

Entries in `findings.md` order. Report the count and the list of ids, and
stop.

## Step 2: `check`

Pre-check: `remaining-findings.md` exists and has at least one entry with
`actionable: TODO`. Only those entries are checked; entries Simon has
already resolved are left alone.

For each entry, in this order, stopping at the first that decides it:

1. **Still there?** Look up the flagged text at the current heads:
   `git grep -n '<text>' origin/master -- <path>` and the same on the
   branch the sweep targeted. Gone on master → find the commit that
   removed it (`git log -S'<text>' origin/master -- <path>`) and record
   `actionable: no — fixed on master by <sha> (<title>)`, plus whether the
   branch still has it. Gone on both → `no — fixed`.
2. **Already tracked?** Search issues with two or three distinctive terms
   (`glab api "projects/ghc%2Fghc/issues?search=<terms>&scope=all&
   state=all&per_page=100" --hostname gitlab.haskell.org`) and open MRs
   touching the file (`.../merge_requests?state=opened&search=<term>`). A
   hit that covers the finding → `no — tracked in #N` or `no — fixed by
   !N (open)`.
3. **Can anyone act on it?** Nothing in the repo to change means nothing
   to file: an inaccurate commit message or MR description, a merged
   discussion, a stylistic preference. Record `no — <what it is>, nothing
   to change in the tree`.
4. **Does it need its own ticket?** A finding that asks for a design
   decision, changes user-visible behaviour, or needs a reproducer to be
   believed doesn't fit a bundle. Record `separate — <reason>` and suggest
   `glahico-draft-ticket` for it.
5. Otherwise `actionable: yes`, followed by one line each for: what the
   correct text or code is (with the source you checked it against), and
   whether it is identical on master or branch-only.

Every verdict cites what was run or read, in one line. Don't edit any
other field. Report a table of id, area and verdict, and stop.

## Step 3: `draft`

Pre-checks: every entry in `remaining-findings.md` has a resolved
`actionable:` line (no `TODO`, no `disposition: unclear`), and at least one
says `yes`. No `SWEEP_DIR/tickets/remaining-findings.md` exists yet.

Only entries marked `yes` go into the ticket. Write
`SWEEP_DIR/tickets/remaining-findings.md`, self-contained, in this order:

1. Metadata block for Simon, not part of the ticket: suggested labels
   (`llm-derived::unverified` unless something was run; the topic labels
   of the areas involved; `documentation` when all items are text),
   related issues found in step 2, the entries marked `separate` and
   `no` with their one-line reasons, and any doubt about bundling.
2. Title, ≤ 90 characters, stating what is wrong, not the process:
   "9.14.2 changelog entries and a WorkWrap Note carry inaccuracies", not
   "GlaHiCo sweep leftovers".
3. Banner, one line in italics, verbatim:

   ```
   *These items were found during an LLM-based code review (see
   "Provenance" below). I have checked each for plausibility,
   but not in depth.*
   ```

4. One sentence saying what the items have in common (found in the same
   sweep; each too small for a ticket of its own; grouped by area).
5. The items, one bullet each. With more than one area, a subsection per
   area (`### RTS`, `### Typechecker`, `### Documentation`, ...), ordered
   by area name; with one area, no subsections. Each bullet: location
   (file and function, Note or entry), what is wrong, what the correct
   text or behaviour is, "identical on master" or "branch-only", the
   introducing commit or MR, review link with the finding id. Two
   sentences plus the link is the target length.
6. Provenance, facts only:

   ```
   Found by [GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo), an
   LLM-based code-review pipeline, in a sweep of <range>. The reviews
   are linked per item; the sweep report is at <URL or TODO>.
   The draft of this ticket was also written by an LLM agent.
   ```

The writing rules of `glahico-draft-ticket` apply: every caveat once, no
justification aimed at the reviewer, facts with their source, no
severity adjectives. Report the path, the item count per area and the
suggested title, and stop.

Inputs: `SWEEP_DIR/{README.md,findings.md,triage.md,state.tsv,
snippets.tsv,buckets.tsv,sources.tsv}` as present (layouts differ between
sweeps; read the README first); run dirs from `state.tsv`; `~/ghc/work`
for git; `glab api` with `--hostname gitlab.haskell.org`, project
`ghc%2Fghc`.
