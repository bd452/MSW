# WinRunAgent Silent Uninstallation Script
# Removes the WinRunAgent MSI package silently for clean removal.
#
# Usage:
#   .\uninstall-silent.ps1 [-KeepData] [-LogDir <path>]
#
# Examples:
#   .\uninstall-silent.ps1
#   .\uninstall-silent.ps1 -KeepData

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # If specified, keeps log files and configuration data in ProgramData.
    [switch]$KeepData,

    # Directory for uninstallation logs. Defaults to temp directory.
    [string]$LogDir = $env:TEMP
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script configuration
$Script:ServiceName = "WinRunAgent"
$Script:ProductName = "WinRun Agent"
$Script:UpgradeCode = "E8F0D742-3B9A-4C2E-8F1D-6A5B7C8D9E0F"
$Script:LogFile = Join-Path $LogDir "WinRunAgent-Uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$Script:DataFolder = "C:\ProgramData\WinRun"

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

function Get-ProductCode {
    # Find the product code for WinRun Agent in the registry
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($path in $uninstallPaths) {
        if (Test-Path $path) {
            $products = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
            foreach ($product in $products) {
                $props = Get-ItemProperty -Path $product.PSPath -ErrorAction SilentlyContinue
                if ($props.DisplayName -eq $Script:ProductName) {
                    Write-Log "Found product code: $($product.PSChildName)"
                    return $product.PSChildName
                }
            }
        }
    }

    return $null
}

function Stop-WinRunService {
    Write-Log "Stopping WinRunAgent service..."

    $service = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue

    if (-not $service) {
        Write-Log "Service not found, may already be removed"
        return $true
    }

    if ($service.Status -eq "Stopped") {
        Write-Log "Service is already stopped"
        return $true
    }

    try {
        Stop-Service -Name $Script:ServiceName -Force -ErrorAction Stop

        # Wait for service to stop
        $timeout = 30
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            $service = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
            if (-not $service -or $service.Status -eq "Stopped") {
                Write-Log "Service stopped successfully"
                return $true
            }
            Start-Sleep -Seconds 1
            $elapsed++
        }

        Write-Log "Service did not stop within $timeout seconds" -Level "WARN"
        return $false
    }
    catch {
        Write-Log "Failed to stop service: $_" -Level "ERROR"
        return $false
    }
}

function Uninstall-WinRunAgent {
    param([string]$ProductCode)

    Write-Log "Starting WinRunAgent uninstallation..."

    $msiLogPath = Join-Path $LogDir "WinRunAgent-MSI-Uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    # Build msiexec arguments for silent uninstallation
    $arguments = @(
        "/x"
        "`"$ProductCode`""
        "/qn"                              # Quiet, no UI
        "/norestart"                       # Don't restart
        "/l*v"                             # Verbose logging
        "`"$msiLogPath`""                  # Log file
    )

    Write-Log "Running: msiexec.exe $($arguments -join ' ')"

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru

    switch ($process.ExitCode) {
        0 {
            Write-Log "MSI uninstallation completed successfully"
            return $true
        }
        1605 {
            Write-Log "Product is not installed"
            return $true
        }
        3010 {
            Write-Log "MSI uninstallation completed, reboot required"
            return $true
        }
        default {
            Write-Log "MSI uninstallation failed with exit code: $($process.ExitCode)" -Level "ERROR"

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

function Remove-DataFolder {
    if ($KeepData) {
        Write-Log "Keeping data folder at: $Script:DataFolder"
        return
    }

    if (Test-Path $Script:DataFolder) {
        Write-Log "Removing data folder: $Script:DataFolder"
        try {
            Remove-Item -Path $Script:DataFolder -Recurse -Force -ErrorAction Stop
            Write-Log "Data folder removed successfully"
        }
        catch {
            Write-Log "Failed to remove data folder: $_" -Level "WARN"
        }
    }
    else {
        Write-Log "Data folder does not exist"
    }
}

function Remove-RegistryKeys {
    $regPath = "HKLM:\Software\WinRun"
    if (Test-Path $regPath) {
        Write-Log "Removing registry keys: $regPath"
        try {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
            Write-Log "Registry keys removed successfully"
        }
        catch {
            Write-Log "Failed to remove registry keys: $_" -Level "WARN"
        }
    }
}

function Test-InstallationRemoved {
    # Check if service is gone
    $service = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-Log "Service still exists" -Level "WARN"
        return $false
    }

    # Check if install folder is gone
    $installDir = "C:\Program Files\WinRun"
    if (Test-Path $installDir) {
        $files = Get-ChildItem -Path $installDir -ErrorAction SilentlyContinue
        if ($files.Count -gt 0) {
            Write-Log "Installation folder still contains files" -Level "WARN"
            return $false
        }
    }

    return $true
}

# ============================================================================
# Main Script
# ============================================================================

Write-Log "=========================================="
Write-Log "WinRunAgent Silent Uninstallation"
Write-Log "=========================================="
Write-Log "Log file: $Script:LogFile"
Write-Log "Keep data: $KeepData"

# Find the product code
$productCode = Get-ProductCode

if (-not $productCode) {
    Write-Log "WinRunAgent is not installed (no product code found)"
    Write-Log "Nothing to uninstall"
    exit 0
}

# Stop the service first
if (-not (Stop-WinRunService)) {
    Write-Log "Could not stop service, attempting uninstallation anyway..." -Level "WARN"
}

# Perform uninstallation
if (-not (Uninstall-WinRunAgent -ProductCode $productCode)) {
    Write-Log "Uninstallation failed" -Level "ERROR"
    exit 1
}

# Clean up data folder if requested
Remove-DataFolder

# Clean up any remaining registry keys (MSI should handle this, but just in case)
Remove-RegistryKeys

# Verify uninstallation
if (Test-InstallationRemoved) {
    Write-Log "WinRunAgent has been completely removed"
}
else {
    Write-Log "Some components may remain. Manual cleanup may be required." -Level "WARN"
}

Write-Log "=========================================="
Write-Log "Uninstallation Complete"
Write-Log "=========================================="

exit 0
