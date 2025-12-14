# Virtualization Lifecycle Decisions

## Guest OS Selection

**Choice:** Windows 11 IoT Enterprise LTSC 2024 ARM64

**Rationale:**
- Apple Silicon Macs run ARM64 VMs natively via Virtualization.framework (no x86 emulation at the hypervisor level)
- Users need to run x86/x64 Windows applications (Office, legacy software, games)
- Windows 11 ARM64 includes **Prism**, Microsoft's x86/x64 emulation layer (~80% native performance)
- Windows Server ARM64 does **not** include Prism — only Windows 11 editions have it
- IoT Enterprise LTSC provides a minimal footprint (~16GB) with removable packages, 10-year support, and full Win32 API compatibility

**Alternatives Considered:**
| Option                         | Why Rejected                                          |
| ------------------------------ | ----------------------------------------------------- |
| Windows Server 2022/2025 ARM64 | No Prism = no x86/x64 app support                     |
| Windows 11 Pro ARM64           | Larger footprint, consumer features we don't need     |
| QEMU x86 emulation             | ~10x slower than native, unusable for interactive GUI |
| Rosetta + Wine on Linux VM     | Poor Windows app compatibility                        |

**Licensing:** IoT Enterprise requires volume licensing or OEM channels. For development, use the 90-day evaluation ISO from Microsoft Evaluation Center.

## Controller Responsibilities
- `VirtualMachineController` owns Virtualization.framework objects (VM, configuration, storage) and serializes lifecycle transitions.
- All state changes must run on a dedicated actor/queue so the daemon, CLI, and UI observe a consistent VM status snapshot.

## Boot/Suspend Policies
- Start the guest VM lazily when the first session arrives, but keep warm caches (disk images, bridged network interfaces) ready to minimize boot latency.
- Suspend or stop the VM when no Spice sessions are active and the daemon detects the configured idle timeout; send pre-suspend notifications to guest services so they can flush state.

## Configuration + Metrics
- Persist VM disk, memory, and network configuration alongside validation rules so misconfiguration is caught before Virtualization.framework throws.
- Emit metrics (boot duration, uptime, session counts, suspend latency) into the shared logging stack to feed dashboards and LaunchDaemon health checks.
