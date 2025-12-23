// GenerateProtocol - Generates Protocol.generated.cs from shared/protocol.def
//
// Usage: dotnet run [path/to/protocol.def] [output/path.cs]

using System.Text;
using System.Text.RegularExpressions;

// Find repo root by looking for shared/protocol.def
var currentDir = Directory.GetCurrentDirectory();
var repoRoot = FindRepoRoot(currentDir) ?? currentDir;

var inputPath = args.Length > 0
    ? args[0]
    : Path.Combine(repoRoot, "shared", "protocol.def");

var outputPath = args.Length > 1
    ? args[1]
    : Path.Combine(repoRoot, "guest", "WinRunAgent", "Protocol.generated.cs");

try
{
    var def = ParseProtocolDef(inputPath);
    var csharp = GenerateCSharp(def);
    File.WriteAllText(outputPath, csharp);
    Console.WriteLine($"✅ Generated {outputPath}");
}
catch (Exception ex)
{
    Console.Error.WriteLine($"❌ Error: {ex.Message}");
    Environment.Exit(1);
}

static string? FindRepoRoot(string startDir)
{
    var dir = startDir;
    while (!string.IsNullOrEmpty(dir))
    {
        if (File.Exists(Path.Combine(dir, "shared", "protocol.def")))
            return dir;
        dir = Path.GetDirectoryName(dir);
    }
    return null;
}

static ProtocolDefinition ParseProtocolDef(string path)
{
    var def = new ProtocolDefinition();
    var currentSection = "";

    foreach (var rawLine in File.ReadLines(path))
    {
        var line = rawLine.Trim();

        // Skip comments and empty lines
        if (string.IsNullOrEmpty(line) || line.StartsWith('#'))
            continue;

        // Section header
        if (line.StartsWith('[') && line.EndsWith(']'))
        {
            currentSection = line[1..^1];
            continue;
        }

        // Key = Value
        var eqIndex = line.IndexOf('=');
        if (eqIndex < 0) continue;

        var key = line[..eqIndex].Trim();
        var value = line[(eqIndex + 1)..].Trim();

        switch (currentSection)
        {
            case "VERSION":
                if (key == "PROTOCOL_VERSION_MAJOR")
                    def.VersionMajor = ParseInt(value);
                else if (key == "PROTOCOL_VERSION_MINOR")
                    def.VersionMinor = ParseInt(value);
                break;

            case "MESSAGE_TYPES_HOST_TO_GUEST":
                def.MessageTypesHostToGuest.Add((key, ParseInt(value)));
                break;

            case "MESSAGE_TYPES_GUEST_TO_HOST":
                def.MessageTypesGuestToHost.Add((key, ParseInt(value)));
                break;

            case "CAPABILITIES":
                def.Capabilities.Add((key, ParseInt(value)));
                break;

            case "MOUSE_BUTTONS":
                def.MouseButtons.Add((key, ParseInt(value)));
                break;

            case "MOUSE_EVENT_TYPES":
                def.MouseEventTypes.Add((key, ParseInt(value)));
                break;

            case "KEY_EVENT_TYPES":
                def.KeyEventTypes.Add((key, ParseInt(value)));
                break;

            case "KEY_MODIFIERS":
                def.KeyModifiers.Add((key, ParseInt(value)));
                break;

            case "DRAG_DROP_EVENT_TYPES":
                def.DragDropEventTypes.Add((key, ParseInt(value)));
                break;

            case "DRAG_OPERATIONS":
                def.DragOperations.Add((key, ParseInt(value)));
                break;

            case "PIXEL_FORMATS":
                def.PixelFormats.Add((key, ParseInt(value)));
                break;

            case "WINDOW_EVENT_TYPES":
                def.WindowEventTypes.Add((key, ParseInt(value)));
                break;

            case "CLIPBOARD_FORMATS":
                def.ClipboardFormats.Add((key, value));
                break;

            case "PROVISIONING_PHASES":
                def.ProvisioningPhases.Add((key, value));
                break;
        }
    }

    return def;
}

static int ParseInt(string value)
{
    if (value.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        return Convert.ToInt32(value[2..], 16);
    return int.Parse(value);
}

static string ToCSharpEnumName(string name, string prefix)
{
    // Convert MSG_LAUNCH_PROGRAM -> LaunchProgram
    var result = name;
    if (result.StartsWith(prefix))
        result = result[prefix.Length..];

    // Special case for key event types to preserve existing API
    if (prefix == "KEY_EVENT_")
    {
        return result switch
        {
            "DOWN" => "KeyDown",
            "UP" => "KeyUp",
            _ => string.Join("", result.Split('_')
                .Select(p => char.ToUpper(p[0]) + p[1..].ToLower()))
        };
    }

    // Convert SNAKE_CASE to PascalCase
    return string.Join("", result.Split('_')
        .Select(p => char.ToUpper(p[0]) + p[1..].ToLower()));
}

static string GenerateCSharp(ProtocolDefinition def)
{
    var sb = new StringBuilder();

    sb.AppendLine("""
        // Protocol.generated.cs
        // AUTO-GENERATED FROM shared/protocol.def - DO NOT EDIT DIRECTLY
        //
        // To regenerate: make generate-protocol
        // Source of truth: shared/protocol.def

        namespace WinRun.Agent.Services;

        #pragma warning disable CA1008 // Enums should have zero value

        // ============================================================================
        // Protocol Version
        // ============================================================================

        /// <summary>
        /// Protocol version constants - generated from shared/protocol.def
        /// </summary>
        public static class SpiceProtocolVersion
        {
        """);

    sb.AppendLine($"    public const ushort Major = {def.VersionMajor};");
    sb.AppendLine($"    public const ushort Minor = {def.VersionMinor};");
    sb.AppendLine("    public static uint Combined => ((uint)Major << 16) | Minor;");
    sb.AppendLine("}");

    // Message Types
    sb.AppendLine("""

        // ============================================================================
        // Message Types
        // ============================================================================

        /// <summary>
        /// Message type codes - generated from shared/protocol.def
        /// </summary>
        public enum SpiceMessageType : byte
        {
            // Host → Guest (0x00-0x7F)
        """);

    foreach (var (name, value) in def.MessageTypesHostToGuest)
    {
        var enumName = ToCSharpEnumName(name, "MSG_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }

    sb.AppendLine();
    sb.AppendLine("    // Guest → Host (0x80-0xFF)");

    foreach (var (name, value) in def.MessageTypesGuestToHost)
    {
        var enumName = ToCSharpEnumName(name, "MSG_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }

    sb.AppendLine("}");

    // Capabilities
    sb.AppendLine("""

        // ============================================================================
        // Guest Capabilities
        // ============================================================================

        /// <summary>
        /// Guest capability flags - generated from shared/protocol.def
        /// </summary>
        [Flags]
        public enum GuestCapabilities : uint
        {
            None = 0,
        """);

    foreach (var (name, value) in def.Capabilities)
    {
        var enumName = ToCSharpEnumName(name, "CAP_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }

    sb.AppendLine("}");

    // Mouse Buttons
    sb.AppendLine("""

        // ============================================================================
        // Mouse Input
        // ============================================================================

        /// <summary>
        /// Mouse button codes - generated from shared/protocol.def
        /// </summary>
        public enum MouseButton : byte
        {
        """);

    foreach (var (name, value) in def.MouseButtons)
    {
        var enumName = ToCSharpEnumName(name, "MOUSE_BUTTON_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Mouse Event Types
    sb.AppendLine("""

        /// <summary>
        /// Mouse event types - generated from shared/protocol.def
        /// </summary>
        public enum MouseEventType : byte
        {
        """);

    foreach (var (name, value) in def.MouseEventTypes)
    {
        var enumName = ToCSharpEnumName(name, "MOUSE_EVENT_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Key Event Types
    sb.AppendLine("""

        // ============================================================================
        // Keyboard Input
        // ============================================================================

        /// <summary>
        /// Key event types - generated from shared/protocol.def
        /// </summary>
        public enum KeyEventType : byte
        {
        """);

    foreach (var (name, value) in def.KeyEventTypes)
    {
        var enumName = ToCSharpEnumName(name, "KEY_EVENT_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Key Modifiers
    sb.AppendLine("""

        /// <summary>
        /// Key modifier flags - generated from shared/protocol.def
        /// </summary>
        [Flags]
        public enum KeyModifiers : byte
        {
        """);

    foreach (var (name, value) in def.KeyModifiers)
    {
        var enumName = ToCSharpEnumName(name, "KEY_MOD_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }

    sb.AppendLine("}");

    // Drag/Drop Event Types
    sb.AppendLine("""

        // ============================================================================
        // Drag and Drop
        // ============================================================================

        /// <summary>
        /// Drag/drop event types - generated from shared/protocol.def
        /// </summary>
        public enum DragDropEventType : byte
        {
        """);

    foreach (var (name, value) in def.DragDropEventTypes)
    {
        var enumName = ToCSharpEnumName(name, "DRAG_EVENT_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Drag Operations
    sb.AppendLine("""

        /// <summary>
        /// Drag operation types - generated from shared/protocol.def
        /// </summary>
        public enum DragOperation : byte
        {
        """);

    foreach (var (name, value) in def.DragOperations)
    {
        var enumName = ToCSharpEnumName(name, "DRAG_OP_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Pixel Formats
    sb.AppendLine("""

        // ============================================================================
        // Pixel Formats
        // ============================================================================

        /// <summary>
        /// Pixel format types - generated from shared/protocol.def
        /// </summary>
        public enum PixelFormatType : byte
        {
        """);

    foreach (var (name, value) in def.PixelFormats)
    {
        var enumName = ToCSharpEnumName(name, "PIXEL_FORMAT_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Window Event Types
    sb.AppendLine("""

        // ============================================================================
        // Window Events
        // ============================================================================

        /// <summary>
        /// Window event types - generated from shared/protocol.def
        /// </summary>
        public enum WindowEventType : int
        {
        """);

    foreach (var (name, value) in def.WindowEventTypes)
    {
        var enumName = ToCSharpEnumName(name, "WINDOW_EVENT_");
        sb.AppendLine($"    {enumName} = {value},");
    }

    sb.AppendLine("}");

    // Clipboard Formats
    sb.AppendLine("""

        // ============================================================================
        // Clipboard Formats
        // ============================================================================

        /// <summary>
        /// Clipboard format identifiers - generated from shared/protocol.def
        /// </summary>
        public enum ClipboardFormat
        {
        """);

    foreach (var (name, _) in def.ClipboardFormats)
    {
        var enumName = ToCSharpEnumName(name, "CLIPBOARD_FORMAT_");
        sb.AppendLine($"    {enumName},");
    }

    sb.AppendLine("}");

    // Provisioning Phases
    sb.AppendLine("""

        // ============================================================================
        // Provisioning Phases
        // ============================================================================

        /// <summary>
        /// Provisioning phase identifiers - generated from shared/protocol.def
        /// </summary>
        public enum ProvisioningPhase
        {
        """);

    foreach (var (name, _) in def.ProvisioningPhases)
    {
        var enumName = ToCSharpEnumName(name, "PROVISION_PHASE_");
        sb.AppendLine($"    {enumName},");
    }

    sb.AppendLine("}");

    // Backwards compatibility typealiases
    sb.AppendLine("""

        // ============================================================================
        // Backwards Compatibility Aliases
        // ============================================================================
        // These allow existing code referencing Generated* types to continue working
        // TODO: Remove these after migrating all code to use the canonical type names

        #pragma warning disable CA1711 // Identifiers should not have incorrect suffix

        /// <summary>Backwards compatibility alias - use SpiceProtocolVersion instead</summary>
        [Obsolete("Use SpiceProtocolVersion instead")]
        public static class GeneratedProtocolVersion
        {
            public const ushort Major = SpiceProtocolVersion.Major;
            public const ushort Minor = SpiceProtocolVersion.Minor;
            public static uint Combined => SpiceProtocolVersion.Combined;
        }

        /// <summary>Backwards compatibility alias - use SpiceMessageType instead</summary>
        [Obsolete("Use SpiceMessageType instead")]
        public enum GeneratedMessageType : byte
        {
        """);

    foreach (var (name, value) in def.MessageTypesHostToGuest)
    {
        var enumName = ToCSharpEnumName(name, "MSG_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }
    foreach (var (name, value) in def.MessageTypesGuestToHost)
    {
        var enumName = ToCSharpEnumName(name, "MSG_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }

    sb.AppendLine("""
        }

        /// <summary>Backwards compatibility alias - use GuestCapabilities instead</summary>
        [Obsolete("Use GuestCapabilities instead")]
        [Flags]
        public enum GeneratedCapabilities : uint
        {
            None = 0,
        """);

    foreach (var (name, value) in def.Capabilities)
    {
        var enumName = ToCSharpEnumName(name, "CAP_");
        sb.AppendLine($"    {enumName} = 0x{value:X2},");
    }

    sb.AppendLine("}");

    sb.AppendLine();
    sb.AppendLine("#pragma warning restore CA1711");
    sb.AppendLine("#pragma warning restore CA1008");

    return sb.ToString();
}

class ProtocolDefinition
{
    public int VersionMajor { get; set; } = 1;
    public int VersionMinor { get; set; }
    public List<(string Name, int Value)> MessageTypesHostToGuest { get; } = [];
    public List<(string Name, int Value)> MessageTypesGuestToHost { get; } = [];
    public List<(string Name, int Value)> Capabilities { get; } = [];
    public List<(string Name, int Value)> MouseButtons { get; } = [];
    public List<(string Name, int Value)> MouseEventTypes { get; } = [];
    public List<(string Name, int Value)> KeyEventTypes { get; } = [];
    public List<(string Name, int Value)> KeyModifiers { get; } = [];
    public List<(string Name, int Value)> DragDropEventTypes { get; } = [];
    public List<(string Name, int Value)> DragOperations { get; } = [];
    public List<(string Name, int Value)> PixelFormats { get; } = [];
    public List<(string Name, int Value)> WindowEventTypes { get; } = [];
    public List<(string Name, string Value)> ClipboardFormats { get; } = [];
    public List<(string Name, string Value)> ProvisioningPhases { get; } = [];
}
