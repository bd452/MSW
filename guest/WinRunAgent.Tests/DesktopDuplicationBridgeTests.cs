using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class DesktopDuplicationBridgeTests
{
    [Fact]
    public void CapturedFrameStoresProperties()
    {
        var data = new byte[100 * 50 * 4]; // 100x50 BGRA
        var frame = new CapturedFrame(
            Width: 100,
            Height: 50,
            Stride: 400,
            Format: PixelFormat.BGRA32,
            Data: data,
            Timestamp: 12345678L);

        Assert.Equal(100, frame.Width);
        Assert.Equal(50, frame.Height);
        Assert.Equal(400, frame.Stride);
        Assert.Equal(PixelFormat.BGRA32, frame.Format);
        Assert.Equal(data, frame.Data);
        Assert.Equal(12345678L, frame.Timestamp);
    }

    [Fact]
    public void ExtractWindowRegion_ValidRegion_ExtractsCorrectly()
    {
        // Create a 10x10 test frame with identifiable pixel pattern
        var width = 10;
        var height = 10;
        var stride = width * 4;
        var data = new byte[height * stride];

        // Fill with pattern: each pixel's R channel = X, G channel = Y
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = (y * stride) + (x * 4);
                data[offset + 0] = (byte)x;     // B = X
                data[offset + 1] = (byte)y;     // G = Y
                data[offset + 2] = 0xFF;        // R = 255
                data[offset + 3] = 0xFF;        // A = 255
            }
        }

        var frame = new CapturedFrame(width, height, stride, PixelFormat.BGRA32, data, 0);

        // Extract region from (2,3) with size 4x3
        var region = new Rect(2, 3, 4, 3);
        var result = DesktopDuplicationBridge.ExtractWindowRegion(frame, region);

        Assert.NotNull(result);
        Assert.Equal(4, result.Width);
        Assert.Equal(3, result.Height);
        Assert.Equal(16, result.Stride); // 4 pixels * 4 bytes

        // Verify first pixel is (2,3) from original
        Assert.Equal(2, result.Data[0]); // B = X = 2
        Assert.Equal(3, result.Data[1]); // G = Y = 3

        // Verify last pixel is (5,5) from original
        var lastOffset = (2 * result.Stride) + (3 * 4); // row 2, col 3
        Assert.Equal(5, result.Data[lastOffset + 0]); // B = X = 5
        Assert.Equal(5, result.Data[lastOffset + 1]); // G = Y = 5
    }

    [Fact]
    public void ExtractWindowRegion_OutOfBounds_ClampsToBounds()
    {
        var width = 10;
        var height = 10;
        var stride = width * 4;
        var data = new byte[height * stride];
        var frame = new CapturedFrame(width, height, stride, PixelFormat.BGRA32, data, 0);

        // Request region that extends past frame bounds
        var region = new Rect(8, 8, 5, 5); // Would extend to (13,13) but frame is only 10x10
        var result = DesktopDuplicationBridge.ExtractWindowRegion(frame, region);

        Assert.NotNull(result);
        Assert.Equal(2, result.Width);  // Clamped: 10 - 8 = 2
        Assert.Equal(2, result.Height); // Clamped: 10 - 8 = 2
    }

    [Fact]
    public void ExtractWindowRegion_NegativeStart_ClampsToZero()
    {
        var width = 10;
        var height = 10;
        var stride = width * 4;
        var data = new byte[height * stride];
        var frame = new CapturedFrame(width, height, stride, PixelFormat.BGRA32, data, 0);

        // Request region starting at negative coordinates
        var region = new Rect(-2, -3, 5, 6);
        var result = DesktopDuplicationBridge.ExtractWindowRegion(frame, region);

        Assert.NotNull(result);
        // Width: min(10, -2+5) - max(0, -2) = 3 - 0 = 3
        Assert.Equal(3, result.Width);
        // Height: min(10, -3+6) - max(0, -3) = 3 - 0 = 3
        Assert.Equal(3, result.Height);
    }

    [Fact]
    public void ExtractWindowRegion_CompletelyOutOfBounds_ReturnsNull()
    {
        var width = 10;
        var height = 10;
        var stride = width * 4;
        var data = new byte[height * stride];
        var frame = new CapturedFrame(width, height, stride, PixelFormat.BGRA32, data, 0);

        // Request region completely outside frame
        var region = new Rect(20, 20, 5, 5);
        var result = DesktopDuplicationBridge.ExtractWindowRegion(frame, region);

        Assert.Null(result);
    }

    [Fact]
    public void ExtractWindowRegion_ZeroSize_ReturnsNull()
    {
        var width = 10;
        var height = 10;
        var stride = width * 4;
        var data = new byte[height * stride];
        var frame = new CapturedFrame(width, height, stride, PixelFormat.BGRA32, data, 0);

        var region = new Rect(5, 5, 0, 0);
        var result = DesktopDuplicationBridge.ExtractWindowRegion(frame, region);

        Assert.Null(result);
    }

    [Fact]
    public void ExtractWindowRegion_PreservesFormatAndTimestamp()
    {
        var frame = new CapturedFrame(10, 10, 40, PixelFormat.BGRA32, new byte[400], 999L);
        var region = new Rect(0, 0, 5, 5);

        var result = DesktopDuplicationBridge.ExtractWindowRegion(frame, region);

        Assert.NotNull(result);
        Assert.Equal(PixelFormat.BGRA32, result.Format);
        Assert.Equal(999L, result.Timestamp);
    }

    [Fact]
    public void DesktopDuplicationBridgeInitializesWithLogger()
    {
        var logger = new TestLogger();
        using var bridge = new DesktopDuplicationBridge(logger);

        Assert.False(bridge.IsInitialized);
        Assert.Equal(0, bridge.OutputWidth);
        Assert.Equal(0, bridge.OutputHeight);
    }

    [Fact]
    public void DesktopDuplicationBridgeDisposeIsIdempotent()
    {
        var logger = new TestLogger();
        var bridge = new DesktopDuplicationBridge(logger);

        bridge.Dispose();
        bridge.Dispose(); // Should not throw
    }

    [Fact]
    public void DesktopDuplicationBridgeCaptureFrameThrowsAfterDispose()
    {
        var logger = new TestLogger();
        var bridge = new DesktopDuplicationBridge(logger);
        bridge.Dispose();

        Assert.Throws<ObjectDisposedException>(() => bridge.CaptureFrame());
    }

    [Fact]
    public void PixelFormatEnumHasExpectedValues()
    {
        var formats = Enum.GetValues<PixelFormat>();

        Assert.Contains(PixelFormat.BGRA32, formats);
        Assert.Contains(PixelFormat.RGBA32, formats);
    }

}

