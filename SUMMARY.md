# WinRun Architecture

## Overview

A seamless Windows-on-macOS solution using Virtualization.framework + Spice protocol to run Windows GUI apps as native-feeling macOS windows.

-----

## Host Architecture (macOS)

### 1. WinRun Service (`winrund`)

**Purpose:** Background daemon managing the Windows VM lifecycle

**Implementation:**

- Launch daemon (plist in `/Library/LaunchDaemons/`)
- Runs as privileged user for VM management
- Swift-based, using Virtualization.framework

**Responsibilities:**

- Start/stop/suspend/resume Windows VM
- Health monitoring and crash recovery
- Resource management (CPU/memory limits)
- VM state persistence (suspend to disk for fast resume)
- IPC server for app instances to communicate with

**Communication:**

- XPC service for apps to request VM operations
- Exposes methods like: `ensureVMRunning()`, `executeProgram(path:args:)`, `getVMStatus()`
- Handles Spice server connection lifecycle

**VM Configuration:**

- Headless Windows Server Core
- 4 CPU cores, 4GB RAM (configurable)
- VirtioFS for filesystem sharing (`/Users` → `Z:\`)
- Spice display/agent devices
- Shared memory transport for Spice (performance)
- Network (NAT) for internet access
- Persistent disk image at `~/Library/Application Support/WinRun/windows.img`

**Startup behavior:**

- On first launch: prompts user to download/install Windows
- Subsequent launches: resume from suspended state (~2 sec startup)
- Keeps VM running while any Windows apps are open
- Auto-suspend after 5 min of no activity
- Full shutdown on system sleep/shutdown

**Files:**

- `/Library/LaunchDaemons/com.winrun.daemon.plist`
- `/usr/local/bin/winrund` (daemon binary)
- `~/Library/Application Support/WinRun/` (VM images, config)

-----

### 2. WinRun App (`WinRun.app`)

**Purpose:** Individual app instance for each Windows program

**Implementation:**

- Standard macOS app bundle
- Swift/AppKit
- Multiple instances can run simultaneously (LSMultipleInstancesProhibited = NO)

**Launch modes:**

**A) Direct execution:**

```bash
open -n WinRun.app --args /path/to/program.exe [program args]
```

**B) File association:**

- User double-clicks `.exe` or `.msi` file
- macOS launches new WinRun.app instance
- WinRun.app opens that specific program

**C) From .app launcher:**

- Installed programs get `.app` wrappers (see below)
- These launch WinRun.app with appropriate args

**App lifecycle:**

1. **Launch:**

- Parse command-line args to determine which Windows program to run
- Connect to `winrund` via XPC
- Request VM is running (daemon handles startup if needed)
- Connect to Spice server
- Request Windows program execution via Spice agent
- Wait for window creation notification from Spice

1. **Running:**

- Receives Spice stream for this specific Windows window
- Creates NSWindow matching Windows window properties
- Renders Spice frames (pixel data or decoded video)
- Forwards input events (mouse, keyboard) back through Spice
- Updates window title, position, size based on Spice metadata
- Monitors for window close events from Windows

1. **Termination:**

- When Windows program exits, quits this app instance
- Notifies daemon (which may suspend VM if no other apps running)
- Cleans up Spice connection

**Window management:**

Each WinRun.app instance creates ONE NSWindow corresponding to ONE Windows window:

```
notepad.exe → WinRun.app instance 1 → NSWindow "Untitled - Notepad"
calc.exe    → WinRun.app instance 2 → NSWindow "Calculator"
```

**NSWindow configuration:**

- Standard macOS window with close/minimize/maximize buttons
- Title matches Windows window title (updated dynamically)
- Size and position match Windows window (scaled for DPI)
- Resizable if Windows window is resizable
- Content view renders Spice frames

**Dock integration:**

- Each instance appears in Dock separately
- App name matches Windows program name (extracted from .exe metadata)
- Icon extracted from .exe resource (or default icon)
- Dock menu shows standard options (Hide, Quit)

**Menu bar:**

- Minimal menu bar (Application, File, Edit, Window, Help)
- Edit menu has Copy/Paste (integrated with Spice clipboard)
- Window menu for standard window management
- Help menu with “About WinRun”, links to docs

**Spice integration:**

- Links against libspice-glib (via Swift bridging)
- Establishes client connection to daemon’s Spice server
- Subscribes to specific window ID stream
- Renders frames using Metal or Core Graphics
- Sends input via Spice input channel

**Files:**

- `/Applications/WinRun.app` (the main app bundle)
- Info.plist declares `.exe` and `.msi` associations
- Bundled with libspice-glib and dependencies

-----

### 3. App Launchers (Generated `.app` bundles)

**Purpose:** Native macOS app launchers for installed Windows programs

**When created:**

- Installer programs (.msi, setup.exe) that create desktop shortcuts
- User manually creates launcher via WinRun settings
- Package managers (winget, chocolatey) that “install” apps

**Structure:**

```
Calculator.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── launcher (shell script or binary)
│   └── Resources/
│       └── icon.icns (extracted from Windows .exe)
```

**Launcher behavior:**

```bash
#!/bin/bash
# Calculator.app/Contents/MacOS/launcher
open -n /Applications/WinRun.app --args "C:\Windows\System32\calc.exe"
```

**Info.plist:**

```xml
<key>CFBundleName</key>
<string>Calculator</string>
<key>CFBundleExecutable</key>
<string>launcher</string>
<key>CFBundleIconFile</key>
<string>icon.icns</string>
```

**Icon extraction:**

- Parse Windows .exe PE format
- Extract icon resources
- Convert to .icns format
- Include in app bundle

**Installation location:**

- `~/Applications/WinRun Apps/ProgramName.app`
- Or user’s choice
- Shows up in Launchpad, Spotlight, etc.

**Desktop shortcut monitoring:**

WinRun daemon watches Windows desktop directory:

```
C:\Users\Public\Desktop\
C:\Users\[username]\Desktop\
```

When .lnk (shortcut) file appears:

1. Parse .lnk to find target .exe path
1. Extract icon from target
1. Generate .app launcher bundle
1. Offer to move to ~/Applications or install system-wide

-----

### 4. CLI Tool (`winrun`)

**Purpose:** Command-line interface for power users

**Installation:** `/usr/local/bin/winrun`

**Commands:**

```bash
# Launch a program
winrun notepad.exe
winrun "C:\Program Files\App\app.exe" --arg1 --arg2

# VM management
winrun vm start
winrun vm stop
winrun vm suspend
winrun vm status

# Installation helpers
winrun install app.msi
winrun install setup.exe

# Create launcher
winrun create-launcher "C:\Program Files\MyApp\app.exe"

# Configuration
winrun config set memory 8G
winrun config set cpus 6
winrun config show

# First-time setup
winrun init
```

**Implementation:**

- Swift CLI tool
- Communicates with daemon via XPC
- Launches WinRun.app instances as needed
- Wrapper around common operations

-----

## Guest Architecture (Windows)

### 1. Windows Base System

**OS:** Windows Server 2022 Core (or latest)

- Minimal installation, no GUI shell
- ~4GB disk footprint
- Includes .NET runtime, PowerShell Core

**Boot configuration:**

- No Explorer.exe (desktop shell disabled)
- Services only mode
- Auto-login to dedicated user account
- Network configured (DHCP)

**Initial setup script:**

- Runs on first boot
- Installs Spice guest tools
- Configures firewall
- Sets up file sharing
- Installs WinRun guest agent

-----

### 2. Spice Guest Tools

**Installation:** Standard spice-guest-tools MSI from Spice project

**Components installed:**

- QXL display driver (or virtio-gpu)
- Spice agent service
- VirtIO serial driver
- Clipboard integration
- File sharing (spice-webdavd)

**Configuration:**

- Spice agent runs as Windows service
- Connects to host via virtio-serial channel
- Handles display, input, clipboard

-----

### 3. WinRun Guest Agent

**Purpose:** Custom service extending Spice functionality for seamless mode

**Implementation:**

- C# Windows service
- Runs with SYSTEM privileges
- Coordinates with Spice agent

**Responsibilities:**

**A) Window enumeration and tracking:**

- Uses Win32 APIs (EnumWindows, SetWinEventHook)
- Tracks all visible application windows
- Filters out system windows, hidden windows
- Maintains map of HWND → metadata

**B) Per-window capture:**

- Uses Windows.Graphics.Capture API (modern, efficient)
- Or Desktop Duplication API (older but universal)
- Captures each window’s pixel content individually
- Sends to Spice with window ID tag

**C) Window metadata reporting:**

- Monitors window events (create, destroy, move, resize, title change)
- Reports to Spice agent via custom protocol extension
- Metadata includes:
  - Window ID (HWND)
  - Title
  - Position (x, y)
  - Size (width, height)
  - Z-order
  - Visibility state
  - Resizable/maximizable flags

**D) Input injection:**

- Receives input events from host (via Spice)
- Each event tagged with target window ID
- Uses SendInput() to inject into correct window
- Handles coordinate translation (global → window-relative)

**E) Program launcher:**

- Listens for launch requests from host
- Executes programs with CreateProcess()
- Monitors process lifecycle
- Reports when program exits

**F) Desktop shortcut monitoring:**

- Watches Desktop directories for .lnk files
- Parses shortcut to find target
- Notifies host when new shortcuts appear
- Host can create macOS .app launchers

**G) Icon extraction service:**

- Extracts icons from .exe files on request
- Sends icon data to host
- Host converts to .icns for launchers

**Protocol extension:**

The agent extends Spice agent protocol with custom messages:

```
MSG_WINDOW_CREATED {
    window_id: uint64,
    title: string,
    x: int32, y: int32,
    width: uint32, height: uint32,
    flags: uint32
}

MSG_WINDOW_DESTROYED {
    window_id: uint64
}

MSG_WINDOW_UPDATED {
    window_id: uint64,
    fields: bitmask,
    ... (updated fields)
}

MSG_WINDOW_PIXELS {
    window_id: uint64,
    format: pixel_format,
    width: uint32, height: uint32,
    stride: uint32,
    data: bytes
}

MSG_LAUNCH_PROGRAM {
    path: string,
    args: string[],
    working_dir: string
}

MSG_PROGRAM_EXITED {
    window_id: uint64,
    exit_code: int32
}

MSG_SHORTCUT_CREATED {
    shortcut_path: string,
    target_path: string,
    icon_path: string
}
```

**Files:**

- `C:\Program Files\WinRun\WinRunAgent.exe` (service binary)
- Registry keys for configuration
- Log files in `C:\ProgramData\WinRun\Logs\`

-----

### 4. Display Driver Integration

**QXL driver (from Spice guest tools):**

- Virtualizes GPU
- Sends rendering commands to host
- Supports multiple “monitors” (one per window in seamless mode)

**Agent configures QXL:**

- Each window gets virtual monitor
- Agent tells QXL to render window content to specific monitor
- Spice streams each monitor separately
- Host receives tagged streams, maps to NSWindows

**Alternative: virtio-gpu:**

- More modern
- Better 3D support potentially
- Would require custom integration

-----

## Communication Flow

### App Launch Flow

1. User double-clicks `MyApp.exe` on macOS
1. macOS launches `WinRun.app --args MyApp.exe`
1. WinRun.app connects to `winrund` via XPC
1. `winrund` ensures VM is running (resume if suspended)
1. WinRun.app connects to Spice server
1. WinRun.app sends launch request via Spice → WinRun Guest Agent
1. Guest Agent executes MyApp.exe via CreateProcess()
1. Guest Agent monitors for window creation
1. Window appears, Agent captures metadata and pixels
1. Agent sends MSG_WINDOW_CREATED via Spice
1. WinRun.app receives notification, creates NSWindow
1. Agent sends MSG_WINDOW_PIXELS periodically
1. WinRun.app renders pixels in NSWindow
1. User interacts with NSWindow
1. WinRun.app sends input events via Spice
1. Agent injects input into Windows window
1. Windows app processes input, repaints
1. Agent captures new pixels, sends to host
1. Cycle continues until user closes window or app exits
1. Agent sends MSG_PROGRAM_EXITED
1. WinRun.app instance quits
1. If no other apps running, `winrund` suspends VM after timeout

### Installer Flow

1. User double-clicks `setup.msi`
1. WinRun.app launches with installer
1. Installer runs in Windows (possibly shows GUI)
1. Installer creates desktop shortcut
1. Guest Agent detects new .lnk file
1. Agent sends MSG_SHORTCUT_CREATED to host
1. `winrund` receives notification
1. Daemon parses .lnk, extracts icon from target .exe
1. Daemon generates .app launcher bundle
1. Daemon shows macOS notification: “Install MyApp to Applications?”
1. User approves
1. Launcher moved to ~/Applications/WinRun Apps/
1. App appears in Launchpad, Spotlight

-----

## File Organization

### macOS Host

```
/Applications/
    WinRun.app                          # Main app
    
/Library/LaunchDaemons/
    com.winrun.daemon.plist             # Daemon config
    
/usr/local/bin/
    winrund                             # Daemon binary
    winrun                              # CLI tool
    
~/Library/Application Support/WinRun/
    windows.img                         # VM disk image
    config.json                         # User configuration
    
~/Applications/WinRun Apps/             # Generated launchers
    Calculator.app
    Notepad.app
    MyInstalledApp.app
```

### Windows Guest

```
C:\Program Files\WinRun\
    WinRunAgent.exe                     # Our custom agent
    spice-guest-tools\                  # Spice components
    
C:\ProgramData\WinRun\
    Logs\                               # Agent logs
    
Z:\                                     # Mounted macOS /Users
    (macOS home directory accessible here)
```

-----

## Performance Optimizations

### Shared Memory Transport

- Spice supports shared memory (vhostuser)
- Instead of TCP, use shared memory for pixel data
- Reduces latency from ~15ms to ~2-5ms
- Configured via Virtualization.framework shared memory device

### Codec Selection

- For static content (text editors): Raw pixels (no compression)
- For video/animations: H.264 hardware encoding
- Spice negotiates automatically based on content type

### Dirty Region Tracking

- Agent only sends changed pixels
- For text editing, only small regions update
- Dramatically reduces bandwidth

### VM Suspend/Resume

- Suspend VM state to disk when idle
- Resume in ~2 seconds vs ~30 second cold boot
- User perception: instant availability

### Icon Caching

- Cache extracted icons
- Don’t re-extract on every launch
- Store in ~/Library/Caches/WinRun/icons/

-----

## User Experience Flow

### First Time Setup (GUI)

When a user launches WinRun.app without an existing Windows VM, the setup wizard appears:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Welcome to WinRun                            │
│                                                                  │
│  Run Windows apps natively on your Mac.                         │
│                                                                  │
│  To get started, you need a Windows 11 ARM64 installation       │
│  image (.iso file).                                             │
│                                                                  │
│  Recommended: Windows 11 IoT Enterprise LTSC 2024 ARM64         │
│  [Get Windows from Microsoft →]                                 │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                                                           │  │
│  │     Drop Windows ISO here or click to browse              │  │
│  │                                                           │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│                                     [Continue]                   │
└─────────────────────────────────────────────────────────────────┘
```

After the user provides an ISO:
1. WinRun validates the ISO (ARM64 architecture, edition detection)
2. Displays warnings if ISO is suboptimal (e.g., Windows Server lacks x86 emulation)
3. Creates disk image and begins automated Windows installation (~10-15 min)
4. Installs VirtIO drivers, WinRun agent, and optimizes Windows
5. Shows "Ready!" screen with quick-start tips

### First Time Setup (CLI)

```
$ winrun init

WinRun Setup
============
Please provide a Windows 11 ARM64 ISO file.
Recommended: Windows 11 IoT Enterprise LTSC 2024 ARM64

ISO path: ~/Downloads/Win11_ARM64.iso

Validating ISO...
✓ Architecture: ARM64
✓ Edition: Windows 11 IoT Enterprise LTSC
✓ Build: 26100

Creating virtual machine...
[████████████████████] 100%

Installing Windows (unattended)...
[████████████████████] 100%

Installing drivers and WinRun agent...
[████████████████████] 100%

Optimizing Windows...
[████████████████████] 100%

Setup complete! 

You can now run Windows programs:
  winrun notepad.exe
  open MyApp.exe

Or install software:
  winrun install setup.msi
```

### Running a Program

```
# From terminal
$ winrun calc.exe

# Or double-click calculator.exe in Finder
# Window appears on desktop looking like native macOS window
# Dock shows "Calculator" with Windows calculator icon
# User interacts normally
# Closing window quits the app
```

### Installing Software

```
# User downloads installer.msi
$ open installer.msi

# WinRun.app launches showing installer GUI
# User clicks through installation
# Installer completes

# macOS notification appears:
"MyApp was installed. Add to Applications? [Yes] [No]"

# User clicks Yes
# MyApp.app appears in Applications folder
# User can launch from Launchpad, Spotlight, or Finder
```

-----

## Technical Challenges & Solutions

### Challenge: Multiple windows per program

Some Windows apps create multiple windows (main + dialogs, palettes, etc.)

**Solution:**

- Guest agent reports parent/child window relationships
- WinRun.app can spawn child NSWindows for dialogs
- Or use app groups to coordinate multiple WinRun.app instances

### Challenge: DPI scaling

macOS Retina displays (2x) vs Windows DPI settings

**Solution:**

- Guest renders at Windows native DPI
- Host scales frames for Retina display
- Or negotiate higher resolution from guest
- Report accurate DPI via Spice agent

### Challenge: Clipboard integration

Copy/paste between macOS and Windows

**Solution:**

- Spice agent already handles this
- Bidirectional clipboard sync
- Format translation (RTF, images, etc.)

### Challenge: File paths

macOS uses `/Users/...`, Windows uses `C:\` and `Z:\`

**Solution:**

- VirtioFS mounts `/Users` as `Z:\`
- CLI tool translates paths automatically:
  - `winrun ~/Documents/file.exe` → `Z:\Documents\file.exe`
- Guest agent canonicalizes paths

### Challenge: Network

Windows apps need internet access

**Solution:**

- VM gets NAT network from Virtualization.framework
- Appears as normal network to Windows apps
- Localhost forwarding for services

### Challenge: Updates

Windows needs security updates

**Solution:**

- Windows Update runs automatically in background
- Or user can trigger via `winrun vm update`
- VM snapshots before updates (rollback if needed)

-----

## Security Considerations

### Isolation

- VM is sandboxed by macOS hypervisor
- Windows malware can’t escape to macOS
- File sharing limited to explicit mounts

### Signing

- Code sign WinRun.app for macOS Gatekeeper
- Notarize for distribution outside App Store
- Potentially distribute via Homebrew

### Permissions

- Request Accessibility permissions for global hotkeys (optional)
- File access limited to user’s home directory
- No kernel extensions needed
