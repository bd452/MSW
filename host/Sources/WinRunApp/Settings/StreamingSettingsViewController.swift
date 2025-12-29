import AppKit
import Foundation
import WinRunShared

/// View controller for the Streaming settings tab.
///
/// Allows users to configure frame buffer mode and view streaming statistics.
@available(macOS 13, *)
final class StreamingSettingsViewController: NSViewController {
    // MARK: - Properties

    private let configStore: ConfigStore
    private let logger: Logger

    /// Callback when frame buffer mode changes.
    var onFrameBufferModeChanged: ((FrameBufferMode) -> Void)?

    // MARK: - UI Elements

    private let frameBufferModePopup = NSPopUpButton()
    private let modeDescriptionLabel = NSTextField(wrappingLabelWithString: "")

    // Stats display (will be populated with real data in future)
    private let statsContainer = NSView()
    private let framesPerSecLabel = NSTextField(labelWithString: "Frames/sec: —")
    private let memoryUsageLabel = NSTextField(labelWithString: "Memory usage: —")
    private let totalAllocationLabel = NSTextField(labelWithString: "Total allocation: —")
    private let windowCountLabel = NSTextField(labelWithString: "Active windows: —")

    // MARK: - Initialization

    init(
        configStore: ConfigStore = ConfigStore(),
        logger: Logger = StandardLogger(subsystem: "WinRunApp.Settings")
    ) {
        self.configStore = configStore
        self.logger = logger
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        view = NSView()

        setupFrameBufferModeSection()
        setupStatsSection()
        setupConstraints()

        loadCurrentSettings()
    }

    // MARK: - UI Setup

    private func setupFrameBufferModeSection() {
        let sectionTitle = NSTextField(labelWithString: "Frame Buffer Mode")
        sectionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false

        let sectionDescription = NSTextField(wrappingLabelWithString:
            "Controls how frame data is allocated and transferred from the Windows VM to your Mac."
        )
        sectionDescription.font = .systemFont(ofSize: 12)
        sectionDescription.textColor = .secondaryLabelColor
        sectionDescription.translatesAutoresizingMaskIntoConstraints = false

        // Frame buffer mode popup
        frameBufferModePopup.translatesAutoresizingMaskIntoConstraints = false
        frameBufferModePopup.removeAllItems()
        for mode in FrameBufferMode.allCases {
            frameBufferModePopup.addItem(withTitle: mode.displayName)
            frameBufferModePopup.lastItem?.representedObject = mode
        }
        frameBufferModePopup.target = self
        frameBufferModePopup.action = #selector(frameBufferModeChanged(_:))

        // Mode description label
        modeDescriptionLabel.font = .systemFont(ofSize: 11)
        modeDescriptionLabel.textColor = .tertiaryLabelColor
        modeDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        modeDescriptionLabel.maximumNumberOfLines = 0
        modeDescriptionLabel.preferredMaxLayoutWidth = 350

        view.addSubview(sectionTitle)
        view.addSubview(sectionDescription)
        view.addSubview(frameBufferModePopup)
        view.addSubview(modeDescriptionLabel)

        // Store for constraints
        sectionTitle.identifier = NSUserInterfaceItemIdentifier("frameBufferTitle")
        sectionDescription.identifier = NSUserInterfaceItemIdentifier("frameBufferDescription")
    }

    private func setupStatsSection() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let statsTitle = NSTextField(labelWithString: "Streaming Statistics")
        statsTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        statsTitle.translatesAutoresizingMaskIntoConstraints = false

        let statsDescription = NSTextField(wrappingLabelWithString:
            "Real-time statistics about frame streaming performance."
        )
        statsDescription.font = .systemFont(ofSize: 12)
        statsDescription.textColor = .secondaryLabelColor
        statsDescription.translatesAutoresizingMaskIntoConstraints = false

        statsContainer.translatesAutoresizingMaskIntoConstraints = false

        // Configure stat labels
        let statLabels = [framesPerSecLabel, memoryUsageLabel, totalAllocationLabel, windowCountLabel]
        for label in statLabels {
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            statsContainer.addSubview(label)
        }

        view.addSubview(separator)
        view.addSubview(statsTitle)
        view.addSubview(statsDescription)
        view.addSubview(statsContainer)

        // Store for constraints
        separator.identifier = NSUserInterfaceItemIdentifier("statsSeparator")
        statsTitle.identifier = NSUserInterfaceItemIdentifier("statsTitle")
        statsDescription.identifier = NSUserInterfaceItemIdentifier("statsDescription")
    }

    private func setupConstraints() {
        guard let frameBufferTitle = view.subviews.first(where: { $0.identifier?.rawValue == "frameBufferTitle" }),
              let frameBufferDescription = view.subviews.first(where: { $0.identifier?.rawValue == "frameBufferDescription" }),
              let separator = view.subviews.first(where: { $0.identifier?.rawValue == "statsSeparator" }),
              let statsTitle = view.subviews.first(where: { $0.identifier?.rawValue == "statsTitle" }),
              let statsDescription = view.subviews.first(where: { $0.identifier?.rawValue == "statsDescription" })
        else { return }

        NSLayoutConstraint.activate([
            // View minimum size
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),

            // Frame Buffer Mode section
            frameBufferTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            frameBufferTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            frameBufferTitle.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            frameBufferDescription.topAnchor.constraint(equalTo: frameBufferTitle.bottomAnchor, constant: 6),
            frameBufferDescription.leadingAnchor.constraint(equalTo: frameBufferTitle.leadingAnchor),
            frameBufferDescription.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            frameBufferModePopup.topAnchor.constraint(equalTo: frameBufferDescription.bottomAnchor, constant: 12),
            frameBufferModePopup.leadingAnchor.constraint(equalTo: frameBufferTitle.leadingAnchor),
            frameBufferModePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            modeDescriptionLabel.topAnchor.constraint(equalTo: frameBufferModePopup.bottomAnchor, constant: 8),
            modeDescriptionLabel.leadingAnchor.constraint(equalTo: frameBufferTitle.leadingAnchor),
            modeDescriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Separator
            separator.topAnchor.constraint(equalTo: modeDescriptionLabel.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Stats section
            statsTitle.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            statsTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statsTitle.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            statsDescription.topAnchor.constraint(equalTo: statsTitle.bottomAnchor, constant: 6),
            statsDescription.leadingAnchor.constraint(equalTo: statsTitle.leadingAnchor),
            statsDescription.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            statsContainer.topAnchor.constraint(equalTo: statsDescription.bottomAnchor, constant: 12),
            statsContainer.leadingAnchor.constraint(equalTo: statsTitle.leadingAnchor),
            statsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statsContainer.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),

            // Stats labels inside container
            framesPerSecLabel.topAnchor.constraint(equalTo: statsContainer.topAnchor),
            framesPerSecLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor),

            memoryUsageLabel.topAnchor.constraint(equalTo: framesPerSecLabel.bottomAnchor, constant: 6),
            memoryUsageLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor),

            totalAllocationLabel.topAnchor.constraint(equalTo: memoryUsageLabel.bottomAnchor, constant: 6),
            totalAllocationLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor),

            windowCountLabel.topAnchor.constraint(equalTo: totalAllocationLabel.bottomAnchor, constant: 6),
            windowCountLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor),
            windowCountLabel.bottomAnchor.constraint(equalTo: statsContainer.bottomAnchor),
        ])
    }

    // MARK: - Settings Management

    private func loadCurrentSettings() {
        let config = configStore.loadOrDefault()
        let mode = config.frameStreaming.frameBufferMode

        // Select the current mode in popup
        for index in 0..<frameBufferModePopup.numberOfItems {
            if let itemMode = frameBufferModePopup.item(at: index)?.representedObject as? FrameBufferMode,
               itemMode == mode {
                frameBufferModePopup.selectItem(at: index)
                break
            }
        }

        updateModeDescription(for: mode)
        logger.debug("Loaded frame buffer mode: \(mode.rawValue)")
    }

    private func updateModeDescription(for mode: FrameBufferMode) {
        modeDescriptionLabel.stringValue = mode.detailedDescription
    }

    // MARK: - Actions

    @objc private func frameBufferModeChanged(_ sender: NSPopUpButton) {
        guard let selectedMode = sender.selectedItem?.representedObject as? FrameBufferMode else {
            return
        }

        updateModeDescription(for: selectedMode)

        // Save to config
        do {
            var config = configStore.loadOrDefault()
            config.frameStreaming.frameBufferMode = selectedMode
            try configStore.save(config)
            logger.info("Frame buffer mode changed to: \(selectedMode.rawValue)")
            onFrameBufferModeChanged?(selectedMode)
        } catch {
            logger.error("Failed to save frame buffer mode: \(error)")

            // Show error alert
            let alert = NSAlert()
            alert.messageText = "Failed to Save Setting"
            alert.informativeText = "Could not save the frame buffer mode setting: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Stats Updates

    /// Updates the streaming statistics display.
    ///
    /// Call this method periodically to update the stats with real data.
    /// - Parameters:
    ///   - framesPerSecond: Current frame rate
    ///   - memoryUsageMB: Per-window memory usage in MB
    ///   - totalAllocationMB: Total allocated memory in MB
    ///   - activeWindows: Number of active windows
    func updateStats(
        framesPerSecond: Double,
        memoryUsageMB: Double,
        totalAllocationMB: Double,
        activeWindows: Int
    ) {
        framesPerSecLabel.stringValue = String(format: "Frames/sec: %.1f", framesPerSecond)
        memoryUsageLabel.stringValue = String(format: "Memory usage: %.1f MB/window", memoryUsageMB)
        totalAllocationLabel.stringValue = String(format: "Total allocation: %.1f MB", totalAllocationMB)
        windowCountLabel.stringValue = "Active windows: \(activeWindows)"
    }

    /// Clears stats display (e.g., when VM is not running).
    func clearStats() {
        framesPerSecLabel.stringValue = "Frames/sec: —"
        memoryUsageLabel.stringValue = "Memory usage: —"
        totalAllocationLabel.stringValue = "Total allocation: —"
        windowCountLabel.stringValue = "Active windows: —"
    }
}
