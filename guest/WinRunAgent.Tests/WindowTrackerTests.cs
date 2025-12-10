using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class WindowTrackerTests
{
    [Fact]
    public void RectStoresDimensions()
    {
        var rect = new Rect(0, 0, 100, 200);
        Assert.Equal(100, rect.Width);
        Assert.Equal(200, rect.Height);
    }
}
