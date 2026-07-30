# TODO

Observations from the 2026-07-29 implementation session (branch `glahico-script`):

- Invite feedback near the top of the review document

- Simon needs to test prompt additions!

- Consider (network) access via glab so the agents can lookup relevant issues.

- **Finder prompt references `discussion.md` on local runs.** The sentence
  "Check {ctx}/discussion.md before reporting …" in `prompts/finder.md` is not
  tagged `[MR targets only]`, so local-range runs still point the finder at a
  file that doesn't exist. Harmless but sloppy; making it conditional needs
  either tags on both prose lines or tag-stripping for MR runs.

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
