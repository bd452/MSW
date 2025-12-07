# Operations, Packaging, and CI Decisions

## Script Ownership
- Treat `scripts/bootstrap.sh` and `scripts/build-all.sh` as the single source of truth for dependency installation and build orchestration.
- Any new packaging steps must be implemented as reusable scripts (e.g., `scripts/package-host.sh`, `scripts/package-guest.ps1`) and then invoked from `build-all.sh`.

## Packaging Targets
- macOS artifacts ship as a LaunchDaemon-installed `winrund`, a signed `WinRun.app`, and optional `.app` launchers; use pkgbuild/productbuild for distribution.
- Windows guest artifacts publish via dotnet `publish` plus MSI/installer bundling so administrators can deploy services predictably.

## Documentation Expectations
- `README.md`, `docs/architecture.md`, and `docs/development.md` must describe the production pipeline (bootstrap → build → package → deploy) to onboard contributors quickly.
- Architecture decisions documents live in `docs/decisions/` and should be linked from relevant TODO items or specs.

## Continuous Integration
- CI must kick off both macOS (SwiftPM) and Windows (dotnet) jobs, running tests before invoking packaging scripts.
- Workflows should upload artifacts, logs, and coverage data, and block merges when either host or guest pipelines fail.
