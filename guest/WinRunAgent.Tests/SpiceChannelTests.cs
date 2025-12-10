using System.Buffers.Binary;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class SpiceChannelTests
{
    [Fact]
    public void TryReadMessageHandlesFragmentedPayload()
    {
        var launch = new LaunchProgramMessage
        {
            MessageId = 42,
            Path = @"C:\Program Files\App.exe",
            Arguments = ["--foo", "--bar"],
            WorkingDirectory = @"C:\Program Files"
        };

        var bytes = SerializeHostMessage(SpiceMessageType.LaunchProgram, launch);

        // Split the envelope to simulate partial network reads
        var part1 = bytes[..3]; // less than header size
        var part2 = bytes[3..7]; // still incomplete payload
        var part3 = bytes[7..]; // remainder

        var buffer = new List<byte>();

        buffer.AddRange(part1);
        var consumed = SpiceMessageSerializer.TryReadMessage(buffer.ToArray(), out var message);
        Assert.Equal(0, consumed);
        Assert.Null(message);

        buffer.AddRange(part2);
        consumed = SpiceMessageSerializer.TryReadMessage(buffer.ToArray(), out message);
        Assert.Equal(0, consumed);
        Assert.Null(message);

        buffer.AddRange(part3);
        consumed = SpiceMessageSerializer.TryReadMessage(buffer.ToArray(), out message);

        Assert.Equal(bytes.Length, consumed);
        var parsed = Assert.IsType<LaunchProgramMessage>(message);
        Assert.Equal(launch.MessageId, parsed.MessageId);
        Assert.Equal(launch.Path, parsed.Path);
        Assert.Equal(launch.Arguments.Length, parsed.Arguments.Length);
        Assert.Equal(launch.WorkingDirectory, parsed.WorkingDirectory);
    }

    [Fact]
    public void TryReadMessageProcessesMultipleQueuedMessages()
    {
        var launch = new LaunchProgramMessage
        {
            MessageId = 1,
            Path = @"C:\first.exe",
            Arguments = ["--first"]
        };

        var shutdown = new ShutdownMessage
        {
            MessageId = 2,
            TimeoutMs = 10_000
        };

        var bytes1 = SerializeHostMessage(SpiceMessageType.LaunchProgram, launch);
        var bytes2 = SerializeHostMessage(SpiceMessageType.Shutdown, shutdown);
        var combined = new byte[bytes1.Length + bytes2.Length];
        bytes1.CopyTo(combined, 0);
        bytes2.CopyTo(combined, bytes1.Length);

        var consumed = SpiceMessageSerializer.TryReadMessage(combined, out var msg1);
        Assert.Equal(bytes1.Length, consumed);
        var launchParsed = Assert.IsType<LaunchProgramMessage>(msg1);
        Assert.Equal(launch.MessageId, launchParsed.MessageId);

        var remaining = combined.AsSpan(consumed);
        consumed = SpiceMessageSerializer.TryReadMessage(remaining, out var msg2);
        Assert.Equal(bytes2.Length, consumed);
        var shutdownParsed = Assert.IsType<ShutdownMessage>(msg2);
        Assert.Equal(shutdown.MessageId, shutdownParsed.MessageId);
        Assert.Equal(shutdown.TimeoutMs, shutdownParsed.TimeoutMs);
    }

    [Fact]
    public void TryReadMessageReturnsZeroUntilEnvelopeComplete()
    {
        var message = new RequestIconMessage
        {
            MessageId = 99,
            ExecutablePath = @"C:\App\app.exe",
            PreferredSize = 256
        };

        var bytes = SerializeHostMessage(SpiceMessageType.RequestIcon, message);

        // Construct a buffer that has full header but not full payload
        var partialLength = 5 + (bytes.Length - 5) / 2;
        var incomplete = bytes[..partialLength];

        var consumed = SpiceMessageSerializer.TryReadMessage(incomplete, out var parsed);
        Assert.Equal(0, consumed);
        Assert.Null(parsed);

        // Append the remaining bytes and expect successful parse
        var complete = bytes;
        consumed = SpiceMessageSerializer.TryReadMessage(complete, out parsed);
        Assert.Equal(bytes.Length, consumed);
        Assert.IsType<RequestIconMessage>(parsed);
    }

    private static byte[] SerializeHostMessage<T>(SpiceMessageType type, T message) where T : HostMessage
    {
        var options = new System.Text.Json.JsonSerializerOptions
        {
            PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase
        };

        var payload = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(message, options);
        var result = new byte[5 + payload.Length];
        result[0] = (byte)type;
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(result, 5);
        return result;
    }
}
