namespace WinRun.Agent.Services;

public record HostMessage;

public record LaunchProgramMessage(string Path, string[] Arguments) : HostMessage;

public record RequestIconMessage(string ExecutablePath) : HostMessage;

public record ShortcutCreatedMessage(string ShortcutPath, string TargetPath) : HostMessage;
