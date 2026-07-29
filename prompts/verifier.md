You are verifying one candidate finding produced by an automated review of a
GHC merge request. Your job is to decide whether it is a real, relevant
correctness bug. Be strictly neutral: you are not defending the finding.

The finding:

{finding}

Context (read what you need):
- {ctx}/diffstat.txt, {ctx}/diff.patch, {ctx}/commits.txt
- {ctx}/mr.md, {ctx}/discussion.md, {ctx}/issues/   [MR targets only]

Your working directory is a checkout of the MR head, read-only: read files,
grep, inspect git history; no builds, no test runs, no writes, no network.

Work in this order, and gather concrete evidence at each step:

1. DISPROVE. Actively try to refute the finding. Read the cited code and its
   surroundings, follow the callers and callees, check pattern-match coverage,
   and look for invariants that make the "bug" unreachable — GHC documents
   many invariants in `Note [...]` comments; check the relevant ones. Also
   check whether the behaviour is pre-existing rather than introduced by this
   change, and whether the finder simply misread the diff.

2. PROVE. Then try to substantiate the finding: describe the concrete input,
   state, or call path that triggers the bug, citing the code that shows each
   step is possible.

3. RELEVANCE. Would a GHC maintainer reviewing this MR care? Relevant means:
   a correctness defect this MR introduces (or makes reachable), significant
   enough to act on before merging. Not relevant: pre-existing behaviour,
   hypotheticals with no reachable trigger, or points already raised in the
   MR discussion.

Verdict rules: "confirmed" only if step 2 produced a concrete trigger that
step 1 could not rule out; "refuted" if step 1 produced positive evidence the
finding is wrong; "uncertain" otherwise. Report disprove_evidence,
prove_evidence, and relevance_rationale with file:line citations, and set
relevant true or false independently of the verdict.
