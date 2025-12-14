using System.Collections.Concurrent;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

/// <summary>
/// Extracts high-resolution icons from Windows executables and caches them for reuse.
/// Uses Shell32 and GDI+ APIs to extract icons in various sizes and convert to PNG.
/// </summary>
public sealed class IconExtractionService : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly ConcurrentDictionary<IconCacheKey, CachedIcon> _cache = new();
    private readonly string _cacheDirectory;
    private readonly TimeSpan _cacheExpiry;
    private bool _disposed;

    /// <summary>
    /// Standard icon sizes to attempt extraction, from largest to smallest.
    /// Windows Vista+ support 256x256 icons; we prefer larger sizes for Retina displays.
    /// </summary>
    private static readonly int[] PreferredSizes = [256, 128, 64, 48, 32, 16];

    public IconExtractionService(IAgentLogger logger)
        : this(logger, GetDefaultCacheDirectory(), TimeSpan.FromHours(24))
    {
    }

    public IconExtractionService(IAgentLogger logger, string cacheDirectory, TimeSpan cacheExpiry)
    {
        _logger = logger;
        _cacheDirectory = cacheDirectory;
        _cacheExpiry = cacheExpiry;

        // Ensure cache directory exists
        if (!Directory.Exists(_cacheDirectory))
        {
            _ = Directory.CreateDirectory(_cacheDirectory);
            _logger.Debug($"Created icon cache directory: {_cacheDirectory}");
        }
    }

    /// <summary>
    /// Extracts an icon from the specified executable path and returns it as PNG data.
    /// </summary>
    /// <param name="executablePath">Path to the executable, shortcut, or file with an icon.</param>
    /// <param name="preferredSize">Preferred icon size in pixels (will get closest available).</param>
    /// <param name="token">Cancellation token.</param>
    /// <returns>PNG-encoded icon data, or empty array if extraction fails.</returns>
    public async Task<IconExtractionResult> ExtractIconAsync(
        string executablePath,
        int preferredSize = 256,
        CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            return IconExtractionResult.Failed("Empty path");
        }

        // Normalize path for cache key
        var normalizedPath = Path.GetFullPath(executablePath);
        var cacheKey = new IconCacheKey(normalizedPath, preferredSize);

        // Check memory cache first
        if (_cache.TryGetValue(cacheKey, out var cached) && !cached.IsExpired(_cacheExpiry))
        {
            _logger.Debug($"Icon cache hit (memory): {executablePath}");
            return cached.Result;
        }

        // Check disk cache
        var diskCachePath = GetDiskCachePath(cacheKey);
        if (File.Exists(diskCachePath))
        {
            var fileInfo = new FileInfo(diskCachePath);
            if (DateTime.UtcNow - fileInfo.LastWriteTimeUtc < _cacheExpiry)
            {
                try
                {
                    var diskData = await File.ReadAllBytesAsync(diskCachePath, token);
                    var diskResult = IconExtractionResult.Success(diskData, preferredSize, preferredSize);
                    _cache[cacheKey] = new CachedIcon(diskResult);
                    _logger.Debug($"Icon cache hit (disk): {executablePath}");
                    return diskResult;
                }
                catch (Exception ex)
                {
                    _logger.Warn($"Failed to read disk cache: {ex.Message}");
                }
            }
        }

        // Extract icon
        var result = await Task.Run(() => ExtractIconCore(normalizedPath, preferredSize), token);

        // Cache result (even failures, to avoid repeated extraction attempts)
        _cache[cacheKey] = new CachedIcon(result);

        // Persist to disk cache if successful
        if (result.IsSuccess)
        {
            try
            {
                await File.WriteAllBytesAsync(diskCachePath, result.PngData, token);
                _logger.Debug($"Icon cached to disk: {diskCachePath}");
            }
            catch (Exception ex)
            {
                _logger.Warn($"Failed to write disk cache: {ex.Message}");
            }
        }

        return result;
    }

    /// <summary>
    /// Extracts an icon synchronously (for backward compatibility).
    /// </summary>
    public Task<byte[]> ExtractIconAsync(string executablePath, CancellationToken token) => ExtractIconAsync(executablePath, 256, token)
            .ContinueWith(t => t.Result.PngData, token, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);

    /// <summary>
    /// Clears expired entries from the memory cache.
    /// </summary>
    public void PruneCache()
    {
        var expiredKeys = _cache
            .Where(kvp => kvp.Value.IsExpired(_cacheExpiry))
            .Select(kvp => kvp.Key)
            .ToList();

        foreach (var key in expiredKeys)
        {
            _ = _cache.TryRemove(key, out _);
        }

        _logger.Debug($"Pruned {expiredKeys.Count} expired icon cache entries");
    }

    /// <summary>
    /// Clears all cached icons (memory and disk).
    /// </summary>
    public void ClearCache()
    {
        _cache.Clear();

        if (Directory.Exists(_cacheDirectory))
        {
            foreach (var file in Directory.GetFiles(_cacheDirectory, "*.png"))
            {
                try
                {
                    File.Delete(file);
                }
                catch
                {
                    // Ignore deletion failures
                }
            }
        }

        _logger.Info("Icon cache cleared");
    }

    private IconExtractionResult ExtractIconCore(string path, int preferredSize)
    {
        _logger.Debug($"Extracting icon from: {path} (preferred size: {preferredSize})");

        // Resolve shortcuts (.lnk files) to their target
        var targetPath = path;
        if (path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
        {
            targetPath = ResolveShortcutTarget(path) ?? path;
            _logger.Debug($"Resolved shortcut to: {targetPath}");
        }

        // Verify file exists
        if (!File.Exists(targetPath) && !Directory.Exists(targetPath))
        {
            _logger.Warn($"Icon target not found: {targetPath}");
            return IconExtractionResult.Failed($"File not found: {targetPath}");
        }

        // Try extraction methods in order of preference
        var result = TryExtractJumboIcon(targetPath, preferredSize);
        if (result.IsSuccess)
        {
            return result;
        }

        result = TryExtractFromShell(targetPath, preferredSize);
        if (result.IsSuccess)
        {
            return result;
        }

        result = TryExtractFromResource(targetPath, preferredSize);
        if (result.IsSuccess)
        {
            return result;
        }

        _logger.Warn($"All icon extraction methods failed for: {path}");
        return IconExtractionResult.Failed("All extraction methods failed");
    }

    /// <summary>
    /// Extracts jumbo (256x256) icons using SHGetFileInfo with SHGFI_SYSICONINDEX
    /// and IImageList interface.
    /// </summary>
    private IconExtractionResult TryExtractJumboIcon(string path, int preferredSize)
    {
        nint hIcon = 0;
        try
        {
            // Get system image list index
            var shfi = new SHFILEINFO();
            var flags = SHGFI.SHGFI_SYSICONINDEX;

            var hr = SHGetFileInfo(path, 0, ref shfi, (uint)Marshal.SizeOf<SHFILEINFO>(), flags);
            if (hr == 0)
            {
                return IconExtractionResult.Failed("SHGetFileInfo failed");
            }

            // Get the jumbo image list (256x256)
            var imageListSize = preferredSize >= 256 ? SHIL.SHIL_JUMBO :
                                preferredSize >= 48 ? SHIL.SHIL_EXTRALARGE :
                                preferredSize >= 32 ? SHIL.SHIL_LARGE : SHIL.SHIL_SMALL;

            var iidImageList = new Guid("46EB5926-582E-4017-9FDF-E8998DAA0950");
            hr = SHGetImageList((int)imageListSize, ref iidImageList, out var imageListPtr);

            if (hr != 0 || imageListPtr == 0)
            {
                return IconExtractionResult.Failed("SHGetImageList failed");
            }

            // Get icon from image list
            var imageList = (IImageList)Marshal.GetObjectForIUnknown(imageListPtr);
            hr = imageList.GetIcon(shfi.iIcon, ILD.ILD_TRANSPARENT, out hIcon);
            _ = Marshal.Release(imageListPtr);

            if (hr != 0 || hIcon == 0)
            {
                return IconExtractionResult.Failed("GetIcon failed");
            }

            // Convert to PNG
            return ConvertIconToPng(hIcon, preferredSize);
        }
        catch (Exception ex)
        {
            _logger.Debug($"Jumbo icon extraction failed: {ex.Message}");
            return IconExtractionResult.Failed(ex.Message);
        }
        finally
        {
            if (hIcon != 0)
            {
                _ = DestroyIcon(hIcon);
            }
        }
    }

    /// <summary>
    /// Extracts icon using ExtractIconEx (standard shell icon extraction).
    /// </summary>
    private IconExtractionResult TryExtractFromShell(string path, int preferredSize)
    {
        var largeIcons = new nint[1];
        var smallIcons = new nint[1];

        try
        {
            var count = ExtractIconEx(path, 0, largeIcons, smallIcons, 1);
            if (count == 0)
            {
                return IconExtractionResult.Failed("ExtractIconEx found no icons");
            }

            // Prefer large icon
            var hIcon = largeIcons[0] != 0 ? largeIcons[0] : smallIcons[0];
            return hIcon == 0 ? IconExtractionResult.Failed("No valid icon handle") : ConvertIconToPng(hIcon, preferredSize);
        }
        catch (Exception ex)
        {
            _logger.Debug($"Shell icon extraction failed: {ex.Message}");
            return IconExtractionResult.Failed(ex.Message);
        }
        finally
        {
            if (largeIcons[0] != 0)
            {
                _ = DestroyIcon(largeIcons[0]);
            }

            if (smallIcons[0] != 0)
            {
                _ = DestroyIcon(smallIcons[0]);
            }
        }
    }

    /// <summary>
    /// Extracts icon directly from PE resources using LoadLibraryEx and LoadImage.
    /// </summary>
    private IconExtractionResult TryExtractFromResource(string path, int preferredSize)
    {
        nint hModule = 0;
        nint hIcon = 0;

        try
        {
            // Load the module without executing DllMain
            hModule = LoadLibraryEx(path, 0, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
            if (hModule == 0)
            {
                return IconExtractionResult.Failed("LoadLibraryEx failed");
            }

            // Try to load icon at preferred size
            foreach (var size in PreferredSizes.Where(s => s <= preferredSize || s == PreferredSizes[^1]))
            {
                hIcon = LoadImage(hModule, MAKEINTRESOURCE(1), IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
                if (hIcon != 0)
                {
                    break;
                }
            }

            return hIcon == 0 ? IconExtractionResult.Failed("LoadImage failed for all sizes") : ConvertIconToPng(hIcon, preferredSize);
        }
        catch (Exception ex)
        {
            _logger.Debug($"Resource icon extraction failed: {ex.Message}");
            return IconExtractionResult.Failed(ex.Message);
        }
        finally
        {
            if (hIcon != 0)
            {
                _ = DestroyIcon(hIcon);
            }

            if (hModule != 0)
            {
                _ = FreeLibrary(hModule);
            }
        }
    }

    /// <summary>
    /// Converts an HICON to PNG-encoded bytes.
    /// </summary>
    private IconExtractionResult ConvertIconToPng(nint hIcon, int targetSize)
    {
        try
        {
            using var icon = Icon.FromHandle(hIcon);
            using var bitmap = icon.ToBitmap();

            // Get actual size
            var actualWidth = bitmap.Width;
            var actualHeight = bitmap.Height;

            // If icon is smaller than target and we want scaling, scale it up
            // Otherwise, keep original size to preserve quality
            Bitmap finalBitmap;
            if (actualWidth < targetSize && actualHeight < targetSize)
            {
                // Scale up using high-quality interpolation
                finalBitmap = new Bitmap(targetSize, targetSize, PixelFormat.Format32bppArgb);
                using var g = Graphics.FromImage(finalBitmap);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.HighQuality;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                g.DrawImage(bitmap, 0, 0, targetSize, targetSize);
            }
            else
            {
                finalBitmap = bitmap;
            }

            using var ms = new MemoryStream();
            finalBitmap.Save(ms, ImageFormat.Png);

            if (!ReferenceEquals(finalBitmap, bitmap))
            {
                finalBitmap.Dispose();
            }

            var pngData = ms.ToArray();
            _logger.Debug($"Extracted icon: {actualWidth}x{actualHeight} -> PNG {pngData.Length} bytes");

            return IconExtractionResult.Success(
                pngData,
                finalBitmap == bitmap ? actualWidth : targetSize,
                finalBitmap == bitmap ? actualHeight : targetSize);
        }
        catch (Exception ex)
        {
            _logger.Debug($"Icon to PNG conversion failed: {ex.Message}");
            return IconExtractionResult.Failed(ex.Message);
        }
    }

    /// <summary>
    /// Resolves a .lnk shortcut to its target path.
    /// </summary>
    private string? ResolveShortcutTarget(string lnkPath)
    {
        try
        {
            var shellLink = (IShellLink)new ShellLink();
            var persistFile = (IPersistFile)shellLink;

            persistFile.Load(lnkPath, 0);
            shellLink.Resolve(0, SLR.SLR_NO_UI);

            var targetPath = new char[260];
            shellLink.GetPath(targetPath, targetPath.Length, out _, SLGP.SLGP_RAWPATH);

            var result = new string(targetPath).TrimEnd('\0');
            return string.IsNullOrEmpty(result) ? null : result;
        }
        catch (Exception ex)
        {
            _logger.Debug($"Failed to resolve shortcut: {ex.Message}");
            return null;
        }
    }

    private static string GetDefaultCacheDirectory() => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "WinRun",
            "IconCache");

    private string GetDiskCachePath(IconCacheKey key)
    {
        // Create a hash-based filename to avoid path issues
        var hash = HashCode.Combine(key.Path.ToLowerInvariant(), key.Size);
        return Path.Combine(_cacheDirectory, $"{hash:X8}_{key.Size}.png");
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _cache.Clear();
        _disposed = true;
    }

    // ========================================================================
    // P/Invoke declarations
    // ========================================================================

    private const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
    private const uint LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x00000020;
    private const uint IMAGE_ICON = 1;
    private const uint LR_DEFAULTCOLOR = 0x00000000;

    private static nint MAKEINTRESOURCE(int id) => (ushort)id;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern nint SHGetFileInfo(
        string pszPath,
        uint dwFileAttributes,
        ref SHFILEINFO psfi,
        uint cbFileInfo,
        SHGFI uFlags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(
        string lpszFile,
        int nIconIndex,
        nint[] phiconLarge,
        nint[] phiconSmall,
        uint nIcons);

    [DllImport("shell32.dll")]
    private static extern int SHGetImageList(
        int iImageList,
        ref Guid riid,
        out nint ppv);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint hIcon);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint LoadLibraryEx(string lpFileName, nint hFile, uint dwFlags);

    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(nint hModule);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint LoadImage(
        nint hInst,
        nint name,
        uint type,
        int cx,
        int cy,
        uint fuLoad);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO
    {
        public nint hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }

    [Flags]
    private enum SHGFI : uint
    {
        SHGFI_ICON = 0x000000100,
        SHGFI_DISPLAYNAME = 0x000000200,
        SHGFI_TYPENAME = 0x000000400,
        SHGFI_ATTRIBUTES = 0x000000800,
        SHGFI_ICONLOCATION = 0x000001000,
        SHGFI_EXETYPE = 0x000002000,
        SHGFI_SYSICONINDEX = 0x000004000,
        SHGFI_LINKOVERLAY = 0x000008000,
        SHGFI_SELECTED = 0x000010000,
        SHGFI_LARGEICON = 0x000000000,
        SHGFI_SMALLICON = 0x000000001,
        SHGFI_OPENICON = 0x000000002,
        SHGFI_SHELLICONSIZE = 0x000000004,
        SHGFI_USEFILEATTRIBUTES = 0x000000010
    }

    private enum SHIL : int
    {
        SHIL_LARGE = 0,
        SHIL_SMALL = 1,
        SHIL_EXTRALARGE = 2,
        SHIL_SYSSMALL = 3,
        SHIL_JUMBO = 4
    }

    [Flags]
    private enum ILD : uint
    {
        ILD_NORMAL = 0x00000000,
        ILD_TRANSPARENT = 0x00000001,
        ILD_BLEND25 = 0x00000002,
        ILD_BLEND50 = 0x00000004
    }

    [ComImport]
    [Guid("46EB5926-582E-4017-9FDF-E8998DAA0950")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IImageList
    {
        [PreserveSig]
        int Add(nint hbmImage, nint hbmMask, out int pi);

        [PreserveSig]
        int ReplaceIcon(int i, nint hicon, out int pi);

        [PreserveSig]
        int SetOverlayImage(int iImage, int iOverlay);

        [PreserveSig]
        int Replace(int i, nint hbmImage, nint hbmMask);

        [PreserveSig]
        int AddMasked(nint hbmImage, int crMask, out int pi);

        [PreserveSig]
        int Draw(ref IMAGELISTDRAWPARAMS pimldp);

        [PreserveSig]
        int Remove(int i);

        [PreserveSig]
        int GetIcon(int i, ILD flags, out nint picon);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IMAGELISTDRAWPARAMS
    {
        public int cbSize;
        public nint himl;
        public int i;
        public nint hdcDst;
        public int x;
        public int y;
        public int cx;
        public int cy;
        public int xBitmap;
        public int yBitmap;
        public int rgbBk;
        public int rgbFg;
        public int fStyle;
        public int dwRop;
        public int fState;
        public int Frame;
        public int crEffect;
    }

    // Shell Link interfaces for resolving .lnk files
    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink
    {
    }

    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLink
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszFile, int cch, out WIN32_FIND_DATA pfd, SLGP fFlags);
        void GetIDList(out nint ppidl);
        void SetIDList(nint pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out ushort pwHotkey);
        void SetHotkey(ushort wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(nint hwnd, SLR fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [Guid("0000010B-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig]
        int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [Flags]
    private enum SLR : uint
    {
        SLR_NO_UI = 0x0001,
        SLR_NOUPDATE = 0x0008,
        SLR_NOSEARCH = 0x0010,
        SLR_NOTRACK = 0x0020,
        SLR_NOLINKINFO = 0x0040,
        SLR_INVOKE_MSI = 0x0080
    }

    private enum SLGP : uint
    {
        SLGP_SHORTPATH = 0x0001,
        SLGP_UNCPRIORITY = 0x0002,
        SLGP_RAWPATH = 0x0004
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }
}

/// <summary>
/// Cache key for icon lookup.
/// </summary>
internal readonly record struct IconCacheKey(string Path, int Size);

/// <summary>
/// Cached icon entry with timestamp for expiry.
/// </summary>
internal sealed class CachedIcon
{
    public IconExtractionResult Result { get; }
    public DateTime CachedAt { get; }

    public CachedIcon(IconExtractionResult result)
    {
        Result = result;
        CachedAt = DateTime.UtcNow;
    }

    public bool IsExpired(TimeSpan expiry) => DateTime.UtcNow - CachedAt > expiry;
}

/// <summary>
/// Result of an icon extraction operation.
/// </summary>
public sealed class IconExtractionResult
{
    public bool IsSuccess { get; }
    public byte[] PngData { get; }
    public int Width { get; }
    public int Height { get; }
    public string? ErrorMessage { get; }

    private IconExtractionResult(bool success, byte[] pngData, int width, int height, string? errorMessage)
    {
        IsSuccess = success;
        PngData = pngData;
        Width = width;
        Height = height;
        ErrorMessage = errorMessage;
    }

    public static IconExtractionResult Success(byte[] pngData, int width, int height) => new(true, pngData, width, height, null);

    public static IconExtractionResult Failed(string message) => new(false, [], 0, 0, message);
}
