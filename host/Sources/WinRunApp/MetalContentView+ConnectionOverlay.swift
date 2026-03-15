import AppKit
import WinRunSpiceBridge

// MARK: - Connection Overlay

@available(macOS 13, *)
extension MetalContentView {
    func setupConnectionOverlay() {
        let overlay = NSVisualEffectView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.material = .hudWindow
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12
        overlay.isHidden = true

        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
            overlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        let spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        overlay.addSubview(spinner)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        overlay.addSubview(label)

        let button = NSButton(title: "Retry", target: self, action: #selector(retryButtonClicked))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.isHidden = true
        overlay.addSubview(button)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            button.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            button.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -20)
        ])

        connectionOverlay = overlay
        statusLabel = label
        retryButton = button
        self.spinner = spinner
    }

    func updateConnectionState(_ state: SpiceConnectionState) {
        currentConnectionState = state

        if connectionOverlay == nil {
            setupConnectionOverlay()
        }

        guard let overlay = connectionOverlay,
              let label = statusLabel,
              let button = retryButton,
              let spinner = spinner else { return }

        switch state {
        case .connected:
            overlay.isHidden = true
            spinner.stopAnimation(nil)
        case .disconnected:
            overlay.isHidden = false
            label.stringValue = "Disconnected"
            button.isHidden = true
            spinner.stopAnimation(nil)
        case .connecting:
            overlay.isHidden = false
            label.stringValue = "Connecting..."
            button.isHidden = true
            spinner.startAnimation(nil)
        case .reconnecting(let attempt, let maxAttempts):
            overlay.isHidden = false
            if let max = maxAttempts {
                label.stringValue = "Reconnecting (attempt \(attempt) of \(max))..."
            } else {
                label.stringValue = "Reconnecting (attempt \(attempt))..."
            }
            button.isHidden = true
            spinner.startAnimation(nil)
        case .failed(let reason):
            overlay.isHidden = false
            label.stringValue = "Connection failed:\n\(reason)"
            button.isHidden = false
            spinner.stopAnimation(nil)
        }
    }

    @objc func retryButtonClicked() {
        inputDelegate?.metalContentViewDidRequestRetry(self)
    }
}
