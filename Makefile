SHELL := /bin/bash
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: bootstrap build build-host build-guest test-host test-guest

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
		echo "dotnet CLI not found; skipping guest build"; \
	fi
endif

test-host:
	cd $(REPO_ROOT)/host && swift test

test-guest:
	cd $(REPO_ROOT)/guest && dotnet test WinRunAgent.sln
