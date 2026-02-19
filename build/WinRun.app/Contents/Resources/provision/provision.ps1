# WinRun Provisioning Master Script
# This script orchestrates the complete Windows provisioning process.
# Called automatically by autounattend.xml FirstLogonCommands.

#Requires -RunAsAdministrator

param(
    [switch]$SkipDrivers,
    [switch]$SkipAgent,
    [switch]$SkipOptimize,
    [switch]$SkipFinalize
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Provisioning directory
$ProvisionDir = "C:\WinRun\provision"
$LogFile = "$ProvisionDir\provision.log"

# Ensure log directory exists
if (-not (Test-Path $ProvisionDir)) {
    New-Item -ItemType Directory -Path $ProvisionDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

function Send-ProvisionProgress {
    param(
        [string]$Phase,
        [int]$Percent,
        [string]$Message
    )
    # Write progress to a status file that can be read by Spice agent
    $Status = @{
        phase = $Phase
        percent = $Percent
        message = $Message
        timestamp = (Get-Date -Format "o")
    }
    $Status | ConvertTo-Json | Set-Content -Path "$ProvisionDir\status.json" -Force
    Write-Log "$Phase ($Percent%): $Message"
}

function Send-ProvisionError {
    param(
        [string]$Phase,
        [int]$ErrorCode,
        [string]$Message
    )
    $Status = @{
        phase = $Phase
        error_code = $ErrorCode
        message = $Message
        timestamp = (Get-Date -Format "o")
        success = $false
    }
    $Status | ConvertTo-Json | Set-Content -Path "$ProvisionDir\status.json" -Force
    Write-Log "$Phase FAILED: $Message" -Level "ERROR"
}

function Find-ProvisionScript {
    param([string]$ScriptPattern)
    
    # First try exact match
    $exactPath = Join-Path $ProvisionDir $ScriptPattern
    if (Test-Path $exactPath) {
        return $exactPath
    }
    
    # Try 8.3 compatible pattern (FAT12 floppy may truncate names)
    # e.g., "install-drivers.ps1" -> "INSTALL*.PS1"
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPattern)
    $searchPrefix = $baseName.Substring(0, [Math]::Min(7, $baseName.Length))
    $pattern = "$searchPrefix*.ps1"
    
    $matches = Get-ChildItem -Path $ProvisionDir -Filter $pattern -ErrorAction SilentlyContinue
    if ($matches) {
        return $matches[0].FullName
    }
    
    return $null
}

function Invoke-ProvisionScript {
    param(
        [string]$ScriptName,
        [string]$Phase,
        [int]$StartPercent,
        [int]$EndPercent
    )
    
    $ScriptPath = Find-ProvisionScript -ScriptPattern $ScriptName
    
    if (-not $ScriptPath) {
        Write-Log "Script not found: $ScriptName (searched $ProvisionDir) - skipping" -Level "WARN"
        return $true
    }
    
    $ActualName = [System.IO.Path]::GetFileName($ScriptPath)
    Send-ProvisionProgress -Phase $Phase -Percent $StartPercent -Message "Starting $ActualName..."
    
    try {
        & $ScriptPath
        Send-ProvisionProgress -Phase $Phase -Percent $EndPercent -Message "Completed $ActualName"
        return $true
    }
    catch {
        Send-ProvisionError -Phase $Phase -ErrorCode $LASTEXITCODE -Message $_.Exception.Message
        return $false
    }
}

# ============================================
# Main Provisioning Sequence
# ============================================

Write-Log "=========================================="
Write-Log "WinRun Provisioning Started"
Write-Log "=========================================="

$Success = $true

# Phase 1: VirtIO Drivers (0-25%)
if (-not $SkipDrivers) {
    if (-not (Invoke-ProvisionScript -ScriptName "install-drivers.ps1" -Phase "drivers" -StartPercent 0 -EndPercent 25)) {
        Write-Log "Driver installation failed, but continuing with provisioning" -Level "WARN"
        # Don't fail completely - drivers may already be installed
    }
} else {
    Write-Log "Skipping driver installation" -Level "INFO"
}

# Phase 2: WinRun Agent (25-50%)
if (-not $SkipAgent) {
    if (-not (Invoke-ProvisionScript -ScriptName "install-agent.ps1" -Phase "agent" -StartPercent 25 -EndPercent 50)) {
        Write-Log "Agent installation failed" -Level "ERROR"
        $Success = $false
    }
} else {
    Write-Log "Skipping agent installation" -Level "INFO"
}

# Phase 3: Windows Optimization (50-80%)
if (-not $SkipOptimize) {
    if (-not (Invoke-ProvisionScript -ScriptName "optimize-windows.ps1" -Phase "optimize" -StartPercent 50 -EndPercent 80)) {
        Write-Log "Optimization had errors, but continuing" -Level "WARN"
        # Don't fail - optimization is nice to have
    }
} else {
    Write-Log "Skipping Windows optimization" -Level "INFO"
}

# Phase 4: Finalization (80-100%)
if (-not $SkipFinalize) {
    if (-not (Invoke-ProvisionScript -ScriptName "finalize.ps1" -Phase "complete" -StartPercent 80 -EndPercent 100)) {
        Write-Log "Finalization failed" -Level "ERROR"
        $Success = $false
    }
} else {
    Write-Log "Skipping finalization" -Level "INFO"
}

Write-Log "=========================================="
if ($Success) {
    Write-Log "WinRun Provisioning Completed Successfully"
    Send-ProvisionProgress -Phase "complete" -Percent 100 -Message "Provisioning complete"
} else {
    Write-Log "WinRun Provisioning Completed with Errors"
}
Write-Log "=========================================="

exit $(if ($Success) { 0 } else { 1 })
