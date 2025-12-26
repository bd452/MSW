# Build WinRunAgent MSI Installer
# This script builds the WinRunAgent.msi using the WiX toolset.
# Must be run on Windows with .NET SDK installed.
#
# Usage:
#   .\build-guest-installer.ps1 [-Configuration <Debug|Release>] [-OutputDir <path>]
#
# Examples:
#   .\build-guest-installer.ps1
#   .\build-guest-installer.ps1 -Configuration Release -OutputDir .\artifacts

[CmdletBinding()]
param(
    # Build configuration (Debug or Release)
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    # Output directory for the MSI file
    [string]$OutputDir,

    # Skip restore step (use if already restored)
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"

# Script paths
$Script:RepoRoot = Split-Path -Parent $PSScriptRoot
$Script:GuestDir = Join-Path $Script:RepoRoot "guest"
$Script:InstallerProject = Join-Path $Script:GuestDir "WinRunAgent.Installer\WinRunAgent.Installer.wixproj"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Prerequisites {
    Write-Step "Checking prerequisites"

    # Check for .NET SDK
    $dotnetVersion = & dotnet --version 2>$null
    if (-not $dotnetVersion) {
        throw ".NET SDK is not installed. Please install .NET 8 or later."
    }
    Write-Host "Found .NET SDK: $dotnetVersion"

    # Check if running on Windows
    if ($env:OS -ne "Windows_NT") {
        throw "This script must be run on Windows. WiX toolset only supports Windows."
    }
    Write-Host "Running on Windows: OK"

    # Check if installer project exists
    if (-not (Test-Path $Script:InstallerProject)) {
        throw "Installer project not found: $Script:InstallerProject"
    }
    Write-Host "Installer project found: OK"
}

function Build-WinRunAgent {
    Write-Step "Building WinRunAgent"

    $projectPath = Join-Path $Script:GuestDir "WinRunAgent\WinRunAgent.csproj"

    $buildArgs = @(
        "build"
        $projectPath
        "-c", $Configuration
    )

    if (-not $NoRestore) {
        # Restore is included by default
    }
    else {
        $buildArgs += "--no-restore"
    }

    Write-Host "Running: dotnet $($buildArgs -join ' ')"
    & dotnet @buildArgs

    if ($LASTEXITCODE -ne 0) {
        throw "WinRunAgent build failed with exit code: $LASTEXITCODE"
    }

    Write-Host "WinRunAgent build completed successfully"
}

function Build-Installer {
    Write-Step "Building MSI Installer"

    $buildArgs = @(
        "build"
        $Script:InstallerProject
        "-c", $Configuration
    )

    if (-not $NoRestore) {
        # Restore is included by default
    }
    else {
        $buildArgs += "--no-restore"
    }

    Write-Host "Running: dotnet $($buildArgs -join ' ')"
    & dotnet @buildArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Installer build failed with exit code: $LASTEXITCODE"
    }

    Write-Host "Installer build completed successfully"
}

function Copy-Output {
    param([string]$DestDir)

    Write-Step "Copying output to: $DestDir"

    # Create output directory
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    # Find the MSI file
    $installerOutputDir = Join-Path $Script:GuestDir "WinRunAgent.Installer\bin\$Configuration"
    $msiFiles = Get-ChildItem -Path $installerOutputDir -Filter "*.msi" -Recurse -ErrorAction SilentlyContinue

    if (-not $msiFiles -or $msiFiles.Count -eq 0) {
        # Try arm64 subdirectory
        $installerOutputDir = Join-Path $Script:GuestDir "WinRunAgent.Installer\bin\arm64\$Configuration"
        $msiFiles = Get-ChildItem -Path $installerOutputDir -Filter "*.msi" -Recurse -ErrorAction SilentlyContinue
    }

    if (-not $msiFiles -or $msiFiles.Count -eq 0) {
        throw "No MSI files found in build output. Check build logs for errors."
    }

    foreach ($msi in $msiFiles) {
        $destPath = Join-Path $DestDir $msi.Name
        Write-Host "Copying: $($msi.FullName) -> $destPath"
        Copy-Item -Path $msi.FullName -Destination $destPath -Force
    }

    # Also copy the silent install scripts
    $scriptsDir = Join-Path $Script:GuestDir "WinRunAgent.Installer"
    $scripts = @("install-silent.ps1", "uninstall-silent.ps1")

    foreach ($script in $scripts) {
        $scriptPath = Join-Path $scriptsDir $script
        if (Test-Path $scriptPath) {
            $destPath = Join-Path $DestDir $script
            Write-Host "Copying: $scriptPath -> $destPath"
            Copy-Item -Path $scriptPath -Destination $destPath -Force
        }
    }

    Write-Host ""
    Write-Host "Output files:" -ForegroundColor Green
    Get-ChildItem -Path $DestDir | ForEach-Object {
        Write-Host "  $($_.Name)"
    }
}

function Get-MsiPath {
    # Find and return the path to the built MSI
    $installerOutputDir = Join-Path $Script:GuestDir "WinRunAgent.Installer\bin\$Configuration"
    $msiFile = Get-ChildItem -Path $installerOutputDir -Filter "*.msi" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $msiFile) {
        $installerOutputDir = Join-Path $Script:GuestDir "WinRunAgent.Installer\bin\arm64\$Configuration"
        $msiFile = Get-ChildItem -Path $installerOutputDir -Filter "*.msi" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    return $msiFile
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host "========================================"
Write-Host "WinRunAgent MSI Installer Build"
Write-Host "========================================"
Write-Host "Configuration: $Configuration"
Write-Host "Repository:    $Script:RepoRoot"
Write-Host ""

try {
    # Check prerequisites
    Test-Prerequisites

    # Build the main project first
    Build-WinRunAgent

    # Build the installer
    Build-Installer

    # Copy output if destination specified
    if ($OutputDir) {
        Copy-Output -DestDir $OutputDir
    }
    else {
        $msiFile = Get-MsiPath
        if ($msiFile) {
            Write-Host ""
            Write-Host "MSI built successfully:" -ForegroundColor Green
            Write-Host "  $($msiFile.FullName)"
        }
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Build Completed Successfully" -ForegroundColor Green
    Write-Host "========================================"

    exit 0
}
catch {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "Build Failed" -ForegroundColor Red
    Write-Host "========================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    exit 1
}
