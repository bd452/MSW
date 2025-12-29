# Iterative Bug Check Protocol

> **Usage:** Reference this file when asking the agent to check TODO items for bugs.
> Example: "Follow docs/bugcheck-protocol.md and check the next item for bugs"

## Overview

Go through `TODO.md` step-by-step and check for bugs in the implementation of every checked-off item. Track progress in `bugchecks.md`. To find the current/next task, look at the next TODO item that's not covered in bugchecks.md (the important part of bugchecks.md is the list of checked steps, not the list of remaining items).

Be aware that the codebase will have likely changed a lot since the relevant TODO item was addressed and marked completed—be mindful of that when addressing scope and making changes. Also review `SUMMARY.md`, everything in `/docs`, and all build scripts/makefiles/configs to understand the current structure.

Further, assume the app is intended to be fully implemented—any stubs, TODOs, or missing functionality in scope of the current item should be immediately addressed.

---

## Branch & PR Strategy

### Branch Scope

One branch corresponds to **one first-level item** in TODO.md. All leaf items under that first-level item are checked and fixed within the same branch.

### Branch Naming Convention

Use `bugcheck/<first-level-item-slug>` format (e.g., `bugcheck/host-platform`).

### When to Create a PR

Create a PR **only after all leaf items under the current first-level item have been checked** and recorded in `bugchecks.md`.

---

## Analysis Depth Requirements

Beyond correctness bugs, also identify design shortcomings—implementations that work correctly but use suboptimal patterns (e.g., polling when push-based notification is available, synchronous blocking when async is appropriate, timer-based detection when event-driven is possible). These are architectural debt to be flagged and added to `TODO.md` for future improvement.

**For each granular item, perform these deep analysis steps:**

### 1. Understand Intent & Scope

- Read the task description and referenced documentation
- Identify all files that were modified by this task
- Identify all files that encompass the scope given the *current* codebase state

### 2. Trace All Data Flows (Critical)

- For each configuration field, struct property, or parameter introduced:
  - Trace where it's **stored** (model definition)
  - Trace where it's **persisted** (serialization/encoding)
  - Trace where it's **loaded** (deserialization/decoding)
  - Trace where it's **validated** (validation methods)
  - **Trace where it's actually USED** (consumed by the feature)
- Flag any fields that exist but are never consumed as bugs
- Flag any fields that are consumed but never validated as bugs

### 3. Verify Implementation Completeness

- For each public API or capability the task claims to implement:
  - Find the actual implementation code
  - Verify it's wired up and callable (not dead code)
  - Verify error cases are handled
- For any "TODO" comments, stubs, or placeholder implementations in scope—these are bugs

### 4. Cross-Reference with Native APIs

- When interfacing with system frameworks (Virtualization.framework, Win32, etc.):
  - Verify all configuration options are properly mapped to native API calls
  - Check for capabilities the native API supports that the wrapper ignores
  - Check for required setup steps that might be missing

### 5. Check Test Coverage Alignment

- Verify tests exist for the implemented functionality
- Verify tests cover the actual code paths (not just happy paths)
- Look for configuration fields or code branches with no test coverage

### 6. Look at Relevant Dependencies

- Check if changes here require updates to dependent code
- Check if this code depends on assumptions that may no longer hold

### 7. Check Future TODOs in bugchecks.md

- If a bug is covered in a future TODO, evaluate whether it should be fixed now or deferred
- If deferring, note it in bugchecks.md under "Deferred Issues"

---

## Execution Steps

### Step 1: Identify Next Item

Find the first checked leaf in `TODO.md` that is not checked in `bugchecks.md`

### Step 2: Gather Full Scope

Read all relevant files, tracing data flows as described above

### Step 3: Analyze Comprehensively

For each capability the TODO claims to implement:

- Can I find the code that does it?
- Is it actually wired up and called?
- Are all configuration options actually used?
- Are error cases handled?

### Step 4: State Findings

List all bugs found in this analysis pass as a **cumulative bug list**

### Step 5: Iterate Analysis Until Exhaustive

Re-run analysis steps 2-4:

- **Re-read all relevant files fresh** — do NOT continue from memory; use the read_file tool again and analyze with new perspective
- Look for issues that may have been missed (cross-references, consistency, edge cases)
- After each pass, **explicitly state "Cumulative bug list after Pass N:"** followed by the list (or "None found" if empty)
- If new bugs are found, add them to the cumulative list and continue
- **Continue iterating until a full analysis pass finds NO NEW bugs**
- Only then proceed to fixing

### Step 6: Fix All Issues

Once analysis is exhaustive:

- Create and move to a new branch (if on main)
- Implement fixes across all affected files
- **Write or update tests** for changed code paths
- Run **local checks**: `make check` (macOS) or `make check-linux` (Linux)
- Only use remote tests (`make test-host-remote` / `make test-guest-remote`) when the code genuinely requires its native environment

### Step 7: Re-Run Full Analysis After Fixing

After all fixes are applied:

- Go back to step 2 and perform the complete iterative analysis again
- **Re-read all files fresh** — fixes may have introduced new issues or revealed previously obscured bugs
- If new bugs are found, repeat from step 5 (iterate analysis) then step 6 (fix)
- **Continue until a full post-fix analysis pass finds NO bugs**

### Step 8: Update bugchecks.md

Record all findings in the same format as existing entries (only after clean pass)

### Step 9: Check if First-Level Item is Complete

After updating bugchecks.md, check if **all leaf items under the current first-level item** have been checked:

- Compare TODO.md first-level item's leaves against bugchecks.md entries
- If more leaves remain → go to Step 10
- If all leaves are complete → go to Step 11

### Step 10: Continue to Next Leaf

If more leaves remain in the current first-level item:

- Commit current changes
- Ask user if they want to continue to the next leaf item
- If yes, go to Step 1
- If no, summarize progress and stop

### Step 11: Create Pull Request

When all leaves under a first-level item are complete:

1. Push the branch and create a PR using the format below
2. Report the PR URL to the user
3. Ask if user wants to continue to the next first-level item
   - If yes, create a new branch and go to Step 1
   - If no, summarize overall progress and stop

---

## Output Formats

### bugchecks.md Entry Format

```markdown
- [X] Task name from TODO.md
  - **Status:** ✅ No bugs found | 🔧 Bug(s) found and fixed
  - **Bug Fixed:** (if applicable) **Brief title** - Description of the bug and fix
  - **Notes:** (if no bugs) Brief summary of what was verified
  - **Test Coverage:** Summary of relevant tests
```

### PR Title Format

```
fix(<scope>): bug check for <First-Level Item Name>
```

### PR Description Format

```markdown
## Summary

Iterative bug check analysis for **<First-Level Item Name>** per `docs/bugcheck-protocol.md`.

## Items Checked

| Item | Status | Bugs Found |
| ---- | ------ | ---------- |
| ...  | ✅ / 🔧 | ...        |

## Bugs Fixed

(List each bug with location, issue description, and fix — or "No bugs found.")

## Design Shortcomings Identified

(List any architectural debt added to TODO.md — or "None identified.")

## Test Coverage

- Summary of tests added/updated
- All checks passing: `make check` ✅
```
