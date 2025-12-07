namespace WinRun.Agent.Services;

public sealed class IconExtractionService
{
    private readonly IAgentLogger _logger;

    public IconExtractionService(IAgentLogger logger)
    {
        _logger = logger;
    }

    public Task<byte[]> ExtractIconAsync(string executablePath, CancellationToken token)
    {
        _logger.Info($"Extracting icon for {executablePath} (mock implementation)");
        return Task.FromResult(Array.Empty<byte>());
    }
}
