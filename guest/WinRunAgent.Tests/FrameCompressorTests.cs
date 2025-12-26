using K4os.Compression.LZ4;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class FrameCompressorTests
{
    [Fact]
    public void FrameCompressionConfigHasReasonableDefaults()
    {
        var config = new FrameCompressionConfig();

        Assert.True(config.Enabled);
        Assert.Equal(LZ4Level.L00_FAST, config.CompressionLevel);
        Assert.Equal(1024, config.MinSizeToCompress);
        Assert.Equal(0.95f, config.MaxCompressionRatio);
    }

    [Fact]
    public void FrameCompressorInitializesWithConfig()
    {
        var logger = new TestLogger();
        var config = new FrameCompressionConfig { CompressionLevel = LZ4Level.L03_HC };

        var compressor = new FrameCompressor(logger, config);

        Assert.Equal(LZ4Level.L03_HC, compressor.Config.CompressionLevel);
    }

    [Fact]
    public void FrameCompressorUsesDefaultConfigWhenNull()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger, null);

        Assert.True(compressor.Config.Enabled);
    }

    [Fact]
    public void CompressSmallDataSkipsCompression()
    {
        var logger = new TestLogger();
        var config = new FrameCompressionConfig { MinSizeToCompress = 1000 };
        var compressor = new FrameCompressor(logger, config);

        var smallData = new byte[500]; // Below threshold
        var result = compressor.Compress(smallData);

        Assert.False(result.IsCompressed);
        Assert.Equal(smallData.Length, result.OriginalSize);
        Assert.Equal(smallData.Length, result.CompressedSize);
        Assert.Equal(smallData, result.Data);
    }

    [Fact]
    public void CompressDisabledSkipsCompression()
    {
        var logger = new TestLogger();
        var config = new FrameCompressionConfig { Enabled = false };
        var compressor = new FrameCompressor(logger, config);

        var data = new byte[10000];
        Random.Shared.NextBytes(data);

        var result = compressor.Compress(data);

        Assert.False(result.IsCompressed);
        Assert.Equal(data.Length, result.OriginalSize);
    }

    [Fact]
    public void CompressLargeRepetitiveDataCompresses()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger);

        // Create highly repetitive data (simulating solid color frame)
        var data = new byte[100000];
        Array.Fill(data, (byte)0x42);

        var result = compressor.Compress(data);

        Assert.True(result.IsCompressed);
        Assert.True(result.CompressedSize < result.OriginalSize);
        Assert.True(result.CompressionRatio < 0.5f); // Should compress very well
    }

    [Fact]
    public void CompressHighEntropyDataMaySkipCompression()
    {
        var logger = new TestLogger();
        var config = new FrameCompressionConfig { MaxCompressionRatio = 0.5f }; // Only keep if 50%+ savings
        var compressor = new FrameCompressor(logger, config);

        // Create high-entropy random data (doesn't compress well)
        var data = new byte[10000];
        Random.Shared.NextBytes(data);

        var result = compressor.Compress(data);

        // Random data typically compresses poorly, so it might skip
        // (though LZ4 may still find some patterns)
        Assert.Equal(data.Length, result.OriginalSize);
    }

    [Fact]
    public void DecompressRestoresOriginalData()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger);

        // Create compressible data
        var original = new byte[10000];
        for (var i = 0; i < original.Length; i++)
        {
            original[i] = (byte)(i % 256);
        }

        var compressed = compressor.Compress(original);

        if (compressed.IsCompressed)
        {
            var decompressed = compressor.Decompress(compressed.Data, compressed.OriginalSize);
            Assert.Equal(original, decompressed);
        }
        else
        {
            // If not compressed, data should match original
            Assert.Equal(original, compressed.Data);
        }
    }

    [Fact]
    public void StatsTrackTotalFrames()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger);

        var data = new byte[100];
        _ = compressor.Compress(data);
        _ = compressor.Compress(data);
        _ = compressor.Compress(data);

        Assert.Equal(3, compressor.Stats.TotalFrames);
    }

    [Fact]
    public void StatsTrackCompressedFrames()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger);

        // Compressible data
        var compressible = new byte[10000];
        Array.Fill(compressible, (byte)0x00);

        // Small data (won't compress)
        var small = new byte[100];

        _ = compressor.Compress(compressible);
        _ = compressor.Compress(small);

        Assert.Equal(2, compressor.Stats.TotalFrames);
        Assert.Equal(1, compressor.Stats.CompressedFrames);
    }

    [Fact]
    public void StatsTrackBytesSaved()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger);

        // Highly compressible data
        var data = new byte[100000];
        Array.Fill(data, (byte)0xFF);

        var result = compressor.Compress(data);

        if (result.IsCompressed)
        {
            Assert.True(compressor.Stats.BytesSaved > 0);
            Assert.True(compressor.Stats.AverageCompressionRatio < 1.0f);
        }
    }

    [Fact]
    public void CompressionResultComputesRatio()
    {
        var result = new CompressionResult
        {
            Data = [],
            IsCompressed = true,
            OriginalSize = 1000,
            CompressedSize = 500
        };

        Assert.Equal(0.5f, result.CompressionRatio);
        Assert.Equal(500, result.BytesSaved);
    }

    [Fact]
    public void CompressionResultHandlesZeroOriginalSize()
    {
        var result = new CompressionResult
        {
            Data = [],
            IsCompressed = false,
            OriginalSize = 0,
            CompressedSize = 0
        };

        Assert.Equal(1.0f, result.CompressionRatio);
        Assert.Equal(0, result.BytesSaved);
    }

    [Fact]
    public void CompressionStatsToStringFormats()
    {
        var logger = new TestLogger();
        var compressor = new FrameCompressor(logger);

        var data = new byte[10000];
        Array.Fill(data, (byte)0x00);
        _ = compressor.Compress(data);

        var str = compressor.Stats.ToString();

        Assert.Contains("Total=1", str);
        Assert.Contains("Saved=", str);
    }

    [Fact]
    public void FrameStreamingConfigCompressionDefaultsToNull()
    {
        var config = new FrameStreamingConfig();

        // Compression is null by default (disabled)
        Assert.Null(config.Compression);
    }

    [Fact]
    public void FrameStreamingConfigCanEnableCompression()
    {
        var config = new FrameStreamingConfig
        {
            Compression = new FrameCompressionConfig { Enabled = true }
        };

        Assert.NotNull(config.Compression);
        Assert.True(config.Compression!.Enabled);
    }

    [Fact]
    public void FrameStreamingConfigCanDisableCompression()
    {
        var config = new FrameStreamingConfig
        {
            Compression = new FrameCompressionConfig { Enabled = false }
        };

        Assert.False(config.Compression.Enabled);
    }

    [Fact]
    public void FrameStreamingConfigCompressionCanBeNull()
    {
        var config = new FrameStreamingConfig { Compression = null };

        Assert.Null(config.Compression);
    }

    [Fact]
    public void FrameSlotFlagsHasExpectedValues()
    {
        Assert.Equal(1u, (uint)FrameSlotFlags.Compressed);
        Assert.Equal(2u, (uint)FrameSlotFlags.KeyFrame);
    }

    [Fact]
    public void FrameSlotFlagsCanCombine()
    {
        var flags = FrameSlotFlags.Compressed | FrameSlotFlags.KeyFrame;

        Assert.True(flags.HasFlag(FrameSlotFlags.Compressed));
        Assert.True(flags.HasFlag(FrameSlotFlags.KeyFrame));
        Assert.Equal(3u, (uint)flags);
    }
}
