using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

public sealed class WindowTracker
{
    private readonly IAgentLogger _logger;

    public WindowTracker(IAgentLogger logger)
    {
        _logger = logger;
    }

    public void Start(EventHandler<WindowEventArgs> handler)
    {
        _logger.Info("Starting Win32 window hooks (mock implementation in repo)");
        // Production builds would install SetWinEventHook callbacks here.
        Task.Run(async () =>
        {
            while (true)
            {
                await Task.Delay(TimeSpan.FromSeconds(5));
                handler.Invoke(this, new WindowEventArgs(0, "Mock Window", new Rect(0, 0, 800, 600)));
            }
        });
    }
}

public sealed record WindowEventArgs(ulong WindowId, string Title, Rect Bounds);

[StructLayout(LayoutKind.Sequential)]
public readonly record struct Rect(int X, int Y, int Width, int Height);
