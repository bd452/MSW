# WinRun VirtIO Driver Installation Script
# Installs VirtIO drivers for optimal VM performance.
# Called by provision.ps1 during Windows provisioning.

#Requires -RunAsAdministrator

param(
    [string]$DriverSource = "D:\",  # VirtIO ISO mount point
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Script:ProvisionDir = "C:\WinRun\provision"
$Script:LogFile = "$Script:ProvisionDir\install-drivers.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $Script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Find-VirtIODriverSource {
    # Try common locations for VirtIO drivers
    $searchPaths = @(
        "D:\",           # VirtIO ISO mounted as second CD-ROM
        "E:\",           # Alternative mount point
        "A:\drivers",    # Floppy with embedded drivers
        "C:\WinRun\drivers"  # Pre-copied drivers
    )
    
    foreach ($path in $searchPaths) {
        $infPath = Join-Path $path "amd64\w11\*.inf"  # ARM64 uses amd64 folder naming in some ISOs
        $arm64Path = Join-Path $path "ARM64\w11\*.inf"
        
        if ((Test-Path $arm64Path) -or (Test-Path $infPath)) {
            Write-Log "Found VirtIO drivers at: $path"
            return $path
        }
        
        # Check for nested virtio-win structure
        $nestedPath = Join-Path $path "virtio-win"
        if (Test-Path $nestedPath) {
            Write-Log "Found VirtIO drivers at: $nestedPath"
            return $nestedPath
        }
    }
    
    return $null
}

function Get-WindowsVersion {
    $os = Get-CimInstance Win32_OperatingSystem
    $version = [version]$os.Version
    
    # Map Windows versions to VirtIO driver folder names
    switch ($version.Build) {
        { $_ -ge 22000 } { return "w11" }   # Windows 11
        { $_ -ge 19041 } { return "w10" }   # Windows 10 2004+
        { $_ -ge 17763 } { return "w10" }   # Windows 10 1809
        default { return "w10" }
    }
}

function Get-Architecture {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch) {
        "Arm64" { return "ARM64" }
        "X64" { return "amd64" }
        "X86" { return "x86" }
        default { return "ARM64" }  # Default to ARM64 for Apple Silicon VMs
    }
}

function Install-VirtIODriver {
    param(
        [string]$DriverPath,
        [string]$DriverName
    )
    
    Write-Log "Installing driver: $DriverName from $DriverPath"
    
    try {
        # Use pnputil to install the driver
        $result = pnputil.exe /add-driver "$DriverPath" /install 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0 -or $exitCode -eq 259) {
            # 0 = success, 259 = no more data (sometimes returned on success)
            Write-Log "Successfully installed: $DriverName"
            return $true
        } elseif ($exitCode -eq 3010) {
            Write-Log "Installed (reboot required): $DriverName"
            return $true
        } else {
            Write-Log "Failed to install $DriverName (exit code: $exitCode): $result" -Level "WARN"
            return $false
        }
    }
    catch {
        Write-Log "Exception installing $DriverName : $_" -Level "ERROR"
        return $false
    }
}

function Install-AllVirtIODrivers {
    param([string]$BasePath)
    
    $winVersion = Get-WindowsVersion
    $arch = Get-Architecture
    
    Write-Log "Detected Windows version: $winVersion, Architecture: $arch"
    
    # List of VirtIO drivers to install (in order of importance)
    $drivers = @(
        @{ Name = "VirtIO SCSI"; Folder = "vioscsi" },
        @{ Name = "VirtIO Serial"; Folder = "vioserial" },
        @{ Name = "VirtIO Network"; Folder = "NetKVM" },
        @{ Name = "VirtIO Balloon"; Folder = "Balloon" },
        @{ Name = "VirtIO RNG"; Folder = "viorng" },
        @{ Name = "VirtIO Input"; Folder = "vioinput" },
        @{ Name = "VirtIO GPU"; Folder = "viogpu" },
        @{ Name = "VirtIO FS"; Folder = "virtiofs" },
        @{ Name = "QEMU Guest Agent"; Folder = "guest-agent" },
        @{ Name = "SPICE Guest Tools"; Folder = "spice-guest-tools" }
    )
    
    $installed = 0
    $failed = 0
    
    foreach ($driver in $drivers) {
        # Try different path patterns
        $paths = @(
            (Join-Path $BasePath "$($driver.Folder)\$arch\$winVersion"),
            (Join-Path $BasePath "$($driver.Folder)\$winVersion\$arch"),
            (Join-Path $BasePath "$arch\$winVersion\$($driver.Folder)"),
            (Join-Path $BasePath "$($driver.Folder)")
        )
        
        $driverInstalled = $false
        
        foreach ($driverPath in $paths) {
            if (Test-Path $driverPath) {
                $infFiles = Get-ChildItem -Path $driverPath -Filter "*.inf" -ErrorAction SilentlyContinue
                
                foreach ($inf in $infFiles) {
                    if (Install-VirtIODriver -DriverPath $inf.FullName -DriverName $driver.Name) {
                        $driverInstalled = $true
                        break
                    }
                }
                
                if ($driverInstalled) { break }
            }
        }
        
        if ($driverInstalled) {
            $installed++
        } else {
            Write-Log "Driver not found or failed: $($driver.Name)" -Level "WARN"
            $failed++
        }
    }
    
    return @{
        Installed = $installed
        Failed = $failed
    }
}

function Install-SpiceGuestTools {
    param([string]$BasePath)
    
    # Look for SPICE guest tools installer
    $spiceInstallers = @(
        (Join-Path $BasePath "spice-guest-tools*.exe"),
        (Join-Path $BasePath "guest-agent\spice-guest-tools*.exe"),
        (Join-Path $BasePath "spice-guest-tools\spice-guest-tools*.exe")
    )
    
    foreach ($pattern in $spiceInstallers) {
        $installer = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($installer) {
            Write-Log "Installing SPICE guest tools from: $($installer.FullName)"
            
            try {
                $process = Start-Process -FilePath $installer.FullName -ArgumentList "/S" -Wait -PassThru
                
                if ($process.ExitCode -eq 0) {
                    Write-Log "SPICE guest tools installed successfully"
                    return $true
                } else {
                    Write-Log "SPICE guest tools installation failed with exit code: $($process.ExitCode)" -Level "WARN"
                }
            }
            catch {
                Write-Log "Exception installing SPICE guest tools: $_" -Level "ERROR"
            }
        }
    }
    
    Write-Log "SPICE guest tools installer not found" -Level "WARN"
    return $false
}

# ============================================
# Main Script
# ============================================

Write-Log "=========================================="
Write-Log "VirtIO Driver Installation Started"
Write-Log "=========================================="

# Find VirtIO driver source
$driverSource = if ($DriverSource -and (Test-Path $DriverSource)) {
    $DriverSource
} else {
    Find-VirtIODriverSource
}

if (-not $driverSource) {
    Write-Log "VirtIO driver source not found. Drivers may already be installed or ISO not mounted." -Level "WARN"
    Write-Log "Checking if essential drivers are already present..."
    
    # Check if we already have the essential drivers
    $scsiDriver = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -like "*VirtIO*SCSI*" }
    if ($scsiDriver) {
        Write-Log "VirtIO SCSI driver already installed. Assuming drivers are present."
        exit 0
    }
    
    Write-Log "No VirtIO drivers found. The VM may have limited functionality." -Level "WARN"
    exit 1
}

Write-Log "Using driver source: $driverSource"

# Install VirtIO drivers
$result = Install-AllVirtIODrivers -BasePath $driverSource

Write-Log "Driver installation complete: $($result.Installed) installed, $($result.Failed) failed/not found"

# Install SPICE guest tools if available
Install-SpiceGuestTools -BasePath $driverSource

Write-Log "=========================================="
Write-Log "VirtIO Driver Installation Complete"
Write-Log "=========================================="

# Return success if at least some drivers were installed
if ($result.Installed -gt 0) {
    exit 0
} elseif ($result.Failed -gt 0) {
    exit 1
} else {
    # No drivers found at all - might be okay if pre-installed
    exit 0
}
