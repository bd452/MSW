import Foundation

// MARK: - Input Models
//
// All input-related types have been moved to WinRunSpiceBridge to use the
// generated protocol types from Protocol.generated.swift:
//
// - MouseButton, MouseEventType, KeyEventType, KeyModifiers,
//   DragDropEventType, DragOperation, ClipboardFormat
//   → Protocol.generated.swift
//
// - MouseInputEvent, KeyboardInputEvent
//   → InputEventTypes.swift
//
// - DraggedFile, DragDropEvent
//   → InputEventTypes.swift
//
// - ClipboardDirection, ClipboardData, ClipboardEvent
//   → ClipboardTypes.swift
//
// - KeyCodeMapper
//   → KeyCodeMapper.swift
//
// This file is kept for backwards compatibility and documentation.
// Import WinRunSpiceBridge to access these types.
