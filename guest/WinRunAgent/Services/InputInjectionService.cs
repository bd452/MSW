using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

/// <summary>
/// Injects mouse and keyboard input into Windows using SendInput API.
/// </summary>
public sealed partial class InputInjectionService
{
    private readonly IAgentLogger _logger;

    public InputInjectionService(IAgentLogger logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Injects a mouse event into the target window.
    /// </summary>
    public bool InjectMouse(MouseInputMessage input)
    {
        try
        {
            // Convert coordinates to absolute screen coordinates
            var (screenX, screenY) = GetAbsoluteCoordinates(input.WindowId, input.X, input.Y);

            var inputs = new InputUnion[1];
            inputs[0].Type = INPUT_MOUSE;
            inputs[0].Data.Mouse.dx = NormalizeX(screenX);
            inputs[0].Data.Mouse.dy = NormalizeY(screenY);
            inputs[0].Data.Mouse.dwFlags = GetMouseFlags(input);
            inputs[0].Data.Mouse.mouseData = GetMouseData(input);

            var result = SendInput(1, inputs, Marshal.SizeOf<InputUnion>());
            if (result != 1)
            {
                _logger.Warn($"SendInput returned {result} for mouse event (expected 1)");
                return false;
            }

            return true;
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to inject mouse input: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Injects a keyboard event into the target window.
    /// </summary>
    public bool InjectKeyboard(KeyboardInputMessage input)
    {
        try
        {
            var inputs = new InputUnion[1];
            inputs[0].Type = INPUT_KEYBOARD;
            inputs[0].Data.Keyboard.wVk = (ushort)input.KeyCode;
            inputs[0].Data.Keyboard.wScan = (ushort)input.ScanCode;
            inputs[0].Data.Keyboard.dwFlags = GetKeyboardFlags(input);

            var result = SendInput(1, inputs, Marshal.SizeOf<InputUnion>());
            if (result != 1)
            {
                _logger.Warn($"SendInput returned {result} for keyboard event (expected 1)");
                return false;
            }

            return true;
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to inject keyboard input: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Moves the focus to the specified window.
    /// </summary>
    public bool FocusWindow(ulong windowId)
    {
        try
        {
            var hwnd = (nint)windowId;
            if (!SetForegroundWindow(hwnd))
            {
                // Try alternative method
                var threadId = GetWindowThreadProcessId(hwnd, out _);
                var currentThreadId = GetCurrentThreadId();
                _ = AttachThreadInput(currentThreadId, threadId, true);
                _ = SetForegroundWindow(hwnd);
                _ = AttachThreadInput(currentThreadId, threadId, false);
            }
            return true;
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to focus window {windowId}: {ex.Message}");
            return false;
        }
    }

    private static (int X, int Y) GetAbsoluteCoordinates(ulong windowId, double relativeX, double relativeY)
    {
        var hwnd = (nint)windowId;
        return GetWindowRect(hwnd, out var rect) ? ((int X, int Y))(rect.Left + (int)relativeX, rect.Top + (int)relativeY) : ((int X, int Y))((int)relativeX, (int)relativeY);
    }

    private static int NormalizeX(int x)
    {
        var screenWidth = GetSystemMetrics(SM_CXSCREEN);
        return x * 65535 / screenWidth;
    }

    private static int NormalizeY(int y)
    {
        var screenHeight = GetSystemMetrics(SM_CYSCREEN);
        return y * 65535 / screenHeight;
    }

    private static uint GetMouseFlags(MouseInputMessage input)
    {
        var flags = MOUSEEVENTF_ABSOLUTE;

        switch (input.EventType)
        {
            case MouseEventType.Move:
                flags |= MOUSEEVENTF_MOVE;
                break;
            case MouseEventType.Press:
                flags |= input.Button switch
                {
                    MouseButton.Left => MOUSEEVENTF_LEFTDOWN,
                    MouseButton.Right => MOUSEEVENTF_RIGHTDOWN,
                    MouseButton.Middle => MOUSEEVENTF_MIDDLEDOWN,
                    MouseButton.Extra1 => MOUSEEVENTF_XDOWN,
                    MouseButton.Extra2 => MOUSEEVENTF_XDOWN,
                    _ => MOUSEEVENTF_LEFTDOWN
                };
                break;
            case MouseEventType.Release:
                flags |= input.Button switch
                {
                    MouseButton.Left => MOUSEEVENTF_LEFTUP,
                    MouseButton.Right => MOUSEEVENTF_RIGHTUP,
                    MouseButton.Middle => MOUSEEVENTF_MIDDLEUP,
                    MouseButton.Extra1 => MOUSEEVENTF_XUP,
                    MouseButton.Extra2 => MOUSEEVENTF_XUP,
                    _ => MOUSEEVENTF_LEFTUP
                };
                break;
            case MouseEventType.Scroll:
                flags |= input.ScrollDeltaX != 0 ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
                break;
            default:
                break;
        }

        return flags;
    }

    private static uint GetMouseData(MouseInputMessage input)
    {
        if (input.EventType == MouseEventType.Scroll)
        {
            // Convert delta to wheel units (WHEEL_DELTA = 120)
            var delta = input.ScrollDeltaY != 0 ? input.ScrollDeltaY : input.ScrollDeltaX;
            return (uint)(int)(delta * 120);
        }

        return input.Button is MouseButton.Extra1 or MouseButton.Extra2 ? input.Button == MouseButton.Extra1 ? XBUTTON1 : XBUTTON2 : 0;
    }

    private static uint GetKeyboardFlags(KeyboardInputMessage input)
    {
        uint flags = 0;

        if (input.EventType == KeyEventType.KeyUp)
        {
            flags |= KEYEVENTF_KEYUP;
        }

        if (input.IsExtendedKey)
        {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }

        if (input.ScanCode != 0)
        {
            flags |= KEYEVENTF_SCANCODE;
        }

        return flags;
    }

    // Input type constants
    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;

    // Mouse event flags
    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_XDOWN = 0x0080;
    private const uint MOUSEEVENTF_XUP = 0x0100;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x1000;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    // Extra button identifiers
    private const uint XBUTTON1 = 0x0001;
    private const uint XBUTTON2 = 0x0002;

    // Keyboard event flags
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_SCANCODE = 0x0008;

    // Screen metrics
    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;

    // Native structs
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)]
        public MouseInput Mouse;
        [FieldOffset(0)]
        public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct InputUnion
    {
        public uint Type;
        public InputData Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial uint SendInput(uint nInputs, InputUnion[] pInputs, int cbSize);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint hWnd);

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(nint hWnd, out uint lpdwProcessId);

    [LibraryImport("user32.dll")]
    private static partial uint GetCurrentThreadId();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool fAttach);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(nint hWnd, out RECT lpRect);

    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int nIndex);
}

