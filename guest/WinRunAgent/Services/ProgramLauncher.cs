using System.Diagnostics;

namespace WinRun.Agent.Services;

public sealed class ProgramLauncher
{
    private readonly IAgentLogger _logger;

    public ProgramLauncher(IAgentLogger logger)
    {
        _logger = logger;
    }

    // TODO: Full implementation - see TODO.md "Launch Windows processes with arguments/env/working dirs"
    public async Task<Process?> LaunchAsync(string path, string[] arguments, CancellationToken token)
    {
        _ = token; // Will be used for process cancellation once fully implemented
        if (!File.Exists(path))
        {
            _logger.Error($"Executable not found: {path}");
            return null;
        }

        var psi = new ProcessStartInfo
        {
            FileName = path,
            Arguments = string.Join(' ', arguments.Select(a => $"\"{a}\"")),
            UseShellExecute = false
        };

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.Exited += (_, _) => _logger.Info($"Process {path} exited with {process.ExitCode}");
        _logger.Info($"Launching {path}");
        _ = process.Start(); // Return value intentionally discarded - we track via Exited event
        await Task.CompletedTask;
        return process;
    }
}
