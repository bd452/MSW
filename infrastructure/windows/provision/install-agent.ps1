# WinRun Agent Installation Script
# Installs the WinRunAgent service for host-guest communication.
# Called by provision.ps1 during Windows provisioning.

#Requires -RunAsAdministrator

param(
    [string]$MsiPath,           # Path to WinRunAgent.msi
    [string]$InstallDir = "C:\Program Files\WinRun",
    [switch]$SkipServiceStart
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Script:ProvisionDir = "C:\WinRun\provision"
$Script:LogFile = "$Script:ProvisionDir\install-agent.log"
$Script:ServiceName = "WinRunAgent"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $Script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Find-AgentInstaller {
    # Search common locations for the WinRunAgent installer
    $searchPaths = @(
        "A:\WinRunAgent.msi",           # Virtual floppy
        "C:\WinRun\WinRunAgent.msi",    # Pre-copied location
        "D:\WinRunAgent.msi",           # CD-ROM
        "E:\WinRunAgent.msi",           # Secondary CD-ROM
        "$Script:ProvisionDir\WinRunAgent.msi"
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            Write-Log "Found WinRunAgent installer at: $path"
            return $path
        }
    }
    
    # Also search for .exe installer
    $exePaths = @(
        "A:\WinRunAgent.exe",
        "C:\WinRun\WinRunAgent.exe",
        "$Script:ProvisionDir\WinRunAgent.exe"
    )
    
    foreach ($path in $exePaths) {
        if (Test-Path $path) {
            Write-Log "Found WinRunAgent executable at: $path"
            return $path
        }
    }
    
    return $null
}

function Install-FromMsi {
    param([string]$InstallerPath)
    
    Write-Log "Installing WinRunAgent from MSI: $InstallerPath"
    
    $logPath = "$Script:ProvisionDir\msi-install.log"
    $arguments = @(
        "/i"
        "`"$InstallerPath`""
        "/qn"                          # Quiet, no UI
        "/norestart"                   # Don't restart
        "INSTALLDIR=`"$InstallDir`""   # Install location
        "/l*v"                         # Verbose logging
        "`"$logPath`""
    )
    
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
    
    if ($process.ExitCode -eq 0) {
        Write-Log "MSI installation completed successfully"
        return $true
    } elseif ($process.ExitCode -eq 3010) {
        Write-Log "MSI installation completed (reboot required)"
        return $true
    } else {
        Write-Log "MSI installation failed with exit code: $($process.ExitCode)" -Level "ERROR"
        
        # Try to extract useful info from MSI log
        if (Test-Path $logPath) {
            $errorLines = Get-Content $logPath | Select-String -Pattern "error|failed" -Context 0,2
            if ($errorLines) {
                Write-Log "MSI log errors: $($errorLines | Out-String)" -Level "ERROR"
            }
        }
        
        return $false
    }
}

function Install-FromExecutable {
    param([string]$ExePath)
    
    Write-Log "Installing WinRunAgent from executable: $ExePath"
    
    # Create installation directory
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    
    # Copy the executable
    $destPath = Join-Path $InstallDir "WinRunAgent.exe"
    Copy-Item -Path $ExePath -Destination $destPath -Force
    
    Write-Log "Copied agent to: $destPath"
    
    # Register as a Windows service
    $servicePath = "`"$destPath`""
    
    # Check if service already exists
    $existingService = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Log "Service already exists, stopping and removing..."
        Stop-Service -Name $Script:ServiceName -Force -ErrorAction SilentlyContinue
        sc.exe delete $Script:ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
    
    # Create the service
    Write-Log "Creating Windows service: $Script:ServiceName"
    $result = sc.exe create $Script:ServiceName binPath= $servicePath start= auto DisplayName= "WinRun Agent"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to create service: $result" -Level "ERROR"
        return $false
    }
    
    # Set service description
    sc.exe description $Script:ServiceName "WinRun guest agent for host-guest communication" | Out-Null
    
    # Configure service recovery options (restart on failure)
    sc.exe failure $Script:ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    
    Write-Log "Service created successfully"
    return $true
}

function Start-AgentService {
    Write-Log "Starting WinRunAgent service..."
    
    try {
        Start-Service -Name $Script:ServiceName -ErrorAction Stop
        
        # Wait for service to be running
        $timeout = 30
        $elapsed = 0
        
        while ($elapsed -lt $timeout) {
            $service = Get-Service -Name $Script:ServiceName
            if ($service.Status -eq "Running") {
                Write-Log "WinRunAgent service is running"
                return $true
            }
            
            Start-Sleep -Seconds 1
            $elapsed++
        }
        
        Write-Log "Service did not start within $timeout seconds" -Level "WARN"
        return $false
    }
    catch {
        Write-Log "Failed to start service: $_" -Level "ERROR"
        return $false
    }
}

function Test-AgentRunning {
    $service = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
    
    if ($service -and $service.Status -eq "Running") {
        Write-Log "WinRunAgent service is running"
        return $true
    }
    
    return $false
}

function Get-AgentVersion {
    $exePath = Join-Path $InstallDir "WinRunAgent.exe"
    
    if (Test-Path $exePath) {
        try {
            $version = (Get-Item $exePath).VersionInfo.FileVersion
            return $version
        }
        catch {
            return "Unknown"
        }
    }
    
    return $null
}

# ============================================
# Main Script
# ============================================

Write-Log "=========================================="
Write-Log "WinRunAgent Installation Started"
Write-Log "=========================================="

# Check if agent is already installed and running
if (Test-AgentRunning) {
    $version = Get-AgentVersion
    Write-Log "WinRunAgent is already installed and running (version: $version)"
    exit 0
}

# Find the installer
$installerPath = if ($MsiPath -and (Test-Path $MsiPath)) {
    $MsiPath
} else {
    Find-AgentInstaller
}

if (-not $installerPath) {
    Write-Log "WinRunAgent installer not found" -Level "ERROR"
    Write-Log "Searched locations: A:\, C:\WinRun\, D:\, provision directory"
    exit 1
}

# Install based on file type
$extension = [System.IO.Path]::GetExtension($installerPath).ToLower()

$installSuccess = switch ($extension) {
    ".msi" { Install-FromMsi -InstallerPath $installerPath }
    ".exe" { Install-FromExecutable -ExePath $installerPath }
    default {
        Write-Log "Unknown installer type: $extension" -Level "ERROR"
        $false
    }
}

if (-not $installSuccess) {
    Write-Log "WinRunAgent installation failed" -Level "ERROR"
    exit 1
}

# Start the service unless skipped
if (-not $SkipServiceStart) {
    if (-not (Start-AgentService)) {
        Write-Log "WinRunAgent installed but failed to start" -Level "WARN"
        # Don't fail completely - service might need reboot
    }
}

# Verify installation
$version = Get-AgentVersion
if ($version) {
    Write-Log "WinRunAgent version $version installed successfully"
} else {
    Write-Log "WinRunAgent installation could not be verified" -Level "WARN"
}

Write-Log "=========================================="
Write-Log "WinRunAgent Installation Complete"
Write-Log "=========================================="

exit 0
