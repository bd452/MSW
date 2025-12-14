using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

/// <summary>
/// Bridge for capturing desktop/window content using DXGI Desktop Duplication API.
/// Provides efficient screen capture for streaming window frames to the host.
/// </summary>
public sealed class DesktopDuplicationBridge : IDisposable
{
    private readonly IAgentLogger _logger;
    private nint _device;
    private nint _context;
    private nint _duplication;
    private nint _stagingTexture;
    private bool _disposed;

    public DesktopDuplicationBridge(IAgentLogger logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Gets whether desktop duplication is currently initialized and ready.
    /// </summary>
    public bool IsInitialized { get; private set; }

    /// <summary>
    /// Gets the width of the captured output in pixels.
    /// </summary>
    public int OutputWidth { get; private set; }

    /// <summary>
    /// Gets the height of the captured output in pixels.
    /// </summary>
    public int OutputHeight { get; private set; }

    /// <summary>
    /// Initializes DXGI Desktop Duplication for the primary display.
    /// </summary>
    /// <returns>True if initialization succeeded, false otherwise.</returns>
    public bool Initialize()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (IsInitialized)
        {
            return true;
        }

        try
        {
            _logger.Info("Initializing DXGI Desktop Duplication");

            // Create DXGI factory
            var factoryIid = DXGI.IID_IDXGIFactory1;
            var hr = DXGI.CreateDXGIFactory1(ref factoryIid, out var factory);
            if (hr < 0)
            {
                _logger.Error($"Failed to create DXGI factory: HRESULT 0x{hr:X8}");
                return false;
            }

            try
            {
                // Get primary adapter
                hr = DXGI.IDXGIFactory1_EnumAdapters1(factory, 0, out var adapter);
                if (hr < 0)
                {
                    _logger.Error($"Failed to enumerate adapters: HRESULT 0x{hr:X8}");
                    return false;
                }

                try
                {
                    // Create D3D11 device
                    hr = D3D11.D3D11CreateDevice(
                        adapter,
                        D3D11.D3D_DRIVER_TYPE_UNKNOWN,
                        IntPtr.Zero,
                        0, // No flags
                        IntPtr.Zero, 0, // Feature levels
                        D3D11.D3D11_SDK_VERSION,
                        out _device,
                        out _,
                        out _context);

                    if (hr < 0)
                    {
                        _logger.Error($"Failed to create D3D11 device: HRESULT 0x{hr:X8}");
                        return false;
                    }

                    // Get primary output
                    hr = DXGI.IDXGIAdapter1_EnumOutputs(adapter, 0, out var output);
                    if (hr < 0)
                    {
                        _logger.Error($"Failed to enumerate outputs: HRESULT 0x{hr:X8}");
                        return false;
                    }

                    try
                    {
                        // Query for IDXGIOutput1
                        var output1Iid = DXGI.IID_IDXGIOutput1;
                        hr = DXGI.QueryInterface(output, ref output1Iid, out var output1);
                        if (hr < 0)
                        {
                            _logger.Error($"Failed to get IDXGIOutput1: HRESULT 0x{hr:X8}");
                            return false;
                        }

                        try
                        {
                            // Get output description for dimensions
                            _ = DXGI.IDXGIOutput_GetDesc(output, out var outputDesc);
                            OutputWidth = outputDesc.DesktopCoordinates.Right - outputDesc.DesktopCoordinates.Left;
                            OutputHeight = outputDesc.DesktopCoordinates.Bottom - outputDesc.DesktopCoordinates.Top;

                            // Create desktop duplication
                            hr = DXGI.IDXGIOutput1_DuplicateOutput(output1, _device, out _duplication);
                            if (hr < 0)
                            {
                                _logger.Error($"Failed to create desktop duplication: HRESULT 0x{hr:X8}");
                                return false;
                            }

                            // Create staging texture for CPU access
                            var textureDesc = new D3D11.D3D11_TEXTURE2D_DESC
                            {
                                Width = (uint)OutputWidth,
                                Height = (uint)OutputHeight,
                                MipLevels = 1,
                                ArraySize = 1,
                                Format = DXGI.DXGI_FORMAT_B8G8R8A8_UNORM,
                                SampleDesc = new D3D11.DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
                                Usage = D3D11.D3D11_USAGE_STAGING,
                                BindFlags = 0,
                                CPUAccessFlags = D3D11.D3D11_CPU_ACCESS_READ,
                                MiscFlags = 0
                            };

                            hr = D3D11.ID3D11Device_CreateTexture2D(_device, ref textureDesc, IntPtr.Zero, out _stagingTexture);
                            if (hr < 0)
                            {
                                _logger.Error($"Failed to create staging texture: HRESULT 0x{hr:X8}");
                                return false;
                            }

                            IsInitialized = true;
                            _logger.Info($"Desktop Duplication initialized: {OutputWidth}x{OutputHeight}");
                            return true;
                        }
                        finally
                        {
                            if (!IsInitialized)
                            {
                                _ = Marshal.Release(output1);
                            }
                        }
                    }
                    finally
                    {
                        _ = Marshal.Release(output);
                    }
                }
                finally
                {
                    _ = Marshal.Release(adapter);
                }
            }
            finally
            {
                _ = Marshal.Release(factory);
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Exception during Desktop Duplication init: {ex.Message}");
            Cleanup();
            return false;
        }
    }

    /// <summary>
    /// Captures a single frame from the desktop.
    /// </summary>
    /// <param name="timeout">Timeout in milliseconds to wait for a new frame.</param>
    /// <returns>Frame data if captured, null if no new frame available or on error.</returns>
    public CapturedFrame? CaptureFrame(int timeout = 100)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!IsInitialized)
        {
            _logger.Warn("CaptureFrame called before initialization");
            return null;
        }

        var frameTexture = IntPtr.Zero;
        try
        {
            // Acquire next frame
            var hr = DXGI.IDXGIOutputDuplication_AcquireNextFrame(
                _duplication,
                (uint)timeout,
                out var frameInfo,
                out var resource);

            if (hr == DXGI.DXGI_ERROR_WAIT_TIMEOUT)
            {
                // No new frame available - this is normal
                return null;
            }

            if (hr < 0)
            {
                // Check for access lost - need to reinitialize
                if (hr == DXGI.DXGI_ERROR_ACCESS_LOST)
                {
                    _logger.Warn("Desktop duplication access lost, needs reinitialization");
                    IsInitialized = false;
                }
                return null;
            }

            try
            {
                // Query for ID3D11Texture2D
                var texture2dIid = D3D11.IID_ID3D11Texture2D;
                hr = DXGI.QueryInterface(resource, ref texture2dIid, out frameTexture);
                if (hr < 0)
                {
                    return null;
                }

                // Copy to staging texture
                D3D11.ID3D11DeviceContext_CopyResource(_context, _stagingTexture, frameTexture);

                // Map staging texture to access pixels
                hr = D3D11.ID3D11DeviceContext_Map(
                    _context,
                    _stagingTexture,
                    0,
                    D3D11.D3D11_MAP_READ,
                    0,
                    out var mappedResource);

                if (hr < 0)
                {
                    return null;
                }

                try
                {
                    // Copy pixel data
                    var dataSize = (int)(OutputHeight * mappedResource.RowPitch);
                    var data = new byte[dataSize];
                    Marshal.Copy(mappedResource.pData, data, 0, dataSize);

                    return new CapturedFrame(
                        Width: OutputWidth,
                        Height: OutputHeight,
                        Stride: (int)mappedResource.RowPitch,
                        Format: PixelFormatType.Bgra32,
                        Data: data,
                        Timestamp: frameInfo.LastPresentTime);
                }
                finally
                {
                    D3D11.ID3D11DeviceContext_Unmap(_context, _stagingTexture, 0);
                }
            }
            finally
            {
                _ = Marshal.Release(resource);
                if (frameTexture != IntPtr.Zero)
                {
                    _ = Marshal.Release(frameTexture);
                }

                _ = DXGI.IDXGIOutputDuplication_ReleaseFrame(_duplication);
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Error capturing frame: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Extracts a region from a captured frame corresponding to a specific window.
    /// </summary>
    /// <param name="frame">The full desktop frame.</param>
    /// <param name="windowBounds">The window bounds to extract.</param>
    /// <returns>A new frame containing only the window region, or null if invalid.</returns>
    public static CapturedFrame? ExtractWindowRegion(CapturedFrame frame, Rect windowBounds)
    {
        // Clamp bounds to frame dimensions
        var x = Math.Max(0, windowBounds.X);
        var y = Math.Max(0, windowBounds.Y);
        var right = Math.Min(frame.Width, windowBounds.X + windowBounds.Width);
        var bottom = Math.Min(frame.Height, windowBounds.Y + windowBounds.Height);

        var width = right - x;
        var height = bottom - y;

        if (width <= 0 || height <= 0)
        {
            return null;
        }

        var bytesPerPixel = 4; // BGRA32
        var newStride = width * bytesPerPixel;
        var newData = new byte[height * newStride];

        // Copy each row from the source frame
        for (var row = 0; row < height; row++)
        {
            var srcOffset = ((y + row) * frame.Stride) + (x * bytesPerPixel);
            var dstOffset = row * newStride;

            Array.Copy(frame.Data, srcOffset, newData, dstOffset, newStride);
        }

        return new CapturedFrame(
            Width: width,
            Height: height,
            Stride: newStride,
            Format: frame.Format,
            Data: newData,
            Timestamp: frame.Timestamp);
    }

    private void Cleanup()
    {
        if (_stagingTexture != IntPtr.Zero)
        {
            _ = Marshal.Release(_stagingTexture);
            _stagingTexture = IntPtr.Zero;
        }

        if (_duplication != IntPtr.Zero)
        {
            _ = Marshal.Release(_duplication);
            _duplication = IntPtr.Zero;
        }

        if (_context != IntPtr.Zero)
        {
            _ = Marshal.Release(_context);
            _context = IntPtr.Zero;
        }

        if (_device != IntPtr.Zero)
        {
            _ = Marshal.Release(_device);
            _device = IntPtr.Zero;
        }

        IsInitialized = false;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Cleanup();
    }
}

/// <summary>
/// Represents a captured desktop frame.
/// </summary>
public sealed record CapturedFrame(
    int Width,
    int Height,
    int Stride,
    PixelFormatType Format,
    byte[] Data,
    long Timestamp);

// Note: PixelFormatType is defined in Messages.cs to avoid duplication

#region DXGI/D3D11 P/Invoke

internal static class DXGI
{
    public static readonly Guid IID_IDXGIFactory1 = new("770aae78-f26f-4dba-a829-253c83d1b387");
    public static readonly Guid IID_IDXGIOutput1 = new("00cddea8-939b-4b83-a340-a685226666cc");

    public const int DXGI_ERROR_WAIT_TIMEOUT = unchecked((int)0x88790001);
    public const int DXGI_ERROR_ACCESS_LOST = unchecked((int)0x887A0026);
    public const uint DXGI_FORMAT_B8G8R8A8_UNORM = 87;

    [StructLayout(LayoutKind.Sequential)]
    public struct DXGI_OUTPUT_DESC
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public char[] DeviceName;
        public RECT DesktopCoordinates;
        public int AttachedToDesktop;
        public int Rotation;
        public nint Monitor;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DXGI_OUTDUPL_FRAME_INFO
    {
        public long LastPresentTime;
        public long LastMouseUpdateTime;
        public uint AccumulatedFrames;
        public int RectsCoalesced;
        public int ProtectedContentMaskedOut;
        public DXGI_OUTDUPL_POINTER_POSITION PointerPosition;
        public uint TotalMetadataBufferSize;
        public uint PointerShapeBufferSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DXGI_OUTDUPL_POINTER_POSITION
    {
        public POINT Position;
        public int Visible;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X, Y;
    }

    [DllImport("dxgi.dll", PreserveSig = true)]
    public static extern int CreateDXGIFactory1(ref Guid riid, out nint ppFactory);

    // IDXGIFactory1::EnumAdapters1 - vtable index 12
    public static int IDXGIFactory1_EnumAdapters1(nint factory, uint index, out nint adapter)
    {
        var vtable = Marshal.ReadIntPtr(factory);
        var func = Marshal.GetDelegateForFunctionPointer<EnumAdapters1Delegate>(
            Marshal.ReadIntPtr(vtable, 12 * IntPtr.Size));
        return func(factory, index, out adapter);
    }
    private delegate int EnumAdapters1Delegate(nint self, uint index, out nint adapter);

    // IDXGIAdapter1::EnumOutputs - vtable index 7
    public static int IDXGIAdapter1_EnumOutputs(nint adapter, uint index, out nint output)
    {
        var vtable = Marshal.ReadIntPtr(adapter);
        var func = Marshal.GetDelegateForFunctionPointer<EnumOutputsDelegate>(
            Marshal.ReadIntPtr(vtable, 7 * IntPtr.Size));
        return func(adapter, index, out output);
    }
    private delegate int EnumOutputsDelegate(nint self, uint index, out nint output);

    // IDXGIOutput::GetDesc - vtable index 7
    public static int IDXGIOutput_GetDesc(nint output, out DXGI_OUTPUT_DESC desc)
    {
        var vtable = Marshal.ReadIntPtr(output);
        var func = Marshal.GetDelegateForFunctionPointer<GetDescDelegate>(
            Marshal.ReadIntPtr(vtable, 7 * IntPtr.Size));
        return func(output, out desc);
    }
    private delegate int GetDescDelegate(nint self, out DXGI_OUTPUT_DESC desc);

    // IUnknown::QueryInterface - vtable index 0
    public static int QueryInterface(nint obj, ref Guid riid, out nint ppvObject)
    {
        var vtable = Marshal.ReadIntPtr(obj);
        var func = Marshal.GetDelegateForFunctionPointer<QueryInterfaceDelegate>(
            Marshal.ReadIntPtr(vtable, 0));
        return func(obj, ref riid, out ppvObject);
    }
    private delegate int QueryInterfaceDelegate(nint self, ref Guid riid, out nint ppvObject);

    // IDXGIOutput1::DuplicateOutput - vtable index 22
    public static int IDXGIOutput1_DuplicateOutput(nint output1, nint device, out nint duplication)
    {
        var vtable = Marshal.ReadIntPtr(output1);
        var func = Marshal.GetDelegateForFunctionPointer<DuplicateOutputDelegate>(
            Marshal.ReadIntPtr(vtable, 22 * IntPtr.Size));
        return func(output1, device, out duplication);
    }
    private delegate int DuplicateOutputDelegate(nint self, nint device, out nint duplication);

    // IDXGIOutputDuplication::AcquireNextFrame - vtable index 8
    public static int IDXGIOutputDuplication_AcquireNextFrame(
        nint duplication, uint timeout, out DXGI_OUTDUPL_FRAME_INFO frameInfo, out nint resource)
    {
        var vtable = Marshal.ReadIntPtr(duplication);
        var func = Marshal.GetDelegateForFunctionPointer<AcquireNextFrameDelegate>(
            Marshal.ReadIntPtr(vtable, 8 * IntPtr.Size));
        return func(duplication, timeout, out frameInfo, out resource);
    }
    private delegate int AcquireNextFrameDelegate(
        nint self, uint timeout, out DXGI_OUTDUPL_FRAME_INFO frameInfo, out nint resource);

    // IDXGIOutputDuplication::ReleaseFrame - vtable index 14
    public static int IDXGIOutputDuplication_ReleaseFrame(nint duplication)
    {
        var vtable = Marshal.ReadIntPtr(duplication);
        var func = Marshal.GetDelegateForFunctionPointer<ReleaseFrameDelegate>(
            Marshal.ReadIntPtr(vtable, 14 * IntPtr.Size));
        return func(duplication);
    }
    private delegate int ReleaseFrameDelegate(nint self);
}

internal static class D3D11
{
    public static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    public const int D3D_DRIVER_TYPE_UNKNOWN = 0;
    public const int D3D11_SDK_VERSION = 7;
    public const int D3D11_USAGE_STAGING = 3;
    public const int D3D11_CPU_ACCESS_READ = 0x20000;
    public const int D3D11_MAP_READ = 1;

    [StructLayout(LayoutKind.Sequential)]
    public struct D3D11_TEXTURE2D_DESC
    {
        public uint Width;
        public uint Height;
        public uint MipLevels;
        public uint ArraySize;
        public uint Format;
        public DXGI_SAMPLE_DESC SampleDesc;
        public int Usage;
        public uint BindFlags;
        public int CPUAccessFlags;
        public uint MiscFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DXGI_SAMPLE_DESC
    {
        public uint Count;
        public uint Quality;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct D3D11_MAPPED_SUBRESOURCE
    {
        public nint pData;
        public uint RowPitch;
        public uint DepthPitch;
    }

    [DllImport("d3d11.dll", PreserveSig = true)]
    public static extern int D3D11CreateDevice(
        nint pAdapter,
        int DriverType,
        nint Software,
        uint Flags,
        nint pFeatureLevels,
        uint FeatureLevels,
        uint SDKVersion,
        out nint ppDevice,
        out int pFeatureLevel,
        out nint ppImmediateContext);

    // ID3D11Device::CreateTexture2D - vtable index 5
    public static int ID3D11Device_CreateTexture2D(
        nint device, ref D3D11_TEXTURE2D_DESC desc, nint initialData, out nint texture)
    {
        var vtable = Marshal.ReadIntPtr(device);
        var func = Marshal.GetDelegateForFunctionPointer<CreateTexture2DDelegate>(
            Marshal.ReadIntPtr(vtable, 5 * IntPtr.Size));
        return func(device, ref desc, initialData, out texture);
    }
    private delegate int CreateTexture2DDelegate(
        nint self, ref D3D11_TEXTURE2D_DESC desc, nint initialData, out nint texture);

    // ID3D11DeviceContext::CopyResource - vtable index 47
    public static void ID3D11DeviceContext_CopyResource(nint context, nint dst, nint src)
    {
        var vtable = Marshal.ReadIntPtr(context);
        var func = Marshal.GetDelegateForFunctionPointer<CopyResourceDelegate>(
            Marshal.ReadIntPtr(vtable, 47 * IntPtr.Size));
        func(context, dst, src);
    }
    private delegate void CopyResourceDelegate(nint self, nint dst, nint src);

    // ID3D11DeviceContext::Map - vtable index 14
    public static int ID3D11DeviceContext_Map(
        nint context, nint resource, uint subresource, int mapType, uint mapFlags,
        out D3D11_MAPPED_SUBRESOURCE mappedResource)
    {
        var vtable = Marshal.ReadIntPtr(context);
        var func = Marshal.GetDelegateForFunctionPointer<MapDelegate>(
            Marshal.ReadIntPtr(vtable, 14 * IntPtr.Size));
        return func(context, resource, subresource, mapType, mapFlags, out mappedResource);
    }
    private delegate int MapDelegate(
        nint self, nint resource, uint subresource, int mapType, uint mapFlags,
        out D3D11_MAPPED_SUBRESOURCE mappedResource);

    // ID3D11DeviceContext::Unmap - vtable index 15
    public static void ID3D11DeviceContext_Unmap(nint context, nint resource, uint subresource)
    {
        var vtable = Marshal.ReadIntPtr(context);
        var func = Marshal.GetDelegateForFunctionPointer<UnmapDelegate>(
            Marshal.ReadIntPtr(vtable, 15 * IntPtr.Size));
        func(context, resource, subresource);
    }
    private delegate void UnmapDelegate(nint self, nint resource, uint subresource);
}

#endregion

