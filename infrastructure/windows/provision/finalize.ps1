# WinRun Finalization Script
# Performs final cleanup and signals completion to the host.
# Called by provision.ps1 as the last step of Windows provisioning.

#Requires -RunAsAdministrator

param(
    [switch]$NoShutdown,
    [switch]$NoReboot
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Script:ProvisionDir = "C:\WinRun\provision"
$Script:LogFile = "$Script:ProvisionDir\finalize.log"
$Script:StatusFile = "$Script:ProvisionDir\status.json"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $Script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Get-DiskUsageMB {
    try {
        $drive = Get-PSDrive -Name C
        $usedBytes = $drive.Used
        return [math]::Round($usedBytes / 1MB, 2)
    }
    catch {
        return 0
    }
}

function Get-WindowsVersion {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        return "$($os.Caption) (Build $($os.BuildNumber))"
    }
    catch {
        return "Unknown"
    }
}

function Get-AgentVersion {
    $exePath = "C:\Program Files\WinRun\WinRunAgent.exe"
    
    if (Test-Path $exePath) {
        try {
            $version = (Get-Item $exePath).VersionInfo.FileVersion
            if ($version) { return $version }
        }
        catch {}
    }
    
    # Try to get from service
    $service = Get-Service -Name "WinRunAgent" -ErrorAction SilentlyContinue
    if ($service) {
        return "Installed (version unknown)"
    }
    
    return "Not installed"
}

function Send-CompletionStatus {
    param(
        [bool]$Success,
        [string]$Message = ""
    )
    
    $diskUsage = Get-DiskUsageMB
    $windowsVersion = Get-WindowsVersion
    $agentVersion = Get-AgentVersion
    
    $status = @{
        phase = "complete"
        percent = 100
        success = $Success
        message = if ($Success) { "Provisioning complete" } else { $Message }
        timestamp = (Get-Date -Format "o")
        disk_usage_mb = $diskUsage
        windows_version = $windowsVersion
        agent_version = $agentVersion
    }
    
    # Write status file for host to read
    $status | ConvertTo-Json | Set-Content -Path $Script:StatusFile -Force
    
    Write-Log "Status file written: $Script:StatusFile"
    Write-Log "Disk usage: $diskUsage MB"
    Write-Log "Windows: $windowsVersion"
    Write-Log "Agent: $agentVersion"
    
    # Also create a completion marker file for simple detection
    $markerPath = "$Script:ProvisionDir\PROVISIONING_COMPLETE"
    if ($Success) {
        "SUCCESS" | Set-Content -Path $markerPath -Force
    } else {
        "FAILED: $Message" | Set-Content -Path $markerPath -Force
    }
}

function Disable-AutoLogon {
    Write-Log "Disabling auto-logon..."
    
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        
        # Remove auto-logon settings
        Remove-ItemProperty -Path $regPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "DefaultUserName" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue
        
        Write-Log "Auto-logon disabled"
    }
    catch {
        Write-Log "Could not disable auto-logon: $_" -Level "WARN"
    }
}

function Remove-ProvisioningArtifacts {
    Write-Log "Cleaning up provisioning artifacts..."
    
    # Remove setup scripts but keep logs
    $scriptsToRemove = @(
        "$Script:ProvisionDir\install-drivers.ps1",
        "$Script:ProvisionDir\install-agent.ps1",
        "$Script:ProvisionDir\optimize-windows.ps1",
        # Keep provision.ps1 for debugging
        # Keep finalize.ps1 for debugging
        # Keep all .log files
    )
    
    foreach ($script in $scriptsToRemove) {
        if (Test-Path $script) {
            Remove-Item -Path $script -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Clean up temp installer files
    $tempFiles = @(
        "C:\WinRun\*.msi",
        "C:\WinRun\*.exe",
        "$env:TEMP\*winrun*"
    )
    
    foreach ($pattern in $tempFiles) {
        Remove-Item -Path $pattern -Force -ErrorAction SilentlyContinue
    }
    
    Write-Log "Cleanup complete"
}

function Test-ProvisioningSuccess {
    $issues = @()
    
    # Check if WinRunAgent service is running
    $service = Get-Service -Name "WinRunAgent" -ErrorAction SilentlyContinue
    if (-not $service) {
        $issues += "WinRunAgent service not found"
    } elseif ($service.Status -ne "Running") {
        $issues += "WinRunAgent service is not running (status: $($service.Status))"
    }
    
    # Check for VirtIO drivers (at least network should be present)
    $virtioDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | 
        Where-Object { $_.DeviceName -like "*VirtIO*" } | 
        Select-Object -First 1
    
    if (-not $virtioDriver) {
        # This is a warning, not a failure - base drivers might work
        Write-Log "VirtIO drivers not detected - using default drivers" -Level "WARN"
    }
    
    # Check for network connectivity (basic test)
    $networkAdapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | 
        Where-Object { $_.Status -eq "Up" } | 
        Select-Object -First 1
    
    if (-not $networkAdapter) {
        Write-Log "No active network adapter detected" -Level "WARN"
    }
    
    return $issues
}

function Set-DefaultUserSettings {
    Write-Log "Configuring default user settings..."
    
    try {
        # Set power plan to high performance
        powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
        
        # Disable screen timeout (we're a VM)
        powercfg.exe /change monitor-timeout-ac 0 2>&1 | Out-Null
        powercfg.exe /change standby-timeout-ac 0 2>&1 | Out-Null
        powercfg.exe /change hibernate-timeout-ac 0 2>&1 | Out-Null
        
        Write-Log "Power settings configured for VM use"
    }
    catch {
        Write-Log "Could not configure power settings: $_" -Level "WARN"
    }
    
    try {
        # Enable Remote Desktop for potential debugging
        Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
            -Name "fDenyTSConnections" -Value 0 -ErrorAction SilentlyContinue
        
        # Enable the firewall rule
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        
        Write-Log "Remote Desktop enabled"
    }
    catch {
        Write-Log "Could not enable Remote Desktop: $_" -Level "WARN"
    }
}

# ============================================
# Main Script
# ============================================

Write-Log "=========================================="
Write-Log "Finalization Started"
Write-Log "=========================================="

# Run final checks
Write-Log "Running provisioning validation..."
$issues = Test-ProvisioningSuccess

if ($issues.Count -gt 0) {
    Write-Log "Provisioning issues detected:" -Level "WARN"
    foreach ($issue in $issues) {
        Write-Log "  - $issue" -Level "WARN"
    }
    $success = $false
    $message = $issues -join "; "
} else {
    Write-Log "All provisioning checks passed"
    $success = $true
    $message = ""
}

# Configure default settings
Set-DefaultUserSettings

# Signal completion to host (before cleanup so status file is correct)
Send-CompletionStatus -Success $success -Message $message

# Disable auto-logon (security)
Disable-AutoLogon

# Clean up provisioning files
Remove-ProvisioningArtifacts

Write-Log "=========================================="
Write-Log "Finalization Complete"
Write-Log "=========================================="

# Determine shutdown behavior
if ($NoShutdown -and $NoReboot) {
    Write-Log "Skipping shutdown/reboot as requested"
    exit $(if ($success) { 0 } else { 1 })
}

if ($NoReboot) {
    Write-Log "Shutting down for snapshot..."
    Start-Sleep -Seconds 2
    Stop-Computer -Force
} else {
    # Default: reboot to apply all changes, then the host can snapshot
    Write-Log "Rebooting to apply changes..."
    Start-Sleep -Seconds 2
    Restart-Computer -Force
}

exit $(if ($success) { 0 } else { 1 })
