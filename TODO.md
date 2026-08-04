# TODO

Observations from the 2026-07-29 implementation session (branch `glahico-script`):

- A tool that runs glahico on (selected) merged MRs

- A command to generate a reproducer for a given finding

- A command that drafts a ticket from a finding and a reproducer

- Near the title, mention HEAD commit and when the review was generated

- Simon needs to test prompt additions!

- Add a command that reruns the report generation on existing review artifacts

- Consider (network) access via glab so the agents can lookup relevant issues.

- Consider re-adding MR discussion and linked issues to the context pack
  (fetching removed 2026-07-31 because the prompts no longer referenced
  `discussion.md`/`issues/`). If re-added, the prompts need matching
  `[MR targets only]` pointers so local-range runs aren't sent to files
  that don't exist.

- **`-dirty` fires on untracked files.** The disclosure's glahico-commit
  suffix comes from `git status --porcelain`, so an untracked file like this
  TODO.md marks the run `-dirty` even though nothing that affects the built
  script or prompts changed. Consider restricting to tracked-file changes
  (`git status --porcelain --untracked-files=no`) — or keep as the
  conservative/honest choice.

- **Odd phrasing at zero findings.** The disclosure line "Findings: 0
  reported by the finder, all verified" reads strangely when there was
  nothing to verify; ditto "Verifier: … ran no calls".

Verification steps from the implementation plan: all complete (2026-07-29).
Step 4: bogus `--finder-model` → claude exits 1, raw envelope preserved with
the API error, replayable argv printed, glahico exits 1. Step 5: full review
of !16419 at low effort → 0 findings, correct review.md
(`~/glahico/runs/ghc-ghc-mr-16419/20260729T143450`).
