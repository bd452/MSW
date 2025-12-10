SHELL := /bin/bash
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: help bootstrap build build-host build-guest test test-host test-guest test-guest-remote \
        lint lint-host lint-guest format format-host format-guest check check-host check-guest \
        install-daemon uninstall-daemon

# Default target
help:
	@echo "WinRun Build System"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Build targets:"
	@echo "  build          Build both host and guest"
	@echo "  build-host     Build macOS host components"
	@echo "  build-guest    Build Windows guest agent"
	@echo ""
	@echo "Test targets:"
	@echo "  test           Run all tests"
	@echo "  test-host      Run macOS host tests"
	@echo "  test-guest     Run Windows guest tests (local)"
	@echo "  test-guest-remote  Run guest tests on Windows via GitHub Actions"
	@echo ""
	@echo "Lint targets:"
	@echo "  lint           Lint both host and guest"
	@echo "  lint-host      Lint macOS host (SwiftLint)"
	@echo "  lint-guest     Lint Windows guest (dotnet format)"
	@echo ""
	@echo "Format targets:"
	@echo "  format         Format both host and guest"
	@echo "  format-host    Format macOS host (SwiftLint autocorrect)"
	@echo "  format-guest   Format Windows guest (dotnet format)"
	@echo ""
	@echo "CI targets:"
	@echo "  check          Run all checks (lint + test) - use before committing"
	@echo "  check-host     Run host checks only"
	@echo "  check-guest    Run guest checks only"
	@echo ""
	@echo "Setup targets:"
	@echo "  bootstrap      Install dependencies and setup environment"
	@echo "  install-daemon Install launchd daemon"
	@echo "  uninstall-daemon Uninstall launchd daemon"

# ============================================================================
# Build
# ============================================================================

bootstrap:
	$(REPO_ROOT)/scripts/bootstrap.sh

build: build-host build-guest

build-host:
	cd $(REPO_ROOT)/host && swift build

build-guest:
ifdef DOTNET_ROOT
	cd $(REPO_ROOT)/guest && dotnet build WinRunAgent.sln
else
	@if command -v dotnet >/dev/null 2>&1; then \
		cd $(REPO_ROOT)/guest && dotnet build WinRunAgent.sln; \
	else \
		echo "⚠️  dotnet CLI not found; skipping guest build"; \
	fi
endif

# ============================================================================
# Test
# ============================================================================

test: test-host test-guest

test-host:
	@echo "🧪 Running host tests..."
	cd $(REPO_ROOT)/host && swift test

test-guest:
ifdef DOTNET_ROOT
	@echo "🧪 Running guest tests..."
	cd $(REPO_ROOT)/guest && dotnet test WinRunAgent.sln
else
	@if command -v dotnet >/dev/null 2>&1; then \
		echo "🧪 Running guest tests..."; \
		cd $(REPO_ROOT)/guest && dotnet test WinRunAgent.sln; \
	else \
		echo "⚠️  dotnet CLI not found; skipping guest tests"; \
	fi
endif

# Run guest tests remotely on Windows via GitHub Actions
# Requires: gh CLI authenticated with repo access
test-guest-remote:
	@echo "🚀 Triggering remote guest tests on Windows..."
	@if ! command -v gh >/dev/null 2>&1; then \
		echo "❌ GitHub CLI (gh) not found. Install with: brew install gh"; \
		exit 1; \
	fi
	@BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	REPO=$$(gh repo view --json nameWithOwner --jq '.nameWithOwner'); \
	echo "📍 Testing branch: $$BRANCH"; \
	gh workflow run test-guest-remote.yml --ref "$$BRANCH" -f ref="$$BRANCH"; \
	echo "⏳ Waiting for workflow to start..."; \
	sleep 5; \
	RUN_ID=$$(gh run list --workflow=test-guest-remote.yml --branch="$$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId'); \
	if [ -z "$$RUN_ID" ]; then \
		echo "❌ Failed to find workflow run"; \
		exit 1; \
	fi; \
	echo "🔗 Run ID: $$RUN_ID"; \
	echo "🌐 Live logs: https://github.com/$$REPO/actions/runs/$$RUN_ID"; \
	echo ""; \
	echo "📺 Waiting for workflow to complete..."; \
	if gh run watch "$$RUN_ID" --exit-status; then \
		echo ""; \
		echo "✅ All tests passed!"; \
	else \
		EXIT_CODE=$$?; \
		echo ""; \
		echo "❌ Tests failed!"; \
	fi; \
	echo ""; \
	echo "📋 Test output:"; \
	gh run view "$$RUN_ID" --log 2>/dev/null | grep -E 'Test\s' | grep -v 'Testhost\|Starting test\|Test run for\|test files matched' || true; \
	if [ "$${EXIT_CODE:-0}" -ne 0 ]; then exit 1; fi

# ============================================================================
# Lint
# ============================================================================

lint: lint-host lint-guest

lint-host:
	@echo "🔍 Linting host (SwiftLint)..."
	@if command -v swiftlint >/dev/null 2>&1; then \
		cd $(REPO_ROOT)/host && swiftlint lint --strict; \
	else \
		echo "⚠️  SwiftLint not found. Install with: brew install swiftlint"; \
		exit 1; \
	fi

lint-guest:
ifdef DOTNET_ROOT
	@echo "🔍 Linting guest (dotnet format)..."
	cd $(REPO_ROOT)/guest && dotnet format WinRunAgent.sln --verify-no-changes
else
	@if command -v dotnet >/dev/null 2>&1; then \
		echo "🔍 Linting guest (dotnet format)..."; \
		cd $(REPO_ROOT)/guest && dotnet format WinRunAgent.sln --verify-no-changes; \
	else \
		echo "⚠️  dotnet CLI not found; skipping guest lint"; \
	fi
endif

# ============================================================================
# Format
# ============================================================================

format: format-host format-guest

format-host:
	@echo "✨ Formatting host (SwiftLint autocorrect)..."
	@if command -v swiftlint >/dev/null 2>&1; then \
		cd $(REPO_ROOT)/host && swiftlint lint --fix; \
	else \
		echo "⚠️  SwiftLint not found. Install with: brew install swiftlint"; \
		exit 1; \
	fi

format-guest:
ifdef DOTNET_ROOT
	@echo "✨ Formatting guest (dotnet format)..."
	cd $(REPO_ROOT)/guest && dotnet format WinRunAgent.sln
else
	@if command -v dotnet >/dev/null 2>&1; then \
		echo "✨ Formatting guest (dotnet format)..."; \
		cd $(REPO_ROOT)/guest && dotnet format WinRunAgent.sln; \
	else \
		echo "⚠️  dotnet CLI not found; skipping guest format"; \
	fi
endif

# ============================================================================
# Check (CI-style: lint + test)
# ============================================================================

check: check-host check-guest
	@echo ""
	@echo "✅ All checks passed!"

check-host: lint-host build-host test-host
	@echo "✅ Host checks passed!"

check-guest: lint-guest build-guest test-guest
	@echo "✅ Guest checks passed!"

# ============================================================================
# Daemon management
# ============================================================================

install-daemon:
	$(REPO_ROOT)/scripts/bootstrap.sh --install-daemon

uninstall-daemon:
	$(REPO_ROOT)/scripts/bootstrap.sh --uninstall-daemon
