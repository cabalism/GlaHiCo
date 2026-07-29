# GlaHiCo

Opt-in LLM code review for GHC merge requests. GlaHiCo assembles a context
pack for an MR (diff, commits, description, discussion, referenced issues),
runs a finder agent to look for correctness bugs, verifies each finding with
an independent verifier agent, and mechanically assembles a `review.md` with
a full disclosure header. See `DESIGN.md` for the rationale and details.

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

The finder runs on model `fable` and the verifier on `opus` by default, both
at `medium` effort (`low|medium|high|xhigh|max`).

## Output

The last line on stdout is the path to the finished review, e.g.
`~/glahico/runs/ghc-ghc-mr-16419/<timestamp>/review.md`. The run directory
also keeps the context pack, the raw agent envelopes, and per-finding
verdicts. All working state lives under `~/glahico/` (bare GHC mirror,
worktrees, runs).

The review is meant to be posted verbatim: the disclosure header records the
GlaHiCo commit, target SHAs, models and effort levels used, and any
truncations, so readers can judge the output's provenance.
