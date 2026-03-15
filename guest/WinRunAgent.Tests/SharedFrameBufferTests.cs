using System.Runtime.InteropServices;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class SharedFrameBufferTests
{
    [Fact]
    public void SharedFrameBufferHeaderCreate_IsValidByDefault()
    {
        var header = SharedFrameBufferHeader.Create();

        Assert.True(header.IsValid);
        Assert.Equal(SharedFrameBufferConstants.Magic, header.Magic);
        Assert.Equal(SharedFrameBufferConstants.Version, header.Version);
    }

    [Fact]
    public void SharedFrameBufferHeader_AvailableFramesAndFullStateHandleWrapAround()
    {
        var header = new SharedFrameBufferHeader
        {
            Magic = SharedFrameBufferConstants.Magic,
            Version = SharedFrameBufferConstants.Version,
            SlotCount = 4,
            ReadIndex = 3,
            WriteIndex = 1
        };

        Assert.Equal(2u, header.AvailableFrames);
        Assert.True(header.HasFrames);

        header.ReadIndex = 0;
        header.WriteIndex = 3;
        Assert.True(header.IsFull);
    }

    [Fact]
    public void SharedFrameBufferConfigCreateHeader_SetsExpectedSizing()
    {
        var config = new SharedFrameBufferConfig
        {
            SlotCount = 3,
            MaxWidth = 640,
            MaxHeight = 480,
            BytesPerPixel = 4
        };

        var header = config.CreateHeader();

        Assert.True(header.IsValid);
        Assert.Equal((uint)config.TotalSize, header.TotalSize);
        Assert.Equal((uint)config.SlotCount, header.SlotCount);
        Assert.Equal((uint)config.SlotSize, header.SlotSize);
        Assert.Equal((uint)config.MaxWidth, header.MaxWidth);
        Assert.Equal((uint)config.MaxHeight, header.MaxHeight);
    }

    [Fact]
    public void SharedFrameBufferWriter_InitializeHeaderAndWriteFrame_WritesSlotAndAdvancesIndex()
    {
        var logger = new TestLogger();
        var config = new SharedFrameBufferConfig
        {
            SlotCount = 3,
            MaxWidth = 8,
            MaxHeight = 8,
            BytesPerPixel = 4
        };

        var pointer = Marshal.AllocHGlobal(config.TotalSize);

        try
        {
            using var writer = new SharedFrameBufferWriter(logger);
            writer.Initialize(pointer, config.TotalSize);
            writer.InitializeHeader(config);

            var payload = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
            var slot = writer.WriteFrame(
                windowId: 42,
                frameNumber: 7,
                width: 2,
                height: 1,
                stride: 8,
                format: PixelFormatType.Bgra32,
                data: payload,
                isCompressed: true);

            Assert.Equal(0, slot);

            var header = writer.ReadHeader();
            Assert.Equal(1u, header.WriteIndex);
            Assert.Equal(0u, header.ReadIndex);

            var slotOffset = SharedFrameBufferHeader.Size;
            var slotHeader = Marshal.PtrToStructure<FrameSlotHeader>(pointer + slotOffset);
            Assert.Equal(42ul, slotHeader.WindowId);
            Assert.Equal(7u, slotHeader.FrameNumber);
            Assert.Equal(2u, slotHeader.Width);
            Assert.Equal(1u, slotHeader.Height);
            Assert.Equal((uint)PixelFormatType.Bgra32, slotHeader.Format);
            Assert.True(slotHeader.Flags.HasFlag(FrameSlotFlags.KeyFrame));
            Assert.True(slotHeader.Flags.HasFlag(FrameSlotFlags.Compressed));

            var data = new byte[payload.Length];
            Marshal.Copy(pointer + slotOffset + FrameSlotHeader.Size, data, 0, data.Length);
            Assert.Equal(payload, data);
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [Fact]
    public void SharedFrameBufferWriter_ReturnsMinusOneWhenBufferIsFull()
    {
        var logger = new TestLogger();
        var config = new SharedFrameBufferConfig
        {
            SlotCount = 2,
            MaxWidth = 4,
            MaxHeight = 4
        };

        var pointer = Marshal.AllocHGlobal(config.TotalSize);

        try
        {
            using var writer = new SharedFrameBufferWriter(logger);
            writer.Initialize(pointer, config.TotalSize);
            writer.InitializeHeader(config);

            var frame = new byte[16];
            var first = writer.WriteFrame(1, 1, 2, 2, 8, PixelFormatType.Bgra32, frame);
            var second = writer.WriteFrame(1, 2, 2, 2, 8, PixelFormatType.Bgra32, frame);

            Assert.Equal(0, first);
            Assert.Equal(-1, second);
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [Fact]
    public void SharedFrameBufferWriter_ReturnsMinusOneWhenFrameDoesNotFitSlot()
    {
        var logger = new TestLogger();
        var config = new SharedFrameBufferConfig
        {
            SlotCount = 3,
            MaxWidth = 4,
            MaxHeight = 4
        };

        var pointer = Marshal.AllocHGlobal(config.TotalSize);

        try
        {
            using var writer = new SharedFrameBufferWriter(logger);
            writer.Initialize(pointer, config.TotalSize);
            writer.InitializeHeader(config);

            var oversized = new byte[config.SlotSize];
            var slot = writer.WriteFrame(1, 1, 2, 2, 8, PixelFormatType.Bgra32, oversized);

            Assert.Equal(-1, slot);
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [Fact]
    public void SharedFrameBufferWriter_CanToggleGuestActiveAndReadHostActive()
    {
        var logger = new TestLogger();
        var config = new SharedFrameBufferConfig
        {
            SlotCount = 3,
            MaxWidth = 4,
            MaxHeight = 4
        };

        var pointer = Marshal.AllocHGlobal(config.TotalSize);

        try
        {
            using var writer = new SharedFrameBufferWriter(logger);
            writer.Initialize(pointer, config.TotalSize);
            writer.InitializeHeader(config);

            writer.SetGuestActive(true);
            var header = writer.ReadHeader();
            Assert.True(((SharedFrameBufferFlags)header.Flags).HasFlag(SharedFrameBufferFlags.GuestActive));

            header.Flags = (uint)(SharedFrameBufferFlags.GuestActive | SharedFrameBufferFlags.HostActive);
            Marshal.StructureToPtr(header, pointer, false);

            Assert.True(writer.IsHostActive());
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [Fact]
    public void SharedFrameBufferWriter_MethodsThrowWhenNotInitialized()
    {
        using var writer = new SharedFrameBufferWriter(new TestLogger());

        _ = Assert.Throws<InvalidOperationException>(() => writer.ReadHeader());
        _ = Assert.Throws<InvalidOperationException>(() =>
            writer.WriteFrame(1, 1, 1, 1, 4, PixelFormatType.Bgra32, new byte[] { 0x1 }));
    }
}
