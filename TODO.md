# TODO

Observations from the 2026-07-29 implementation session (branch `glahico-script`):

- **Experiment: opus-medium vs. opus-high for the finder.** No evidence yet
  that high effort finds more: ~158 archived runs are opus-high vs. 8
  opus-medium, and the only same-target pair (!16452) is confounded by the
  MR changing between runs. High-effort no-findings runs cost $5–6; the one
  opus-medium no-findings MR run cost $0.24. Plan: rerun a sample of past
  opus-high runs with confirmed findings at opus-medium against the same
  pinned SHAs (recorded in the disclosure) and measure how many findings
  medium recovers. ~60+ candidate runs exist; ten targets ≈ $25–40.

- Turn a landed-patch check directly into an issue-tracker ticket, without
  the intermediate review report. Reviewing a landed commit already works
  (`CommitTarget`), and glahico-file-issue drafts tickets with reproducers,
  but the flow still goes review run → finding → ticket.

- Near the title, mention HEAD commit and when the review was generated

- Simon needs to test prompt additions!

- Consider having the finder report test-coverage issues too. Currently
  `prompts/finder.md` lists missing tests as out of scope; lift that once the
  core review flow is solid.

- Add a command that reruns the report generation on existing review artifacts
  (for testing "UI" changes)

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

- **Retry `publish` on Anubis challenge.** gitlab.haskell.org intermittently
  serves an Anubis anti-bot HTML page ("Making sure you're not a bot!") on
  API requests, so the snippet POST can fail with a JSON parse error on
  `<!doctype html>`. Detect a non-JSON response and retry a few times with a
  short backoff (token is read once up front, so no repeated sudo prompts).
  Safe to retry the POST: Anubis blocks before GitLab sees the request, so
  the HTML page means the snippet was not created. (Observed 2026-08-06.)

- **Make reproducers more prominent in GlaHiCo-derived tickets** (e.g. those
  created by glahico-file-issue). See
  https://gitlab.haskell.org/ghc/ghc/-/work_items/27658#note_691258.
