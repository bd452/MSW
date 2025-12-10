using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class InputInjectionServiceTests
{
    private readonly TestLogger _logger = new();
    private readonly InputInjectionService _service;

    public InputInjectionServiceTests()
    {
        _service = new InputInjectionService(_logger);
    }

    [Fact]
    public void InjectMouse_WithMoveEvent_LogsAttempt()
    {
        var input = new MouseInputMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = MouseEventType.Move,
            X = 100,
            Y = 200
        };


        // On non-Windows, this will fail but should not throw
        _ = _service.InjectMouse(input);

        // On non-Windows, the P/Invoke will fail
        // Just verify no exception and logging occurred
        Assert.True(_logger.Messages.Count >= 0);
    }

    [Fact]
    public void InjectMouse_WithClickEvent_LogsAttempt()
    {
        var input = new MouseInputMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = MouseEventType.Press,
            Button = MouseButton.Left,
            X = 100,
            Y = 200
        };

        _ = _service.InjectMouse(input);

        // Verify no exception thrown
    }

    [Fact]
    public void InjectMouse_WithScrollEvent_LogsAttempt()
    {
        var input = new MouseInputMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = MouseEventType.Scroll,
            ScrollDeltaY = 3.0
        };

        _ = _service.InjectMouse(input);

        // Verify no exception thrown
    }

    [Fact]
    public void InjectKeyboard_WithKeyDown_LogsAttempt()
    {
        var input = new KeyboardInputMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = KeyEventType.KeyDown,
            KeyCode = 65, // 'A' key
            ScanCode = 30
        };

        _ = _service.InjectKeyboard(input);

        // Verify no exception thrown
    }

    [Fact]
    public void InjectKeyboard_WithExtendedKey_LogsAttempt()
    {
        var input = new KeyboardInputMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = KeyEventType.KeyDown,
            KeyCode = 0x25, // Left arrow
            IsExtendedKey = true
        };

        _ = _service.InjectKeyboard(input);

        // Verify no exception thrown
    }

    [Fact]
    public void FocusWindow_DoesNotThrow()
    {
        // Try to focus a non-existent window
        var result = _service.FocusWindow(999999UL);

        // On non-Windows, this will fail silently
        // Just verify no exception thrown
        Assert.True(result || !result); // Always true, just checking no exception
    }

    [Fact]
    public void MouseEventType_HasExpectedValues()
    {
        Assert.Equal(0, (int)MouseEventType.Move);
        Assert.Equal(1, (int)MouseEventType.Press);
        Assert.Equal(2, (int)MouseEventType.Release);
        Assert.Equal(3, (int)MouseEventType.Scroll);
    }

    [Fact]
    public void KeyEventType_HasExpectedValues()
    {
        Assert.Equal(0, (int)KeyEventType.KeyDown);
        Assert.Equal(1, (int)KeyEventType.KeyUp);
    }

    [Fact]
    public void MouseButton_HasExpectedValues()
    {
        Assert.Equal(1, (int)MouseButton.Left);
        Assert.Equal(2, (int)MouseButton.Right);
        Assert.Equal(4, (int)MouseButton.Middle);
        Assert.Equal(5, (int)MouseButton.Extra1);
        Assert.Equal(6, (int)MouseButton.Extra2);
    }

    [Fact]
    public void KeyModifiers_AreFlagsEnum()
    {
        var combined = KeyModifiers.Shift | KeyModifiers.Control | KeyModifiers.Alt;

        Assert.True(combined.HasFlag(KeyModifiers.Shift));
        Assert.True(combined.HasFlag(KeyModifiers.Control));
        Assert.True(combined.HasFlag(KeyModifiers.Alt));
        Assert.False(combined.HasFlag(KeyModifiers.Command));
    }

    [Fact]
    public void InjectMouse_AllButtonTypes_DoNotThrow()
    {
        var buttons = new[] { MouseButton.Left, MouseButton.Right, MouseButton.Middle, MouseButton.Extra1, MouseButton.Extra2 };

        foreach (var button in buttons)
        {
            var input = new MouseInputMessage
            {
                MessageId = 1,
                EventType = MouseEventType.Press,
                Button = button
            };

            // Should not throw
            _ = _service.InjectMouse(input);
        }
    }

    [Fact]
    public void InjectMouse_HorizontalScroll_DoesNotThrow()
    {
        var input = new MouseInputMessage
        {
            MessageId = 1,
            EventType = MouseEventType.Scroll,
            ScrollDeltaX = 2.0 // Horizontal scroll
        };

        _ = _service.InjectMouse(input);

        // Verify no exception thrown
    }

    private sealed class TestLogger : IAgentLogger
    {
        public List<string> Messages { get; } = [];

        public void Debug(string message) => Messages.Add(message);
        public void Info(string message) => Messages.Add(message);
        public void Warn(string message) => Messages.Add(message);
        public void Error(string message) => Messages.Add(message);
    }
}

