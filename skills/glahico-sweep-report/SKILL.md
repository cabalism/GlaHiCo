---
name: glahico-sweep-report
description: >
  Draft the sweep report for a finished GlaHiCo sweep: a markdown document,
  published as a snippet in the GlaHiCo project, that records which commits
  the sweep covered and what became of every finding. Never publishes it.
  Usage: /glahico-sweep-report SWEEP_DIR
  (e.g. /glahico-sweep-report ~/glahico/sweeps/ghc-9.14.2-rc2).
---

# GlaHiCo sweep → draft sweep report

Vocabulary, used the same way in the draft and in what you say:

- sweep: one GlaHiCo pass over every commit in a range, split into groups.
- group: one target spec (a commit or a commit range), one run dir, one
  review.
- review: a group's `review.md`, published as a GitLab snippet.
- finding: one numbered item of a review (`f1`, `f2`, ...). A finder
  report the verifier dropped before publication is not a finding: it
  appears in the review only as a count in the Disclosure section, and
  nobody looked at it after the verifier.
- remaining-findings ticket: the bundled GHC issue for the findings too
  small for a ticket of their own, made by `glahico-remaining-findings`.
- sweep report: the document drafted here. Never call it a review, and
  never call a review a report.

Task: write `SWEEP_DIR/sweep-report.md`, with a coverage table for the
whole sweep and one line per finding saying what became of it. Simon
publishes it with `glahico publish SWEEP_DIR/sweep-report.md`, which
uploads the file verbatim as a snippet (title from the first `# `
heading) and writes `snippet.json` next to it. So the file contains
nothing addressed to Simon; open points go into the final message.

The report records decisions already made in `triage.md` and
`remaining-findings.md`; it does not reopen them. If a disposition looks
wrong, say so in the final message and draft it as decided.

Pre-checks, before any other work:

- `SWEEP_DIR` has `state.tsv`, `findings.md` and `triage.md`. Without a
  `triage.md`, stop: triage comes first.
- Every group with status `done` has a published review: a row in
  `snippets.tsv`, or `snippet.json` in its run dir. If any is missing,
  stop and ask Simon to run `publish-reviews.sh` — the report links every
  review, and a report with unlinkable rows is not worth drafting.
- Every finding in `findings.md` has a disposition (see "Dispositions").
  List the undecided ones and stop. Verifier-dropped items need none.
- No draft exists yet. If `SWEEP_DIR/sweep-report.md` is there, stop and
  point to it; never overwrite it.

Hard policies:

- **Draft only, never publish.** Publishing is Simon's action. Don't post
  anything.
- **Verify before you claim.** Issue and MR numbers, titles and states
  come from the GitLab API, not from the notes. Snippet URLs come from
  `snippets.tsv` or `snippet.json`. Commit counts, SHAs and the parent of
  the range come from git in `~/ghc/work`. A finding's one-line fact
  comes from its `verdicts/<fid>.json`, not from the paraphrase in
  `findings.md`.
- **No new investigation.** Don't re-verify findings, build reproducers,
  or search for duplicates; that was done before triage and by
  `glahico-remaining-findings`. The report is bookkeeping.
- **Explicit links only.** The snippet's file view renders markdown
  without resolving references: `#27833`, `ghc/ghc!16722` and
  `ghc/ghc@<sha>` all stay plain text there (they do link in issue
  previews, which is misleading). So every reference is a markdown link
  with an absolute URL, the reference as its text:
  `[ghc/ghc#27833](https://gitlab.haskell.org/ghc/ghc/-/issues/27833)`,
  `[ghc/ghc!16722](.../ghc/ghc/-/merge_requests/16722)`,
  `[ghc/ghc@9033629ce22](.../ghc/ghc/-/commit/9033629ce22)`, and for a
  range `[ghc/ghc@<parent>...<last>](.../ghc/ghc/-/compare/<parent>...<last>)`
  with three dots and the resolved parent (`git rev-parse 'X^{commit}'`
  for tags). Snippet links are full URLs too.
- **Title** `GlaHiCo sweep report: <range>`. The range is the one the
  sweep README uses, tags where they exist
  (`ghc-9.14.2-rc1..ghc-9.14.2-rc2`), otherwise `<branch> <start>..<end>`
  or the MR (`!16629`).

Dispositions — where each finding's fate is recorded, and the section of
the report it goes to:

- own ticket, filed: `triage.md` names the issue → **Filed**.
- bundled: `remaining-findings.md` says `actionable: yes` and `triage.md`
  or the metadata of `SWEEP_DIR/tickets/remaining-findings.md` names the
  issue → **Bundled**. If the bundled ticket isn't filed yet, write the
  items with `ghc/ghc#TODO` and say in the final message that the report
  must not be published before the number is in.
- fixed by an MR or commit that came out of the sweep (`no — fixed by
  !N` with a date on or after the sweep, or `triage.md` says so) →
  **Fixed directly**.
- reported on a tracking ticket or MR (`triage.md` names the channel) →
  **Reported elsewhere**. If the comment doesn't exist yet, draft it as
  `SWEEP_DIR/<channel>-comment.md` (e.g. `tracking-comment.md`), keep it to
  the branch-only facts plus a review link, and write `TODO: link` in the
  report line.
- refuted, duplicate, already fixed before the sweep acted, moot, or
  nothing to change (`triage.md` "Dropped", or `actionable: no — ...`
  other than the case above) → **Not pursued**.
- own ticket not filed yet (`separate — ...` without an issue number, or
  a triage entry without a number) → undecided; stop in the pre-check.
- dropped by the verifier (`findings.md` or the review's Disclosure says
  "refuted" or "dropped" for an id the review has no section for) → not
  a finding. No line in any section, no id in the coverage table, no
  count anywhere. `findings.md` may still count these, so recount from
  the reviews. A published finding that triage refuted afterwards
  is a finding and goes to **Not pursued**.

Writing rules — the reader is a maintainer or release manager who wants
to know what was looked at and what came of it:

- One line per finding, two at most. The disposition carries the weight;
  no adjectives about severity or confidence.
- A Filed or Fixed directly line is the reference, its title and the
  finding id, nothing more: the issue or MR carries the branch facts, and
  the coverage table links the review. Only a Not pursued line adds the
  master/branch fact and the review link, since nothing else records
  them.
- No re-summarising the reviews. Where a line has to say what the finding
  is (Bundled, Not pursued), it uses the review's own terms.
- Every number in the Scope paragraph must match the coverage table.
- The rules of `glahico-draft-ticket` apply as well: every caveat once,
  no justification aimed at the reviewer, no lists a reader would feel
  obliged to check beyond the coverage table itself.

Report structure, in this order:

1. Title, as the first line: `# GlaHiCo sweep report: <range>`.
2. Lead — one sentence: what was reviewed (branch, range) and by what
   ([GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo), an LLM-based
   code-review pipeline). No caveats here; the footer covers the
   report's own origin.
3. Scope — one short paragraph: number of commits with the compare link,
   that they were grouped by source MR, how many groups were reviewed
   and how many skipped (the reasons are in Coverage, not here), and the
   number of findings, published ones only, in this form: "The reviews
   resulted in 11 findings, spread across 5 groups." Reviews don't
   "report"; the findings result from them.
4. Findings — one line each, under these headings in this order, empty
   ones omitted:
   - **Filed**: `ghc/ghc#N` — issue title (group and finding id).
   - **Bundled**: `ghc/ghc#N` (the remaining-findings ticket) once, then
     one line per item: what it is (group and finding id).
   - **Fixed directly**: `ghc/ghc!N` — MR title (group and finding id).
   - **Reported elsewhere**: where, with the link (group and finding
     id).
   - **Not pursued**: group and finding id; what it is; what the check
     showed, in one line (e.g. "refuted: the test does fail on an
     unfixed RTS, in a later GC"; "already fixed on the branch by
     ghc/ghc@<sha>"; "moot: release prep rewrote the entry"; "commit
     message only, nothing to change in the tree"); "identical on
     master" or "branch-only" where the check established it; the
     review link with the finding id.
5. Coverage — a table of reviewed groups: group | commits | source MR |
   subject | outcome | review. `commits` is the branch SHA, or for a
   range the compare link (see "Explicit links only") with the count in
   parentheses (the parent's short SHA is the first one in the run dir's
   slug; confirm with `git rev-parse`); `subject` is the first commit's;
   `outcome` is "no findings" or the finding ids with their section above
   (e.g. "f1 filed, f2 not pursued"); `review` is the snippet number,
   linked. Then the skipped groups with their reason, as a list. Wrap a
   table longer than about 15 rows in `<details>` with a summary line
   giving the count, and a blank line after `</summary>`. The section
   closes with this plain sentence: "The pipeline commit, models,
   effort and token counts of each review can be found in its
   Disclosure section." No Method section: the Disclosures carry it.
6. Footer — a horizontal rule, then one italic line: "This report was
   drafted by an LLM agent from the sweep's records."

Final message: the path; counts per section; every `TODO` left in the
file; dispositions that disagree between `triage.md`, `state.tsv`,
`remaining-findings.md` and GitLab; and what to do after publishing —
put the snippet URL into the remaining-findings ticket's provenance and
into `triage.md`, and where the report could be linked from (the release
tracking ticket, label `T::release tracking`, for a backport sweep).

Inputs to consult:

- `SWEEP_DIR/README.md` — scope, range, batches, models. Sweep dirs differ
  in layout (rc1: `triage.tsv`; rc2: `sources.tsv`; 9.12.5-rc4: tiers and
  `coverage.tsv`), so read the README first and take the file list from
  there.
- `SWEEP_DIR/state.tsv` — one row per group: status, target spec, short
  SHAs, titles, run dir, outcome. The coverage table is built from it.
- `SWEEP_DIR/findings.md`, `triage.md`, `remaining-findings.md` — the
  findings and their dispositions. `triage.md` is authoritative for own
  tickets and dropped findings, `remaining-findings.md` for the rest;
  `state.tsv` outcomes may lag behind both.
- `SWEEP_DIR/snippets.tsv` — review URLs. `sources.tsv` or `worklist.json`
  — master source SHAs and source MRs, where the sweep recorded them.
- Run dirs: `verdicts/<fid>.json` for the finding facts, `tickets/<fid>.md`
  for the draft a filed issue came from.
- GitLab: `glab api "projects/ghc%2Fghc/issues/<N>" --hostname
  gitlab.haskell.org`, likewise `merge_requests/<N>`.
- `~/ghc/work` is **read-only** (fetch, `git log`, `git rev-parse` are
  fine; never check anything out).
