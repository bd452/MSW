using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class LoggingTests : IDisposable
{
    private readonly string _testLogDir;

    public LoggingTests()
    {
        _testLogDir = Path.Combine(Path.GetTempPath(), $"LoggingTest_{Guid.NewGuid():N}");
        _ = Directory.CreateDirectory(_testLogDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_testLogDir))
        {
            try
            {
                Directory.Delete(_testLogDir, recursive: true);
            }
            catch
            {
                // Ignore cleanup failures
            }
        }
    }

    // MARK: - LogLevel Tests

    [Fact]
    public void LogLevel_HasCorrectOrdering()
    {
        Assert.True(LogLevel.Debug < LogLevel.Info);
        Assert.True(LogLevel.Info < LogLevel.Warn);
        Assert.True(LogLevel.Warn < LogLevel.Error);
    }

    [Fact]
    public void LogLevel_Name_ReturnsExpectedValues()
    {
        Assert.Equal("DEBUG", LogLevel.Debug.Name());
        Assert.Equal("INFO", LogLevel.Info.Name());
        Assert.Equal("WARN", LogLevel.Warn.Name());
        Assert.Equal("ERROR", LogLevel.Error.Name());
    }

    // MARK: - LogMetadata Tests

    [Fact]
    public void LogMetadata_Empty_FormatsAsEmptyString()
    {
        var metadata = new LogMetadata();
        Assert.Equal(string.Empty, metadata.Format());
    }

    [Fact]
    public void LogMetadata_SingleEntry_FormatsCorrectly()
    {
        var metadata = new LogMetadata { ["key"] = "value" };
        Assert.Equal("key=value", metadata.Format());
    }

    [Fact]
    public void LogMetadata_MultipleEntries_FormatsCorrectly()
    {
        var metadata = new LogMetadata
        {
            ["first"] = "one",
            ["second"] = 2,
        };

        var formatted = metadata.Format();
        Assert.Contains("first=one", formatted);
        Assert.Contains("second=2", formatted);
    }

    [Fact]
    public void LogMetadata_NullValue_FormatsAsNull()
    {
        var metadata = new LogMetadata { ["key"] = null };
        Assert.Equal("key=null", metadata.Format());
    }

    [Fact]
    public void LogMetadata_IsCaseInsensitive()
    {
        var metadata = new LogMetadata { ["Key"] = "value" };

        Assert.Equal("value", metadata["key"]);
        Assert.Equal("value", metadata["KEY"]);
    }

    // MARK: - ConsoleLogger Tests

    [Fact]
    public void ConsoleLogger_RespectsMinimumLevel()
    {
        var logger = new ConsoleLogger { MinimumLevel = LogLevel.Warn };

        // This should not throw - we can't easily capture console output in tests
        // but we can verify it doesn't crash
        logger.Debug("debug message");
        logger.Info("info message");
        logger.Warn("warn message");
        logger.Error("error message");
    }

    [Fact]
    public void ConsoleLogger_DefaultMinimumLevelIsDebug()
    {
        var logger = new ConsoleLogger();
        Assert.Equal(LogLevel.Debug, logger.MinimumLevel);
    }

    // MARK: - FileLogger Tests

    [Fact]
    public void FileLogger_CreatesLogFile()
    {
        var logPath = Path.Combine(_testLogDir, "test.log");

        using (var logger = new FileLogger(logPath))
        {
            logger.Info("Test message");
        }

        Assert.True(File.Exists(logPath));
    }

    [Fact]
    public void FileLogger_WritesFormattedMessages()
    {
        var logPath = Path.Combine(_testLogDir, "test.log");

        using (var logger = new FileLogger(logPath))
        {
            logger.Info("Test message");
        }

        var contents = File.ReadAllText(logPath);
        Assert.Contains("[INFO]", contents);
        Assert.Contains("Test message", contents);
    }

    [Fact]
    public void FileLogger_WritesMetadata()
    {
        var logPath = Path.Combine(_testLogDir, "test.log");

        using (var logger = new FileLogger(logPath))
        {
            logger.Info("Test", new LogMetadata { ["key"] = "value" });
        }

        var contents = File.ReadAllText(logPath);
        Assert.Contains("key=value", contents);
    }

    [Fact]
    public void FileLogger_RespectsMinimumLevel()
    {
        var logPath = Path.Combine(_testLogDir, "test.log");

        using (var logger = new FileLogger(logPath) { MinimumLevel = LogLevel.Warn })
        {
            logger.Debug("debug");
            logger.Info("info");
            logger.Warn("warn");
            logger.Error("error");
        }

        var contents = File.ReadAllText(logPath);
        Assert.DoesNotContain("debug", contents);
        Assert.DoesNotContain("[INFO]", contents);
        Assert.Contains("warn", contents);
        Assert.Contains("error", contents);
    }

    [Fact]
    public void FileLogger_CreatesDirectoryIfNotExists()
    {
        var nestedDir = Path.Combine(_testLogDir, "nested", "dir");
        var logPath = Path.Combine(nestedDir, "test.log");

        using (var logger = new FileLogger(logPath))
        {
            logger.Info("Test");
        }

        Assert.True(Directory.Exists(nestedDir));
        Assert.True(File.Exists(logPath));
    }

    [Fact]
    public void FileLogger_DisposeIsIdempotent()
    {
        var logPath = Path.Combine(_testLogDir, "test.log");
        var logger = new FileLogger(logPath);

        logger.Dispose();
        logger.Dispose(); // Should not throw
    }

    // MARK: - CompositeLogger Tests

    [Fact]
    public void CompositeLogger_DispatchesToAllLoggers()
    {
        var testLogger1 = new TestLogger();
        var testLogger2 = new TestLogger();

        var composite = new CompositeLogger(testLogger1, testLogger2);
        composite.Info("Test message");

        _ = Assert.Single(testLogger1.InfoMessages);
        _ = Assert.Single(testLogger2.InfoMessages);
        Assert.Equal("Test message", testLogger1.InfoMessages[0]);
        Assert.Equal("Test message", testLogger2.InfoMessages[0]);
    }

    [Fact]
    public void CompositeLogger_RespectsMinimumLevel()
    {
        var testLogger = new TestLogger();
        var composite = new CompositeLogger(testLogger) { MinimumLevel = LogLevel.Error };

        composite.Debug("debug");
        composite.Info("info");
        composite.Warn("warn");
        composite.Error("error");

        Assert.Empty(testLogger.DebugMessages);
        Assert.Empty(testLogger.InfoMessages);
        Assert.Empty(testLogger.WarnMessages);
        _ = Assert.Single(testLogger.ErrorMessages);
    }

    [Fact]
    public void CompositeLogger_PropagatesMinimumLevelToChildren()
    {
        var testLogger = new TestLogger();

        _ = new CompositeLogger(testLogger)
        {
            MinimumLevel = LogLevel.Warn
        };

        Assert.Equal(LogLevel.Warn, testLogger.MinimumLevel);
    }

    // MARK: - EtwLogger Tests

    [Fact]
    public void EtwLogger_DoesNotThrow()
    {
        var logger = new EtwLogger();

        // ETW won't have listeners in tests, but shouldn't throw
        logger.Debug("debug");
        logger.Info("info");
        logger.Warn("warn");
        logger.Error("error");
    }

    [Fact]
    public void EtwLogger_DefaultMinimumLevelIsInfo()
    {
        var logger = new EtwLogger();
        Assert.Equal(LogLevel.Info, logger.MinimumLevel);
    }

    // MARK: - Extension Methods Tests

    [Fact]
    public void AgentLoggerExtensions_Debug_LogsAtDebugLevel()
    {
        var logger = new TestLogger();
        logger.Debug("test");

        _ = Assert.Single(logger.DebugMessages);
        Assert.Equal("test", logger.DebugMessages[0]);
    }

    [Fact]
    public void AgentLoggerExtensions_Info_LogsAtInfoLevel()
    {
        var logger = new TestLogger();
        logger.Info("test");

        _ = Assert.Single(logger.InfoMessages);
        Assert.Equal("test", logger.InfoMessages[0]);
    }

    [Fact]
    public void AgentLoggerExtensions_Warn_LogsAtWarnLevel()
    {
        var logger = new TestLogger();
        logger.Warn("test");

        _ = Assert.Single(logger.WarnMessages);
        Assert.Equal("test", logger.WarnMessages[0]);
    }

    [Fact]
    public void AgentLoggerExtensions_Error_LogsAtErrorLevel()
    {
        var logger = new TestLogger();
        logger.Error("test");

        _ = Assert.Single(logger.ErrorMessages);
        Assert.Equal("test", logger.ErrorMessages[0]);
    }

    [Fact]
    public void AgentLoggerExtensions_ErrorWithException_IncludesExceptionInfo()
    {
        var logger = new TestLogger();
        var exception = new InvalidOperationException("Test error");

        logger.Error(exception, "Something failed");

        _ = Assert.Single(logger.ErrorMessages);

        var entry = logger.Entries[0];
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.NotNull(entry.Metadata);
        Assert.Equal("InvalidOperationException", entry.Metadata["exception_type"]);
        Assert.Equal("Test error", entry.Metadata["exception_message"]);
    }

    // MARK: - LoggerFactory Tests

    [Fact]
    public void LoggerFactory_CreateAgentLogger_ReturnsValidLogger()
    {
        var logger = LoggerFactory.CreateAgentLogger(
            enableFile: false,
            enableEtw: false,
            enableConsole: false,
            minimumLevel: LogLevel.Info);

        // Should return a fallback console logger
        Assert.NotNull(logger);
    }

    [Fact]
    public void LoggerFactory_CreateDevelopmentLogger_EnablesConsole()
    {
        var logger = LoggerFactory.CreateDevelopmentLogger();
        Assert.NotNull(logger);
    }

    [Fact]
    public void LoggerFactory_DefaultLogDirectory_IsUnderProgramData()
    {
        var dir = LoggerFactory.DefaultLogDirectory;
        Assert.Contains("WinRun", dir);
        Assert.Contains("Logs", dir);
    }

    // MARK: - TestLogger Tests

    [Fact]
    public void TestLogger_CapturesAllLevels()
    {
        var logger = new TestLogger();

        logger.Debug("debug");
        logger.Info("info");
        logger.Warn("warn");
        logger.Error("error");

        Assert.Equal(4, logger.Entries.Count);
        _ = Assert.Single(logger.DebugMessages);
        _ = Assert.Single(logger.InfoMessages);
        _ = Assert.Single(logger.WarnMessages);
        _ = Assert.Single(logger.ErrorMessages);
    }

    [Fact]
    public void TestLogger_MessagesProperty_ReturnsAllMessages()
    {
        var logger = new TestLogger();

        logger.Debug("debug");
        logger.Info("info");

        Assert.Equal(2, logger.Messages.Count);
        Assert.Contains("debug", logger.Messages);
        Assert.Contains("info", logger.Messages);
    }

    [Fact]
    public void TestLogger_Clear_RemovesAllEntries()
    {
        var logger = new TestLogger();

        logger.Info("test");
        _ = Assert.Single(logger.Entries);

        logger.Clear();
        Assert.Empty(logger.Entries);
    }

    [Fact]
    public void TestLogger_CapturesMetadata()
    {
        var logger = new TestLogger();

        logger.Info("test", new LogMetadata { ["key"] = "value" });

        _ = Assert.Single(logger.Entries);
        Assert.NotNull(logger.Entries[0].Metadata);
        Assert.Equal("value", logger.Entries[0].Metadata!["key"]);
    }

    // MARK: - NullLogger Tests

    [Fact]
    public void NullLogger_DoesNotThrow()
    {
        var logger = NullLogger.Instance;

        logger.Debug("debug");
        logger.Info("info");
        logger.Warn("warn");
        logger.Error("error");

        // Just verifying no exceptions
    }

    [Fact]
    public void NullLogger_IsSingleton()
    {
        var instance1 = NullLogger.Instance;
        var instance2 = NullLogger.Instance;

        Assert.Same(instance1, instance2);
    }
}
