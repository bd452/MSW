# Architecture Decisions Index

This directory organizes decision records by domain so contributors can link to the relevant guidance from TODO items, specs, and pull requests.

- [Spice Bridge Integration](decisions/spice-bridge.md) — binding strategy, streaming model, and resilience expectations for the Swift ↔ libspice-glib bridge.
- [Virtualization Lifecycle](decisions/virtualization.md) — ownership rules for `VirtualMachineController`, boot/suspend policies, and metrics requirements.
- [Host ↔ Guest Protocols](decisions/protocols.md) — transport, schema versioning, and security considerations for XPC and Spice payloads.
- [Operations & Packaging](decisions/operations.md) — build/bootstrap ownership, packaging targets, documentation expectations, and CI policies.

Add new records under `docs/decisions/` when architecture choices impact multiple tasks, then link them from the relevant TODO items.
