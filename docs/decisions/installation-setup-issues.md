# Installation/Setup Flow Issues Analysis

**Date**: January 30, 2026  
**Branch**: `cursor/installation-setup-flow-bf7c`

## Executive Summary

The current WinRun installation/setup flow has several critical issues that would prevent successful Windows provisioning. This document catalogs these issues in order of severity.

---

## Critical Issues (Blocking)

### 1. FloppyImageCreator Uses Wrong Filename for autounattend.xml

**Location**: `host/Sources/WinRunSetup/FloppyImageCreator.swift:134`

**Problem**: The floppy image creator stores `autounattend.xml` as `AUTOUNAT.XML` (8.3 format):

```swift
var files: [String: URL] = [
    "AUTOUNAT.XML": autounattendPath  // 8.3 format for FAT12 compatibility
]
```

Windows Setup specifically looks for files named `autounattend.xml` or `Autounattend.xml` on removable media. The 8.3 truncated name `AUTOUNAT.XML` will NOT be recognized by Windows Setup.

**Impact**: Windows installation will NOT be unattended — user will see manual prompts.

**Fix**: Use a filename Windows recognizes. While FAT12 requires 8.3 format, Windows Setup on modern Windows 11 can read long filenames from FAT12 if the proper long filename entries (LFN) are stored. Alternatively, we could use a larger FAT16/FAT32 floppy image or use a small ISO image instead.

---

### 2. VMProvisioner Doesn't Actually Boot the VM

**Location**: `host/Sources/WinRunSetup/VMProvisioner.swift:328-378`

**Problem**: The `runInstallationPhases()` and `runSinglePhase()` methods only simulate installation progress with `Task.sleep()`:

```swift
private func runSinglePhase(...) async throws {
    for step in 1...10 {
        if isCancelled() { throw WinRunError.cancelled }
        try await Task.sleep(nanoseconds: 10_000_000)  // Just simulates!
        // ...
    }
}
```

The `VMProvisioner` creates a `ProvisioningVMConfiguration` with storage devices and CPU/memory settings, but this configuration is never actually used to boot a VM. There's no call to `VirtualMachineController` or any Virtualization.framework APIs.

**Impact**: No Windows installation will occur — the setup wizard will show fake progress and "complete" without installing anything.

**Fix**: Implement actual VM booting using the provisioning configuration. This requires:
1. Creating a `VZVirtualMachineConfiguration` from `ProvisioningVMConfiguration`
2. Attaching the Windows ISO as a bootable CD-ROM
3. Attaching the floppy with autounattend.xml
4. Booting the VM and monitoring Windows Setup progress

---

### 3. SetupWizardCoordinator Doesn't Pass autounattendPath

**Location**: `host/Sources/WinRunApp/Setup/SetupWizardCoordinator.swift:268-276`

**Problem**: When starting provisioning, the coordinator creates a config without the autounattend path:

```swift
private func beginProvisioning(isoPath: URL) {
    provisioningTask = Task { [weak self] in
        guard let self else { return }

        let config = SetupCoordinatorConfiguration(
            isoPath: isoPath,
            diskImagePath: self.diskImagePath
            // autounattendPath is nil!
        )
        // ...
    }
}
```

Even though `SetupCoordinatorConfiguration` accepts an `autounattendPath` parameter, it's never provided. This means unattended installation won't work even if the other issues were fixed.

**Impact**: Even if the VM was actually booted, Windows would not find the autounattend.xml because the floppy wouldn't be created.

**Fix**: Pass the bundled `autounattend.xml` path from the app bundle resources or infrastructure directory.

---

### 4. No EFI NVRAM Store for Fresh Installation

**Location**: `host/Sources/WinRunVirtualMachine/VirtualMachineController.swift:399-410`

**Problem**: The VM configuration uses `VZEFIBootLoader()` but doesn't provide EFI variable storage:

```swift
vmConfig.bootLoader = VZEFIBootLoader()
```

For Windows ARM64 installation, an EFI variable store is required. During first boot from ISO, the bootloader writes NVRAM variables that persist across reboots. Without a variable store:
- First boot from ISO might work (UEFI firmware defaults)
- But after installation, subsequent boots will fail because Windows boot manager entries won't persist

**Impact**: Windows installation might complete, but the VM won't boot from the installed disk afterward.

**Fix**: Create and configure `VZEFIVariableStore`:
```swift
let efiStore = try VZEFIVariableStore(creatingVariableStoreAt: efiVarsURL)
let bootLoader = VZEFIBootLoader(variableStore: efiStore)
vmConfig.bootLoader = bootLoader
```

---

### 5. No VirtIO Drivers or WinRunAgent MSI Included

**Location**: `infrastructure/windows/provision/install-drivers.ps1`, `install-agent.ps1`

**Problem**: The provisioning scripts expect to find:
- VirtIO drivers at `D:\`, `E:\`, or `A:\drivers`
- `WinRunAgent.msi` at `A:\`, `C:\WinRun\`, or `D:\`

But the current provisioning flow doesn't:
1. Mount a VirtIO driver ISO
2. Include the WinRunAgent.msi on the floppy or anywhere accessible

**Impact**: 
- Without VirtIO drivers, the VM will have degraded performance (generic Windows drivers)
- Without WinRunAgent, there's no guest-side communication — no window tracking, frame streaming, or input injection

**Fix**: 
1. Download and bundle VirtIO drivers ISO (from Fedora/Red Hat)
2. Include the VirtIO ISO as a secondary CD-ROM during provisioning
3. Build and bundle `WinRunAgent.msi` for inclusion (could go on the floppy if small enough, or a secondary ISO)

---

## High-Priority Issues

### 6. Provisioning Script Filename Truncation

**Location**: `host/Sources/WinRunSetup/FloppyImageCreator.swift:138-141`

**Problem**: Provisioning scripts are truncated to 8.3 format:

| Original Name | 8.3 Name |
|--------------|----------|
| `provision.ps1` | `PROVISIO.PS1` |
| `install-drivers.ps1` | `INSTALL-.PS1` |
| `install-agent.ps1` | `INSTALL-.PS1` (collision!) |
| `optimize-windows.ps1` | `OPTIMIZE.PS1` |
| `finalize.ps1` | `FINALIZE.PS1` |

The `install-drivers.ps1` and `install-agent.ps1` both become `INSTALL-.PS1`, causing a collision.

The autounattend.xml references scripts by exact name:
```xml
<CommandLine>powershell.exe ... -File C:\WinRun\provision\provision.ps1</CommandLine>
```

But the specialize pass copies files from floppy:
```xml
<Path>cmd /c if exist A:\*.PS1 copy A:\*.PS1 C:\WinRun\provision\</Path>
```

This will copy the truncated names, not the expected names.

**Impact**: The provisioning scripts won't be found or will overwrite each other.

**Fix**: Either:
1. Use a FAT16/FAT32 image that supports LFN (Long File Names)
2. Or use short unique names that don't truncate (e.g., `drivers.ps1`, `agent.ps1`, `setup.ps1`)

---

### 7. No Communication Channel During Initial Installation

**Location**: `host/Sources/WinRunSetup/SetupCoordinator.swift:319-332`

**Problem**: The `runPostInstallProvisioning()` method expects to receive progress updates from the guest via Spice control channel:

```swift
if controlChannel != nil {
    try await waitForGuestProvisioning()
} else {
    try await simulateGuestProvisioning()
}
```

During initial Windows installation and provisioning:
1. There's no Spice agent running (it gets installed by `install-agent.ps1`)
2. The WinRunAgent isn't installed yet
3. There's no way to communicate progress from guest to host

The code falls back to simulation, which is why progress appears to work in testing.

**Impact**: The host has no visibility into actual provisioning progress. The "Installing Windows..." phase will show fake progress while real installation takes 10-15 minutes with no feedback.

**Fix**: Options:
1. Use vsock for simple progress reporting (guest writes to a vsock port, host reads)
2. Monitor the guest disk for marker files (e.g., `C:\WinRun\provision\status.json`)
3. Use shared memory for status communication
4. Simply show indeterminate progress during Windows Setup phase, then connect via vsock for post-install provisioning

---

### 8. Boot Order Not Configured for Installation

**Location**: `host/Sources/WinRunVirtualMachine/VirtualMachineController.swift:399-441`

**Problem**: When provisioning, the VM needs to boot from the ISO first, then from the disk after installation. The current configuration doesn't set boot order:

```swift
vmConfig.storageDevices = [blockDevice]  // Just the disk
// ISO not attached, no boot order
```

The `ProvisioningVMConfiguration` includes the ISO as a bootable device, but this config is never used.

**Impact**: Even if the VM was booted, it wouldn't boot from the Windows ISO.

**Fix**: During provisioning:
1. Attach ISO as bootable storage device
2. Set boot order to ISO first, disk second
3. After installation, detach ISO and boot from disk

---

## Medium-Priority Issues

### 9. Missing Progress Indicators for Real Installation Time

**Problem**: Windows 11 ARM64 installation takes 10-15 minutes or longer. The current simulated phases complete in under 1 second total.

**Fix**: Implement realistic time estimates and progress tracking.

---

### 10. No Error Recovery from Partial Installation

**Problem**: If installation fails midway, there's no way to:
1. Resume from where it stopped
2. Clean up partial state
3. Show diagnostic information

The rollback mechanism exists in `SetupCoordinator` but it just deletes the disk image.

**Fix**: Save installation state checkpoints and implement intelligent recovery.

---

### 11. Floppy Image Too Small for All Content

**Problem**: FAT12 floppy is 1.44MB. Contents needed:
- `autounattend.xml` (~3KB)
- 5 PowerShell scripts (~15KB total)
- Potentially `WinRunAgent.exe` (~500KB-2MB)

If WinRunAgent is larger than ~1MB, it won't fit on the floppy with everything else.

**Fix**: Use alternative delivery mechanisms:
1. Create a secondary ISO for agent/drivers
2. Use VirtioFS to share files from host
3. Download agent from the network during provisioning

---

## Recommendations

### Short-Term Fixes (Required for MVP)

1. **Fix autounattend.xml filename** - Use proper LFN in FAT12 or switch to FAT16
2. **Implement actual VM booting** - Connect VMProvisioner to VirtualMachineController
3. **Pass autounattendPath** - Wire up the bundled autounattend.xml
4. **Add EFI variable store** - Required for Windows boot persistence
5. **Resolve script name collisions** - Use unique 8.3 names

### Medium-Term Improvements

1. Bundle VirtIO drivers ISO
2. Implement vsock-based progress reporting
3. Add checkpoints for installation recovery
4. Show realistic time estimates

### Architecture Considerations

Consider separating the provisioning VM configuration from the runtime VM configuration. During provisioning:
- Mount Windows ISO as boot device
- Mount VirtIO drivers ISO
- Include floppy with autounattend
- Use more aggressive timeouts (30+ minutes for installation)

After provisioning:
- Detach ISOs
- Boot from installed disk
- Enable Spice, shared memory, etc.

---

## Test Matrix

To verify fixes, test with:

| ISO Type | Expected Result |
|----------|----------------|
| Windows 11 IoT Enterprise LTSC ARM64 | Full unattended install |
| Windows 11 Pro ARM64 | Install with consumer warnings |
| Windows 11 x64 | Fail validation (wrong arch) |
| Windows Server ARM64 | Install with Prism warning |
| Corrupted/Invalid ISO | Fail validation with error |

---

## References

- [Windows Unattended Installation Reference](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/update-windows-settings-and-scripts-create-your-own-answer-file-sxs)
- [Apple Virtualization.framework Documentation](https://developer.apple.com/documentation/virtualization)
- [VirtIO Drivers for Windows](https://github.com/virtio-win/virtio-win-pkg-scripts)
