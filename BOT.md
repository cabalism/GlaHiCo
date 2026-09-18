# GlaHiCo bot — working notes

Bot account on gitlab.haskell.org: `@glahico-bot-unofficial`.
Purpose: let GHC MR authors request GlaHiCo reviews without pinging Simon.

## Status (2026-09-18)

- Workflow below is accepted as the plan.
- Account not created yet. Simon can register the name; undecided what
  kind of account to use (plain user account vs. project/group access
  token bot). A plain user is needed to be addable as an MR reviewer on
  ghc/ghc and to hold to-dos; project access tokens only act within their
  own project.
- No code yet: `bot poll/run/post` are not implemented.

## Requesting a review

Two ways to trigger, both usable **only by the MR author**:

1. Comment `@glahico-bot-unofficial review` on the MR.
2. Add `@glahico-bot-unofficial` as a reviewer. For later reviews, use
   GitLab's "re-request review" button on the reviewer entry.

Requests from anyone other than the author are ignored (perhaps with a
short reply saying so). Rationale: keeps cost opt-in and controlled by the
person who owns the MR.

## Reviewer state as protocol

GitLab tracks a per-reviewer state. Use it end to end:

- unreviewed = queued (set by adding the bot or re-requesting review)
- review started = a run is in progress (set by the bot when it picks up)
- reviewed = review posted (set by the bot when done)

Never approve, never "request changes": approvals feed merge rules, and
reviews are labelled tool output (see DESIGN.md).

Setting state is GraphQL only (no REST endpoint); the token must be the
bot's, since a reviewer may only change their own state:

```sh
glab api graphql -f query='
mutation {
  mergeRequestUpdateReviewerState(input: {
    projectPath: "ghc/ghc",
    iid: "16419",
    userId: "gid://gitlab/User/<BOT_USER_ID>",
    state: REVIEW_STARTED       # or REVIEWED
  }) { errors }
}'
```

Verify `REVIEW_STARTED` exists on the instance before relying on it
(added in GitLab 16.x; settable set has changed across versions):

```sh
glab api graphql -f query='{ __type(name: "MergeRequestReviewState") { enumValues { name } } }'
```

If missing, only use unreviewed/reviewed.

For the comment trigger there is no reviewer state to flip unless the bot
is also a reviewer. Option: on `@glahico-bot-unofficial review`, the bot
adds itself as reviewer and then proceeds as above, so both paths converge.

## Workflow (phase 1: human in the loop)

### Learning about requests

- Set the bot account's notification email to an address Simon reads:
  GitLab mails on every assignment, re-request, and mention.
- `glahico.hs bot poll` (bot token): reads the bot's pending to-dos.
  Assignment/re-request -> action `review_requested`; comment trigger ->
  `mentioned` / `directly_addressed`. For each, fetch the MR, check the
  requester is the MR author, and print a table: MR, title, trigger,
  head SHA, diff size, previous reviews of that MR.

### State

One JSON file per request in `~/glahico/bot/requests/<todo-id>.json`.
The to-do id is the key: each re-request creates a fresh to-do, and the
to-do stays pending in GitLab until the bot marks it done, so nothing is
lost if a local file goes missing. Fields: MR iid, head SHA, trigger,
requester, status, and once known the run dir and models/effort used.

Status: `pending` -> `running` -> `generated` -> `posted`, or `skipped`
(with a reason: non-author, duplicate SHA, diff too large, ...).

### Deciding models and effort, then running

Per-request human decision, driven by the poll table.

`glahico.hs bot run TODO_ID [--finder-model ID] [--finder-effort L]
[--verifier-model ID] [--verifier-effort L]`, `--all` for every pending
request with defaults.

Defaults for the bot path are pinned full model IDs, never aliases, so
the models don't drift by accident; the bot path refuses bare aliases.

- verifier: `claude-fable-5-1`, medium
- finder: opus at high effort (pinned full ID of the current opus).
  Most cost data is for this configuration.

Fable has a track record of better findings in some cases, at least one
typechecker MR. Eventually a simple rule-based choice (e.g. by touched
subsystem or diff size) may pick fable for the finder; not now. Until
then, per-request overrides on `bot run`.

The interactive `--finder-model`/`--verifier-model` flags keep their
`opus` alias defaults.

`bot run` sets reviewer state REVIEW_STARTED when the bot is a reviewer,
records the run dir in the request file, marks `generated` on success.

### Push

`glahico.hs bot post TODO_ID` or `--all` for everything in `generated`:

1. Publish the snippet (existing code path; snippet.json guards
   against double publish).
2. If triggered by mention, add the bot as reviewer so the re-request
   button exists.
3. Post one MR comment: review H1, snippet link, models/effort used, and
   a fixed footer: "To request another review after pushing, click
   re-request review on @glahico-bot-unofficial in the Reviewers list, or
   comment `@glahico-bot-unofficial review`."
4. Set reviewer state REVIEWED, mark the to-do done, status `posted`.

Ordered so that a crash midway is recoverable by re-running; the request
status says where it stopped.

Open: link only (current plan) vs. embedding the full review in the MR
comment. Linking keeps the thread short; embedding puts feedback in the
MR.

### Dedupe on head SHA

At poll time, if the MR head matches the last posted review for that MR,
mark `skipped`; `bot post` leaves a one-line comment pointing at the
previous review and closes the to-do. Consider the same for pure rebases
with an unchanged diff.

### Non-author requests

Marked `skipped` at poll time. Initially reply nothing (avoid noise);
reconsider if people are confused.

### Token

Bot token needs `api` scope. Store like the snippet token: root-owned,
`~/glahico/bot-token`.

### Phase 2

Unattended polling with a per-day run cap, once the queue is quiet
enough to trust.

## Edge cases

- Bot removed as reviewer mid-run: treat as cancel, suppress the post.
- Draft MRs: reviewed like any other; say so in the docs.
- Optional later: a mention comment may carry `--prompt`-style hints
  ("pay attention to the FFI changes"). Leave out of the first announcement.

## Open items

- Get the bot's numeric user id (`GET /user` with the bot token).
- Check GitLab version on gitlab.haskell.org for reviewer-state support.
- Where to document for GHC devs: wiki page first; MR template comment once proven.
