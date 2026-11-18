# GlaHiCo

Opt-in LLM code review for GHC merge requests. GlaHiCo assembles a context
pack for an MR (diff, commits, description),
runs a finder agent to look for correctness bugs, verifies each finding with
an independent verifier agent, and mechanically assembles a `review.md` with
a full disclosure header. Published reviews are available as
[snippets on sjakobi/GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo/-/snippets).
See `DESIGN.md` for the rationale.

It can also review pull requests of public GitHub repositories, such as
[haskell/cabal](https://github.com/haskell/cabal); see
[GitHub pull requests](#github-pull-requests).

## The name

GlaHiCo wants to be a bit like [sashiko](https://github.com/sashiko-dev/sashiko) —
the Linux kernel review service this borrows its shape from.

## Prerequisites

- `cabal` and GHC (`glahico.hs` is a cabal script)
- the `claude` CLI, logged in
- `glab` authenticated against `gitlab.haskell.org` (for MR targets)
- `gh` authenticated against `github.com` (for pull request targets)

## Usage

```
./glahico.hs TARGET [--finder-model ALIAS] [--verifier-model ALIAS]
             [--finder-effort LEVEL] [--verifier-effort LEVEL]
             [--prompt TEXT | --prompt-file PATH]
```

`TARGET` is one of:

- an MR number: `16419` or `!16419` (assumes ghc/ghc)
- a gitlab.haskell.org MR URL
- a github.com pull request URL
- a local commit range in the current repository: `BASE..HEAD`
  (either side may be omitted and defaults to `HEAD`)
- a single local commit: any other rev, reviewed as `REV^..REV`

Examples:

```sh
# Review a ghc/ghc MR
./glahico.hs 16419

# Review a GitHub pull request
./glahico.hs https://github.com/haskell/cabal/pull/12566

# Cheaper models and effort for a quick pass
./glahico.hs 16419 --finder-model sonnet --verifier-model sonnet \
    --finder-effort low --verifier-effort low

# Review local commits before pushing
./glahico.hs 'origin/master..HEAD'

# Point the finder at something specific
./glahico.hs 16419 --prompt 'Pay extra attention to the changed FFI code.'
```

Finder and verifier both run on model `opus` by default, at `medium` effort
(`low|medium|high|xhigh|max`).

A model `ALIAS` is passed verbatim to `claude --model`: either a short
alias like `opus`, `sonnet`, or `haiku`, or a full model ID such as
`claude-opus-4-6` (note the dashes: `opus-4.6` is rejected).

## Cost

Anecdotally, over ~160 archived runs with an opus finder at high effort,
a review costs $0.13–16 in Claude API terms, typically $3–8 (median
≈ $4.50). Data for other configurations is thin: the eight opus-medium
runs ranged $0.24–9.60. On a Claude subscription there is no per-run
bill, but a run draws the corresponding amount from the subscription's
usage limits.

Cost scales mainly with diff size, finder effort, and the number of
findings — each finding gets an independent verifier run.

A run ends by printing what it cost in the same terms, for the finder
and for the verifier calls together, taken from the `total_cost_usd`
that `claude` reports for each call. The figure includes the harness's
auxiliary haiku calls, which the review's disclosure leaves out.

## Output

The last line on stdout is the path to the finished review, e.g.
`~/glahico/runs/ghc-ghc-mr-16419/<timestamp>/review.md`. The run directory
also keeps the context pack, the raw agent envelopes, and per-finding
verdicts. All working state lives under `~/glahico/` (bare GHC mirror,
mirrors of GitHub repositories, worktrees, runs).

The review is meant to be posted verbatim: the disclosure header records the
GlaHiCo commit, target SHAs, models and effort levels used, and any
truncations, so readers can judge the output's provenance.

## Publishing

```sh
./glahico.hs publish RUN_DIR
```

posts `RUN_DIR/review.md` as a snippet on
[sjakobi/GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo/-/snippets),
titled with the review's H1, and prints the snippet URL. Visibility is
`internal` (any logged-in gitlab.haskell.org user can view and comment; the
project's own visibility caps what snippets can have). Snippet comments are
the feedback channel: `RUN_DIR/snippet.json` records the snippet id so later
tooling can poll them with the read-only glab token. While that file exists,
publishing the same run again is refused.

Linking the snippet from the MR remains a manual step. Snippets are authored
by the token's bot user, not your account.

### One-time token setup

The glab-configured token is deliberately read-only (`read_api`); snippet
creation needs the `api` scope, GitLab's only write-capable API scope. To
confine it, use a *project access token* on sjakobi/GlaHiCo (Settings →
Access tokens; role Developer, scope `api`): it authenticates as a bot
member of that one project and can't touch anything else.

Save the token where processes running as your user — coding agents
included — cannot read it. Paste it into `~/glahico/gitlab-token` with an
editor (a shell `echo` would leave the token in your history), then:

```sh
sudo chown root:root ~/glahico/gitlab-token
sudo chmod 600 ~/glahico/gitlab-token
```

`publish` reads the file via `sudo cat`, prompting for your password in the
terminal. Agent-spawned processes have no terminal, so for them sudo fails
immediately instead of exposing the token.

## GitHub pull requests

A pull request is reviewed the same way as a merge request. The differences
are in the wording of the prompts and in how the review is published.

- The repository must be public. Each one gets a mirror of its own under
  `~/glahico/mirrors/github.com/OWNER/REPO.git`, cloned over HTTPS.
- The prompts name the project under review in place of GHC, and carry none
  of the GHC-specific guidance. haskell/cabal is introduced as Cabal; any
  other repository goes by its `OWNER/REPO` name.
- `gh` only reads. The finder and verifier are tool-using agents running as
  your user, so prefer to give `gh` a token that cannot write: a fine-grained
  token with read-only access to public repositories is enough.

### Publishing

GitHub has no project snippets, so the review is posted as an issue in a
repository of your choosing:

```sh
./glahico.hs publish --reviews-repo OWNER/REPO RUN_DIR
```

This prints the issue URL. There is no default for `--reviews-repo`. Nothing
is written to the repository the pull request belongs to: linking the issue
from the pull request is a manual step, as it is for snippets. Issues in a
public repository can be read by anyone, where the snippets need a
gitlab.haskell.org account.

So that the pull request shows nothing of the review but that link, the
posted copy has its references made inert. Otherwise GitHub would add a
"mentioned this" entry to the timeline of the pull request, and of anything
else the review refers to, and notify any user it mentions. Outside code
blocks and code spans, links to github.com go through `redirect.github.com`
and a zero-width space follows the `#` or `@` of `#123` and `@user`. The
links from the summary to each finding are reduced to their text, as GitHub
gives the headings of an issue no anchors to link to. A note appended to
the issue says so; `review.md` in the run directory is left as generated.

To see the title and body that would be posted, without posting:

```sh
./glahico.hs publish --dry-run RUN_DIR
```

To make the issue by hand instead, with no token, write that copy to files:

```sh
./glahico.hs publish --issue-file RUN_DIR
```

This writes the body to `issue.md` and the title to `issue-title.txt` in
the run directory, prints the two paths, and posts nothing. Paste the body
from `issue.md`, not from `review.md`, or the pull request will show that
the issue mentions it. The title has a zero-width space after its `#`, so
that it does not link to an issue of that number in the reviews repository;
copy it from the file to keep it.

### One-time token setup

Create a fine-grained personal access token whose only permission is read
and write access to Issues on the reviews repository. Save it as
`~/glahico/github-token` and make it root-only, as described for the GitLab
token above.
