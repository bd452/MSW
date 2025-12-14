# WinRun

Run Windows applications seamlessly on macOS. WinRun uses Apple's Virtualization.framework and the Spice protocol to display Windows apps as native-feeling macOS windows.

## Features

- **Seamless Windows apps** — Windows applications appear as individual macOS windows, not a full desktop
- **Native integration** — Clipboard sync, drag-and-drop, Retina display support
- **Fast startup** — VM suspends when idle, resumes in ~2 seconds
- **Auto-generated launchers** — Install Windows apps and they appear in Launchpad
- **No kernel extensions** — Uses Apple's built-in virtualization technology

## Requirements

- **macOS 13 (Ventura) or later** on Apple Silicon (M1/M2/M3/M4)
- **Windows 11 ARM64 ISO** (you provide your own license)
- **~20GB free disk space** for Windows VM

## Quick Start

### 1. Download WinRun

Download the latest `WinRun.dmg` from the [Releases](https://github.com/winrun/winrun/releases) page and drag `WinRun.app` to your Applications folder.

### 2. Get Windows 11 ARM64

WinRun requires a Windows 11 ARM64 installation image. You can obtain one from:

- **[Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise)** — Free 90-day evaluation
- **[Windows Insider Program](https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewiso)** — Free for Insiders
- **Volume Licensing** — For enterprise users

#### Recommended: Windows 11 IoT Enterprise LTSC 2024 ARM64

For the best experience, we recommend **Windows 11 IoT Enterprise LTSC 2024 ARM64**:

| Feature           | IoT Enterprise LTSC | Consumer (Home/Pro) |
| ----------------- | ------------------- | ------------------- |
| Bloatware         | None                | Heavy               |
| Update frequency  | Security only       | Feature updates     |
| Support lifecycle | 10 years            | ~2 years            |
| x86/x64 emulation | ✅ Full              | ✅ Full              |

#### ⚠️ Avoid Windows Server

Windows Server ARM64 **does not include x86/x64 app emulation**. Most Windows applications won't work. Use Windows 11 instead.

### 3. First-Run Setup

1. Launch `WinRun.app`
2. The setup wizard will guide you through:
   - Dropping or selecting your Windows ISO
   - Automated Windows installation (~10-15 minutes)
   - Driver and agent configuration
3. Once complete, you're ready to run Windows apps!

### 4. Running Windows Apps

**From Finder:**
- Right-click any `.exe` file → Open With → WinRun
- Or drag an `.exe` onto the WinRun dock icon

**From Terminal:**
```bash
winrun notepad.exe
winrun "C:\Program Files\App\app.exe" --arg1 --arg2
```

**Installing Windows software:**
- Double-click any `.msi` or `setup.exe` installer
- After installation, a macOS launcher is automatically created
- Find your new app in Launchpad or Spotlight

## Architecture

WinRun is a monorepo containing:

```
├── host/                 # Swift Package (macOS daemon, app, CLI)
├── guest/                # C# Windows agent service
├── infrastructure/       # LaunchDaemon plist, provisioning scripts
├── scripts/              # Build and packaging automation
└── docs/                 # Architecture and decision documentation
```

See `docs/architecture.md` for detailed component breakdown.

## Development

### Prerequisites

**macOS Host:**
- Xcode 15+
- Swift 5.9+
- Homebrew

**Windows Guest (for agent development):**
- .NET 9 SDK
- Visual Studio 2022 or VS Code

### Building

```bash
# Install dependencies and prepare environment
./scripts/bootstrap.sh

# Build all components
./scripts/build-all.sh

# Or build individually
cd host && swift build
cd guest && dotnet build WinRunAgent.sln
```

### Testing

```bash
# Run all tests
make test

# Host tests only
make test-host

# Guest tests (requires Windows or use remote)
make test-guest-remote  # Runs on Windows via GitHub Actions
```

### Documentation

- `docs/architecture.md` — System design and component interaction
- `docs/development.md` — Build, test, and deployment workflows
- `docs/decisions/` — Architecture Decision Records (ADRs)

## CLI Reference

```bash
# Launch programs
winrun notepad.exe
winrun "C:\path\to\app.exe" --arg1 --arg2

# VM management
winrun vm start      # Start the Windows VM
winrun vm stop       # Stop the VM
winrun vm suspend    # Suspend to disk
winrun vm status     # Show VM state

# Session management
winrun session list  # List running Windows apps
winrun session close <id>  # Close a specific app

# Shortcuts and launchers
winrun shortcut list    # List detected Windows shortcuts
winrun shortcut sync    # Create macOS launchers for all shortcuts
winrun create-launcher "C:\path\to\app.exe"  # Create single launcher

# Configuration
winrun config show      # Display current configuration
winrun config set memory 8G   # Set VM memory
winrun config set cpus 6      # Set VM CPU cores

# Setup
winrun init             # Initialize Windows VM (CLI alternative to GUI wizard)
```

## Troubleshooting

### Windows apps are slow

- Ensure you're using Windows 11 ARM64 (not Windows Server)
- Close unused Windows apps to free VM resources
- Increase VM memory: `winrun config set memory 8G`

### x86/x64 apps don't work

- Windows Server doesn't include x86/x64 emulation — use Windows 11 instead
- Windows 10 ARM only supports 32-bit apps — upgrade to Windows 11

### Setup stuck or failed

- Verify your ISO is Windows 11 ARM64 (not x64)
- Ensure you have at least 20GB free disk space
- Check Console.app for detailed error logs

## Contributing

Contributions welcome! Please read `docs/development.md` for guidelines.

1. Fork the repository
2. Create a feature branch
3. Run `make check` before submitting
4. Open a Pull Request

## License

See [LICENSE](LICENSE) for details.
