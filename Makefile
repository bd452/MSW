SHELL := /bin/bash
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Tool paths: prefer system installs, fall back to bundled/local versions
SWIFTLINT := $(shell command -v swiftlint 2>/dev/null || echo "$(REPO_ROOT)/.tools/swiftlint/swiftlint-static")
DOTNET := $(shell command -v dotnet 2>/dev/null || echo "$$HOME/.dotnet/dotnet")

.PHONY: help bootstrap build build-host build-guest test test-host test-guest \
        test-guest-remote test-host-remote build-host-remote check-host-remote check-remote \
        lint lint-host lint-guest format format-host format-guest check check-host check-guest \
        check-linux install-daemon uninstall-daemon \
        generate-protocol generate-protocol-host generate-protocol-guest \
        validate-protocol validate-protocol-host validate-protocol-guest

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
	@echo "  test-host      Run macOS host tests (requires macOS)"
	@echo "  test-guest     Run Windows guest tests (local)"
	@echo "  test-guest-remote  Run guest tests on Windows via GitHub Actions"
	@echo "  test-host-remote   Run host tests on macOS via GitHub Actions"
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
	@echo "  check-host     Run host checks only (requires macOS)"
	@echo "  check-guest    Run guest checks only"
	@echo "  check-linux    Run checks that work on Linux (lint + guest build/test)"
	@echo ""
	@echo "Remote CI targets (via GitHub Actions):"
	@echo "  check-remote       Run full CI remotely (host on macOS, guest on Windows)"
	@echo "  check-host-remote  Run host checks on macOS via GitHub Actions"
	@echo "  build-host-remote  Build host on macOS via GitHub Actions"
	@echo ""
	@echo "  Remote targets accept GH_TOKEN for authentication:"
	@echo "    make test-guest-remote GH_TOKEN=ghp_xxx"
	@echo "  Token requires 'workflow' scope. Create at: https://github.com/settings/tokens/new"
	@echo ""
	@echo "Protocol targets:"
	@echo "  generate-protocol      Regenerate protocol code from shared/protocol.def"
	@echo "  generate-protocol-host Generate Swift protocol code (requires macOS)"
	@echo "  generate-protocol-guest Generate C# protocol code (requires .NET)"
	@echo "  validate-protocol      Validate generated files match source"
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
	@$(call run-remote-workflow,test-guest-remote.yml,guest tests)

# Run host tests remotely on macOS via GitHub Actions
# Requires: gh CLI authenticated with repo access
test-host-remote:
	@echo "🚀 Triggering remote host tests on macOS..."
	@$(call run-remote-workflow,test-host-remote.yml,host tests)

# Run host build only remotely on macOS via GitHub Actions
build-host-remote:
	@echo "🚀 Triggering remote host build on macOS..."
	@$(call run-remote-workflow,test-host-remote.yml,host build,-f build_only=true)

# Run full host check (build + test) remotely on macOS
check-host-remote: test-host-remote
	@echo "✅ Remote host checks passed!"

# GitHub token for remote workflows (can be passed via environment or make variable)
# Usage: make test-guest-remote GH_TOKEN=ghp_xxx
# Token requires 'workflow' scope (and 'repo' for private repos)
GH_TOKEN ?=
export GH_TOKEN

# Remote log streaming (best-effort)
# NOTE: GitHub Actions does not provide a true push-based stdout stream.
# This setting controls whether we "tail" logs by repeatedly fetching them.
LIVE_LOG ?= 1
# How often we refresh logs (seconds). Lower feels "more live" but hits API harder.
LIVE_LOG_REFRESH_SECONDS ?= 2
# Safety: avoid hanging forever if status/log fetching gets stuck.
# Total seconds before aborting log streaming (0 = no timeout).
# Default: 30 minutes (reasonable for local dev).
LIVE_LOG_TIMEOUT_SECONDS ?= 1800
# Abort after this many consecutive log fetch failures (rate limits, transient API errors).
LIVE_LOG_MAX_CONSECUTIVE_ERRORS ?= 60
# Exponential backoff cap (seconds) when log fetch fails repeatedly.
LIVE_LOG_MAX_BACKOFF_SECONDS ?= 30

# Backwards-compatible aliases (older names)
LIVE_LOG_INTERVAL ?= $(LIVE_LOG_REFRESH_SECONDS)
LIVE_LOG_TIMEOUT ?= $(LIVE_LOG_TIMEOUT_SECONDS)
LIVE_LOG_MAX_ERRORS ?= $(LIVE_LOG_MAX_CONSECUTIVE_ERRORS)
LIVE_LOG_MAX_BACKOFF ?= $(LIVE_LOG_MAX_BACKOFF_SECONDS)

# Helper function for running remote workflows
# Usage: $(call run-remote-workflow,workflow-file,description,extra-args)
define run-remote-workflow
	if ! command -v gh >/dev/null 2>&1; then \
		echo "❌ GitHub CLI (gh) not found. Install with: brew install gh"; \
		exit 1; \
	fi; \
	if [ -n "$$GH_TOKEN" ]; then \
		echo "🔑 Using provided GH_TOKEN for authentication"; \
	fi; \
	BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	REPO=$$(gh repo view --json nameWithOwner --jq '.nameWithOwner'); \
	echo "📍 Testing branch: $$BRANCH"; \
	if ! gh workflow run $(1) --ref "$$BRANCH" -f ref="$$BRANCH" $(3) 2>/tmp/gh-error.txt; then \
		if grep -q "not found" /tmp/gh-error.txt 2>/dev/null; then \
			echo ""; \
			echo "❌ Workflow '$(1)' not found on default branch."; \
			echo ""; \
			echo "   GitHub requires workflow files to exist on the default branch (main)"; \
			echo "   before they can be triggered via workflow_dispatch."; \
			echo ""; \
			echo "   Options:"; \
			echo "   1. Push a PR to add the workflow file to main first"; \
			echo "   2. Use 'gh pr create' to open a PR - CI runs automatically on PRs"; \
			echo "   3. Push to main and then test your branch"; \
			echo ""; \
			exit 1; \
		elif grep -qi "Resource not accessible\|HTTP 403\|permission\|forbidden" /tmp/gh-error.txt 2>/dev/null; then \
			echo ""; \
			echo "❌ Permission denied: Cannot trigger workflow dispatch."; \
			echo ""; \
			cat /tmp/gh-error.txt; \
			echo ""; \
			echo "   The GitHub token doesn't have permission to trigger workflows."; \
			echo "   This can happen when:"; \
			echo "   • Running in an automated environment (CI, Cursor cloud agent, etc.)"; \
			echo "   • The gh CLI is authenticated with a token missing 'workflow' scope"; \
			echo "   • Repository settings restrict workflow dispatch"; \
			echo ""; \
			echo "   Solutions:"; \
			echo "   1. Provide a token with 'workflow' scope:"; \
			echo "      make $@ GH_TOKEN=ghp_your_token_here"; \
			echo ""; \
			echo "   2. Push your branch and create a PR - CI runs automatically on PRs"; \
			echo "      git push -u origin $$BRANCH && gh pr create"; \
			echo ""; \
			echo "   3. Re-authenticate gh with workflow scope:"; \
			echo "      gh auth login --scopes workflow"; \
			echo ""; \
			echo "   To create a token: https://github.com/settings/tokens/new"; \
			echo "   Required scopes: 'workflow' (and 'repo' for private repositories)"; \
			echo ""; \
			exit 1; \
		else \
			cat /tmp/gh-error.txt; \
			exit 1; \
		fi; \
	fi; \
	echo "⏳ Waiting for workflow to start..."; \
	sleep 5; \
	RUN_ID=$$(gh run list --workflow=$(1) --branch="$$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId'); \
	if [ -z "$$RUN_ID" ]; then \
		echo "❌ Failed to find workflow run"; \
		exit 1; \
	fi; \
	echo "🔗 Run ID: $$RUN_ID"; \
	echo "🌐 Live logs: https://github.com/$$REPO/actions/runs/$$RUN_ID"; \
	echo ""; \
	if [ "$(LIVE_LOG)" = "1" ]; then \
		echo "📺 Streaming workflow logs (best-effort, refresh $(LIVE_LOG_REFRESH_SECONDS)s)..."; \
		echo "   Tip: disable with LIVE_LOG=0 (or tune LIVE_LOG_REFRESH_SECONDS / LIVE_LOG_TIMEOUT_SECONDS)"; \
		echo ""; \
		LAST_LINES=0; \
		TMP_LOG="/tmp/gh-run-$$RUN_ID.log"; \
		TMP_LOG_NEW="/tmp/gh-run-$$RUN_ID.log.new"; \
		START_TS=$$(date +%s); \
		ERRORS=0; \
		BACKOFF="$(LIVE_LOG_REFRESH_SECONDS)"; \
		trap 'rm -f "$$TMP_LOG" "$$TMP_LOG_NEW" 2>/dev/null || true' EXIT INT TERM; \
		: > "$$TMP_LOG"; \
		while true; do \
			NOW_TS=$$(date +%s); \
			if [ "$(LIVE_LOG_TIMEOUT_SECONDS)" != "0" ] && [ $$((NOW_TS-START_TS)) -gt "$(LIVE_LOG_TIMEOUT_SECONDS)" ]; then \
				echo ""; \
				echo "❌ Timed out after $(LIVE_LOG_TIMEOUT_SECONDS)s while waiting for remote workflow logs."; \
				echo "   See: https://github.com/$$REPO/actions/runs/$$RUN_ID"; \
				exit 124; \
			fi; \
			STATUS=$$(gh run view "$$RUN_ID" --json status --jq '.status' 2>/dev/null || echo ""); \
			if gh run view "$$RUN_ID" --log > "$$TMP_LOG_NEW" 2>/dev/null; then \
				ERRORS=0; \
				BACKOFF="$(LIVE_LOG_REFRESH_SECONDS)"; \
				NEW_LINES=$$(wc -l < "$$TMP_LOG_NEW" | tr -d ' '); \
				if [ "$$NEW_LINES" -gt "$$LAST_LINES" ]; then \
					tail -n +$$((LAST_LINES+1)) "$$TMP_LOG_NEW"; \
					LAST_LINES="$$NEW_LINES"; \
				fi; \
				mv "$$TMP_LOG_NEW" "$$TMP_LOG"; \
			else \
				rm -f "$$TMP_LOG_NEW" 2>/dev/null || true; \
				ERRORS=$$((ERRORS+1)); \
				if [ "$$ERRORS" -ge "$(LIVE_LOG_MAX_CONSECUTIVE_ERRORS)" ]; then \
					echo ""; \
					echo "❌ Too many errors ($$ERRORS) fetching remote logs. Aborting."; \
					echo "   See: https://github.com/$$REPO/actions/runs/$$RUN_ID"; \
					exit 2; \
				fi; \
				# Exponential backoff (capped) to reduce flakiness / rate-limit pressure. \
				if [ "$$BACKOFF" -lt "$(LIVE_LOG_MAX_BACKOFF_SECONDS)" ]; then \
					BACKOFF=$$((BACKOFF*2)); \
					if [ "$$BACKOFF" -gt "$(LIVE_LOG_MAX_BACKOFF_SECONDS)" ]; then BACKOFF="$(LIVE_LOG_MAX_BACKOFF_SECONDS)"; fi; \
				fi; \
			fi; \
			if [ "$$STATUS" = "completed" ]; then \
				break; \
			fi; \
			sleep "$$BACKOFF"; \
		done; \
		CONCLUSION=$$(gh run view "$$RUN_ID" --json conclusion --jq '.conclusion' 2>/dev/null || echo ""); \
		echo ""; \
		if [ "$$CONCLUSION" = "success" ]; then \
			echo "✅ $(2) passed!"; \
			echo ""; \
		else \
			echo "❌ $(2) failed! (conclusion: $$CONCLUSION)"; \
			echo ""; \
			echo "📌 Failed step logs:"; \
			echo ""; \
			gh run view "$$RUN_ID" --log-failed; \
			exit 1; \
		fi; \
	else \
		echo "📺 Watching workflow progress..."; \
		if gh run watch "$$RUN_ID" --exit-status; then \
			echo ""; \
			echo "✅ $(2) passed!"; \
			echo ""; \
		else \
			EXIT_CODE=$$?; \
			echo ""; \
			echo "❌ $(2) failed! Showing failed step logs:"; \
			echo ""; \
			gh run view "$$RUN_ID" --log-failed; \
			exit $$EXIT_CODE; \
		fi; \
	fi
endef

# ============================================================================
# Lint
# ============================================================================

lint: lint-host lint-guest

lint-host:
	@echo "🔍 Linting host (SwiftLint)..."
	@if [ -x "$(SWIFTLINT)" ]; then \
		cd $(REPO_ROOT)/host && $(SWIFTLINT) lint --strict; \
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
	@if [ -x "$(SWIFTLINT)" ]; then \
		cd $(REPO_ROOT)/host && $(SWIFTLINT) lint --fix; \
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

# Linux-friendly check: runs everything that works on Linux
# - Host: lint only (build/test require macOS)
# - Guest: lint + build + test (97% of tests pass, ~3% require Windows P/Invoke)
check-linux: lint-host lint-guest build-guest
	@echo ""
	@echo "🧪 Running guest tests (some Windows-only tests expected to fail on Linux)..."
	@cd $(REPO_ROOT)/guest && \
		if $(DOTNET) test WinRunAgent.sln 2>&1 | tee /tmp/test-output.txt | tail -20; then \
			echo ""; \
			echo "✅ All guest tests passed!"; \
		else \
			PASSED=$$(grep -oP 'Passed:\s+\K\d+' /tmp/test-output.txt || echo 0); \
			FAILED=$$(grep -oP 'Failed:\s+\K\d+' /tmp/test-output.txt || echo 0); \
			TOTAL=$$(grep -oP 'Total:\s+\K\d+' /tmp/test-output.txt || echo 0); \
			if [ "$$FAILED" -le 10 ] && [ "$$PASSED" -gt 250 ]; then \
				echo ""; \
				echo "⚠️  $$PASSED/$$TOTAL tests passed ($$FAILED failed - expected on Linux due to Windows P/Invoke)"; \
			else \
				echo ""; \
				echo "❌ Too many test failures ($$FAILED). Check for real issues."; \
				exit 1; \
			fi; \
		fi
	@echo ""
	@echo "✅ Linux checks passed!"
	@echo "   Note: Host build/test skipped (requires macOS). Use 'make check-host-remote' for full host CI."
	@echo "   Note: Some guest tests require Windows. Use 'make test-guest-remote' for full guest tests."

# Full remote CI: run host on macOS, guest on Windows via GitHub Actions
check-remote:
	@echo "🚀 Running full remote CI..."
	@echo ""
	@$(MAKE) test-host-remote
	@echo ""
	@$(MAKE) test-guest-remote
	@echo ""
	@echo "✅ All remote checks passed!"

# ============================================================================
# Protocol Generation
# ============================================================================
# Source of truth: shared/protocol.def
# Generated files: host/Sources/WinRunSpiceBridge/Protocol.generated.swift
#                  guest/WinRunAgent/Protocol.generated.cs

generate-protocol: generate-protocol-host generate-protocol-guest
	@echo "✅ Protocol code regenerated!"

generate-protocol-host:
	@echo "🔄 Generating Swift protocol code..."
	@if command -v swift >/dev/null 2>&1; then \
		swift $(REPO_ROOT)/host/Scripts/generate-protocol.swift; \
	else \
		echo "⚠️  Swift not found; skipping host protocol generation"; \
	fi

generate-protocol-guest:
	@echo "🔄 Generating C# protocol code..."
ifdef DOTNET_ROOT
	cd $(REPO_ROOT)/guest/tools/GenerateProtocol && dotnet run
else
	@if command -v dotnet >/dev/null 2>&1; then \
		cd $(REPO_ROOT)/guest/tools/GenerateProtocol && dotnet run; \
	else \
		echo "⚠️  dotnet CLI not found; skipping guest protocol generation"; \
	fi
endif

# Validate that generated files match source (for CI)
validate-protocol: validate-protocol-host validate-protocol-guest
	@echo "✅ Protocol files are up to date!"

validate-protocol-host:
	@echo "🔍 Validating Swift protocol code..."
	@if command -v swift >/dev/null 2>&1; then \
		cp $(REPO_ROOT)/host/Sources/WinRunSpiceBridge/Protocol.generated.swift /tmp/Protocol.generated.swift.bak; \
		swift $(REPO_ROOT)/host/Scripts/generate-protocol.swift; \
		if ! diff -q $(REPO_ROOT)/host/Sources/WinRunSpiceBridge/Protocol.generated.swift /tmp/Protocol.generated.swift.bak >/dev/null 2>&1; then \
			echo "❌ Protocol.generated.swift is out of date!"; \
			echo "   Run 'make generate-protocol' and commit the changes."; \
			echo ""; \
			echo "=== DIFF (committed vs generated) ==="; \
			diff -u /tmp/Protocol.generated.swift.bak $(REPO_ROOT)/host/Sources/WinRunSpiceBridge/Protocol.generated.swift || true; \
			echo "=== END DIFF ==="; \
			mv /tmp/Protocol.generated.swift.bak $(REPO_ROOT)/host/Sources/WinRunSpiceBridge/Protocol.generated.swift; \
			exit 1; \
		fi; \
		rm /tmp/Protocol.generated.swift.bak; \
		echo "✅ Swift protocol code is up to date"; \
	else \
		echo "⚠️  Swift not found; skipping host protocol validation"; \
	fi

validate-protocol-guest:
	@echo "🔍 Validating C# protocol code..."
ifdef DOTNET_ROOT
	@cp $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs /tmp/Protocol.generated.cs.bak; \
	cd $(REPO_ROOT)/guest/tools/GenerateProtocol && dotnet run; \
	if ! diff -q $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs /tmp/Protocol.generated.cs.bak >/dev/null 2>&1; then \
		echo "❌ Protocol.generated.cs is out of date!"; \
		echo "   Run 'make generate-protocol' and commit the changes."; \
		echo ""; \
		echo "=== DIFF (committed vs generated) ==="; \
		diff -u /tmp/Protocol.generated.cs.bak $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs || true; \
		echo "=== END DIFF ==="; \
		mv /tmp/Protocol.generated.cs.bak $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs; \
		exit 1; \
	fi; \
	rm /tmp/Protocol.generated.cs.bak; \
	echo "✅ C# protocol code is up to date"
else
	@if command -v dotnet >/dev/null 2>&1; then \
		cp $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs /tmp/Protocol.generated.cs.bak; \
		cd $(REPO_ROOT)/guest/tools/GenerateProtocol && dotnet run; \
		if ! diff -q $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs /tmp/Protocol.generated.cs.bak >/dev/null 2>&1; then \
			echo "❌ Protocol.generated.cs is out of date!"; \
			echo "   Run 'make generate-protocol' and commit the changes."; \
			echo ""; \
			echo "=== DIFF (committed vs generated) ==="; \
			diff -u /tmp/Protocol.generated.cs.bak $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs || true; \
			echo "=== END DIFF ==="; \
			mv /tmp/Protocol.generated.cs.bak $(REPO_ROOT)/guest/WinRunAgent/Protocol.generated.cs; \
			exit 1; \
		fi; \
		rm /tmp/Protocol.generated.cs.bak; \
		echo "✅ C# protocol code is up to date"; \
	else \
		echo "⚠️  dotnet CLI not found; skipping guest protocol validation"; \
	fi
endif

# ============================================================================
# Daemon management
# ============================================================================

install-daemon:
	$(REPO_ROOT)/scripts/bootstrap.sh --install-daemon

uninstall-daemon:
	$(REPO_ROOT)/scripts/bootstrap.sh --uninstall-daemon
