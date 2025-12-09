namespace WinRun.Agent.Services;

public interface IAgentLogger
{
    void Debug(string message);
    void Info(string message);
    void Warn(string message);
    void Error(string message);
}

public sealed class ConsoleLogger : IAgentLogger
{
    private static readonly object Gate = new();

    public void Debug(string message) => Write("DEBUG", message);
    public void Info(string message) => Write("INFO", message);
    public void Warn(string message) => Write("WARN", message);
    public void Error(string message) => Write("ERROR", message);

    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            Console.WriteLine($"[{DateTime.UtcNow:o}] [{level}] {message}");
        }
    }
}
