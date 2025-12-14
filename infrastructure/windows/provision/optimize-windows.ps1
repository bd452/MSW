# WinRun Windows Optimization Script
# Optimizes Windows for VM performance by disabling unnecessary services,
# removing bloatware, and applying registry tweaks.
# Called by provision.ps1 during Windows provisioning.

#Requires -RunAsAdministrator

param(
    [switch]$SkipAppRemoval,
    [switch]$SkipServiceOptimization,
    [switch]$SkipRegistryTweaks,
    [switch]$SkipDiskOptimization
)

$ErrorActionPreference = "Continue"  # Continue on errors for optimization
$ProgressPreference = "SilentlyContinue"

$Script:ProvisionDir = "C:\WinRun\provision"
$Script:LogFile = "$Script:ProvisionDir\optimize-windows.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $Script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

# ============================================
# Service Optimization
# ============================================

function Disable-UnnecessaryServices {
    Write-Log "Disabling unnecessary services..."
    
    # Services to disable for VM optimization
    # See docs/decisions/windows-provisioning.md for rationale
    $servicesToDisable = @(
        @{ Name = "DiagTrack"; Reason = "Telemetry" },
        @{ Name = "WSearch"; Reason = "Search indexing (not needed in VM)" },
        @{ Name = "SysMain"; Reason = "Superfetch (VM overhead)" },
        @{ Name = "TabletInputService"; Reason = "Touch input (not used)" },
        @{ Name = "WbioSrvc"; Reason = "Windows Biometric Service" },
        @{ Name = "XblAuthManager"; Reason = "Xbox Live Auth" },
        @{ Name = "XblGameSave"; Reason = "Xbox Game Save" },
        @{ Name = "XboxGipSvc"; Reason = "Xbox Accessory Management" },
        @{ Name = "XboxNetApiSvc"; Reason = "Xbox Live Networking" },
        @{ Name = "MapsBroker"; Reason = "Downloaded Maps Manager" },
        @{ Name = "lfsvc"; Reason = "Geolocation Service" },
        @{ Name = "WerSvc"; Reason = "Windows Error Reporting" },
        @{ Name = "dmwappushservice"; Reason = "WAP Push Message Service" },
        @{ Name = "RetailDemo"; Reason = "Retail Demo Service" },
        @{ Name = "RemoteRegistry"; Reason = "Remote Registry" },
        @{ Name = "SharedAccess"; Reason = "Internet Connection Sharing" },
        @{ Name = "Fax"; Reason = "Fax Service" },
        @{ Name = "wisvc"; Reason = "Windows Insider Service" }
    )
    
    $disabled = 0
    $skipped = 0
    
    foreach ($svc in $servicesToDisable) {
        $service = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        
        if ($service) {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                Write-Log "Disabled: $($svc.Name) ($($svc.Reason))"
                $disabled++
            }
            catch {
                Write-Log "Could not disable $($svc.Name): $_" -Level "WARN"
                $skipped++
            }
        } else {
            $skipped++
        }
    }
    
    Write-Log "Services: $disabled disabled, $skipped skipped/not found"
    return $disabled
}

# ============================================
# AppX Package Removal
# ============================================

function Remove-BloatwareApps {
    Write-Log "Removing bloatware applications..."
    
    # AppX packages to remove
    # Wildcards used for version-agnostic matching
    $packagesToRemove = @(
        # Microsoft Store apps
        "Microsoft.BingNews",
        "Microsoft.BingWeather",
        "Microsoft.BingFinance",
        "Microsoft.BingSports",
        "Microsoft.GetHelp",
        "Microsoft.Getstarted",
        "Microsoft.Microsoft3DViewer",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.MixedReality.Portal",
        "Microsoft.People",
        "Microsoft.SkypeApp",
        "Microsoft.Wallet",
        "Microsoft.WindowsAlarms",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsMaps",
        "Microsoft.WindowsSoundRecorder",
        "Microsoft.Xbox.TCUI",
        "Microsoft.XboxApp",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.YourPhone",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Clipchamp.Clipchamp",
        "Microsoft.Todos",
        "Microsoft.PowerAutomateDesktop",
        "Microsoft.549981C3F5F10",  # Cortana
        "MicrosoftCorporationII.QuickAssist",
        "Microsoft.WindowsCommunicationsApps",  # Mail & Calendar
        "Microsoft.GamingApp",
        "Microsoft.MicrosoftStickyNotes",
        "Microsoft.Paint",  # Keep new Paint? Maybe optional
        "Microsoft.ScreenSketch",
        "Microsoft.WindowsCamera"
    )
    
    $removed = 0
    $failed = 0
    
    foreach ($package in $packagesToRemove) {
        try {
            $apps = Get-AppxPackage -Name "*$package*" -AllUsers -ErrorAction SilentlyContinue
            
            if ($apps) {
                foreach ($app in $apps) {
                    Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                    Write-Log "Removed: $($app.Name)"
                    $removed++
                }
            }
            
            # Also remove provisioned packages to prevent reinstall
            $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | 
                Where-Object { $_.DisplayName -like "*$package*" }
            
            if ($provisioned) {
                foreach ($prov in $provisioned) {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            Write-Log "Could not remove $package : $_" -Level "WARN"
            $failed++
        }
    }
    
    Write-Log "Apps: $removed removed, $failed failed"
    return $removed
}

# ============================================
# Registry Optimizations
# ============================================

function Apply-RegistryOptimizations {
    Write-Log "Applying registry optimizations..."
    
    $changes = 0
    
    # Helper function to set registry value
    function Set-RegValue {
        param(
            [string]$Path,
            [string]$Name,
            $Value,
            [string]$Type = "DWord"
        )
        
        try {
            if (-not (Test-Path $Path)) {
                New-Item -Path $Path -Force | Out-Null
            }
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
            return $true
        }
        catch {
            Write-Log "Failed to set $Path\$Name : $_" -Level "WARN"
            return $false
        }
    }
    
    # Disable Windows Update automatic restart
    Write-Log "Disabling automatic restart for updates..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value 2) { $changes++ }
    
    # Disable Cortana
    Write-Log "Disabling Cortana..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1) { $changes++ }
    
    # Disable first-run animations
    Write-Log "Disabling first-run animations..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableFirstLogonAnimation" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "EnableFirstLogonAnimation" -Value 0) { $changes++ }
    
    # Reduce telemetry level
    Write-Log "Reducing telemetry..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0) { $changes++ }
    
    # Disable lock screen
    Write-Log "Disabling lock screen..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1) { $changes++ }
    
    # Disable Windows tips and suggestions
    Write-Log "Disabling Windows tips..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -Value 1) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1) { $changes++ }
    
    # Disable Game Bar
    Write-Log "Disabling Game Bar..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0) { $changes++ }
    
    # Disable Windows Defender SmartScreen for apps
    Write-Log "Adjusting SmartScreen..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name "SmartScreenEnabled" -Value "Off" -Type "String") { $changes++ }
    
    # Disable activity history
    Write-Log "Disabling activity history..."
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0) { $changes++ }
    
    # Performance optimizations
    Write-Log "Applying performance tweaks..."
    if (Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "ClearPageFileAtShutdown" -Value 0) { $changes++ }
    if (Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name "EnableSuperfetch" -Value 0) { $changes++ }
    
    Write-Log "Registry: $changes optimizations applied"
    return $changes
}

# ============================================
# Disk Optimization
# ============================================

function Optimize-Disk {
    Write-Log "Optimizing disk usage..."
    
    $savedBytes = 0
    
    # Run CompactOS to compress Windows files
    Write-Log "Running CompactOS compression..."
    try {
        $result = Compact.exe /CompactOS:always 2>&1
        Write-Log "CompactOS: $result"
    }
    catch {
        Write-Log "CompactOS failed: $_" -Level "WARN"
    }
    
    # Clear temp files
    Write-Log "Clearing temporary files..."
    $tempPaths = @(
        "$env:TEMP\*",
        "$env:WINDIR\Temp\*",
        "$env:LOCALAPPDATA\Temp\*",
        "$env:WINDIR\SoftwareDistribution\Download\*",
        "$env:WINDIR\Prefetch\*"
    )
    
    foreach ($path in $tempPaths) {
        try {
            $items = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            $size = ($items | Measure-Object -Property Length -Sum).Sum
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            $savedBytes += $size
        }
        catch {
            # Ignore errors - some files may be in use
        }
    }
    
    # Clear Windows.old if present
    $windowsOld = "C:\Windows.old"
    if (Test-Path $windowsOld) {
        Write-Log "Removing Windows.old..."
        try {
            # Take ownership and remove
            takeown /F $windowsOld /R /D Y 2>&1 | Out-Null
            icacls $windowsOld /grant Administrators:F /T 2>&1 | Out-Null
            Remove-Item -Path $windowsOld -Recurse -Force -ErrorAction Stop
            Write-Log "Removed Windows.old"
        }
        catch {
            Write-Log "Could not remove Windows.old: $_" -Level "WARN"
        }
    }
    
    # Run disk cleanup silently
    Write-Log "Running disk cleanup..."
    try {
        # Set up cleanup flags
        $cleanupKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
        $cleanupItems = @(
            "Active Setup Temp Folders",
            "Downloaded Program Files",
            "Internet Cache Files",
            "Recycle Bin",
            "Setup Log Files",
            "System error memory dump files",
            "System error minidump files",
            "Temporary Files",
            "Thumbnail Cache",
            "Windows Error Reporting Files"
        )
        
        foreach ($item in $cleanupItems) {
            $path = Join-Path $cleanupKey $item
            if (Test-Path $path) {
                Set-ItemProperty -Path $path -Name "StateFlags0099" -Value 2 -ErrorAction SilentlyContinue
            }
        }
        
        # Run cleanmgr with our flags
        Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:99" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Disk cleanup error: $_" -Level "WARN"
    }
    
    $savedMB = [math]::Round($savedBytes / 1MB, 2)
    Write-Log "Disk optimization complete. Freed approximately $savedMB MB"
    return $savedBytes
}

# ============================================
# Main Script
# ============================================

Write-Log "=========================================="
Write-Log "Windows Optimization Started"
Write-Log "=========================================="

$totalOptimizations = 0

# Disable unnecessary services
if (-not $SkipServiceOptimization) {
    $totalOptimizations += Disable-UnnecessaryServices
}

# Remove bloatware apps
if (-not $SkipAppRemoval) {
    $totalOptimizations += Remove-BloatwareApps
}

# Apply registry tweaks
if (-not $SkipRegistryTweaks) {
    $totalOptimizations += Apply-RegistryOptimizations
}

# Optimize disk usage
if (-not $SkipDiskOptimization) {
    Optimize-Disk | Out-Null
    $totalOptimizations++
}

Write-Log "=========================================="
Write-Log "Windows Optimization Complete"
Write-Log "Total optimizations applied: $totalOptimizations"
Write-Log "=========================================="

exit 0
