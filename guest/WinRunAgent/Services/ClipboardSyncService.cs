using System.Runtime.InteropServices;
using System.Text;

namespace WinRun.Agent.Services;

/// <summary>
/// Handles clipboard synchronization between host and guest.
/// </summary>
public sealed partial class ClipboardSyncService : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly Func<GuestMessage, Task>? _sendMessage;
    private ulong _lastSequenceNumber;
    private bool _disposed;

    /// <summary>
    /// Event raised when the guest clipboard changes.
    /// </summary>
    public event EventHandler<GuestClipboardMessage>? ClipboardChanged;

    public ClipboardSyncService(IAgentLogger logger, Func<GuestMessage, Task>? sendMessage = null)
    {
        _logger = logger;
        _sendMessage = sendMessage;
    }

    /// <summary>
    /// Sets the Windows clipboard from host clipboard data.
    /// </summary>
    public bool SetClipboard(HostClipboardMessage message)
    {
        if (message.SequenceNumber <= _lastSequenceNumber)
        {
            _logger.Debug($"Ignoring stale clipboard data (seq {message.SequenceNumber} <= {_lastSequenceNumber})");
            return true; // Ignore stale data
        }

        _lastSequenceNumber = message.SequenceNumber;

        try
        {
            if (!OpenClipboard(IntPtr.Zero))
            {
                _logger.Warn("Failed to open clipboard");
                return false;
            }

            try
            {
                if (!EmptyClipboard())
                {
                    _logger.Warn("Failed to empty clipboard");
                    return false;
                }

                var (format, data) = ConvertToWindowsFormat(message.Format, message.Data);
                if (data == null)
                {
                    _logger.Warn($"Failed to convert clipboard format {message.Format}");
                    return false;
                }

                var hGlobal = Marshal.AllocHGlobal(data.Length);
                try
                {
                    Marshal.Copy(data, 0, hGlobal, data.Length);

                    if (SetClipboardData(format, hGlobal) == IntPtr.Zero)
                    {
                        _logger.Warn("SetClipboardData failed");
                        Marshal.FreeHGlobal(hGlobal);
                        return false;
                    }

                    // hGlobal is now owned by the clipboard, don't free it
                }
                catch
                {
                    Marshal.FreeHGlobal(hGlobal);
                    throw;
                }

                _logger.Debug($"Clipboard set: {message.Format}, {message.Data.Length} bytes");
                return true;
            }
            finally
            {
                _ = CloseClipboard();
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to set clipboard: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Gets the current Windows clipboard content and sends it to the host.
    /// </summary>
    public async Task<GuestClipboardMessage?> GetClipboardAsync()
    {
        try
        {
            if (!OpenClipboard(IntPtr.Zero))
            {
                return null;
            }

            try
            {
                // Try formats in order of preference
                var formats = new[] { CF_UNICODETEXT, CF_TEXT, CF_DIB, CF_HDROP };

                foreach (var format in formats)
                {
                    if (!IsClipboardFormatAvailable(format))
                    {
                        continue;
                    }

                    var hData = GetClipboardData(format);
                    if (hData == IntPtr.Zero)
                    {
                        continue;
                    }

                    var data = ExtractClipboardData(format, hData);
                    if (data == null)
                    {
                        continue;
                    }

                    var (clipFormat, clipData) = data.Value;
                    var message = new GuestClipboardMessage
                    {
                        Format = clipFormat,
                        Data = clipData,
                        SequenceNumber = ++_lastSequenceNumber
                    };

                    ClipboardChanged?.Invoke(this, message);

                    if (_sendMessage != null)
                    {
                        await _sendMessage(message);
                    }

                    return message;
                }

                return null;
            }
            finally
            {
                _ = CloseClipboard();
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to get clipboard: {ex.Message}");
            return null;
        }
    }

    private static (uint Format, byte[]? Data) ConvertToWindowsFormat(ClipboardFormat format, byte[] data)
    {
        switch (format)
        {
            case ClipboardFormat.PlainText:
                // Convert UTF-8 to UTF-16LE with null terminator
                var text = Encoding.UTF8.GetString(data);
                var utf16Bytes = Encoding.Unicode.GetBytes(text + "\0");
                return (CF_UNICODETEXT, utf16Bytes);

            case ClipboardFormat.Rtf:
                // RTF is ASCII/ANSI
                return (RegisterClipboardFormat("Rich Text Format"), data);

            case ClipboardFormat.Html:
                // HTML clipboard format has specific header requirements
                return (RegisterClipboardFormat("HTML Format"), data);

            case ClipboardFormat.Png:
                // PNG can be placed as DIB after conversion (not implemented)
                // For now, just return null to indicate unsupported
                return (0, null);

            case ClipboardFormat.FileUrl:
                // File URLs need to be converted to HDROP format
                // This is complex and not implemented here
                return (0, null);

            case ClipboardFormat.Tiff:
                // TIFF not implemented
                return (0, null);

            default:
                return (0, null);
        }
    }

    private static (ClipboardFormat, byte[])? ExtractClipboardData(uint format, nint hData)
    {
        var ptr = GlobalLock(hData);
        if (ptr == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var size = (int)GlobalSize(hData);

            switch (format)
            {
                case CF_UNICODETEXT:
                    var text = Marshal.PtrToStringUni(ptr) ?? "";
                    var utf8Bytes = Encoding.UTF8.GetBytes(text);
                    return (ClipboardFormat.PlainText, utf8Bytes);

                case CF_TEXT:
                    var ansiText = Marshal.PtrToStringAnsi(ptr) ?? "";
                    return (ClipboardFormat.PlainText, Encoding.UTF8.GetBytes(ansiText));

                case CF_DIB:
                    var bitmapData = new byte[size];
                    Marshal.Copy(ptr, bitmapData, 0, size);
                    // Would need to convert to PNG here
                    return (ClipboardFormat.Png, bitmapData);

                default:
                    var rawData = new byte[size];
                    Marshal.Copy(ptr, rawData, 0, size);
                    return (ClipboardFormat.PlainText, rawData);
            }
        }
        finally
        {
            _ = GlobalUnlock(hData);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
    }

    // Clipboard formats
    private const uint CF_TEXT = 1;
    private const uint CF_UNICODETEXT = 13;
    private const uint CF_DIB = 8;
    private const uint CF_HDROP = 15;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenClipboard(nint hWndNewOwner);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseClipboard();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool EmptyClipboard();

    [LibraryImport("user32.dll")]
    private static partial nint SetClipboardData(uint uFormat, nint hMem);

    [LibraryImport("user32.dll")]
    private static partial nint GetClipboardData(uint uFormat);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterClipboardFormat(string lpszFormat);

    [LibraryImport("kernel32.dll")]
    private static partial nint GlobalLock(nint hMem);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalUnlock(nint hMem);

    [LibraryImport("kernel32.dll")]
    private static partial nuint GlobalSize(nint hMem);
}

