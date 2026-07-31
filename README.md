# GlaHiCo

Opt-in LLM code review for GHC merge requests. GlaHiCo assembles a context
pack for an MR (diff, commits, description),
runs a finder agent to look for correctness bugs, verifies each finding with
an independent verifier agent, and mechanically assembles a `review.md` with
a full disclosure header. Published reviews are available as
[snippets on sjakobi/GlaHiCo](https://gitlab.haskell.org/sjakobi/GlaHiCo/-/snippets).
See `DESIGN.md` for the rationale.

## Prerequisites

- `cabal` and GHC (`glahico.hs` is a cabal script)
- the `claude` CLI, logged in
- `glab` authenticated against `gitlab.haskell.org` (for MR targets)

## Usage

```
./glahico.hs TARGET [--finder-model ALIAS] [--verifier-model ALIAS]
             [--finder-effort LEVEL] [--verifier-effort LEVEL]
             [--prompt TEXT | --prompt-file PATH]
```

`TARGET` is one of:

- an MR number: `16419` or `!16419` (assumes ghc/ghc)
- a gitlab.haskell.org MR URL
- a local commit range in the current repository: `BASE..HEAD`
  (either side may be omitted and defaults to `HEAD`)

Examples:

```sh
# Review a ghc/ghc MR
./glahico.hs 16419

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

## Output

The last line on stdout is the path to the finished review, e.g.
`~/glahico/runs/ghc-ghc-mr-16419/<timestamp>/review.md`. The run directory
also keeps the context pack, the raw agent envelopes, and per-finding
verdicts. All working state lives under `~/glahico/` (bare GHC mirror,
worktrees, runs).

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
included — cannot read it:

```sh
echo glpat-... > ~/glahico/gitlab-token
sudo chown root:root ~/glahico/gitlab-token
sudo chmod 600 ~/glahico/gitlab-token
```

`publish` reads the file via `sudo cat`, prompting for your password in the
terminal. Agent-spawned processes have no terminal, so for them sudo fails
immediately instead of exposing the token.
