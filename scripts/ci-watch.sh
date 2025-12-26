#!/bin/bash
# ci-watch.sh - Watch CI runs and extract errors for easy fixing
#
# Usage:
#   ./scripts/ci-watch.sh              # Watch the latest CI run for current branch
#   ./scripts/ci-watch.sh --push       # Push first, then watch
#   ./scripts/ci-watch.sh --run-id 123 # Watch a specific run
#   ./scripts/ci-watch.sh --pr 456     # Watch CI for a specific PR
#
# Output:
#   On failure, writes formatted errors to .ci-errors.md for easy reference

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERROR_FILE="$REPO_ROOT/.ci-errors.md"
REFRESH_INTERVAL="${CI_REFRESH_INTERVAL:-5}"
PUSH_FIRST=false
RUN_ID=""
PR_NUMBER=""
SHOW_FULL_LOG=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --push|-p)
            PUSH_FIRST=true
            shift
            ;;
        --run-id|-r)
            RUN_ID="$2"
            shift 2
            ;;
        --pr)
            PR_NUMBER="$2"
            shift 2
            ;;
        --full|-f)
            SHOW_FULL_LOG=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --push, -p       Push current branch before watching"
            echo "  --run-id, -r ID  Watch a specific workflow run"
            echo "  --pr NUMBER      Watch CI for a specific PR"
            echo "  --full, -f       Show full logs (not just failures)"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Environment:"
            echo "  CI_REFRESH_INTERVAL  Seconds between status checks (default: 5)"
            echo ""
            echo "Output:"
            echo "  On CI failure, errors are written to .ci-errors.md"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for gh CLI
if ! command -v gh >/dev/null 2>&1; then
    echo "❌ GitHub CLI (gh) not found. Install with: brew install gh"
    exit 1
fi

# Get repo info
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [[ -z "$REPO" ]]; then
    echo "❌ Could not determine repository. Make sure you're in a git repo with a GitHub remote."
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Push if requested
if [[ "$PUSH_FIRST" == "true" ]]; then
    echo "📤 Pushing branch '$BRANCH' to origin..."
    if ! git push -u origin "$BRANCH" 2>&1; then
        echo "❌ Failed to push. You may need to set up tracking or resolve conflicts."
        exit 1
    fi
    echo ""
fi

# Find the run to watch
if [[ -n "$PR_NUMBER" ]]; then
    echo "🔍 Finding CI run for PR #$PR_NUMBER..."
    RUN_ID=$(gh run list --workflow=ci.yml --json databaseId,headBranch,event \
        --jq ".[] | select(.event == \"pull_request\") | .databaseId" \
        --limit 20 | head -1)
    
    if [[ -z "$RUN_ID" ]]; then
        # Try to get the PR's head branch and find runs for it
        PR_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
        if [[ -n "$PR_BRANCH" ]]; then
            RUN_ID=$(gh run list --workflow=ci.yml --branch="$PR_BRANCH" --limit=1 \
                --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
        fi
    fi
elif [[ -z "$RUN_ID" ]]; then
    echo "🔍 Finding latest CI run for branch '$BRANCH'..."
    RUN_ID=$(gh run list --workflow=ci.yml --branch="$BRANCH" --limit=1 \
        --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
fi

if [[ -z "$RUN_ID" ]]; then
    echo "❌ No CI run found for branch '$BRANCH'"
    echo ""
    echo "   Options:"
    echo "   1. Push your branch: git push -u origin $BRANCH"
    echo "   2. Create a PR: gh pr create"
    echo "   3. Run with --push to push and watch: $0 --push"
    exit 1
fi

echo "🔗 Watching run: https://github.com/$REPO/actions/runs/$RUN_ID"
echo ""

# Watch the run
watch_run() {
    local run_id="$1"
    local last_status=""
    
    while true; do
        local run_info
        run_info=$(gh run view "$run_id" --json status,conclusion,jobs 2>/dev/null || echo "")
        
        if [[ -z "$run_info" ]]; then
            echo "⚠️  Failed to fetch run status, retrying..."
            sleep "$REFRESH_INTERVAL"
            continue
        fi
        
        local status
        status=$(echo "$run_info" | jq -r '.status')
        local conclusion
        conclusion=$(echo "$run_info" | jq -r '.conclusion // "pending"')
        
        # Show job status if changed
        if [[ "$status" != "$last_status" ]]; then
            echo "📊 Status: $status"
            echo "$run_info" | jq -r '.jobs[] | "   \(if .status == "completed" then (if .conclusion == "success" then "✅" else "❌" end) elif .status == "in_progress" then "🔄" else "⏳" end) \(.name): \(.status)\(if .conclusion then " (\(.conclusion))" else "" end)"'
            last_status="$status"
        fi
        
        if [[ "$status" == "completed" ]]; then
            return 0
        fi
        
        sleep "$REFRESH_INTERVAL"
    done
}

# Strip ANSI color codes from text
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g' | sed 's/\[36;1m//g' | sed 's/\[0m//g'
}

# Extract and format errors
extract_errors() {
    local run_id="$1"
    local conclusion
    conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion')
    
    if [[ "$conclusion" == "success" ]]; then
        echo ""
        echo "✅ CI passed! No errors to report."
        rm -f "$ERROR_FILE"
        return 0
    fi
    
    echo ""
    echo "❌ CI failed! Extracting errors..."
    echo ""
    
    # Get failed logs
    local failed_log
    failed_log=$(gh run view "$run_id" --log-failed 2>/dev/null | strip_ansi || echo "")
    
    # Get job details
    local jobs_info
    jobs_info=$(gh run view "$run_id" --json jobs 2>/dev/null || echo "")
    
    # Get failed jobs (excluding the CI gate job which just reports other failures)
    local failed_jobs
    failed_jobs=$(echo "$jobs_info" | jq -r '.jobs[] | select(.conclusion == "failure" and .name != "CI") | .name')
    
    # Write formatted error report
    {
        echo "# CI Errors"
        echo ""
        echo "**Run:** https://github.com/$REPO/actions/runs/$run_id"
        echo "**Branch:** $BRANCH"
        echo "**Time:** $(date)"
        echo ""
        
        # List failed jobs
        echo "## Failed Jobs"
        echo ""
        echo "$jobs_info" | jq -r '.jobs[] | select(.conclusion == "failure" and .name != "CI") | "- **\(.name)**"'
        echo ""
        
        # Parse and format the failed log - extract actual errors
        echo "## Errors"
        echo ""
        echo '```'
        
        # Filter to actual error lines - skip CI gate job, timestamps, and noise
        echo "$failed_log" | while IFS= read -r line; do
            # Skip CI gate job output
            if [[ "$line" =~ ^CI$'\t' ]]; then
                continue
            fi
            
            # Extract content after job/step/timestamp
            local content="$line"
            if [[ "$line" =~ $'\t' ]]; then
                # Remove job name, step name, and timestamp prefix
                content=$(echo "$line" | sed 's/^[^\t]*\t[^\t]*\t[^ ]* //')
            fi
            
            # Skip GitHub Actions meta-lines
            if [[ "$content" =~ ^##\[(group|endgroup)\] ]] || \
               [[ "$content" =~ ^shell: ]] || \
               [[ "$content" =~ ^\[.*\]$ ]] || \
               [[ -z "$content" ]]; then
                continue
            fi
            
            # Match actual compiler/runtime errors
            if [[ "$content" =~ \.swift:[0-9]+:[0-9]+:\ (error|warning): ]] || \
               [[ "$content" =~ \.cs\([0-9]+,[0-9]+\):\ error ]] || \
               [[ "$content" =~ ^error: ]] || \
               [[ "$content" =~ ^##\[error\] ]] || \
               [[ "$content" =~ fatalError ]]; then
                # Clean up ##[error] prefix
                content="${content#\#\#\[error\]}"
                echo "$content"
            fi
        done
        
        echo '```'
        echo ""
        
        # Include context around errors (file:line references)
        echo "## Files to Fix"
        echo ""
        # Extract file:line references and convert CI runner paths to relative paths
        echo "$failed_log" | grep -oE '[a-zA-Z0-9_/.-]+\.(swift|cs):[0-9]+' | \
            sed 's|.*/host/|host/|g' | \
            sed 's|.*/guest/|guest/|g' | \
            sort -u | while read -r ref; do
            echo "- \`$ref\`"
        done
        echo ""
        
    } > "$ERROR_FILE"
    
    echo "📝 Errors written to: $ERROR_FILE"
    echo ""
    
    # Print clean error summary to console
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo "ERRORS:"
    echo "─────────────────────────────────────────────────────────────────────────────"
    
    # Extract just the actual error messages
    echo "$failed_log" | while IFS= read -r line; do
        # Skip CI gate job
        if [[ "$line" =~ ^CI$'\t' ]]; then
            continue
        fi
        
        local content="$line"
        if [[ "$line" =~ $'\t' ]]; then
            content=$(echo "$line" | sed 's/^[^\t]*\t[^\t]*\t[^ ]* //')
        fi
        
        if [[ "$content" =~ \.swift:[0-9]+:[0-9]+:\ error: ]] || \
           [[ "$content" =~ \.cs\([0-9]+,[0-9]+\):\ error ]] || \
           [[ "$content" =~ ^error: ]]; then
            echo "$content"
        fi
    done | head -20
    
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo ""
    echo "📋 Full error report: $ERROR_FILE"
    echo "🔗 View online: https://github.com/$REPO/actions/runs/$run_id"
    
    return 1
}

# Main execution
echo "⏳ Watching CI run (refresh every ${REFRESH_INTERVAL}s)..."
echo "   Press Ctrl+C to stop watching"
echo ""

watch_run "$RUN_ID"
extract_errors "$RUN_ID"
