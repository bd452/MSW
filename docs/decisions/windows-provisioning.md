# Windows Provisioning Decision Record

## Context

WinRun requires a Windows ARM64 virtual machine to run Windows applications. To provide a plug-and-play experience, we must automate the entire Windows installation and configuration process from a user-provided ISO.

## Recommended Windows Versions

### Primary Recommendation: Windows 11 IoT Enterprise LTSC 2024 ARM64

| Attribute         | Value                                   |
| ----------------- | --------------------------------------- |
| x86/x64 emulation | ✅ Full support                          |
| Bloatware         | ❌ None (no Store, Edge forced installs) |
| Update cadence    | Stable (LTSC = security only)           |
| Support lifecycle | 10 years                                |
| Disk footprint    | ~8GB (can strip to ~4GB)                |
| Licensing         | Volume/enterprise licensing required    |

### Acceptable Alternatives

| Version                     | x86/x64 Emulation | Bloat Level | Notes                              |
| --------------------------- | ----------------- | ----------- | ---------------------------------- |
| Windows 11 Pro/Home ARM64   | ✅ Full            | High        | Consumer bloat, aggressive updates |
| Windows 11 Enterprise ARM64 | ✅ Full            | Medium      | Less bloat than consumer           |
| Windows Server 2022 ARM64   | ❌ None            | Low         | No x86 translation layer           |
| Windows 10 ARM64            | ⚠️ x86 only        | Medium      | No x64 emulation                   |

### ISO Validation Warnings

The setup wizard should detect and warn about suboptimal ISOs:

1. **Windows Server (any version)**: "Windows Server does not include x86/x64 app compatibility. Most Windows applications won't run. Consider Windows 11 IoT Enterprise LTSC instead."

2. **Windows 10 ARM**: "Windows 10 ARM only supports 32-bit (x86) app emulation. 64-bit Windows apps won't work. Consider Windows 11 for full compatibility."

3. **Consumer Windows 11 (Home/Pro)**: "This Windows version includes consumer apps that will increase disk usage and may affect performance. For best results, use Windows 11 IoT Enterprise LTSC."

4. **Non-ARM ISO**: "This ISO is for Intel/AMD processors and cannot run on Apple Silicon. Please download the ARM64 version."

## Provisioning Architecture

### Phase 1: ISO Validation

```
User provides ISO
       ↓
┌─────────────────────────┐
│ ISOValidator            │
├─────────────────────────┤
│ • Mount ISO             │
│ • Read install.wim/esd  │
│ • Extract edition info  │
│ • Detect architecture   │
│ • Check for ARM64       │
│ • Identify version      │
│ • Return validation     │
│   result + warnings     │
└─────────────────────────┘
```

### Phase 2: Disk Creation

```
┌─────────────────────────┐
│ DiskImageCreator        │
├─────────────────────────┤
│ • Create sparse disk    │
│   (64GB default)        │
│ • Format as raw or      │
│   QCOW2 (if supported)  │
│ • Location:             │
│   ~/Library/App Support │
│   /WinRun/windows.img   │
└─────────────────────────┘
```

### Phase 3: Unattended Installation

The VM boots with:
- Installer ISO attached as **USB mass storage** (EFI-removable media discovery)
- Target disk attached as **virtio block** storage
- `autounattend.xml` injected via virtual floppy or in ISO

#### Boot Media Configuration (Documented Virtualization.framework Pattern)

WinRun follows Apple's documented installer paradigm from the Virtualization sample
"Running GUI Linux in a virtual machine on a Mac" (same EFI discovery mechanism):

1. Attach installer image as `VZUSBMassStorageDeviceConfiguration` (read-only)
2. Attach target OS disk as block storage
3. Use `VZEFIBootLoader` + `VZEFIVariableStore`
4. Let EFI discover bootable removable media and start installer

Why this matters for WinRun:

- Treating installer media as generic block devices can produce nondeterministic pre-driver boot behavior.
- Windows ARM installation media must be surfaced as EFI-discoverable removable media for predictable boot.
- Persisting/controlling EFI variable store is required to avoid stale boot-entry state across attempts.

Implementation alignment:

- `VMProvisioner` orders storage as: installer ISO first, then target disk.
- `VMProvisionerVirtualization` maps installer-phase ISO media (Windows installer + auxiliary autounattend/VirtIO media) to `VZUSBMassStorageDeviceConfiguration`.
- This avoids a bootstrap dependency where WinPE would need VirtIO block drivers before it can read the ISO that contains those drivers.
- `autounattend.xml` scans multiple possible drive letters for scripts/drivers to tolerate nondeterministic removable-media assignment.
- A shared persisted `MachineIdentifier` + `NVRAM` path is reused by both install and normal runtime boots.

**Autounattend.xml responsibilities:**
- Skip all OOBE screens
- Create local admin account (WinRun)
- Enable auto-login
- Configure regional settings
- Schedule first-logon provisioning script

### Phase 4: Post-Install Provisioning

After Windows OOBE completes:

```
┌─────────────────────────────────────────────────────────────────┐
│ FirstLogonCommand runs: C:\WinRun\provision.ps1                 │
├─────────────────────────────────────────────────────────────────┤
│ 1. install-drivers.ps1   → VirtIO drivers (disk, network, etc) │
│ 2. install-agent.ps1     → WinRunAgent.msi + service start     │
│ 3. optimize-windows.ps1  → Remove bloat, disable services      │
│ 4. finalize.ps1          → Signal completion to host, shutdown │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 5: Golden Snapshot

After provisioning completes:
- VM shuts down cleanly
- Host creates snapshot of disk state
- Future boots resume from snapshot (~2 second startup)

## Host↔Guest Signaling

During provisioning, the guest signals progress to the host via Spice agent channel:

```
MSG_PROVISION_PROGRESS {
    phase: string,        // "drivers", "agent", "optimize", "complete"
    percent: uint8,       // 0-100
    message: string       // Human-readable status
}

MSG_PROVISION_ERROR {
    phase: string,
    error_code: uint32,
    message: string
}

MSG_PROVISION_COMPLETE {
    success: bool,
    disk_usage_mb: uint64,
    windows_version: string,
    agent_version: string
}
```

## Windows Optimization

### Services to Disable

| Service                     | Reason                       |
| --------------------------- | ---------------------------- |
| DiagTrack                   | Telemetry                    |
| WSearch                     | Search indexing (not needed) |
| SysMain                     | Superfetch (VM overhead)     |
| TabletInputService          | Touch (not used)             |
| WbioSrvc                    | Biometrics                   |
| XblAuthManager, XblGameSave | Xbox                         |
| MapsBroker                  | Maps                         |
| lfsvc                       | Geolocation                  |

### AppX Packages to Remove

All Microsoft Store apps except core system components:
- Microsoft.WindowsStore
- Microsoft.Edge* (if removable)
- Microsoft.Bing*
- Microsoft.Xbox*
- Microsoft.ZuneMusic/Video
- Clipchamp, DevHome, QuickAssist
- Microsoft.People, YourPhone, WindowsFeedbackHub

### Registry Optimizations

- Disable Windows Update automatic restarts
- Disable Cortana
- Disable first-run animations
- Reduce telemetry level
- Disable lock screen

### Disk Optimization

- Run `Compact.exe /CompactOS:always` (reduces footprint by ~2GB)
- Clear temp files
- Remove Windows.old if present

## Resource Bundling

The app bundle includes:

```
WinRun.app/Contents/Resources/
├── provision/
│   ├── autounattend.xml
│   ├── install-drivers.ps1
│   ├── install-agent.ps1
│   ├── optimize-windows.ps1
│   └── finalize.ps1
├── WinRunAgent.msi
└── virtio-drivers.iso (or download URL in config)
```

### VirtIO Drivers

Options:
1. **Bundle in app** (~50MB): Immediate availability, larger download
2. **Download on demand**: Smaller app, requires internet during setup

Recommendation: Download on demand with bundled fallback URL. Cache locally after first download.

Source: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/

## Error Recovery

### Common Failure Scenarios

| Scenario              | Detection              | Recovery                        |
| --------------------- | ---------------------- | ------------------------------- |
| ISO mount failed      | hdiutil error          | Show error, allow retry         |
| Windows install hung  | No progress for 10min  | Offer cancel + retry            |
| Driver install failed | Non-zero exit code     | Log, continue with warning      |
| Agent install failed  | Service not responding | Retry, offer manual install     |
| Disk full             | Write error            | Show error, suggest larger disk |

### Rollback Strategy

If provisioning fails:
1. Stop VM
2. Offer to delete partial disk image
3. Allow retry with different ISO or settings

## Security Considerations

1. **No credentials in autounattend.xml**: Use blank password with auto-login
2. **Provisioning scripts signed**: Sign with Authenticode if distributing
3. **Firewall default deny**: Enable Windows Firewall with minimal rules
4. **VM isolation**: Rely on macOS hypervisor sandbox

## Testing Requirements

- ISO validation tests (mock ISO metadata)
- Provisioning state machine unit tests
- End-to-end integration test (requires Windows ARM ISO in CI)
- Error recovery tests
