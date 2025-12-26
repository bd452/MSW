#!/bin/bash
# ci-watch.sh - Simple CI watcher: find latest run, wait for completion, show errors
# Usage: ./scripts/ci-watch.sh [--hierarchical] [RUN_ID]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERROR_FILE="$REPO_ROOT/.ci-errors"

# Check for gh CLI
if ! command -v gh >/dev/null 2>&1; then
    echo "❌ GitHub CLI (gh) not found. Install with: brew install gh"
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

# Find run ID
RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
    echo "🔍 Finding latest CI run for branch '$BRANCH'..."
    RUN_ID=$(gh run list --workflow=ci.yml --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
fi

if [[ -z "$RUN_ID" ]]; then
    echo "❌ No CI run found. Push your branch first: git push -u origin $BRANCH"
    exit 1
fi

echo "🔗 https://github.com/$REPO/actions/runs/$RUN_ID"
echo ""

# Wait for completion
echo "⏳ Waiting for CI to complete..."
gh run watch "$RUN_ID" --exit-status 2>/dev/null && {
    echo ""
    echo "✅ CI passed!"
    rm -f "$ERROR_FILE"
    exit 0
}

# CI failed - extract errors
echo ""
echo "❌ CI failed. Extracting errors..."
echo ""

# Get failed logs and save to file
{
    echo "# CI Errors - $(date)"
    echo "# Run: https://github.com/$REPO/actions/runs/$RUN_ID"
    echo ""
    gh run view "$RUN_ID" --log-failed 2>/dev/null | \
        sed 's/\x1b\[[0-9;]*m//g' | \
        grep -E '(error|Error|ERROR|\.swift:[0-9]+:|\.cs\([0-9]+)' | \
        head -50
} > "$ERROR_FILE"

# Show errors
echo "─────────────────────────────────────────────────────"
cat "$ERROR_FILE"
echo "─────────────────────────────────────────────────────"
echo ""
echo "📋 Errors saved to: $ERROR_FILE"

exit 1
