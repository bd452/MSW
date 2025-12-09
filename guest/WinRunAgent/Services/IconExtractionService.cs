namespace WinRun.Agent.Services;

public sealed class IconExtractionService
{
    private readonly IAgentLogger _logger;

    public IconExtractionService(IAgentLogger logger)
    {
        _logger = logger;
    }

    // TODO: Implement real icon extraction - see TODO.md "Extract & cache high-res icons for host launchers"
    public Task<byte[]> ExtractIconAsync(string executablePath, CancellationToken token)
    {
        _ = token; // Will be used for cancellation once extraction is implemented
        _logger.Info($"Extracting icon for {executablePath} (stub - not yet implemented)");
        return Task.FromResult(Array.Empty<byte>());
    }
}
