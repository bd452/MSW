using System.Text.Json;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

/// <summary>
/// Tests that validate protocol types match the shared source of truth (protocol.def)
/// and verify behavioral correctness of the protocol implementation.
///
/// These tests read from shared/protocol-test-data.json which is generated from protocol.def.
/// This ensures Swift and C# implementations stay in sync.
/// </summary>
public sealed class ProtocolValidationTests
{
    private static readonly Lazy<ProtocolTestData> LazyTestData = new(LoadTestData);
    private static ProtocolTestData TestData => LazyTestData.Value;

    private static ProtocolTestData LoadTestData()
    {
        // Try multiple possible locations for the test data file
        var possiblePaths = new[]
        {
            // When running from dotnet test in guest/
            Path.Combine("..", "..", "..", "..", "shared", "protocol-test-data.json"),
            // When running from repo root
            Path.Combine("shared", "protocol-test-data.json"),
            // When running from guest/WinRunAgent.Tests/
            Path.Combine("..", "..", "shared", "protocol-test-data.json"),
            // Absolute path fallback (for CI)
            "/workspace/shared/protocol-test-data.json",
        };

        foreach (var path in possiblePaths)
        {
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<ProtocolTestData>(json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                    ?? new ProtocolTestData();
            }
        }

        // Return empty data - tests will be skipped
        return new ProtocolTestData();
    }

    // ========================================================================
    // Cross-Platform Parity Tests
    // ========================================================================

    [Fact]
    public void MessageTypesMatchProtocolDef()
    {
        Skip.If(TestData.MessageTypesHostToGuest.Count == 0, "Test data not loaded");

        // Host → Guest
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgLaunchProgram"),
            (int)SpiceMessageType.LaunchProgram);
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgRequestIcon"),
            (int)SpiceMessageType.RequestIcon);
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgClipboardData"),
            (int)SpiceMessageType.ClipboardData);
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgMouseInput"),
            (int)SpiceMessageType.MouseInput);
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgKeyboardInput"),
            (int)SpiceMessageType.KeyboardInput);
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgListSessions"),
            (int)SpiceMessageType.ListSessions);
        Assert.Equal(
            TestData.MessageTypesHostToGuest.GetValueOrDefault("msgShutdown"),
            (int)SpiceMessageType.Shutdown);

        // Guest → Host
        Assert.Equal(
            TestData.MessageTypesGuestToHost.GetValueOrDefault("msgWindowMetadata"),
            (int)SpiceMessageType.WindowMetadata);
        Assert.Equal(
            TestData.MessageTypesGuestToHost.GetValueOrDefault("msgFrameData"),
            (int)SpiceMessageType.FrameData);
        Assert.Equal(
            TestData.MessageTypesGuestToHost.GetValueOrDefault("msgCapabilityFlags"),
            (int)SpiceMessageType.CapabilityFlags);
        Assert.Equal(
            TestData.MessageTypesGuestToHost.GetValueOrDefault("msgError"),
            (int)SpiceMessageType.Error);
        Assert.Equal(
            TestData.MessageTypesGuestToHost.GetValueOrDefault("msgAck"),
            (int)SpiceMessageType.Ack);
    }

    [Fact]
    public void CapabilitiesMatchProtocolDef()
    {
        Skip.If(TestData.Capabilities.Count == 0, "Test data not loaded");

        Assert.Equal(
            TestData.Capabilities.GetValueOrDefault("capWindowTracking"),
            (int)GuestCapabilities.WindowTracking);
        Assert.Equal(
            TestData.Capabilities.GetValueOrDefault("capDesktopDuplication"),
            (int)GuestCapabilities.DesktopDuplication);
        Assert.Equal(
            TestData.Capabilities.GetValueOrDefault("capClipboardSync"),
            (int)GuestCapabilities.ClipboardSync);
        Assert.Equal(
            TestData.Capabilities.GetValueOrDefault("capIconExtraction"),
            (int)GuestCapabilities.IconExtraction);
    }

    // ========================================================================
    // Behavioral Tests: Message Direction
    // ========================================================================

    [Fact]
    public void HostToGuestMessagesAreInCorrectRange()
    {
        var hostMessages = new[]
        {
            SpiceMessageType.LaunchProgram, SpiceMessageType.RequestIcon,
            SpiceMessageType.ClipboardData, SpiceMessageType.MouseInput,
            SpiceMessageType.KeyboardInput, SpiceMessageType.DragDropEvent,
            SpiceMessageType.ListSessions, SpiceMessageType.CloseSession,
            SpiceMessageType.ListShortcuts, SpiceMessageType.Shutdown
        };

        foreach (var msg in hostMessages)
        {
            Assert.True((byte)msg < 0x80, $"{msg} should be < 0x80 (host→guest range)");
        }
    }

    [Fact]
    public void GuestToHostMessagesAreInCorrectRange()
    {
        var guestMessages = new[]
        {
            SpiceMessageType.WindowMetadata, SpiceMessageType.FrameData,
            SpiceMessageType.CapabilityFlags, SpiceMessageType.DpiInfo,
            SpiceMessageType.IconData, SpiceMessageType.ShortcutDetected,
            SpiceMessageType.ClipboardChanged, SpiceMessageType.Heartbeat,
            SpiceMessageType.TelemetryReport, SpiceMessageType.ProvisionProgress,
            SpiceMessageType.ProvisionError, SpiceMessageType.ProvisionComplete,
            SpiceMessageType.SessionList, SpiceMessageType.ShortcutList,
            SpiceMessageType.Error, SpiceMessageType.Ack
        };

        foreach (var msg in guestMessages)
        {
            Assert.True((byte)msg >= 0x80, $"{msg} should be >= 0x80 (guest→host range)");
        }
    }

    // ========================================================================
    // Behavioral Tests: Capabilities
    // ========================================================================

    [Fact]
    public void CapabilitiesArePowersOfTwo()
    {
        var capabilities = new[]
        {
            GuestCapabilities.WindowTracking, GuestCapabilities.DesktopDuplication,
            GuestCapabilities.ClipboardSync, GuestCapabilities.DragDrop,
            GuestCapabilities.IconExtraction, GuestCapabilities.ShortcutDetection,
            GuestCapabilities.HighDpiSupport, GuestCapabilities.MultiMonitor
        };

        foreach (var cap in capabilities)
        {
            var value = (uint)cap;
            // Power of 2 check: value & (value - 1) == 0 for powers of 2
            Assert.True((value & (value - 1)) == 0, $"{cap} should be a power of 2");
            Assert.True(value > 0, $"{cap} should be non-zero");
        }
    }

    [Fact]
    public void CapabilitiesCanBeCombined()
    {
        var combined = GuestCapabilities.WindowTracking | GuestCapabilities.ClipboardSync;

        Assert.True(combined.HasFlag(GuestCapabilities.WindowTracking));
        Assert.True(combined.HasFlag(GuestCapabilities.ClipboardSync));
        Assert.False(combined.HasFlag(GuestCapabilities.DragDrop));
    }

    // ========================================================================
    // Behavioral Tests: Protocol Version
    // ========================================================================

    [Fact]
    public void ProtocolVersionCombinedFormat()
    {
        // Combined format: upper 16 bits = major, lower 16 bits = minor
        var combined = SpiceProtocolVersion.Combined;
        var major = (ushort)(combined >> 16);
        var minor = (ushort)(combined & 0xFFFF);

        Assert.Equal(SpiceProtocolVersion.Major, major);
        Assert.Equal(SpiceProtocolVersion.Minor, minor);
    }

    [Fact]
    public void ProtocolVersionMatchesTestData()
    {
        Skip.If(TestData.Version.Count == 0, "Test data not loaded");

        Assert.Equal(
            TestData.Version.GetValueOrDefault("protocolVersionMajor"),
            SpiceProtocolVersion.Major);
        Assert.Equal(
            TestData.Version.GetValueOrDefault("protocolVersionMinor"),
            SpiceProtocolVersion.Minor);
    }

    // ========================================================================
    // Behavioral Tests: Key Modifiers
    // ========================================================================

    [Fact]
    public void KeyModifiersCanBeCombined()
    {
        var combined = KeyModifiers.Shift | KeyModifiers.Control | KeyModifiers.Alt;

        Assert.True(combined.HasFlag(KeyModifiers.Shift));
        Assert.True(combined.HasFlag(KeyModifiers.Control));
        Assert.True(combined.HasFlag(KeyModifiers.Alt));
        Assert.False(combined.HasFlag(KeyModifiers.Command));
    }

    // ========================================================================
    // Completeness Tests
    // ========================================================================

    [Fact]
    public void AllMessageTypesExist()
    {
        var allValues = Enum.GetValues<SpiceMessageType>();
        Assert.Equal(26, allValues.Length);

        // Verify no duplicate raw values
        var rawValues = allValues.Select(v => (byte)v).ToList();
        Assert.Equal(rawValues.Count, rawValues.Distinct().Count());
    }

    [Fact]
    public void AllClipboardFormatsExist()
    {
        var allFormats = Enum.GetValues<ClipboardFormat>();
        Assert.True(allFormats.Length >= 6);

        Assert.Contains(ClipboardFormat.PlainText, allFormats);
        Assert.Contains(ClipboardFormat.Rtf, allFormats);
        Assert.Contains(ClipboardFormat.Html, allFormats);
        Assert.Contains(ClipboardFormat.Png, allFormats);
    }

    [Fact]
    public void AllProvisioningPhasesExist()
    {
        var allPhases = Enum.GetValues<ProvisioningPhase>();
        Assert.Equal(5, allPhases.Length);

        Assert.Contains(ProvisioningPhase.Drivers, allPhases);
        Assert.Contains(ProvisioningPhase.Agent, allPhases);
        Assert.Contains(ProvisioningPhase.Optimize, allPhases);
        Assert.Contains(ProvisioningPhase.Finalize, allPhases);
        Assert.Contains(ProvisioningPhase.Complete, allPhases);
    }

    [Fact]
    public void AllKeyEventTypesExist()
    {
        var allTypes = Enum.GetValues<KeyEventType>();
        Assert.Equal(2, allTypes.Length);

        Assert.Contains(KeyEventType.KeyDown, allTypes);
        Assert.Contains(KeyEventType.KeyUp, allTypes);
    }

    [Fact]
    public void AllMouseEventTypesExist()
    {
        var allTypes = Enum.GetValues<MouseEventType>();
        Assert.Equal(4, allTypes.Length);

        Assert.Contains(MouseEventType.Move, allTypes);
        Assert.Contains(MouseEventType.Press, allTypes);
        Assert.Contains(MouseEventType.Release, allTypes);
        Assert.Contains(MouseEventType.Scroll, allTypes);
    }

    [Fact]
    public void AllDragOperationsExist()
    {
        var allOps = Enum.GetValues<DragOperation>();
        Assert.Equal(4, allOps.Length);

        Assert.Contains(DragOperation.None, allOps);
        Assert.Contains(DragOperation.Copy, allOps);
        Assert.Contains(DragOperation.Move, allOps);
        Assert.Contains(DragOperation.Link, allOps);
    }
}

// ========================================================================
// Test Data Model
// ========================================================================

file sealed class ProtocolTestData
{
    public Dictionary<string, int> Version { get; set; } = [];
    public Dictionary<string, int> MessageTypesHostToGuest { get; set; } = [];
    public Dictionary<string, int> MessageTypesGuestToHost { get; set; } = [];
    public Dictionary<string, int> Capabilities { get; set; } = [];
    public Dictionary<string, int> MouseButtons { get; set; } = [];
    public Dictionary<string, int> MouseEventTypes { get; set; } = [];
    public Dictionary<string, int> KeyEventTypes { get; set; } = [];
    public Dictionary<string, int> KeyModifiers { get; set; } = [];
    public Dictionary<string, int> DragDropEventTypes { get; set; } = [];
    public Dictionary<string, int> DragOperations { get; set; } = [];
    public Dictionary<string, int> PixelFormats { get; set; } = [];
    public Dictionary<string, int> WindowEventTypes { get; set; } = [];
    public Dictionary<string, string> ClipboardFormats { get; set; } = [];
    public Dictionary<string, string> ProvisioningPhases { get; set; } = [];
}
