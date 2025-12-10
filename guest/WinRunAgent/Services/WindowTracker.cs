using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;

namespace WinRun.Agent.Services;

/// <summary>
/// Tracks visible application windows using Win32 hooks and reports events to subscribers.
/// Uses SetWinEventHook for efficient, system-wide window monitoring.
/// </summary>
public sealed class WindowTracker : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly ConcurrentDictionary<nint, WindowMetadata> _trackedWindows = new();
    private readonly List<nint> _hookHandles = [];
    private GCHandle _delegateHandle;
    private WinEventDelegate? _winEventDelegate;
    private EventHandler<WindowEventArgs>? _eventHandler;
    private bool _disposed;

    /// <summary>
    /// Event raised when a window event occurs. Subscribe to this for passive monitoring.
    /// </summary>
    public event EventHandler<WindowEventArgs>? WindowEvent;

    public WindowTracker(IAgentLogger logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Gets the currently tracked windows and their metadata.
    /// </summary>
    public IReadOnlyDictionary<nint, WindowMetadata> TrackedWindows => _trackedWindows;

    /// <summary>
    /// Starts monitoring window events. Installs Win32 hooks for system-wide window tracking.
    /// </summary>
    public void Start(EventHandler<WindowEventArgs> handler)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        _eventHandler = handler;

        // Create delegate and pin it to prevent GC collection during native callbacks
        _winEventDelegate = new WinEventDelegate(WinEventCallback);
        _delegateHandle = GCHandle.Alloc(_winEventDelegate);

        _logger.Info("Installing Win32 window hooks");

        // Install hooks for various window events
        InstallHook(Win32.EVENT_OBJECT_CREATE);      // Window created
        InstallHook(Win32.EVENT_OBJECT_DESTROY);     // Window destroyed
        InstallHook(Win32.EVENT_OBJECT_SHOW);        // Window shown
        InstallHook(Win32.EVENT_OBJECT_HIDE);        // Window hidden
        InstallHook(Win32.EVENT_OBJECT_NAMECHANGE);  // Title changed
        InstallHook(Win32.EVENT_OBJECT_LOCATIONCHANGE); // Moved/resized
        InstallHook(Win32.EVENT_SYSTEM_FOREGROUND);  // Foreground changed
        InstallHook(Win32.EVENT_SYSTEM_MINIMIZESTART);
        InstallHook(Win32.EVENT_SYSTEM_MINIMIZEEND);

        // Enumerate existing windows
        EnumerateExistingWindows();

        _logger.Info($"Window hooks installed. Tracking {_trackedWindows.Count} existing windows");
    }

    /// <summary>
    /// Stops monitoring and releases all hooks.
    /// </summary>
    public void Stop()
    {
        foreach (var handle in _hookHandles)
        {
            _ = Win32.UnhookWinEvent(handle);
        }
        _hookHandles.Clear();

        if (_delegateHandle.IsAllocated)
        {
            _delegateHandle.Free();
        }

        _trackedWindows.Clear();
        _logger.Info("Window hooks uninstalled");
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Stop();
    }

    private void InstallHook(uint eventType)
    {
        var handle = Win32.SetWinEventHook(
            eventType, eventType,
            IntPtr.Zero,
            _winEventDelegate!,
            0, 0,
            Win32.WINEVENT_OUTOFCONTEXT | Win32.WINEVENT_SKIPOWNPROCESS);

        if (handle != IntPtr.Zero)
        {
            _hookHandles.Add(handle);
        }
        else
        {
            _logger.Warn($"Failed to install hook for event 0x{eventType:X}");
        }
    }

    private void EnumerateExistingWindows() => _ = Win32.EnumWindows((hwnd, _) =>
                                                    {
                                                        if (IsTrackableWindow(hwnd))
                                                        {
                                                            TrackWindow(hwnd, isNew: false);
                                                        }
                                                        return true; // Continue enumeration
                                                    }, IntPtr.Zero);

    private void WinEventCallback(
        nint hWinEventHook,
        uint eventType,
        nint hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        // Only handle window-level events (not child objects like buttons)
        if (idObject != Win32.OBJID_WINDOW || hwnd == IntPtr.Zero)
        {
            return;
        }

        try
        {
            switch (eventType)
            {
                case Win32.EVENT_OBJECT_CREATE:
                case Win32.EVENT_OBJECT_SHOW:
                    HandleWindowCreatedOrShown(hwnd);
                    break;

                case Win32.EVENT_OBJECT_DESTROY:
                case Win32.EVENT_OBJECT_HIDE:
                    HandleWindowDestroyedOrHidden(hwnd, eventType);
                    break;

                case Win32.EVENT_OBJECT_NAMECHANGE:
                    HandleWindowTitleChanged(hwnd);
                    break;

                case Win32.EVENT_OBJECT_LOCATIONCHANGE:
                    HandleWindowLocationChanged(hwnd);
                    break;

                case Win32.EVENT_SYSTEM_FOREGROUND:
                    HandleForegroundChanged(hwnd);
                    break;

                case Win32.EVENT_SYSTEM_MINIMIZESTART:
                    HandleWindowMinimized(hwnd, minimized: true);
                    break;

                case Win32.EVENT_SYSTEM_MINIMIZEEND:
                    HandleWindowMinimized(hwnd, minimized: false);
                    break;
                default:
                    break;
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Error handling window event 0x{eventType:X} for HWND {hwnd}: {ex.Message}");
        }
    }

    private void HandleWindowCreatedOrShown(nint hwnd)
    {
        if (!IsTrackableWindow(hwnd))
        {
            return;
        }

        if (_trackedWindows.ContainsKey(hwnd))
        {
            return;
        }

        TrackWindow(hwnd, isNew: true);
    }

    private void HandleWindowDestroyedOrHidden(nint hwnd, uint _)
    {
        if (!_trackedWindows.TryRemove(hwnd, out var metadata))
        {
            return;
        }

        _logger.Debug($"Window destroyed/hidden: HWND={hwnd}, Title=\"{metadata.Title}\"");
        RaiseEvent(new WindowEventArgs(
            (ulong)hwnd,
            metadata.Title,
            metadata.Bounds,
            WindowEventType.Destroyed));
    }

    private void HandleWindowTitleChanged(nint hwnd)
    {
        if (!_trackedWindows.TryGetValue(hwnd, out var existing))
        {
            return;
        }

        var newTitle = GetWindowTitle(hwnd);
        if (newTitle == existing.Title)
        {
            return;
        }

        var updated = existing with { Title = newTitle };
        _trackedWindows[hwnd] = updated;

        _logger.Debug($"Window title changed: HWND={hwnd}, \"{existing.Title}\" -> \"{newTitle}\"");
        RaiseEvent(new WindowEventArgs(
            (ulong)hwnd,
            newTitle,
            updated.Bounds,
            WindowEventType.TitleChanged));
    }

    private void HandleWindowLocationChanged(nint hwnd)
    {
        if (!_trackedWindows.TryGetValue(hwnd, out var existing))
        {
            return;
        }

        var newBounds = GetWindowBounds(hwnd);
        if (newBounds == existing.Bounds)
        {
            return;
        }

        var updated = existing with { Bounds = newBounds };
        _trackedWindows[hwnd] = updated;

        RaiseEvent(new WindowEventArgs(
            (ulong)hwnd,
            updated.Title,
            newBounds,
            WindowEventType.Moved));
    }

    private void HandleForegroundChanged(nint hwnd)
    {
        if (!_trackedWindows.ContainsKey(hwnd))
        {
            return;
        }

        RaiseEvent(new WindowEventArgs(
            (ulong)hwnd,
            _trackedWindows[hwnd].Title,
            _trackedWindows[hwnd].Bounds,
            WindowEventType.FocusChanged));
    }

    private void HandleWindowMinimized(nint hwnd, bool minimized)
    {
        if (!_trackedWindows.TryGetValue(hwnd, out var existing))
        {
            return;
        }

        var updated = existing with { IsMinimized = minimized };
        _trackedWindows[hwnd] = updated;

        RaiseEvent(new WindowEventArgs(
            (ulong)hwnd,
            updated.Title,
            updated.Bounds,
            minimized ? WindowEventType.Minimized : WindowEventType.Restored));
    }

    private void TrackWindow(nint hwnd, bool isNew)
    {
        var title = GetWindowTitle(hwnd);
        var bounds = GetWindowBounds(hwnd);
        var processId = GetWindowProcessId(hwnd);
        var className = GetWindowClassName(hwnd);

        var metadata = new WindowMetadata(
            Hwnd: hwnd,
            Title: title,
            Bounds: bounds,
            ProcessId: processId,
            ClassName: className,
            IsMinimized: Win32.IsIconic(hwnd));

        _trackedWindows[hwnd] = metadata;

        if (isNew)
        {
            _logger.Debug($"New window tracked: HWND={hwnd}, Title=\"{title}\", Class=\"{className}\", PID={processId}");
            RaiseEvent(new WindowEventArgs(
                (ulong)hwnd,
                title,
                bounds,
                WindowEventType.Created));
        }
    }

    private static bool IsTrackableWindow(nint hwnd)
    {
        // Must be a visible, top-level window
        if (!Win32.IsWindowVisible(hwnd))
        {
            return false;
        }

        // Filter by extended window style - skip tool windows, layered windows used for effects
        var exStyle = Win32.GetWindowLongPtr(hwnd, Win32.GWL_EXSTYLE);
        if ((exStyle & Win32.WS_EX_TOOLWINDOW) != 0)
        {
            return false;
        }

        // Must have either WS_EX_APPWINDOW or not be owned
        var owner = Win32.GetWindow(hwnd, Win32.GW_OWNER);
        if (owner != IntPtr.Zero && (exStyle & Win32.WS_EX_APPWINDOW) == 0)
        {
            return false;
        }

        // Skip windows with empty titles (usually helper windows)
        var title = GetWindowTitle(hwnd);
        if (string.IsNullOrWhiteSpace(title))
        {
            return false;
        }

        // Skip known system window classes
        var className = GetWindowClassName(hwnd);
        return !IsSystemWindowClass(className);
    }

    private static bool IsSystemWindowClass(string className) =>
        // Common Windows system classes to ignore
        className switch
        {
            "Progman" => true,                    // Desktop
            "WorkerW" => true,                    // Desktop worker
            "Shell_TrayWnd" => true,              // Taskbar
            "Shell_SecondaryTrayWnd" => true,     // Secondary taskbar
            "Windows.UI.Core.CoreWindow" => true, // UWP system windows
            "ApplicationFrameWindow" => true,     // UWP frame (we track the inner window)
            "XamlExplorerHostIslandWindow" => true,
            "TaskManagerWindow" => true,
            "ForegroundStaging" => true,
            "MultitaskingViewFrame" => true,
            "NativeHWNDHost" => true,
            _ => className.StartsWith("IME", StringComparison.Ordinal)
        };

    private static string GetWindowTitle(nint hwnd)
    {
        var length = Win32.GetWindowTextLength(hwnd);
        if (length == 0)
        {
            return string.Empty;
        }

        var sb = new StringBuilder(length + 1);
        _ = Win32.GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    private static string GetWindowClassName(nint hwnd)
    {
        var sb = new StringBuilder(256);
        _ = Win32.GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    private static Rect GetWindowBounds(nint hwnd)
    {
        _ = Win32.GetWindowRect(hwnd, out var rect);
        return new Rect(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }

    private static uint GetWindowProcessId(nint hwnd)
    {
        _ = Win32.GetWindowThreadProcessId(hwnd, out var processId);
        return processId;
    }

    private void RaiseEvent(WindowEventArgs args)
    {
        _eventHandler?.Invoke(this, args);
        WindowEvent?.Invoke(this, args);
    }
}

/// <summary>
/// Metadata for a tracked window.
/// </summary>
public sealed record WindowMetadata(
    nint Hwnd,
    string Title,
    Rect Bounds,
    uint ProcessId,
    string ClassName,
    bool IsMinimized);

/// <summary>
/// Event args for window events.
/// </summary>
public sealed record WindowEventArgs(
    ulong WindowId,
    string Title,
    Rect Bounds,
    WindowEventType EventType = WindowEventType.Updated);

/// <summary>
/// Type of window event.
/// </summary>
public enum WindowEventType
{
    Created,
    Destroyed,
    Moved,
    TitleChanged,
    FocusChanged,
    Minimized,
    Restored,
    Updated
}

/// <summary>
/// Window bounds rectangle.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct Rect(int X, int Y, int Width, int Height);

/// <summary>
/// Delegate for Win32 event hooks.
/// </summary>
internal delegate void WinEventDelegate(
    nint hWinEventHook,
    uint eventType,
    nint hwnd,
    int idObject,
    int idChild,
    uint dwEventThread,
    uint dwmsEventTime);

/// <summary>
/// Win32 P/Invoke declarations for window tracking.
/// </summary>
internal static partial class Win32
{
    // Event constants
    public const uint EVENT_OBJECT_CREATE = 0x8000;
    public const uint EVENT_OBJECT_DESTROY = 0x8001;
    public const uint EVENT_OBJECT_SHOW = 0x8002;
    public const uint EVENT_OBJECT_HIDE = 0x8003;
    public const uint EVENT_OBJECT_FOCUS = 0x8005;
    public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
    public const uint EVENT_OBJECT_NAMECHANGE = 0x800C;
    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint EVENT_SYSTEM_MINIMIZESTART = 0x0016;
    public const uint EVENT_SYSTEM_MINIMIZEEND = 0x0017;

    // Hook flags
    public const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    public const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

    // Object IDs
    public const int OBJID_WINDOW = 0;

    // Window styles
    public const int GWL_EXSTYLE = -20;
    public const nint WS_EX_TOOLWINDOW = 0x00000080;
    public const nint WS_EX_APPWINDOW = 0x00040000;

    // GetWindow constants
    public const uint GW_OWNER = 4;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public delegate bool EnumWindowsProc(nint hwnd, nint lParam);

    [LibraryImport("user32.dll")]
    public static partial nint SetWinEventHook(
        uint eventMin,
        uint eventMax,
        nint hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc,
        uint idProcess,
        uint idThread,
        uint dwFlags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnhookWinEvent(nint hWinEventHook);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool EnumWindows(EnumWindowsProc lpEnumFunc, nint lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindowVisible(nint hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsIconic(nint hWnd);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static partial nint GetWindowLongPtr(nint hWnd, int nIndex);

    [LibraryImport("user32.dll")]
    public static partial nint GetWindow(nint hWnd, uint uCmd);

    // Use DllImport for StringBuilder parameters (LibraryImport source gen doesn't support them)
    [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(nint hWnd, StringBuilder lpString, int nMaxCount);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextLengthW")]
    public static partial int GetWindowTextLength(nint hWnd);

    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(nint hWnd, StringBuilder lpClassName, int nMaxCount);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(nint hWnd, out RECT lpRect);

    [LibraryImport("user32.dll")]
    public static partial uint GetWindowThreadProcessId(nint hWnd, out uint lpdwProcessId);
}
