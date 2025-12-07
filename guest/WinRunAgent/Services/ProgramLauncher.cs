using System.Diagnostics;

namespace WinRun.Agent.Services;

public sealed class ProgramLauncher
{
    private readonly IAgentLogger _logger;

    public ProgramLauncher(IAgentLogger logger)
    {
        _logger = logger;
    }

    public async Task<Process?> LaunchAsync(string path, string[] arguments, CancellationToken token)
    {
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
        process.Start();
        await Task.CompletedTask;
        return process;
    }
}
