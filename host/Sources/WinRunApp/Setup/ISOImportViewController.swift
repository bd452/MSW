import AppKit
import Foundation
import WinRunSetup

/// Setup wizard screen for importing a Windows ISO.
@available(macOS 13, *)
final class ISOImportViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Import a Windows ISO")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "Drag and drop a Windows 11 ARM64 .iso file to begin.")
    private let selectedFileLabel = NSTextField(labelWithString: "No ISO selected")
    private let chooseFileButton = NSButton(title: "Choose ISO…", target: nil, action: nil)
    private let validationStatusLabel = NSTextField(labelWithString: "")
    private let warningsLabel = NSTextField(wrappingLabelWithString: "")
    private let dropZoneView = ISODropZoneView()

    /// Called when a valid ISO file is selected via drag/drop.
    var onISOSelected: ((URL) -> Void)?

    private var validationTask: Task<Void, Never>?
    private var lastSelectedISO: URL?

    override func loadView() {
        view = NSView()

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        selectedFileLabel.font = .systemFont(ofSize: 12)
        selectedFileLabel.textColor = .secondaryLabelColor

        chooseFileButton.target = self
        chooseFileButton.action = #selector(chooseISOFile)
        chooseFileButton.bezelStyle = .rounded

        validationStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        validationStatusLabel.textColor = .secondaryLabelColor
        validationStatusLabel.stringValue = "No ISO selected"

        warningsLabel.font = .systemFont(ofSize: 12)
        warningsLabel.textColor = .secondaryLabelColor
        warningsLabel.lineBreakMode = .byWordWrapping
        warningsLabel.maximumNumberOfLines = 0

        dropZoneView.onFileAccepted = { [weak self] url in
            self?.handleISOSelected(url)
        }

        for subview in [
            titleLabel,
            subtitleLabel,
            dropZoneView,
            chooseFileButton,
            selectedFileLabel,
            validationStatusLabel,
            warningsLabel,
        ] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            dropZoneView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            dropZoneView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dropZoneView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            dropZoneView.heightAnchor.constraint(equalToConstant: 180),

            chooseFileButton.topAnchor.constraint(equalTo: dropZoneView.bottomAnchor, constant: 12),
            chooseFileButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            selectedFileLabel.topAnchor.constraint(equalTo: chooseFileButton.bottomAnchor, constant: 10),
            selectedFileLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            selectedFileLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            validationStatusLabel.topAnchor.constraint(equalTo: selectedFileLabel.bottomAnchor, constant: 8),
            validationStatusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            validationStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            warningsLabel.topAnchor.constraint(equalTo: validationStatusLabel.bottomAnchor, constant: 8),
            warningsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            warningsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            warningsLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])
    }

    private func handleISOSelected(_ url: URL) {
        lastSelectedISO = url
        selectedFileLabel.stringValue = url.lastPathComponent
        validationStatusLabel.stringValue = "Validating…"
        warningsLabel.stringValue = ""

        onISOSelected?(url)

        validationTask?.cancel()
        validationTask = Task { [weak self] in
            guard let self else { return }

            let validator = ISOValidator()
            do {
                let result = try await validator.validate(isoURL: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.lastSelectedISO == url else { return }
                    self.applyValidationResult(result)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.lastSelectedISO == url else { return }
                    self.validationStatusLabel.stringValue = "Could not validate ISO"
                    self.validationStatusLabel.textColor = .systemRed
                    self.warningsLabel.stringValue = (error as NSError).localizedDescription
                }
            }
        }
    }

    private func applyValidationResult(_ result: ISOValidationResult) {
        if let info = result.editionInfo {
            validationStatusLabel.stringValue = "\(info.editionName) • \(info.architecture) • \(info.version)"
            validationStatusLabel.textColor = info.isARM64 ? .secondaryLabelColor : .systemRed
        } else {
            validationStatusLabel.stringValue = "Validated, but Windows version details could not be read"
            validationStatusLabel.textColor = .secondaryLabelColor
        }

        if result.warnings.isEmpty {
            warningsLabel.stringValue = result.isRecommended
                ? "Looks good — this is the recommended Windows edition for WinRun."
                : "No issues detected."
            return
        }

        warningsLabel.stringValue = result.warnings
            .map { warning in
                let prefix: String = switch warning.severity {
                case .critical: "Critical"
                case .warning: "Warning"
                case .info: "Info"
                }
                if let suggestion = warning.suggestion, !suggestion.isEmpty {
                    return "\(prefix): \(warning.message)\n  \(suggestion)"
                }
                return "\(prefix): \(warning.message)"
            }
            .joined(separator: "\n\n")
    }

    @objc private func chooseISOFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["iso"]
        panel.title = "Choose a Windows ISO"
        panel.message = "Select a Windows 11 ARM64 .iso file."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        handleISOSelected(url)
    }
}

@available(macOS 13, *)
private final class ISODropZoneView: NSView {
    var onFileAccepted: ((URL) -> Void)?

    private let label = NSTextField(labelWithString: "Drop Windows ISO here")
    private var isDragTargeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])

        wantsLayer = true
        layer?.cornerRadius = 10

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundColor: NSColor = isDragTargeted ? .selectedContentBackgroundColor : .controlBackgroundColor
        backgroundColor.setFill()
        dirtyRect.fill()

        let strokeColor: NSColor = isDragTargeted ? .controlAccentColor : .separatorColor
        strokeColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        let dashes: [CGFloat] = [6, 4]
        path.setLineDash(dashes, count: dashes.count, phase: 0)
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAcceptableISO(sender) else {
            isDragTargeted = false
            return []
        }
        isDragTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isAcceptableISO(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isDragTargeted = false }
        guard let url = extractFirstFileURL(from: sender),
              url.pathExtension.lowercased() == "iso"
        else {
            return false
        }

        onFileAccepted?(url)
        return true
    }

    private func isAcceptableISO(_ sender: NSDraggingInfo) -> Bool {
        guard let url = extractFirstFileURL(from: sender) else { return false }
        return url.pathExtension.lowercased() == "iso"
    }

    private func extractFirstFileURL(from sender: NSDraggingInfo) -> URL? {
        let pasteboard = sender.draggingPasteboard
        guard let items = pasteboard.pasteboardItems else { return nil }

        for item in items {
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value)
            else { continue }
            return url
        }
        return nil
    }
}
