# WinRunAgent Silent Installation Script
# Installs the WinRunAgent MSI package silently for provisioning automation.
#
# Usage:
#   .\install-silent.ps1 [-MsiPath <path>] [-InstallDir <path>] [-LogDir <path>]
#
# Examples:
#   .\install-silent.ps1
#   .\install-silent.ps1 -MsiPath "C:\Setup\WinRunAgent.msi"
#   .\install-silent.ps1 -InstallDir "D:\WinRun"

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Path to the WinRunAgent.msi file. If not specified, searches common locations.
    [string]$MsiPath,

    # Installation directory. Defaults to "C:\Program Files\WinRun".
    [string]$InstallDir = "C:\Program Files\WinRun",

    # Directory for installation logs. Defaults to temp directory.
    [string]$LogDir = $env:TEMP
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script configuration
$Script:ServiceName = "WinRunAgent"
$Script:LogFile = Join-Path $LogDir "WinRunAgent-Install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $Script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Find-MsiInstaller {
    # Search common locations for the MSI installer
    $searchPaths = @(
        # Same directory as this script
        (Join-Path $PSScriptRoot "WinRunAgent.Installer.msi"),
        (Join-Path $PSScriptRoot "WinRunAgent.msi"),
        # Virtual floppy (provisioning)
        "A:\WinRunAgent.msi",
        "A:\WinRunAgent.Installer.msi",
        # Provisioning directory
        "C:\WinRun\WinRunAgent.msi",
        "C:\WinRun\provision\WinRunAgent.msi",
        # CD-ROM drives
        "D:\WinRunAgent.msi",
        "E:\WinRunAgent.msi"
    )

    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            Write-Log "Found MSI installer at: $path"
            return $path
        }
    }

    return $null
}

function Test-ServiceInstalled {
    $service = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    return $null -ne $service
}

function Test-ServiceRunning {
    $service = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    return $service -and $service.Status -eq "Running"
}

function Get-InstalledVersion {
    # Check registry for installed version
    $regPath = "HKLM:\Software\WinRun"
    if (Test-Path $regPath) {
        $version = Get-ItemProperty -Path $regPath -Name "Version" -ErrorAction SilentlyContinue
        if ($version) {
            return $version.Version
        }
    }
    return $null
}

function Install-WinRunAgent {
    param([string]$InstallerPath)

    Write-Log "Starting WinRunAgent installation from: $InstallerPath"

    $msiLogPath = Join-Path $LogDir "WinRunAgent-MSI-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    # Build msiexec arguments for silent installation
    $arguments = @(
        "/i"
        "`"$InstallerPath`""
        "/qn"                              # Quiet, no UI
        "/norestart"                       # Don't restart
        "INSTALLDIR=`"$InstallDir`""       # Installation directory
        "/l*v"                             # Verbose logging
        "`"$msiLogPath`""                  # Log file
    )

    Write-Log "Running: msiexec.exe $($arguments -join ' ')"

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru

    switch ($process.ExitCode) {
        0 {
            Write-Log "MSI installation completed successfully"
            return $true
        }
        1641 {
            Write-Log "MSI installation completed, reboot initiated"
            return $true
        }
        3010 {
            Write-Log "MSI installation completed, reboot required"
            return $true
        }
        1618 {
            Write-Log "Another installation is in progress. Please wait and retry." -Level "ERROR"
            return $false
        }
        1619 {
            Write-Log "MSI package could not be opened. File may be corrupted." -Level "ERROR"
            return $false
        }
        default {
            Write-Log "MSI installation failed with exit code: $($process.ExitCode)" -Level "ERROR"

            # Try to extract useful information from MSI log
            if (Test-Path $msiLogPath) {
                $errorLines = Get-Content $msiLogPath -Tail 50 | Select-String -Pattern "error|failed" -Context 0,2
                if ($errorLines) {
                    Write-Log "MSI log errors:" -Level "ERROR"
                    foreach ($line in $errorLines) {
                        Write-Log "  $($line.Line)" -Level "ERROR"
                    }
                }
            }

            return $false
        }
    }
}

function Wait-ForService {
    param([int]$TimeoutSeconds = 30)

    Write-Log "Waiting for WinRunAgent service to start..."

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-ServiceRunning) {
            Write-Log "WinRunAgent service is running"
            return $true
        }
        Start-Sleep -Seconds 1
        $elapsed++
    }

    Write-Log "Service did not start within $TimeoutSeconds seconds" -Level "WARN"
    return $false
}

# ============================================================================
# Main Script
# ============================================================================

Write-Log "=========================================="
Write-Log "WinRunAgent Silent Installation"
Write-Log "=========================================="
Write-Log "Log file: $Script:LogFile"

# Check if already installed
$existingVersion = Get-InstalledVersion
if ($existingVersion) {
    if (Test-ServiceRunning) {
        Write-Log "WinRunAgent version $existingVersion is already installed and running"
        Write-Log "Use uninstall-silent.ps1 first to reinstall"
        exit 0
    }
    else {
        Write-Log "WinRunAgent version $existingVersion is installed but not running"
        Write-Log "Proceeding with reinstallation..."
    }
}

# Find the MSI installer
$installerPath = if ($MsiPath -and (Test-Path $MsiPath)) {
    $MsiPath
}
else {
    Find-MsiInstaller
}

if (-not $installerPath) {
    Write-Log "WinRunAgent MSI installer not found" -Level "ERROR"
    Write-Log "Searched locations: script directory, A:\, C:\WinRun\, D:\, E:\" -Level "ERROR"
    Write-Log "Specify path with: -MsiPath <path>" -Level "ERROR"
    exit 1
}

# Perform installation
if (-not (Install-WinRunAgent -InstallerPath $installerPath)) {
    Write-Log "Installation failed" -Level "ERROR"
    exit 1
}

# Wait for service to start
if (-not (Wait-ForService -TimeoutSeconds 30)) {
    Write-Log "Service installed but not running. Manual start may be required." -Level "WARN"
}

# Verify installation
$installedVersion = Get-InstalledVersion
if ($installedVersion) {
    Write-Log "Successfully installed WinRunAgent version $installedVersion"
}
else {
    Write-Log "Installation completed but version could not be verified" -Level "WARN"
}

Write-Log "=========================================="
Write-Log "Installation Complete"
Write-Log "=========================================="

exit 0
