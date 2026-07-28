Prompt: What would it take to adapt this system so it can be used e.g. for the GHC Haskell compiler

Short version: the Rust plumbing is ~85% domain-agnostic and the kernel-specific parts are concentrated in two places — one file of hardcoded stage prompts, and the prompt bundle. The hard part isn't the port, it's authoring a GHC `false-positive-guide.md` that's as good as the kernel one.

## What ports for free

- **Ingestion of local git**: `sashiko-cli review <range>` / `--repo` (`src/bin/sashiko-cli.rs:1423-1520`) works on any git repo. Patch parsing is mbox/`git format-patch`-shaped, not C-shaped.
- **GitLab forge + webhooks** (`src/forge.rs:289-440`) — GHC lives on gitlab.haskell.org, so the MR-webhook path is the natural entry point, and it's already there (flagged experimental).
- **Toolbox**: `git_grep`, `git_blame`, `git_log`, `git_show`, `git_read_files`, `git_find_files` — no language assumptions anywhere in `src/toolbox/`.
- **Stage orchestration, the `concerns`/`dismissed_concerns` JSON contract with retry** (`src/worker/stage.rs:101-109,252`), DB, web UI, all LLM providers.
- **`--prompts <path>`** already exists on `serve`/`review` (`src/main.rs:126,162,291`), and `append_file` silently skips missing files (`src/worker/prompts.rs:368-370`), so an incomplete bundle degrades instead of crashing.
- **The benchmark harness** (`src/bin/benchmark.rs`) is generic: it takes JSON of `{commit, fixed_by, problem_description}` and uses an LLM judge. Only the dataset is kernel-specific.

Upstream review-prompts already ships `systemd/` and `iproute/` bundles alongside `kernel/` (`third_party/prompts/README.md`), so multi-project was anticipated — sashiko just never grew the switch.

## Rust changes needed (small, mechanical)

1. `src/worker/prompts.rs:162,169` — base persona is literally "You are an expert Linux kernel maintainer".
2. `src/worker/prompts.rs:222-320` — stages 1–7 are hardcoded kernel C prose (DMA barriers, `kmalloc`, RCU, `copy_to_user`). This is the bulk of the edit.
3. `src/worker/prompts.rs:332-352` — per-stage file appends (`callstack.md`, `subsystem/locking.md`, `false-positive-guide.md`, `severity.md`, `inline-template.md`); the names are fine, the contents aren't.
4. `src/worker/prompts.rs:560` — Phase 0 pre-screening prompt says "Linux kernel patch review" and needs a `subsystem/subsystem.md` trigger index.
5. `src/worker/prompts.rs:717-723` — the planning phase that picks which of stages 4–7 to run, described in kernel terms.
6. `src/prompt_bundle.rs:22-24` + `src/main.rs:912-917` — `default_kernel_prompts_path()` hardcodes `root.join("kernel")`. Wants a `project = "ghc"` setting.
7. `src/baseline.rs` — parses `MAINTAINERS` to resolve which tree a patch targets. GHC has no such file; for MR-driven review the baseline is just the MR target branch, so this mostly gets bypassed rather than rewritten.
8. Email path (`src/main.rs:2240-2246` vger list mapping, NNTP/lore ingestion) — GHC doesn't do mailing-list patches. Drop it; `email_policy.toml` ships `mute_all = true` anyway.

## The actual work: the GHC bundle

You need GHC analogues of `review-core.md`, `technical-patterns.md`, `severity.md`, `inline-template.md`, `callstack.md`, `subsystem/*.md` + the index, and above all `false-positive-guide.md`. The kernel one is 495 lines of *enumerated* noise patterns with carve-outs (missing return checks are real bugs — except in `__init`, debugfs, teardown, and `(void)`-cast calls). GHC's noise list is completely different and doesn't exist yet. Candidates: "add a bang here for strictness" without a demonstrated leak, "this partial pattern match could fail" where the invariant is established by a preceding `Note`, "this `error` call is unsafe" in genuinely-unreachable compiler-panic positions, suggested `Data.Map` → `IntMap` micro-optimizations, and Haskell-shaped totality pedantry generally.

Stage remapping I'd propose:

| Kernel stage          | GHC replacement                                                                                                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 4 Resource management | Laziness/strictness: thunk and space leaks, `foldl` vs `foldl'`, missing bangs in accumulators, `unsafePerformIO`/`NOINLINE` pairing, `ForeignPtr` lifetimes                          |
| 5 Locking             | Split: `MVar`/`STM` deadlock and `IORef` races in the compiler; the RTS keeps something close to the kernel locking guide                                                             |
| 6 Security audit      | Replaced by **semantics preservation**: does this Core-to-Core transform preserve semantics, arity, demand, and Lint invariants? Unsafe coercions, levity/representation polymorphism |
| 7 Hardware review     | Maps surprisingly well onto **backend/codegen**: Cmm invariants, NCG per-arch, calling conventions, tag bits, info tables, stack layout, ABI                                          |

Subsystem guides worth writing: renamer, typechecker/constraint solver, desugarer, simplifier + occurrence analysis + join points + arity/demand, STG, Cmm, NCG (per arch), RTS (GC, scheduler, STM, weak pointers, linker), Template Haskell, GHCi/bytecode, `hs-boot` and recompilation avoidance, Hadrian, testsuite, `base`/boot libraries.

## GHC-specific hazards the kernel design doesn't cover

- **Two languages in one tree.** `compiler/` is Haskell, `rts/` is C. Stage selection has to route on that, and the FP guide effectively needs two halves.
- **Notes are load-bearing.** GHC's `Note [Title]` convention is a first-class invariant store. A GHC-specific stage or check — "does this patch contradict, or fail to update, a `Note` it depends on?" — would be genuinely high-value and has no kernel analogue.
- **Checklist items with near-zero FP risk** that are worth their own cheap stage: missing `changelog.d/` entry, missing `testsuite/` regression test for a `Fixes #NNNN` commit, stale `.stderr` expected output, missing users-guide update, `base` changelog/haddock for exported API changes.
- **Performance tests**: GHC has perf baselines that patches shift; "did this need a metric update" is checkable but noisy.
- **Ground truth for benchmarking**: no `Fixes:` tag convention. Use commits whose message closes a ticket *and* add a `testsuite/tests/` regression test — the added test is a strong signal, and the ticket often names the introducing MR. That gives you the `{commit, fixed_by, problem_description}` triples `benchmark.rs` wants.

## Phasing

Get a signal cheaply first: point `--prompts` at a hand-written minimal GHC bundle (review-core + FP guide + 2–3 subsystem guides), run `sashiko-cli review` over a few dozen known-buggy commits, and judge with the existing benchmark harness before touching any Rust. If detection looks plausible, then do the `project` config plumbing and the GitLab webhook wiring.

Rough effort: a few days for the Rust changes and CLI-level bring-up; the prompt bundle is the multi-week item, and the FP guide specifically wants a GHC contributor's judgment, not an LLM's first draft.
