using System.Buffers.Binary;
using System.Reflection;
using System.Threading.Channels;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class SpiceControlPortTests : IDisposable
{
    private readonly Channel<HostMessage> _inbound = Channel.CreateUnbounded<HostMessage>();
    private readonly Channel<GuestMessage> _outbound = Channel.CreateUnbounded<GuestMessage>();
    private readonly SpiceControlPort _port;

    public SpiceControlPortTests()
    {
        _port = new SpiceControlPort(new TestLogger(), _inbound, _outbound);
    }

    public void Dispose()
    {
        _port.Dispose();
    }

    [Fact]
    public async Task ProcessReadBufferAsync_WithCompleteMessage_QueuesInboundMessage()
    {
        var launch = new LaunchProgramMessage
        {
            MessageId = 77,
            Path = @"C:\Windows\System32\notepad.exe",
            Arguments = ["file.txt"]
        };

        var bytes = SerializeHostMessage(SpiceMessageType.LaunchProgram, launch);
        AppendToReadBuffer(_port, bytes);
        await InvokeProcessReadBufferAsync(_port);

        Assert.True(_inbound.Reader.TryRead(out var message));
        var parsed = Assert.IsType<LaunchProgramMessage>(message);
        Assert.Equal(77u, parsed.MessageId);
        Assert.Equal(launch.Path, parsed.Path);
        Assert.Equal(launch.Arguments, parsed.Arguments);
    }

    [Fact]
    public async Task ProcessReadBufferAsync_WithFragmentedMessage_WaitsForRemainder()
    {
        var shutdown = new ShutdownMessage
        {
            MessageId = 5,
            TimeoutMs = 1234
        };

        var bytes = SerializeHostMessage(SpiceMessageType.Shutdown, shutdown);
        var splitAt = Math.Min(8, bytes.Length - 1);

        AppendToReadBuffer(_port, bytes[..splitAt]);
        await InvokeProcessReadBufferAsync(_port);
        Assert.False(_inbound.Reader.TryRead(out _));

        AppendToReadBuffer(_port, bytes[splitAt..]);
        await InvokeProcessReadBufferAsync(_port);

        Assert.True(_inbound.Reader.TryRead(out var message));
        var parsed = Assert.IsType<ShutdownMessage>(message);
        Assert.Equal(5u, parsed.MessageId);
        Assert.Equal(1234, parsed.TimeoutMs);
    }

    [Fact]
    public async Task ProcessReadBufferAsync_WithMultipleMessages_QueuesAllMessages()
    {
        var first = new ListSessionsMessage { MessageId = 10 };
        var second = new CloseSessionMessage { MessageId = 11, SessionId = "session-11" };

        var firstBytes = SerializeHostMessage(SpiceMessageType.ListSessions, first);
        var secondBytes = SerializeHostMessage(SpiceMessageType.CloseSession, second);
        var combined = new byte[firstBytes.Length + secondBytes.Length];
        firstBytes.CopyTo(combined, 0);
        secondBytes.CopyTo(combined, firstBytes.Length);

        AppendToReadBuffer(_port, combined);
        await InvokeProcessReadBufferAsync(_port);

        Assert.True(_inbound.Reader.TryRead(out var m1));
        Assert.True(_inbound.Reader.TryRead(out var m2));
        Assert.False(_inbound.Reader.TryRead(out _));

        var parsedFirst = Assert.IsType<ListSessionsMessage>(m1);
        var parsedSecond = Assert.IsType<CloseSessionMessage>(m2);

        Assert.Equal(10u, parsedFirst.MessageId);
        Assert.Equal(11u, parsedSecond.MessageId);
        Assert.Equal("session-11", parsedSecond.SessionId);
    }

    [Fact]
    public async Task StartWithoutConnection_AndStopAsync_AreSafe()
    {
        _port.Start();
        await _port.StopAsync();
    }

    [Fact]
    public async Task StopAsync_CanBeCalledBeforeStart()
    {
        await _port.StopAsync();
    }

    private static void AppendToReadBuffer(SpiceControlPort port, ReadOnlySpan<byte> data)
    {
        var readBufferField = typeof(SpiceControlPort).GetField(
            "_readBuffer",
            BindingFlags.NonPublic | BindingFlags.Instance);

        Assert.NotNull(readBufferField);
        var stream = Assert.IsType<MemoryStream>(readBufferField!.GetValue(port));
        stream.Write(data);
    }

    private static async Task InvokeProcessReadBufferAsync(SpiceControlPort port)
    {
        var method = typeof(SpiceControlPort).GetMethod(
            "ProcessReadBufferAsync",
            BindingFlags.NonPublic | BindingFlags.Instance);

        Assert.NotNull(method);
        var task = Assert.IsAssignableFrom<Task>(method!.Invoke(port, [CancellationToken.None]));
        await task;
    }

    private static byte[] SerializeHostMessage<T>(SpiceMessageType type, T message)
        where T : HostMessage
    {
        var payload = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(
            message,
            new System.Text.Json.JsonSerializerOptions
            {
                PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase
            });

        var result = new byte[5 + payload.Length];
        result[0] = (byte)type;
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(result, 5);
        return result;
    }
}
