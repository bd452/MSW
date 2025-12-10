import Foundation
import WinRunShared
#if os(macOS)
import CSpiceBridge
typealias SpiceStreamHandle = winrun_spice_stream_handle
#endif

// MARK: - Transport Protocol

protocol SpiceStreamTransport {
    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription

    func closeStream(_ subscription: SpiceStreamSubscription)

    // Input forwarding
    func sendMouseEvent(_ event: MouseInputEvent)
    func sendKeyboardEvent(_ event: KeyboardInputEvent)

    // Clipboard
    func sendClipboard(_ clipboard: ClipboardData)
    func requestClipboard(format: ClipboardFormat)

    // Drag and drop
    func sendDragDropEvent(_ event: DragDropEvent)
}

// MARK: - macOS Implementation

#if os(macOS)
final class LibSpiceStreamTransport: SpiceStreamTransport {
    private let logger: Logger
    private var currentHandle: SpiceStreamHandle?

    init(logger: Logger) {
        self.logger = logger
    }

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        let trampoline = CallbackTrampoline(callbacks: callbacks)
        let unmanaged = Unmanaged.passRetained(trampoline)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let handle: SpiceStreamHandle?

        switch configuration.transport {
        case let .tcp(host, port, security, ticket):
            handle = host.withCString { hostPointer in
                if let ticket {
                    return ticket.withCString { ticketPointer in
                        winrun_spice_stream_open_tcp(
                            hostPointer,
                            port,
                            security == .tls,
                            windowID,
                            unmanaged.toOpaque(),
                            spiceFrameThunk,
                            spiceMetadataThunk,
                            spiceClosedThunk,
                            ticketPointer,
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                } else {
                    return winrun_spice_stream_open_tcp(
                        hostPointer,
                        port,
                        security == .tls,
                        windowID,
                        unmanaged.toOpaque(),
                        spiceFrameThunk,
                        spiceMetadataThunk,
                        spiceClosedThunk,
                        nil,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
        case let .sharedMemory(descriptor, ticket):
            guard descriptor >= 0 else {
                unmanaged.release()
                throw SpiceStreamError.sharedMemoryUnavailable("Missing shared-memory descriptor")
            }

            if let ticket {
                handle = ticket.withCString { ticketPointer in
                    winrun_spice_stream_open_shared(
                        descriptor,
                        windowID,
                        unmanaged.toOpaque(),
                        spiceFrameThunk,
                        spiceMetadataThunk,
                        spiceClosedThunk,
                        ticketPointer,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            } else {
                handle = winrun_spice_stream_open_shared(
                    descriptor,
                    windowID,
                    unmanaged.toOpaque(),
                    spiceFrameThunk,
                    spiceMetadataThunk,
                    spiceClosedThunk,
                    nil,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }

        guard handle != nil else {
            unmanaged.release()
            let message = String(cString: errorBuffer)
            throw SpiceStreamError.connectionFailed(message.isEmpty ? "Unknown libspice error" : message)
        }

        self.currentHandle = handle

        return SpiceStreamSubscription {
            if let handle {
                winrun_spice_stream_close(handle)
            }
            unmanaged.release()
        }
    }

    func closeStream(_ subscription: SpiceStreamSubscription) {
        currentHandle = nil
        subscription.cleanup()
    }

    // MARK: - Input Forwarding

    func sendMouseEvent(_ event: MouseInputEvent) {
        guard let handle = currentHandle else { return }

        var cEvent = winrun_mouse_event(
            window_id: event.windowID,
            event_type: winrun_mouse_event_type(rawValue: UInt32(event.eventType.rawValue)),
            button: winrun_mouse_button(rawValue: UInt32(event.button?.rawValue ?? 0)),
            x: event.x,
            y: event.y,
            scroll_delta_x: event.scrollDeltaX,
            scroll_delta_y: event.scrollDeltaY,
            modifiers: event.modifiers.rawValue
        )

        _ = winrun_spice_send_mouse_event(handle, &cEvent)
    }

    func sendKeyboardEvent(_ event: KeyboardInputEvent) {
        guard let handle = currentHandle else { return }

        let character = event.character

        if let character {
            character.withCString { charPtr in
                var cEvent = winrun_keyboard_event(
                    window_id: event.windowID,
                    event_type: winrun_key_event_type(rawValue: UInt32(event.eventType.rawValue)),
                    key_code: event.keyCode,
                    scan_code: event.scanCode,
                    is_extended_key: event.isExtendedKey,
                    modifiers: event.modifiers.rawValue,
                    character: charPtr
                )
                _ = winrun_spice_send_keyboard_event(handle, &cEvent)
            }
        } else {
            var cEvent = winrun_keyboard_event(
                window_id: event.windowID,
                event_type: winrun_key_event_type(rawValue: UInt32(event.eventType.rawValue)),
                key_code: event.keyCode,
                scan_code: event.scanCode,
                is_extended_key: event.isExtendedKey,
                modifiers: event.modifiers.rawValue,
                character: nil
            )
            _ = winrun_spice_send_keyboard_event(handle, &cEvent)
        }
    }

    // MARK: - Clipboard

    func sendClipboard(_ clipboard: ClipboardData) {
        guard let handle = currentHandle else { return }

        clipboard.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var cClipboard = winrun_clipboard_data(
                format: clipboardFormatToC(clipboard.format),
                data: baseAddress.assumingMemoryBound(to: UInt8.self),
                data_length: clipboard.data.count,
                sequence_number: clipboard.sequenceNumber
            )
            _ = winrun_spice_send_clipboard(handle, &cClipboard)
        }
    }

    func requestClipboard(format: ClipboardFormat) {
        guard let handle = currentHandle else { return }
        winrun_spice_request_clipboard(handle, clipboardFormatToC(format))
    }

    // MARK: - Drag and Drop

    func sendDragDropEvent(_ event: DragDropEvent) {
        guard let handle = currentHandle else { return }

        // Convert files to C structs
        var cFiles: [winrun_dragged_file] = []
        var hostPathPtrs: [UnsafeMutablePointer<CChar>?] = []
        var guestPathPtrs: [UnsafeMutablePointer<CChar>?] = []

        for file in event.files {
            let hostPtr = strdup(file.hostPath)
            let guestPtr = file.guestPath.flatMap { strdup($0) }
            hostPathPtrs.append(hostPtr)
            guestPathPtrs.append(guestPtr)

            cFiles.append(winrun_dragged_file(
                host_path: hostPtr,
                guest_path: guestPtr,
                file_size: file.fileSize,
                is_directory: file.isDirectory
            ))
        }

        defer {
            for ptr in hostPathPtrs { free(ptr) }
            for ptr in guestPathPtrs { free(ptr) }
        }

        cFiles.withUnsafeBufferPointer { filesBuffer in
            var cEvent = winrun_drag_event(
                window_id: event.windowID,
                event_type: winrun_drag_event_type(rawValue: UInt32(event.eventType.rawValue)),
                x: event.x,
                y: event.y,
                files: filesBuffer.baseAddress,
                file_count: event.files.count,
                allowed_operations: winrun_drag_operation(rawValue: UInt32(event.allowedOperations.first?.rawValue ?? 0)),
                selected_operation: winrun_drag_operation(rawValue: UInt32(event.selectedOperation?.rawValue ?? 0))
            )
            _ = winrun_spice_send_drag_event(handle, &cEvent)
        }
    }

    private func clipboardFormatToC(_ format: ClipboardFormat) -> winrun_clipboard_format {
        switch format {
        case .plainText: return WINRUN_CLIPBOARD_FORMAT_TEXT
        case .rtf: return WINRUN_CLIPBOARD_FORMAT_RTF
        case .html: return WINRUN_CLIPBOARD_FORMAT_HTML
        case .png: return WINRUN_CLIPBOARD_FORMAT_PNG
        case .tiff: return WINRUN_CLIPBOARD_FORMAT_TIFF
        case .fileURL: return WINRUN_CLIPBOARD_FORMAT_FILE_URL
        }
    }
}

// MARK: - C Callback Trampolines

private final class CallbackTrampoline {
    private let callbacks: SpiceStreamCallbacks

    init(callbacks: SpiceStreamCallbacks) {
        self.callbacks = callbacks
    }

    func handleFrame(_ data: Data) {
        callbacks.onFrame(data)
    }

    func handleMetadata(_ metadata: WindowMetadata) {
        callbacks.onMetadata(metadata)
    }

    func handleClose(_ reason: SpiceStreamCloseReason) {
        callbacks.onClosed(reason)
    }

    func handleClipboard(_ clipboard: ClipboardData) {
        callbacks.onClipboard(clipboard)
    }
}

private let spiceFrameThunk: @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { bytes, length, userData in
    guard let bytes, let userData else { return }
    let trampoline = Unmanaged<CallbackTrampoline>.fromOpaque(userData).takeUnretainedValue()
    let frame = Data(bytes: bytes, count: length)
    trampoline.handleFrame(frame)
}

private let spiceMetadataThunk: @convention(c) (
    UnsafePointer<winrun_spice_window_metadata>?,
    UnsafeMutableRawPointer?
) -> Void = { metadataPointer, userData in
    guard let metadataPointer, let userData else { return }
    let metadata = metadataPointer.pointee
    let title = metadata.title.flatMap { String(cString: $0) } ?? "Windows Application"
    let frame = CGRect(
        x: metadata.position_x,
        y: metadata.position_y,
        width: metadata.width,
        height: metadata.height
    )
    let windowMetadata = WindowMetadata(
        windowID: metadata.window_id,
        title: title,
        frame: frame,
        isResizable: metadata.is_resizable,
        scaleFactor: CGFloat(metadata.scale_factor)
    )
    let trampoline = Unmanaged<CallbackTrampoline>.fromOpaque(userData).takeUnretainedValue()
    trampoline.handleMetadata(windowMetadata)
}

private let spiceClosedThunk: @convention(c) (
    winrun_spice_close_reason,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { reason, messagePointer, userData in
    guard let userData else { return }
    let message = messagePointer.flatMap { String(cString: $0) } ?? ""
    let code: SpiceStreamCloseReason.Code
    switch reason {
    case WINRUN_SPICE_CLOSE_REASON_REMOTE:
        code = .remoteClosed
    case WINRUN_SPICE_CLOSE_REASON_AUTHENTICATION:
        code = .authenticationFailed
    default:
        code = .transportError
    }

    let trampoline = Unmanaged<CallbackTrampoline>.fromOpaque(userData).takeUnretainedValue()
    trampoline.handleClose(SpiceStreamCloseReason(code: code, message: message))
}
#else
// MARK: - Mock Implementation (non-macOS)

final class MockSpiceStreamTransport: SpiceStreamTransport {
    private final class TimerBox {
        var timer: DispatchSourceTimer?
    }

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        logger.info("Mock Spice stream open for window \(windowID) via \(configuration.transport.summaryDescription)")
        let box = TimerBox()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler {
            let fakeFrame = Data(repeating: UInt8.random(in: 0...255), count: 1024)
            callbacks.onFrame(fakeFrame)
            let metadata = WindowMetadata(
                windowID: windowID,
                title: "Mock Window \(windowID)",
                frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                isResizable: true
            )
            callbacks.onMetadata(metadata)
        }
        timer.resume()
        box.timer = timer

        return SpiceStreamSubscription {
            box.timer?.cancel()
        }
    }

    func closeStream(_ subscription: SpiceStreamSubscription) {
        subscription.cleanup()
    }

    // MARK: - Input Forwarding (Mock)

    func sendMouseEvent(_ event: MouseInputEvent) {
        logger.debug("Mock: sendMouseEvent type=\(event.eventType) at (\(event.x), \(event.y))")
    }

    func sendKeyboardEvent(_ event: KeyboardInputEvent) {
        logger.debug("Mock: sendKeyboardEvent type=\(event.eventType) keyCode=\(event.keyCode)")
    }

    // MARK: - Clipboard (Mock)

    func sendClipboard(_ clipboard: ClipboardData) {
        logger.debug("Mock: sendClipboard format=\(clipboard.format) size=\(clipboard.data.count)")
    }

    func requestClipboard(format: ClipboardFormat) {
        logger.debug("Mock: requestClipboard format=\(format)")
    }

    // MARK: - Drag and Drop (Mock)

    func sendDragDropEvent(_ event: DragDropEvent) {
        logger.debug("Mock: sendDragDropEvent type=\(event.eventType) files=\(event.files.count)")
    }
}
#endif
