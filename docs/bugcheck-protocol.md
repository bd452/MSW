# Iterative Bug Check Protocol

Go through `TODO.md` step-by-step and check for bugs in the implementation of every checked-off item. Track progress in `bugchecks.md`. To find the current/next task, look at the next TODO item that's not covered in bugchecks.md (the important part of bugchecks.md is the list of checked steps, not the list of remaining items).

Be aware that the codebase will have likely changed a lot since the relevant TODO item was addressed and marked completed—be mindful of that when addressing scope and making changes. Also review `SUMMARY.md`, everything in `/docs`, and all build scripts/makefiles/configs to understand the current structure.

Further, assume the app is intended to be fully implemented—any stubs, TODOs, or missing functionality in scope of the current item should be immediately addressed.

## Branch Strategy

One branch corresponds to **one first-level item** in TODO.md. All leaf items under that first-level item are checked and fixed within the same branch. Use `bugcheck/<first-level-item-slug>` naming (e.g., `bugcheck/host-platform`).

## Analysis Depth Requirements

Beyond correctness bugs, also identify design shortcomings—implementations that work correctly but use suboptimal patterns (e.g., polling when push-based notification is available, synchronous blocking when async is appropriate, timer-based detection when event-driven is possible). These are architectural debt to be flagged and added to `TODO.md` for future improvement.

**For each granular item, perform these deep analysis steps:**

1. **Understand Intent & Scope**
   - Read the task description and referenced documentation
   - Identify all files that were modified by this task
   - Identify all files that encompass the scope given the *current* codebase state

2. **Trace All Data Flows (Critical)**
   - For each configuration field, struct property, or parameter introduced:
     - Trace where it's **stored** (model definition)
     - Trace where it's **persisted** (serialization/encoding)
     - Trace where it's **loaded** (deserialization/decoding)
     - Trace where it's **validated** (validation methods)
     - **Trace where it's actually USED** (consumed by the feature)
   - Flag any fields that exist but are never consumed as bugs
   - Flag any fields that are consumed but never validated as bugs

3. **Verify Implementation Completeness**
   - For each public API or capability the task claims to implement:
     - Find the actual implementation code
     - Verify it's wired up and callable (not dead code)
     - Verify error cases are handled
   - For any "TODO" comments, stubs, or placeholder implementations in scope—these are bugs

4. **Cross-Reference with Native APIs**
   - When interfacing with system frameworks (Virtualization.framework, Win32, etc.):
     - Verify all configuration options are properly mapped to native API calls
     - Check for capabilities the native API supports that the wrapper ignores
     - Check for required setup steps that might be missing

5. **Check Test Coverage Alignment**
   - Verify tests exist for the implemented functionality
   - Verify tests cover the actual code paths (not just happy paths)
   - Look for configuration fields or code branches with no test coverage

6. **Look at Relevant Dependencies**
   - Check if changes here require updates to dependent code
   - Check if this code depends on assumptions that may no longer hold

7. **Check Future TODOs in bugchecks.md**
   - If a bug is covered in a future TODO, evaluate whether it should be fixed now or deferred
   - If deferring, add an item to bugchecks.md under "Deferred Issues" with the hierarchy position and issue details

## Execution Steps

1. **Identify Next Item** - Find the first checked leaf in `TODO.md` that is not checked in `bugchecks.md`

2. **Gather Full Scope** - Read all relevant files, tracing data flows as described above

3. **Analyze Comprehensively** - For each capability the TODO claims to implement:
   - Can I find the code that does it?
   - Is it actually wired up and called?
   - Are all configuration options actually used?
   - Are error cases handled?

4. **State Findings** - List all bugs found in this analysis pass as a **cumulative bug list**

5. **Iterate Analysis Until Exhaustive** - Re-run analysis steps 2-4:
   - **Re-read all relevant files fresh** — do NOT continue from memory; use the read_file tool again and analyze with new perspective
   - Look for issues that may have been missed (cross-references, consistency, edge cases)
   - After each pass, **explicitly state "Cumulative bug list after Pass N:"** followed by the list (or "None found" if empty)
   - If new bugs are found, add them to the cumulative list and continue
   - **Continue iterating until a full analysis pass finds NO NEW bugs**
   - Only then proceed to fixing

6. **Fix All Issues** - Once analysis is exhaustive:
   - Create and move to a new branch (if on main)
   - Implement fixes across all affected files
   - **Write or update tests** for changed code paths
   - Run **local checks**: `make check` (macOS) or `make check-linux` (Linux)
   - Only use remote tests (`make test-host-remote` / `make test-guest-remote`) when the code genuinely requires its native environment (e.g., Windows-only APIs, CRLF validation) and cannot be tested locally

7. **Re-Run Full Analysis After Fixing** - After all fixes are applied:
   - Go back to step 2 and perform the complete iterative analysis again
   - **Re-read all files fresh** — fixes may have introduced new issues or revealed previously obscured bugs
   - This catches issues introduced by fixes
   - If new bugs are found, repeat from step 5 (iterate analysis) then step 6 (fix)
   - **Continue until a full post-fix analysis pass finds NO bugs**

8. **Update bugchecks.md** - Record all findings in the same format as existing entries (only after clean pass)

9. **Check First-Level Item Completion** - After updating bugchecks.md:
   - If more leaf items remain under the current first-level item → ask user if they want to continue, then go to step 1
   - If all leaf items under the current first-level item are complete → go to step 10

10. **Create Pull Request** - When all leaves under a first-level item are complete:
    - Push the branch: `git push -u origin HEAD`
    - Create PR: `gh pr create --title "fix(<scope>): bug check for <First-Level Item Name>" --body "<description of bugs found and fixed>"`
    - Report the PR URL to the user
    - Ask if user wants to continue to the next first-level item
      - If yes, create a new branch and go to step 1
      - If no, summarize overall progress and stop
