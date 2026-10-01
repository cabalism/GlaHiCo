# GlaHiCo bot — working notes

Bot account on gitlab.haskell.org: `@glahico-bot-unofficial`.
Purpose: let GHC MR authors request GlaHiCo reviews without pinging Simon.

## Status (2026-10-01)

- Workflow below is accepted as the plan.
- Account created: https://gitlab.haskell.org/glahico-bot-unofficial,
  user id 146625, display name "GlaHiCo Bot". Primary email
  simon.t.jakobi+glahico-bot@proton.me (see "Email for the bot account").
  Reporter on sjakobi/GlaHiCo since 2026-10-01. Reporter on ghc/ghc
  requested from a GHC maintainer 2026-10-01, pending.
- Bot personal access token (`api` scope) created 2026-10-01, stored
  root-owned at `~/glahico/bot-token`. Expires 2027-10-01.
- Instance: GitLab 18.11.12-ee. ghc group does not require 2FA.
- No code yet: `bot poll/run/post` are not implemented.

## Requesting a review

Two ways to trigger, both usable **only by the MR author**:

1. Comment `@glahico-bot-unofficial review` on the MR. This is also the
   way to request every subsequent review.
2. Add `@glahico-bot-unofficial` as a reviewer (first review only; see
   below for why there is no re-request button).

Requests from anyone other than the author are ignored (perhaps with a
short reply saying so). Rationale: keeps cost opt-in and controlled by the
person who owns the MR.

## What the bot can and cannot do as Reporter (verified 2026-10-01)

What matters: learning about a request and being able to post a review.
Both work. Verified on sjakobi/GlaHiCo!3, GitLab 18.11:

- Author adds the bot as reviewer -> pending to-do on the bot account
  (`action_name: review_requested`), plus a system note "requested
  review from @glahico-bot-unofficial".
- Comment mentioning the bot -> to-do with `action_name:
  directly_addressed` (mention at the start of the comment) or
  `mentioned` (elsewhere in the text); accept both. The to-do's `body`
  carries the comment text, so the poller can check for "review" there.
  List with REST `GET /todos?type=MergeRequest`.
- Bot posts a comment on the MR under its own name (REST `POST .../notes`
  suffices; the draft-note route also works). The comment auto-completes
  the bot's pending to-do for that MR, so `mark_as_done` is only needed
  on paths where the bot posts nothing.
- Bot cannot set reviewers (PUT on the MR -> 403; needs Developer), so
  after a mention-triggered review it cannot add itself to the sidebar.
  Stay at Reporter anyway: Developer would also unlock approving and
  pushing.

Reviewer state is not important for the workflow and not controllable:
there is no API on this instance that moves the caller to REVIEWED or
REVIEW_STARTED (no GraphQL mutation; draft notes and `bulk_publish` do
not change it). APPROVED and REQUESTED_CHANGES are reachable but off
limits: approvals feed merge rules, and reviews are labelled tool output
(see DESIGN.md). The bot therefore stays UNREVIEWED on every MR, shown
as "awaiting review" in the sidebar, and GitLab offers the author no
"re-request review" button for such a reviewer (confirmed on !3). Hence
the mention comment is the re-trigger; remove-and-re-add the reviewer
would also work but is not worth documenting.

Read-side: GraphQL
`mergeRequest.reviewers.nodes.mergeRequestInteraction.reviewState`, or
REST `GET .../merge_requests/:iid/reviewers`.

glab notes: `glab api graphql` turns any `__type` query into a full
`__schema` dump; pipe through jq. `--input` bodies need an explicit
`-H "Content-Type: application/json"`.

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

`bot run` records the run dir in the request file and marks `generated`
on success. (Reviewer state REVIEW_STARTED is not settable via API.)

### Push

`glahico.hs bot post TODO_ID` or `--all` for everything in `generated`:

1. Publish the snippet (existing code path; snippet.json guards
   against double publish).
2. (Dropped: the bot cannot add itself as reviewer at Reporter. The
   footer text covers it instead.)
3. Post one MR comment: review H1, snippet link, models/effort used, and
   a fixed footer: "To request another review after pushing, comment
   `@glahico-bot-unofficial review`."
4. Status `posted`. The comment auto-completes the bot's to-do; reviewer
   state stays UNREVIEWED (not settable via API).

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

## Email for the bot account

Current thinking (2026-10-01). What the address does, by job:

1. Registration + account recovery: rare mail, but the mailbox must stay
   under control for years. Dormant free mailboxes get deleted (Proton,
   Disroot after ~1 year; Gmail after 2), so a dedicated never-visited
   mailbox is a liability. Use an address on a mailbox Simon actively
   uses; a plus-address on the current personal account is fine (GitLab
   treats it as distinct and verifies it). Changing the account email
   later is trivial.
2. Notifications as wake-up signal: redundant with the to-do API; only
   useful if they land in an inbox Simon already reads. GitLab allows a
   separate notification email, so route via filter into the main inbox.
   Keep the global level at Participate (default): it is the only level
   that delivers review requests and comments on reviewed MRs. Custom
   only *adds* events on top of Participate, and On mention drops both.
   The price is mail for every push/merge/close on every reviewed MR;
   prune those with client-side filters, not in GitLab.
3. Follow-up discussion on posted reviews: participants get mail but no
   to-do unless mentioned. Email is the free feedback archive here; the
   alternative is polling notes on each reviewed MR.
4. IMAP / scripted consumption: not a requirement. Mail as trigger is
   wrong (spoofable; API must re-verify anyway). Possible later for
   archiving feedback. Webhooks are out (need Maintainer on ghc/ghc).

Conclusion: no separate mailbox, no paid provider. Durable address on
the active inbox + filter. Check whether the ghc group enforces 2FA for
members; if so, store recovery codes safely.

## Edge cases

- Bot removed as reviewer mid-run: treat as cancel, suppress the post.
- Draft MRs: reviewed like any other; say so in the docs.
- Optional later: a mention comment may carry `--prompt`-style hints
  ("pay attention to the FFI changes"). Leave out of the first announcement.

## Open items

- Wait for Reporter on ghc/ghc (requested 2026-10-01).
- Leave notification level at Participate; decide whether notifications
  go to Proton or Gmail, and set up client filters for push/merge noise.
- Where to document for GHC devs: wiki page first; MR template comment once proven.
