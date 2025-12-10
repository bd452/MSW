using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class WindowTrackerTests
{
    [Fact]
    public void RectStoresDimensions()
    {
        var rect = new Rect(10, 20, 100, 200);

        Assert.Equal(10, rect.X);
        Assert.Equal(20, rect.Y);
        Assert.Equal(100, rect.Width);
        Assert.Equal(200, rect.Height);
    }

    [Fact]
    public void RectValueEquality()
    {
        var rect1 = new Rect(0, 0, 100, 200);
        var rect2 = new Rect(0, 0, 100, 200);
        var rect3 = new Rect(0, 0, 100, 201);

        Assert.Equal(rect1, rect2);
        Assert.NotEqual(rect1, rect3);
    }

    [Fact]
    public void WindowEventArgsStoresProperties()
    {
        var bounds = new Rect(10, 20, 800, 600);
        var args = new WindowEventArgs(
            WindowId: 12345,
            Title: "Test Window",
            Bounds: bounds,
            EventType: WindowEventType.Created);

        Assert.Equal(12345UL, args.WindowId);
        Assert.Equal("Test Window", args.Title);
        Assert.Equal(bounds, args.Bounds);
        Assert.Equal(WindowEventType.Created, args.EventType);
    }

    [Fact]
    public void WindowEventArgsDefaultEventTypeIsUpdated()
    {
        var args = new WindowEventArgs(1, "Title", new Rect(0, 0, 100, 100));

        Assert.Equal(WindowEventType.Updated, args.EventType);
    }

    [Fact]
    public void WindowMetadataStoresAllProperties()
    {
        var bounds = new Rect(0, 0, 1920, 1080);
        var metadata = new WindowMetadata(
            Hwnd: 0x12345,
            Title: "Test App",
            Bounds: bounds,
            ProcessId: 4567,
            ClassName: "TestClass",
            IsMinimized: false);

        Assert.Equal(0x12345, metadata.Hwnd);
        Assert.Equal("Test App", metadata.Title);
        Assert.Equal(bounds, metadata.Bounds);
        Assert.Equal(4567u, metadata.ProcessId);
        Assert.Equal("TestClass", metadata.ClassName);
        Assert.False(metadata.IsMinimized);
    }

    [Fact]
    public void WindowMetadataWithExpressionUpdatesField()
    {
        var original = new WindowMetadata(
            Hwnd: 0x100,
            Title: "Original",
            Bounds: new Rect(0, 0, 800, 600),
            ProcessId: 1234,
            ClassName: "TestClass",
            IsMinimized: false);

        var updated = original with { Title = "Updated", IsMinimized = true };

        Assert.Equal("Original", original.Title);
        Assert.False(original.IsMinimized);
        Assert.Equal("Updated", updated.Title);
        Assert.True(updated.IsMinimized);
        Assert.Equal(original.Hwnd, updated.Hwnd);
    }

    [Fact]
    public void WindowTrackerInitializesWithLogger()
    {
        var logger = new TestLogger();
        using var tracker = new WindowTracker(logger);

        Assert.NotNull(tracker.TrackedWindows);
        Assert.Empty(tracker.TrackedWindows);
    }

    [Fact]
    public void WindowTrackerDisposeIsIdempotent()
    {
        var logger = new TestLogger();
        var tracker = new WindowTracker(logger);

        tracker.Dispose();
        tracker.Dispose(); // Should not throw
    }

    [Fact]
    public void WindowTrackerStartThrowsAfterDispose()
    {
        var logger = new TestLogger();
        var tracker = new WindowTracker(logger);
        tracker.Dispose();

        _ = Assert.Throws<ObjectDisposedException>(() =>
            tracker.Start((_, _) => { }));
    }

    [Fact]
    public void AllWindowEventTypesAreDefined()
    {
        var eventTypes = Enum.GetValues<WindowEventType>();

        Assert.Contains(WindowEventType.Created, eventTypes);
        Assert.Contains(WindowEventType.Destroyed, eventTypes);
        Assert.Contains(WindowEventType.Moved, eventTypes);
        Assert.Contains(WindowEventType.TitleChanged, eventTypes);
        Assert.Contains(WindowEventType.FocusChanged, eventTypes);
        Assert.Contains(WindowEventType.Minimized, eventTypes);
        Assert.Contains(WindowEventType.Restored, eventTypes);
        Assert.Contains(WindowEventType.Updated, eventTypes);
    }

    [Fact]
    public void WindowTrackerStartCanBeCalledMultipleTimes()
    {
        var logger = new TestLogger();
        using var tracker = new WindowTracker(logger);

        var handler = new EventHandler<WindowEventArgs>((_, _) => { });

        tracker.Start(handler);
        tracker.Stop();

        // Should be able to start again after stop
        tracker.Start(handler);
        tracker.Stop();
    }

    [Fact]
    public void WindowTrackerStopClearsTrackedWindows()
    {
        var logger = new TestLogger();
        using var tracker = new WindowTracker(logger);

        tracker.Start((_, _) => { });
        tracker.Stop();

        Assert.Empty(tracker.TrackedWindows);
    }

    [Fact]
    public void WindowTrackerWindowEventCanBeSubscribed()
    {
        var logger = new TestLogger();
        using var tracker = new WindowTracker(logger);

        // Event subscription should not throw
        tracker.WindowEvent += (_, _) => { };

        tracker.Start((_, _) => { });

        // If we get here, event subscription succeeded
        Assert.True(true);
    }

    [Fact]
    public void WindowTrackerDisposeStopsTracking()
    {
        var logger = new TestLogger();
        var tracker = new WindowTracker(logger);

        tracker.Start((_, _) => { });
        tracker.Dispose();

        // Should not throw when accessing after dispose
        _ = tracker.TrackedWindows;
    }

    [Fact]
    public void WindowEventArgsAllEventTypes()
    {
        var bounds = new Rect(0, 0, 100, 100);

        var created = new WindowEventArgs(1, "Title", bounds, WindowEventType.Created);
        var destroyed = new WindowEventArgs(2, "Title", bounds, WindowEventType.Destroyed);
        var moved = new WindowEventArgs(3, "Title", bounds, WindowEventType.Moved);
        var titleChanged = new WindowEventArgs(4, "Title", bounds, WindowEventType.TitleChanged);
        var focusChanged = new WindowEventArgs(5, "Title", bounds, WindowEventType.FocusChanged);
        var minimized = new WindowEventArgs(6, "Title", bounds, WindowEventType.Minimized);
        var restored = new WindowEventArgs(7, "Title", bounds, WindowEventType.Restored);
        var updated = new WindowEventArgs(8, "Title", bounds, WindowEventType.Updated);

        Assert.Equal(WindowEventType.Created, created.EventType);
        Assert.Equal(WindowEventType.Destroyed, destroyed.EventType);
        Assert.Equal(WindowEventType.Moved, moved.EventType);
        Assert.Equal(WindowEventType.TitleChanged, titleChanged.EventType);
        Assert.Equal(WindowEventType.FocusChanged, focusChanged.EventType);
        Assert.Equal(WindowEventType.Minimized, minimized.EventType);
        Assert.Equal(WindowEventType.Restored, restored.EventType);
        Assert.Equal(WindowEventType.Updated, updated.EventType);
    }

    [Fact]
    public void RectNegativeValuesAreAllowed()
    {
        var rect = new Rect(-100, -200, 50, 75);

        Assert.Equal(-100, rect.X);
        Assert.Equal(-200, rect.Y);
        Assert.Equal(50, rect.Width);
        Assert.Equal(75, rect.Height);
    }

    [Fact]
    public void RectZeroDimensionsAreAllowed()
    {
        var rect = new Rect(0, 0, 0, 0);

        Assert.Equal(0, rect.Width);
        Assert.Equal(0, rect.Height);
    }

}
