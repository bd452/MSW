using K4os.Compression.LZ4;

namespace WinRun.Agent.Services;

/// <summary>
/// Configuration for frame compression.
/// </summary>
public sealed record FrameCompressionConfig
{
    /// <summary>Whether compression is enabled.</summary>
    public bool Enabled { get; init; } = true;

    /// <summary>
    /// LZ4 compression level. Higher = better compression but slower.
    /// Fast (0-2): Best for real-time streaming
    /// Medium (3-6): Balanced
    /// High (7-12): Best compression for storage
    /// </summary>
    public LZ4Level CompressionLevel { get; init; } = LZ4Level.L00_FAST;

    /// <summary>
    /// Minimum frame size to compress (bytes). Smaller frames may not benefit from compression.
    /// </summary>
    public int MinSizeToCompress { get; init; } = 1024;

    /// <summary>
    /// Maximum compression ratio above which the uncompressed frame is preferred.
    /// If compressed size / original size > this value, skip compression.
    /// </summary>
    public float MaxCompressionRatio { get; init; } = 0.95f;
}

/// <summary>
/// Provides LZ4 compression/decompression for frame data.
/// Optimized for real-time streaming with minimal latency.
/// </summary>
public sealed class FrameCompressor
{
    private readonly IAgentLogger _logger;
    private readonly FrameCompressionConfig _config;

    // Statistics
    private long _totalFrames;
    private long _compressedFrames;
    private long _uncompressedBytes;
    private long _compressedBytes;

    public FrameCompressor(IAgentLogger logger, FrameCompressionConfig? config = null)
    {
        _logger = logger;
        _config = config ?? new FrameCompressionConfig();
    }

    /// <summary>
    /// Gets the compression configuration.
    /// </summary>
    public FrameCompressionConfig Config => _config;

    /// <summary>
    /// Gets compression statistics.
    /// </summary>
    public CompressionStats Stats => new()
    {
        TotalFrames = Interlocked.Read(ref _totalFrames),
        CompressedFrames = Interlocked.Read(ref _compressedFrames),
        UncompressedBytes = Interlocked.Read(ref _uncompressedBytes),
        CompressedBytes = Interlocked.Read(ref _compressedBytes)
    };

    /// <summary>
    /// Compresses frame data using LZ4.
    /// </summary>
    /// <param name="data">Raw frame pixel data.</param>
    /// <returns>Compression result with compressed data (or original if compression not beneficial).</returns>
    public CompressionResult Compress(ReadOnlySpan<byte> data)
    {
        Interlocked.Increment(ref _totalFrames);
        Interlocked.Add(ref _uncompressedBytes, data.Length);

        // Skip compression for small frames or if disabled
        if (!_config.Enabled || data.Length < _config.MinSizeToCompress)
        {
            return new CompressionResult
            {
                Data = data.ToArray(),
                IsCompressed = false,
                OriginalSize = data.Length,
                CompressedSize = data.Length
            };
        }

        // Allocate buffer for compressed data (max possible size)
        var maxCompressedSize = LZ4Codec.MaximumOutputSize(data.Length);
        var compressedBuffer = new byte[maxCompressedSize];

        // Compress
        var compressedSize = LZ4Codec.Encode(
            data,
            compressedBuffer.AsSpan(),
            _config.CompressionLevel);

        // Check if compression is beneficial
        var ratio = (float)compressedSize / data.Length;
        if (ratio > _config.MaxCompressionRatio)
        {
            // Compression didn't help enough, return original
            return new CompressionResult
            {
                Data = data.ToArray(),
                IsCompressed = false,
                OriginalSize = data.Length,
                CompressedSize = data.Length
            };
        }

        // Return compressed data (trimmed to actual size)
        var result = new byte[compressedSize];
        Array.Copy(compressedBuffer, result, compressedSize);

        Interlocked.Increment(ref _compressedFrames);
        Interlocked.Add(ref _compressedBytes, compressedSize);

        _logger.Debug($"Frame compressed: {data.Length} -> {compressedSize} ({ratio:P1})");

        return new CompressionResult
        {
            Data = result,
            IsCompressed = true,
            OriginalSize = data.Length,
            CompressedSize = compressedSize
        };
    }

    /// <summary>
    /// Decompresses LZ4 frame data.
    /// </summary>
    /// <param name="compressedData">Compressed frame data.</param>
    /// <param name="originalSize">Original uncompressed size.</param>
    /// <returns>Decompressed frame data.</returns>
    public byte[] Decompress(ReadOnlySpan<byte> compressedData, int originalSize)
    {
        var decompressedBuffer = new byte[originalSize];
        var decompressedSize = LZ4Codec.Decode(compressedData, decompressedBuffer);

        if (decompressedSize != originalSize)
        {
            _logger.Warn($"Decompression size mismatch: expected {originalSize}, got {decompressedSize}");
        }

        return decompressedBuffer;
    }
}

/// <summary>
/// Result of frame compression.
/// </summary>
public sealed record CompressionResult
{
    /// <summary>The resulting data (compressed or original if compression was skipped).</summary>
    public required byte[] Data { get; init; }

    /// <summary>Whether the data is LZ4 compressed.</summary>
    public required bool IsCompressed { get; init; }

    /// <summary>Original uncompressed size in bytes.</summary>
    public required int OriginalSize { get; init; }

    /// <summary>Compressed size in bytes (same as OriginalSize if not compressed).</summary>
    public required int CompressedSize { get; init; }

    /// <summary>Compression ratio (compressed / original).</summary>
    public float CompressionRatio => OriginalSize > 0 ? (float)CompressedSize / OriginalSize : 1.0f;

    /// <summary>Bytes saved by compression.</summary>
    public int BytesSaved => OriginalSize - CompressedSize;
}

/// <summary>
/// Statistics for frame compression.
/// </summary>
public sealed record CompressionStats
{
    public required long TotalFrames { get; init; }
    public required long CompressedFrames { get; init; }
    public required long UncompressedBytes { get; init; }
    public required long CompressedBytes { get; init; }

    public float AverageCompressionRatio =>
        UncompressedBytes > 0 ? (float)CompressedBytes / UncompressedBytes : 1.0f;

    public long BytesSaved => UncompressedBytes - CompressedBytes;

    public override string ToString() =>
        $"Total={TotalFrames}, Compressed={CompressedFrames}, " +
        $"Ratio={AverageCompressionRatio:P1}, Saved={BytesSaved / 1024}KB";
}
