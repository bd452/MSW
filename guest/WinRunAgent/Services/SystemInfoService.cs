using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

/// <summary>
/// Service for detecting system capabilities and gathering display/DPI information.
/// Used to report guest capabilities and display configuration to the host on connection.
/// </summary>
public sealed class SystemInfoService
{
    private readonly IAgentLogger _logger;

    public SystemInfoService(IAgentLogger logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Detects which guest capabilities are available on this system.
    /// </summary>
    public GuestCapabilities DetectCapabilities()
    {
        var capabilities = GuestCapabilities.None;

        // Window tracking is always available via Win32 hooks
        capabilities |= GuestCapabilities.WindowTracking;
        _logger.Debug("Capability: WindowTracking = available");

        // Check Desktop Duplication (requires Windows 8+ and DXGI 1.2)
        if (IsDesktopDuplicationAvailable())
        {
            capabilities |= GuestCapabilities.DesktopDuplication;
            _logger.Debug("Capability: DesktopDuplication = available");
        }
        else
        {
            _logger.Debug("Capability: DesktopDuplication = unavailable");
        }

        // Clipboard sync is available via Win32 clipboard APIs
        capabilities |= GuestCapabilities.ClipboardSync;
        _logger.Debug("Capability: ClipboardSync = available");

        // Drag-drop support via OLE drag-drop
        capabilities |= GuestCapabilities.DragDrop;
        _logger.Debug("Capability: DragDrop = available");

        // Icon extraction is available via shell APIs
        capabilities |= GuestCapabilities.IconExtraction;
        _logger.Debug("Capability: IconExtraction = available");

        // Shortcut detection via FileSystemWatcher on Start Menu paths
        capabilities |= GuestCapabilities.ShortcutDetection;
        _logger.Debug("Capability: ShortcutDetection = available");

        // High DPI support (Windows 8.1+ with per-monitor DPI awareness)
        if (IsHighDpiSupported())
        {
            capabilities |= GuestCapabilities.HighDpiSupport;
            _logger.Debug("Capability: HighDpiSupport = available");
        }
        else
        {
            _logger.Debug("Capability: HighDpiSupport = unavailable");
        }

        // Multi-monitor support
        var monitorCount = SystemInfoNative.GetSystemMetrics(SystemInfoNative.SM_CMONITORS);
        if (monitorCount > 0)
        {
            capabilities |= GuestCapabilities.MultiMonitor;
            _logger.Debug($"Capability: MultiMonitor = available ({monitorCount} monitors)");
        }

        _logger.Info($"Detected capabilities: {capabilities}");
        return capabilities;
    }

    /// <summary>
    /// Gathers DPI and display information for all monitors.
    /// </summary>
    public DpiInfoMessage GatherDpiInfo()
    {
        var monitors = new List<MonitorInfo>();
        var primaryDpi = 96; // Default fallback
        var primaryScaleFactor = 1.0;

        // Enumerate all monitors
        var callback = new SystemInfoNative.MonitorEnumProc((hMonitor, hdcMonitor, lprcMonitor, dwData) =>
        {
            var info = new SystemInfoNative.MONITORINFOEX { cbSize = Marshal.SizeOf<SystemInfoNative.MONITORINFOEX>() };

            if (SystemInfoNative.GetMonitorInfo(hMonitor, ref info))
            {
                // Get DPI for this monitor
                var dpi = GetMonitorDpi(hMonitor);
                var scaleFactor = dpi / 96.0;

                var bounds = new RectInfo(
                    info.rcMonitor.Left,
                    info.rcMonitor.Top,
                    info.rcMonitor.Right - info.rcMonitor.Left,
                    info.rcMonitor.Bottom - info.rcMonitor.Top);

                var workArea = new RectInfo(
                    info.rcWork.Left,
                    info.rcWork.Top,
                    info.rcWork.Right - info.rcWork.Left,
                    info.rcWork.Bottom - info.rcWork.Top);

                var isPrimary = (info.dwFlags & SystemInfoNative.MONITORINFOF_PRIMARY) != 0;

                // Get device name (trim null chars)
                var deviceName = new string(info.szDevice).TrimEnd('\0');

                monitors.Add(new MonitorInfo
                {
                    DeviceName = deviceName,
                    Bounds = bounds,
                    WorkArea = workArea,
                    Dpi = dpi,
                    ScaleFactor = scaleFactor,
                    IsPrimary = isPrimary
                });

                if (isPrimary)
                {
                    primaryDpi = dpi;
                    primaryScaleFactor = scaleFactor;
                }

                _logger.Debug($"Monitor: {deviceName}, DPI={dpi}, Scale={scaleFactor:F2}, Primary={isPrimary}");
            }

            return true; // Continue enumeration
        });

        _ = SystemInfoNative.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);

        // Fallback if enumeration failed
        if (monitors.Count == 0)
        {
            _logger.Warn("Monitor enumeration failed, using fallback values");
            primaryDpi = GetSystemDpi();
            primaryScaleFactor = primaryDpi / 96.0;

            monitors.Add(new MonitorInfo
            {
                DeviceName = "PRIMARY",
                Bounds = new RectInfo(0, 0,
                    SystemInfoNative.GetSystemMetrics(SystemInfoNative.SM_CXSCREEN),
                    SystemInfoNative.GetSystemMetrics(SystemInfoNative.SM_CYSCREEN)),
                WorkArea = new RectInfo(0, 0,
                    SystemInfoNative.GetSystemMetrics(SystemInfoNative.SM_CXSCREEN),
                    SystemInfoNative.GetSystemMetrics(SystemInfoNative.SM_CYSCREEN)),
                Dpi = primaryDpi,
                ScaleFactor = primaryScaleFactor,
                IsPrimary = true
            });
        }

        _logger.Info($"DPI info gathered: {monitors.Count} monitors, primary DPI={primaryDpi}");

        return SpiceMessageSerializer.CreateDpiInfoMessage(primaryDpi, primaryScaleFactor, monitors);
    }

    /// <summary>
    /// Creates a capability flags message ready for transmission to the host.
    /// </summary>
    public CapabilityFlagsMessage CreateCapabilityMessage()
    {
        var capabilities = DetectCapabilities();
        return SpiceMessageSerializer.CreateCapabilityMessage(capabilities);
    }

    private static bool IsDesktopDuplicationAvailable()
    {
        // Desktop Duplication requires Windows 8 or later
        // Check for DXGI 1.2 by trying to load the required interface
        var version = Environment.OSVersion.Version;
        return version.Major > 6 || (version.Major == 6 && version.Minor >= 2);
    }

    private static bool IsHighDpiSupported()
    {
        // Per-monitor DPI awareness requires Windows 8.1 (6.3) or later
        var version = Environment.OSVersion.Version;
        return version.Major > 6 || (version.Major == 6 && version.Minor >= 3);
    }

    private static int GetMonitorDpi(IntPtr hMonitor)
    {
        // Try GetDpiForMonitor (Windows 8.1+)
        var hr = SystemInfoNative.GetDpiForMonitor(
            hMonitor,
            SystemInfoNative.MDT_EFFECTIVE_DPI,
            out var dpiX,
            out _);

        if (hr == 0)
        {
            return (int)dpiX;
        }

        // Fallback to system DPI
        return GetSystemDpi();
    }

    private static int GetSystemDpi()
    {
        // Get system DPI via GetDeviceCaps
        var hdc = SystemInfoNative.GetDC(IntPtr.Zero);
        if (hdc == IntPtr.Zero)
        {
            return 96; // Default
        }

        try
        {
            return SystemInfoNative.GetDeviceCaps(hdc, SystemInfoNative.LOGPIXELSX);
        }
        finally
        {
            _ = SystemInfoNative.ReleaseDC(IntPtr.Zero, hdc);
        }
    }
}

/// <summary>
/// Win32 P/Invoke declarations for system info queries.
/// </summary>
internal static partial class SystemInfoNative
{
    // System metrics
    public const int SM_CXSCREEN = 0;
    public const int SM_CYSCREEN = 1;
    public const int SM_CMONITORS = 80;

    // Monitor info flags
    public const uint MONITORINFOF_PRIMARY = 0x00000001;

    // DPI types
    public const int MDT_EFFECTIVE_DPI = 0;

    // Device caps
    public const int LOGPIXELSX = 88;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [LibraryImport("user32.dll")]
    public static partial int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr lprcClip,
        MonitorEnumProc lpfnEnum,
        IntPtr dwData);

    [LibraryImport("shcore.dll")]
    public static partial int GetDpiForMonitor(
        IntPtr hMonitor,
        int dpiType,
        out uint dpiX,
        out uint dpiY);

    [LibraryImport("user32.dll")]
    public static partial IntPtr GetDC(IntPtr hWnd);

    [LibraryImport("user32.dll")]
    public static partial int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [LibraryImport("gdi32.dll")]
    public static partial int GetDeviceCaps(IntPtr hdc, int index);
}

