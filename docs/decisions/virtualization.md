# Virtualization Lifecycle Decisions

## Controller Responsibilities
- `VirtualMachineController` owns Virtualization.framework objects (VM, configuration, storage) and serializes lifecycle transitions.
- All state changes must run on a dedicated actor/queue so the daemon, CLI, and UI observe a consistent VM status snapshot.

## Boot/Suspend Policies
- Start the guest VM lazily when the first session arrives, but keep warm caches (disk images, bridged network interfaces) ready to minimize boot latency.
- Suspend or stop the VM when no Spice sessions are active and the daemon detects the configured idle timeout; send pre-suspend notifications to guest services so they can flush state.

## Configuration + Metrics
- Persist VM disk, memory, and network configuration alongside validation rules so misconfiguration is caught before Virtualization.framework throws.
- Emit metrics (boot duration, uptime, session counts, suspend latency) into the shared logging stack to feed dashboards and LaunchDaemon health checks.
